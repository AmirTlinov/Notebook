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
    let ink: Task<NotebookLassoInkSource?,Never>?
    var points: [SpatialPoint]
  }
  private unowned let model: NotebookAppModel
  private(set) var contact: Contact?
  var ruler: NotebookRuler?
  private(set) var laserTraces: [NotebookLaserTrace] = []
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
    let ink: Task<NotebookLassoInkSource?,Never>?
    if model.drawingTool == .lasso {
      if let page = model.pages[address.surface.ownerID!], address.surface.kind == .page { ink = model.lassoInkSnapshot(page) }
      else if let journal = model.renderingInk(on:address.surface,fallback:model.compositionTiles.published?.liveData.ink) {
        let suppressed = Set(graph.nodes.values.filter { !$0.graphic.visible || $0.graphic.representation == .geometry }.flatMap { $0.graphic.sourceInkIDs })
        ink = Task { .spatial(journal,suppressed) }
      } else { ink = nil }
    } else { ink = nil }
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
    case .laser: expireLaser(current.id)
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
    var references = model.lassoElements(current.points,at:current.address,graph:current.graph)
    var items = model.lassoItems(current.points,at:current.address)
    if current.settings.lassoAddsToSelection {
      references += model.selectionSession.elements; items += model.selectionSession.items
    }
    model.selectElements(references,items:items)
    let selection = model.selectionSession.id
    lassoTask = Task { [weak self] in
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
        let items = model.selectionSession.items
        guard references.count+items.count+(result == nil ? 0 : 1) <= 32 else {
          model.showCue("Выберите не более 32 объектов за один раз."); return
        }
        if let result, let ink = source {
          let object = NotebookWorkingGraphic(id:current.id,surface:current.address.surface,frame:result.frame,
            worldOrigin:current.address.worldOrigin,graphic:result.graphic)
          if model.acceptAuthoredGraphic(object,at:current.address,expectedInkRevision:ink.revision) { references.append(current.address.reference(object.id)) }
        }
        if result != nil { model.selectElements(references,items:items) }
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
      fill:tool == .shape && settings.shapeFilled && fit.connection == nil ? .init(red:fill.red,green:fill.green,blue:fill.blue) : nil),connection:fit.connection,vertices:fit.vertices)
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

  /// A tap creates the real addressed object and focuses its ordinary inline
  /// editor. No modal draft, placeholder string or content-type guessing.
  @discardableResult
  func beginToolText(at point: SpatialPoint, address: NotebookToolAddress, screenScale: Double) -> String? {
    guard screenScale.isFinite, screenScale > 0 else { return nil }
    let fontSize = drawingToolSettings.textSize/screenScale
    guard (3...5760).contains(fontSize) else { return nil }
    let color = drawingToolSettings.textColor.components
    let style = NativeTextStyle(fontSize:fontSize,
      red:color.red,green:color.green,blue:color.blue)
    let width = min(320/screenScale,address.bounds.map { $0.maxX-point.x } ?? .greatestFiniteMagnitude)
    let height = min(64/screenScale,address.bounds.map { $0.maxY-point.y } ?? .greatestFiniteMagnitude)
    guard width > 0, height > 0 else { return nil }
    let id = "text-" + UUID().uuidString.lowercased(), reference = address.reference(id)
    do {
      var values: [String:JSONValue] = ["kind":.string("nativeText"),"source":.string(""),
        "frame":try .encode(PageRect(x:point.x,y:point.y,width:width,height:height)),"textStyle":try .encode(style)]
      if let origin = address.worldOrigin { values["worldOrigin"] = try .encode(origin) }
      guard performElementOperations([.init(reference:reference,kind:.insertElement,values:values)],
        summary:"Добавить текст",insertionTarget:address.target) else { return nil }
      selectElement(reference)
      editSelectedElement(reference)
      let selection = selectionSession.id, accepted = elementCommandSources[reference]?.task
      Task { [weak self] in
        guard let self, let result = await accepted?.value else { return }
        guard selectionSession.id == selection else {
          // Never remove text that has already received accepted input.
          let currentText: String?
          switch reference {
          case .page(let owner,let id): currentText = pages[owner]?.elements.first { $0.id == id }?.source
          case .spatial(let owner,let id): currentText = boardHierarchy?.board(owner)?.elements.first { $0.id == id }?.source
          }
          guard currentText?.isEmpty != false else { return }
          _ = performElementOperations([.init(reference:reference,kind:.removeElement,values:[:])],summary:"Отменить ввод текста",
            retainedSources:[reference:.init(target:address.target,id:id,page:result.page,spatial:result.spatial)])
          return
        }
      }
      return id
    } catch { showCue(error.localizedDescription); return nil }
  }

  func lassoElements(_ polygon: [SpatialPoint], at address: NotebookToolAddress, graph: NotebookGraphicGraph) -> [EditableElementReference] {
    let origin = address.worldOrigin ?? .zero
    let erasures = elementErasures(on:address.surface)
    let references = graph.nodes.values.filter { node in
      guard node.surface == address.surface, node.shown, let layout = graph.resolve(node.id).layout else { return false }
      let delta = origin.delta(to:node.origin), frame = layout.frame
      guard NotebookToolGeometry.intersects(.init(x:delta.x+frame.x,y:delta.y+frame.y,width:frame.width,height:frame.height),polygon:polygon) else { return false }
      let cuts = erasures[node.id] ?? []
      guard !cuts.isEmpty else { return true }
      return elementErasureCache.appearance(surface:address.surface,id:node.id,graphic:node.graphic,layout:layout,
        size:.init(width:frame.width,height:frame.height),erasures:cuts).map { $0.state != .erased } ?? false
    }.map { address.reference($0.id) }
    var all = references
    if address.surface.kind == .page, let page = pages[address.surface.ownerID!] {
      all += page.elements.filter { $0.graphic == nil && NotebookToolGeometry.intersects(.init(x:$0.frame.x,y:$0.frame.y,width:$0.frame.width,height:$0.frame.height),polygon:polygon) }.map { address.reference($0.id) }
    } else if let board = address.boardID ?? address.surface.ownerID, let cohort = compositionTiles.published {
      let elements = address.surface.kind == .cover
        ? cohort.frame.index.coverElements(itemID:address.surface.ownerID!,boardID:board)
        : cohort.frame.workset(boardID:board).elements
      all += elements.filter { element in
        guard element.surface == address.surface, element.graphic == nil else { return false }
        let delta = origin.delta(to:element.worldOrigin ?? .zero), f = element.frame
        return NotebookToolGeometry.intersects(.init(x:delta.x+f.x,y:delta.y+f.y,width:f.width,height:f.height),polygon:polygon)
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
