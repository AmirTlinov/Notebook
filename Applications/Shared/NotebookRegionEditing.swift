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
    try sources(for:region.graphics,graph:graph)
  }

  func sources(for references:[EditableElementReference],graph:NotebookGraphicGraph) throws
    -> [EditableElementReference:NotebookNativeElementSource] {
    var result:[EditableElementReference:NotebookNativeElementSource]=[:]
    for reference in references {
      guard let placement=graph.placement(reference.elementID) else { throw staleRegion() }
      for id in [reference.elementID]+placement.ancestors {
        let ref:EditableElementReference,target:CollaborationTarget
        switch reference {
        case .page(let owner,_): ref = .page(pageID:owner,elementID:id);target = .init(kind:.page,id:owner)
        case .spatial(let owner,_):
          ref = .spatial(boardID:owner,elementID:id)
          guard let surface=accepted[ref]?.spatial?.surface ?? board?.element(id:id)?.surface,
            let surfaceID=surface.ownerID else { throw staleRegion() }
          target = .init(kind:surface.kind == .cover ? .cover : .board,id:surfaceID,
            boardID:surface.kind == .cover ? owner : nil)
        }
        guard result[ref] == nil else { continue }
        let value=accepted[ref] ?? NotebookNativeElementSource(target:target,id:id,
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
    return .init(edits:edits,working:objects,selected:selected,sources:sources,outside:outside,dependencies:dependencies)
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
    return .init(edits:objects.map { .create(address.reference($0.id),convertsInk:false) },
      working:objects,selected:selected,sources:sources,dependencies:dependencies)
  }

  func deleting() -> Self {
    let ids=Set(selected.map(\.elementID))
    var objects=working.filter { !ids.contains($0.id) }
    var operations=edits.compactMap { edit -> Edit? in
      guard ids.contains(edit.reference.elementID) else { return edit }
      // A continued cut now names an accepted element. Delete addresses that
      // element, while an uncreated fragment simply leaves the creation plan.
      if case .placement(let reference)=edit { return .remove(reference) }
      return nil
    }
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
      operations.append(.create(ref,convertsInk:true))
    }
    return .init(edits:operations,working:objects,selected:[],sources:sources,outside:outside,dependencies:dependencies)
  }

  /// The existing command FIFO owns this conversion after acceptance. The
  /// drawing/selection path carries these same immutable values without JSON.
  func encodedEdits() throws -> [NotebookElementEdit] {
    let objects=Dictionary(uniqueKeysWithValues:working.map { ($0.id,$0) })
    return try edits.map { edit in
      try Task.checkCancellation()
      let values:[String:JSONValue]
      switch edit {
      case .create:
        guard let object=objects[edit.reference.elementID] else { throw staleRegion() }
        values=try object.authoredValues()
      case .remainder(_,let mask):
        values=["graphic":.object(["mask":try .encode(mask)])]
      case .placement:
        guard let object=objects[edit.reference.elementID] else { throw staleRegion() }
        values=["frame":try .encode(object.frame),"basis":try object.basis.map(JSONValue.encode) ?? .null]
      case .remove: values=[:]
      }
      return .init(reference:edit.reference,kind:edit.kind,values:values)
    }
  }

  func commandSources(at address:NotebookToolAddress) -> [EditableElementReference:NotebookNativeElementSource] {
    var result=sources
    for edit in edits where edit.kind == .insertElement || edit.kind == .convertInkToElement {
      result[edit.reference] = .init(target:address.target,id:edit.reference.elementID)
    }
    return result
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
    return selectionSourcesAreCurrent(prepared.sources,dependencies:prepared.dependencies)
  }

  func selectionSourcesAreCurrent(_ sources:[EditableElementReference:NotebookNativeElementSource],
    dependencies:[EditableElementReference:NotebookElementCommand]) -> Bool {
    sources.allSatisfy { reference,source in
      guard let current=acceptedElementSource(reference) else { return false }
      if let dependency=dependencies[reference] {
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

  private enum RegionChange: Sendable {
    case prepared(NotebookRegionMaterialization)
    case placement(CGRect)
    case deletion

    func applying(to region:NotebookRegionSelection) throws -> NotebookRegionMaterialization {
      switch self {
      case .prepared(let material): return material
      case .placement(let frame):
        guard let material=region.materialization else { throw staleRegion() }
        return try material.transformed(from:region.frame,to:frame,address:region.address)
      case .deletion:
        guard let material=region.materialization else { throw staleRegion() }
        return material.deleting()
      }
    }
  }

  @discardableResult
  func commitRegion(_ region:NotebookRegionSelection,prepared:NotebookRegionMaterialization,summary:String) -> Bool {
    acceptRegionCommand(region,change:.prepared(prepared),summary:summary)
  }

  @discardableResult
  func placeRegion(_ region:NotebookRegionSelection,in frame:CGRect,summary:String)->Bool {
    acceptRegionCommand(region,change:.placement(frame),summary:summary)
  }

  func deleteRegion(_ region:NotebookRegionSelection) {
    _ = acceptRegionCommand(region,change:.deletion,summary:"Удалить область лассо")
  }

  /// Both ready and still-preparing regions reserve the same causal writer at
  /// acceptance. The typed material becomes visible before its JSON is built.
  private func acceptRegionCommand(_ region:NotebookRegionSelection,change:RegionChange,summary:String)->Bool {
    guard let reservation=reserveElementPreparation() else { return false }
    var transferred=false
    defer { if !transferred { releaseElementPreparation(reservation) } }
    let ready:NotebookRegionMaterialization?
    do {
      if region.materialization != nil {
        guard regionIsCurrent(region) else { showCue(staleRegion().localizedDescription);return false }
        ready=try change.applying(to:region)
      } else {
        guard region.preparation != nil else { return false }
        ready=nil
      }
    } catch { showCue(error.localizedDescription);return false }
    region.preparation?.claimed=true
    let future=region.preparation?.task,batch=NotebookElementCommandBatch()
    let resolved=Task.detached(priority:.userInitiated) { () throws -> (NotebookRegionSelection,NotebookRegionMaterialization) in
      if let ready { return (region,ready) }
      guard let source=try await future?.value,
        source.id == region.id,source.address == region.address,source.polygon == region.polygon,
        source.frame == region.frame,source.materialization != nil else {
        throw CollaborationError("empty_selection","В обведённой области нет материала для изменения.")
      }
      try Task.checkCancellation()
      return (source,try change.applying(to:source))
    }
    let admitted=Task { [weak self] () throws -> (NotebookRegionSelection,NotebookRegionMaterialization) in
      let (source,material)=try await resolved.value
      try Task.checkCancellation()
      guard let self else { throw CancellationError() }
      if ready == nil { admitRegionMaterial(material,batch:batch) }
      return (source,material)
    }
    let plan=Task { [weak self] () throws -> NotebookElementCommandPlan in
      let (source,material)=try await admitted.value
      let encoding=Task.detached(priority:.userInitiated) { try material.encodedEdits() }
      let edits=try await withTaskCancellationHandler { try await encoding.value } onCancel:{ encoding.cancel() }
      try Task.checkCancellation()
      guard let self,var plan=prepareElementOperations(edits,summary:summary,
        readSources:Array(material.sources.keys),insertionTarget:source.address.target,
        expectedInkRevision:source.expectedInkRevision,previews:false,
        frozenSources:material.commandSources(at:source.address),frozenDependencies:material.dependencies) else { throw staleRegion() }
      plan.working=material.working
      return plan
    }
    guard enqueueElementCommand(target:region.address.target,preparing:plan,batch:batch,reservation:reservation) != nil else {
      plan.cancel();admitted.cancel();resolved.cancel()
      Task { [self] in
        _ = await plan.result;_ = await admitted.result;_ = await resolved.result
        releaseElementPreparation(reservation)
      }
      transferred=true
      return false
    }
    transferred=true
    if let ready { admitRegionMaterial(ready,batch:batch) }
    let admission=Task { [weak self] in
      _ = try? await admitted.value
      if self?.pendingMaterialAdmissions[region.address.surface]?.id == batch.id {
        self?.pendingMaterialAdmissions[region.address.surface]=nil
      }
    }
    pendingMaterialAdmissions[region.address.surface]=(batch.id,admission)
    if case .deletion=change { clearSelection() }
    else if let ready { selectElements(ready.selected) }
    else if case .placement(let frame)=change { continueRegion(region,in:frame,after:admitted) }
    return true
  }

  /// The accepted typed values own immediate scene projection. Encoding a
  /// large measured source cannot delay its pose or recapture a newer edit.
  private func admitRegionMaterial(_ material:NotebookRegionMaterialization,
    batch:NotebookElementCommandBatch) {
    let objects=Dictionary(uniqueKeysWithValues:material.working.map { ($0.id,$0) })
    for edit in material.edits {
      registerElementCommand(edit.reference,batch:batch)
      guard var pose=material.sources[edit.reference]?.placementSource else { continue }
      var graphic=material.sources[edit.reference]?.page?.graphic ?? material.sources[edit.reference]?.spatial?.graphic
      var removed=false
      switch edit {
      case .remainder(_,let mask): graphic?.mask=mask
      case .placement:
        guard let object=objects[edit.reference.elementID] else { continue }
        pose.frame=object.frame;pose.basis=object.basis;graphic=object.graphic
      case .remove: removed=true;graphic?.visible=false
      case .create: continue
      }
      elementCommandDrafts[edit.reference] = .init(source:pose,graphic:graphic,removed:removed)
    }
    acceptWorkingGraphics(material.working)
    didChangeElementCommandProjection()
  }

  /// A second lift or Delete may address the accepted fragment before either
  /// material preparation or SQLite finishes, without splitting its source again.
  private func continueRegion(_ region:NotebookRegionSelection,in end:CGRect,
    after admitted:Task<(NotebookRegionSelection,NotebookRegionMaterialization),Error>) {
    let f=region.frame
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
      let (_,material)=try await admitted.value
      guard let self else { throw CancellationError() }
      let ids=Set(material.selected.map(\.elementID)),working=material.working.filter { ids.contains($0.id) }
      var sources:[EditableElementReference:NotebookNativeElementSource]=[:]
      var dependencies:[EditableElementReference:NotebookElementCommand]=[:]
      let edits=try working.map { object -> NotebookRegionMaterialization.Edit in
        let ref=region.address.reference(object.id)
        guard let source=acceptedElementSource(ref) else { throw staleRegion() }
        sources[ref]=source;dependencies[ref]=elementCommandSources[ref]
        return .placement(ref)
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
