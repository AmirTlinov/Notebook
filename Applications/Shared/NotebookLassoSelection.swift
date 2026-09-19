import CoreGraphics
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
  func selection(polygon: [SpatialPoint], surface: SurfaceID, origin: WorldPoint?, bounds: CGRect?, screenScale: Double = 1) throws -> Result? {
    var strokes: [Stroke] = []
    var erasers: [[SpatialInkSample]] = [], sampleCount = 0
    func point(_ sample: SpatialInkSample) -> SpatialPoint {
      origin.flatMap { o in sample.worldPoint.map { o.delta(to:$0) } } ?? sample.point
    }
    func intersects(_ samples: [[SpatialInkSample]]) -> Bool {
      samples.contains { span in
        span.contains { sample in
          let p = point(sample), r = sample.width/2
          return NotebookToolGeometry.intersects(.init(x:p.x-r,y:p.y-r,width:max(0.01,r*2),height:max(0.01,r*2)),polygon:polygon)
        } || zip(span,span.dropFirst()).contains { NotebookToolGeometry.intersects(from:point($0),to:point($1),polygon:polygon) }
      }
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
        else if !suppressed.contains(action.id), intersects([action.samples]) {
          try retain(id:action.id,color:action.color,samples:[action.samples])
        }
      }
    case .spatial(let journal,let suppressed):
      for action in journal.actions where action.isActive {
        try Task.checkCancellation()
        let samples = action.spans.filter { $0.surface == surface }.map(\.samples)
        if action.tool == .eraser { if !strokes.isEmpty { erasers += samples } }
        else if !suppressed.contains(action.id), action.spans.allSatisfy({ $0.surface == surface }), intersects(samples) {
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
      if tool == .eraser {
        // Keep the exact sweep compact; a long eraser contact must not exhaust
        // the unrelated pen-mesh budget and make all handwriting unselectable.
        let local = samples.map { sample in
          let p = point(sample)
          return NotebookFreehand.Eraser.Sample(point:.init(x:p.x-frame.x,y:p.y-frame.y),width:sample.width)
        }
        layers.append(.init(eraser:.init(size:.init(x:frame.width,y:frame.height),samples:local)))
        return
      }
      let vertices = NotebookFreehand.mesh(samples:samples,frame:frame,origin:origin,tool:tool)
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
    guard Self.hasVisiblePaint(ink,frame:frame,polygon:polygon,scale:screenScale) else { return nil }
    return .init(frame:frame,graphic:.init(shape:.freehand,sourceInkIDs:strokes.map(\.id),freehand:ink))
  }
  /// Selection asks whether the contacted pixels contain paint. Filling the
  /// ordered triangle layers directly avoids an enormous vector boolean union
  /// merely to discover that a previously erased stroke is invisible.
  private static func hasVisiblePaint(_ ink: NotebookFreehand, frame: PageRect,
    polygon: [SpatialPoint], scale: Double) -> Bool {
    let selection = polygon.reduce(CGRect.null) { $0.union(.init(x:$1.x,y:$1.y,width:0.01,height:0.01)) }
    let box = selection.intersection(.init(x:frame.x,y:frame.y,width:frame.width,height:frame.height))
    guard !box.isNull, box.width > 0, box.height > 0, scale.isFinite, scale > 0 else { return false }
    // One screen pixel is the selection unit. The lasso itself is viewport
    // bounded; no page/world-sized image or approximation of its path is needed.
    let width = max(1,Int(ceil(box.width*scale))), height = max(1,Int(ceil(box.height*scale)))
    guard width <= 8192, height <= 8192,
      let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width,
        space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
    context.scaleBy(x:scale,y:scale); context.translateBy(x:-box.minX,y:-box.minY)
    let clip = CGMutablePath()
    if let first = polygon.first {
      clip.move(to:.init(x:first.x,y:first.y))
      for p in polygon.dropFirst() { clip.addLine(to:.init(x:p.x,y:p.y)) }
      clip.closeSubpath()
    }
    context.addPath(clip); context.clip()
    context.translateBy(x:frame.x,y:frame.y)
    // This is a coverage mask, not a painted image. A whole overlapping eraser
    // mesh in one CGPath makes CoreGraphics intersect every edge with every
    // other edge. Rasterize bounded triangle batches instead; chronological
    // paint/erase order and the exact measured tessellation stay unchanged.
    func paint(_ layers: ArraySlice<NotebookFreehand.Layer>) {
      for layer in layers {
        context.setFillColor(gray:layer.tool == .eraser ? 0 : 1,alpha:1)
        let vertices = layer.renderVertices
        for start in stride(from:0,to:vertices.count,by:96) {
          if Task.isCancelled { return }
          let batch = Array(vertices[start..<min(start+96,vertices.count)])
          context.addPath(NotebookFreehand.path(batch,size:.init(width:frame.width,height:frame.height)))
          context.fillPath()
        }
      }
    }
    guard let data = context.data?.assumingMemoryBound(to:UInt8.self) else { return false }
    func hasPaint() -> Bool { UnsafeBufferPointer(start:data,count:width*height).contains { $0 != 0 } }
    // Paint after the final cut cannot be erased by any older contact. Prove
    // visibility there first instead of replaying the whole page's eraser history.
    let tail = ink.layers.lastIndex(where:{ $0.tool == .eraser }).map { $0+1 } ?? 0
    paint(ink.layers[tail...])
    if hasPaint() { return !Task.isCancelled }
    paint(ink.layers[..<tail])
    return !Task.isCancelled && hasPaint()
  }

}
