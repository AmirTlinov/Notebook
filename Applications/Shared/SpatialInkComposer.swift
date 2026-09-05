import NotebookCore
import PencilKit

enum SpatialInkRenderLayer {
  case ink(points: [PKStrokePoint], color: SpatialInkColor)
  case erase(points: [PKStrokePoint])
}

enum SpatialInkComposer {
  static func pageLayers(_ drawing: PageInkDrawing) -> [SpatialInkRenderLayer] {
    drawing.actions.map { action in
      let points = action.samples.map { point($0,location:CGPoint(x:$0.point.x,y:$0.point.y),widthScale:1) }
      return action.tool == .pen ? .ink(points:points,color:action.color) : .erase(points:points)
    }
  }

  static func boardLayers(
    board: SurfaceID,
    journal: SpatialInkJournal?,
    camera: SpatialCamera,
    viewport: SpatialPoint
  ) -> [SpatialInkRenderLayer] {
    guard let journal else { return [] }
    return layers(for: board, in: journal) { sample in
      guard let worldPoint = sample.worldPoint else { return nil }
      let screen = camera.worldToScreen(worldPoint, viewport: viewport)
      return point(
        sample,
        location: CGPoint(x: screen.x, y: screen.y),
        widthScale: camera.scale
      )
    }
  }

  static func localLayers(
    for surface: SurfaceID,
    journal: SpatialInkJournal?
  ) -> [SpatialInkRenderLayer] {
    guard let journal else { return [] }
    return layers(for: surface, in: journal) { sample in
      point(
        sample,
        location: CGPoint(x: sample.point.x, y: sample.point.y),
        widthScale: 1
      )
    }
  }

  private static func layers(
    for surface: SurfaceID,
    in journal: SpatialInkJournal,
    point transform: (SpatialInkSample) -> PKStrokePoint?
  ) -> [SpatialInkRenderLayer] {
    var result: [SpatialInkRenderLayer] = []
    for action in journal.actions where action.isActive {
      for span in action.spans where span.surface == surface {
        let points = span.samples.compactMap(transform)
        guard !points.isEmpty else { continue }
        if action.tool == .pen {
          result.append(.ink(points: points, color: action.color))
        } else {
          result.append(.erase(points: points))
        }
      }
    }
    return result
  }

  private static func point(
    _ sample: SpatialInkSample,
    location: CGPoint,
    widthScale: Double
  ) -> PKStrokePoint {
    PKStrokePoint(
      location: location,
      timeOffset: sample.timeOffset,
      size: CGSize(
        width: sample.width * widthScale,
        height: sample.width * widthScale
      ),
      opacity: sample.opacity,
      force: sample.force,
      azimuth: sample.azimuth,
      altitude: sample.altitude
    )
  }
}
