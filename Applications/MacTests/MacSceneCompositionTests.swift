import AppKit
import NotebookCore
import SwiftUI
import WebKit
import XCTest
@testable import Notebook

@MainActor final class MacSceneCompositionTests: XCTestCase {
  func testVisibleProgramsHaveOneInteractiveOwnerBeforeAnyClick() async throws {
    let fixture = Fixture(), resources = SceneRenderResources()
    XCTAssertEqual(resources.profile, .interactive, "A windowed Mac is not a headless export")
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

  func testMountedProgramsAndStaticPixelsSurviveRepeatedZoomWithoutReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let command = MacCommandFixture(root: root), model = command.model, fixture = Fixture()
    retainNotebookUntilTeardown(model, removing: root)
    let header = try command.store.initializeWorkspace(actor: UUID(), pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try command.store.loadIndex(), before = try command.store.loadBoard(items: workspace.items)
    var hierarchy = before
    XCTAssertTrue(hierarchy.moveItem(workspace.selectedItemID, in: header.rootBoardID,
      to: .init(x: -100_000, y: -100_000), actor: model.actorID))
    for element in fixture.elements {
      XCTAssertTrue(hierarchy.upsertElement(element, in: header.rootBoardID, expected: nil, actor: model.actorID))
    }
    _ = try command.store.saveBoardEdits(before: before, after: hierarchy)
    try command.store.savePresence(fixture.presence)
    try await command.start()
    let viewport = fixture.presence.viewport
    let host = NSHostingView(rootView: NotebookMacCanvas(documentLayout: .constant(nil)).environment(model))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: viewport.x, height: viewport.y),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    func webViews(_ view: NSView) -> [WKWebView] {
      (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
    try await waitUntil { webViews(host).count == 4 }
    let programs = webViews(host), identities = Set(programs.map(ObjectIdentifier.init))
    XCTAssertEqual(programs.count, 4)
    try await waitUntil { programs.allSatisfy { !$0.isLoading } }
    for web in programs {
      _ = try await web.evaluateJavaScript("document.querySelector('input').value = 'unsaved draft'")
    }
    let address = SceneSourceAddress(plane: .board(header.rootBoardID), elementID: "static-svg")
    try await waitUntil { model.compositionTiles.published?.sourceReceipts[address]?.hasCurrentPixels == true }
    for scale in [0.15, 1.4, 0.3, 1.8, 0.2, 1.0] {
      model.updatePresence(fixture.presence.replacingCamera(.init(center: fixture.presence.camera.center, scale: scale)), settled: false)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(120))
      XCTAssertEqual(Set(webViews(host).map(ObjectIdentifier.init)), identities, "Zoom must not remount the program")
      XCTAssertNotNil(model.compositionTiles.published?.sourceRasters[address], "Ready drawing pixels must not disappear")
      for web in programs {
        XCTAssertFalse(web.visibleRect.isEmpty)
        XCTAssertEqual(web.bounds.width, 200, accuracy: 1, "Source layout stays at its physical size")
        let value = try await web.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(value, "unsaved draft")
      }
      model.updatePresence(try XCTUnwrap(model.presence), settled: true)
      try await Task.sleep(for: .milliseconds(80))
    }
    XCTAssertNil(model.compositionTiles.failure)
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

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(predicate())
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
