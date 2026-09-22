import CoreGraphics
import Foundation
import NotebookCore
import Observation

/// A contact pins one physical owner and one coordinate basis at admission.
/// Its adapter may disappear; completion cannot silently target a new page.
struct NotebookToolAddress: Equatable, Sendable {
  let surface: SurfaceID
  let boardID: UUID?
  let worldOrigin: WorldPoint?
  let bounds: CGRect?
  var target: CollaborationTarget {
    .init(kind: surface.kind == .page ? .page : surface.kind == .cover ? .cover : .board,
      id:surface.ownerID!,boardID:surface.kind == .cover ? boardID : nil)
  }
  func reference(_ id: String) -> EditableElementReference {
    surface.kind == .page ? .page(pageID:surface.ownerID!,elementID:id)
      : .spatial(boardID:boardID ?? surface.ownerID!,elementID:id)
  }
}

@MainActor @Observable
final class NotebookDrawingToolController {
  struct SpatialSelectionSource: Sendable {
    let index: WorkspaceSceneIndex
    let changedElementIDs: Set<String>
  }
  struct Contact: Sendable {
    let id: UUID
    let tool: DrawingTool
    let settings: NotebookDrawingToolSettings
    let pen: PenStyle
    let address: NotebookToolAddress
    let graph: NotebookGraphicGraph
    let spatialSelection: SpatialSelectionSource?
    let screenScale: Double
    let ink: Task<NotebookLassoInkSource.Prepared?,Error>?
    var points: [SpatialPoint]
  }
  private unowned let model: NotebookAppModel
  private(set) var contact: Contact?
  var ruler: NotebookRuler?
  private(set) var laserTraces: [NotebookLaserTrace] = []
  @ObservationIgnored private var inkSnapshotCache: (surface:SurfaceID,key:String,
    task:Task<NotebookLassoInkSource.Prepared,Error>)?
  @ObservationIgnored private var lassoTask: Task<Void,Never>?
  @ObservationIgnored var onContactCancellation: (() -> Void)?
  init(model: NotebookAppModel) { self.model = model }
  var selectsWorkspaceItems: Bool {
    model.drawingTool == .lasso && model.drawingToolSettings.lassoMode == .elements
      && model.presence?.mode == .board
  }

  func placeRuler() {
    guard let presence = model.presence else { return }
    let address: NotebookToolAddress, start: SpatialPoint
    if presence.mode == .page, let id = model.workspace?.selectedPageID, let page = model.pages[id] {
      address = .init(surface:.page(id),boardID:nil,worldOrigin:nil,bounds:.init(x:0,y:0,width:page.size.width,height:page.size.height))
      start = .init(x:page.size.width*0.15,y:page.size.height*0.45)
    } else if presence.mode == .cover, let id = presence.focusedItemID {
      let size = model.itemGeometry(id)
      address = .init(surface:.cover(id),boardID:presence.boardID,worldOrigin:nil,bounds:.init(x:0,y:0,width:size.width,height:size.height))
      start = .init(x:size.width*0.15,y:size.height*0.45)
    } else {
      let origin = presence.camera.screenToWorld(.init(x:presence.viewport.x*0.2,y:presence.viewport.y*0.45),viewport:presence.viewport)
      address = .init(surface:.board(presence.boardID),boardID:presence.boardID,worldOrigin:origin,bounds:nil)
      start = .zero
    }
    ruler = .init(address:address,start:start,angle:model.drawingToolSettings.rulerAngle,
      length:min(PhysicalPaper.pointsPerCentimeter*10,address.bounds.map { $0.width*0.7 } ?? .infinity))
  }

  @discardableResult
  func begin(at point: SpatialPoint, address: NotebookToolAddress, screenScale: Double) -> Bool {
    guard !model.drawingTool.usesInkJournal, address.surface.ownerID != nil,
      screenScale.isFinite, screenScale > 0 else { return false }
    cancel()
    laserTraces.removeAll { $0.expiresAt <= Date.timeIntervalSinceReferenceDate }
    let graph: NotebookGraphicGraph
    var spatialSelection: SpatialSelectionSource? = nil
    if [.laser,.ruler,.text].contains(model.drawingTool) { graph = .init([]) }
    else if address.surface.kind == .page, let page = model.pages[address.surface.ownerID!] { graph = model.graphicGraph(page:page) }
    else if model.drawingTool == .lasso, let source=spatialSelectionSource(at:address) {
      graph=source.graph;spatialSelection=source.source
    }
    else if let board = address.boardID ?? address.surface.ownerID {
      graph = model.authoredGraphicGraph(boardID:board)
    } else { graph = .init([]) }
    if model.drawingTool == .lasso,address.surface.kind != .page,spatialSelection == nil { return false }
    let ink = model.drawingTool == .lasso && model.drawingToolSettings.lassoMode == .region
      ? inkSnapshot(at:address,graph:graph) : nil
    if model.drawingTool == .ruler, ruler?.address.surface != address.surface {
      ruler = .init(address:address,start:point,angle:model.drawingToolSettings.rulerAngle,length:PhysicalPaper.pointsPerCentimeter*10)
    }
    contact = .init(id:UUID(),tool:model.drawingTool,settings:model.drawingToolSettings,pen:model.penStyle,
      address:address,graph:graph,spatialSelection:spatialSelection,
      screenScale:screenScale,ink:ink,points:[point])
    if let contact, contact.tool == .laser {
      laserTraces.append(.init(id:contact.id,address:address,color:contact.settings.laserColor,
        width:4/screenScale,lifetime:contact.settings.laserDuration,
        samples:[.init(point:point,time:Date.timeIntervalSinceReferenceDate)]))
    }
    return true
  }

  private func inkSnapshot(at address: NotebookToolAddress, graph: NotebookGraphicGraph) -> Task<NotebookLassoInkSource.Prepared?,Error>? {
    let raw: Task<NotebookLassoInkSource?,Never>
    if let page = model.pages[address.surface.ownerID!], address.surface.kind == .page { raw = model.lassoInkSnapshot(page) }
    else {
      guard let journal = model.renderingInk(on:address.surface,fallback:model.compositionTiles.published?.liveData.ink) else { return nil }
      let suppressed = Set(graph.nodes.values.filter { !$0.graphic.visible || $0.graphic.representation == .geometry }.flatMap { $0.graphic.sourceInkIDs })
      let revision=model.lassoMembershipRevision
      raw = Task { .spatial(journal,suppressed,membershipRevision:revision) }
    }
    return Task { [weak self] in
      guard let source = await raw.value, let self else { return nil }
      let key = source.cacheKey(surface:address.surface)
      if let cached = inkSnapshotCache,cached.surface == address.surface,cached.key == key {
        return try await cached.task.value.excluding(source.suppressed)
      }
      let reusable=inkSnapshotCache.flatMap { $0.surface == address.surface ? $0.task : nil }
      let task = Task.detached(priority:.userInitiated) {
        let previous:NotebookLassoInkSource.Prepared?
        if let reusable { previous=try? await reusable.value } else { previous=nil }
        return try source.prepare(surface:address.surface,origin:address.worldOrigin,reusing:previous)
      }
      inkSnapshotCache = (address.surface,key,task)
      return try await task.value
    }
  }

  func selectInk(at point: SpatialPoint, address: NotebookToolAddress, screenScale: Double) {
    cancel()
    let graph:NotebookGraphicGraph, spatialSelection:SpatialSelectionSource?
    if address.surface.kind == .page {
      graph=model.pages[address.surface.ownerID!].map { model.graphicGraph(page:$0) } ?? .init([])
      spatialSelection=nil
    } else if let source=spatialSelectionSource(at:address) {
      graph=source.graph;spatialSelection=source.source
    } else { return }
    let radius = 6/max(0.001,screenScale)
    var settings = model.drawingToolSettings
    settings.lassoMode = .region; settings.lassoAddsToSelection = false
    finishLasso(.init(id:UUID(),tool:.lasso,settings:settings,pen:model.penStyle,address:address,graph:graph,
      spatialSelection:spatialSelection,
      screenScale:screenScale,ink:inkSnapshot(at:address,graph:graph),points:[
        .init(x:point.x-radius,y:point.y-radius),.init(x:point.x+radius,y:point.y-radius),
        .init(x:point.x+radius,y:point.y+radius),.init(x:point.x-radius,y:point.y+radius)]))
  }

  private func spatialSelectionSource(at address:NotebookToolAddress)
    -> (graph:NotebookGraphicGraph,source:SpatialSelectionSource)? {
    guard let board=address.boardID ?? address.surface.ownerID,
      let cohort=model.compositionTiles.published,
      cohort.frame.index.board(id:board) != nil else { return nil }
    let graph=model.interactionGraphicGraph(boardID:board,cohort:cohort)
    return (graph,.init(index:cohort.frame.index,
      changedElementIDs:model.spatialSelectionChanges(boardID:board,graph:graph)))
  }

  func move(to point: SpatialPoint) {
    guard var current = contact, point.x.isFinite, point.y.isFinite else { return }
    var point = point
    if let bounds = current.address.bounds {
      point = .init(x:min(bounds.maxX,max(bounds.minX,point.x)),y:min(bounds.maxY,max(bounds.minY,point.y)))
    }
    if current.tool == .lasso || current.tool == .laser {
      if let last = current.points.last, hypot(last.x-point.x,last.y-point.y)*current.screenScale < 1 { return }
      if current.points.count >= 8192 { current.points=simplifiedLasso(current.points,screenScale:current.screenScale,maximum:4096) }
      current.points.append(point)
    } else { current.points = [current.points[0],point] }
    contact = current
    if current.tool == .laser, let index = laserTraces.firstIndex(where:{ $0.id == current.id }) {
      let now = Date.timeIntervalSinceReferenceDate
      laserTraces[index].append(point,time:now)
    }
    if let object = figure(current) { model.updateWorkingGraphic(object,strokeID:current.id) }
  }

  func finish() {
    guard let current = contact else { return }
    contact = nil
    onContactCancellation = nil
    switch current.tool {
    case .shape, .connector, .ruler:
      if let object = figure(current), hypot(current.points[0].x-current.points.last!.x,current.points[0].y-current.points.last!.y)*current.screenScale >= 4 {
        if current.tool == .shape, let operation = current.settings.shapeOperation, operation != .normal {
          model.combineAuthoredShape(object,at:current.address,graph:current.graph,operation:operation)
        } else { model.acceptAuthoredGraphic(object,at:current.address) }
      } else { model.updateWorkingGraphic(nil,strokeID:current.id) }
    case .lasso: finishLasso(current)
    case .text:
      model.beginToolText(at:current.points[0],address:current.address,screenScale:current.screenScale)
    case .laser:
      #if os(iOS)
      model.captureLaserContext(current)
      #endif
      expireLaser(current.id)
    case .pen,.marker,.eraser: assertionFailure("Ink belongs to the measured journal adapter")
    }
  }

  func cancel() {
    lassoTask?.cancel(); lassoTask = nil
    if let contact {
      model.updateWorkingGraphic(nil,strokeID:contact.id)
      if contact.tool == .laser { expireLaser(contact.id) }
    }
    contact = nil
    let cancellation = onContactCancellation; onContactCancellation = nil
    cancellation?()
  }

  private func expireLaser(_ id: UUID) {
    guard let trace = laserTraces.first(where:{ $0.id == id }) else { return }
    let remaining = max(0,trace.expiresAt-Date.timeIntervalSinceReferenceDate)
    Task { [weak self] in
      try? await Task.sleep(for:.seconds(remaining))
      self?.laserTraces.removeAll { $0.id == id }
    }
  }

  private func finishLasso(_ current: Contact) {
    let polygon = simplifiedLasso(current.points,screenScale:current.screenScale)
    guard polygon.count >= 3 else { model.clearSelection(); return }
    if current.settings.lassoMode == .elements {
      finishElementSelection(current,polygon:polygon)
      return
    }
    let references:[EditableElementReference]
    do {
      references=try model.regionGraphics(intersecting:polygon,at:current.address,
        graph:current.graph,spatial:current.spatialSelection)
    } catch { model.showCue(error.localizedDescription);return }
    let selection = model.selectionSession.id
    lassoTask = Task { [weak self] in
      do {
        let source=try await current.ink?.value
        let preparation=Task.detached(priority:.userInitiated) {
          try source?.selection(polygon:polygon,surface:current.address.surface,
            origin:current.address.worldOrigin,bounds:current.address.bounds)
        }
        let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        guard !Task.isCancelled, let self, model.selectionSession.id == selection else { return }
        guard result != nil || !references.isEmpty else { model.clearSelection();return }
        let box=polygon.reduce(CGRect.null) { $0.union(.init(x:$1.x,y:$1.y,width:0,height:0)) }
        guard !box.isNull,box.width > 0,box.height > 0 else { model.clearSelection();return }
        model.selectRegion(.init(id:current.id,address:current.address,polygon:polygon,
          frame:.init(x:box.minX,y:box.minY,width:box.width,height:box.height),rawInk:result,
          expectedInkRevision:source?.revision,graphics:references))
      } catch is CancellationError {} catch { self?.model.showCue(error.localizedDescription) }
    }
  }

  private func finishElementSelection(_ current:Contact,polygon:[SpatialPoint]) {
    let selected:([EditableElementReference],[NotebookSelectedItem])
    do {
      selected=(try model.elementsIntersecting(polygon,at:current.address,graph:current.graph,
        spatial:current.spatialSelection),try model.itemsIntersecting(polygon,at:current.address,
          spatial:current.spatialSelection))
    } catch { model.showCue(error.localizedDescription);return }
    var references=selected.0,items=selected.1
    let previousReferences=current.settings.lassoAddsToSelection ? model.selectionSession.elements : []
    let previousItems=current.settings.lassoAddsToSelection ? model.selectionSession.items : []
    references += previousReferences;items += previousItems
    model.selectElements(references,items:items)
  }

  private func simplifiedLasso(_ points:[SpatialPoint],screenScale:Double,maximum:Int=2048)->[SpatialPoint] {
    guard points.count > 3 else { return points }
    func distance(_ p:SpatialPoint,_ a:SpatialPoint,_ b:SpatialPoint)->Double {
      let dx=b.x-a.x,dy=b.y-a.y,square=dx*dx+dy*dy
      let t=square == 0 ? 0 : min(1,max(0,((p.x-a.x)*dx+(p.y-a.y)*dy)/square))
      return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)
    }
    func reduced(_ tolerance:Double)->[SpatialPoint] {
      var keep=Array(repeating:false,count:points.count);keep[0]=true;keep[points.count-1]=true
      var stack=[(0,points.count-1)]
      while let (start,end)=stack.popLast(),end > start+1 {
        var far=start,value=0.0
        for index in (start+1)..<end {
          let d=distance(points[index],points[start],points[end]);if d > value { value=d;far=index }
        }
        if value > tolerance { keep[far]=true;stack.append((start,far));stack.append((far,end)) }
      }
      return points.indices.filter { keep[$0] }.map { points[$0] }
    }
    var tolerance=0.5/max(screenScale,0.001),result=reduced(tolerance)
    while result.count > maximum { tolerance *= 1.5;result=reduced(tolerance) }
    return result
  }

  private func figure(_ current: Contact) -> NotebookWorkingGraphic? {
    let tool = current.tool, settings = current.settings
    guard [.shape,.connector,.ruler].contains(tool), let last = current.points.last else { return nil }
    let shape = settings.shape
    let color = (tool == .shape ? settings.shapeColor : tool == .connector ? settings.connectionColor : current.pen.color).components
    let width = (tool == .shape ? settings.shapeWidth : tool == .connector ? settings.connectionWidth : current.pen.width)/current.screenScale
    let start = tool == .ruler ? ruler?.project(current.points[0],from:current.address,snap:settings.rulerSnapToGrid) ?? current.points[0] : current.points[0]
    var end = tool == .ruler ? ruler?.project(last,from:current.address,snap:settings.rulerSnapToGrid) ?? last : last
    if let bounds = current.address.bounds {
      var dx = end.x-start.x, dy = end.y-start.y
      if tool == .shape && settings.preservesAspect {
        let side = min(max(abs(dx),abs(dy)),dx < 0 ? start.x-bounds.minX : bounds.maxX-start.x,
          dy < 0 ? start.y-bounds.minY : bounds.maxY-start.y)
        dx = (dx < 0 ? -1 : 1)*side; dy = (dy < 0 ? -1 : 1)*side
      }
      let tx = dx == 0 ? 1 : (dx > 0 ? bounds.maxX-start.x : bounds.minX-start.x)/dx
      let ty = dy == 0 ? 1 : (dy > 0 ? bounds.maxY-start.y : bounds.minY-start.y)/dy
      let t = min(1,max(0,min(tx,ty)))
      end = .init(x:start.x+dx*t,y:start.y+dy*t)
    }
    guard var fit = tool == .shape
      ? NotebookToolGeometry.figure(from:start,to:end,shape:shape,preservesAspect:settings.preservesAspect,width:width)
      : NotebookToolGeometry.connection(from:start,to:end,width:width) else { return nil }
    if let bounds = current.address.bounds {
      let rect = CGRect(x:fit.frame.x,y:fit.frame.y,width:fit.frame.width,height:fit.frame.height).intersection(bounds)
      guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
      fit = .init(frame:.init(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height),sampleCount:fit.sampleCount,
        connection:fit.connection,shape:fit.shape,vertices:fit.vertices)
    }
    if tool == .connector {
      fit = fit.binding(in:current.graph,surface:current.address.surface,origin:current.address.worldOrigin ?? .zero,
        tolerance:18/current.screenScale,erasures:model.elementErasures(on:current.address.surface))
      fit.connection?.routing = settings.connectionRouting
      fit.connection?.startArrowhead = settings.connectionStart ?? .none
      fit.connection?.endArrowhead = settings.connectionEnd ?? .arrow
    }
    if tool == .ruler { fit.connection?.endArrowhead = .none }
    let fill = (settings.shapeFillColor ?? .yellow).components
    let stroke = SpatialInkColor(red:color.red,green:color.green,blue:color.blue)
    let graphic = NotebookGraphic(shape:fit.shape,style:.init(stroke:stroke,strokeWidth:width,
      fill:tool == .shape && settings.shapeFilled && fit.connection == nil ? .init(red:fill.red,green:fill.green,blue:fill.blue) : nil,
      dash:tool == .connector ? settings.connectionDash : nil),connection:fit.connection,vertices:fit.vertices)
    return .init(id:current.id,surface:current.address.surface,frame:fit.frame,worldOrigin:current.address.worldOrigin,graphic:graphic)
  }
}

extension NotebookAppModel {
  /// The immutable scene index covers the installed generation. Only accepted
  /// insertions and active placement drafts can differ from it; keep that
  /// delta explicit instead of rebuilding or rescanning the board on contact.
  func spatialSelectionChanges(boardID:UUID,graph:NotebookGraphicGraph)->Set<String> {
    var ids=Set(workingGraphics.compactMap { graphic -> String? in
      let belongs=graphic.surface == .board(boardID) || (graphic.surface.kind == .cover
        && graphic.surface.ownerID.flatMap { boardHierarchy?.ownerBoardID(of:$0) } == boardID)
      return belongs ? graphic.id : nil
    })
    ids.formUnion(elementCommandDrafts.keys.compactMap { reference in
      if case .spatial(let owner,let id)=reference,owner == boardID { return id };return nil
    })
    guard !ids.isEmpty else { return ids }
    let groups=ids.filter { graph.groups[$0] != nil }
    guard !groups.isEmpty else { return ids }
    // Parent motion changes descendant surface bounds without rewriting them.
    // This rare active-edit delta is the only case that visits group members.
    for node in graph.nodes.values where groups.contains(where: { node.placement.descends(from:$0) }) {
      ids.insert(node.id)
    }
    if let board=boardHierarchy?.board(boardID) {
      for element in board.elements where groups.contains(where: { graph.placement(element.id)?.descends(from:$0) == true }) {
        ids.insert(element.id)
      }
    }
    return ids
  }

  private func spatialSelectionBounds(_ polygon:[SpatialPoint],address:NotebookToolAddress)
    -> WorkspaceSpatialBounds? {
    guard let x=polygon.map(\.x).min(),let y=polygon.map(\.y).min(),
      let right=polygon.map(\.x).max(),let bottom=polygon.map(\.y).max(),
      [x,y,right,bottom].allSatisfy(\.isFinite) else { return nil }
    let origin=(address.surface.kind == .board ? address.worldOrigin ?? .zero : .zero)
      .offsetBy(x:x,y:y)
    return .init(origin:origin,width:max(0,right-x),height:max(0,bottom-y))
  }

  private func spatialCandidates(_ polygon:[SpatialPoint],address:NotebookToolAddress,
    source:NotebookDrawingToolController.SpatialSelectionSource?,kinds:WorkspaceSpatialKinds)
    throws -> WorkspaceSpatialIntersectionQuery? {
    guard address.surface.kind != .page else { return nil }
    guard let source,let board=address.boardID ?? address.surface.ownerID,
      let bounds=spatialSelectionBounds(polygon,address:address) else {
      throw CollaborationError("snapshot_pending","Геометрия сцены ещё готовится.")
    }
    return try source.index.interactionCandidates(boardID:board,
      coverID:address.surface.kind == .cover ? address.surface.ownerID : nil,
      bounds:bounds,kinds:kinds)
  }

  private func spatialElementIDs(_ query:WorkspaceSpatialIntersectionQuery?)->Set<String> {
    Set((query?.entries ?? []).compactMap { entry -> String? in
      guard case .element(let id)=entry.id else { return nil };return id
    })
  }

  private func pageSelectionCandidates(_ polygon:[SpatialPoint],pageID:UUID,
    graph:NotebookGraphicGraph,limit:Int=4_096) throws -> NotebookGraphicVisibilityResult? {
    guard let x=polygon.map(\.x).min(),let y=polygon.map(\.y).min(),
      let right=polygon.map(\.x).max(),let bottom=polygon.map(\.y).max(),
      [x,y,right,bottom].allSatisfy(\.isFinite) else { return nil }
    let visible=graph.visiblePageGraphics(pageID,
      in:.init(x:x,y:y,width:max(0,right-x),height:max(0,bottom-y)),limit:limit)
    guard !visible.overflow else {
      throw CollaborationError("selection_limit",
        "Выделите меньшую область: в ней слишком много объектов.")
    }
    return visible
  }

  private func nativeElementIntersects(_ presentation:NotebookElementPresentation,id:String,
    surface:SurfaceID,polygon:[SpatialPoint],from origin:WorldPoint)->Bool {
    let transform=presentation.placement.transform
    let determinant=transform.a*transform.d-transform.b*transform.c
    guard determinant.isFinite,determinant != 0 else { return false }
    let inverse=transform.inverted(),delta=origin.delta(to:presentation.placement.origin)
    let local=polygon.map {
      CGPoint(x:$0.x-delta.x,y:$0.y-delta.y).applying(inverse)
    }
    return NotebookElementAppearance(graphic:nil,layout:nil,size:presentation.bodySize,
      erasures:elementErasures(on:surface)[id] ?? []).intersects(local)
  }

  private func authoredGraphicValues(_ object:NotebookWorkingGraphic,address:NotebookToolAddress)->[String:JSONValue]? {
    guard var values = try? ["kind":JSONValue.string("graphic"),"source":.string(""),
      "frame":.encode(object.frame),"graphic":.encode(object.graphic)] else { return nil }
    if let origin = address.worldOrigin { values["worldOrigin"] = try? .encode(origin) }
    if let basis=object.basis { values["basis"] = try? .encode(basis) }
    return values
  }

  @discardableResult
  func acceptAuthoredGraphic(_ object: NotebookWorkingGraphic, at address: NotebookToolAddress, expectedInkRevision: String? = nil) -> Bool {
    guard let values=authoredGraphicValues(object,address:address) else { return false }
    var accepted = object; accepted.accepted = true
    if object.graphic.freehand == nil || address.surface.kind == .page { updateWorkingGraphic(accepted,strokeID:object.strokeID) }
    if !performElementOperations([.init(reference:address.reference(object.id),kind:object.graphic.sourceInkIDs.isEmpty ? .insertElement : .convertInkToElement,values:values)],
      summary:"Нарисовать: " + object.graphic.shape.displayName,insertionTarget:address.target,expectedInkRevision:expectedInkRevision) {
      removeWorkingGraphics { $0.id == object.id }; return false
    }
    return true
  }

  /// The first causal operation materializes a region as compact masked views
  /// of the same retained vectors. Merely drawing a lasso never writes.
  @discardableResult
  func materializeRegionSelection()->[EditableElementReference]? {
    guard let region=selectionSession.region else { return nil }
    func normalized(_ polygon:[SpatialPoint],in frame:PageRect)->[SpatialPoint] {
      guard frame.width > 0,frame.height > 0 else { return [] }
      return polygon.map { .init(x:($0.x-frame.x)/frame.width,y:($0.y-frame.y)/frame.height) }
    }
    func copied(_ graphic:NotebookGraphic,claims:[UUID],mask:NotebookGraphicMask)->NotebookGraphic {
      .init(shape:graphic.shape,style:graphic.style,label:graphic.label,representation:graphic.representation,
        visible:graphic.visible,sourceInkIDs:claims,connection:graphic.connection,vertices:graphic.vertices,
        cornerRadius:graphic.cornerRadius,freehand:graphic.freehand,transform:graphic.transform,path:graphic.path,mask:mask)
    }
    func reframed(_ graphic:NotebookGraphic,to frame:PageRect)->NotebookGraphic {
      guard let freehand=graphic.freehand,graphic.transform == nil else { return graphic }
      let layers=freehand.layers.map { layer -> NotebookFreehand.Layer in
        guard let measured=layer.measured else { return layer }
        return .init(tool:layer.tool,color:layer.color,measured:.init(sourceID:measured.sourceID,
          span:measured.span,measurements:measured.measurements,frame:frame,origin:measured.origin))
      }
      return .init(shape:graphic.shape,style:graphic.style,label:graphic.label,representation:graphic.representation,
        visible:graphic.visible,sourceInkIDs:graphic.sourceInkIDs,connection:graphic.connection,vertices:graphic.vertices,
        cornerRadius:graphic.cornerRadius,freehand:.init(layers:layers),transform:nil,path:graphic.path,mask:graphic.mask)
    }
    var edits:[NotebookElementEdit]=[],working:[NotebookWorkingGraphic]=[],selected:[EditableElementReference]=[]
    if let raw=region.rawInk {
      let selectedFrame=raw.selectionFrame
      let selectedPolygon=normalized(region.polygon,in:selectedFrame)
      let sourcePolygon=normalized(region.polygon,in:raw.frame)
      guard selectedPolygon.count >= 3,sourcePolygon.count >= 3 else { return nil }
      let inside=(raw.graphic.mask ?? .init()).appending(.intersect,polygon:selectedPolygon)
      let outside=(raw.graphic.mask ?? .init()).appending(.subtract,polygon:sourcePolygon)
      let reference=region.address.reference(region.id.uuidString.lowercased())
      let graphic=copied(reframed(raw.graphic,to:selectedFrame),claims:raw.graphic.sourceInkIDs,mask:inside)
      let object=NotebookWorkingGraphic(id:region.id,surface:region.address.surface,frame:selectedFrame,
        worldOrigin:region.address.worldOrigin,graphic:graphic)
      guard let values=authoredGraphicValues(object,address:region.address) else { return nil }
      edits.append(.init(reference:reference,kind:.convertInkToElement,values:values));working.append(object);selected.append(reference)
      if !outside.path(in:.init(x:0,y:0,width:1,height:1)).isEmpty {
        let id=UUID(),ref=region.address.reference(id.uuidString.lowercased())
        let rest=copied(raw.graphic,claims:[],mask:outside)
        let object=NotebookWorkingGraphic(id:id,surface:region.address.surface,frame:raw.frame,
          worldOrigin:region.address.worldOrigin,graphic:rest)
        guard let values=authoredGraphicValues(object,address:region.address) else { return nil }
        edits.append(.init(reference:ref,kind:.insertElement,values:values));working.append(object)
      }
    }
    for reference in region.graphics {
      guard let source=nativeElementSource(reference),source.target == region.address.target,
        let graphic=graphicElement(reference),graphic.freehand != nil,
        let layout=graphicLayout(reference) else { continue }
      let size=layout.projection?.size ?? .init(width:layout.frame.width,height:layout.frame.height)
      let polygon=region.polygon.compactMap { point -> SpatialPoint? in
        guard size.width > 0,size.height > 0,
          let frame=layout.framePoint(point,from:region.address.worldOrigin ?? .zero),
          let local=layout.localPoint(frame) else { return nil }
        return .init(x:local.x/size.width,y:local.y/size.height)
      }
      guard polygon.count == region.polygon.count else { continue }
      let inside=(graphic.mask ?? .init()).appending(.intersect,polygon:polygon)
      guard !inside.path(in:.init(x:0,y:0,width:1,height:1)).isEmpty else { continue }
      let outside=(graphic.mask ?? .init()).appending(.subtract,polygon:polygon)
      edits.append(.init(reference:reference,kind:.updateElement,
        values:["graphic":.object(["mask":(try? .encode(outside)) ?? .null])]))
      let id=UUID(),ref=region.address.reference(id.uuidString.lowercased())
      let selectedGraphic=copied(graphic,claims:[],mask:inside)
      guard let placement=layout.flattenedPlacement() else { continue }
      let frame=placement.frame
      var values:[String:JSONValue]=["kind":.string("graphic"),"source":.string(""),
        "frame":(try? .encode(frame)) ?? .null,"graphic":(try? .encode(selectedGraphic)) ?? .null]
      let worldOrigin=source.spatial == nil ? nil : layout.origin
      if let worldOrigin { values["worldOrigin"]=try? .encode(worldOrigin) }
      if let basis=placement.basis { values["basis"]=try? .encode(basis) }
      edits.append(.init(reference:ref,kind:.insertElement,values:values))
      working.append(.init(id:id,surface:source.spatial?.surface ?? region.address.surface,
        frame:frame,worldOrigin:worldOrigin,graphic:selectedGraphic,basis:placement.basis));selected.append(ref)
    }
    guard !selected.isEmpty,!edits.isEmpty,edits.count <= 32 else {
      if edits.count > 32 { showCue("Выделите меньшую область: одно изменение содержит не более 32 частей.") }
      return nil
    }
    for var object in working { object.accepted=true;updateWorkingGraphic(object,strokeID:object.strokeID) }
    guard performElementOperations(edits,summary:"Изменить область лассо",insertionTarget:region.address.target,
      expectedInkRevision:region.rawInk == nil ? nil : region.expectedInkRevision) else {
      let ids=Set(working.map(\.id));removeWorkingGraphics { ids.contains($0.id) };return nil
    }
    selectElements(selected);return selected
  }

  /// Empty input is a selection-session draft, not a saved invisible object.
  /// The first nonempty edit inserts through the same addressed command queue.
  @discardableResult
  func beginToolText(at point: SpatialPoint, address: NotebookToolAddress, screenScale: Double) -> String? {
    guard !consumeNativeTextCanvasTap(), screenScale.isFinite, screenScale > 0 else { return nil }
    let candidates: [EditableElementReference]
    if address.surface.kind == .page, let page = pages[address.surface.ownerID!] {
      candidates = page.elements.reversed().filter { $0.kind == .nativeText }.map { address.reference($0.id) }
    } else {
      candidates = boardHierarchy?.board(address.boardID ?? address.surface.ownerID!)?.elements.reversed()
        .filter { $0.surface == address.surface && $0.kind == .nativeText }.map { address.reference($0.id) } ?? []
    }
    for reference in candidates {
      guard let shown=elementPresentation(reference) else { continue }
      let delta=(address.worldOrigin ?? .zero).delta(to:shown.placement.origin)
      let local=CGPoint(x:point.x-delta.x,y:point.y-delta.y).applying(shown.placement.transform.inverted())
      guard shown.localBounds.contains(local) else { continue }
      let cuts=elementErasures(on:address.surface)[reference.elementID] ?? []
      if !cuts.isEmpty {
        guard elementErasureCache.appearance(surface:address.surface,id:reference.elementID,graphic:nil,layout:nil,
          size:shown.bodySize,erasures:cuts)?.contains(.init(x:local.x,y:local.y),tolerance:0) == true else { continue }
      }
      selectElement(reference);return nil
    }
    let fontSize = drawingToolSettings.textSize/screenScale
    guard (3...5760).contains(fontSize) else { return nil }
    let color = drawingToolSettings.textColor.components
    let style = NativeTextStyle(fontSize:fontSize,
      red:color.red,green:color.green,blue:color.blue,format:.init(fontName:drawingToolSettings.textFontName))
    let width = min(320/screenScale,address.bounds.map { $0.maxX-point.x } ?? .greatestFiniteMagnitude)
    let height = min(64/screenScale,address.bounds.map { $0.maxY-point.y } ?? .greatestFiniteMagnitude)
    guard width > 0, height > 0 else { return nil }
    let id = "text-" + UUID().uuidString.lowercased(), reference = address.reference(id)
    selectElement(reference)
    prepareNativeTextEditing(.init(reference:reference,address:address,
      frame:.init(x:point.x,y:point.y,width:width,height:height),source:"",style:style))
    editSelectedElement(reference)
    return id
  }

  /// Exact region candidates among already-authored vector ink. The query
  /// reads retained geometry directly and never waits for the paint cache.
  func regionGraphics(intersecting polygon:[SpatialPoint],at address:NotebookToolAddress,
    graph:NotebookGraphicGraph,spatial:NotebookDrawingToolController.SpatialSelectionSource? = nil)
    throws ->[EditableElementReference] {
    let origin=address.worldOrigin ?? .zero
    let candidates:AnySequence<NotebookGraphicGraph.Node>
    var spatialIDs=Set<String>()
    if address.surface.kind == .page,let pageID=address.surface.ownerID,
      let visible=try pageSelectionCandidates(polygon,pageID:pageID,graph:graph) {
      candidates=AnySequence(visible.layouts.keys.lazy.compactMap { graph.node($0) })
    } else if address.surface.kind == .page { candidates=AnySequence([]) }
    else {
      let indexed=try spatialCandidates(polygon,address:address,source:spatial,kinds:.elements)
      spatialIDs=spatialElementIDs(indexed)
      spatialIDs.formUnion(spatial?.changedElementIDs ?? [])
      candidates=AnySequence(spatialIDs.lazy.compactMap { graph.node($0) })
    }
    return candidates.compactMap { node in
      guard node.shown,node.graphic.freehand != nil,let layout=graph.resolve(node.id).layout else { return nil }
      guard node.surface == address.surface else { return nil }
      let reference=address.reference(node.id)
      let delta=origin.delta(to:node.origin),frame=layout.frame
      guard NotebookToolGeometry.intersects(.init(x:delta.x+frame.x,y:delta.y+frame.y,width:frame.width,height:frame.height),polygon:polygon) else { return nil }
      let local=polygon.compactMap { layout.framePoint($0,from:origin) }
      guard local.count == polygon.count else { return nil }
      let cuts=elementErasures(on:node.surface)[node.id] ?? []
      let appearance=NotebookElementAppearance(graphic:node.graphic,layout:layout,
        size:.init(width:frame.width,height:frame.height),erasures:cuts)
      return appearance.intersects(local.map { .init(x:$0.x,y:$0.y) }) ? reference : nil
    }
  }

  func elementsIntersecting(_ polygon:[SpatialPoint],at address:NotebookToolAddress,
    graph:NotebookGraphicGraph,spatial:NotebookDrawingToolController.SpatialSelectionSource? = nil)
    throws ->[EditableElementReference] {
    let origin=address.worldOrigin ?? .zero
    let candidates:AnySequence<NotebookGraphicGraph.Node>
    var pagePlacements:[String:NotebookElementPlacement]=[:]
    var spatialIDs=Set<String>()
    if address.surface.kind == .page,let pageID=address.surface.ownerID,origin == .zero,
      let visible=try pageSelectionCandidates(polygon,pageID:pageID,graph:graph) {
      pagePlacements=visible.placements
      candidates=AnySequence(visible.layouts.keys.lazy.compactMap { graph.node($0) })
    } else if address.surface.kind == .page { candidates=AnySequence([]) }
    else {
      let indexed=try spatialCandidates(polygon,address:address,source:spatial,kinds:.elements)
      spatialIDs=spatialElementIDs(indexed)
      spatialIDs.formUnion(spatial?.changedElementIDs ?? [])
      candidates=AnySequence(spatialIDs.lazy.compactMap { graph.node($0) })
    }
    var all=candidates.filter { node in
      guard node.shown,let layout=graph.resolve(node.id).layout else { return false }
      guard node.surface == address.surface else { return false }
      let delta=origin.delta(to:node.origin),frame=layout.frame
      guard NotebookToolGeometry.intersects(.init(x:delta.x+frame.x,y:delta.y+frame.y,width:frame.width,height:frame.height),polygon:polygon) else { return false }
      let local=polygon.compactMap { layout.framePoint($0,from:origin) }
      guard local.count == polygon.count else { return false }
      let cuts=elementErasures(on:node.surface)[node.id] ?? []
      return NotebookElementAppearance(graphic:node.graphic,layout:layout,
        size:.init(width:frame.width,height:frame.height),erasures:cuts)
        .intersects(local.map { .init(x:$0.x,y:$0.y) })
    }.map { address.reference($0.id) }
    if address.surface.kind == .page,let page=pages[address.surface.ownerID!] {
      all += pagePlacements.compactMap { id,placement -> EditableElementReference? in
        let reference=address.reference(id)
        guard elementCommandDrafts[reference]?.removed != true,
          let element=page.element(id:id),element.kind != .group,element.graphic == nil else { return nil }
        let presentation=NotebookElementPresentation(element,placement:placement)
        return nativeElementIntersects(presentation,id:id,surface:address.surface,
          polygon:polygon,from:origin) ? reference : nil
      }
    } else if let board=address.boardID ?? address.surface.ownerID,let spatial {
      let native:[SpatialElement]=spatialIDs.compactMap { id in
        spatial.index.element(id:id,boardID:board) ?? nativeElementSource(address.reference(id))?.spatial
      }
      let selected=native.filter { element in
        guard element.kind != .group,element.graphic == nil else { return false }
        guard element.surface == address.surface else { return false }
        guard let placement=graph.placement(element.id) else { return false }
        return nativeElementIntersects(.init(element,placement:placement),id:element.id,
          surface:element.surface,polygon:polygon,from:origin)
      }.map { address.reference($0.id) }
      all += selected
    }
    return Array(Set(all))
  }

  func itemsIntersecting(_ polygon:[SpatialPoint],at address:NotebookToolAddress,
    spatial:NotebookDrawingToolController.SpatialSelectionSource? = nil) throws ->[NotebookSelectedItem] {
    guard address.surface.kind == .board,let board=address.surface.ownerID,
      let spatial,let presence,presence.boardID == board else { return [] }
    let origin=address.worldOrigin ?? .zero
    let query=try spatialCandidates(polygon,address:address,source:spatial,kinds:.items)
    return (query?.entries ?? []).compactMap { entry -> NotebookSelectedItem? in
      guard case .item(let id)=entry.id,
        let item=spatial.index.renderedItem(id:id,presence:presence) else { return nil }
      let center=origin.delta(to:item.center),size=item.geometry
      let rect=CGRect(x:center.x-size.width/2,y:center.y-size.height/2,width:size.width,height:size.height)
      return NotebookToolGeometry.intersects(rect,polygon:polygon) ? .init(boardID:board,itemID:item.id) : nil
    }
  }
}
