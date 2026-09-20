import NotebookCore
import SwiftUI

/// Reuses the canonical tessellator; no approximate stroked centerline. Later
/// erasers are subtracted from the chosen stroke, never resurrected by light.
@MainActor enum NotebookAgentFeedbackInk {
  static func path(strokeID: UUID, reference: CollaborationReference, model: NotebookAppModel) -> Path? {
    guard let region = reference.region else { return nil }
    var vertices: [InkStrokeGeometry.Vertex] = []
    var erasures: [Path] = []
    func geometry(_ samples: InkMeasurements, origin: WorldPoint? = nil) -> Path {
      let points = samples.compactMap { sample -> InkStrokeGeometry.RenderPoint? in
        let point: SpatialPoint
        if let world = sample.worldPoint, let origin {
          let delta = origin.delta(to: world); point = .init(x:delta.x,y:delta.y)
        } else { point = sample.point }
        return .init(position:.init(Float(point.x-region.x),Float(point.y-region.y)),
          radius:max(0.25,Float(sample.width/2)),premultipliedColor:.init(repeating:1))
      }
      vertices.removeAll(keepingCapacity:true)
      InkStrokeGeometry.appendStrokeVertices(renderPoints:points,to:&vertices)
      var path = Path()
      for i in stride(from:0,to:vertices.count,by:3) {
        path.move(to:.init(x:Double(vertices[i].position.x),y:Double(vertices[i].position.y)))
        path.addLine(to:.init(x:Double(vertices[i+1].position.x),y:Double(vertices[i+1].position.y)))
        path.addLine(to:.init(x:Double(vertices[i+2].position.x),y:Double(vertices[i+2].position.y)))
        path.closeSubpath()
      }
      return path
    }
    var selected: Path?
    if reference.target.kind == .page {
      guard let page = model.pages[reference.target.id], !page.graphicPresentation.suppressedInkIDs.contains(strokeID),
        let drawing = try? PageInkDrawing.decode(page.drawingData) else { return nil }
      for action in drawing.activeActions {
        if action.id == strokeID, action.tool == .pen { selected = geometry(action.samples) }
        else if selected != nil, action.tool == .eraser { erasures.append(geometry(action.samples)) }
      }
    } else {
      guard model.compositionTiles.published?.liveData.suppressedInkIDs.contains(strokeID) != true else { return nil }
      let surface: SurfaceID = reference.target.kind == .cover ? .cover(reference.target.id) : .board(reference.target.id)
      for action in model.spatialInk?.actions ?? [] where action.isActive {
        for span in action.spans where span.surface == surface {
          if action.id == strokeID, action.tool == .pen { selected = geometry(span.samples,origin:reference.worldOrigin) }
          else if selected != nil, action.tool == .eraser { erasures.append(geometry(span.samples,origin:reference.worldOrigin)) }
        }
      }
    }
    guard var selected else { return nil }
    for erasure in erasures { selected = selected.subtracting(erasure) }
    return selected
  }
}
