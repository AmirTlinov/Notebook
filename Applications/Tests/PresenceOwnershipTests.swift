import TetradCore
import XCTest
@testable import Tetrad

final class PresenceOwnershipTests: XCTestCase {
  @MainActor
  func testActiveCameraFrameDoesNotReplaceTheDurableContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = TetradStore(root: root)
    let model = TetradAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let stable = try store.loadPresence()
    let notebookID = try XCTUnwrap(model.workspace?.selectedNotebookID)
    let active = SessionPresence(
      mode: .cover,
      camera: SpatialCamera(center: stable.camera.center, scale: 0.84),
      viewport: stable.viewport,
      focusedNotebookID: notebookID,
      openProgress: 0.5
    )

    model.updatePresence(active, settled: false)

    XCTAssertEqual(model.presence, active)
    XCTAssertEqual(model.presencePhase, .active)
    XCTAssertEqual(try store.loadPresence(), stable)
  }

  @MainActor
  func testSettledPageCannotPersistAtATransitionalScale() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = TetradStore(root: root)
    let model = TetradAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let notebookID = try XCTUnwrap(model.workspace?.selectedNotebookID)
    let center = try XCTUnwrap(model.board?.placement(of: notebookID)?.center)
    let broken = SessionPresence(
      mode: .page,
      camera: SpatialCamera(center: center, scale: 0.487_891_719_906_063),
      viewport: SpatialPoint(x: 834, y: 1_194),
      focusedNotebookID: notebookID,
      openProgress: 1
    )

    model.updatePresence(broken, settled: true)

    XCTAssertEqual(model.presence?.camera.scale, 1)
    XCTAssertEqual(model.presence?.camera.center, center)
    XCTAssertEqual(try store.loadPresence().camera.scale, 1)
  }

  @MainActor
  func testSettledBoardKeepsTheScaleChosenForInspection() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = TetradStore(root: root)
    let model = TetradAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: PageSize(width: 834, height: 1_194))
    let viewport = SpatialPoint(x: 834, y: 1_194)
    let inspected = SessionPresence(
      mode: .board,
      camera: SpatialCamera(center: WorldPoint(x: 90, y: -40), scale: 0.68),
      viewport: viewport
    )

    model.updatePresence(inspected, settled: true)

    XCTAssertEqual(model.presence, inspected)
    XCTAssertEqual(try store.loadPresence(), inspected)
  }
}
