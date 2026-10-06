import Foundation
import NotebookCore
import Observation
import SwiftUI
#if os(iOS)
import UIKit

/// Only the selected authored graphics have native hosts. The ordinary batch
/// remains a single Canvas for every other object. A host keeps its original
/// body while the contact owner moves its layer together with the raw plane.
@MainActor @Observable final class NotebookSelectedGraphicHosts {
  private struct Entry {
    weak var view: NotebookSelectedGraphicHostController?
    let selectionID: UUID
  }
  @ObservationIgnored private var entries: [EditableElementReference: Entry] = [:]
  private var hostedSourceRevision:UInt64=0
  private struct TextEntry {
    weak var view:NotebookSelectedTextHostController?
    let selectionID:UUID
  }
  @ObservationIgnored private var textEntries:[EditableElementReference:TextEntry]=[:]
  private var selectedReferences:[EditableElementReference:UUID]=[:]
  private var selectedByBoard:[UUID:[String:UUID]]=[:]
  private final class Claim {
    let id:UUID
    weak var value:NotebookSelectionPresentation?
    var accepted:NotebookSelectionPresentation?
    var owner:NotebookSelectionPresentation? {accepted ?? value}
    init(_ value:NotebookSelectionPresentation){id=value.id;self.value=value}
  }
  @ObservationIgnored private var claims:[UUID:Claim]=[:]
  @ObservationIgnored private var claimsByReference:[EditableElementReference:UUID]=[:]
  private struct PageCoverage {
    let owner:UUID
    let visible:Set<String>
  }
  @ObservationIgnored private var pageCoverage:[UUID:PageCoverage]=[:]
  @ObservationIgnored private weak var controls: NotebookSelectionControlsView?
  @ObservationIgnored private var controlsSelectionID: UUID?

  func select(_ session:NotebookSelectionSession) {
    let id=session.id
    selectedReferences=Dictionary(uniqueKeysWithValues:(session.count > 1 ? session.elements : []).map{($0,id)})
    rebuildBoardIndex()
  }
  private func rebuildBoardIndex() {
    var byBoard:[UUID:[String:UUID]]=[:]
    for (reference,id) in selectedReferences {
      if case .spatial(let board,let element)=reference {byBoard[board,default:[:]][element]=id}
    }
    for (reference,id) in claimsByReference where claims[id]?.owner?.ownsAuthoredHosts == true {
      if case .spatial(let board,let element)=reference {byBoard[board,default:[:]][element]=id}
    }
    selectedByBoard=byBoard
  }
  func selectionID(for reference:EditableElementReference)->UUID? {
    heldSelectionID(reference) ?? selectedReferences[reference]
  }
  func selectedIDs(boardID:UUID)->[String:UUID] { selectedByBoard[boardID] ?? [:] }

  func publishPageCoverage(_ pageID:UUID,owner:UUID,visible:Set<String>) {
    pageCoverage[pageID] = .init(owner:owner,visible:visible)
  }
  func removePageCoverage(_ pageID:UUID,owner:UUID) {
    if pageCoverage[pageID]?.owner == owner {pageCoverage[pageID]=nil}
  }
  func requiredHostIDs(_ source:NotebookSelectionEditSource)->Set<String> {
    let authored=Set(source.references.map(\.elementID))
    let ordered=Set(source.orderedMembers.map(\.id))
    let candidates=Set(source.members.map(\.id)).intersection(authored).subtracting(ordered)
    guard source.address.surface.kind == .page,
      let pageID=source.address.surface.ownerID,let coverage=pageCoverage[pageID] else {return candidates}
    return candidates.intersection(coverage.visible)
  }
  func requiredTextHostIDs(_ source:NotebookSelectionEditSource,model:NotebookAppModel)->Set<String> {
    let text=Set(source.references.compactMap { reference -> String? in
      let current=model.nativeElementSource(reference)
      guard current?.page?.kind == .nativeText || current?.spatial?.kind == .nativeText else {return nil}
      return reference.elementID
    })
    if source.address.surface.kind == .page,
      let pageID=source.address.surface.ownerID,let coverage=pageCoverage[pageID] {
      return text.intersection(coverage.visible)
    }
    if source.address.surface.kind != .page,let cohort=model.compositionTiles.published,
      let boardID=source.address.boardID {
      let plane:SceneCompositionPlane
      if source.address.surface.kind == .cover,let itemID=source.address.surface.ownerID {
        plane = .cover(boardID:boardID,itemID:itemID)
      } else {plane = .board(boardID)}
      return Set(text.filter {cohort.plan.allowsLive(.element($0),in:plane)})
    }
    return text
  }
  func textHosts(_ source:NotebookSelectionEditSource,requiredIDs:Set<String>)->[NotebookSelectedTextHostController]? {
    var result:[NotebookSelectedTextHostController]=[]
    for id in requiredIDs {
      let reference=source.address.reference(id)
      guard let entry=textEntries[reference],entry.selectionID == source.selectionID,
        let view=entry.view,view.viewIfLoaded?.window != nil else {return nil}
      result.append(view)
    }
    return result
  }
  func registerText(_ view:NotebookSelectedTextHostController,reference:EditableElementReference,selectionID:UUID) {
    textEntries[reference] = .init(view:view,selectionID:selectionID)
    claims[selectionID]?.owner?.graphicHostDidInstall()
  }
  func unregisterText(_ view:NotebookSelectedTextHostController,reference:EditableElementReference) {
    if textEntries[reference]?.view === view {
      let owner=textEntries[reference].flatMap {claims[$0.selectionID]?.owner}
      textEntries[reference]=nil
      owner?.authoredHostUnmounted(reference.elementID)
    }
  }

  func bind(_ owner: NotebookSelectionPresentation) {
    claims[owner.source.selectionID]=Claim(owner)
    for reference in owner.source.references {claimsByReference[reference]=owner.source.selectionID}
    hostedSourceRevision &+= 1
    rebuildBoardIndex()
  }
  func retainClaim(_ owner:NotebookSelectionPresentation) {
    if claims[owner.source.selectionID]?.owner === owner {claims[owner.source.selectionID]?.accepted=owner}
  }
  func unbind(_ owner: NotebookSelectionPresentation) {
    if claims[owner.source.selectionID]?.id == owner.id {
      claims[owner.source.selectionID]=nil
      for reference in owner.source.references where claimsByReference[reference] == owner.source.selectionID {
        claimsByReference[reference]=nil
      }
      hostedSourceRevision &+= 1
      rebuildBoardIndex()
    }
  }
  func heldSelectionID(_ reference:EditableElementReference)->UUID? {
    _ = hostedSourceRevision
    guard let selectionID=claimsByReference[reference],claims[selectionID]?.owner?.ownsAuthoredHosts == true else {return nil}
    return selectionID
  }
  func heldOwnerID(_ reference:EditableElementReference)->UUID? {
    guard let selectionID=heldSelectionID(reference) else {return nil}
    return claims[selectionID]?.owner?.id
  }
  func heldMember(_ reference: EditableElementReference) -> NotebookGraphicSelection.Member? {
    _ = hostedSourceRevision
    guard let selectionID=heldSelectionID(reference),
      let owner=claims[selectionID]?.owner,owner.ownsAuthoredHosts else { return nil }
    return owner.membersByID[reference.elementID]
  }
  func canonicalHostStaged(_ reference:EditableElementReference,selectionID:UUID) {
    guard let owner=claims[selectionID]?.owner,owner.canonicalAuthoredCutReady else {return}
    owner.canonicalHostStaged()
  }
  func canonicalCutReady(selectionID:UUID)->Bool {
    claims[selectionID]?.owner?.canonicalAuthoredCutReady == true
  }
  func mountedHosts(_ source:NotebookSelectionEditSource,ownerID:UUID)->[String:NotebookSelectedGraphicHostController] {
    let authored=Set(source.references.map(\.elementID))
    let ordered=Set(source.orderedMembers.map(\.id))
    var result:[String:NotebookSelectedGraphicHostController]=[:]
    for member in source.members where authored.contains(member.id) && !ordered.contains(member.id) {
      let ref=source.address.reference(member.id)
      if let entry=entries[ref],entry.selectionID == source.selectionID,
        let host=entry.view,host.sourceOwnerID == ownerID,
        host.viewIfLoaded?.window != nil,host.matches(member) {result[member.id]=host}
    }
    return result
  }
  func admitAcceptedAuthoredSources() {
    // The model has installed the accepted SQLite cut before SwiftUI is
    // invalidated. Its ordinary graph may now replace the temporary pose.
    for owner in Array(claims.values.compactMap(\.owner)) {owner.canonicalAuthoredSourceLoaded()}
  }
  func acceptedDeletingOwners(on surface:SurfaceID,through cursor:UInt64)->[NotebookSelectionPresentation] {
    claims.values.compactMap(\.owner).filter {
      $0.source.address.surface == surface && $0.acceptsCanonicalCut(cursor)
    }
  }
  func hosts(_ source: NotebookSelectionEditSource,requiredIDs:Set<String>? = nil,
    ownerID:UUID? = nil) -> [String: NotebookSelectedGraphicHostController]? {
    let required=requiredIDs ?? requiredHostIDs(source)
    let expectedOwner=ownerID ?? claims[source.selectionID]?.owner?.id
    var result: [String: NotebookSelectedGraphicHostController] = [:]
    for member in source.members where required.contains(member.id) {
      let reference=source.address.reference(member.id)
      guard let entry = entries[reference],entry.selectionID == source.selectionID,
        let view = entry.view,view.viewIfLoaded?.window != nil,
        view.matches(member),expectedOwner.map({view.sourceOwnerID == $0}) ?? true else { return nil }
      result[reference.elementID] = view
    }
    return result
  }
  func register(_ view: NotebookSelectedGraphicHostController, reference: EditableElementReference, selectionID: UUID) {
    entries[reference] = .init(view:view,selectionID:selectionID)
    claims[selectionID]?.owner?.graphicHostDidInstall()
  }
  func unregister(_ view: NotebookSelectedGraphicHostController, reference: EditableElementReference) {
    if entries[reference]?.view === view {
      let owner=entries[reference].flatMap { claims[$0.selectionID]?.owner }
      entries[reference] = nil
      owner?.authoredHostUnmounted(reference.elementID)
    }
  }
  func registerControls(_ view:NotebookSelectionControlsView,selectionID:UUID) {
    controls=view;controlsSelectionID=selectionID
  }
  func unregisterControls(_ view:NotebookSelectionControlsView) {
    if controls === view { controls=nil;controlsSelectionID=nil }
  }
  func installControls(model:NotebookAppModel,selectionID:UUID) {
    guard controlsSelectionID == selectionID,let controls,controls.window != nil,let presence=model.presence,
      let frames=NotebookAttentionProjection.selectionFrames(model:model,presence:presence),
      frames.count == model.selectionSession.count else { return }
    let rect=frames.reduce(CGRect.null) { $0.union($1) }
    controls.configure(selectionID:selectionID,frame:rect,scale:presence.camera.scale,
      manipulating:true,subject:.elements(frames.count),transformsSelection:model.canTransformSelection,
      memberFrames:frames,camera:presence,cameraProjection:model.nativeCameraProjection)
    controls.layoutIfNeeded()
  }
}

@MainActor final class NotebookSelectedGraphicHostController: UIViewController {
  private let host = UIHostingController(rootView:AnyView(EmptyView()))
  private weak var registry:NotebookSelectedGraphicHosts?
  private var reference:EditableElementReference?
  private var selectionID:UUID?
  private(set) var sourceOwnerID:UUID?
  private var contentInstalled=false
  private var contentSize=CGSize.zero
  private var displaySize=CGSize.zero
  private var sourceGraphic:NotebookGraphic?
  private var sourceLayout:NotebookGraphicLayout?
  private struct Canonical {
    let content:AnyView
    let graphic:NotebookGraphic
    let layout:NotebookGraphicLayout
    let size:CGSize
    let offset:CGPoint
  }
  private var canonical:Canonical?
  private var awaitingWrapperRebase=false
  private(set) var generation=UUID()
  private(set) var displayGeneration=UUID()
  func matches(_ member:NotebookGraphicSelection.Member)->Bool {
    sourceGraphic == member.graphic && sourceLayout == member.layout
  }
  override func loadView() {
    view=UIView();view.backgroundColor = .clear;view.isOpaque=false;view.clipsToBounds=false
    host.view.backgroundColor = .clear;host.view.isOpaque=false;host.view.clipsToBounds=false
    host.safeAreaRegions=[]
    addChild(host);view.addSubview(host.view);host.didMove(toParent:self)
  }
  override func viewDidAppear(_ animated:Bool) {
    super.viewDidAppear(animated)
    if let registry,let reference,let selectionID,view.window != nil {
      registry.register(self,reference:reference,selectionID:selectionID)
    }
  }
  func update(registry:NotebookSelectedGraphicHosts,reference:EditableElementReference,
    selectionID:UUID,size:CGSize,graphic:NotebookGraphic,layout:NotebookGraphicLayout,content:AnyView,
    targetGraphic:NotebookGraphic,targetLayout:NotebookGraphicLayout,targetSize:CGSize,
    targetOffset:CGPoint,targetContent:AnyView) {
    loadViewIfNeeded()
    let nextOwnerID=registry.heldOwnerID(reference)
    if self.reference != reference || self.selectionID != selectionID {
      if let previous=self.reference {self.registry?.unregister(self,reference:previous)}
      self.reference=reference;self.selectionID=selectionID;contentInstalled=false;generation=UUID();canonical=nil
    }
    if let nextOwnerID,sourceOwnerID != nextOwnerID {
      // This is a new contact/source owner, not a publication of the current
      // one. Its wrapper already names its admitted source pose; rebase the
      // retained native body there before applying the next desired pose.
      sourceOwnerID=nextOwnerID;contentInstalled=false;generation=UUID()
      canonical=nil;awaitingWrapperRebase=false
    }
    self.registry=registry
    if displaySize != size { displaySize=size;displayGeneration=UUID() }
    if !contentInstalled || registry.heldMember(reference) == nil {
      if awaitingWrapperRebase {
        // The canonical body is already correctly offset inside the frozen
        // wrapper. Only reset its offset after SwiftUI supplied the matching
        // canonical wrapper in this very update, never on an old pass.
        guard sourceGraphic == graphic,sourceLayout == layout,contentSize == size,
          targetOffset == .zero else {
          registry.register(self,reference:reference,selectionID:selectionID)
          return
        }
        awaitingWrapperRebase=false
      }
      if sourceGraphic != graphic || sourceLayout != layout { generation=UUID() }
      if !contentInstalled || sourceGraphic != graphic || sourceLayout != layout || contentSize != size {
        host.rootView=content
      }
      contentInstalled=true
      sourceGraphic=graphic;sourceLayout=layout
      contentSize=size
      host.view.bounds=CGRect(origin:.zero,size:size)
      host.view.transform = .identity
      host.view.center=CGPoint(x:size.width/2,y:size.height/2)
      host.view.setNeedsLayout();host.view.layoutIfNeeded()
      canonical=nil
      if nextOwnerID == nil {sourceOwnerID=nil}
    } else if registry.canonicalCutReady(selectionID:selectionID) {
      canonical = .init(content:targetContent,graphic:targetGraphic,layout:targetLayout,
        size:targetSize,offset:targetOffset)
      registry.canonicalHostStaged(reference,selectionID:selectionID)
    }
    registry.register(self,reference:reference,selectionID:selectionID)
  }
  func hasCanonical(graphic:NotebookGraphic,layout:NotebookGraphicLayout)->Bool {
    canonical?.graphic == graphic && canonical?.layout == layout
  }
  func installCanonical() {
    guard let canonical else {return}
    host.rootView=canonical.content
    sourceGraphic=canonical.graphic;sourceLayout=canonical.layout
    contentSize=canonical.size;generation=UUID()
    host.view.bounds=CGRect(origin:.zero,size:canonical.size)
    host.view.transform = .identity
    host.view.center=CGPoint(x:displaySize.width/2+canonical.offset.x,
      y:displaySize.height/2+canonical.offset.y)
    host.view.isHidden=false
    host.view.setNeedsLayout();host.view.layoutIfNeeded()
    self.canonical=nil
    awaitingWrapperRebase=true
  }
  func pose(_ edit:NotebookGraphicSelection.Edit,from member:NotebookGraphicSelection.Member)->CGAffineTransform? {
    guard contentInstalled,contentSize.width>0,contentSize.height>0,
      let surface=NotebookGraphicSelection.displayTransform(from:member,to:edit) else {return nil}
    let old=member.layout.frame
    let sourceX=contentSize.width/CGFloat(old.width),sourceY=contentSize.height/CGFloat(old.height)
    let targetX=displaySize.width/CGFloat(old.width),targetY=displaySize.height/CGFloat(old.height)
    guard [sourceX,sourceY,targetX,targetY].allSatisfy({$0.isFinite && $0>0}) else {return nil}
    // The hosting view is a bounding rectangle in surface coordinates. Move
    // that rectangle by the exact body-to-surface affine, including ancestors,
    // rotation and skew; resizing a CGRect loses all three.
    let local=CGAffineTransform(scaleX:1/sourceX,y:1/sourceY)
      .concatenating(.init(translationX:CGFloat(old.x),y:CGFloat(old.y)))
      .concatenating(surface)
      .concatenating(.init(translationX:-CGFloat(old.x),y:-CGFloat(old.y)))
      .concatenating(.init(scaleX:targetX,y:targetY))
    return [local.a,local.b,local.c,local.d,local.tx,local.ty].allSatisfy(\.isFinite) ? local : nil
  }
  func install(_ pose:CGAffineTransform) {
    host.view.isHidden=false
    let centre=CGPoint(x:contentSize.width/2,y:contentSize.height/2).applying(pose)
    host.view.transform=CGAffineTransform(a:pose.a,b:pose.b,c:pose.c,d:pose.d,tx:0,ty:0)
    host.view.center=centre
  }
  func hide() {host.view.isHidden=true}
  func uninstall() {
    if let reference {registry?.unregister(self,reference:reference)}
    reference=nil;registry=nil
  }
}

struct NotebookSelectedGraphicHost<Content:View>:UIViewControllerRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let reference:EditableElementReference
  let selectionID:UUID
  let size:CGSize
  let graphic:NotebookGraphic
  let layout:NotebookGraphicLayout
  let targetGraphic:NotebookGraphic
  let targetLayout:NotebookGraphicLayout
  let targetSize:CGSize
  let targetOffset:CGPoint
  let targetContent:AnyView
  @ViewBuilder let content:()->Content
  func makeUIViewController(context:Context)->NotebookSelectedGraphicHostController { .init() }
  func updateUIViewController(_ controller:NotebookSelectedGraphicHostController,context:Context) {
    controller.update(registry:model.selectedGraphicHosts,reference:reference,
      selectionID:selectionID,size:size,graphic:graphic,layout:layout,
      content:AnyView(content().environment(model).frame(width:size.width,height:size.height)),
      targetGraphic:targetGraphic,targetLayout:targetLayout,targetSize:targetSize,
      targetOffset:targetOffset,targetContent:AnyView(targetContent.environment(model)))
  }
  static func dismantleUIViewController(_ controller:NotebookSelectedGraphicHostController,coordinator:()) {
    controller.uninstall()
  }
}

/// Text has no graphic mesh, but its visible body must leave with the raw
/// drawable in the same native transaction during a mixed deletion.
@MainActor final class NotebookSelectedTextHostController:UIViewController {
  private let host=UIHostingController(rootView:AnyView(EmptyView()))
  private weak var registry:NotebookSelectedGraphicHosts?
  private var reference:EditableElementReference?
  private var selectionID:UUID?
  private var size=CGSize.zero
  private var installed=false
  override func loadView() {
    view=UIView();view.backgroundColor = .clear;view.isOpaque=false;view.clipsToBounds=false
    host.view.backgroundColor = .clear;host.view.isOpaque=false;host.view.clipsToBounds=false
    host.safeAreaRegions=[]
    addChild(host);view.addSubview(host.view);host.didMove(toParent:self)
  }
  override func viewDidAppear(_ animated:Bool) {
    super.viewDidAppear(animated)
    if let registry,let reference,let selectionID,view.window != nil {
      registry.registerText(self,reference:reference,selectionID:selectionID)
    }
  }
  func update(registry:NotebookSelectedGraphicHosts,reference:EditableElementReference,
    selectionID:UUID,size:CGSize,content:AnyView) {
    loadViewIfNeeded()
    if self.reference != reference || self.selectionID != selectionID {
      if let previous=self.reference {self.registry?.unregisterText(self,reference:previous)}
      self.reference=reference;self.selectionID=selectionID;installed=false
    }
    self.registry=registry
    if !installed || self.size != size {
      host.rootView=content;self.size=size;installed=true
      host.view.frame=CGRect(origin:.zero,size:size)
      host.view.setNeedsLayout();host.view.layoutIfNeeded()
    }
    registry.registerText(self,reference:reference,selectionID:selectionID)
  }
  func hide() {host.view.isHidden=true}
  func show() {host.view.isHidden=false}
  var isHidden:Bool {host.view.isHidden}
  func uninstall() {
    if let reference {registry?.unregisterText(self,reference:reference)}
    reference=nil;registry=nil
  }
}

struct NotebookSelectedTextHost<Content:View>:UIViewControllerRepresentable {
  @Environment(NotebookAppModel.self) private var model
  let reference:EditableElementReference
  let selectionID:UUID
  let size:CGSize
  @ViewBuilder let content:()->Content
  func makeUIViewController(context:Context)->NotebookSelectedTextHostController {.init()}
  func updateUIViewController(_ controller:NotebookSelectedTextHostController,context:Context) {
    controller.update(registry:model.selectedGraphicHosts,reference:reference,selectionID:selectionID,
      size:size,content:AnyView(content().environment(model).frame(width:size.width,height:size.height)))
  }
  static func dismantleUIViewController(_ controller:NotebookSelectedTextHostController,coordinator:()) {
    controller.uninstall()
  }
}
#endif

struct NotebookSelectedGraphicHostModifier:ViewModifier {
  let reference:EditableElementReference
  let selectionID:UUID?
  let size:CGSize
  let graphic:NotebookGraphic?
  let layout:NotebookGraphicLayout?
  let targetGraphic:NotebookGraphic?
  let targetLayout:NotebookGraphicLayout?
  let targetSize:CGSize
  let targetOffset:CGPoint
  let targetContent:AnyView?
  @ViewBuilder func body(content:Content)->some View {
    #if os(iOS)
    if let selectionID {
      if let graphic,let layout {
        NotebookSelectedGraphicHost(reference:reference,selectionID:selectionID,size:size,graphic:graphic,layout:layout,
          targetGraphic:targetGraphic ?? graphic,targetLayout:targetLayout ?? layout,targetSize:targetSize,
          targetOffset:targetOffset,targetContent:targetContent ?? AnyView(content)) { content }
      } else {content}
    } else { content }
    #else
    content
    #endif
  }
}

struct NotebookSelectedTextHostModifier:ViewModifier {
  let reference:EditableElementReference
  let selectionID:UUID?
  let size:CGSize
  @ViewBuilder func body(content:Content)->some View {
    #if os(iOS)
    if let selectionID {
      NotebookSelectedTextHost(reference:reference,selectionID:selectionID,size:size) {content}
    } else {content}
    #else
    content
    #endif
  }
}
