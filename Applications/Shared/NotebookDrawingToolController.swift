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
  @ObservationIgnored private var lassoTask: Task<Void,Never>?
  @ObservationIgnored var onContactCancellation: (() -> Void)?
  init(model: NotebookAppModel) { self.model = model }

  @discardableResult
  func begin(at point: SpatialPoint, address: NotebookToolAddress, screenScale: Double) -> Bool {
    guard !model.drawingTool.usesInkJournal, address.surface.ownerID != nil,
      screenScale.isFinite, screenScale > 0 else { return false }
    cancel()
    let graph: NotebookGraphicGraph
    if address.surface.kind == .page, let page = model.pages[address.surface.ownerID!] { graph = model.graphicGraph(page:page,preview:false) }
    else if let board = address.boardID ?? address.surface.ownerID, let cohort = model.compositionTiles.published {
      graph = model.presentedGraphicGraph(boardID:board,cohort:cohort,preview:false)
    } else { graph = .init([]) }
    let ink: Task<NotebookLassoInkSource?,Never>?
    if model.drawingTool == .lasso {
      if let page = model.pages[address.surface.ownerID!], address.surface.kind == .page { ink = model.lassoInkSnapshot(page) }
      else if let journal = model.renderingInk(on:address.surface,fallback:model.compositionTiles.published?.liveData.ink) {
        let suppressed = Set(graph.nodes.values.filter { !$0.graphic.visible || $0.graphic.representation == .geometry }.flatMap { $0.graphic.sourceInkIDs })
        ink = Task { .spatial(journal,suppressed) }
      } else { ink = nil }
    } else { ink = nil }
    contact = .init(id:UUID(),tool:model.drawingTool,settings:model.drawingToolSettings,pen:model.penStyle,
      address:address,graph:graph,screenScale:screenScale,ink:ink,points:[point])
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
    if let object = figure(current) { model.updateWorkingGraphic(object,strokeID:current.id) }
  }

  func finish() {
    guard let current = contact else { return }
    contact = nil
    onContactCancellation = nil
    switch current.tool {
    case .shape, .connector, .ruler:
      if let object = figure(current), hypot(current.points[0].x-current.points.last!.x,current.points[0].y-current.points.last!.y)*current.screenScale >= 4 {
        model.acceptAuthoredGraphic(object,at:current.address)
      } else { model.updateWorkingGraphic(nil,strokeID:current.id) }
    case .lasso: finishLasso(current)
    case .text:
      model.beginToolText(at:current.points[0],address:current.address,screenScale:current.screenScale)
    case .laser: break
    case .pen,.marker,.eraser: assertionFailure("Ink belongs to the measured journal adapter")
    }
  }

  func cancel() {
    lassoTask?.cancel(); lassoTask = nil
    if let contact { model.updateWorkingGraphic(nil,strokeID:contact.id) }
    contact = nil
    let cancellation = onContactCancellation; onContactCancellation = nil
    cancellation?()
  }

  private func finishLasso(_ current: Contact) {
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
        var references = model.lassoElements(current.points,at:current.address,graph:current.graph)
        if current.settings.lassoAddsToSelection { references += model.selectionSession.elements }
        references = Array(Set(references))
        guard references.count + (result == nil ? 0 : 1) <= 32 else {
          model.showCue("Выберите не более 32 объектов за один раз."); return
        }
        if let result, let ink = source {
          let object = NotebookWorkingGraphic(id:current.id,surface:current.address.surface,frame:result.frame,
            worldOrigin:current.address.worldOrigin,graphic:result.graphic)
          if model.acceptAuthoredGraphic(object,at:current.address,expectedInkRevision:ink.revision) { references.append(current.address.reference(object.id)) }
        }
        model.selectElements(references)
      } catch is CancellationError {} catch { self?.model.showCue(error.localizedDescription) }
    }
  }

  private func figure(_ current: Contact) -> NotebookWorkingGraphic? {
    let tool = current.tool, settings = current.settings
    guard [.shape,.connector,.ruler].contains(tool), let last = current.points.last else { return nil }
    let shape = tool == .shape ? settings.shape : tool == .connector ? .arrow : .line
    let color = (tool == .shape ? settings.shapeColor : tool == .connector ? settings.connectionColor : current.pen.color).components
    let width = tool == .shape ? settings.shapeWidth : tool == .connector ? settings.connectionWidth : current.pen.width
    var end = tool == .ruler ? NotebookToolGeometry.rulerEnd(from:current.points[0],to:last,angle:settings.rulerAngle,
      grid:settings.rulerSnapToGrid ? PhysicalPaper.gridSpacing : nil) : last
    if let bounds = current.address.bounds {
      let start = current.points[0]
      var dx = end.x-start.x, dy = end.y-start.y
      if tool == .shape && settings.preservesAspect && ![DrawingShape.line,.arrow].contains(shape) {
        let side = min(max(abs(dx),abs(dy)),dx < 0 ? start.x-bounds.minX : bounds.maxX-start.x,
          dy < 0 ? start.y-bounds.minY : bounds.maxY-start.y)
        dx = (dx < 0 ? -1 : 1)*side; dy = (dy < 0 ? -1 : 1)*side
      }
      let tx = dx == 0 ? 1 : (dx > 0 ? bounds.maxX-start.x : bounds.minX-start.x)/dx
      let ty = dy == 0 ? 1 : (dy > 0 ? bounds.maxY-start.y : bounds.minY-start.y)/dy
      let t = min(1,max(0,min(tx,ty)))
      end = .init(x:start.x+dx*t,y:start.y+dy*t)
    }
    guard var fit = NotebookToolGeometry.figure(from:current.points[0],to:end,shape:shape,
      preservesAspect:tool == .shape && settings.preservesAspect,width:width) else { return nil }
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
    }
    let stroke = SpatialInkColor(red:color.red,green:color.green,blue:color.blue)
    let graphic = NotebookGraphic(shape:fit.shape,style:.init(stroke:stroke,strokeWidth:width,
      fill:tool == .shape && settings.shapeFilled && fit.connection == nil ? stroke : nil),connection:fit.connection,vertices:fit.vertices)
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
      guard [(0.0,0.0),(1,0),(1,1),(0,1)].allSatisfy({ x,y in
        NotebookToolGeometry.contains(.init(x:delta.x+frame.x+x*frame.width,y:delta.y+frame.y+y*frame.height),polygon:polygon)
      }) else { return false }
      let cuts = erasures[node.id] ?? []
      guard !cuts.isEmpty else { return true }
      return elementErasureCache.appearance(surface:address.surface,id:node.id,graphic:node.graphic,layout:layout,
        size:.init(width:frame.width,height:frame.height),erasures:cuts).map { $0.state != .erased } ?? false
    }.map { address.reference($0.id) }
    return references
  }
}
