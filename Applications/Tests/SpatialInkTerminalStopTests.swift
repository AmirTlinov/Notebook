import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SpatialInkTerminalStopTests: XCTestCase {
  func testStoppedCanvasReleasesItsSourceAndMeshWhileItsNativeLeaseRemainsRetained() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let lease = try XCTUnwrap(fixture.tiles.published?.nativeInk)
    let surface = SurfaceID.board(fixture.boardID)
    let canvas = try XCTUnwrap(fixture.mount.inkView)
    let before = try Self.inkPixels(fixture.mount)
    XCTAssertGreaterThan(before, 0)
    let action = try fixture.contact()
    try await Self.waitUntil { canvas.isStableFramePresented }
    let acceptedPixels = try Self.inkPixels(fixture.mount)
    XCTAssertGreaterThan(acceptedPixels, before)
    let acceptedSource = try XCTUnwrap(canvas.installedSpatialSource).referenceInk()
    XCTAssertTrue(acceptedSource.actions.contains { $0.id == action.id })
    let vertices = canvas.committedVertexCount
    XCTAssertGreaterThan(vertices, 0)
    XCTAssertGreaterThan(canvas.spatialDrawableAccountedBytes, 0)

    // Ordinary handoff is not a terminal release, even after accepted input.
    fixture.parkAndRemount()
    XCTAssertTrue(fixture.mount.inkView === canvas)
    XCTAssertEqual(canvas.committedVertexCount, vertices)
    XCTAssertEqual(try canvas.installedSpatialSource?.referenceInk(), acceptedSource)
    try await Self.waitUntil { canvas.isStableFramePresented }
    XCTAssertEqual(try Self.inkPixels(fixture.mount), acceptedPixels)

    let saved = await fixture.queue.flush()
    XCTAssertTrue(saved, fixture.queue.failure ?? "")
    let durable = try await fixture.queue.submit { try $0.readSpatialInk(surfaces: [surface]) }
    XCTAssertEqual(durable.actions.first { $0.id == action.id }, action)
    // Hold stop behind a real native presentation transaction, not a sleep or
    // a synthetic completion. No local frame reference outlives installation.
    var nativeFrame: InkCanvasView.PreparedSpatialFrame? = try await canvas.prepareSpatialFrame(nil,
      size: .init(x: canvas.bounds.width, y: canvas.bounds.height), displayScale: 2)
    let owner = try XCTUnwrap(lease.owners[surface])
    let pending = SpatialInkSceneLease(registry: lease.registry, rootBoardID: fixture.boardID,
      focusedCoverID: lease.focusedCoverID,
      owners: lease.owners, updates: [.init(owner: owner, generation: canvas.spatialSourceGeneration,
        frame: nativeFrame, journal: durable)])
    nativeFrame = nil
    var transactionCommitted = false
    pending.afterPresentationTransaction { transactionCommitted = true }
    try pending.install()
    XCTAssertFalse(transactionCommitted)
    XCTAssertEqual(canvas.committedVertexCount, vertices)
    XCTAssertEqual(try canvas.installedSpatialSource?.referenceInk(), acceptedSource)
    await fixture.stop()
    XCTAssertTrue(transactionCommitted, "Terminal release waits for the already submitted native transaction")

    // Simulate a UIKit configuration retaining the lease after its real view
    // has dismantled. ARC is deliberately not the terminal resource contract.
    XCTAssertTrue(lease.owners[surface]?.canvas === canvas)
    XCTAssertNil(canvas.installedSpatialSource)
    XCTAssertEqual(canvas.committedVertexCount, 0)
    XCTAssertEqual(canvas.committedEraserVertexCount, 0)
    XCTAssertEqual(canvas.residentCommittedBufferBytes, 0)
    XCTAssertEqual(canvas.spatialDrawableAccountedBytes, 0)
    XCTAssertFalse(canvas.isStableFramePresented)
    XCTAssertEqual(fixture.resources.reservedBytes, 0)
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
    XCTAssertEqual(fixture.resources.activePhysicalOwnerCount, 0)

    // A late ordinary native-mount update cannot repopulate the stopped owner.
    fixture.mount.update(lease: lease, surface: surface, boardID: fixture.boardID,
      camera: .init(scale: 1), active: false)
    canvas.draw(in: canvas)
    XCTAssertNil(fixture.mount.inkView)
    XCTAssertNil(canvas.installedSpatialSource)
    XCTAssertEqual(canvas.committedVertexCount, 0)
    XCTAssertEqual(fixture.resources.reservedBytes, 0)
  }

  private static func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate(), "The actual native frame did not become ready", file: file, line: line)
  }

  private static func inkPixels(_ view: UIView) throws -> Int {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
      UIColor.white.setFill(); context.fill(view.bounds)
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let cg = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
      bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return stride(from: 0, to: cg.width * cg.height * 4, by: 4).filter {
      bytes[$0] < 160 && bytes[$0 + 1] < 160 && bytes[$0 + 2] < 160
    }.count
  }

  @MainActor
  private final class Fixture {
    let actor: UUID, boardID: UUID, root: URL, store: NotebookStore
    let resources = SceneRenderResources(), tiles: SceneCompositionTiles
    let gate = NotebookInputGate(), queue: NotebookPersistenceQueue
    let window: UIWindow, host = TerminalInkHost()
    let mount = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 384, height: 384))
    let viewport = SpatialPoint(x: 384, y: 384), camera = SpatialCamera(scale: 1)
    private var coordinator: SpatialInkCanvas.Coordinator?
    private var journal: SpatialInkJournal
    private var accepted: SpatialInkAction?
    private weak var previousKeyWindow: UIWindow?

    static func make() async throws -> Fixture {
      let fixture = try Fixture()
      let workspace = try fixture.store.loadIndex()
      let hierarchy = try fixture.store.loadBoard(items: workspace.items)
      let header = try fixture.store.workspaceHeader()
      let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
      let presence = SessionPresence(boardID: fixture.boardID, mode: .board,
        camera: fixture.camera, viewport: fixture.viewport)
      let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
      fixture.tiles.prepare(source: .init(store: fixture.store, revision: header.cursor, workspaceID: header.workspaceID),
        presence: presence, frame: frame, pinned: [], displayScale: 2)
      try await waitUntil { fixture.tiles.published != nil || fixture.tiles.failure != nil }
      _ = try XCTUnwrap(fixture.tiles.published, fixture.tiles.failure ?? "")
      fixture.window.frame = fixture.mount.frame
      fixture.window.rootViewController = fixture.host
      fixture.host.view.backgroundColor = .white; fixture.host.view.addSubview(fixture.mount)
      fixture.window.makeKeyAndVisible()
      try await waitUntil { fixture.host.appeared }
      fixture.coordinator = .init(surfaceRegistry: fixture.tiles.surfaceRegistry, inputGate: fixture.gate) { [weak fixture] in
        fixture?.accept(tool: $0, color: $1, spans: $2)
      }
      fixture.update()
      try await waitUntil { fixture.mount.inkView?.isStableFramePresented == true }
      return fixture
    }

    private init() throws {
      actor = UUID()
      root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-native-ink-" + UUID().uuidString)
      store = NotebookStore(root: root)
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      boardID = header.rootBoardID
      let workspace = try store.loadIndex()
      var hierarchy = try store.loadBoard(items: workspace.items)
      _ = hierarchy.moveItem(workspace.selectedItemID, in: boardID, to: .init(x: 100_000, y: 100_000), actor: actor)
      try store.saveBoard(hierarchy, items: workspace.items)
      journal = .init(stamp: .init(counter: 0, actor: actor))
      _ = journal.append(tool: .pen, spans: [.init(surface: .board(boardID), samples: [-80.0, 0, 80].enumerated().map { index, x in
        .init(point: .zero, worldPoint: .init(x: x, y: 0), timeOffset: Double(index) / 10,
          width: 12, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], actor: actor)
      try store.saveSpatialInk(journal)
      queue = .init(store: store); tiles = .init(resources: resources)
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
      window = UIWindow(windowScene: scene)
    }

    private func update() {
      coordinator?.update(view: mount, cohort: tiles.published, boardID: boardID, camera: camera,
        viewport: viewport, items: [], journal: journal, penStyle: .standard, eraserStyle: .standard,
        drawingTool: .pen, surfaceRegistry: tiles.surfaceRegistry, inputGate: gate,
        isItemBeingDeleted: { _ in false }, admitsNewContact: { true }, isEnabled: true,
        onCommit: { [weak self] in self?.accept(tool: $0, color: $1, spans: $2) })
    }

    func parkAndRemount() {
      let canvas = mount.inkView
      coordinator?.uninstall()
      XCTAssertNotNil(canvas?.window)
      XCTAssertFalse(canvas?.window === window)
      XCTAssertEqual(canvas?.window?.canBecomeKey, false, "A parked renderer cannot own system input")
      XCTAssertEqual(canvas?.window?.accessibilityElementsHidden, true, "A prepared surface is not another human window")
      update()
    }

    func contact() throws -> SpatialInkAction {
      let recognizer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
      let touch = TerminalInkTouch(window: window), event = UIEvent()
      touch.point = .init(x: 24, y: 30); recognizer.touchesBegan([touch], with: event)
      XCTAssertTrue(gate.hasActivePencil)
      touch.point = .init(x: 120, y: 80); touch.sampleTime += 0.1
      recognizer.touchesMoved([touch], with: event)
      touch.sampleTime += 0.1; recognizer.touchesEnded([touch], with: event)
      return try XCTUnwrap(accepted)
    }

    private func accept(tool: SpatialInkTool, color: SpatialInkColor, spans: [SpatialInkSpan]) -> SpatialInkAction? {
      guard let action = journal.append(tool: tool, color: color, spans: spans, actor: actor) else { return nil }
      accepted = action
      let command = NotebookSpatialInkCommand.append(action, journalStamp: journal.stamp)
      queue.enqueue(owner: .spatialInk(action.id)) { _ = try $0.commitSpatialInk(command); return false }
      return action
    }

    func stop() async {
      coordinator?.uninstall(); coordinator = nil
      mount.unmount()
      await tiles.stop()
    }

    func close() async {
      coordinator?.uninstall()
      let saved = await queue.flush()
      XCTAssertTrue(saved, queue.failure ?? "")
      await stop()
      mount.unmount(); mount.removeFromSuperview()
      window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey()
      if saved, FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) }
    }
  }
}

@MainActor
private final class TerminalInkHost: UIViewController {
  private(set) var appeared = false
  override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true }
}

@MainActor
private final class TerminalInkTouch: UITouch {
  let sourceWindow: UIWindow
  var point = CGPoint.zero, sampleTime: TimeInterval = 1
  init(window: UIWindow) { sourceWindow = window; super.init() }
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint { view.map { $0.convert(point, from: sourceWindow) } ?? point }
  override func location(in view: UIView?) -> CGPoint { preciseLocation(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
