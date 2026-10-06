import CoreGraphics
import Foundation
import NotebookCore

/// A finite export of the selected material. It never writes the source or
/// reads the system clipboard. Live rendering and selection keep their owners.
extension NotebookAppModel {
  /// Menu eligibility only captures bounded metadata; it never serializes source bodies.
  var canExportSelection: Bool {
    selectionSession.items.isEmpty && selectionSession.count > 0 && !selectionSession.isInteractive
      && selectionSession.count <= 32
  }

  func clipboardSelectionSnapshot() throws -> NotebookSelectionExport {
    let work=try beginClipboardWork()
    let source=try selectionExportSource()
    let selectionID=selectionSession.id,revision=selectionInkRevision(source.surface)
    let erasures=elementErasures(on:source.surface)
    let checks:[EditableElementReference:NotebookNativeElementSource]
    if let region=selectionSession.region,let material=region.materialization { checks=material.sources }
    else {
      // The exported pose includes its ancestors, not only the child's own
      // frame. A parent edit during preparation must also revoke a late Cut.
      let rawIDs=Set(selectionSession.ink.map(\.memberID))
      var ids=Set(source.sources.map(\.id)).subtracting(rawIDs)
      for element in source.sources where !rawIDs.contains(element.id) {
        ids.formUnion(source.graph.placement(element.id)?.ancestors ?? [])
      }
      let board=selectionSession.elements.first.map { reference -> UUID in
        if case .spatial(let board,_) = reference { return board };return source.surface.ownerID!
      } ?? selectionSession.ink.first?.address.boardID ?? source.surface.ownerID!
      var captured:[EditableElementReference:NotebookNativeElementSource]=[:]
      for id in ids {
        let reference:EditableElementReference = source.surface.kind == .page
          ? .page(pageID:source.surface.ownerID!,elementID:id) : .spatial(boardID:board,elementID:id)
        guard let value=nativeElementSource(reference),elementCommandDrafts[reference] == nil else {
          throw CollaborationError("selection_not_ready","Выделение изменилось или ещё готовится. Повторите действие.")
        }
        captured[reference]=value
      }
      checks=captured
    }
    var keys:[String:NotebookInkPaintKey]=[:]
    for raw in selectionSession.ink {
      if source.surface.kind == .page { keys[raw.memberID] = .page(sequence:raw.painterOrder.counter,id:raw.actionID) }
      else {
        guard let actor=UUID(uuidString:raw.painterOrder.actor) else {
          throw CollaborationError("selection_not_ready","Порядок рукописи ещё не готов.")
        }
        keys[raw.memberID] = .spatial(stamp:.init(counter:raw.painterOrder.counter,actor:actor),id:raw.actionID)
      }
    }
    if selectionSession.region != nil,source.surface.kind == .page {
      let pending=source.sources.filter { keys[$0.id] == nil && $0.graphic?.sourceInkContactID != nil }
      if !pending.isEmpty {
        // Borrow only addressed headers from this already prepared page cut.
        // The export retains scalar keys rather than the drawing/source root.
        guard let revision,let pageID=source.surface.ownerID,let page=pages[pageID],
          page.drawingStamp.revision == revision,let drawing=page.preparedInkDrawing else {
          throw CollaborationError("selection_not_ready","Порядок рукописи ещё не готов.")
        }
        for element in pending {
          guard let id=element.graphic?.sourceInkContactID,let action=drawing.action(id:id),
            action.id == id,action.tool == .pen,action.sequence > 0 else {
            throw CollaborationError("selection_not_ready","Порядок рукописи ещё не готов.")
          }
          keys[element.id] = .page(sequence:action.sequence,id:id)
        }
      }
    } else if source.surface.kind != .page {
      for element in source.sources {
        guard let id=element.graphic?.sourceInkContactID,keys[element.id] == nil else {continue}
        guard let header=spatialInkHistoryStates[id],header.surfaces.contains(source.surface) else {
          throw CollaborationError("selection_not_ready","Порядок рукописи ещё не готов.")
        }
        keys[element.id] = .spatial(stamp:header.result.creationStamp,id:id)
      }
    }
    let transfer:Task<NotebookElementTransfer,Error>?
    if selectionSession.region == nil,!selectionSession.elements.isEmpty {
      let roots=selectionSession.elements.map(\.elementID),observed=Array(checks.values)
      let target=observed.first!.target
      transfer=Task {
        defer { withExtendedLifetime(work) {} }
        return try await readClipboardTransfer(target:target,rootIDs:roots,observedSources:observed,inkRevision:revision)
      }
    } else { transfer=nil }
    return .init(selectionID:selectionID,surface:source.surface,
      inkRevision:revision,sourceChecks:checks,
      sources:source.sources,graph:transfer == nil ? source.graph : .init(selectionSession.ink.map { $0.working.node }),rootOrigin:source.rootOrigin,
      erasures:erasures,inkKeys:keys,
      transfer:transfer,rawInk:selectionSession.ink,observedChecks:checks,workLease:work)
  }

  func selectionStillMatches(_ snapshot:NotebookSelectionExport) -> Bool {
    guard selectionSession.id == snapshot.selectionID,selectionSession.count > 0,!selectionSession.isInteractive,
      selectionInkRevision(snapshot.surface) == snapshot.inkRevision else { return false }
    if let region=selectionSession.region { return regionIsCurrent(region) }
    return snapshot.observedChecks.allSatisfy { nativeElementSource($0.key) == $0.value && elementCommandDrafts[$0.key] == nil }
      && snapshot.sourceChecks.keys.allSatisfy { elementCommandDrafts[$0] == nil }
  }

  func selectionInkIsCurrent(_ raw:NotebookSelectedInk)->Bool {
    guard let readSet=raw.readSet else {return false}
    if raw.address.surface.kind == .page,let pageID=raw.address.surface.ownerID,let page=pages[pageID] {
      return readSet.matches(page.inkSource,suppressed:page.graphicPresentation.suppressedInkIDs)
    }
    guard let journal=spatialInk else {return false}
    return readSet.matches(journal,suppressed:compositionTiles.published?.liveData.suppressedInkIDs ?? [])
  }

  func selectionInkRevision(_ surface:SurfaceID) -> String? {
    surface.kind == .page ? surface.ownerID.flatMap { pages[$0]?.drawingStamp.revision } : spatialInk?.stamp.revision
  }

  /// Duplication shares the same bounded export and ordinary addressed writer.
  /// Native graphic contacts retain their causal copy operation; text, programs
  /// and whole groups use the same element transaction, never the clipboard.
  func duplicateSelectedContent() {
    if !selectionSession.ink.isEmpty || selectionContainsSourceAnchoredInk { duplicateMeasuredSelection();return }
    if selectionSession.region != nil {
      duplicateGraphicMaterial(); return
    }
    guard selectionSession.items.isEmpty,let first=selectionSession.elements.first,
      let target=nativeElementSource(first)?.target else { return }
    do {
      let snapshot=try clipboardSelectionSnapshot(),bounds=elementGeometry(first)?.bounds
      let preparation=Task.detached(priority:.userInitiated) {
        let material=try await snapshot.materialized(),exported=try material.prepare()
        let fragment=try exported.fragment.reidentified()
        let offset=SpatialPoint(x:exported.minimum.x+min(24,max(0,bounds.map { $0.maxX-exported.minimum.x-fragment.size.x } ?? 24)),
          y:exported.minimum.y+min(24,max(0,bounds.map { $0.maxY-exported.minimum.y-fragment.size.y } ?? 24)))
        let operations=try fragment.operations(target:target,offset:offset,
          worldOrigin:target.kind == .board ? exported.worldOrigin : nil)
        var sources=material.sourceChecks
        func reference(_ id:String)->EditableElementReference {
          switch first { case .page(let owner,_): .page(pageID:owner,elementID:id)
            case .spatial(let owner,_): .spatial(boardID:owner,elementID:id) }
        }
        let edits=operations.map { operation in
          let ref=reference(operation.id!);sources[ref] = .init(target:target,id:operation.id!)
          return NotebookElementEdit(reference:ref,kind:operation.kind,values:operation.values)
        }
        guard sources.count<=64 else { throw CollaborationError("selection_limit","У копии слишком много связанных исходников.") }
        let copied=Dictionary(uniqueKeysWithValues:zip(fragment.elements,exported.fragment.elements).map { ($0.id,$1.id) })
        return (edits,sources,fragment.elements.filter { $0.parentID == nil }.map { reference($0.id) },copied,
          material.transferWitness,try fragment.prepareProgramResources())
      }
      let plan=Task { [weak self] () throws -> NotebookElementCommandPlan in
        let result=try await preparation.value
        guard let self,var plan=prepareElementOperations(result.0,summary:"Дублировать содержимое",
          readSources:Array(result.1.keys),copiedFrom:result.3,insertionTarget:target,
          expectedInkRevision:snapshot.inkRevision,frozenSources:result.1) else {
          throw CollaborationError("revision_conflict","Не удалось подготовить всё выделение.")
        }
        plan.transferWitness=result.4
        plan.retainedProgramResources=result.5
        return plan
      }
      guard let batch=enqueueElementCommand(target:target,preparing:plan,reservation:snapshot.workLease?.reservation) else {
        preparation.cancel();plan.cancel()
        Task { _ = try? await preparation.value;_ = try? await plan.value;snapshot.workLease?.finish() }
        return
      }
      Task { [weak self] in
        do {
          _ = try await batch.prepared()
          let result=try await preparation.value
          if let self,selectionSession.id == snapshot.selectionID { selectElements(result.2) }
        } catch { /* The accepted command reports its failure. */ }
      }
    } catch { showCue(error.localizedDescription) }
  }

  /// Copies never convert the original contacts. Their immutable export and
  /// exact source checks enter the same addressed command FIFO as every edit.
  func duplicateMeasuredSelection() {
    guard selectionSession.items.isEmpty else {return}
    do {
      let snapshot=try clipboardSelectionSnapshot(),namespace=UUID()
      let address:NotebookToolAddress
      if let raw=selectionSession.ink.first {address=raw.address}
      else {
        guard let first=selectionSession.elements.first,let target=nativeElementSource(first)?.target else {return}
        address = .init(surface:snapshot.surface,boardID:target.kind == .page ? nil : target.boardID ?? target.id,
          worldOrigin:target.kind == .board ? snapshot.rootOrigin : nil,bounds:elementGeometry(first)?.bounds)
      }
      let preparation=Task.detached(priority:.userInitiated) {
        let material=try await snapshot.materialized(),exported=try material.prepare()
        let fragment=try exported.fragment.reidentified(namespace:namespace)
        let offset=SpatialPoint(x:exported.minimum.x+min(24,max(0,address.bounds.map { $0.maxX-exported.minimum.x-fragment.size.x } ?? 24)),
          y:exported.minimum.y+min(24,max(0,address.bounds.map { $0.maxY-exported.minimum.y-fragment.size.y } ?? 24)))
        let operations=try fragment.operations(target:address.target,offset:offset,
          worldOrigin:address.target.kind == .board ? exported.worldOrigin : nil)
        var sources=material.sourceChecks
        let edits=operations.map { operation -> NotebookElementEdit in
          let reference=address.reference(operation.id!)
          sources[reference] = .init(target:address.target,id:operation.id!)
          return .init(reference:reference,kind:operation.kind,values:operation.values)
        }
        guard sources.count<=64 else { throw CollaborationError("selection_limit","У копии слишком много связанных исходников.") }
        let selected=fragment.elements.filter { $0.parentID == nil }.map { address.reference($0.id) }
        return (edits,sources,selected,material.transferWitness,try fragment.prepareProgramResources())
      }
      let plan=Task { [weak self] () throws -> NotebookElementCommandPlan in
        let result=try await preparation.value
        guard let self,var plan=prepareElementOperations(result.0,summary:"Дублировать выделенное",
          readSources:Array(result.1.keys),insertionTarget:address.target,expectedInkRevision:snapshot.inkRevision,
          frozenSources:result.1) else {
          throw CollaborationError("revision_conflict","Не удалось подготовить всё выделение.")
        }
        plan.transferWitness=result.3
        plan.retainedProgramResources=result.4
        return plan
      }
      guard let batch=enqueueElementCommand(target:address.target,preparing:plan,reservation:snapshot.workLease?.reservation) else {
        preparation.cancel();plan.cancel()
        Task { _ = try? await preparation.value;_ = try? await plan.value;snapshot.workLease?.finish() }
        return
      }
      Task { [weak self] in
        do {
          _ = try await batch.prepared()
          let result=try await preparation.value
          if let self,selectionSession.id == snapshot.selectionID { selectElements(result.2) }
        } catch { /* The existing command reports the failure. */ }
      }
    } catch { showCue(error.localizedDescription) }
  }

  func cutExportedSelection(_ snapshot:NotebookSelectionExport) {
    guard selectionStillMatches(snapshot) else { showCue("Выделение изменилось. Повторите вырезание.");return }
    guard let witness=snapshot.transferWitness,snapshot.rawInk.isEmpty else {
      if let work=snapshot.workLease {
        // Both source and encoder workers have completed before Cut reaches
        // here. Make their credit immediately available to the delete owner.
        work.finish();releaseClipboardWork(work.reservation)
      }
      deleteSelectedContent();return
    }
    let owner=witness.target.kind == .page ? witness.target.id : witness.target.boardID ?? witness.target.id
    let edits=snapshot.sources.map { element in
      let reference:EditableElementReference = snapshot.surface.kind == .page
        ? .page(pageID:owner,elementID:element.id) : .spatial(boardID:owner,elementID:element.id)
      return NotebookElementEdit(reference:reference,kind:.removeElement,values:[:])
    }
    guard var plan=prepareElementOperations(edits,summary:"Вырезать выделенное",
      readSources:Array(snapshot.sourceChecks.keys),expectedInkRevision:snapshot.inkRevision,
      frozenSources:snapshot.sourceChecks) else { showCue("Выделение изменилось. Повторите вырезание.");return }
    plan.transferWitness=witness
    guard enqueueElementCommand(target:witness.target,ready:plan,reservation:snapshot.workLease?.reservation) != nil else { return }
    clearSelection()
  }

  private func selectionExportSource() throws -> (sources:[AgentElement],graph:NotebookGraphicGraph,surface:SurfaceID,rootOrigin:WorldPoint) {
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
      let references=selectionSession.elements,raw=selectionSession.ink
      guard selectionSession.items.isEmpty,
        let target=raw.first?.address.target ?? references.first.flatMap({ nativeElementSource($0)?.target }),
        references.allSatisfy({ nativeElementSource($0)?.target == target && elementCommandDrafts[$0] == nil }),
        raw.allSatisfy({ $0.address.target == target && selectionInkIsCurrent($0) }) else { throw unavailable() }
      let prepared:NotebookGraphicGraph
      if let first=references.first {
        guard let value=editingGraphicGraph(first) else { throw unavailable() };prepared=value
      } else { prepared = .init([]) }
      graph=prepared.projecting(adding:raw.map { $0.working.node })
      surface=target.kind == .page ? .page(target.id) : target.kind == .cover ? .cover(target.id) : .board(target.id)
      rootOrigin=references.first.flatMap { graph.placement($0.elementID)?.origin } ?? raw.first?.address.worldOrigin ?? .zero
      let ids=Set(references.map(\.elementID))
      guard (1...32).contains(ids.count+raw.count) else { throw unavailable() }
      if target.kind == .page { sources=pages[target.id]?.interactionElements(ids:ids) ?? [] }
      else {
        let owner=target.boardID ?? target.id
        sources=(boardHierarchy?.board(owner)?.interactionElements(ids:ids) ?? []).map { element in
          AgentElement(id:element.id,kind:AgentElementKind(rawValue:element.kind.rawValue)!,
            frame:.init(x:element.frame.x,y:element.frame.y,width:element.frame.width,height:element.frame.height),
            source:element.source,html:element.html,css:element.css,javaScript:element.javaScript,
            programPackage:element.programPackage,state:element.state,graphic:element.graphic,
            textStyle:element.textStyle,parentID:element.parentID,basis:element.basis)
        }
      }
      guard sources.count == ids.count else { throw unavailable() }
      sources += raw.map { $0.working.pageElement }
    }
    guard (1...32).contains(sources.count) else { throw unavailable() }
    return (sources,graph,surface,rootOrigin)
  }
}

/// Immutable captured material; preparation is pure and runs off the UI actor.
/// Copy consumes it once. Cut checks its selection/content token before deleting.
struct NotebookSelectionExport: Sendable {
  struct Result: Sendable {
    let fragment:NotebookPasteFragment
    let minimum:SpatialPoint
    let worldOrigin:WorldPoint
  }
  let selectionID:UUID
  let surface:SurfaceID
  let inkRevision:String?
  let sourceChecks:[EditableElementReference:NotebookNativeElementSource]
  let sources:[AgentElement]
  let graph:NotebookGraphicGraph
  let rootOrigin:WorldPoint
  let erasures:InkElementErasureMap
  let inkKeys:[String:NotebookInkPaintKey]
  let transfer:Task<NotebookElementTransfer,Error>?
  let transferWitness:NotebookElementTransferWitness?
  let programResources:NotebookProgramTransfer?
  let rawInk:[NotebookSelectedInk]
  let observedChecks:[EditableElementReference:NotebookNativeElementSource]
  let workLease:NotebookClipboardWorkLease?

  init(selectionID:UUID,surface:SurfaceID,inkRevision:String?,
    sourceChecks:[EditableElementReference:NotebookNativeElementSource],sources:[AgentElement],
    graph:NotebookGraphicGraph,rootOrigin:WorldPoint,erasures:InkElementErasureMap,
    inkKeys:[String:NotebookInkPaintKey]=[:],
    transfer:Task<NotebookElementTransfer,Error>?=nil,
    transferWitness:NotebookElementTransferWitness?=nil,programResources:NotebookProgramTransfer?=nil,
    rawInk:[NotebookSelectedInk]=[],
    observedChecks:[EditableElementReference:NotebookNativeElementSource]?=nil,
    workLease:NotebookClipboardWorkLease?=nil) {
    self.selectionID=selectionID;self.surface=surface;self.inkRevision=inkRevision
    self.sourceChecks=sourceChecks;self.sources=sources;self.graph=graph;self.rootOrigin=rootOrigin
    self.erasures=erasures;self.inkKeys=inkKeys
    self.transfer=transfer;self.transferWitness=transferWitness;self.programResources=programResources;self.rawInk=rawInk
    self.observedChecks=observedChecks ?? sourceChecks
    self.workLease=workLease
  }

  func materialized() async throws -> Self {
    guard let transfer else { return self }
    let material=try await withTaskCancellationHandler { try await transfer.value } onCancel: { transfer.cancel() }
    guard material.elements.count+rawInk.count <= 32 else {
      throw CollaborationError("selection_limit","За один раз можно перенести до 32 объектов вместе со всем составом групп.")
    }
    let owner=material.witness.target.kind == .page ? material.witness.target.id
      : material.witness.target.boardID ?? material.witness.target.id
    let checks=Dictionary(uniqueKeysWithValues:material.witness.sources.map { value in
      let reference:EditableElementReference = surface.kind == .page
        ? .page(pageID:owner,elementID:value.id) : .spatial(boardID:owner,elementID:value.id)
      return (reference,value)
    })
    return .init(selectionID:selectionID,surface:surface,inkRevision:inkRevision,
      sourceChecks:checks,sources:material.elements+rawInk.map { $0.working.pageElement },
      graph:material.graph.projecting(adding:rawInk.map { $0.working.node }),rootOrigin:material.rootOrigin,
      erasures:erasures,inkKeys:inkKeys.merging(material.inkKeys,uniquingKeysWith:{ first,_ in first }),
      transferWitness:material.witness,programResources:material.programResources,
      rawInk:rawInk,observedChecks:observedChecks,workLease:workLease)
  }

  func prepare() throws -> Result {
    func unavailable() -> CollaborationError { .init("selection_not_ready","Выделение изменилось или ещё готовится. Повторите действие.") }
    guard transfer == nil else { throw unavailable() }
    let ids=Set(sources.map(\.id))
    var bounds=CGRect.null
    for element in sources {
      try Task.checkCancellation()
      guard let placement=graph.placement(element.id) else { throw unavailable() }
      let delta=rootOrigin.delta(to:placement.origin)
      let box=CGRect(x:0,y:0,width:placement.localSize.x,height:placement.localSize.y).applying(placement.transform)
        .offsetBy(dx:delta.x,dy:delta.y)
      bounds=bounds.union(box)
    }
    guard !bounds.isNull,bounds.width > 0,bounds.height > 0 else { throw unavailable() }
    let keys=inkKeys
    let pending=sources.filter{keys[$0.id] == nil && $0.graphic?.sourceInkContactID != nil}
    guard pending.isEmpty else { throw unavailable() }
    let byID=Dictionary(uniqueKeysWithValues:sources.map{($0.id,$0)})
    let elements=try NotebookInkPaintKey.ordering(sources.map(\.id),keys:keys).map { id -> AgentElement in
      let element=byID[id]!
      try Task.checkCancellation()
      var frame=element.frame,parent=element.parentID,basis=element.basis
      if parent.map({ !ids.contains($0) }) ?? true {
        guard let placement=graph.placement(element.id) else { throw unavailable() }
        let pose=try placement.detached(),delta=rootOrigin.delta(to:placement.origin)
        parent=nil
        frame = .init(x:pose.frame.x+delta.x-bounds.minX,y:pose.frame.y+delta.y-bounds.minY,
          width:pose.frame.width,height:pose.frame.height)
        basis=pose.basis
      }
      var graphic=element.graphic
      if let source=graphic {
        var connection=source.connection
        if let value=connection,let body=graph.resolve(element.id,space:.body).layout {
          connection=value.detachingEndpoints(in:body,retainingBindingsTo:ids)
        }
        let cuts=erasures[element.id] ?? []
        let mask=cuts.isEmpty ? source.mask : (source.mask ?? .init()).capturing(cuts,transform:source.transform)
        graphic = .init(shape:source.shape,style:source.style,label:source.label,
          representation:source.representation,visible:source.visible,sourceInkIDs:[],connection:connection,
          vertices:source.vertices,cornerRadius:source.cornerRadius,freehand:source.freehand,
          transform:source.transform,path:source.path,mask:mask)
      }
      return .init(id:element.id,kind:element.kind,frame:frame,source:element.source,html:element.html,
        css:element.css,javaScript:element.javaScript,programPackage:element.programPackage,state:element.state,
        graphic:graphic,textStyle:element.kind == .nativeText ? element.textStyle : nil,parentID:parent,basis:basis)
    }
    return .init(fragment:.init(elements:elements,size:.init(x:bounds.width,y:bounds.height),programResources:programResources),
      minimum:.init(x:bounds.minX,y:bounds.minY),worldOrigin:rootOrigin)
  }
}
