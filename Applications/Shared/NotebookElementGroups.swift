import CoreGraphics
import Foundation
import NotebookCore

extension NotebookAppModel {
  func isElementGroup(_ reference: EditableElementReference) -> Bool {
    nativeElementSource(reference)?.placementSource?.isGroup == true
  }

  func parentGroup(_ reference: EditableElementReference) -> EditableElementReference? {
    guard let id=nativeElementSource(reference)?.placementSource?.parentID else { return nil }
    switch reference { case .page(let owner,_): return .page(pageID:owner,elementID:id)
      case .spatial(let owner,_): return .spatial(boardID:owner,elementID:id) }
  }

  private func groupGraph(_ reference: EditableElementReference) -> (NotebookGraphicGraph,String)? {
    switch reference {
    case .page(let owner,let id): return pages[owner].map { (graphicGraph(page:$0),id) }
    case .spatial(let owner,let id):
      guard let cohort=compositionTiles.published else { return nil }
      return (presentedGraphicGraph(boardID:owner,cohort:cohort),id)
    }
  }

  func groupManipulationGeometry(_ reference: EditableElementReference) -> (placement:NotebookElementPlacement,bounds:CGRect)? {
    guard isElementGroup(reference),let (graph,id)=groupGraph(reference),
      let placement=graph.placement(id),let bounds=graph.groupBounds(id) else { return nil }
    return (placement,bounds)
  }

  /// Baked descendants cannot silently remain at the old pose. Until the scene
  /// has admitted all shown participants, selection is allowed but not a drag.
  func groupAllowsLiveManipulation(_ reference: EditableElementReference) -> Bool {
    guard let (graph,id)=groupGraph(reference) else { return false }
    let unpaintedParents:[String]
    switch reference {
    case .page(let owner,_): unpaintedParents=(pages[owner]?.elements ?? []).filter { $0.kind != .group && $0.graphic == nil }.compactMap(\.parentID)
    case .spatial(let owner,_): unpaintedParents=(boardHierarchy?.board(owner)?.elements ?? []).filter { $0.kind != .group && $0.graphic == nil }.compactMap(\.parentID)
    }
    let key=UUID(uuidString:id)?.uuidString ?? id
    guard !unpaintedParents.contains(where: { (UUID(uuidString:$0)?.uuidString ?? $0) == key || graph.placement($0)?.descends(from:id) == true }) else { return false }
    if case .page = reference { return true }
    guard case .spatial(let owner,_) = reference,let cohort=compositionTiles.published else { return false }
    let authored=authoredGraphicGraph(boardID:owner)
    guard graph.placement(id) == authored.placement(id) else { return false }
    let members=authored.nodes.values.filter { $0.shown && $0.placement.descends(from:id) }
    return !members.isEmpty && members.allSatisfy { presentedElement(.spatial(boardID:owner,elementID:$0.id),cohort:cohort) != nil }
  }

  var canGroupSelectedElements: Bool {
    let refs=selectionSession.elements
    guard selectionSession.items.isEmpty,(2...31).contains(refs.count) else { return false }
    let sources=refs.compactMap(nativeElementSource)
    return sources.count == refs.count && (try? NotebookStore.elementGroupingEdits(sources,id:UUID().uuidString)) != nil
  }

  func groupSelectedElements() {
    guard canGroupSelectedElements else { return }
    let selection=selectionSession.id
    Task { [weak self] in
      guard let self else { return }
      _ = await graphicCommandTask?.value
      await reloadExternalChanges()?.value
      guard selectionSession.id == selection,canGroupSelectedElements else { return }
      let refs=selectionSession.elements,sources=refs.compactMap(nativeElementSource),id=UUID().uuidString
      do {
        let operations=try NotebookStore.elementGroupingEdits(sources,id:id)
        let first=refs[0]
        func reference(_ id:String) -> EditableElementReference {
          switch first { case .page(let owner,_): .page(pageID:owner,elementID:id)
            case .spatial(let owner,_): .spatial(boardID:owner,elementID:id) }
        }
        // Membership preserves all displayed points. Keep that exact image
        // until the atomic action is published, rather than half-previewing it.
        guard performElementOperations(operations.map { .init(reference:reference($0.id!),kind:$0.kind,values:$0.values) },
          summary:"Сгруппировать объекты",readSources:refs,previews:false),
          await graphicCommandTask?.value != nil else { return }
        await reloadExternalChanges()?.value
        if selectionSession.id == selection,isElementGroup(reference(id)) { selectElement(reference(id)) }
      } catch { showCue(error.localizedDescription) }
    }
  }

  /// Returns true when the selection is a group, including a refused edit.
  /// Rejection never falls through to a per-member rewriting implementation.
  func transformSelectedGroup(radians: Double,scale: Double) -> Bool {
    guard let ref=selectionSession.element,isElementGroup(ref) else { return false }
    guard radians.isFinite,scale.isFinite,scale>0,groupAllowsLiveManipulation(ref),
      let value=groupManipulationGeometry(ref) else { return true }
    let box=value.bounds
    let change=CGAffineTransform(translationX:-box.midX,y:-box.midY)
      .concatenating(.init(rotationAngle:radians)).concatenating(.init(scaleX:scale,y:scale))
      .concatenating(.init(translationX:box.midX,y:box.midY))
    if let boundary=elementGeometry(ref)?.bounds,!boundary.contains(box.applying(change)) {
      showCue("Для этого поворота или масштаба не хватает места на листе.");return true
    }
    do {
      let edit=try value.placement.applyingSurfaceTransform(change)
      let ancestors=value.placement.ancestors.map { id -> EditableElementReference in
        switch ref { case .page(let owner,_): .page(pageID:owner,elementID:id)
          case .spatial(let owner,_): .spatial(boardID:owner,elementID:id) }
      }
      _ = performElementOperation(.updateElement,reference:ref,values:["frame":try .encode(edit.frame),"basis":try .encode(edit.basis)],
        summary:radians == 0 ? "Масштабировать группу" : "Повернуть группу",readSources:ancestors)
    } catch { showCue(error.localizedDescription) }
    return true
  }
}
