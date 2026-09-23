import CoreGraphics
import Foundation
import NotebookCore

/// A cheap immutable document cut. Only the selected sources and their bases
/// survive preparation; a later edit never silently borrows today's revision.
struct NotebookRegionSourceSnapshot: Sendable {
  let page: PageDocument?
  let board: BoardDocument?
  var accepted:[EditableElementReference:NotebookNativeElementSource] = [:]
  var appended:[String] = []
  var dependencies:[EditableElementReference:NotebookElementCommand] = [:]

  func orderedGraphics(for region:NotebookRegionSelection) throws -> [EditableElementReference] {
    let ids=Set(region.graphics.map(\.elementID))
    var ordered=page?.interactionElements(ids:ids).map(\.id)
      ?? board?.interactionElements(ids:ids).map(\.id) ?? []
    let known=Set(ordered)
    ordered += appended.filter { ids.contains($0) && !known.contains($0) }
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
        let value=accepted[ref] ?? NotebookNativeElementSource(target:region.address.target,id:id,
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
    let objects=try placedWorking(by:change,address:address)
    let ids=Set(selected.map(\.elementID))
    let poses=Dictionary(uniqueKeysWithValues:objects.filter { ids.contains($0.id) }.map { ($0.id,$0) })
    let changed=try edits.map { edit -> NotebookElementEdit in
      guard let object=poses[edit.reference.elementID] else { return edit }
      var values=edit.values
      values["frame"]=try .encode(object.frame)
      values["basis"]=try object.basis.map(JSONValue.encode)
      // Only lift constructs the command; movement never serializes it.
      return .init(reference:edit.reference,kind:edit.kind,values:values)
    }
    return .init(edits:changed,working:objects,selected:selected,sources:sources,outside:outside,dependencies:dependencies)
  }

  func placedWorking(by change:CGAffineTransform,address:NotebookToolAddress) throws -> [NotebookWorkingGraphic] {
    let ids=Set(selected.map(\.elementID))
    return try working.map { object -> NotebookWorkingGraphic in
      guard ids.contains(object.id) else { return object }
      let delta=(address.worldOrigin ?? .zero).delta(to:object.worldOrigin ?? .zero)
      let local=CGAffineTransform(translationX:delta.x,y:delta.y).concatenating(change)
        .concatenating(.init(translationX:-delta.x,y:-delta.y))
      let pose=try object.node.placement.applyingSurfaceTransform(local)
      return .init(id:object.strokeID,surface:object.surface,frame:pose.frame,
        worldOrigin:object.worldOrigin,graphic:object.graphic,basis:pose.basis)
    }
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
      working:objects,selected:selected,sources:sources,dependencies:dependencies)
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
    return .init(edits:operations,working:objects,selected:[],sources:sources,outside:outside,dependencies:dependencies)
  }

}

extension NotebookAppModel {
  func regionSourceSnapshot(_ address:NotebookToolAddress) -> NotebookRegionSourceSnapshot {
    let working=pendingModelGraphics.filter { $0.surface == address.surface }
    var accepted:[EditableElementReference:NotebookNativeElementSource]=[:]
    let refs=Set(working.map { address.reference($0.id) }).union(elementCommandDrafts.keys)
    for ref in refs {
      if let source=acceptedElementSource(ref),source.target == address.target { accepted[ref]=source }
    }
    return .init(page:address.surface.kind == .page ? address.surface.ownerID.flatMap { pages[$0] } : nil,
      board:address.surface.kind == .page ? nil : (address.boardID ?? address.surface.ownerID).flatMap { boardHierarchy?.board($0) },
      accepted:accepted,appended:working.map(\.id),dependencies:elementCommandSources.filter { accepted[$0.key] != nil })
  }

  func regionIsCurrent(_ region:NotebookRegionSelection) -> Bool {
    guard let prepared=region.materialization else { return false }
    if let expected=region.expectedInkRevision {
      let current=region.address.surface.kind == .page
        ? region.address.surface.ownerID.flatMap { pages[$0]?.drawingStamp.revision }
        : spatialInk?.stamp.revision
      guard current == expected else { return false }
    }
    return prepared.sources.allSatisfy { reference,source in
      guard let current=acceptedElementSource(reference) else { return false }
      if let dependency=prepared.dependencies[reference] {
        if let active=elementCommandSources[reference],active.id != dependency.id { return false }
        // An own predecessor may publish a newer spatial stamp while this
        // immutable read is prepared. Its exact receipt is checked by storage.
        return source.target == current.target && source.page == current.page
          && (source.spatial.map { value in
            guard let next=current.spatial else { return false }
            return value.frame == next.frame && value.worldOrigin == next.worldOrigin
              && value.graphic == next.graphic && value.parentID == next.parentID && value.basis == next.basis
              && value.kind == next.kind && value.source == next.source && value.html == next.html
              && value.css == next.css && value.javaScript == next.javaScript && value.programPackage == next.programPackage
              && value.state == next.state && value.textStyle == next.textStyle && value.surface == next.surface
          } ?? (current.spatial == nil))
      }
      return current == source && elementCommandSources[reference] == nil
    }
  }

  @discardableResult
  func commitRegion(_ region:NotebookRegionSelection,prepared:NotebookRegionMaterialization,summary:String) -> Bool {
    guard let plan=prepareRegionCommand(region,prepared:prepared,summary:summary) else { return false }
    enqueueElementCommand(target:plan.target,ready:plan)
    selectElements(prepared.selected);return true
  }

  private func prepareRegionCommand(_ region:NotebookRegionSelection,prepared:NotebookRegionMaterialization,
    summary:String,alreadyAccepted:Bool = false)->NotebookElementCommandPlan? {
    // A finished contact keeps its captured preconditions in the FIFO. New
    // live input may advance the UI meanwhile, never its frozen storage basis.
    guard alreadyAccepted || regionIsCurrent(region) else { showCue(staleRegion().localizedDescription);return nil }
    guard let plan=prepareElementOperations(prepared.edits,summary:summary,readSources:Array(prepared.sources.keys),
      insertionTarget:region.address.target,expectedInkRevision:region.expectedInkRevision,
      frozenSources:prepared.sources,frozenDependencies:prepared.dependencies,
      preparedGraphics:Dictionary(uniqueKeysWithValues:prepared.outside.map { (region.address.reference($0.key),$0.value) })) else { return nil }
    acceptWorkingGraphics(prepared.working)
    return plan
  }

  /// The finger ended, not the choice. The existing causal queue takes over
  /// even if preparation, another selection and persistence finish later.
  func acceptPreparingRegion(_ contact:NotebookElementManipulation)->Bool {
    guard let region=contact.region,let preparation=region.preparation else { return false }
    preparation.claimed=true
    cancelElementManipulation(contact.id)
    let resolved=Task { () throws -> (NotebookRegionSelection,NotebookRegionMaterialization) in
      guard let source=try await preparation.task.value,let material=source.materialization else {
        throw CollaborationError("empty_selection","В обведённой области нет материала для переноса.")
      }
      try Task.checkCancellation()
      return (source,try material.transformed(from:source.frame,to:contact.frame,address:source.address))
    }
    let plan=Task { [weak self] () throws -> NotebookElementCommandPlan in
      let (source,material)=try await resolved.value
      try Task.checkCancellation()
      guard let self,let plan=prepareRegionCommand(source,prepared:material,
        summary:contact.kind == .move ? "Переместить область лассо" : "Изменить размер области лассо",alreadyAccepted:true) else { throw staleRegion() }
      return plan
    }
    let batch=enqueueElementCommand(target:region.address.target,preparing:plan)
    let admission=Task { [weak self] in
      _ = try? await batch.prepared()
      if self?.pendingMaterialAdmissions[region.address.surface]?.id == batch.id { self?.pendingMaterialAdmissions[region.address.surface]=nil }
    }
    pendingMaterialAdmissions[region.address.surface]=(batch.id,admission)

    // Keep an immediate movable contour. A second lift can chain another
    // placement while the first is preparing; it does not split the source twice.
    let f=region.frame,end=contact.frame
    let change=CGAffineTransform(translationX:-f.x,y:-f.y)
      .concatenating(.init(scaleX:end.width/f.width,y:end.height/f.height))
      .concatenating(.init(translationX:end.minX,y:end.minY))
    let polygon=region.polygon.map { p in
      let p=CGPoint(x:p.x,y:p.y).applying(change);return SpatialPoint(x:p.x,y:p.y)
    }
    var next=NotebookRegionSelection(id:UUID(),address:region.address,polygon:polygon,
      frame:.init(x:end.minX,y:end.minY,width:end.width,height:end.height),rawInk:nil,
      expectedInkRevision:nil,graphics:[])
    next.editingExisting=true
    let continuation=next
    next.preparation=NotebookRegionPreparation(Task { [weak self] in
      _ = try await batch.prepared()
      let (_,material)=try await resolved.value
      guard let self else { throw CancellationError() }
      let ids=Set(material.selected.map(\.elementID)),working=material.working.filter { ids.contains($0.id) }
      var sources:[EditableElementReference:NotebookNativeElementSource]=[:]
      var dependencies:[EditableElementReference:NotebookElementCommand]=[:]
      let edits=try working.map { object -> NotebookElementEdit in
        let ref=region.address.reference(object.id)
        guard let source=acceptedElementSource(ref) else { throw staleRegion() }
        sources[ref]=source;dependencies[ref]=elementCommandSources[ref]
        return .init(reference:ref,kind:.updateElement,
          values:["frame":try .encode(object.frame),"basis":try object.basis.map(JSONValue.encode) ?? .null])
      }
      var ready=continuation
      ready.materialization = .init(edits:edits,working:working,selected:material.selected,sources:sources,dependencies:dependencies)
      return ready
    })
    selectRegion(next)
    let focus=selectionSession.id,future=next.preparation!.task
    Task { [weak self] in
      do {
        guard let ready=try await future.value,let self,selectionSession.id == focus else { return }
        resolveRegionPreparation(ready)
      } catch {
        if let self,selectionSession.id == focus { clearSelection() }
        // The command reports its own failure exactly once.
      }
    }
    return true
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
    guard let region=contact.region,let material=region.materialization else { return }
    let f=region.frame,frame=contact.frame
    let change=CGAffineTransform(translationX:-f.x,y:-f.y)
      .concatenating(.init(scaleX:frame.width/f.width,y:frame.height/f.height))
      .concatenating(.init(translationX:frame.minX,y:frame.minY))
    guard let working=try? material.placedWorking(by:change,address:region.address) else { return }
    let selected=Set(material.selected.map(\.elementID))
    if selectionSession.manipulation?.id == contact.id {
      updateRegionPoses(contact.id,poses:Dictionary(uniqueKeysWithValues:working.filter { selected.contains($0.id) }.map {
        ($0.id,NotebookElementPlacement.Source(frame:$0.frame,origin:$0.worldOrigin ?? .zero,basis:$0.basis))
      }))
    }
    updateWorkingGraphics(working)
  }
}
