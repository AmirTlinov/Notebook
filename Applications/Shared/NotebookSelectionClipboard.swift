import CoreGraphics
import Foundation
import NotebookCore

/// A finite export of the selected material. It never writes the source or
/// reads the system clipboard. Live rendering and selection keep their owners.
extension NotebookAppModel {
  func clipboardSelectionFragment() throws -> NotebookPasteFragment { try selectionExport().fragment }

  /// Duplication shares the same bounded export and ordinary addressed writer.
  /// Native graphic contacts retain their causal copy operation; text, programs
  /// and whole groups use the same element transaction, never the clipboard.
  func duplicateSelectedContent() {
    if selectionSession.region != nil || (!selectionSession.elements.isEmpty
      && selectionSession.elements.allSatisfy({ graphicElement($0) != nil })) {
      duplicateGraphicMaterial(); return
    }
    guard selectionSession.items.isEmpty,let first=selectionSession.elements.first,
      let target=nativeElementSource(first)?.target else { return }
    do {
      let exported=try selectionExport(),fragment=try exported.fragment.reidentified()
      let bounds=elementGeometry(first)?.bounds
      let offset=SpatialPoint(x:exported.minimum.x+min(24,max(0,bounds.map { $0.maxX-exported.minimum.x-fragment.size.x } ?? 24)),
        y:exported.minimum.y+min(24,max(0,bounds.map { $0.maxY-exported.minimum.y-fragment.size.y } ?? 24)))
      let operations=try fragment.operations(target:target,offset:offset,
        worldOrigin:target.kind == .board ? exported.worldOrigin : nil)
      let edits=operations.map { operation -> NotebookElementEdit in
        let reference:EditableElementReference
        switch first {
        case .page(let owner,_): reference = .page(pageID:owner,elementID:operation.id!)
        case .spatial(let owner,_): reference = .spatial(boardID:owner,elementID:operation.id!)
        }
        return .init(reference:reference,kind:operation.kind,values:operation.values)
      }
      let originals=exported.fragment.elements
      let references=originals.map { element -> EditableElementReference in
        switch first { case .page(let owner,_): .page(pageID:owner,elementID:element.id)
          case .spatial(let owner,_): .spatial(boardID:owner,elementID:element.id) }
      }
      if performElementOperations(edits,summary:"Дублировать содержимое",readSources:references,
        copiedFrom:Dictionary(uniqueKeysWithValues:zip(fragment.elements,originals).map { ($0.id,$1.id) })) {
        selectElements(edits.filter { edit in fragment.elements.contains { $0.id == edit.reference.elementID && $0.parentID == nil } }.map(\.reference))
      }
    } catch { showCue(error.localizedDescription) }
  }

  private func selectionExport() throws -> (fragment:NotebookPasteFragment,minimum:SpatialPoint,worldOrigin:WorldPoint) {
    func unavailable() -> CollaborationError { .init("selection_not_ready","Выделение изменилось или ещё готовится. Повторите действие.") }
    var sources: [AgentElement] = []
    let graph: NotebookGraphicGraph
    let surface: SurfaceID
    let rootOrigin: WorldPoint
    if let region=selectionSession.region {
      guard regionIsCurrent(region),let prepared=region.materialization else { throw unavailable() }
      let ids=Set(prepared.selected.map(\.elementID))
      let objects=prepared.working.filter { ids.contains($0.id) }
      sources=objects.map(\.pageElement); graph = .init(objects.map(\.node))
      surface=region.address.surface;rootOrigin=region.address.worldOrigin ?? .zero
    } else {
      let references=selectionSession.elements
      guard selectionSession.items.isEmpty,let first=references.first,
        let target=nativeElementSource(first)?.target,let prepared=editingGraphicGraph(first),
        references.allSatisfy({ nativeElementSource($0)?.target == target && elementCommandDrafts[$0] == nil }) else { throw unavailable() }
      graph=prepared
      surface = target.kind == .page ? .page(target.id) : target.kind == .cover ? .cover(target.id) : .board(target.id)
      rootOrigin=graph.placement(first.elementID)?.origin ?? .zero
      var ids=Set(references.map(\.elementID))
      for reference in references where isElementGroup(reference) {
        guard groupAllowsLiveManipulation(reference,in:graph) else { throw unavailable() }
        let members=graph.visibleGroupCandidates(reference.elementID,on:surface,in:.infinite,limit:33)
        guard !members.overflow else { throw CollaborationError("selection_limit","За один раз можно скопировать до 32 объектов.") }
        ids.formUnion(members.ids)
        for id in members.ids {
          for ancestor in graph.placement(id)?.ancestors ?? [] {
            ids.insert(ancestor)
            if ancestor == reference.elementID { break }
          }
        }
      }
      guard (1...32).contains(ids.count) else { throw unavailable() }
      switch first {
      case .page(let owner,_): sources=pages[owner]?.interactionElements(ids:ids) ?? []
      case .spatial(let owner,_):
        sources=try (boardHierarchy?.board(owner)?.interactionElements(ids:ids) ?? []).map { element in
          try JSONValue.encode(element).decode(AgentElement.self)
        }
      }
      guard sources.count == ids.count else { throw unavailable() }
    }
    let ids=Set(sources.map(\.id))
    var bounds=CGRect.null
    for element in sources {
      guard let placement=graph.placement(element.id) else { throw unavailable() }
      let delta=rootOrigin.delta(to:placement.origin)
      let box=CGRect(x:0,y:0,width:placement.localSize.x,height:placement.localSize.y).applying(placement.transform)
        .offsetBy(dx:delta.x,dy:delta.y)
      bounds=bounds.union(box)
    }
    guard !bounds.isNull,bounds.width > 0,bounds.height > 0 else { throw unavailable() }
    let elements=try sources.map { element -> AgentElement in
      guard case .object(var values)=try JSONValue.encode(element) else { throw unavailable() }
      if element.parentID.map({ !ids.contains($0) }) ?? true {
        guard let placement=graph.placement(element.id) else { throw unavailable() }
        let pose=try placement.detached(),delta=rootOrigin.delta(to:placement.origin)
        values.removeValue(forKey:"parentID")
        values["frame"]=try .encode(PageRect(x:pose.frame.x+delta.x-bounds.minX,y:pose.frame.y+delta.y-bounds.minY,
          width:pose.frame.width,height:pose.frame.height))
        values["basis"]=try .encode(pose.basis)
      }
      if var graphic=element.graphic {
        if let body=graph.resolve(element.id,space:.body).layout {
          graphic.connection=graphic.connection?.detachingEndpoints(in:body,retainingBindingsTo:ids)
        }
        let cuts=elementErasures(on:surface)[element.id] ?? []
        if !cuts.isEmpty { graphic.mask=(graphic.mask ?? .init()).capturing(cuts,transform:graphic.transform) }
        guard case .object(var encoded)=try JSONValue.encode(graphic) else { throw unavailable() }
        encoded["sourceInkIDs"] = .array([])
        values["graphic"] = .object(encoded)
      }
      return try JSONValue.object(values).decode(AgentElement.self)
    }
    return (.init(elements:elements,size:.init(x:bounds.width,y:bounds.height)),.init(x:bounds.minX,y:bounds.minY),rootOrigin)
  }
}
