import Foundation
import NotebookCore
import Observation
import QuartzCore
/// The current contact and its accepted working members share this one native
/// exchange. It retains no screenshot and owns no render clock. Source and
/// material drawables are private until the existing canvas install transaction.
@MainActor @Observable final class NotebookSelectionPresentation: Equatable {
  nonisolated static func ==(lhs:NotebookSelectionPresentation,rhs:NotebookSelectionPresentation)->Bool { lhs === rhs }
  let id:UUID
  let source:NotebookSelectionEditSource
  let membersByID:[String:NotebookGraphicSelection.Member]
  @ObservationIgnored private weak var model:NotebookAppModel?
  @ObservationIgnored private weak var canvas:InkCanvasView?
  private var restoration:InkCanvasView.SourceRestoration?
  private let isSpatial:Bool
  private let originalWorking:[NotebookWorkingGraphic]
  private let originals:[String:NotebookOrderedInkPlan.Body]
  private let rawMemberIDs:Set<String>
  #if os(iOS)
  @ObservationIgnored private let requiredAuthoredHostIDs:Set<String>
  @ObservationIgnored private let requiredTextHostIDs:Set<String>
  @ObservationIgnored private var physicalLease:SpatialInkSurfaceRegistry.ContactLease?
  #endif
  @ObservationIgnored private var preparation:Task<Void,Never>?
  @ObservationIgnored private var generation=UUID()
  @ObservationIgnored private var claimed=false
  @ObservationIgnored private var accepted=false
  @ObservationIgnored private var acceptedCursor:UInt64?
  @ObservationIgnored private var acceptedSources:[EditableElementReference:NotebookNativeElementSource]=[:]
  @ObservationIgnored private(set) var canonicalAuthoredCutReady=false
  @ObservationIgnored private var canonicalCommitScheduled=false
  @ObservationIgnored private var preparationFailed=false
  @ObservationIgnored private var deleting=false
  #if os(iOS)
  @ObservationIgnored private var installedHostGenerations:[String:UUID]=[:]
  @ObservationIgnored private var installedDisplayGenerations:[String:UUID]=[:]
  #endif
  /// Geometry, authored poses and controls are one cut. A newer contact pose
  /// replaces demand; only the native installation publishes its whole result.
  private struct Cut:Equatable {
    let working:[NotebookWorkingGraphic]
    let edits:[NotebookGraphicSelection.Edit]
    let frame:CGRect
  }
  @ObservationIgnored private var desired:Cut?
  private var presented:Cut?
  private var originalCut:Cut {
    .init(working:originalWorking,edits:NotebookGraphicSelection.translated(source.members,by:.zero),
      frame:NotebookGraphicSelection.bounds(source.members,relativeTo:source.members.first?.origin ?? .zero))
  }
  var presentedEdits:[NotebookGraphicSelection.Edit]? {presented?.edits}
  var presentedFrame:CGRect? {presented?.frame}
  var working:[NotebookWorkingGraphic] {
    (presented?.working ?? originalWorking).map {value in var value=value;value.inkPresentation=self;return value}
  }
  var installed:Bool {presented != nil}
  private(set) var retiring=false
  @ObservationIgnored private var disposed=false
  var ownsAuthoredHosts:Bool { !disposed }
  var retainsOriginal:Bool {!installed && !disposed}
  func retainsRawSource(_ id:String)->Bool {
    // An installed preview keeps its raw suppression through cancellation.
    // SourceRestoration returns raw/body/peers together; projecting the old
    // source before that install creates a second, competing restoration.
    retainsOriginal && rawMemberIDs.contains(id)
  }
  /// A failed private stage may yield source preparation to the accepted
  /// canonical owner, but controls still describe the last installed picture.
  var acceptedAwaitingPresentation:Bool {!disposed && accepted && !installed}
  var needsCanonicalSource:Bool {!disposed && accepted && (preparationFailed || !installed)}
  var awaitsAcceptedDeleteCut:Bool {!disposed && accepted && deleting && canvas != nil}
  func acceptsCanonicalCut(_ cursor:UInt64)->Bool {
    awaitsAcceptedDeleteCut && acceptedCursor.map({cursor >= $0}) == true && acceptedSourcesAreLoaded
  }
  private var acceptedSourcesAreLoaded:Bool {
    guard let model,!acceptedSources.isEmpty else {return false}
    return acceptedSources.allSatisfy { reference, expected in
      model.nativeElementSource(reference)?.covers(expected) == true
    }
  }
  // Cancellation ends the contact, not its installed picture. Authored peers
  // and controls leave this pose only with the raw restoration's frame receipt.
  var holdsPresentation:Bool {!disposed && (retiring || presented != desired || needsCanonicalSource || (canvas == nil && installed))}
  func update(_ values:[NotebookWorkingGraphic],edits:[NotebookGraphicSelection.Edit],frame:CGRect) {
    guard !disposed,!retiring else {return}
    desired=Cut(working:values,edits:edits,frame:frame)
    // Selection is read-only until the actual desired pose differs. The raw
    // stream keeps its exact original alpha grouping until that first edit.
    guard values != originalWorking || edits != NotebookGraphicSelection.translated(source.members,by:.zero) || installed else {return}
    prepareIfPossible()
  }

  func stageDeletion() { deleting=true }

  init?(id:UUID,source:NotebookSelectionEditSource,model:NotebookAppModel) {
    let raw:InkCanvasView?
    if source.needsOrderedPresentation {
      if source.address.surface.kind == .page,let pageID=source.address.surface.ownerID {
        raw=model.pageInkPublication.currentCanvas(on:pageID)
        isSpatial=false
      } else {
        let registry=model.compositionTiles.surfaceRegistry
        raw=registry.canvas(for:source.address.surface)
        guard raw?.installedSpatialSource != nil,model.selectionEditSourceIsCurrent(source) else {return nil}
        isSpatial=true
        #if os(iOS)
        if let raw { physicalLease=registry.acquireContact(on:source.address.surface,in:raw) }
        #endif
      }
      guard raw != nil else {return nil}
    } else {
      #if os(iOS)
      raw=nil;isSpatial=source.address.surface.kind != .page
      #else
      return nil
      #endif
    }
    let selectedIDs=Set(source.members.map(\.id))
    guard !model.workingGraphics.contains(where: {selectedIDs.contains($0.id)
      && $0.surface == source.address.surface && $0.inkPresentation?.holdsPresentation == true}) else {return nil}
    var originals:[String:NotebookOrderedInkPlan.Body]=[:]
    var restoration:InkCanvasView.SourceRestoration?
    if let raw {
      for member in source.orderedMembers {
        guard let body=raw.orderedInkPlan.bodies.first(where:{$0.elementID == member.id}),
          body.graphic == member.graphic,body.layout == member.layout else {return nil}
        originals[member.id]=body
      }
      let sourceIDs=Set(source.ink.map(\.actionID)).union(originals.values.map(\.sourceID))
      guard !sourceIDs.isEmpty,let captured=raw.captureSourceRestoration(for:sourceIDs) else {return nil}
      restoration=captured
    }
    self.originals=originals;originalWorking=source.initialPresentationWorking
    rawMemberIDs=Set(source.ink.map(\.memberID))
    self.id=id;self.source=source
    membersByID=Dictionary(uniqueKeysWithValues:source.members.map{($0.id,$0)})
    self.model=model;canvas=raw;self.restoration=restoration
    #if os(iOS)
    requiredAuthoredHostIDs=model.selectedGraphicHosts.requiredHostIDs(source)
    requiredTextHostIDs=model.selectedGraphicHosts.requiredTextHostIDs(source,model:model)
    model.selectedGraphicHosts.bind(self)
    #endif
    raw?.retainSelectionLifetime(self)
  }

  #if os(iOS)
  func graphicHostDidInstall() { prepareIfPossible() }
  #endif

  private func prepareIfPossible() {
    guard !disposed,!retiring,!preparationFailed,preparation == nil,let cut=desired else {return}
    #if os(iOS)
    guard let hosts=model?.selectedGraphicHosts.hosts(source,requiredIDs:requiredAuthoredHostIDs,ownerID:id),
      let textHosts=model?.selectedGraphicHosts.textHosts(source,requiredIDs:requiredTextHostIDs) else {return}
    let hostGenerations=hosts.mapValues(\.generation)
    let displayGenerations=hosts.mapValues(\.displayGeneration)
    #endif
    let generation=generation,values=cut.working,edits=cut.edits
    if installed,presented?.working == values,presented?.edits == edits {
      #if os(iOS)
      guard presentedFrame != cut.frame || installedHostGenerations != hostGenerations
        || installedDisplayGenerations != displayGenerations else {return}
      guard let poses=authoredPoses(edits,hosts:hosts) else {return}
      CATransaction.begin();CATransaction.setDisableActions(true)
      for (host,pose) in poses {if let pose {host.install(pose)} else {host.hide()}}
      if deleting {for host in textHosts {host.hide()}}
      presented=cut;installedHostGenerations=hostGenerations
      installedDisplayGenerations=displayGenerations
      if let model {model.selectedGraphicHosts.installControls(model:model,selectionID:source.selectionID)}
      CATransaction.commit()
      #endif
      return
    }
    guard let canvas else {
      #if os(iOS)
      guard let poses=authoredPoses(edits,hosts:hosts),model?.selectionEditSourceIsCurrent(source) == true || claimed else {return}
      CATransaction.begin();CATransaction.setDisableActions(true)
      for (host,pose) in poses {if let pose {host.install(pose)} else {host.hide()}}
      if deleting {for host in textHosts {host.hide()}}
      presented=cut
      installedHostGenerations=hostGenerations;installedDisplayGenerations=displayGenerations
      if deleting {model?.publishSelectionDrafts(source:source,edits:edits,deleting:true)}
      model?.selectedInkPresentationInstalled(self)
      if let model {model.selectedGraphicHosts.installControls(model:model,selectionID:source.selectionID)}
      CATransaction.commit()
      #endif
      return
    }
    preparation=Task { [weak self] in
      guard let self else {return}
      do {
        try Task.checkCancellation()
        let ids=Set(source.ink.map(\.actionID)).union(originals.values.map(\.sourceID))
        var bodies:[NotebookOrderedInkPlan.Body]=[]
        for value in values {
          guard let layout=NotebookGraphicGraph([value.node]).resolve(value.id).layout else {throw CancellationError()}
          let key:NotebookInkPaintKey,erasures:[InkElementErasure]
          if let original=originals[value.id] {
            key=original.key;erasures=original.erasures
          } else {
            guard let raw=source.ink.first(where:{$0.memberID == value.id}) else {throw CancellationError()}
            if isSpatial {
              guard let actor=UUID(uuidString:raw.painterOrder.actor) else {throw CancellationError()}
              key = .spatial(stamp:.init(counter:raw.painterOrder.counter,actor:actor),id:raw.actionID)
            } else {key = .page(sequence:raw.painterOrder.counter,id:raw.actionID)}
            erasures=[]
          }
          bodies.append(.init(elementID:value.id,key:key,graphic:value.graphic,layout:layout,erasures:erasures))
        }
        let plan=NotebookOrderedInkPlan(bodies:bodies,suppressedInkIDs:ids)
        let geometry=try await canvas.prepareOrderedPlan(plan)
        try Task.checkCancellation()
        guard self.generation == generation,!disposed,!retiring,
          claimed || model?.selectionEditSourceIsCurrent(source) == true else {throw CancellationError()}
        #if os(iOS)
        guard let hosts=model?.selectedGraphicHosts.hosts(source,requiredIDs:requiredAuthoredHostIDs,ownerID:id),
          hosts.mapValues(\.generation) == hostGenerations else {
          preparation=nil;prepareIfPossible();return
        }
        guard let currentTextHosts=model?.selectedGraphicHosts.textHosts(source,requiredIDs:requiredTextHostIDs),
          Set(currentTextHosts.map(ObjectIdentifier.init)) == Set(textHosts.map(ObjectIdentifier.init)) else {
          preparation=nil;prepareIfPossible();return
        }
        var nativeCut:NativeCut?
        #endif
        try await canvas.presentOrderedPlan(geometry,plan:plan,replacing:ids,validate:{ [weak self] in
          guard let self,self.generation == generation,!disposed,!retiring,
            claimed || model?.selectionEditSourceIsCurrent(source) == true else {return false}
          #if os(iOS)
          nativeCut=prepareNativeCut(edits,hostGenerations:hostGenerations,textHosts:textHosts)
          guard nativeCut != nil else {return false}
          #endif
          return true
        }) { [weak self] in
          guard let self else {return}
          presented=cut
          #if os(iOS)
          // validate and install run synchronously in the canvas transaction.
          // These poses therefore use the host geometry of this exact cut,
          // rather than geometry captured before waiting for a drawable slot.
          guard let nativeCut else {preconditionFailure("Installing an unvalidated selection cut")}
          installedHostGenerations=nativeCut.hostGenerations
          installedDisplayGenerations=nativeCut.displayGenerations
          #endif
          restoration?.installed()
          if deleting {model?.publishSelectionDrafts(source:source,edits:edits,deleting:true)}
          model?.selectedInkPresentationInstalled(self)
          #if os(iOS)
          for (host,pose) in nativeCut.poses {if let pose {host.install(pose)} else {host.hide()}}
          if deleting {for host in nativeCut.textHosts {host.hide()}}
          if let model {model.selectedGraphicHosts.installControls(model:model,selectionID:source.selectionID)}
          #endif
        }
        preparation=nil
        if accepted && presented == desired {releasePhysicalLease()}
        if desired != cut {prepareIfPossible()}
      } catch {
        guard self.generation == generation else {return}
        preparation=nil;fail(error)
      }
    }
  }

  #if os(iOS)
  private struct NativeCut {
    let poses:[(NotebookSelectedGraphicHostController,CGAffineTransform?)]
    let textHosts:[NotebookSelectedTextHostController]
    let hostGenerations:[String:UUID]
    let displayGenerations:[String:UUID]
  }
  private func prepareNativeCut(_ edits:[NotebookGraphicSelection.Edit],hostGenerations:[String:UUID],
    textHosts:[NotebookSelectedTextHostController])->NativeCut? {
    guard let hosts=model?.selectedGraphicHosts.hosts(source,requiredIDs:requiredAuthoredHostIDs,ownerID:id),
      hosts.mapValues(\.generation) == hostGenerations,
      let currentText=model?.selectedGraphicHosts.textHosts(source,requiredIDs:requiredTextHostIDs),
      Set(currentText.map(ObjectIdentifier.init)) == Set(textHosts.map(ObjectIdentifier.init)),
      let poses=authoredPoses(edits,hosts:hosts) else {return nil}
    return .init(poses:poses,textHosts:currentText,hostGenerations:hostGenerations,
      displayGenerations:hosts.mapValues(\.displayGeneration))
  }

  private func authoredPoses(_ edits:[NotebookGraphicSelection.Edit],
    hosts:[String:NotebookSelectedGraphicHostController]) -> [(NotebookSelectedGraphicHostController,CGAffineTransform?)]? {
    let byID=Dictionary(uniqueKeysWithValues:edits.map { ($0.id,$0) })
    let members=Dictionary(uniqueKeysWithValues:source.members.map { ($0.id,$0) })
    var result:[(NotebookSelectedGraphicHostController,CGAffineTransform?)]=[]
    for (id,host) in hosts {
      guard let member=members[id] else {return nil}
      if let edit=byID[id] {
        guard let pose=host.pose(edit,from:member) else {return nil}
        result.append((host,pose))
      } else {result.append((host,nil))}
    }
    return result
  }
  #endif

  /// Enqueueing owns the material independently of the selection or view.
  func claim() {
    claimed=true
    #if os(iOS)
    if canvas == nil || deleting {
      model?.selectedGraphicHosts.retainClaim(self)
    }
    #endif
  }
  func didAcceptSource(cursor:UInt64? = nil,sources:[EditableElementReference:NotebookNativeElementSource] = [:]) {
    accepted=true
    acceptedCursor=cursor ?? acceptedCursor
    if !sources.isEmpty {acceptedSources=sources}
    // The atomic writer receipt ends rollback authority. Keep only the current
    // native picture/controls, not the captured pre-command body geometry.
    restoration=nil
    if installed || preparationFailed { releasePhysicalLease() }
    if !installed {
      // Durable acceptance is terminal for rollback. The latest canonical
      // source may publish before a private host or drawable ever installs.
      generation=UUID();preparation?.cancel();preparation=nil
      preparationFailed=true
      releasePhysicalLease()
      model?.selectedInkPresentationNeedsCanonical(self)
    }
    if let canvas,canvas.window == nil {selectionCanvasUnmounted(canvas)}
    if let model {
      canonicalAuthoredSourceLoaded()
      if acceptedSourcesAreLoaded,
        let canvas,source.address.surface.kind == .page,let pageID=source.address.surface.ownerID,
        let page=model.pages[pageID],canvas.presentsCanonicalPageSource(page.inkSource) {
        canonicalInstalled(canvas.orderedInkPlan,on:canvas,surface:source.address.surface)
      }
    }
    authoredHostUnmounted()
  }
  func selectionCanvasUnmounted(_ departing:InkCanvasView) {
    guard canvas === departing else {return}
    departing.releaseSelectionLifetime(id)
    guard accepted else {return}
    canvas=nil
    generation=UUID();preparation?.cancel();preparation=nil
    releasePhysicalLease()
    canonicalAuthoredSourceLoaded()
    authoredHostUnmounted()
  }
  func authoredHostUnmounted(_ memberID:String? = nil) {
    #if os(iOS)
    // A required physical host disappearing ends the unaccepted cut. Its
    // subsequent replacement must not install a command whose waiter failed.
    let requiredHostLost=memberID.map {
      requiredAuthoredHostIDs.contains($0) || requiredTextHostIDs.contains($0)
    } ?? false
    if !disposed,!accepted,requiredHostLost {
      fail(CancellationError())
      return
    }
    guard accepted,canvas == nil,!disposed,let model,
      acceptedSourcesAreLoaded,
      model.selectedGraphicHosts.mountedHosts(source,ownerID:id).isEmpty,
      requiredTextHostIDs.isEmpty else {return}
    finishRetirement()
    #endif
    if canonicalAuthoredCutReady {canonicalHostStaged()}
  }
  func canonicalAuthoredSourceLoaded() {
    guard accepted,canvas == nil,!disposed,!canonicalAuthoredCutReady,
      acceptedSourcesAreLoaded else {return}
    #if os(iOS)
    guard let model else {return}
    if deleting {
      CATransaction.begin();CATransaction.setDisableActions(true)
      for host in model.selectedGraphicHosts.mountedHosts(source,ownerID:id).values {host.hide()}
      for host in model.selectedGraphicHosts.textHosts(source,requiredIDs:requiredTextHostIDs) ?? [] {host.hide()}
      finishRetirement();CATransaction.commit();return
    }
    if model.selectedGraphicHosts.mountedHosts(source,ownerID:id).isEmpty,requiredTextHostIDs.isEmpty {finishRetirement();return}
    canonicalAuthoredCutReady=true
    // A later queued edit or peer action may already have superseded this
    // command. The scene's current source, not this command's desired pose,
    // is the canonical handoff target. The hosts retain the old complete
    // picture until that source has been staged together.
    model.didChangeWorkingGraphics(on:[source.address.surface])
    canonicalHostStaged()
    #else
    finishRetirement()
    #endif
  }
  func canonicalHostStaged() {
    guard canonicalAuthoredCutReady,!disposed,!canonicalCommitScheduled else {return}
    canonicalCommitScheduled=true
    // One turn admits every host's source view; only then can a single native
    // transaction replace their visible bodies and controls together.
    Task { @MainActor [weak self] in
      self?.canonicalCommitScheduled=false
      self?.commitCanonicalHostsIfReady()
    }
  }
  private func commitCanonicalHostsIfReady() {
    guard canonicalAuthoredCutReady,!disposed,let model else {return}
    #if os(iOS)
    let hosts=model.selectedGraphicHosts.mountedHosts(source,ownerID:id)
    guard !hosts.isEmpty else {finishRetirement();return}
    for (id,host) in hosts {
      let ref=source.address.reference(id)
      guard let graphic=model.graphicElement(ref),let layout=model.graphicLayout(ref),
        host.hasCanonical(graphic:graphic,layout:layout) else {return}
    }
    CATransaction.begin();CATransaction.setDisableActions(true)
    for host in hosts.values {host.installCanonical()}
    finishRetirement()
    CATransaction.commit()
    #endif
  }
  func canonicalInstalled(_ plan:NotebookOrderedInkPlan,on current:InkCanvasView,surface:SurfaceID) {
    guard (needsCanonicalSource || awaitsAcceptedDeleteCut),surface == source.address.surface,current.window != nil,
      acceptedSourcesAreLoaded,current.isStableFramePresented,current.orderedInkPlan == plan else {return}
    current.acknowledgeAcceptedOrderedFrame(plan)
    // The addressed canonical source and this native receipt cover the same
    // immutable output. A newly mounted physical owner can perform the handoff.
    finishRetirement()
  }
  func commandFailed() { claimed=false;cancel() }
  func cancel() {
    guard !claimed,!disposed,!retiring else { return }
    generation=UUID();preparation?.cancel();preparation=nil
    if !installed { finishRetirement();return }
    retiring=true
    guard let restoration else {
      #if os(iOS)
      let original=NotebookGraphicSelection.translated(source.members,by:.zero)
      if let hosts=model?.selectedGraphicHosts.hosts(source,requiredIDs:requiredAuthoredHostIDs,ownerID:id),
        let poses=authoredPoses(original,hosts:hosts) {
        CATransaction.begin();CATransaction.setDisableActions(true)
        for (host,pose) in poses {if let pose {host.install(pose)} else {host.hide()}}
        presented=originalCut
        if let model {model.selectedGraphicHosts.installControls(model:model,selectionID:source.selectionID)}
        CATransaction.commit()
      }
      #endif
      finishRetirement();return
    }
    restoration.restore(install:{ [weak self] in
      guard let self else {return}
      #if os(iOS)
      if let textHosts=model?.selectedGraphicHosts.textHosts(source,requiredIDs:requiredTextHostIDs) {
        for host in textHosts {host.show()}
      }
      let original=NotebookGraphicSelection.translated(source.members,by:.zero)
      if let hosts=model?.selectedGraphicHosts.hosts(source,requiredIDs:requiredAuthoredHostIDs,ownerID:id),
        let poses=authoredPoses(original,hosts:hosts) {
        for (host,pose) in poses {if let pose {host.install(pose)} else {host.hide()}}
      }
      presented=originalCut
      if let model {model.selectedGraphicHosts.installControls(model:model,selectionID:source.selectionID)}
      #endif
      finishRetirement()
    },abandon:{ [weak self] in self?.finishRetirement() })
  }
  private func fail(_ error:Error) {
    guard !disposed,!preparationFailed else { return }
    preparationFailed=true
    generation=UUID();preparation?.cancel();preparation=nil
    if claimed {
      // Enqueued is not installed. Keep the last complete picture/controls
      // through the writer outcome, then let the existing canonical source
      // prepare and retire this owner only on its exact native receipt.
      if accepted {releasePhysicalLease()}
      model?.selectedInkPresentationNeedsCanonical(self)
    } else {
      model?.cancelElementManipulation(id)
      if !disposed && !retiring { cancel() }
    }
    if !accepted,!(error is CancellationError) {model?.showCue("Не удалось подготовить всё выделение. Повторите действие.")}
  }
  private func finishRetirement() {
    guard !disposed else { return }
    disposed=true
    canvas?.releaseSelectionLifetime(id)
    #if os(iOS)
    model?.selectedGraphicHosts.unbind(self)
    #endif
    releasePhysicalLease()
    model?.retireSelectedInkPresentation(self)
    if canonicalAuthoredCutReady {model?.didChangeWorkingGraphics(on:[source.address.surface])}
  }
  private func releasePhysicalLease() {
    #if os(iOS)
    physicalLease?.release();physicalLease=nil
    #endif
  }
  isolated deinit {
    preparation?.cancel()
    canvas?.releaseSelectionLifetime(id)
    #if os(iOS)
    model?.selectedGraphicHosts.unbind(self)
    #endif
    releasePhysicalLease()
  }
}
