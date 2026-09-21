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
  struct Contact: Sendable {
    let id: UUID
    let tool: DrawingTool
    let settings: NotebookDrawingToolSettings
    let pen: PenStyle
    let address: NotebookToolAddress
    let graph: NotebookGraphicGraph
    let screenScale: Double
    let ink: Task<NotebookLassoInkSource.Prepared?,Never>?
    var points: [SpatialPoint]
  }
  private unowned let model: NotebookAppModel
  private(set) var contact: Contact?
  var ruler: NotebookRuler?
  private(set) var laserTraces: [NotebookLaserTrace] = []
  @ObservationIgnored private var inkSnapshotCache: (key: String, task: Task<NotebookLassoInkSource.Prepared?,Never>)?
  @ObservationIgnored private var lassoTask: Task<Void,Never>?
  @ObservationIgnored var onContactCancellation: (() -> Void)?
  init(model: NotebookAppModel) { self.model = model }
  var selectsWorkspaceItems: Bool { model.drawingTool == .lasso && model.presence?.mode == .board }

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
    if [.laser,.ruler,.text].contains(model.drawingTool) { graph = .init([]) }
    else if address.surface.kind == .page, let page = model.pages[address.surface.ownerID!] { graph = model.graphicGraph(page:page) }
    else if let board = address.boardID ?? address.surface.ownerID {
      graph = model.authoredGraphicGraph(boardID:board)
    } else { graph = .init([]) }
    let ink = model.drawingTool == .lasso && model.drawingToolSettings.lassoSelectsInk
      ? inkSnapshot(at:address,graph:graph) : nil
    if model.drawingTool == .ruler, ruler?.address.surface != address.surface {
      ruler = .init(address:address,start:point,angle:model.drawingToolSettings.rulerAngle,length:PhysicalPaper.pointsPerCentimeter*10)
    }
    contact = .init(id:UUID(),tool:model.drawingTool,settings:model.drawingToolSettings,pen:model.penStyle,
      address:address,graph:graph,screenScale:screenScale,ink:ink,points:[point])
    if let contact, contact.tool == .laser {
      laserTraces.append(.init(id:contact.id,address:address,color:contact.settings.laserColor,
        width:4/screenScale,lifetime:contact.settings.laserDuration,
        samples:[.init(point:point,time:Date.timeIntervalSinceReferenceDate)]))
    }
    return true
  }

  private func inkSnapshot(at address: NotebookToolAddress, graph: NotebookGraphicGraph) -> Task<NotebookLassoInkSource.Prepared?,Never>? {
    let raw: Task<NotebookLassoInkSource?,Never>
    if let page = model.pages[address.surface.ownerID!], address.surface.kind == .page { raw = model.lassoInkSnapshot(page) }
    else {
      guard let journal = model.renderingInk(on:address.surface,fallback:model.compositionTiles.published?.liveData.ink) else { return nil }
      let suppressed = Set(graph.nodes.values.filter { !$0.graphic.visible || $0.graphic.representation == .geometry }.flatMap { $0.graphic.sourceInkIDs })
      raw = Task { .spatial(journal,suppressed) }
    }
    return Task { [weak self] in
      guard let source = await raw.value, let self else { return nil }
      let key = source.cacheKey(surface:address.surface)
      if let cached = inkSnapshotCache, cached.key == key {
        return await cached.task.value?.excluding(source.suppressed)
      }
      let task = Task.detached(priority:.userInitiated) {
        try? source.prepare(surface:address.surface,origin:address.worldOrigin)
      }
      inkSnapshotCache?.task.cancel()
      inkSnapshotCache = (key,task)
      return await task.value
    }
  }

  func selectInk(at point: SpatialPoint, address: NotebookToolAddress, screenScale: Double) {
    cancel()
    let graph = address.surface.kind == .page
      ? model.pages[address.surface.ownerID!].map { model.graphicGraph(page:$0) } ?? .init([])
      : model.authoredGraphicGraph(boardID:address.boardID ?? address.surface.ownerID!)
    let radius = 6/max(0.001,screenScale)
    var settings = model.drawingToolSettings
    settings.lassoSelectsInk = true; settings.lassoSelectsObjects = false; settings.lassoAddsToSelection = false
    finishLasso(.init(id:UUID(),tool:.lasso,settings:settings,pen:model.penStyle,address:address,graph:.init([]),
      screenScale:screenScale,ink:inkSnapshot(at:address,graph:graph),points:[
        .init(x:point.x-radius,y:point.y-radius),.init(x:point.x+radius,y:point.y-radius),
        .init(x:point.x+radius,y:point.y+radius),.init(x:point.x-radius,y:point.y+radius)]))
  }

  func move(to point: SpatialPoint) {
    guard var current = contact, point.x.isFinite, point.y.isFinite else { return }
    var point = point
    if let bounds = current.address.bounds {
      point = .init(x:min(bounds.maxX,max(bounds.minX,point.x)),y:min(bounds.maxY,max(bounds.minY,point.y)))
    }
    if current.tool == .lasso || current.tool == .laser {
      if let last = current.points.last, hypot(last.x-point.x,last.y-point.y)*current.screenScale < 1 { return }
      if current.points.count >= 4096 { current.points = current.points.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
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
    var pending: [Task<Void, Never>] = []
    var references = model.lassoElements(current.points,at:current.address,graph:current.graph,
      includesInk:current.settings.lassoSelectsInk,includesObjects:current.settings.lassoSelectsObjects,
      waiting: { pending.append($0) })
    var items = current.settings.lassoSelectsObjects ? model.lassoItems(current.points,at:current.address) : []
    if current.settings.lassoAddsToSelection {
      references += model.selectionSession.elements; items += model.selectionSession.items
    }
    model.selectElements(references,items:items)
    let selection = model.selectionSession.id
    lassoTask = Task { [weak self] in
      for task in pending {
        await task.value
        guard !Task.isCancelled else { return }
      }
      let source = await current.ink?.value
      guard !Task.isCancelled else { return }
      let preparation = Task.detached(priority:.userInitiated) {
        try source?.selection(polygon:current.points,surface:current.address.surface,
          origin:current.address.worldOrigin,bounds:current.address.bounds)
      }
      do {
        let result = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        guard !Task.isCancelled, let self, model.selectionSession.id == selection else { return }
        var references = model.selectionSession.elements
        if !pending.isEmpty {
          references += model.lassoElements(current.points,at:current.address,graph:current.graph,
            includesInk:current.settings.lassoSelectsInk,includesObjects:current.settings.lassoSelectsObjects)
          references = Array(Set(references))
        }
        let items = model.selectionSession.items
        guard references.count+items.count+(result == nil ? 0 : 1) <= 32 else {
          model.showCue("Выберите не более 32 объектов за один раз."); return
        }
        if let result, let ink = source {
          let object = NotebookWorkingGraphic(id:current.id,surface:current.address.surface,frame:result.frame,
            worldOrigin:current.address.worldOrigin,graphic:result.graphic)
          if model.acceptAuthoredGraphic(object,at:current.address,expectedInkRevision:ink.revision) { references.append(current.address.reference(object.id)) }
        }
        if result != nil || !pending.isEmpty { model.selectElements(references,items:items) }
      } catch is CancellationError {} catch { self?.model.showCue(error.localizedDescription) }
    }
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
  @discardableResult
  func acceptAuthoredGraphic(_ object: NotebookWorkingGraphic, at address: NotebookToolAddress, expectedInkRevision: String? = nil) -> Bool {
    guard var values = try? ["kind":JSONValue.string("graphic"),"source":.string(""),
      "frame":.encode(object.frame),"graphic":.encode(object.graphic)] else { return false }
    if let origin = address.worldOrigin { values["worldOrigin"] = try? .encode(origin) }
    var accepted = object; accepted.accepted = true
    if object.graphic.freehand == nil || address.surface.kind == .page { updateWorkingGraphic(accepted,strokeID:object.strokeID) }
    if !performElementOperations([.init(reference:address.reference(object.id),kind:object.graphic.sourceInkIDs.isEmpty ? .insertElement : .convertInkToElement,values:values)],
      summary:"Нарисовать: " + object.graphic.shape.displayName,insertionTarget:address.target,expectedInkRevision:expectedInkRevision) {
      workingGraphics.removeAll { $0.id == object.id }; return false
    }
    return true
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

  func lassoElements(_ polygon: [SpatialPoint], at address: NotebookToolAddress, graph: NotebookGraphicGraph,
    includesInk: Bool = true, includesObjects: Bool = true,
    waiting: ((Task<Void, Never>) -> Void)? = nil) -> [EditableElementReference] {
    let origin = address.worldOrigin ?? .zero
    let erasures = elementErasures(on:address.surface)
    let candidates:AnySequence<NotebookGraphicGraph.Node>
    if address.surface.kind == .page,let pageID=address.surface.ownerID,origin == .zero,
      let x=polygon.map(\.x).min(),let y=polygon.map(\.y).min(),let right=polygon.map(\.x).max(),let bottom=polygon.map(\.y).max() {
      let visible=graph.visiblePageGraphics(pageID,in:.init(x:x,y:y,width:right-x,height:bottom-y))
      candidates=AnySequence(visible.layouts.keys.lazy.compactMap { graph.node($0) })
    } else { candidates=graph.nodes.values }
    let references = candidates.filter { node in
      guard (node.graphic.freehand != nil ? includesInk : includesObjects), node.surface == address.surface, node.shown, let layout = graph.resolve(node.id).layout else { return false }
      let delta = origin.delta(to:node.origin), frame = layout.frame
      guard NotebookToolGeometry.intersects(.init(x:delta.x+frame.x,y:delta.y+frame.y,width:frame.width,height:frame.height),polygon:polygon) else { return false }
      let local = polygon.compactMap { layout.framePoint($0,from:origin) }
      guard local.count == polygon.count else { return false }
      let cuts = erasures[node.id] ?? []
      let appearance = cuts.isEmpty
        ? NotebookElementAppearance(graphic:node.graphic,layout:layout,size:.init(width:frame.width,height:frame.height),erasures:[])
        : elementErasureCache.appearance(surface:address.surface,id:node.id,graphic:node.graphic,layout:layout,
            size:.init(width:frame.width,height:frame.height),erasures:cuts)
      guard let appearance else {
        if let task = elementErasureCache.pendingPreparation(surface:address.surface,id:node.id) { waiting?(task) }
        return false
      }
      guard appearance.state != .erased else { return false }
      return appearance.intersects(local.map { .init(x:$0.x,y:$0.y) })
    }.map { address.reference($0.id) }
    guard includesObjects else { return references }
    func visible(_ id: String, _ frame: CGRect) -> Bool {
      let cuts = erasures[id] ?? []
      guard !cuts.isEmpty else { return true }
      if let appearance = elementErasureCache.appearance(surface:address.surface,id:id,graphic:nil,layout:nil,
        size:frame.size,erasures:cuts) { return appearance.state != .erased }
      if let task = elementErasureCache.pendingPreparation(surface:address.surface,id:id) { waiting?(task) }
      return false
    }
    var all = references
    if address.surface.kind == .page, let page = pages[address.surface.ownerID!] {
      all += page.displayElements(graphicIDs:[]).filter { element in
        guard element.kind != .group, element.graphic == nil else { return false }
        let f = elementPresentationFrame(address.reference(element.id),fallback:element.frame)
        let rect = CGRect(x:f.x,y:f.y,width:f.width,height:f.height)
        return NotebookToolGeometry.intersects(rect,polygon:polygon) && visible(element.id,rect)
      }.map { address.reference($0.id) }
    } else if let board = address.boardID ?? address.surface.ownerID, let cohort = compositionTiles.published {
      let elements = address.surface.kind == .cover
        ? cohort.frame.index.coverElements(itemID:address.surface.ownerID!,boardID:board)
        : cohort.frame.workset(boardID:board).elements
      all += elements.filter { element in
        guard element.surface == address.surface, element.kind != .group, element.graphic == nil else { return false }
        // A grouped body is placed in its ancestor's world basis, not its
        // unchanged source origin. Picking must use the same placement as paint.
        let placement = graph.placement(element.id)
        let delta = origin.delta(to:placement?.origin ?? element.worldOrigin ?? .zero)
        let f = elementPresentationFrame(address.reference(element.id),fallback:NotebookTextTypography.frame(element))
        return NotebookToolGeometry.intersects(.init(x:delta.x+f.x,y:delta.y+f.y,width:f.width,height:f.height),polygon:polygon)
          && visible(element.id,.init(x:f.x,y:f.y,width:f.width,height:f.height))
      }.map { address.reference($0.id) }
    }
    return all
  }

  func lassoItems(_ polygon: [SpatialPoint], at address: NotebookToolAddress) -> [NotebookSelectedItem] {
    guard address.surface.kind == .board, let board = address.surface.ownerID,
      let cohort = compositionTiles.published, let presence, presence.boardID == board else { return [] }
    let origin = address.worldOrigin ?? .zero
    return presentedWorkset(cohort:cohort,boardID:board,presence:presence).items.compactMap { item in
      let center = origin.delta(to:item.center), size = item.geometry
      let rect = CGRect(x:center.x-size.width/2,y:center.y-size.height/2,width:size.width,height:size.height)
      return NotebookToolGeometry.intersects(rect,polygon:polygon) ? .init(boardID:board,itemID:item.id) : nil
    }
  }
}
