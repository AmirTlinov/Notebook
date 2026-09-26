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

  func groupManipulationGeometry(_ reference: EditableElementReference,in prepared:NotebookGraphicGraph? = nil) -> (placement:NotebookElementPlacement,bounds:CGRect)? {
    if case .spatial(let boardID,let id)=reference {
      guard let read=spatialGroupReads[boardID]?[id],!read.localBounds.isNull,
        let graph=prepared ?? groupGraph(reference)?.0,let placement=graph.placement(id) else { return nil }
      return (placement,read.localBounds.applying(placement.transform))
    }
    if let contact=selectionSession.manipulation,contact.reference == reference,contact.graphicCapture?.closedGroup == true,
      let placement=try? contact.placement?.updating(frame:.init(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height),basis:contact.basis) {
      return (placement,contact.presentedFrame)
    }
    // A second contact/draft can change a member independently. Its bounds
    // must then be derived from that complete projected cut, not this snapshot.
    if selectionSession.manipulation == nil,elementCommandDrafts.count == 1,
      let draft=elementCommandDrafts[reference],let capture=draft.capture,capture.closedGroup,
      let bounds=capture.bounds,let placement=try? capture.graph.placement(reference.elementID)?.updating(frame:draft.frame,basis:draft.basis) {
      return (placement,bounds)
    }
    guard isElementGroup(reference),let graph=prepared ?? groupGraph(reference)?.0 else { return nil }
    let id=reference.elementID
    guard
      let placement=graph.placement(id),let bounds=graph.groupBounds(id) else { return nil }
    return (placement,bounds)
  }

  /// A spatial whole is admitted by the complete indexed source, not by the
  /// accidental subset of children that happens to fit the live workset.
  func groupAllowsLiveManipulation(_ reference: EditableElementReference,in prepared:NotebookGraphicGraph? = nil) -> Bool {
    guard let graph=prepared ?? groupGraph(reference)?.0 else { return false }
    let id=reference.elementID
    if case .spatial(let owner,_)=reference {
      guard let read=spatialGroupReads[owner]?[id],!read.localBounds.isNull,
        read.source == nativeElementSource(reference)?.placementSource else { return false }
      let desired=projectingGraphicCommands(boardHierarchy?.board(owner)?.graphicGraph() ?? NotebookGraphicGraph([]),holdingSelectedInk:false) { .spatial(boardID:owner,elementID:$0) }
      return graph.placement(id) == desired.placement(id)
    }
    return graph.groups[id] != nil
  }

  var hasSpatialGroupContact: Bool {
    guard let contact=selectionSession.manipulation,let reference=contact.reference,case .spatial=reference else { return false }
    return contact.graphicCapture?.source.isGroup == true
  }

  /// The view's ordinary composition request carries the desired whole poses.
  /// Painting reads only the published request; pointer samples never author
  /// a second live geometry ahead of the same whole's passive pixels.
  var compositionGroupPoses: [SceneCompositionPlane:[String:NotebookElementPlacement.Source]] {
    var drafts=elementCommandDrafts.filter { $0.value.source.isGroup }.mapValues(\.source)
    if let contact=selectionSession.manipulation,let reference=contact.reference,
      let captured=contact.graphicCapture,captured.source.isGroup {
      var source=captured.source
      source.frame = .init(x:contact.frame.minX,y:contact.frame.minY,width:contact.frame.width,height:contact.frame.height)
      source.basis=contact.basis;drafts[reference]=source
    }
    var result:[SceneCompositionPlane:[String:NotebookElementPlacement.Source]]=[:]
    for (ref,source) in drafts {
      guard case .spatial(let boardID,let id)=ref,let element=nativeElementSource(ref)?.spatial else { continue }
      let plane=element.surface.kind == .cover ? SceneCompositionPlane.cover(boardID:boardID,itemID:element.surface.ownerID!) : .board(boardID)
      result[plane,default:[:]][id]=source
    }
    return result
  }

  var canGroupSelectedElements: Bool {
    let refs=selectionSession.elements
    guard !selectionContainsSourceAnchoredInk,selectionSession.ink.isEmpty,selectionSession.items.isEmpty,(2...31).contains(refs.count) else { return false }
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
