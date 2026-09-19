import Foundation
import NotebookCore

/// A lasso freezes the presented ink frontier. Mesh preparation can leave the
/// main actor; admission still compares that frontier before claiming strokes.
enum NotebookLassoInkSource: Sendable {
  case page(PageDocument)
  case spatial(SpatialInkJournal, Set<UUID>)
  var revision: String {
    switch self { case .page(let page): page.drawingStamp.revision; case .spatial(let journal,_): journal.stamp.revision }
  }
  struct Result: Sendable { let frame: PageRect; let graphic: NotebookGraphic }
  private struct Stroke {
    let id: UUID
    let color: SpatialInkColor
    let samples: [[SpatialInkSample]]
    let eraserIndex: Int
  }
  func selection(polygon: [SpatialPoint], surface: SurfaceID, origin: WorldPoint?, bounds: CGRect?) throws -> Result? {
    var strokes: [Stroke] = []
    var erasers: [[SpatialInkSample]] = [], sampleCount = 0
    func point(_ sample: SpatialInkSample) -> SpatialPoint {
      origin.flatMap { o in sample.worldPoint.map { o.delta(to:$0) } } ?? sample.point
    }
    func enclosed(_ samples: [[SpatialInkSample]]) -> Bool {
      !samples.isEmpty && samples.joined().allSatisfy { NotebookToolGeometry.contains(point($0),polygon:polygon) }
    }
    func retain(id: UUID, color: SpatialInkColor, samples: [[SpatialInkSample]]) throws {
      sampleCount += samples.reduce(0) { $0+$1.count }
      guard strokes.count < 1024, sampleCount <= 10_000 else {
        throw CollaborationError("selection_limit","Выделите меньшую часть рукописи: это выделение слишком большое.")
      }
      strokes.append(.init(id:id,color:color,samples:samples,eraserIndex:erasers.count))
    }
    switch self {
    case .page(let page):
      let drawing = try PageInkDrawing.decode(page.drawingData), suppressed = page.graphicPresentation.suppressedInkIDs
      for action in drawing.actions where action.isActive {
        try Task.checkCancellation()
        if action.tool == .eraser { if !strokes.isEmpty { erasers.append(action.samples) } }
        else if !suppressed.contains(action.id), enclosed([action.samples]) {
          try retain(id:action.id,color:action.color,samples:[action.samples])
        }
      }
    case .spatial(let journal,let suppressed):
      for action in journal.actions where action.isActive {
        try Task.checkCancellation()
        let samples = action.spans.filter { $0.surface == surface }.map(\.samples)
        if action.tool == .eraser { if !strokes.isEmpty { erasers += samples } }
        else if !suppressed.contains(action.id), action.spans.allSatisfy({ $0.surface == surface }), enclosed(samples) {
          try retain(id:action.id,color:action.color,samples:samples)
        }
      }
    }
    guard !strokes.isEmpty else { return nil }
    var box = CGRect.null
    for sample in strokes.flatMap(\.samples).joined() {
      let p = point(sample), radius = max(0.25,sample.width/2)*1.8
      box = box.union(.init(x:p.x-radius,y:p.y-radius,width:radius*2,height:radius*2))
    }
    if let bounds { box = box.intersection(bounds) }
    guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
    let frame = PageRect(x:box.minX,y:box.minY,width:box.width,height:box.height)
    let target = InkElementTarget(elementID:"lasso",frame:frame,worldOrigin:origin)
    var layers: [NotebookFreehand.Layer] = [], count = 0, eraserCursor = 0
    func append(_ samples: [SpatialInkSample], tool: SpatialInkTool, color: SpatialInkColor) throws {
      guard samples.count <= 10_000 else { throw CollaborationError("selection_limit","Слишком сложное выделение; выделите меньшую часть рукописи.") }
      let vertices = NotebookFreehand.mesh(samples:samples,frame:frame,origin:origin)
      count += vertices.count
      guard count <= NotebookFreehand.maximumVertices, layers.count < 2048 else {
        throw CollaborationError("selection_limit","Слишком сложное выделение; выделите меньшую часть рукописи.")
      }
      if !vertices.isEmpty { layers.append(.init(tool:tool,color:color,vertices:vertices)) }
    }
    // Retain chronological paint/erase layers, not duplicated cuts per stroke.
    // This is also the exact blend order consumed by the shared Metal renderer.
    for stroke in strokes {
      try Task.checkCancellation()
      for eraser in erasers[eraserCursor..<stroke.eraserIndex] where target.intersects(eraser) {
        try append(eraser,tool:.eraser,color:.black)
      }
      eraserCursor = stroke.eraserIndex
      for samples in stroke.samples { try append(samples,tool:.pen,color:stroke.color) }
    }
    for eraser in erasers.dropFirst(eraserCursor) where target.intersects(eraser) {
      try append(eraser,tool:.eraser,color:.black)
    }
    let ink = NotebookFreehand(layers:layers)
    guard ink.isValid else { throw CollaborationError("selection_limit","Выделите меньшую часть рукописи.") }
    guard !ink.paintPath(size:box.size,transform:nil).isEmpty else { return nil }
    return .init(frame:frame,graphic:.init(shape:.freehand,sourceInkIDs:strokes.map(\.id),freehand:ink))
  }
}
