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

  @MainActor
  func testPreparedSurfaceTransfersSynchronouslyToTheNewCoordinateOwner() async throws {
    let journal = projectionJournal()
    let cache = SpatialInkMeshCache()
    let portal = SpatialInkMeshPreparation(cache: cache)
    let ready = expectation(description: "Портал уже показал окончательные чернила")
    var expectedCount = 0
    XCTAssertTrue(portal.update(surface: .board, journal: journal) { mesh in
      expectedCount = mesh?.batches.reduce(0) { $0 + $1.vertices.count } ?? 0
      if expectedCount > 0 { ready.fulfill() }
    })
    await fulfillment(of: [ready], timeout: 3)
    let active = SpatialInkMeshPreparation(cache: cache)
    var transferred: SpatialInkMesh?
    let pending = active.update(surface: .board, journal: journal) { transferred = $0 }
    XCTAssertFalse(pending, "Смена камеры получает уже готовую геометрию без новой фоновой работы")
    XCTAssertEqual(transferred?.batches.reduce(0) { $0 + $1.vertices.count }, expectedCount)
    portal.cancel(); active.cancel()
  }

  @MainActor
  func testIndependentInkWithAnUnchangedMaximumClockInvalidatesTheMesh() async throws {
    let cache = SpatialInkMeshCache()
    let preparation = SpatialInkMeshPreparation(cache: cache)
    var journal = projectionJournal()
    let before = try await prepare(preparation, surface: .board, journal: journal)
    let oldStamp = journal.stamp
    let action = SpatialInkAction(tool: .pen, spans: journal.actions[0].spans,
      stamp: .init(counter: 1, actor: UUID()))
    XCTAssertTrue(journal.merge(.init(actions: [action], stamp: action.stamp)))
    XCTAssertEqual(journal.stamp, oldStamp)
    let after = try await prepare(preparation, surface: .board, journal: journal)
    XCTAssertGreaterThan(after.batches.reduce(0) { $0 + $1.vertices.count },
      before.batches.reduce(0) { $0 + $1.vertices.count })
    for _ in 0..<1000 {
      XCTAssertFalse(preparation.update(surface: .board, journal: journal) { _ in
        XCTFail("Камера не пересобирает и не переустанавливает неизменённые чернила")
      })
    }
    preparation.cancel()
  }

  @MainActor
  func testMeshRetentionIsBoundedAndAnUncachedOwnerCannotShowPreviousInk() async throws {
    let journal = projectionJournal()
    let cache = SpatialInkMeshCache(capacity: 2, byteLimit: 1024 * 1024)
    let preparation = SpatialInkMeshPreparation(cache: cache)
    _ = try await prepare(preparation, surface: .board, journal: journal)
    for _ in 0..<6 {
      let owner = SurfaceID.board(UUID())
      var clearedImmediately = false
      let pending = preparation.update(surface: owner, journal: journal) { mesh in
        if let mesh, mesh.batches.isEmpty { clearedImmediately = true }
      }
      XCTAssertTrue(pending)
      XCTAssertTrue(clearedImmediately, "Новый владелец не показывает чернила старой доски даже в первом кадре")
      // Switching again cancels the obsolete request; only this owner may publish.
      _ = try await prepare(SpatialInkMeshPreparation(cache: cache), surface: owner, journal: journal)
      XCTAssertLessThanOrEqual(cache.count, 2)
      XCTAssertLessThanOrEqual(cache.retainedBytes, 1024 * 1024)
    }
    preparation.cancel()
    let tiny = SpatialInkMeshCache(capacity: 2, byteLimit: 1)
    _ = try await prepare(SpatialInkMeshPreparation(cache: tiny), surface: .board, journal: journal)
    XCTAssertEqual(tiny.count, 0)
    XCTAssertEqual(tiny.retainedBytes, 0)
  }

  @MainActor
  private func prepare(_ owner: SpatialInkMeshPreparation, surface: SurfaceID,
    journal: SpatialInkJournal) async throws -> SpatialInkMesh {
    let ready = expectation(description: "Окончательная геометрия готова")
    let received = MeshReception()
    let pending = owner.update(surface: surface, journal: journal) { value in
      if let value { received.mesh = value }
      if !received.updating { ready.fulfill() }
    }
    received.updating = false
    if pending { await fulfillment(of: [ready], timeout: 3) }
    else { ready.fulfill() }
    return try XCTUnwrap(received.mesh)
  }

  @MainActor private final class MeshReception {
    var mesh: SpatialInkMesh?
    var updating = true
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
