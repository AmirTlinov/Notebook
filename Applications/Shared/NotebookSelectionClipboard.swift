import CoreGraphics
import Foundation
import NotebookCore

/// A finite export of the selected material. It never writes the source or
/// reads the system clipboard. Live rendering and selection keep their owners.
extension NotebookAppModel {
  /// Menu eligibility only captures bounded metadata; it never serializes source bodies.
  var canExportSelection: Bool { (try? selectionExportSource()) != nil }

  func clipboardSelectionSnapshot() throws -> NotebookSelectionExport {
    let source=try selectionExportSource()
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
    if source.surface.kind != .page {
      for element in source.sources {
        guard let id=element.graphic?.sourceInkContactID,keys[element.id] == nil else {continue}
        guard let header=spatialInkHistoryStates[id],header.surfaces.contains(source.surface) else {
          throw CollaborationError("selection_not_ready","Порядок рукописи ещё не готов.")
        }
        keys[element.id] = .spatial(stamp:header.result.creationStamp,id:id)
      }
    }
    return .init(selectionID:selectionSession.id,surface:source.surface,
      inkRevision:selectionInkRevision(source.surface),sourceChecks:checks,
      sources:source.sources,graph:source.graph,rootOrigin:source.rootOrigin,
      erasures:elementErasures(on:source.surface),inkKeys:keys,
      pageInkSource:source.surface.kind == .page ? source.surface.ownerID.flatMap{pages[$0]?.inkSource} : nil)
  }

  func selectionStillMatches(_ snapshot:NotebookSelectionExport) -> Bool {
    guard selectionSession.id == snapshot.selectionID,
      selectionInkRevision(snapshot.surface) == snapshot.inkRevision else { return false }
    if let region=selectionSession.region { return regionIsCurrent(region) }
    return snapshot.sourceChecks.allSatisfy { nativeElementSource($0.key) == $0.value && elementCommandDrafts[$0.key] == nil }
  }

  func selectionInkRevision(_ surface:SurfaceID) -> String? {
    surface.kind == .page ? surface.ownerID.flatMap { pages[$0]?.drawingStamp.revision } : spatialInk?.stamp.revision
  }

  private func selectionExport() throws -> NotebookSelectionExport.Result {
    try clipboardSelectionSnapshot().prepare()
  }

  /// Duplication shares the same bounded export and ordinary addressed writer.
  /// Native graphic contacts retain their causal copy operation; text, programs
  /// and whole groups use the same element transaction, never the clipboard.
  func duplicateSelectedContent() {
    if !selectionSession.ink.isEmpty || selectionContainsSourceAnchoredInk { duplicateMeasuredSelection();return }
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
        let exported=try snapshot.prepare(),fragment=try exported.fragment.reidentified(namespace:namespace)
        let offset=SpatialPoint(x:exported.minimum.x+min(24,max(0,address.bounds.map { $0.maxX-exported.minimum.x-fragment.size.x } ?? 24)),
          y:exported.minimum.y+min(24,max(0,address.bounds.map { $0.maxY-exported.minimum.y-fragment.size.y } ?? 24)))
        let operations=try fragment.operations(target:address.target,offset:offset,
          worldOrigin:address.target.kind == .board ? exported.worldOrigin : nil)
        var sources=snapshot.sourceChecks
        let edits=operations.map { operation -> NotebookElementEdit in
          let reference=address.reference(operation.id!)
          sources[reference] = .init(target:address.target,id:operation.id!)
          return .init(reference:reference,kind:operation.kind,values:operation.values)
        }
        guard sources.count<=64 else { throw CollaborationError("selection_limit","У копии слишком много связанных исходников.") }
        let selected=fragment.elements.filter { $0.parentID == nil }.map { address.reference($0.id) }
        return (edits,sources,selected)
      }
      let plan=Task { [weak self] () throws -> NotebookElementCommandPlan in
        let result=try await preparation.value
        guard let self,let plan=prepareElementOperations(result.0,summary:"Дублировать выделенное",
          readSources:Array(result.1.keys),insertionTarget:address.target,expectedInkRevision:snapshot.inkRevision,
          frozenSources:result.1) else {
          throw CollaborationError("revision_conflict","Не удалось подготовить всё выделение.")
        }
        return plan
      }
      let batch=enqueueElementCommand(target:address.target,preparing:plan)
      Task { [weak self] in
        do {
          _ = try await batch.prepared()
          let result=try await preparation.value
          if let self,selectionSession.id == snapshot.selectionID { selectElements(result.2) }
        } catch { /* The existing command reports the failure. */ }
      }
    } catch { showCue(error.localizedDescription) }
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
        raw.allSatisfy({ $0.address.target == target && selectionInkRevision($0.address.surface) == $0.revision }) else { throw unavailable() }
      let prepared:NotebookGraphicGraph
      if let first=references.first {
        guard let value=editingGraphicGraph(first) else { throw unavailable() };prepared=value
      } else { prepared = .init([]) }
      graph=prepared.projecting(adding:raw.map { $0.working.node })
      surface=target.kind == .page ? .page(target.id) : target.kind == .cover ? .cover(target.id) : .board(target.id)
      rootOrigin=references.first.flatMap { graph.placement($0.elementID)?.origin } ?? raw.first?.address.worldOrigin ?? .zero
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
  let erasures:[String:[InkElementErasure]]
  let inkKeys:[String:NotebookInkPaintKey]
  let pageInkSource:PageInkSource?

  init(selectionID:UUID,surface:SurfaceID,inkRevision:String?,
    sourceChecks:[EditableElementReference:NotebookNativeElementSource],sources:[AgentElement],
    graph:NotebookGraphicGraph,rootOrigin:WorldPoint,erasures:[String:[InkElementErasure]],
    inkKeys:[String:NotebookInkPaintKey]=[:],pageInkSource:PageInkSource?=nil) {
    self.selectionID=selectionID;self.surface=surface;self.inkRevision=inkRevision
    self.sourceChecks=sourceChecks;self.sources=sources;self.graph=graph;self.rootOrigin=rootOrigin
    self.erasures=erasures;self.inkKeys=inkKeys;self.pageInkSource=pageInkSource
  }

  func prepare() throws -> Result {
    func unavailable() -> CollaborationError { .init("selection_not_ready","Выделение изменилось или ещё готовится. Повторите действие.") }
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
    var keys=inkKeys
    let pending=sources.filter{keys[$0.id] == nil && $0.graphic?.sourceInkContactID != nil}
    if !pending.isEmpty {
      guard surface.kind == .page,let drawing=try pageInkSource?.drawing() else {throw unavailable()}
      for element in pending {
        guard let id=element.graphic?.sourceInkContactID,let action=drawing.action(id:id),action.tool == .pen else {throw unavailable()}
        keys[element.id] = .page(sequence:action.sequence,id:id)
      }
    }
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
        let body=graph.resolve(element.id,space:.body).layout
        let connection=body.map { source.connection?.detachingEndpoints(in:$0,retainingBindingsTo:ids) } ?? source.connection
        let cuts=erasures[element.id] ?? []
        let mask=cuts.isEmpty ? source.mask : (source.mask ?? .init()).capturing(cuts,transform:source.transform)
        graphic = .init(shape:source.shape,style:source.style,label:source.label,
          representation:source.representation,visible:source.visible,sourceInkIDs:[],connection:connection,
          vertices:source.vertices,cornerRadius:source.cornerRadius,freehand:source.freehand,
          transform:source.transform,path:source.path,mask:mask)
      }
      return .init(id:element.id,kind:element.kind,frame:frame,source:element.source,html:element.html,
        css:element.css,javaScript:element.javaScript,programPackage:element.programPackage,state:element.state,
        graphic:graphic,textStyle:element.textStyle,parentID:parent,basis:basis)
    }
    return .init(fragment:.init(elements:elements,size:.init(x:bounds.width,y:bounds.height)),
      minimum:.init(x:bounds.minX,y:bounds.minY),worldOrigin:rootOrigin)
  }
}
