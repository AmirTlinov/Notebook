import NotebookCore
import SwiftUI

/// Owns the geometric camera path for one two-finger gesture.
///
/// Within one board every frame is solved from the same starting camera and
/// finger pair. Paper docking never becomes the next frame's baseline. A portal
/// handoff expresses the current camera and pair in the new board exactly once,
/// keeping the cumulative magnification of the same physical gesture.
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
