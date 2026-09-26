import Foundation
import NotebookCore

/// Exact persisted source of the preceding command on this physical element.
/// The serial writer may advance our own source, never silently rebase onto a
/// peer's edit. A failed predecessor cancels its dependent commands.
struct NotebookElementCommandResult: Sendable {
  let page: AgentElement?
  let spatial: SpatialElement?
  var boardHeader: BoardDocument? = nil
}

struct NotebookElementCommand: Equatable, Sendable {
  let id: UUID
  let task: Task<NotebookElementCommandResult?, Never>
  var cursor: UInt64?
  static func == (lhs:Self,rhs:Self)->Bool { lhs.id == rhs.id }
}

/// A ready or asynchronously prepared edit enters this same causal writer.
/// Selection lifetime is deliberately absent from an accepted command.
struct NotebookElementCommandPlan: Sendable {
  let target:CollaborationTarget
  let references:[EditableElementReference]
  let sources:[EditableElementReference:NotebookNativeElementSource]
  let sourceTasks:[EditableElementReference:Task<NotebookElementCommandResult?,Never>]
  let operations:[CollaborationOperation]
  let summary:String
  let layerMove:NotebookElementLayerMove?
  let copiedFrom:[String:String]
  let expectedInkRevision:String?
}

/// The first edit of a raw contact uses the same native command as authored
/// members. This is one frozen selection cut, not a second mutation queue.
struct NotebookSelectionEditSource: Equatable, Sendable {
  let selectionID:UUID
  let address:NotebookToolAddress
  let references:[EditableElementReference]
  let ink:[NotebookSelectedInk]
  let sources:[EditableElementReference:NotebookNativeElementSource]
  let dependencies:[EditableElementReference:NotebookElementCommand]
  let members:[NotebookGraphicSelection.Member]
  var expectedInkRevision:String? { ink.first?.revision }

  var orderedMembers:[NotebookGraphicSelection.Member] {
    let ids=Set(references.map(\.elementID))
    return members.filter { ids.contains($0.id) && $0.placement.parentID == nil
      && $0.graphic.sourceInkContactID != nil }
  }
  var needsOrderedPresentation:Bool { !ink.isEmpty || !orderedMembers.isEmpty }

  var initialPresentationWorking:[NotebookWorkingGraphic] {
    ink.map(\.working)+orderedMembers.map { member in
      .init(elementID:member.id,sourceID:member.graphic.sourceInkContactID!,surface:address.surface,
        frame:member.frame,worldOrigin:address.surface.kind == .page ? nil : member.origin,
        graphic:member.graphic,basis:member.placement.basis)
    }
  }

  /// Presentation is independent of mutation kind: an already authored contact
  /// updates its existing element; only a raw contact is converted by prepare.
  func presentationWorking(for edits:[NotebookGraphicSelection.Edit],deleting:Bool) throws -> [NotebookWorkingGraphic] {
    let raw=try working(for:edits,deleting:deleting)
    // Existing ordered members are absent from the desired delete frame. The
    // captured originals still let the same presentation restore them on failure.
    if deleting { return raw }
    let byID=Dictionary(uniqueKeysWithValues:edits.map { ($0.id,$0) })
    return try raw+orderedMembers.map { member in
      guard let edit=byID[member.id],let sourceID=member.graphic.sourceInkContactID else {
        throw CollaborationError("revision_conflict","Выделение изменилось. Повторите действие.")
      }
      return .init(elementID:member.id,sourceID:sourceID,surface:address.surface,frame:edit.frame,
        worldOrigin:address.surface.kind == .page ? nil : member.origin,graphic:edit.graphic,basis:edit.basis)
    }
  }

  struct Prepared:Sendable {
    let edits:[NotebookElementEdit]
    let working:[NotebookWorkingGraphic]
    let sources:[EditableElementReference:NotebookNativeElementSource]
    let selected:[EditableElementReference]
  }

  func working(for edits:[NotebookGraphicSelection.Edit],deleting:Bool) throws -> [NotebookWorkingGraphic] {
    let byID=Dictionary(uniqueKeysWithValues:edits.map { ($0.id,$0) })
    return try ink.map { raw in
      if deleting {
        var graphic=raw.material.graphic
        graphic.mask=(graphic.mask ?? .init()).appending(.subtract,polygon:[.zero,.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)])
        return .init(id:raw.conversionID,surface:address.surface,frame:raw.material.frame,
          worldOrigin:raw.address.worldOrigin,graphic:graphic)
      }
      guard let edit=byID[raw.memberID] else {
        throw CollaborationError("revision_conflict","Выделение изменилось. Повторите действие.")
      }
      return .init(id:raw.conversionID,surface:address.surface,frame:edit.frame,
        worldOrigin:raw.address.worldOrigin,graphic:edit.graphic,basis:edit.basis)
    }
  }

  /// Measured bodies are encoded once outside MainActor, after lift has
  /// synchronously reserved the existing writer FIFO.
  func prepare(_ edits:[NotebookGraphicSelection.Edit],deleting:Bool = false) throws -> Prepared {
    func changed()->CollaborationError { .init("revision_conflict","Выделение изменилось. Повторите действие.") }
    guard deleting || (edits.count == members.count && Set(edits.map(\.id)) == Set(members.map(\.id))) else { throw changed() }
    let byID=Dictionary(uniqueKeysWithValues:edits.map { ($0.id,$0) })
    let originals=Dictionary(uniqueKeysWithValues:members.map { ($0.id,$0) })
    var operations:[NotebookElementEdit]=[],checks=sources
    let working=try working(for:edits,deleting:deleting)
    for reference in references {
      try Task.checkCancellation()
      if deleting { operations.append(.init(reference:reference,kind:.removeElement,values:[:]));continue }
      guard let edit=byID[reference.elementID],let original=originals[reference.elementID] else { throw changed() }
      var values:[String:JSONValue]=[:],patch:[String:JSONValue]=[:]
      if original.frame != edit.frame { values["frame"]=try .encode(edit.frame) }
      if original.placement.basis != edit.basis { values["basis"]=try edit.basis.map(JSONValue.encode) ?? .null }
      let old=original.graphic,new=edit.graphic
      if old.connection != new.connection { patch["connection"]=try .encode(new.connection) }
      if old.transform != new.transform { patch["transform"]=try .encode(new.transform) }
      if old.style != new.style { patch["style"]=try .encode(new.style) }
      if old.cornerRadius != new.cornerRadius { patch["cornerRadius"]=try .encode(new.cornerRadius) }
      if !patch.isEmpty { values["graphic"] = .object(patch) }
      if !values.isEmpty { operations.append(.init(reference:reference,kind:.updateElement,values:values)) }
    }
    for object in working {
      try Task.checkCancellation()
      let reference=address.reference(object.id)
      // The ID becomes an insertion precondition here and nowhere during
      // read-only selection. Do not ask nativeElementSource for a fake member.
      checks[reference] = .init(target:address.target,id:object.id)
      operations.append(.init(reference:reference,kind:.convertInkToElement,values:try object.authoredValues()))
    }
    guard operations.count<=32,checks.count<=64 else {
      throw CollaborationError("selection_limit","За один раз можно изменить до 32 объектов и 64 исходников.")
    }
    return .init(edits:operations,working:working,sources:checks,
      selected:deleting ? [] : references+ink.map { address.reference($0.memberID) })
  }
}

struct NotebookElementCommandWriteResult:Sendable {
  let cursor:UInt64
  let sources:[NotebookNativeElementSource]
  let header:BoardDocument?
}

@MainActor final class NotebookElementCommandBatch {
  let id=UUID(),generation=UUID()
  var result:Task<[EditableElementReference:NotebookElementCommandResult]?,Never>!
  private var admission:Result<NotebookElementCommandPlan,Error>?
  private var waiters:[CheckedContinuation<NotebookElementCommandPlan,Error>]=[]
  var admittedPlan:NotebookElementCommandPlan? { try? admission?.get() }
  func prepared() async throws -> NotebookElementCommandPlan {
    if let admission { return try admission.get() }
    return try await withCheckedThrowingContinuation { waiters.append($0) }
  }
  func resolve(_ result:Result<NotebookElementCommandPlan,Error>) {
    guard admission == nil else { return }
    admission=result
    let pending=waiters;waiters.removeAll()
    for waiter in pending { waiter.resume(with:result) }
  }
}

struct NotebookElementCommandDraft: Equatable {
  let source: NotebookElementPlacement.Source
  let graphic: NotebookGraphic?
  var capture: NotebookGraphicContactSource? = nil
  var removed = false
  var textSource: String? = nil
  var textHTML: String? = nil
  var textStyle: NativeTextStyle? = nil
  var frame: PageRect { source.frame }
  var basis: NotebookElementBasis? { source.basis }
  var rect: CGRect { .init(x: frame.x, y: frame.y, width: frame.width, height: frame.height) }

  func projecting(_ element:AgentElement) -> AgentElement? {
    guard !removed else { return nil }
    return .init(id:element.id,kind:element.kind,frame:frame,
      source:textSource ?? element.source,html:textHTML ?? element.html,css:element.css,javaScript:element.javaScript,
      programPackage:element.programPackage,state:element.state,graphic:graphic,textStyle:textStyle ?? element.textStyle,
      parentID:source.parentID,basis:basis)
  }

  /// Same accepted draft as the native body and controls; its causal stamp
  /// remains unresolved until this command's own writer result is available.
  func projecting(_ element:SpatialElement) -> SpatialElement? {
    guard !removed else { return nil }
    return .init(id:element.id,surface:element.surface,kind:element.kind,
      frame:.init(x:frame.x,y:frame.y,width:frame.width,height:frame.height),worldOrigin:element.worldOrigin,
      source:textSource ?? element.source,html:textHTML ?? element.html,css:element.css,javaScript:element.javaScript,
      programPackage:element.programPackage,state:element.state,textStyle:textStyle ?? element.textStyle,
      graphic:graphic,parentID:source.parentID,basis:basis,stamp:element.stamp)
  }

}

extension NotebookAppModel {
  /// Accepted content is independent of focus. The exact writer predecessor
  /// still supplies its durable stamp; this projection never invents one.
  func acceptedElementSource(_ reference:EditableElementReference) -> NotebookNativeElementSource? {
    guard let source=nativeElementSource(reference) else { return nil }
    let working=acceptedWorkingGraphic(reference),draft=elementCommandDrafts[reference]
    let page=working?.surface.kind == .page ? working?.pageElement : source.page
    let spatial=working.map { $0.surface.kind == .page ? nil : $0.spatialElement(stamp:source.spatial?.stamp ?? .init(counter:0,actor:actorID)) } ?? source.spatial
    return .init(target:source.target,id:source.id,
      page:page.flatMap { draft == nil ? $0 : draft!.projecting($0) },
      spatial:spatial.flatMap { draft == nil ? $0 : draft!.projecting($0) })
  }

  func retireGraphicCommands(through cursor: UInt64) {
    for (reference, command) in elementCommandSources {
      guard !editingNativeTextReferences.contains(reference), let accepted = command.cursor, cursor >= accepted else { continue }
      elementCommandSources[reference] = nil
      elementCommandDrafts[reference] = nil
    }
  }

  /// SQL decoding replaces values, not the material they describe. Hand ready
  /// coverage to the equal incoming mask before accepted drafts are retired.
  /// The same rule covers unchanged material and page/board/cover publications.
  func retainPreparedGraphicMasks(in state:NotebookSceneState) {
    func retain(_ graphic:NotebookGraphic?,reference:EditableElementReference,surface:SurfaceID,
      previous:NotebookGraphic?) {
      guard let mask=graphic?.mask else { return }
      let candidates=[elementCommandDrafts[reference]?.graphic?.mask,
        workingGraphics.first(where:{$0.surface == surface && $0.id == reference.elementID})?.graphic.mask,previous?.mask]
      for case let old? in candidates where mask.retainPreparedPaths(from:old) { return }
    }
    for (id,page) in state.pages {
      for element in page.elements where element.graphic?.mask != nil {
        retain(element.graphic,reference:.page(pageID:id,elementID:element.id),surface:.page(id),
          previous:pages[id]?.element(id:element.id)?.graphic)
      }
    }
    for node in state.hierarchy.boards {
      let old=boardHierarchy?.board(node.id)
      for element in node.board.elements where element.graphic?.mask != nil {
        retain(element.graphic,reference:.spatial(boardID:node.id,elementID:element.id),surface:element.surface,
          previous:old?.element(id:element.id)?.graphic)
      }
    }
  }

  func retainedGraphicGraph(includingGroups:Bool = true,reference:(String) -> EditableElementReference) -> NotebookGraphicGraph? {
    if let contact=selectionSession.manipulation,
      let ref=contact.reference ?? contact.selectionSource?.references.first,reference(ref.elementID) == ref,
      let captured=contact.graphicCapture,includingGroups || !captured.source.isGroup { return captured.graph }
    return elementCommandDrafts.first { ref,draft in
      reference(ref.elementID) == ref && draft.capture != nil && (includingGroups || !draft.source.isGroup)
    }?.value.capture?.graph
  }

  /// Whole and leaf drafts enter the one placement resolver before children
  /// are resolved. Never rewrite each child's local frame to preview its parent.
  func elementPlacementDrafts(reference: (String) -> EditableElementReference) -> [String:NotebookElementPlacement.Source] {
    var result:[String:NotebookElementPlacement.Source]=[:]
    for (ref,draft) in elementCommandDrafts {
      let id:String
      switch ref { case .page(_,let value),.spatial(_,let value): id=value }
      if reference(id) == ref { result[id]=draft.source }
    }
    if let contact=selectionSession.manipulation,contact.selectedMembers.isEmpty,let ref=contact.reference {
      let id:String
      switch ref { case .page(_,let value),.spatial(_,let value): id=value }
      if reference(id) == ref,var source=result[id] ?? contact.graphicCapture?.source ?? nativeElementSource(ref)?.placementSource {
        source.frame = .init(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height)
        source.basis=contact.basis;result[id]=source
      }
      if let region=contact.region {
        for (id,pose) in contact.regionPoses where reference(id) == region.address.reference(id) { result[id]=pose }
      }
    }
    return result
  }

  /// Contact and accepted edits share the existing graph, renderer and camera.
  /// Only nodes already admitted by that graph can change here.
  func projectingGraphicCommands(_ graph: NotebookGraphicGraph,
    publishedGroups: [String:NotebookElementPlacement.Source]? = nil,
    holdingSelectedInk:Bool = true,
    reference: (String) -> EditableElementReference) -> NotebookGraphicGraph {
    let selectedEdits=(holdingSelectedInk ? selectionSession.manipulation?.presentedSelectedEdits : selectionSession.manipulation?.selectedEdits) ?? []
    let placements=elementPlacementDrafts(reference:reference)
    var graphics:[String:NotebookGraphic]=[:]
    for (ref,draft) in elementCommandDrafts {
      let id=ref.elementID
      if reference(id) == ref,let graphic=draft.graphic { graphics[id]=graphic }
    }
    if let region=selectionSession.manipulation?.region,let prepared=region.materialization {
      for (id,outside) in prepared.outside where reference(id) == region.address.reference(id) {
        graphics[id]=outside
      }
    }
    if let contact=selectionSession.manipulation,contact.selectedMembers.isEmpty,
      let ref=contact.reference,reference(ref.elementID) == ref,
      var graphic=graphics[ref.elementID] ?? graph.node(ref.elementID)?.graphic {
      if let connection=contact.connection { graphic.connection=connection }
      if contact.vertices != contact.originalVertices { graphic.vertices=contact.vertices }
      if contact.cornerRadius != contact.originalCornerRadius { graphic.cornerRadius=contact.cornerRadius }
      graphics[ref.elementID]=graphic
    }
    var sources=placements
    if let publishedGroups {
      sources=sources.filter { !$0.value.isGroup }
      sources.merge(publishedGroups) { _,published in published }
    }
    for selected in selectedEdits where graph.node(selected.id) != nil {
      graphics[selected.id]=selected.graphic
      if var source=graph.source(selected.id) { source.frame=selected.frame;source.basis=selected.basis;sources[selected.id]=source }
    }
    var held=Set<UUID>()
    for working in workingGraphics {
      guard holdingSelectedInk,let owner=working.inkPresentation,owner.holdsPresentation,held.insert(owner.id).inserted else { continue }
      if let shown=owner.presentedEdits {
        for edit in shown where reference(edit.id) == owner.source.address.reference(edit.id) {
          graphics[edit.id]=edit.graphic
          if var pose=graph.source(edit.id) {pose.frame=edit.frame;pose.basis=edit.basis;sources[edit.id]=pose}
        }
        continue
      }
      for (ref,source) in owner.source.sources where reference(ref.elementID) == ref {
        if let pose=source.placementSource { sources[ref.elementID]=pose }
        if let graphic=source.page?.graphic ?? source.spatial?.graphic { graphics[ref.elementID]=graphic }
      }
      for raw in owner.source.ink {
        guard reference(raw.memberID) == owner.source.address.reference(raw.memberID),var pose=graph.source(raw.memberID) else { continue }
        pose.frame=raw.material.frame;pose.basis=nil;sources[raw.memberID]=pose
        graphics[raw.memberID]=raw.material.graphic
      }
    }
    return graph.projecting(placements:sources,graphics:graphics)
  }
}

struct NotebookElementEdit: Equatable, Sendable {
  let reference: EditableElementReference
  let kind: CollaborationOperation.Kind
  let values: [String: JSONValue]
}

/// A contact retains the exact admitted graph, just as it retains its input
/// settings. Lift transfers this source to the existing command draft; disposal
/// of that draft also disposes of the captured graph, without a global cache.
final class NotebookGraphicContactSource: Equatable, Sendable {
  let graph:NotebookGraphicGraph
  let source:NotebookElementPlacement.Source
  let closedGroup:Bool
  let bounds:CGRect?
  init(graph:NotebookGraphicGraph,source:NotebookElementPlacement.Source,id:String,closedGroup:Bool? = nil) {
    self.graph=graph;self.source=source;self.closedGroup=closedGroup ?? (source.isGroup && graph.groupIsSelfContained(id));bounds=nil
  }
  private init(_ original:NotebookGraphicContactSource,bounds:CGRect) {
    graph=original.graph;source=original.source;closedGroup=original.closedGroup;self.bounds=bounds
  }
  func retaining(bounds:CGRect) -> NotebookGraphicContactSource { .init(self,bounds:bounds) }
  static func == (a:NotebookGraphicContactSource,b:NotebookGraphicContactSource) -> Bool { a === b }
}
