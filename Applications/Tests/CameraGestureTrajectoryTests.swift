import NotebookCore
import SwiftUI
import XCTest

@testable import Notebook

final class CameraGestureTrajectoryTests: XCTestCase {
  func testNoisyDirectionChangesCannotBecomeNewCameraBaselines() {
    let viewport = SpatialPoint(x: 834, y: 1_194)
    let centroid = CGPoint(x: 417, y: 597)
    let startingCamera = SpatialCamera(
      center: WorldPoint(x: 280, y: -160),
      scale: 0.65
    )
    let trajectory = CameraGestureTrajectory(
      startingCamera: startingCamera,
      startingCentroid: centroid,
      startingMagnification: 1,
      viewport: viewport
    )
    let startingStrength = NotebookDockingField.strength(
      camera: startingCamera,
      viewport: viewport, geometry: .notebook
    )
    let noisyMagnifications: [CGFloat] = [
      1.08, 1.079, 1.10, 1.099, 1.12, 1.119, 1.14, 1.139, 1.16,
    ]

    let displayed = noisyMagnifications.map { magnification in
      let raw = trajectory.camera(
        at: magnification,
        centroid: centroid,
        maximumScale: SpatialCamera.maximumScale
      )
      let fieldStrength = NotebookDockingField.strength(
        camera: raw,
        viewport: viewport, geometry: .notebook
      )
      return NotebookDockingField.attractedCamera(
        raw,
        toward: .zero,
        viewport: viewport, geometry: .notebook,
        correction: NotebookDockingField.approachCorrection(
          currentStrength: fieldStrength,
          startingStrength: startingStrength
        )
      )
    }

    XCTAssertLessThan(displayed.last?.scale ?? 1, 0.85)
    XCTAssertEqual(
      displayed[4].scale,
      displayCamera(
        trajectory: trajectory,
        magnification: 1.12,
        centroid: centroid,
        viewport: viewport,
        startingStrength: startingStrength
      ).scale,
      accuracy: 0.000_000_1
    )
  }

  func testReversingToTheSameFingerGeometryRetracesTheSameCamera() {
    let viewport = SpatialPoint(x: 1_194, y: 834)
    let start = CGPoint(x: 620, y: 390)
    let trajectory = CameraGestureTrajectory(
      startingCamera: SpatialCamera(
        center: WorldPoint(x: 120, y: 80),
        scale: 0.58
      ),
      startingCentroid: start,
      startingMagnification: 1,
      viewport: viewport
    )
    let startingStrength = NotebookDockingField.strength(
      camera: trajectory.startingCamera,
      viewport: viewport, geometry: .notebook
    )
    let first = displayCamera(
      trajectory: trajectory,
      magnification: 1.31,
      centroid: CGPoint(x: 655, y: 405),
      viewport: viewport,
      startingStrength: startingStrength
    )
    _ = displayCamera(
      trajectory: trajectory,
      magnification: 1.48,
      centroid: CGPoint(x: 680, y: 416),
      viewport: viewport,
      startingStrength: startingStrength
    )
    let returned = displayCamera(
      trajectory: trajectory,
      magnification: 1.31,
      centroid: CGPoint(x: 655, y: 405),
      viewport: viewport,
      startingStrength: startingStrength
    )

    let centerDelta = first.center.delta(to: returned.center)
    XCTAssertEqual(returned.scale, first.scale, accuracy: 0.000_000_1)
    XCTAssertEqual(centerDelta.x, 0, accuracy: 0.000_000_1)
    XCTAssertEqual(centerDelta.y, 0, accuracy: 0.000_000_1)
  }

  private func displayCamera(
    trajectory: CameraGestureTrajectory,
    magnification: CGFloat,
    centroid: CGPoint,
    viewport: SpatialPoint,
    startingStrength: Double
  ) -> SpatialCamera {
    let raw = trajectory.camera(
      at: magnification,
      centroid: centroid,
      maximumScale: SpatialCamera.maximumScale
    )
    let fieldStrength = NotebookDockingField.strength(
      camera: raw,
      viewport: viewport, geometry: .notebook
    )
    return NotebookDockingField.attractedCamera(
      raw,
      toward: .zero,
      viewport: viewport, geometry: .notebook,
      correction: NotebookDockingField.approachCorrection(
        currentStrength: fieldStrength,
        startingStrength: startingStrength
      )
    )
  }
}
