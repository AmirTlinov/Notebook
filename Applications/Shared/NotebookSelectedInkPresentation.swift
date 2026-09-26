import Foundation
import NotebookCore
import Observation
import QuartzCore

/// The current contact and its accepted working members share this one native
/// exchange. It retains no screenshot and owns no render clock. Source and
/// material drawables are private until the existing canvas install transaction.
@MainActor @Observable final class NotebookSelectedInkPresentation: Equatable {
  nonisolated static func ==(lhs:NotebookSelectedInkPresentation,rhs:NotebookSelectedInkPresentation)->Bool { lhs === rhs }
  let id:UUID
  let source:NotebookSelectionEditSource
  @ObservationIgnored private weak var model:NotebookAppModel?
  @ObservationIgnored private weak var canvas:InkCanvasView?
  private var restoration:InkCanvasView.SourceRestoration?
  private let isSpatial:Bool
  private let originalWorking:[NotebookWorkingGraphic]
  private let originals:[String:NotebookOrderedInkPlan.Body]
  #if os(iOS)
  @ObservationIgnored private var physicalLease:SpatialInkSurfaceRegistry.ContactLease?
  #endif
  @ObservationIgnored private var preparation:Task<Void,Never>?
  @ObservationIgnored private var generation=UUID()
  @ObservationIgnored private var claimed=false
  @ObservationIgnored private var accepted=false
  @ObservationIgnored private var preparationFailed=false
  @ObservationIgnored private var desired:[NotebookWorkingGraphic]=[]
  @ObservationIgnored private var desiredEdits:[NotebookGraphicSelection.Edit]=[]
  private(set) var presentedEdits:[NotebookGraphicSelection.Edit]?
  private(set) var presentedFrame:CGRect?
  @ObservationIgnored private var desiredFrame:CGRect?
  private var shown:[NotebookWorkingGraphic]?
  var working:[NotebookWorkingGraphic] {
    (shown ?? originalWorking).map {value in var value=value;value.inkPresentation=self;return value}
  }
  private(set) var installed=false
  private(set) var retiring=false
  @ObservationIgnored private var disposed=false
  var retainsOriginal:Bool {!installed && !disposed}
  func retainsRawSource(_ id:String)->Bool {
    (retainsOriginal || retiring) && source.ink.contains(where:{$0.memberID == id})
  }
  var retiringBodies:[NotebookOrderedInkPlan.Body] {
    retiring && !disposed ? originals.values.sorted{$0.key < $1.key} : []
  }
  /// A failed private stage may yield source preparation to the accepted
  /// canonical owner, but controls still describe the last installed picture.
  var needsCanonicalSource:Bool {!disposed && preparationFailed && accepted}
  var holdsPresentation:Bool {!disposed && (shown != desired || needsCanonicalSource)}
  func update(_ values:[NotebookWorkingGraphic],edits:[NotebookGraphicSelection.Edit],frame:CGRect) {
    guard !disposed,!retiring else {return}
    desired=values;desiredEdits=edits;desiredFrame=frame
    // Selection is read-only until the actual desired pose differs. The raw
    // stream keeps its exact original alpha grouping until that first edit.
    guard values != originalWorking || installed else {return}
    prepareIfPossible()
  }

  init?(id:UUID,source:NotebookSelectionEditSource,model:NotebookAppModel) {
    let raw:InkCanvasView?
    if source.address.surface.kind == .page,let pageID=source.address.surface.ownerID {
      raw=model.pageInkPublication.currentCanvas(on:pageID)
      isSpatial=false
    } else {
      let registry=model.compositionTiles.surfaceRegistry
      raw=registry.canvas(for:source.address.surface)
      guard let installed=raw?.installedSpatialSource,
        source.expectedInkRevision.map({installed.journalRevision == $0}) ?? true else { return nil }
      isSpatial=true
      #if os(iOS)
      if let raw { physicalLease=registry.acquireContact(on:source.address.surface,in:raw) }
      #endif
    }
    guard let raw else {return nil}
    let selectedIDs=Set(source.members.map(\.id))
    guard !model.workingGraphics.contains(where: {selectedIDs.contains($0.id)
      && $0.surface == source.address.surface && $0.inkPresentation?.holdsPresentation == true}) else {return nil}
    var originals:[String:NotebookOrderedInkPlan.Body]=[:]
    for member in source.orderedMembers {
      guard let body=raw.orderedInkPlan.bodies.first(where:{$0.elementID == member.id}),
        body.graphic == member.graphic,body.layout == member.layout else {return nil}
      originals[member.id]=body
    }
    let sourceIDs=Set(source.ink.map(\.actionID)).union(originals.values.map(\.sourceID))
    guard !sourceIDs.isEmpty,let restoration=raw.captureSourceRestoration(for:sourceIDs) else {return nil}
    self.originals=originals;originalWorking=source.initialPresentationWorking
    self.id=id;self.source=source;self.model=model;canvas=raw;self.restoration=restoration
  }

  private func prepareIfPossible() {
    guard !disposed,!retiring,preparation == nil,let canvas,let desiredFrame else {return}
    let generation=generation,values=desired,edits=desiredEdits
    preparation=Task { [weak self] in
      guard let self else {return}
      var frame:InkCanvasView.PreparedFrame?
      do {
        try Task.checkCancellation()
        let ids=Set(source.ink.map(\.actionID)).union(originals.values.map(\.sourceID))
        var bodies=canvas.orderedInkPlan.bodies.filter{!ids.contains($0.sourceID)}
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
        let plan=NotebookOrderedInkPlan(bodies:bodies,suppressedInkIDs:canvas.orderedInkPlan.suppressedInkIDs.union(ids))
        frame=try await canvas.prepareFrame(.ordered(plan))
        try Task.checkCancellation()
        guard self.generation == generation,!disposed,!retiring,let frame,frame.isValid,
          claimed || model?.selectionEditSourceIsCurrent(source) == true else {throw CancellationError()}
        CATransaction.begin();CATransaction.setDisableActions(true)
        canvas.installPreparedFrame(frame)
        shown=values;presentedEdits=edits;presentedFrame=desiredFrame
        restoration?.installed();installed=true
        model?.selectedInkPresentationInstalled(self)
        CATransaction.commit()
        preparation=nil
        if accepted && shown == desired {releasePhysicalLease()}
        if desired != values {prepareIfPossible()}
      } catch {
        frame?.cancel()
        guard self.generation == generation else {return}
        preparation=nil;fail()
      }
    }
  }

  /// Enqueueing owns the material independently of the selection or view.
  func claim() { claimed=true }
  func didAcceptSource() {
    accepted=true
    // The atomic writer receipt ends rollback authority. Keep only the current
    // native picture/controls, not the captured pre-command body geometry.
    restoration=nil
    if installed || preparationFailed { releasePhysicalLease() }
  }
  func canonicalInstalled(_ plan:NotebookOrderedInkPlan,on current:InkCanvasView,surface:SurfaceID) {
    guard needsCanonicalSource,surface == source.address.surface,current.window != nil,
      current.isStableFramePresented,current.orderedInkPlan == plan else {return}
    // The caller also checked its accepted publication cursor and immutable
    // source. A newer physical owner may legitimately replace the original one.
    finishRetirement()
  }
  func commandFailed() { claimed=false;cancel() }
  func cancel() {
    guard !claimed,!disposed,!retiring,let restoration else { return }
    generation=UUID();preparation?.cancel();preparation=nil
    if !installed { finishRetirement();return }
    retiring=true
    restoration.restore(install:{ [weak self] in self?.finishRetirement() },abandon:{ [weak self] in self?.finishRetirement() })
  }
  private func fail() {
    guard !disposed else { return }
    generation=UUID();preparation?.cancel();preparation=nil
    if claimed {
      // Enqueued is not installed. Keep the last complete picture/controls
      // through the writer outcome, then let the existing canonical source
      // prepare and retire this owner only on its exact native receipt.
      preparationFailed=true
      if accepted {releasePhysicalLease()}
      model?.selectedInkPresentationNeedsCanonical(self)
    } else {
      model?.cancelElementManipulation(id)
      if !disposed && !retiring { cancel() }
    }
    model?.showCue("Не удалось подготовить всё выделение. Повторите действие.")
  }
  private func finishRetirement() {
    guard !disposed else { return }
    disposed=true
    releasePhysicalLease()
    model?.retireSelectedInkPresentation(self)
  }
  private func releasePhysicalLease() {
    #if os(iOS)
    physicalLease?.release();physicalLease=nil
    #endif
  }
  isolated deinit { preparation?.cancel();releasePhysicalLease() }
}
