import NotebookCore
import Testing

@Suite("Camera gesture retains its initial coordinate basis")
struct CameraGestureTrajectoryTests {
  @Test func noisyDirectionChangesCannotBecomeNewCameraBaselines() {
    let centroid = SpatialPoint(x:417,y:597)
    let trajectory = CameraGestureTrajectory(
      startingCamera:.init(center:.init(x:280,y:-160),scale:0.65),
      startingCentroid:centroid,viewport:.init(x:834,y:1194))
    let samples = [1.08,1.079,1.10,1.099,1.12,1.119,1.14,1.139,1.16]
      .map { trajectory.camera(at:$0,centroid:centroid) }
    #expect(samples.last!.scale < 0.85)
    #expect(samples[4] == trajectory.camera(at:1.12,centroid:centroid))
  }

  @Test func reversingFingerGeometryRetracesTheSameCamera() {
    let trajectory = CameraGestureTrajectory(
      startingCamera:.init(center:.init(x:120,y:80),scale:0.58),
      startingCentroid:.init(x:620,y:390),viewport:.init(x:1194,y:834))
    let first = trajectory.camera(at:1.31,centroid:.init(x:655,y:405))
    _ = trajectory.camera(at:1.48,centroid:.init(x:680,y:416))
    #expect(trajectory.camera(at:1.31,centroid:.init(x:655,y:405)) == first)
  }
}
