import UIKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookInputTests: XCTestCase {
  private func acceptedAction(_ tool: SpatialInkTool, _ color: SpatialInkColor, _ spans: [SpatialInkSpan]) -> SpatialInkAction {
    .init(tool: tool, color: color, spans: spans, stamp: .init(counter: 1, actor: UUID()))
  }

  @MainActor
  func testPresentedUIKitSurfaceKeepsItsTouchOutsideWindowLevelSceneRecognizers() throws {
    let gate = NotebookInputGate()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host
    let anchor = UIView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    host.view.addSubview(anchor); window.makeKeyAndVisible()
    let camera = WorkspaceGestureLayer.Coordinator(defersHorizontalMotionToPageTurn: false,
      isEnabled: true, inputGate: gate, onCamera: { _ in }, onUndo: {})
    camera.install(on: window, inside: anchor)
    let pan = BoardPanView.Coordinator(isEnabled: true, itemFrames: [], inputGate: gate,
      onTap: {}, onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
    pan.install(on: window, inside: anchor)
    defer { camera.uninstall(); pan.uninstall(); window.isHidden = true }
    let gesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is TwoFingerPaperGestureRecognizer })
    let panGesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
    let observer = try XCTUnwrap(window.gestureRecognizers?.first { $0 is NotebookContactObserver })
    let touch = InputTouch(); touch.inputType = .direct; touch.point = .init(x: 200, y: 300)
    let embedded = UIViewController(); host.addChild(embedded); host.view.addSubview(embedded.view)
    embedded.didMove(toParent: host)
    touch.sourceView = embedded.view
    XCTAssertTrue(camera.gestureRecognizer(gesture, shouldReceive: touch), "Embedded paper and WebKit keep the scene camera")
    let menu = UIViewController(); window.addSubview(menu.view)
    touch.sourceView = menu.view
    XCTAssertFalse(camera.gestureRecognizer(gesture, shouldReceive: touch))
    XCTAssertFalse(camera.gestureRecognizer(observer, shouldReceive: touch), "A menu press cannot invalidate the scene's published cut")
    XCTAssertFalse(pan.gestureRecognizer(panGesture, shouldReceive: touch))
    XCTAssertFalse(gate.isActive)
  }

  @MainActor
  func testPencilImmediatelyStopsAStationaryTwoFingerUndoHoldAndCamera() async throws {
    let gate = NotebookInputGate(), pencilSource = UUID()
    let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: windowScene), host = UIViewController()
    let scene = UIView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host; host.view.addSubview(scene); window.makeKeyAndVisible()
    var undoCount = 0, cameraBeginCount = 0
    let owner = WorkspaceGestureLayer.Coordinator(defersHorizontalMotionToPageTurn: false,
      isEnabled: true, inputGate: gate, onCamera: { phase in
        if case .began = phase { cameraBeginCount += 1 }
      }, onUndo: { undoCount += 1 })
    owner.install(on: window, inside: scene)
    defer { owner.uninstall(); gate.endPencilAction(source: pencilSource); window.isHidden = true }
    let recognizer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? TwoFingerPaperGestureRecognizer }.first)
    let first = InputTouch(), second = InputTouch(), event = UIEvent()
    first.inputType = .direct; second.inputType = .direct
    first.point = .init(x: 100, y: 300); second.point = .init(x: 300, y: 300)
    recognizer.touchesBegan([first, second], with: event)
    for _ in 0..<100 where undoCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(recognizer.permitsUndoRepetition)
    XCTAssertGreaterThan(undoCount, 0, "UIKit должен передать распознанное удержание настоящему владельцу")
    gate.beginPencilAction(source: pencilSource)
    XCTAssertEqual(recognizer.state, .cancelled, "Не требуется ждать нового движения пальцев")
    XCTAssertFalse(recognizer.permitsUndoRepetition)
    let stoppedAt = undoCount
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(undoCount, stoppedAt, "Даже отложенная доставка UIKit cancellation не допускает повтор undo")
    gate.endPencilAction(source: pencilSource)
    XCTAssertFalse(recognizer.permitsUndoRepetition, "Прежняя удерживаемая пара не возвращает своё разрешение")

    recognizer.reset()
    recognizer.touchesBegan([first, second], with: event)
    first.point.x -= 40; second.point.x += 40
    first.sampleTime += 0.1; second.sampleTime += 0.1
    recognizer.touchesMoved([first, second], with: event)
    for _ in 0..<100 where cameraBeginCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(cameraBeginCount, 1, "Следующая пара должна начать новый жест через UIKit")
    XCTAssertEqual(recognizer.state, .began)
    gate.beginPencilAction(source: pencilSource)
    XCTAssertEqual(recognizer.state, .cancelled)
    recognizer.touchesCancelled([first, second], with: event)
    XCTAssertEqual(recognizer.state, .cancelled, "Поздняя системная отмена не переписывает завершение активной камеры")
  }

  @MainActor
  func testBoardPanCannotStartDuringPencilAndPencilCancelsAnEarlierPanWithoutRewinding() throws {
    let gate = NotebookInputGate(), pencil = UUID()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    let anchor = UIView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host; host.view.addSubview(anchor); window.makeKeyAndVisible()
    var shown = CGPoint.zero, cancellations = 0, commits = 0
    let owner = BoardPanView.Coordinator(isEnabled: true, itemFrames: [], inputGate: gate,
      onTap: {}, onBegan: {}, onChanged: { shown = $0 }, onEnded: { shown = $0; commits += 1 },
      onCancelled: { cancellations += 1 })
    owner.install(on: window, inside: anchor)
    defer { owner.uninstall(); window.isHidden = true }
    let pan = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
    let finger = InputTouch(); finger.inputType = .direct
    gate.beginPencilAction(source: pencil)
    XCTAssertFalse(owner.gestureRecognizer(pan, shouldReceive: finger))
    gate.endPencilAction(source: pencil)
    XCTAssertTrue(owner.gestureRecognizer(pan, shouldReceive: finger))
    owner.receivePan(state: .began, translation: .init(x: 30, y: 20))
    owner.receivePan(state: .changed, translation: .init(x: 80, y: 40))
    gate.beginPencilAction(source: pencil)
    XCTAssertEqual(cancellations, 1, "Pencil немедленно завершает уже движущуюся камеру")
    owner.receivePan(state: .changed, translation: .init(x: 160, y: 80))
    owner.receivePan(state: .cancelled, translation: .zero)
    XCTAssertEqual(shown, .init(x: 80, y: 40), "Отмена не становится нулевым измерением")
    XCTAssertEqual(commits, 0)
    XCTAssertEqual(cancellations, 1)
    gate.endPencilAction(source: pencil)
    XCTAssertTrue(owner.gestureRecognizer(pan, shouldReceive: finger))
    owner.receivePan(state: .began, translation: .init(x: 12, y: 7))
    owner.receivePan(state: .cancelled, translation: .zero)
    XCTAssertEqual(shown, .init(x: 12, y: 7))
    XCTAssertEqual(cancellations, 2)
  }

  @MainActor
  func testBoardPanDefersConfigurationCancellationWithoutStoppingTheNextContact() async throws {
    let gate = NotebookInputGate()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    let anchor = UIView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host; host.view.addSubview(anchor); window.makeKeyAndVisible()
    var isUpdatingView = false, begins = 0, cancellations = 0, successorCancellations = 0
    var shown = CGPoint.zero
    let owner = BoardPanView.Coordinator(isEnabled: true, itemFrames: [], inputGate: gate,
      onTap: {}, onBegan: { begins += 1 }, onChanged: { shown = $0 }, onEnded: { shown = $0 },
      onCancelled: {
        XCTAssertFalse(isUpdatingView, "SwiftUI completion must not run inside native configuration")
        cancellations += 1
      })
    owner.install(on: window, inside: anchor)
    defer { owner.uninstall(); window.isHidden = true; previousKeyWindow?.makeKey() }
    let pan = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
    let finger = InputTouch(); finger.inputType = .direct
    XCTAssertTrue(owner.gestureRecognizer(pan, shouldReceive: finger))
    pan.state = .began
    for _ in 0..<100 where begins == 0 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(begins, 1, "Exercise UIKit target delivery, not only receivePan")
    owner.receivePan(state: .changed, translation: .init(x: 80, y: 40))

    isUpdatingView = true
    owner.isEnabled = false
    owner.receivePan(state: .changed, translation: .init(x: 160, y: 80))
    owner.receivePan(state: .cancelled, translation: .zero)
    XCTAssertEqual(cancellations, 0)
    XCTAssertFalse(owner.gestureRecognizer(pan, shouldReceive: finger))
    XCTAssertFalse(pan.isEnabled)
    XCTAssertEqual(shown, .init(x: 80, y: 40), "Native ownership closes immediately without rewinding")
    isUpdatingView = false
    for _ in 0..<100 where cancellations == 0 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(cancellations, 1)

    // The native cancellation path above has completed. Exercise the owner's
    // queued-completion ordering with admitted phases below; assigning a new
    // UIKit .began before its cancelled recognizer resets is not a new touch.
    owner.isEnabled = true
    XCTAssertTrue(owner.gestureRecognizer(pan, shouldReceive: finger))
    owner.receivePan(state: .began, translation: .init(x: 40, y: 20))
    XCTAssertEqual(begins, 2)
    isUpdatingView = true
    owner.isEnabled = false
    owner.onCancelled = { successorCancellations += 1 }
    owner.isEnabled = true
    isUpdatingView = false
    XCTAssertEqual(cancellations, 1)
    XCTAssertTrue(owner.gestureRecognizer(pan, shouldReceive: finger))
    XCTAssertEqual(cancellations, 2, "The next contact first completes the captured preceding owner")
    XCTAssertEqual(successorCancellations, 0)
    owner.receivePan(state: .began, translation: .init(x: 12, y: 7))
    XCTAssertEqual(begins, 3)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(cancellations, 2)
    XCTAssertEqual(successorCancellations, 0, "The queued old completion cannot cancel the new pan")
    owner.receivePan(state: .changed, translation: .init(x: 24, y: 14))
    XCTAssertEqual(shown, .init(x: 24, y: 14))
    owner.receivePan(state: .ended, translation: .init(x: 24, y: 14))
  }

  @MainActor
  func testBoardPanYieldsToPhysicalElementsAndNativeInteractiveAncestors() throws {
    let gate = NotebookInputGate()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    let anchor = UIView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host; host.view.addSubview(anchor); window.makeKeyAndVisible()
    let owner = BoardPanView.Coordinator(isEnabled: true,
      itemFrames: [.init(x: 100, y: 200, width: 200, height: 100)], inputGate: gate,
      onTap: {}, onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
    owner.install(on: window, inside: anchor)
    defer { owner.uninstall(); window.isHidden = true }
    let pan = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
    let finger = InputTouch(); finger.inputType = .direct
    XCTAssertFalse(owner.gestureRecognizer(pan, shouldReceive: finger), "Элемент доски не является свободным фоном")
    finger.point = .init(x: 400, y: 500)
    XCTAssertTrue(owner.gestureRecognizer(pan, shouldReceive: finger))
    let slider = UISlider(), thumb = UIView(); slider.addSubview(thumb)
    finger.sourceView = thumb
    XCTAssertFalse(owner.gestureRecognizer(pan, shouldReceive: finger))
    let scroll = UIScrollView(), webContent = UIView(); scroll.addSubview(webContent)
    finger.sourceView = webContent
    XCTAssertFalse(owner.gestureRecognizer(pan, shouldReceive: finger))
  }

  @MainActor
  func testSpatialContactRoutesOnceAndKeepsItsOriginalCameraAcrossAnUpdate() async throws {
    let gate = NotebookInputGate(), registry = SpatialInkSurfaceRegistry(), board = UUID(), cover = UUID()
    var commits: [[SpatialInkSpan]] = []
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    let canvas = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host; host.view.addSubview(canvas); window.makeKeyAndVisible()
    let cohort = try await WorkspaceInkFixture.prepare(boardID: board, camera: .init(scale: 0.1),
      viewport: .init(x: 600, y: 800), items: [.init(itemID: cover, geometry: .notebook, center: .zero, zIndex: 1)], journal: nil, registry: registry)
    let physical = try WorkspaceInkFixture(cohort: cohort,
      presence: .init(boardID: board, mode: .board, camera: .init(scale: 0.1), viewport: .init(x: 600, y: 800)),
      canvas: canvas, parent: host, registry: registry, gate: gate, journal: nil)
    defer { physical.close() }
    let owner = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: gate) { tool, color, spans in commits.append(spans); return self.acceptedAction(tool, color, spans) }
    defer { owner.uninstall(); window.isHidden = true }
    func update(camera: SpatialCamera, items: [SpatialWorkspaceItemSurface]) {
      owner.update(view: canvas, cohort: cohort, boardID: board, camera: camera, viewport: .init(x: 600, y: 800),
        items: items, journal: cohort.liveData.ink, penStyle: .standard, eraserStyle: .standard, drawingTool: .pen,
        surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { _ in false }, admitsNewContact: { true }, isEnabled: true, onCommit: { tool, color, spans in commits.append(spans); return self.acceptedAction(tool, color, spans) })
    }
    update(camera: .init(scale: 0.1), items: [.init(itemID: cover, geometry: .notebook, center: .zero, zIndex: 1)])
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = InputTouch(), event = UIEvent()
    touch.point = .init(x: 200, y: 400)
    pencil.touchesBegan([touch], with: event)
    update(camera: .init(center: .init(x: 1000, y: 2000), scale: 2), items: [])
    touch.point.x = 400; touch.sampleTime += 0.1
    pencil.touchesMoved([touch], with: event)
    XCTAssertEqual(owner.routedSegmentCount, 1)
    pencil.touchesEnded([touch], with: event)
    XCTAssertEqual(owner.routedSegmentCount, 1, "Поднятие Pencil не повторяет маршрутизацию")
    XCTAssertEqual(commits.count, 1)
    let spans = try XCTUnwrap(commits.first)
    XCTAssertEqual(spans.map(\.surface), [.board(board), .cover(cover), .board(board)])
    XCTAssertEqual(spans.first?.samples.first?.worldPoint, .init(x: -1000, y: 0))
    XCTAssertEqual(spans.last?.samples.last?.worldPoint, .init(x: 1000, y: 0))
    // PKStrokePoint round-trips a screen location through Float. The world
    // conversion amplifies at most one screen ULP by the original 0.1 scale.
    let boundaryPrecision = Double(Float(touch.point.x).ulp) / 0.1
    XCTAssertEqual(try XCTUnwrap(spans[1].samples.first).point.x, 0, accuracy: boundaryPrecision)
    XCTAssertEqual(try XCTUnwrap(spans[1].samples.last).point.x, WorkspaceItemGeometry.notebook.width, accuracy: boundaryPrecision)
  }

  @MainActor
  func testDeletionWaitsForFrozenSpatialContactAndBlocksOnlyThatPhysicalCover() async throws {
    let gate = NotebookInputGate(), registry = SpatialInkSurfaceRegistry(), board = UUID(), deleting = UUID(), other = UUID()
    let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: windowScene), host = UIViewController()
    let canvas = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 1000, height: 800))
    window.rootViewController = host; host.view.addSubview(canvas); window.makeKeyAndVisible()
    let cohort = try await WorkspaceInkFixture.prepare(boardID: board, camera: .init(scale: 0.3),
      viewport: .init(x: 1000, y: 800), items: [.init(itemID: deleting, geometry: .notebook, center: .zero, zIndex: 1),
        .init(itemID: other, geometry: .notebook, center: .init(x: 1000, y: 0), zIndex: 2)], journal: nil, registry: registry)
    let physical = try WorkspaceInkFixture(cohort: cohort,
      presence: .init(boardID: board, mode: .board, camera: .init(scale: 0.3), viewport: .init(x: 1000, y: 800)),
      canvas: canvas, parent: host, registry: registry, gate: gate, journal: nil)
    defer { physical.close() }
    var blocked: Set<UUID> = [], commits: [[SpatialInkSpan]] = [], events: [String] = []
    let owner = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: gate) { _, _, _ in nil }
    defer { owner.uninstall(); window.isHidden = true }
    owner.update(view: canvas, cohort: cohort, boardID: board, camera: .init(scale: 0.3), viewport: .init(x: 1000, y: 800),
      items: [.init(itemID: deleting, geometry: .notebook, center: .zero, zIndex: 1),
        .init(itemID: other, geometry: .notebook, center: .init(x: 1000, y: 0), zIndex: 2)],
      journal: cohort.liveData.ink, penStyle: .standard, eraserStyle: .standard, drawingTool: .pen,
      surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { blocked.contains($0) }, admitsNewContact: { true }, isEnabled: true,
      onCommit: { tool, color, spans in commits.append(spans); events.append("ink"); return self.acceptedAction(tool, color, spans) })
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = InputTouch(), event = UIEvent()
    touch.point = .init(x: 500, y: 400)
    pencil.touchesBegan([touch], with: event)
    gate.performAfterPageInput { blocked.insert(deleting); events.append("delete") }
    XCTAssertTrue(blocked.isEmpty, "Удаление не меняет владельца принятого Pencil-контакта")
    XCTAssertTrue(commits.isEmpty)
    touch.point.x += 20; touch.sampleTime += 0.1
    pencil.touchesMoved([touch], with: event)
    pencil.touchesEnded([touch], with: event)
    XCTAssertEqual(events, ["ink", "delete"], "Snapshot удаления начинается только после публикации контакта")
    XCTAssertEqual(commits.first?.map(\.surface), [.cover(deleting)])

    // No SwiftUI update has delivered the pending state to the canvas.
    pencil.reset()
    pencil.touchesBegan([touch], with: event)
    XCTAssertEqual(pencil.state, .failed, "Новый контакт проверяет живое разрешение до принятия UIKit")
    XCTAssertNotNil(gate.beginFingerSequence(), "Отклонённый Pencil не блокирует другие поверхности")
    pencil.touchesEnded([touch], with: event)
    XCTAssertEqual(commits.count, 1)

    pencil.reset()
    touch.point.x = 100; touch.sampleTime += 0.1
    pencil.touchesBegan([touch], with: event)
    touch.point.x = 660; touch.sampleTime += 0.1
    pencil.touchesMoved([touch], with: event)
    pencil.touchesEnded([touch], with: event)
    let aroundCover = try XCTUnwrap(commits.last)
    XCTAssertEqual(aroundCover.map(\.surface), [.board(board), .board(board)],
      "Удаляемая обложка оставляет разрыв, а не становится доступной доской под ней")
    XCTAssertEqual(commits.count, 2)

    pencil.reset()
    touch.point.x = 800; touch.sampleTime += 0.1
    pencil.touchesBegan([touch], with: event)
    touch.point.x += 10; touch.sampleTime += 0.1
    pencil.touchesMoved([touch], with: event)
    pencil.touchesEnded([touch], with: event)
    XCTAssertEqual(commits.last?.map(\.surface), [.cover(other)])
    XCTAssertEqual(commits.count, 3, "Другая обложка продолжает принимать Pencil во время удаления")

    let coverInput = NotebookInteractionTouchView(inputGate: gate), finger = InputTouch()
    finger.inputType = .direct
    var taps = 0
    coverInput.onTap = { _, _ in taps += 1 }
    coverInput.updateOwnerAvailability { !blocked.contains(deleting) }
    coverInput.touchesBegan([finger], with: event)
    coverInput.touchesEnded([finger], with: event)
    XCTAssertEqual(taps, 0)
    coverInput.updateOwnerAvailability { !blocked.contains(other) }
    coverInput.touchesBegan([finger], with: event)
    coverInput.touchesEnded([finger], with: event)
    XCTAssertEqual(taps, 1, "Отказ одного владельца не выключает соседнюю обложку")
  }

  @MainActor
  func testPendingSceneClosesOnlyNewSpatialAdmissionAndKeepsAcceptedContactUntilLift() async throws {
    let gate = NotebookInputGate(), registry = SpatialInkSurfaceRegistry(), board = UUID(), cover = UUID()
    let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: windowScene), host = UIViewController()
    let canvas = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host; host.view.addSubview(canvas); window.makeKeyAndVisible()
    let cohort = try await WorkspaceInkFixture.prepare(boardID: board, camera: .init(scale: 0.3),
      viewport: .init(x: 600, y: 800), items: [.init(itemID: cover, geometry: .notebook, center: .zero, zIndex: 1)], journal: nil, registry: registry)
    let physical = try WorkspaceInkFixture(cohort: cohort,
      presence: .init(boardID: board, mode: .board, camera: .init(scale: 0.3), viewport: .init(x: 600, y: 800)),
      canvas: canvas, parent: host, registry: registry, gate: gate, journal: nil)
    defer { physical.close() }
    var preparing = false, commits: [[SpatialInkSpan]] = []
    let owner = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: gate) { _, _, _ in nil }
    defer { owner.uninstall(); window.isHidden = true }
    func update(enabled: Bool = true) {
      owner.update(view: canvas, cohort: cohort, boardID: board, camera: .init(scale: 0.3), viewport: .init(x: 600, y: 800),
        items: [.init(itemID: cover, geometry: .notebook, center: .zero, zIndex: 1)],
        journal: cohort.liveData.ink, penStyle: .standard, eraserStyle: .standard, drawingTool: .pen,
        surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { _ in false },
        admitsNewContact: { !preparing }, isEnabled: enabled,
        onCommit: { tool, color, spans in commits.append(spans); return self.acceptedAction(tool, color, spans) })
    }
    update()
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = InputTouch(), event = UIEvent()
    touch.point = .init(x: 300, y: 400)
    pencil.touchesBegan([touch], with: event)
    preparing = true
    update()
    XCTAssertTrue(commits.isEmpty, "Подготовка другого изменения не завершает уже принятое касание")
    XCTAssertTrue(gate.hasActivePencil)
    touch.point.x += 20; touch.sampleTime += 0.1
    pencil.touchesMoved([touch], with: event)
    XCTAssertTrue(commits.isEmpty)
    pencil.touchesEnded([touch], with: event)
    XCTAssertEqual(commits.count, 1)
    XCTAssertEqual(commits.first?.map(\.surface), [.cover(cover)])
    XCTAssertFalse(gate.hasActivePencil)

    pencil.reset()
    pencil.touchesBegan([touch], with: event)
    XCTAssertEqual(pencil.state, .failed, "Следующий контакт ждёт готовую геометрию")
    pencil.touchesEnded([touch], with: event)
    XCTAssertEqual(commits.count, 1)
    XCTAssertFalse(gate.hasActivePencil)

    // Admission observes the ready owner directly, without waiting for SwiftUI.
    preparing = false
    pencil.reset()
    pencil.touchesBegan([touch], with: event)
    XCTAssertTrue(gate.hasActivePencil)
    update(enabled: false)
    XCTAssertEqual(commits.count, 2, "Явное выключение инструмента по-прежнему завершает принятый контакт")
    XCTAssertFalse(gate.hasActivePencil)
    pencil.touchesEnded([touch], with: event)
    XCTAssertEqual(commits.count, 2)
  }

  @MainActor
  func testFinishedSpatialEraserKeepsTheSameGeometryThroughCanonicalEchoAndCameraUpdates() async throws {
    let actor = UUID(), board = UUID(), gate = NotebookInputGate(), registry = SpatialInkSurfaceRegistry()
    let resources = SceneRenderResources()
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
    let cohort = try await WorkspaceInkFixture.prepare(boardID: board, camera: .init(scale: 1),
      viewport: .init(x: 600, y: 800), items: [], journal: journal, registry: registry, resources: resources)
    let physical = try WorkspaceInkFixture(cohort: cohort,
      presence: .init(boardID: board, mode: .board, camera: .init(scale: 1), viewport: .init(x: 600, y: 800)),
      canvas: canvas, parent: host, registry: registry, gate: gate, journal: journal)
    defer { physical.close() }
    let coordinator = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: gate) { _, _, _ in nil }
    defer { coordinator.uninstall(); window.isHidden = true }
    func update(camera: SpatialCamera = .init(scale: 1)) {
      coordinator.update(view: canvas, cohort: cohort, boardID: board, camera: camera, viewport: .init(x: 600, y: 800),
        items: [], journal: journal, penStyle: .standard, eraserStyle: .standard, drawingTool: .eraser,
        surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { _ in false }, admitsNewContact: { true }, isEnabled: true, onCommit: { tool, color, spans in
          journal.append(tool: tool, color: color, spans: spans, actor: actor)
        })
    }
    update()
    let installedCanvas = try XCTUnwrap(canvas.inkView)
    for _ in 0..<200 where installedCanvas.committedVertexCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
    let baseline = installedCanvas.committedVertexCount
    XCTAssertGreaterThan(baseline, 0)
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = InputTouch(), event = UIEvent()
    pencil.touchesBegan([touch], with: event)
    update()
    XCTAssertEqual(installedCanvas.committedVertexCount, baseline, "Первое касание не очищает рисунок")
    touch.point.x += 80; touch.sampleTime += 0.1
    pencil.touchesMoved([touch], with: event)
    pencil.touchesEnded([touch], with: event)
    let committed = installedCanvas.committedVertexCount
    XCTAssertGreaterThan(committed, baseline)
    XCTAssertGreaterThan(installedCanvas.committedEraserVertexCount, 0)
    let installations = installedCanvas.spatialMeshInstallCount
    let installedSource = try XCTUnwrap(installedCanvas.installedSpatialSource?.referenceInk())
    let eraserVertices = installedCanvas.committedEraserVertexCount
    update()
    XCTAssertEqual(installedCanvas.committedVertexCount, committed,
      "Публикация стирания не подменяет ту же доску пустой геометрией")
    XCTAssertEqual(installedCanvas.spatialMeshInstallCount, installations,
      "До готовности новой геометрии остаётся уже показанный результат")
    for frame in 0..<200 {
      update(camera: .init(center: .init(x: Double(frame), y: 0), scale: 1 + Double(frame) / 500))
      XCTAssertGreaterThan(installedCanvas.committedVertexCount, 0)
    }
    let echo = try await registry.prepareSceneInk(plan: cohort.plan, frame: cohort.frame,
      liveData: .init(documents: cohort.liveData.documents, states: cohort.liveData.states,
        pages: cohort.liveData.pages, ink: journal), resources: resources, displayScale: 1)
    try echo.install()
    XCTAssertTrue(registry.canvas(for: .board(board)) === installedCanvas)
    XCTAssertEqual(installedCanvas.spatialMeshInstallCount, installations,
      "The canonical echo adopts the accepted source without reinstalling identical pen/eraser geometry")
    XCTAssertEqual(try installedCanvas.installedSpatialSource?.referenceInk(), installedSource)
    XCTAssertEqual(installedSource.actions, journal.actions)
    XCTAssertEqual(installedCanvas.committedVertexCount, committed)
    XCTAssertEqual(installedCanvas.committedEraserVertexCount, eraserVertices)
    let settled = installedCanvas.spatialMeshInstallCount
    for frame in 0..<100 {
      update(camera: .init(center: .init(x: Double(frame), y: 0), scale: 0.5))
    }
    XCTAssertEqual(installedCanvas.spatialMeshInstallCount, settled,
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
  func testTerminalDismantleCompletesMeasuredInkAndCannotReinstallItsRecognizer() async throws {
    try await assertSpatialCompletion(.retired)
  }

  @MainActor
  func testOwnerChangeFinishesInkAgainstItsOriginalBoard() async throws {
    try await assertSpatialCompletion(.ownerChanged)
  }

  private enum InputEnding { case disabled, reset, cancelled, lifted, detached, retired, ownerChanged }

  @MainActor
  private func assertSpatialCompletion(_ ending: InputEnding) async throws {
    let gate = NotebookInputGate(), registry = SpatialInkSurfaceRegistry(), boardID = UUID()
    var nextBoardID = boardID
    var projection = SpatialCamera(scale: 1)
    var commits: [(SpatialInkTool, [SpatialInkSpan])] = []
    let coordinator = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: gate) { tool, color, spans in commits.append((tool, spans)); return self.acceptedAction(tool, color, spans) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let host = UIViewController()
    let canvas = SpatialInkContainerView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host
    host.view.addSubview(canvas)
    window.makeKeyAndVisible()
    let cohort = try await WorkspaceInkFixture.prepare(boardID: boardID, camera: projection,
      viewport: .init(x: 600, y: 800), items: [], journal: nil, registry: registry)
    let physical = try WorkspaceInkFixture(cohort: cohort,
      presence: .init(boardID: boardID, mode: .board, camera: projection, viewport: .init(x: 600, y: 800)),
      canvas: canvas, parent: host, registry: registry, gate: gate, journal: nil)
    defer { physical.close() }
    defer { coordinator.uninstall(); window.isHidden = true }
    func update(enabled: Bool) {
      coordinator.update(view: canvas, cohort: cohort, boardID: nextBoardID, camera: projection, viewport: .init(x: 600, y: 800),
        items: [], journal: cohort.liveData.ink, penStyle: .standard, eraserStyle: .standard, drawingTool: .eraser,
        surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { _ in false }, admitsNewContact: { true }, isEnabled: enabled,
        onCommit: { tool, color, spans in commits.append((tool, spans)); return self.acceptedAction(tool, color, spans) })
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
    case .retired: SpatialInkCanvas.dismantleUIView(canvas, coordinator: coordinator)
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

    if ending == .retired {
      update(enabled: true)
      coordinator.install(on: window, inside: canvas)
      XCTAssertFalse(window.gestureRecognizers?.contains { $0 is SpatialPencilGestureRecognizer } ?? false,
        "A late configuration cannot give a retired input owner a new recognizer")
      XCTAssertEqual(commits.count, 1)
    }

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
    weak let weakMonitor = monitor
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
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
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
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var incoming = try XCTUnwrap(model.collaborationContent)
    let source = UUID()
    let element = AgentElement(id: "agent", kind: .web, frame: .init(x: 100, y: 100, width: 200, height: 80), source: "Agent", html: "Agent")
    XCTAssertTrue(incoming.pages[0].replaceElements([element], actor: UUID()))
    model.inputGate.beginContact(source: source)
    let peer = NotebookStore(root: root.appendingPathComponent("peer")), peerID = UUID()
    try NotebookPeerFixture.copy(from: model.store, to: peer, peerID: model.actorID)
    _ = try peer.savePage(incoming.pages[0])
    let delivery = Task { try await NotebookPeerFixture.deliver(from: peer, to: model, peerID: peerID) }
    await Task.yield()
    XCTAssertTrue(try XCTUnwrap(model.activePage).elements.isEmpty)
    XCTAssertTrue(try model.store.loadPage(incoming.pages[0].id).elements.isEmpty)
    XCTAssertFalse(model.permitsBackgroundPreparation)
    var human = try model.store.loadPage(incoming.pages[0].id)
    XCTAssertTrue(human.replaceElements([.init(id: "human", kind: .markdown, frame: .init(x: 30, y: 400, width: 120, height: 90), source: "Human", html: "Human")], actor: model.actorID))
    _ = try model.store.savePage(human)
    model.inputGate.endContact(source: source)
    for _ in 0..<100 where model.inputGate.isActive { await Task.yield() }
    XCTAssertFalse(model.inputGate.isActive)
    try await delivery.value
    let duplicate = try XCTUnwrap(peer.changeJournal(after: 0, limit: 16).last)
    for _ in 0..<50 { _ = try await model.applyDurablePeerChange(duplicate, peerID: peerID) }
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
  var sourceView: UIView?
  override var view: UIView? { sourceView }
  override var type: UITouch.TouchType { inputType }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func location(in view: UIView?) -> CGPoint { point }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}

extension NotebookInputTests {
  @MainActor
  func testPencilKeepsValidSpansWithoutDrawingAcrossTheFiniteWorldEdge() async throws {
    for tool in [DrawingTool.pen, .eraser] {
      for sign in [-1, 1] {
        for axis in ["x", "y"] {
          let edge = sign > 0 ? WorldPoint.tileSize - 32 : 32
          let center = WorldPoint(tileX: axis == "x" ? Int64(sign) * WorldPoint.maximumTileIndex : 0,
            tileY: axis == "y" ? Int64(sign) * WorldPoint.maximumTileIndex : 0,
            localX: axis == "x" ? edge : 0, localY: axis == "y" ? edge : 0)
          let camera = SpatialCamera(center: center, scale: 1), viewport = SpatialPoint(x: 600, y: 800)
          let gate = NotebookInputGate(), registry = SpatialInkSurfaceRegistry(), board = WorkspaceRoot.boardID
          var commits: [SpatialInkAction] = []
          let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
          let window = UIWindow(windowScene: scene), host = UIViewController()
          let canvas = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 600, height: 800))
          window.rootViewController = host; host.view.addSubview(canvas); window.makeKeyAndVisible()
          let cohort = try await WorkspaceInkFixture.prepare(boardID: board, camera: camera,
            viewport: viewport, items: [], registry: registry)
          let physical = try WorkspaceInkFixture(cohort: cohort,
            presence: .init(boardID: board, mode: .board, camera: camera, viewport: viewport),
            canvas: canvas, parent: host, registry: registry, gate: gate)
          defer { physical.close() }
          let commit: (SpatialInkTool, SpatialInkColor, [SpatialInkSpan]) -> SpatialInkAction? = { tool, color, spans in
            let value = self.acceptedAction(tool, color, spans); commits.append(value); return value
          }
          let owner = SpatialInkCanvas.Coordinator(surfaceRegistry: registry, inputGate: gate, onCommit: commit)
          defer { owner.uninstall(); window.isHidden = true }
          owner.update(view: canvas, cohort: cohort, boardID: board, camera: camera, viewport: viewport,
            items: [], journal: cohort.liveData.ink, penStyle: .standard, eraserStyle: .standard, drawingTool: tool,
            surfaceRegistry: registry, inputGate: gate, isItemBeingDeleted: { _ in false },
            admitsNewContact: { true }, isEnabled: true, onCommit: commit)
          let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
          let touch = InputTouch(), event = UIEvent()
          func point(_ delta: Double) -> CGPoint {
            .init(x: 300 + (axis == "x" ? Double(sign) * delta : 0),
              y: 400 + (axis == "y" ? Double(sign) * delta : 0))
          }
          touch.point = point(-24); pencil.touchesBegan([touch], with: event)
          XCTAssertTrue(gate.hasActivePencil, "The actual installed cohort admitted this contact")
          for delta in [24.0, 64, 24, -24] {
            touch.point = point(delta); touch.sampleTime += 0.1
            pencil.touchesMoved([touch], with: event)
          }
          pencil.touchesEnded([touch], with: event)
          XCTAssertFalse(gate.hasActivePencil)
          XCTAssertGreaterThan(owner.rejectedWorldAddressCount, 0)
          XCTAssertEqual(commits.count, 1)
          let action = try XCTUnwrap(commits.first)
          XCTAssertEqual(action.spans.count, 2, "No bridge through an unaddressable interval")
          XCTAssertEqual(action.spans.map { $0.samples.count }, [2, 2])
          let expected = [-24.0, 24, 24, -24].map { camera.worldAddress(at: .init(x: point($0).x, y: point($0).y), viewport: viewport) }
          XCTAssertEqual(action.spans.flatMap { $0.samples.map(\.worldPoint) }, expected)
          XCTAssertEqual(try JSONDecoder().decode(SpatialInkAction.self, from: JSONEncoder().encode(action)), action)
          XCTAssertEqual(action.tool, tool == .pen ? .pen : .eraser)
          let stored = try await Task.detached {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("edge-contact-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = NotebookStore(root: root)
            _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
            _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
            return try store.readSpatialInk(surfaces: [.board(board)])
          }.value
          XCTAssertEqual(stored.actions, [action], "Both accepted spans keep their UUID, exact points and tool in SQLite")
          // A subsequent wholly outside contact has no accepted content and must
          // not publish an empty action or retain a Pencil gate/lease.
          touch.point = point(96); touch.sampleTime += 1
          pencil.touchesBegan([touch], with: event); pencil.touchesEnded([touch], with: event)
          XCTAssertEqual(commits.count, 1)
          XCTAssertFalse(gate.hasActivePencil)
        }
      }
    }
  }
}
