import NotebookCore
import SwiftUI

/// Owns the geometric camera path for one two-finger gesture.
///
/// Every frame is solved from the same starting camera and finger pair. A
/// semantic correction may change what is displayed, but it never becomes the
/// starting point of the next frame.
struct CameraGestureTrajectory {
  let startingCamera: SpatialCamera
  let startingCentroid: CGPoint
  let startingMagnification: CGFloat
  let viewport: SpatialPoint

  func camera(
    at magnification: CGFloat,
    centroid: CGPoint,
    maximumScale: Double
  ) -> SpatialCamera {
    startingCamera.pinched(
      by: Double(magnification)
        / max(Double(startingMagnification), 0.001),
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
