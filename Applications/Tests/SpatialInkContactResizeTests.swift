import NotebookCore
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SpatialInkContactResizeTests: XCTestCase {
  func testPencilKeepsItsInstalledCoordinateMapAcrossLayoutsUntilLift() async throws {
    try await assertContactResize(tool: .pen, cancels: false)
  }

  func testEraserKeepsItsInstalledCoordinateMapAcrossLayoutsUntilCancellation() async throws {
    try await assertContactResize(tool: .eraser, cancels: true)
  }

  func testUntouchedLeasedBoardKeepsItsPoseUntilTheLastContactLeaseReleases() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let native = try XCTUnwrap(fixture.mount.inkView)
    let original = native.center
    let first = try XCTUnwrap(fixture.registry.acquireContact(on: .board(fixture.boardID), in: fixture.mount))
    let second = try XCTUnwrap(fixture.registry.acquireContact(on: .board(fixture.boardID), in: fixture.mount))
    XCTAssertFalse(fixture.registry.hasActiveAction(on: .board(fixture.boardID)),
      "A route pins its physical board even before the Pencil crosses onto it")
    fixture.resize(to: .init(x: 640, y: 640))
    XCTAssertEqual(native.center, original, "Layout cannot move a leased, not-yet-visited route surface")
    first.release()
    XCTAssertEqual(native.center, original, "Another contact still owns the installed geometry")
    fixture.resize(to: .init(x: 768, y: 704))
    XCTAssertEqual(native.center, original)
    second.release()
    XCTAssertEqual(native.center, CGPoint(x: 384, y: 352),
      "The final release applies the latest layout through the same physical owner")
  }

  func testReadyCandidateCannotReplaceAnUntouchedLeasedSurfaceUntilItsFinalRelease() async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    let surface = SurfaceID.board(fixture.boardID)
    let owner = try XCTUnwrap(fixture.cohort.nativeInk.owners[surface])
    let native = owner.canvas, originalBounds = native.bounds
    let originalSource = try native.installedSpatialSource?.referenceInk()
    var journal = fixture.journal
    let action = try XCTUnwrap(journal.append(tool: .pen,
      spans: [.init(surface: surface, samples: [-40.0, 40].enumerated().map { index, x in
        .init(point: .zero, worldPoint: .init(x: x, y: 0), timeOffset: Double(index) / 10,
          width: 8, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })], actor: fixture.actor))
    let frame = try await native.prepareSpatialFrame(SpatialInkMesh.prepare(surface: surface, journal: journal),
      size: .init(x: 768, y: 768), displayScale: 1)
    let candidate = SpatialInkSceneLease(registry: fixture.registry, rootBoardID: fixture.boardID,
      focusedCoverID: nil,
      owners: [surface: owner], updates: [.init(owner: owner, generation: native.spatialSourceGeneration,
        frame: frame, journal: journal)])
    XCTAssertTrue(frame.isValid)
    let first = try XCTUnwrap(fixture.registry.acquireContact(on: surface, in: fixture.mount))
    let second = try XCTUnwrap(fixture.registry.acquireContact(on: surface, in: fixture.mount))
    defer { first.release(); second.release() }
    XCTAssertFalse(fixture.registry.hasActiveAction(on: surface))
    XCTAssertThrowsError(try candidate.install()) { XCTAssertTrue($0 is CancellationError) }
    XCTAssertFalse(candidate.isInstalled)
    XCTAssertEqual(native.bounds, originalBounds)
    XCTAssertEqual(try native.installedSpatialSource?.referenceInk(), originalSource,
      "A prepared source cannot replace the route's leased physical content before its first segment")
    first.release()
    XCTAssertThrowsError(try candidate.install()) { XCTAssertTrue($0 is CancellationError) }
    second.release()
    if !candidate.isInstalled { try candidate.install() }
    XCTAssertTrue(candidate.isInstalled)
    XCTAssertEqual(native.bounds.size, CGSize(width: 768, height: 768))
    XCTAssertTrue(try native.installedSpatialSource?.referenceInk().actions.contains { $0.id == action.id } == true)
  }

  private func assertContactResize(tool: DrawingTool, cancels: Bool) async throws {
    let fixture = try await Fixture.make()
    addTeardownBlock { await fixture.close() }
    fixture.update(tool: tool)
    let native = try XCTUnwrap(fixture.mount.inkView)
    let originalCenter = native.center
    let frozenOrigin = native.convert(CGPoint.zero, from: fixture.mount)
    let points = [CGPoint(x: 80, y: 100), CGPoint(x: 120, y: 140), CGPoint(x: 180, y: 160)]
    let touch = ContactResizeTouch(window: fixture.window), event = UIEvent()
    let recognizer = try XCTUnwrap(fixture.window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    touch.point = points[0]
    recognizer.touchesBegan([touch], with: event)
    XCTAssertTrue(fixture.gate.hasActivePencil)
    XCTAssertTrue(fixture.registry.hasActiveAction(on: .board(fixture.boardID)))
    for (index, size) in [SpatialPoint(x: 640, y: 640), .init(x: 768, y: 704)].enumerated() {
      fixture.resize(to: size)
      fixture.update(tool: tool)
      XCTAssertTrue(fixture.gate.hasActivePencil)
      XCTAssertTrue(fixture.mount.inkView === native)
      XCTAssertEqual(native.center, originalCenter,
        "A new view layout cannot move the already measured beginning of this contact")
      let point = points[index + 1]
      let livePoint = native.convert(point, from: fixture.mount)
      XCTAssertEqual(livePoint.x, frozenOrigin.x + point.x, accuracy: 0.00001)
      XCTAssertEqual(livePoint.y, frozenOrigin.y + point.y, accuracy: 0.00001,
        "The next live point must use the same installed map as the first point and durable world samples")
      touch.point = point; touch.sampleTime += 0.1
      recognizer.touchesMoved([touch], with: event)
    }
    if cancels { recognizer.touchesCancelled([touch], with: event) }
    else { recognizer.touchesEnded([touch], with: event) }
    XCTAssertFalse(fixture.gate.hasActivePencil)
    XCTAssertEqual(native.center, CGPoint(x: 384, y: 352),
      "Lift/cancel releases the retained map and installs the latest layout without another callback")
    let action = try XCTUnwrap(fixture.actions.last)
    XCTAssertEqual(action.tool, tool == .pen ? .pen : .eraser)
    let samples = action.spans.flatMap(\.samples)
    let uniqueWorldPoints = samples.compactMap(\.worldPoint).reduce(into: [WorldPoint]()) { result, point in
      if result.last != point { result.append(point) }
    }
    XCTAssertEqual(uniqueWorldPoints, points.map {
      fixture.camera.screenToWorld(.init(x: $0.x, y: $0.y), viewport: fixture.initialViewport)
    }, "Every accepted sample preserves the original live-to-world correspondence")
    XCTAssertEqual(native.installedSpatialSource?.surface, .board(fixture.boardID))
    XCTAssertTrue(try native.installedSpatialSource?.referenceInk().actions.contains { $0.id == action.id } == true)
  }

  @MainActor
  private final class Fixture {
    let boardID = UUID(), actor = UUID()
    let initialViewport = SpatialPoint(x: 384, y: 384)
    let camera = SpatialCamera(scale: 1)
    let registry = SpatialInkSurfaceRegistry(), gate = NotebookInputGate()
    let resources = SceneRenderResources()
    let window: UIWindow, host = UIViewController()
    let mount = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 384, height: 384))
    var cohort: SceneCompositionCohort!
    var journal: SpatialInkJournal
    var actions: [SpatialInkAction] = []
    var viewport = SpatialPoint(x: 384, y: 384)
    private var coordinator: SpatialInkCanvas.Coordinator!
    private weak var oldKeyWindow: UIWindow?

    static func make() async throws -> Fixture {
      let fixture = try Fixture()
      fixture.cohort = try await WorkspaceInkFixture.prepare(boardID: fixture.boardID,
        camera: fixture.camera, viewport: fixture.initialViewport, items: [], journal: fixture.journal,
        registry: fixture.registry, resources: fixture.resources)
      fixture.window.rootViewController = fixture.host
      fixture.host.view.addSubview(fixture.mount); fixture.window.makeKeyAndVisible()
      fixture.coordinator = .init(surfaceRegistry: fixture.registry, inputGate: fixture.gate) { [weak fixture] in
        fixture?.accept(tool: $0, color: $1, spans: $2)
      }
      fixture.update(tool: .pen)
      fixture.mount.setNeedsLayout(); fixture.mount.layoutIfNeeded()
      return fixture
    }

    private init() throws {
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
      window = UIWindow(windowScene: scene)
      journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    }

    func update(tool: DrawingTool) {
      coordinator.update(view: mount, cohort: cohort, boardID: boardID, camera: camera, viewport: viewport,
        items: cohort.frame.workset(boardID: boardID).items.map {
          .init(itemID: $0.id, geometry: $0.geometry, center: $0.center, zIndex: $0.zIndex)
        }, journal: journal, penStyle: .standard, eraserStyle: .standard, drawingTool: tool,
        surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { _ in false },
        admitsNewContact: { true }, isEnabled: true,
        onCommit: { [weak self] in self?.accept(tool: $0, color: $1, spans: $2) })
    }

    func resize(to size: SpatialPoint) {
      viewport = size
      mount.frame = .init(x: 0, y: 0, width: size.x, height: size.y)
      mount.setNeedsLayout(); mount.layoutIfNeeded()
    }

    private func accept(tool: SpatialInkTool, color: SpatialInkColor, spans: [SpatialInkSpan]) -> SpatialInkAction? {
      guard let action = journal.append(tool: tool, color: color, spans: spans, actor: actor) else { return nil }
      actions.append(action)
      return action
    }

    func close() async {
      coordinator?.uninstall(); mount.unmount(); mount.removeFromSuperview()
      await registry.stopSceneInk()
      cohort = nil
      window.isHidden = true; window.rootViewController = nil; oldKeyWindow?.makeKey()
    }
  }
}

@MainActor
private final class ContactResizeTouch: UITouch {
  let sourceWindow: UIWindow
  var point = CGPoint.zero
  var sampleTime: TimeInterval = 1
  init(window: UIWindow) { sourceWindow = window; super.init() }
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
  override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
