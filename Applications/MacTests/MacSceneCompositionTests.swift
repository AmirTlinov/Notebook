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

  func testHundredThousandPagePaintCandidatesKeepResolvedCrossingsAndGlobalClaims() throws {
    let actor = UUID(), count = 100_000, region = PageRect(x: 480, y: 480, width: 40, height: 40)
    let bounds = CGRect(x: region.x, y: region.y, width: region.width, height: region.height), claimedID = UUID()
    func shape(_ id: String, frame: PageRect, graphic: NotebookGraphic = .init(shape: .rectangle), parent: String? = nil) -> AgentElement {
      .init(id: id, kind: .graphic, frame: frame, source: "", html: "", graphic: graphic, parentID: parent)
    }
    let group = AgentElement(id: "group", kind: .group, frame: .init(x: 100, y: 100, width: 100, height: 100),
      source: "", html: "", basis: .init(size: .init(x: 100, y: 100),
        transform: .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)))
    let erasedFrame = PageRect(x: 490, y: 490, width: 20, height: 20)
    let textFrame = PageRect(x: 480, y: 430, width: 100, height: 10)
    let collisionID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    var elements = (0..<count).map { shape("distant-\($0)",
      frame: .init(x: 600 + Double($0 % 100), y: 890 + Double($0 % 100), width: 5, height: 5)) }
    elements += [group, shape("escaped", frame: .init(x: 380, y: -310, width: 30, height: 30), parent: group.id),
      shape("left", frame: .init(x: 80, y: 490, width: 20, height: 20)),
      shape("right", frame: .init(x: 850, y: 490, width: 20, height: 20)),
      shape("edge", frame: .init(x: 800, y: 800, width: 50, height: 50), graphic: .init(shape: .connector,
        connection: .init(start: .init(point: .zero, binding: .init(elementID: "left")),
          end: .init(point: .zero, binding: .init(elementID: "right"))))),
      .init(id: "overflow", kind: .nativeText, frame: textFrame, source: Array(repeating: "Body", count: 8).joined(separator: "\n"), html: ""),
      .init(id: "erased", kind: .nativeText, frame: erasedFrame, source: "Erased source", html: ""),
      shape("losing-claim", frame: erasedFrame, graphic: .init(shape: .rectangle, sourceInkIDs: [claimedID])),
      shape("winning-offscreen-claim", frame: .init(x: 900, y: 900, width: 20, height: 20),
        graphic: .init(shape: .rectangle, sourceInkIDs: [claimedID])),
      .init(id: collisionID, kind: .nativeText, frame: erasedFrame, source: "First exact owner", html: ""),
      .init(id: collisionID.lowercased(), kind: .nativeText, frame: erasedFrame, source: "Second exact owner", html: "")]
    let drawing = PageInkDrawing(actions: [
      .init(id: claimedID, tool: .pen, samples: [.init(point: .init(x: 500, y: 500), timeOffset: 0,
        width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)]),
      .init(tool: .eraser, samples: [.init(point: .init(x: 500, y: 500), timeOffset: 0,
        width: 200, opacity: 1, force: 1, azimuth: 0, altitude: 1)], sequence: 1,
        elementTargets: [.init(elementID: "erased", frame: erasedFrame, wholeElement: true)])])
    // The production sparse causal format admits this full source without
    // manufacturing one field frontier per workload object in the fixture.
    let base = PageDocument(size: .init(width: 1000, height: 1000), actor: actor, drawingData: try drawing.dataRepresentation())
    let page = try JSONValue.encode(base).setting("elements", .encode(elements)).setting("collaboration", .null).decode(PageDocument.self)
    let graphStarted = ContinuousClock.now, graph = page.graphicGraph()
    graph.prepareVisibility(on: .page(page.id))
    let graphElapsed = graphStarted.duration(to: .now), queryStarted = ContinuousClock.now
    let selected = PageCompositionRenderer.elements(in: page, region: region, elementID: nil)
    let queryElapsed = queryStarted.duration(to: .now)
    let expected = page.elements.filter { element in
      let presentation = element.graphic == nil ? graph.placement(element.id).map { NotebookElementPresentation(element, placement: $0) } : nil
      guard let frame = graph.resolve(element.id).layout?.frame ?? presentation?.frame else { return false }
      return element.kind != .group && (element.graphic == nil || page.graphicPresentation.geometryIDs.contains(element.id))
        && (element.graphic == nil || graph.resolve(element.id).layout != nil)
        && bounds.intersects(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
    }
    XCTAssertEqual(selected, expected, "Visibility narrows preparation while the existing exact painter predicate and source order remain authoritative")
    XCTAssertEqual(selected.map(\.id), ["escaped", "edge", "overflow", "erased", collisionID, collisionID.lowercased()])
    XCTAssertTrue(page.graphicPresentation.suppressedInkIDs.contains(claimedID), "Off-window claim arbitration still suppresses the raw contact")
    XCTAssertFalse(selected.contains { $0.id == "losing-claim" })
    XCTAssertEqual(PageCompositionRenderer.elements(in: page, region: region, elementID: collisionID.lowercased()).map(\.id),
      [collisionID.lowercased()], "Exact selected-element export keeps the second owner of a canonical UUID collision")
    XCTAssertTrue(try XCTUnwrap(page.inkDrawing().elementErasures["erased"]).contains { $0.target.wholeElement })
    let nextRegion = PageRect(x: 850, y: 490, width: 20, height: 20)
    XCTAssertTrue(PageCompositionRenderer.elements(in: page, region: nextRegion, elementID: nil).contains { $0.id == "right" })
    XCTAssertEqual(page.elements.count, count + 11)
    print("PAGE_PAINT_SCALE source_elements=\(page.elements.count) selected=\(selected.count) graph=\(graphElapsed) warm_query=\(queryElapsed)")
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
