import AppKit
import NotebookCore
import SwiftUI
import WebKit
import XCTest
@testable import Notebook

@MainActor final class MacSceneCompositionTests: XCTestCase {
  func testVisiblePaperKeepsNativeInkBesideProgramsAcrossZoom() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let command = MacCommandFixture(root: root), model = command.model, actor = UUID()
    retainNotebookUntilTeardown(model, removing: root)
    var (workspace, _) = try command.store.loadOrCreate(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
    var hierarchy = try command.store.loadBoard(items: workspace.items)
    let boardID = workspace.rootBoardID, notebookID = workspace.selectedItemID
    let stamp = VersionStamp(counter: 0, actor: actor)
    XCTAssertTrue(hierarchy.moveItem(workspace.selectedItemID, in: boardID,
      to: .init(x: 3800, y: 600), actor: actor))
    let document = try XCTUnwrap(workspace.createDocument(title: "Full paper", actor: actor))
    let center = WorldPoint(x: 2098.2841376385095, y: 547.7435409354148)
    XCTAssertTrue(hierarchy.addItem(document.id, to: boardID, near: center, actor: actor))
    let frames: [SpatialRect] = [.init(x: 0, y: 0, width: 1120, height: 90),
      .init(x: 0, y: 120, width: 540, height: 290), .init(x: 0, y: 460, width: 540, height: 290),
      .init(x: 580, y: 460, width: 540, height: 290), .init(x: 0, y: 820, width: 540, height: 240),
      .init(x: 580, y: 820, width: 540, height: 240), .init(x: 0, y: 1120, width: 1120, height: 210)]
    for index in frames.indices {
      let html: String = (1...3).contains(index) ? "<button>Increment</button><input value='draft'>"
        : index > 3 ? "<svg viewBox='0 0 540 240'><rect width='540' height='240' fill='white'/></svg>" : ""
      XCTAssertTrue(hierarchy.upsertElement(.init(id: "element-\(index)", surface: .board(boardID), kind: index == 0 ? .nativeText : .web,
        frame: frames[index], worldOrigin: .zero, source: "\(index)", html: html, stamp: stamp),
        in: boardID, expected: nil, actor: actor))
    }
    try command.store.saveDocumentWorkspaceBundle(index: workspace,
      document: .init(id: document.id, actor: actor, paperSize: .a4),
      state: .init(id: document.id, actor: actor), board: hierarchy)
    var ink = try command.store.loadOrCreateSpatialInk(actor: actor)
    for line in 0..<8 {
      let samples = (0..<60).map { point in
        SpatialInkSample(point: .init(x: Double(point) * 18, y: 400 + Double(line) * 75 + sin(Double(point) / 9) * 30),
          timeOffset: Double(point) / 60, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      }
      _ = ink.append(tool: .pen, spans: [.init(surface: .cover(document.id), samples: samples)], actor: actor)
    }
    try command.store.saveSpatialInk(ink)
    let viewport = SpatialPoint(x: 1100, y: 728), geometry = WorkspaceItemGeometry.document(.a4)
    let initial = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 1571.4631430057862, y: 350.341394864676), scale: 1), viewport: viewport)
    try command.store.savePresence(initial)
    try await command.start()
    let host = NSHostingView(rootView: NotebookMacCanvas(documentLayout: .constant(nil)).environment(model))
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: viewport.x, height: viewport.y),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    try await waitUntil { model.compositionTiles.published != nil && !model.compositionTiles.isPreparing }
    for (step, scale) in [1.0, 0.19694791329734226, 2.0, 0.12, 0.28, 0.19694791329734226].enumerated() {
      let targetCenter = initial.camera.center.offsetBy(x: step.isMultiple(of: 2) ? -700 : 600,
        y: step.isMultiple(of: 2) ? 240 : -300)
      let presence = initial.replacingCamera(.init(center: targetCenter, scale: scale))
      let previousCamera = try XCTUnwrap(model.presence).camera
      let previous = previousCamera.scale
      let delta = previousCamera.center.delta(to: targetCenter)
      let started = Date()
      for tick in 1...15 {
        let fraction = Double(tick) / 15
        let current = initial.replacingCamera(.init(center: previousCamera.center.offsetBy(x: delta.x * fraction, y: delta.y * fraction),
          scale: exp(log(previous) * (1 - fraction) + log(scale) * fraction)))
        model.updatePresence(current, settled: false)
        try await Task.sleep(for: .milliseconds(16))
      }
      model.updatePresence(presence, settled: true)
      try await Task.sleep(for: .milliseconds(120))
      try await waitUntil { !model.compositionTiles.isPreparing }
      XCTAssertNil(model.compositionTiles.failure)
      let cohort = try XCTUnwrap(model.compositionTiles.published)
      let diagnostic = XCTAttachment(string: "scale=\(scale) seconds=\(Date().timeIntervalSince(started)) live=\(cohort.plan.allowsLive(.item(document.id), in: .board(boardID))) tiles=\(cohort.plan.tiles.count)")
      diagnostic.lifetime = .keepAlways; add(diagnostic)
      CATransaction.flush()
      let context = try XCTUnwrap(CGContext(data: nil, width: Int(viewport.x), height: Int(viewport.y),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.translateBy(x: 0, y: viewport.y); context.scaleBy(x: 1, y: -1)
      try XCTUnwrap(host.layer).render(in: context)
      let pixels = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
      let rect = geometry.screenFrame(center: center, camera: presence.camera, viewport: viewport)
      for (id, material, position) in [(document.id, geometry, center),
        (notebookID, WorkspaceItemGeometry.notebook, WorldPoint(x: 3800, y: 600))] {
        let paper = material.screenFrame(center: position, camera: presence.camera, viewport: viewport)
        if paper.x < viewport.x, paper.y < viewport.y, paper.x + paper.width > 0, paper.y + paper.height > 0 {
          XCTAssertTrue(cohort.plan.allowsLive(.item(id), in: .board(boardID)),
            "Visible paper must project its native ink, not wait behind decorative sources for each new tile window")
        }
      }
      XCTAssertLessThanOrEqual(cohort.plan.nativeOwnerCount, SceneCompositionPlan.maximumLiveOwners)
      for x in [0.15, 0.4, 0.65, 0.9] {
        for y in [0.2, 0.7, 0.9] {
          let sx = rect.x + rect.width * x, sy = rect.y + rect.height * y
          guard sx >= 0, sx < viewport.x, sy >= 0, sy < viewport.y else { continue }
          let color = try XCTUnwrap(pixels.colorAt(x: Int(sx), y: Int(sy))?.usingColorSpace(.deviceRGB))
          XCTAssertGreaterThan(color.redComponent, 0.94, "Missing paper at \(x),\(y); scale \(scale)")
        }
      }
      let attachment = XCTAttachment(data: try XCTUnwrap(pixels.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
      attachment.name = "Native paper zoom \(step)"; attachment.lifetime = .keepAlways; add(attachment)
    }
  }

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
