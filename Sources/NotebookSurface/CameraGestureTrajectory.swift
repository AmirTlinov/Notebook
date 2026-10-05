/// One immutable camera basis for a pan or pinch. Every sample is solved from
/// the same initial contact; frame cadence and direction changes cannot drift it.
public struct CameraGestureTrajectory: Sendable {
  public let startingCamera: SpatialCamera
  public let startingCentroid: SpatialPoint
  public let viewport: SpatialPoint

  public init(startingCamera: SpatialCamera, startingCentroid: SpatialPoint, viewport: SpatialPoint) {
    self.startingCamera = startingCamera
    self.startingCentroid = startingCentroid
    self.viewport = viewport
  }

  public func camera(at magnification: Double, centroid: SpatialPoint,
    maximumScale: Double = SpatialCamera.maximumScale) -> SpatialCamera {
    startingCamera.pinched(by: magnification, from: startingCentroid,
      to: centroid, viewport: viewport, maximumScale: maximumScale)
  }
}
