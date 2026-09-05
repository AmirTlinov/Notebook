import Foundation
import NotebookCore
import PencilKit

extension PageInkAction {
  init(
    id: UUID = UUID(), tool: SpatialInkTool, color: SpatialInkColor = .black,
    points: [PKStrokePoint]
  ) {
    self.init(
      id: id, tool: tool, color: color,
      samples: points.map { point in
        SpatialInkSample(
          point: .init(x: point.location.x, y: point.location.y), timeOffset: point.timeOffset,
          width: point.size.width, opacity: point.opacity, force: point.force,
          azimuth: point.azimuth, altitude: point.altitude)
      })
  }
}
