import CoreGraphics
import Foundation
import NotebookCore

/// A cheap immutable document cut. Only the selected sources and their bases
/// survive preparation; a later edit never silently borrows today's revision.
struct NotebookRegionSourceSnapshot: Sendable {
  let page: PageDocument?
  let board: BoardDocument?

  func orderedGraphics(for region:NotebookRegionSelection) throws -> [EditableElementReference] {
    let ids=Set(region.graphics.map(\.elementID))
    let ordered=page?.interactionElements(ids:ids).map(\.id)
      ?? board?.interactionElements(ids:ids).map(\.id) ?? []
    guard ordered.count == region.graphics.count else { throw staleRegion() }
    return ordered.map(region.address.reference)
  }

  func sources(for region:NotebookRegionSelection,graph:NotebookGraphicGraph) throws
    -> [EditableElementReference:NotebookNativeElementSource] {
    var result:[EditableElementReference:NotebookNativeElementSource]=[:]
    for reference in region.graphics {
      guard let placement=graph.placement(reference.elementID) else { throw staleRegion() }
      for id in [reference.elementID]+placement.ancestors {
        let ref=region.address.reference(id)
        guard result[ref] == nil else { continue }
        let value=NotebookNativeElementSource(target:region.address.target,id:id,
          page:page?.element(id:id),spatial:board?.element(id:id))
        guard let source=value.placementSource,source == graph.source(id),
          (value.page?.graphic ?? value.spatial?.graphic) == graph.node(id)?.graphic else { throw staleRegion() }
        result[ref]=value
      }
    }
    guard result.count <= 64 else { throw staleRegion() }
    return result
  }
}

private func staleRegion() -> CollaborationError {
  .init("revision_conflict","Материал области изменился или ещё сохраняется. Повторите лассо.")
}

extension NotebookRegionMaterialization {
  /// Transform the relative bases, never the retained measurements or cutouts.
  func transformed(from original:PageRect,to frame:CGRect,address:NotebookToolAddress) throws -> Self {
    let change=CGAffineTransform(translationX:-original.x,y:-original.y)
      .concatenating(.init(scaleX:frame.width/original.width,y:frame.height/original.height))
      .concatenating(.init(translationX:frame.minX,y:frame.minY))
    return try transformed(by:change,address:address)
  }

  func transformed(by change:CGAffineTransform,address:NotebookToolAddress) throws -> Self {
    let ids=Set(selected.map(\.elementID))
    let objects=try working.map { object -> NotebookWorkingGraphic in
      guard ids.contains(object.id) else { return object }
      let delta=(address.worldOrigin ?? .zero).delta(to:object.worldOrigin ?? .zero)
      let local=CGAffineTransform(translationX:delta.x,y:delta.y).concatenating(change)
        .concatenating(.init(translationX:-delta.x,y:-delta.y))
      let pose=try object.node.placement.applyingSurfaceTransform(local)
      return .init(id:object.strokeID,surface:object.surface,frame:pose.frame,
        worldOrigin:object.worldOrigin,graphic:object.graphic,basis:pose.basis)
    }
    let poses=Dictionary(uniqueKeysWithValues:objects.filter { ids.contains($0.id) }.map { ($0.id,$0) })
    let changed=try edits.map { edit -> NotebookElementEdit in
      guard let object=poses[edit.reference.elementID] else { return edit }
      var values=edit.values
      values["frame"]=try .encode(object.frame)
      values["basis"]=try object.basis.map(JSONValue.encode)
      // A gesture changes placement, not a megabyte of immutable material.
      return .init(reference:edit.reference,kind:edit.kind,values:values)
    }
    return .init(edits:changed,working:objects,selected:selected,sources:sources)
  }

  func copying(offset:SpatialPoint,address:NotebookToolAddress) throws -> Self {
    let ids=Set(selected.map(\.elementID))
    let objects=working.filter { ids.contains($0.id) }.map { object in
      let old=object.graphic
      let graphic=NotebookGraphic(shape:old.shape,style:old.style,label:old.label,
        representation:old.representation,visible:old.visible,connection:old.connection,
        vertices:old.vertices,cornerRadius:old.cornerRadius,freehand:old.freehand,
        transform:old.transform,path:old.path,mask:old.mask)
      return NotebookWorkingGraphic(id:object.strokeID,surface:object.surface,
        frame:.init(x:object.frame.x+offset.x,y:object.frame.y+offset.y,width:object.frame.width,height:object.frame.height),
        worldOrigin:object.worldOrigin,graphic:graphic,basis:object.basis)
    }
    return .init(edits:try objects.map { .init(reference:address.reference($0.id),kind:.insertElement,values:try $0.authoredValues()) },
      working:objects,selected:selected,sources:sources)
  }

  func deleting() throws -> Self {
    let ids=Set(selected.map(\.elementID))
    var objects=working.filter { !ids.contains($0.id) }
    var operations=edits.filter { !ids.contains($0.reference.elementID) }
    if let conversion=edits.first(where:{ $0.kind == .convertInkToElement }),
      let claimant=working.first(where:{ $0.id == conversion.reference.elementID }) {
      // The surviving outside becomes the sole claimant of the raw ink. If
      // nothing survives, an empty coverage relation retains that undo identity.
      let remainder=objects.first { $0.graphic.freehand != nil }
      let original=remainder ?? claimant,old=original.graphic
      let empty=NotebookGraphicMask().appending(.subtract,polygon:[.zero,.init(x:1,y:0),.init(x:1,y:1),.init(x:0,y:1)])
      let graphic=NotebookGraphic(shape:old.shape,style:old.style,label:old.label,
        sourceInkIDs:claimant.graphic.sourceInkIDs,connection:old.connection,vertices:old.vertices,
        cornerRadius:old.cornerRadius,freehand:old.freehand,transform:old.transform,path:old.path,
        mask:remainder == nil ? empty : old.mask)
      let object=NotebookWorkingGraphic(id:original.strokeID,surface:original.surface,frame:original.frame,
        worldOrigin:original.worldOrigin,graphic:graphic,basis:original.basis)
      let ref:EditableElementReference
      switch conversion.reference {
      case .page(let owner,_): ref = .page(pageID:owner,elementID:object.id)
      case .spatial(let owner,_): ref = .spatial(boardID:owner,elementID:object.id)
      }
      objects.removeAll { $0.id == object.id };objects.append(object)
      operations.removeAll { $0.reference == ref }
      operations.append(.init(reference:ref,kind:.convertInkToElement,values:try object.authoredValues()))
    }
    return .init(edits:operations,working:objects,selected:[],sources:sources)
  }

}

extension NotebookAppModel {
  func regionSourceSnapshot(_ address:NotebookToolAddress) -> NotebookRegionSourceSnapshot {
    .init(page:address.surface.kind == .page ? address.surface.ownerID.flatMap { pages[$0] } : nil,
      board:address.surface.kind == .page ? nil : (address.boardID ?? address.surface.ownerID).flatMap { boardHierarchy?.board($0) })
  }

  func regionIsCurrent(_ region:NotebookRegionSelection) -> Bool {
    guard let prepared=region.materialization else { return false }
    if let expected=region.expectedInkRevision {
      let current=region.address.surface.kind == .page
        ? region.address.surface.ownerID.flatMap { pages[$0]?.drawingStamp.revision }
        : spatialInk?.stamp.revision
      guard current == expected else { return false }
    }
    return prepared.sources.allSatisfy { nativeElementSource($0.key) == $0.value && elementCommandDrafts[$0.key] == nil }
  }

  @discardableResult
  func commitRegion(_ region:NotebookRegionSelection,prepared:NotebookRegionMaterialization,summary:String) -> Bool {
    guard regionIsCurrent(region) else { showCue(staleRegion().localizedDescription);return false }
    acceptWorkingGraphics(prepared.working)
    guard performElementOperations(prepared.edits,summary:summary,readSources:Array(prepared.sources.keys),
      insertionTarget:region.address.target,expectedInkRevision:region.expectedInkRevision,
      frozenSources:prepared.sources) else {
      let ids=Set(prepared.working.map(\.id));removeWorkingGraphics { ids.contains($0.id) };return false
    }
    selectElements(prepared.selected);return true
  }

  func transformRegion(_ region:NotebookRegionSelection,radians:Double,scale:Double) {
    guard radians.isFinite,scale.isFinite,scale>0,let prepared=region.materialization else { return }
    let f=region.frame,center=CGPoint(x:f.x+f.width/2,y:f.y+f.height/2)
    let change=CGAffineTransform(translationX:-center.x,y:-center.y)
      .concatenating(.init(rotationAngle:radians)).concatenating(.init(scaleX:scale,y:scale))
      .concatenating(.init(translationX:center.x,y:center.y))
    if let bounds=region.address.bounds,region.polygon.contains(where:{ !bounds.contains(CGPoint(x:$0.x,y:$0.y).applying(change)) }) {
      showCue("Для этого поворота или масштаба не хватает места на листе.");return
    }
    do { _ = commitRegion(region,prepared:try prepared.transformed(by:change,address:region.address),
      summary:radians == 0 ? "Масштабировать область лассо" : "Повернуть область лассо") }
    catch { showCue(error.localizedDescription) }
  }

  func updateRegionPreview(_ contact:NotebookElementManipulation) {
    guard let region=contact.region,let prepared=try? region.materialization?.transformed(from:region.frame,to:contact.frame,address:region.address) else { return }
    for object in prepared.working { updateWorkingGraphic(object,strokeID:object.strokeID) }
  }
}
