import CoreGraphics
import Foundation
@testable import NotebookCore

/// Unreduced tessellation oracle only; production retains measured bodies.
extension NotebookFreehand {
  static func meshControl(samples: some Sequence<SpatialInkSample>, frame: PageRect, origin: WorldPoint?, tool: SpatialInkTool = .pen) -> [Vertex] {
    var points: [InkStrokeGeometry.RenderPoint] = []
    for sample in samples {
      let p = origin.flatMap { o in sample.worldPoint.map { o.delta(to:$0) } } ?? sample.point
      let alpha = Float(sample.opacity)
      let next = InkStrokeGeometry.RenderPoint(position:.init(Float(p.x-frame.x),Float(p.y-frame.y)),
        radius:max(0.25,Float(sample.width/2)),premultipliedColor:.init(repeating:alpha))
      if let last = points.last, InkStrokeGeometry.areCoincident(last,next) { points[points.count-1] = next }
      else { points.append(next) }
    }
    var vertices: [InkStrokeGeometry.Vertex] = []
    if tool == .eraser { InkStrokeGeometry.appendEraserVertices(renderPoints:points,to:&vertices) }
    else { InkStrokeGeometry.appendStrokeVertices(renderPoints:points,to:&vertices) }
    return vertices.map { .init(x:Double($0.position.x)/frame.width,y:Double($0.position.y)/frame.height,opacity:Double($0.premultipliedColor.w)) }
  }
}
