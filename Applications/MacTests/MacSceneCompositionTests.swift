import AppKit
import NotebookCore
import SwiftUI
import WebKit
import XCTest
@testable import Notebook

@MainActor final class MacSceneCompositionTests: XCTestCase {
  func testVisibleProgramsHaveOneInteractiveOwnerBeforeAnyClick() async throws {
    let fixture = Fixture(), resources = SceneRenderResources()
    XCTAssertEqual(resources.profile, .interactive, "Live composition retains the interactive resource profile")
    XCTAssertEqual(resources.passiveByteLimit, resources.byteLimit, "Mac has no separate Pencil backing reservation")
    let coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    coordinator.prepare(source: fixture.source, presence: fixture.presence,
      frame: fixture.frame(fixture.presence), pinned: [], displayScale: 2)
    try await waitUntil { coordinator.published != nil || coordinator.failure != nil }
    XCTAssertNil(coordinator.failure)
    let cohort = try XCTUnwrap(coordinator.published)
    let owners = Set((0..<4).map {
      SceneSourceAddress(plane: .board(fixture.presence.boardID), elementID: "program-\($0)")
    })
    XCTAssertEqual(cohort.runtimeOwners, owners,
      "Mounted programs must not be replaced by background snapshots that queue behind each other")
    for owner in owners {
      let focus = InteractiveElementReference.board(boardID: owner.plane.boardID, elementID: owner.elementID)
      XCTAssertEqual(resources.webActivity(for: focus).activeLeaseCount, 0,
        "Composition cannot start a second executor for a program owned by its mounted view")
    }
    await coordinator.stop()
  }

  func testStaticSourceRetainsPixelsThroughoutZoomRefinement() async throws {
    let fixture = Fixture(), resources = SceneRenderResources()
    let coordinator = SceneCompositionTiles(resources: resources)
    addTeardownBlock { @MainActor in await coordinator.stop() }
    let address = SceneSourceAddress(plane: .board(fixture.presence.boardID), elementID: "static-svg")
    func prepare(_ presence: SessionPresence) {
      coordinator.prepare(source: fixture.source, presence: presence, frame: fixture.frame(presence),
        pinned: [], displayScale: 2)
    }
    prepare(fixture.presence)
    try await waitUntil { coordinator.published?.sourceReceipts[address]?.hasCurrentPixels == true || coordinator.failure != nil }
    XCTAssertNil(coordinator.failure)
    for scale in [0.15, 1.4, 0.3, 1.8, 0.2, 1.0] {
      let presence = SessionPresence(boardID: fixture.presence.boardID, mode: .board,
        camera: .init(center: fixture.presence.camera.center, scale: scale), viewport: fixture.presence.viewport)
      prepare(presence)
      for _ in 0..<8 {
        let cohort = try XCTUnwrap(coordinator.published)
        let raster = try XCTUnwrap(cohort.sourceRasters[address], "Refinement must retain the last source, not replace it with a blank")
        XCTAssertFalse(raster.isReleased)
        try await Task.sleep(for: .milliseconds(30))
      }
    }
    XCTAssertNil(coordinator.failure)
    await coordinator.stop()
  }

  @discardableResult
  private func waitUntil(message: () -> String = { "The expected scene must become ready" },
    _ predicate: () async -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(8)
    var ready = await predicate()
    while !ready, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
      ready = await predicate()
    }
    XCTAssertTrue(ready, message())
    return ready
  }

  private struct Fixture {
    let elements: [SpatialElement]
    let source: SceneCompositionSource
    let index: WorkspaceSceneIndex
    let presence: SessionPresence
    init() {
      let stamp = VersionStamp(counter: 0, actor: UUID())
      let notebook = WorkspaceItem.notebook(title: "Offscreen", pageIDs: [UUID()])
      let workspace = WorkspaceIndex(items: [notebook], selectedItemID: notebook.id,
        selectedPageID: notebook.pageIDs[0], stamp: stamp)
      let boardID = WorkspaceRoot.boardID
      var elements = (0..<4).map { index in
        SpatialElement(id: "program-\(index)", surface: .board(boardID), kind: .web,
          frame: .init(x: Double(index % 2) * 220, y: Double(index / 2) * 120, width: 200, height: 100),
          worldOrigin: .zero, source: "Program \(index)", html: "<button>Increment</button><input value='draft'>", stamp: stamp)
      }
      elements.append(.init(id: "static-svg", surface: .board(boardID), kind: .web,
        frame: .init(x: 180, y: 260, width: 80, height: 80), worldOrigin: .zero, source: "Drawing",
        html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 80 80'><rect width='80' height='80' fill='red'/></svg>", stamp: stamp))
      self.elements = elements
      let hierarchy = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID,
        board: .init(freeItems: [.init(itemID: notebook.id, center: .init(x: -100_000, y: -100_000), zIndex: 0, stamp: stamp)],
          elements: elements, stamp: stamp))], stamp: stamp)
      index = .init(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
      source = .init(index: index, hierarchy: hierarchy, journal: .init(stamp: stamp))
      presence = .init(boardID: boardID, mode: .board,
        camera: .init(center: .init(x: 220, y: 180), scale: 1), viewport: .init(x: 1100, y: 780))
    }
    func frame(_ presence: SessionPresence) -> WorkspaceSceneFrame {
      .init(index: index, presence: presence, portalCamera: { _ in nil })
    }
  }
}
