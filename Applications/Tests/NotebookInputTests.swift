import UIKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookInputTests: XCTestCase {
  @MainActor
  func testFinishedSpatialEraserKeepsTheBoardVisibleWhileItsJournalReplays() async throws {
    let actor = UUID(), board = UUID(), gate = NotebookInputGate(), registry = SpatialInkSurfaceRegistry()
    var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
    let samples = [-240.0, 240.0].enumerated().map { index, x in
      SpatialInkSample(point: .init(x: x, y: -180), worldPoint: .init(x: x, y: -180),
        timeOffset: Double(index) * 0.1, width: 8, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    journal.append(tool: .pen, spans: [.init(surface: .board(board), samples: samples)], actor: actor)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    let canvas = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host; host.view.addSubview(canvas); window.makeKeyAndVisible()
    let coordinator = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: gate) { _, _, _ in }
    defer { coordinator.uninstall(); window.isHidden = true }
    func update(camera: SpatialCamera = .init(scale: 1)) {
      coordinator.update(view: canvas, boardID: board, camera: camera, viewport: .init(x: 600, y: 800),
        items: [], journal: journal, penStyle: .standard, eraserStyle: .standard, drawingTool: .eraser,
        surfaceRegistry: registry, inputGate: gate, isEnabled: true, onCommit: { tool, color, spans in
          journal.append(tool: tool, color: color, spans: spans, actor: actor)
        })
    }
    update()
    for _ in 0..<200 where canvas.inkView.committedVertexCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let baseline = canvas.inkView.committedVertexCount
    XCTAssertGreaterThan(baseline, 0)
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = InputTouch(), event = UIEvent()
    pencil.touchesBegan([touch], with: event)
    update()
    XCTAssertEqual(canvas.inkView.committedVertexCount, baseline, "Первое касание не очищает рисунок")
    touch.point.x += 80; touch.sampleTime += 0.1
    pencil.touchesMoved([touch], with: event)
    pencil.touchesEnded([touch], with: event)
    let committed = canvas.inkView.committedVertexCount
    XCTAssertGreaterThan(committed, baseline)
    XCTAssertGreaterThan(canvas.inkView.committedEraserVertexCount, 0)
    let installations = canvas.inkView.spatialMeshInstallCount
    update()
    XCTAssertEqual(canvas.inkView.committedVertexCount, committed,
      "Публикация стирания не подменяет ту же доску пустой геометрией")
    XCTAssertEqual(canvas.inkView.spatialMeshInstallCount, installations,
      "До готовности новой геометрии остаётся уже показанный результат")
    for frame in 0..<200 {
      update(camera: .init(center: .init(x: Double(frame), y: 0), scale: 1 + Double(frame) / 500))
      XCTAssertGreaterThan(canvas.inkView.committedVertexCount, 0)
      if canvas.inkView.spatialMeshInstallCount > installations { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(canvas.inkView.spatialMeshInstallCount, installations + 1)
    XCTAssertGreaterThan(canvas.inkView.committedEraserVertexCount, 0)
    let settled = canvas.inkView.spatialMeshInstallCount
    for frame in 0..<100 {
      update(camera: .init(center: .init(x: Double(frame), y: 0), scale: 0.5))
    }
    XCTAssertEqual(canvas.inkView.spatialMeshInstallCount, settled,
      "Следующий зум не перезагружает готовые чернила")
  }

  @MainActor
  func testInterruptedSpatialEraserReleasesTheNextCameraGesture() async throws {
    try await assertSpatialCompletion(.disabled)
  }

  @MainActor
  func testUIKitResetCompletesMeasuredInkAndReleasesCamera() async throws {
    try await assertSpatialCompletion(.reset)
  }

  @MainActor
  func testCancelledPencilCompletesMeasuredInkOnce() async throws {
    try await assertSpatialCompletion(.cancelled)
  }

  @MainActor
  func testLiftCompletesMeasuredInkOnceBeforeRecognizerReset() async throws {
    try await assertSpatialCompletion(.lifted)
  }

  @MainActor
  func testWindowDetachCompletesMeasuredInkAndReleasesCamera() async throws {
    try await assertSpatialCompletion(.detached)
  }

  @MainActor
  func testOwnerChangeFinishesInkAgainstItsOriginalBoard() async throws {
    try await assertSpatialCompletion(.ownerChanged)
  }

  private enum InputEnding { case disabled, reset, cancelled, lifted, detached, ownerChanged }

  @MainActor
  private func assertSpatialCompletion(_ ending: InputEnding) async throws {
    let gate = NotebookInputGate(), registry = SpatialInkSurfaceRegistry(), boardID = UUID()
    var nextBoardID = boardID
    var projection = SpatialCamera(scale: 1)
    var commits: [(SpatialInkTool, [SpatialInkSpan])] = []
    let coordinator = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: gate) { tool, _, spans in commits.append((tool, spans)) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let host = UIViewController()
    let canvas = SpatialInkContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host
    host.view.addSubview(canvas)
    window.makeKeyAndVisible()
    defer { coordinator.uninstall(); window.isHidden = true }
    func update(enabled: Bool) {
      coordinator.update(view: canvas, boardID: nextBoardID, camera: projection, viewport: .init(x: 600, y: 800),
        items: [], journal: nil, penStyle: .standard, eraserStyle: .standard, drawingTool: .eraser,
        surfaceRegistry: registry, inputGate: gate, isEnabled: enabled,
        onCommit: { tool, _, spans in commits.append((tool, spans)) })
    }
    update(enabled: true)
    let recognizer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = InputTouch(), event = UIEvent()
    recognizer.touchesBegan([touch], with: event)
    touch.sampleTime += 0.1; touch.point.x += 80
    recognizer.touchesMoved([touch], with: event)
    XCTAssertNil(gate.beginFingerSequence(), "Незаконченный Pencil защищает свой контакт")

    switch ending {
    case .disabled: update(enabled: false)
    case .reset: break
    case .cancelled: recognizer.touchesCancelled([touch], with: event)
    case .lifted: recognizer.touchesEnded([touch], with: event)
    case .detached: coordinator.uninstall()
    case .ownerChanged:
      nextBoardID = UUID()
      projection = .init(center: .init(x: 1_000, y: 2_000), scale: 0.4)
      update(enabled: true)
    }
    // UIKit can reset without another measured touch event. Subsequent reset
    // or detach must not publish the same human action a second time.
    recognizer.reset()
    for _ in 0..<30 where gate.isActive { await Task.yield() }
    XCTAssertNotNil(gate.beginFingerSequence(), "Прерванный ластик не удерживает камеру навсегда")
    XCTAssertFalse(gate.isActive)
    XCTAssertEqual(commits.map { $0.0 }, [.eraser], "Уже измеренное стирание завершается один раз")
    let span = try XCTUnwrap(commits.first?.1.first)
    XCTAssertEqual(span.surface, .board(boardID), "Смена доски не переносит измеренное стирание")
    XCTAssertGreaterThanOrEqual(span.samples.count, 2)
    XCTAssertEqual(span.samples.first?.worldPoint, WorldPoint(x: -180, y: -180))
    XCTAssertEqual(span.samples.last?.worldPoint, WorldPoint(x: -100, y: -180))

    for pinch in [false, true] {
      let camera = TwoFingerPaperGestureRecognizer()
      camera.inputGate = gate
      window.addGestureRecognizer(camera)
      defer { camera.reset(); window.removeGestureRecognizer(camera) }
      let first = InputTouch(), second = InputTouch()
      first.inputType = .direct; second.inputType = .direct
      first.point = .init(x: 100, y: 300); second.point = .init(x: 300, y: 300)
      camera.touchesBegan([first, second], with: event)
      first.point.x += pinch ? -40 : 80; second.point.x += 80
      first.sampleTime += 0.1; second.sampleTime += 0.1
      camera.touchesMoved([first, second], with: event)
      XCTAssertEqual(camera.state, .began, "Следующее движение распознаётся камерой")
      if pinch {
        guard case .magnification = camera.intent else { return XCTFail("Ожидался щипок после \(ending)") }
      } else {
        guard case .navigation = camera.intent else { return XCTFail("Ожидалось перемещение после \(ending)") }
      }
      camera.touchesEnded([first, second], with: event)
    }
    coordinator.uninstall()
    XCTAssertEqual(commits.count, 1)
  }

  @MainActor
  func testProbeRetainsContactWithoutAnyDisplayCallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: true)
    let monitor = InputFrameMonitor(root: root)
    monitor.begin(mode: "board")
    monitor.end()
    let url = root.appendingPathComponent("runtime/input-frames.json")
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(for: .milliseconds(10)) }
    let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    XCTAssertEqual(rows.count, 1)
    XCTAssertNotNil(rows[0]["lastServiceToEndMS"])
    XCTAssertEqual((rows[0]["cadence"] as? [String: Any])?["totalIntervals"] as? Int, 0)
  }

  @MainActor
  func testDisplayProbeDoesNotRetainAnUnmountedSurface() {
    var monitor: InputFrameMonitor? = .init(root: FileManager.default.temporaryDirectory)
    weak var weakMonitor = monitor
    monitor?.begin(mode: "board")
    monitor = nil
    XCTAssertNil(weakMonitor)
  }

  @MainActor
  func testContactObserverCannotClaimCameraOrInteractiveTouches() {
    let observer = NotebookContactObserver(gate: NotebookInputGate())
    let camera = UIPanGestureRecognizer()
    XCTAssertFalse(observer.canPrevent(camera))
    XCTAssertFalse(observer.canBePrevented(by: camera))
    XCTAssertFalse(observer.cancelsTouchesInView)
    XCTAssertFalse(observer.delaysTouchesBegan)
    XCTAssertFalse(observer.delaysTouchesEnded)
  }

  @MainActor
  func testIdleWaitsForAllContactsAndCurrentInkSerialization() async throws {
    let gate = NotebookInputGate(), first = UUID(), second = UUID(), page = UUID()
    var callbacks: [NotebookInputCompletion] = []
    var changes: [Bool] = []
    gate.onActivityChange = { changes.append($0) }
    gate.registerPageFinisher(source: page) { _, completion in callbacks.append(completion) }
    gate.setCurrentPageSource(page, isCurrent: true)
    gate.beginContact(source: first); gate.beginContact(source: second)
    gate.endContact(source: first)
    XCTAssertTrue(gate.isActive)
    XCTAssertTrue(callbacks.isEmpty)
    gate.endContact(source: second)
    for _ in 0..<20 where callbacks.isEmpty { await Task.yield() }
    XCTAssertEqual(callbacks.count, 1)
    gate.beginContact(source: first)
    gate.endContact(source: first)
    for _ in 0..<20 where callbacks.count < 2 { await Task.yield() }
    XCTAssertEqual(callbacks.count, 2)
    callbacks[0]()
    XCTAssertTrue(gate.isActive, "Предыдущий хвост не завершает новое касание")
    callbacks[1]()
    XCTAssertFalse(gate.isActive)
    XCTAssertEqual(changes, [true, false])
  }

  @MainActor
  func testContactProtectionFollowsPortalWithoutEndingContact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let parent = try XCTUnwrap(model.workspace?.rootBoardID)
    let child = try XCTUnwrap(model.createBoard(at: .zero))
    let viewport = BoardPortalProjection.viewport
    model.updatePresence(.init(boardID: parent, mode: .board,
      camera: .init(scale: 0.3), viewport: viewport), settled: false)
    let source = UUID()
    model.inputGate.beginContact(source: source)
    await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.inputActivities().first?.targets, [.init(kind: .board, id: parent)])

    XCTAssertTrue(model.enterBoard(child, through: .init(scale: 1), settled: false))
    await model.finishPendingPersistence()
    XCTAssertTrue(model.inputGate.isActive)
    XCTAssertEqual(try model.store.inputActivities().first?.targets, [.init(kind: .board, id: child)])

    XCTAssertTrue(model.leaveBoard(settled: false))
    await model.finishPendingPersistence()
    XCTAssertTrue(model.inputGate.isActive)
    XCTAssertEqual(try model.store.inputActivities().first?.targets, [.init(kind: .cover, id: child, boardID: parent)])
    model.updatePresence(.init(boardID: parent, mode: .board,
      camera: .init(scale: 0.3), viewport: viewport), settled: false)
    await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.inputActivities().first?.targets, [.init(kind: .board, id: parent)])

    model.inputGate.endContact(source: source)
    for _ in 0..<100 where model.inputGate.isActive { await Task.yield() }
    await model.finishPendingPersistence()
    XCTAssertEqual(try model.store.inputActivities().first?.targets, [])
  }

  @MainActor
  func testIncomingCompositionWaitsForFingerAndMergesHumanContinuation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    var incoming = try XCTUnwrap(model.collaborationContent)
    let source = UUID()
    let element = AgentElement(id: "agent", kind: .web, frame: .init(x: 100, y: 100, width: 200, height: 80), source: "Agent", html: "Agent")
    XCTAssertTrue(incoming.pages[0].replaceElements([element], actor: UUID()))
    model.inputGate.beginContact(source: source)
    for _ in 0..<50 { model.receivePeerMessage(.collaboration(.init(content: incoming))) }
    XCTAssertTrue(try XCTUnwrap(model.activePage).elements.isEmpty)
    XCTAssertTrue(try model.store.loadPage(incoming.pages[0].id).elements.isEmpty)
    XCTAssertFalse(model.permitsBackgroundPreparation)
    var human = try model.store.loadPage(incoming.pages[0].id)
    XCTAssertTrue(human.replaceElements([.init(id: "human", kind: .markdown, frame: .init(x: 30, y: 400, width: 120, height: 90), source: "Human", html: "Human")], actor: model.actorID))
    _ = try model.store.saveMergedPage(human)
    model.inputGate.endContact(source: source)
    for _ in 0..<100 where model.inputGate.isActive { await Task.yield() }
    XCTAssertFalse(model.inputGate.isActive)
    await model.finishPendingPersistence()
    XCTAssertEqual(Set(try XCTUnwrap(model.activePage).elements.map(\.id)), ["agent", "human"])
    XCTAssertEqual(Set(try model.store.loadPage(human.id).elements.map(\.id)), ["agent", "human"])
  }
}

@MainActor
private final class InputTouch: UITouch {
  var point = CGPoint(x: 120, y: 220)
  var sampleTime: TimeInterval = 1
  var inputType: UITouch.TouchType = .pencil
  override var type: UITouch.TouchType { inputType }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func location(in view: UIView?) -> CGPoint { point }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
