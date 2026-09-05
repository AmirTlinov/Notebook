import NotebookCore
import XCTest
@testable import Notebook

final class SpatialInkProjectionTests: XCTestCase {
  func testWorldProjectionPreservesPrecisionAtDistantTiles() throws {
    let origin = WorldPoint(tileX: 1_000_000, tileY: -1_000_000, localX: 10, localY: 20)
    let viewport = SpatialPoint(x: 1366, y: 1024)
    let sample = origin.offsetBy(x: 0.125, y: -0.25)
    for scale in [0.02, 0.5, 1.0, 4.0] {
      let camera = SpatialCamera(center: origin.offsetBy(x: 70, y: -50), scale: scale)
      let transform = SpatialInkMesh.Projection.world(origin).transform(camera: camera, viewport: viewport)
      let expected = camera.worldToScreen(sample, viewport: viewport)
      XCTAssertEqual(Double(Float(0.125) * transform.x + transform.z), expected.x, accuracy: 0.0001)
      XCTAssertEqual(Double(Float(-0.25) * transform.y + transform.w), expected.y, accuracy: 0.0001)
    }
  }

  @MainActor
  func testCameraFramesNeverReinstallThePreparedMesh() throws {
    let view = InkCanvasView(frame: .init(x: 0, y: 0, width: 834, height: 1194))
    view.applySpatial(try SpatialInkMesh.prepare(surface: .board, journal: projectionJournal()))
    let revision = view.spatialMeshInstallCount
    for frame in 0..<1000 {
      view.project(camera: .init(center: .init(x: Double(frame), y: -10), scale: 0.7),
        viewport: .init(x: 834, y: 1194))
    }
    XCTAssertEqual(view.spatialMeshInstallCount, revision)
  }

  func testTileBatchingPreservesEraserOrderAndEveryStroke() throws {
    let journal = projectionJournal()
    let mesh = try SpatialInkMesh.prepare(surface: .board, journal: journal)
    XCTAssertEqual(mesh.batches.map(\.tool), [.pen, .eraser, .pen])
    let single = try SpatialInkMesh.prepare(surface: .board,
      journal: .init(actions: [journal.actions[0]], stamp: journal.stamp))
    XCTAssertEqual(mesh.batches[0].vertices.count, single.batches[0].vertices.count * 2)
    XCTAssertEqual(mesh.batches[1].vertices.count, single.batches[0].vertices.count)
    XCTAssertEqual(mesh.batches[2].vertices.count, single.batches[0].vertices.count)
    XCTAssertEqual(mesh.batches[0].projection,
      .world(.init(tileX: 1_000_000, tileY: -1_000_000, localX: 0, localY: 0)))
  }

  private func projectionJournal() -> SpatialInkJournal {
    let actor = UUID()
    let actions = [SpatialInkTool.pen, .pen, .eraser, .pen].enumerated().map { index, tool in
      SpatialInkAction(tool: tool, spans: [.init(surface: .board, samples: [
        .init(point: .init(x: 10, y: 20),
          worldPoint: .init(tileX: 1_000_000, tileY: -1_000_000, localX: Double(index) + 10, localY: 20),
          timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      ])], stamp: .init(counter: UInt64(index + 1), actor: actor))
    }
    return .init(actions: actions, stamp: .init(counter: 4, actor: actor))
  }

  func testFinishedScreenStrokeFollowsTheNextCameraBeforeJournalReplay() {
    let first = SpatialCamera(center: .init(x: 500, y: -200), scale: 0.5)
    let next = SpatialCamera(center: .init(x: 640, y: -170), scale: 1.7)
    let oldSize = SpatialPoint(x: 834, y: 1194), nextSize = SpatialPoint(x: 1366, y: 1024)
    let point = SpatialPoint(x: 50, y: 300)
    let expected = next.worldToScreen(first.screenToWorld(point, viewport: oldSize), viewport: nextSize)
    let transform = SpatialInkMesh.Projection.screen(first, oldSize).transform(camera: next, viewport: nextSize)
    XCTAssertEqual(Double(Float(point.x) * transform.x + transform.z), expected.x, accuracy: 0.001)
    XCTAssertEqual(Double(Float(point.y) * transform.y + transform.w), expected.y, accuracy: 0.001)
  }
  @MainActor
  func testInterruptedSpringLeavesTheLastPublishedCamera() async throws {
    let start = SessionPresence(mode: .board, camera: .init(scale: 0.3), viewport: .init(x: 834, y: 1194))
    let target = SessionPresence(mode: .board, camera: .init(center: .init(x: 600, y: -500), scale: 1), viewport: start.viewport)
    XCTAssertEqual(SceneCameraSettlement.sample(from: start, to: target, fraction: 0), start)
    XCTAssertEqual(SceneCameraSettlement.sample(from: start, to: target, fraction: 1), target)
    let owner = SceneCameraSettlement()
    var shown = start, samples = 0
    var finished = false
    owner.start(from: start, to: target, duration: 0.3, bounce: 0.025) { value, settled in
      shown = value; samples += 1; XCTAssertFalse(settled)
    } completion: { finished = true }
    try await Task.sleep(for: .milliseconds(60))
    owner.cancel()
    let interrupted = shown, count = samples
    XCTAssertGreaterThan(count, 1)
    XCTAssertNotEqual(interrupted, target)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(shown, interrupted)
    XCTAssertEqual(samples, count)
    XCTAssertFalse(finished)
  }

}
