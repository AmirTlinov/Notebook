import NotebookCore
import SwiftUI

/// Owns the geometric camera path for one two-finger gesture.
///
/// Every frame is solved from the same starting camera and finger pair.
/// No frame becomes the next frame's baseline, and zoom never changes boards.
struct CameraGestureTrajectory {
  let startingCamera: SpatialCamera
  let startingCentroid: CGPoint
  let viewport: SpatialPoint

  func camera(
    at magnification: CGFloat,
    centroid: CGPoint,
    maximumScale: Double
  ) -> SpatialCamera {
    startingCamera.pinched(
      by: Double(magnification),
      from: SpatialPoint(
        x: startingCentroid.x,
        y: startingCentroid.y
      ),
      to: SpatialPoint(x: centroid.x, y: centroid.y),
      viewport: viewport,
      maximumScale: maximumScale
    )
  }
}
