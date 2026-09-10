import NotebookCore
import UIKit
import XCTest
@testable import Notebook

final class AcceptedPageInputTests: XCTestCase {
  @MainActor
  func testPencilLiftRegistersItsMutationBeforeReleasingWaitingPageInput() async throws {
    let gate = NotebookInputGate()
    let page = PageDocument(size: .init(width: 834, height: 1194), actor: UUID())
    let stamp = VersionStamp(counter: 1, actor: UUID())
    let entered = expectation(description: "accepted preparation entered")
    var release: CheckedContinuation<PreparedPageInkChange?, Never>?
    var acceptedAction: PageInkAction?
    let coordinator = PencilCanvasView.Coordinator(inputGate: gate,
      reserveAction: { _ in stamp }, releaseAction: { _, _ in }, acceptAction: { action, _, _ in
        acceptedAction = action
        return Task { await withCheckedContinuation { release = $0; entered.fulfill() } }
      })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper)
    coordinator.setPageFinisherCurrent(true)
    coordinator.apply(Data(), pageID: page.id, to: paper)
    let touch = AcceptedInputTouch()
    paper.touchView.touchesBegan([touch], with: nil)
    var released = false
    let drained = expectation(description: "waiting page input released")
    gate.performAfterPageInput { released = true; drained.fulfill() }
    XCTAssertFalse(released)
    touch.point = .init(x: 180, y: 240); touch.sampleTime = 1.01
    paper.touchView.touchesEnded([touch], with: nil)
    XCTAssertFalse(released, "Pencil-up cannot release the waiter before its accepted preparation is registered")
    await fulfillment(of: [entered], timeout: 2)
    let action = try XCTUnwrap(acceptedAction)
    let prepared = try page.prepareInkChange(.append(action), stamp: stamp)
    release?.resume(returning: prepared)
    await fulfillment(of: [drained], timeout: 2)
    XCTAssertEqual(prepared.drawing.activeActions.map(\.id), [action.id])
    coordinator.detach(from: paper)
  }

  @MainActor
  func testWaitingInteractionDrainSavesTheExactLiftedAction() async throws {
    let entered = expectation(description: "model preparation held")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [entered])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage)
    var action: PageInkAction?
    let coordinator = PencilCanvasView.Coordinator(inputGate: model.inputGate,
      reserveAction: model.reserveDrawingAction,
      releaseAction: { model.releaseDrawingReservation(pageID: $0, stamp: $1) }, acceptAction: { mutation, pageID, stamp in
        action = mutation
        return model.acceptDrawingAction(mutation, pageID: pageID, stamp: stamp)
      })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper); coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.drawingData, pageID: page.id, to: paper)
    await waitForDecodedInput(paper)
    let touch = AcceptedInputTouch()
    paper.touchView.touchesBegan([touch], with: nil)
    let drainStarted = expectation(description: "drain waiting at Pencil contact")
    var drainFinished = false
    let drain = Task { @MainActor in
      drainStarted.fulfill()
      let saved = await model.finishPendingInteraction()
      drainFinished = true
      return saved
    }
    await fulfillment(of: [drainStarted], timeout: 2)
    touch.point = .init(x: 180, y: 240); touch.sampleTime = 1.01
    paper.touchView.touchesEnded([touch], with: nil)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 1, "Ownership transfers before the lift callback returns")
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertFalse(drainFinished)
    XCTAssertTrue(try PageInkDrawing.decode(model.store.loadPage(page.id).drawingData).activeActions.isEmpty)
    await barrier.releaseNext()
    let saved = await drain.value
    XCTAssertTrue(saved)
    let measured = try XCTUnwrap(action)
    let reopened = try NotebookStore(root: root).loadPage(page.id)
    XCTAssertEqual(try PageInkDrawing.decode(reopened.drawingData).activeActions, PageInkDrawing(actions: [measured]).activeActions)
    XCTAssertEqual(measured.samples.map(\.point), [.init(x: 120, y: 220), .init(x: 180, y: 240)])
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 0)
    coordinator.detach(from: paper)
  }

  @MainActor
  func testUnmountTransfersTheCurrentMeasuredContactBeforeRemovingCallbacks() async throws {
    let entered = expectation(description: "unmounted measured contact transferred")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [entered])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage)
    var mutation: PageInkAction?
    let coordinator = PencilCanvasView.Coordinator(inputGate: model.inputGate,
      reserveAction: model.reserveDrawingAction,
      releaseAction: { model.releaseDrawingReservation(pageID: $0, stamp: $1) }, acceptAction: { action, pageID, stamp in
        mutation = action
        return model.acceptDrawingAction(action, pageID: pageID, stamp: stamp)
      })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper); coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.drawingData, pageID: page.id, to: paper)
    await waitForDecodedInput(paper)
    let touch = AcceptedInputTouch()
    paper.touchView.touchesBegan([touch], with: nil)
    touch.point = .init(x: 180, y: 240); touch.sampleTime = 1.01
    paper.touchView.touchesMoved([touch], with: nil)
    coordinator.detach(from: paper)
    XCTAssertFalse(model.inputGate.hasActivePencil)
    XCTAssertFalse(paper.touchView.hasActiveAction)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 1)
    await fulfillment(of: [entered], timeout: 2)
    await barrier.releaseNext()
    let saved = await model.finishPendingInteraction()
    XCTAssertTrue(saved)
    let accepted = try XCTUnwrap(mutation)
    XCTAssertEqual(try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData).activeActions,
      PageInkDrawing(actions: [accepted]).activeActions)
  }

  @MainActor
  func testPencilDownReservationSurvivesRealWorkingSetEvictionBeforeUnmount() async throws {
    let entered = expectation(description: "evicted page's measured action prepared")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [entered])
    let (model, root) = await makeModel(barrier: barrier)
    let itemID = try XCTUnwrap(model.activeItem?.id)
    for index in 1...7 { XCTAssertEqual(model.selectNotebookPage(index, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), index) }
    var saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.prepareNotebookPage(at: 0, in: itemID)
    XCTAssertEqual(model.selectNotebookPage(0, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), 0)
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    await model.prepareNotebookPage(at: 0, in: itemID)
    await model.prepareNotebookPage(at: 3, in: itemID)
    let page = try XCTUnwrap(model.activePage)
    var mutation: PageInkAction?
    let coordinator = PencilCanvasView.Coordinator(inputGate: model.inputGate,
      reserveAction: model.reserveDrawingAction,
      releaseAction: { model.releaseDrawingReservation(pageID: $0, stamp: $1) },
      acceptAction: { action, pageID, stamp in
        mutation = action
        return model.acceptDrawingAction(action, pageID: pageID, stamp: stamp)
      })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper); coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.drawingData, pageID: page.id, to: paper)
    await waitForDecodedInput(paper)
    let touch = AcceptedInputTouch()
    paper.touchView.touchesBegan([touch], with: nil)
    XCTAssertEqual(model.pendingPageDrawingReservationCount, 1)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 0)
    await model.prepareNotebookPage(at: 7, in: itemID)
    XCTAssertEqual(model.selectNotebookPage(7, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), 7)
    await model.prepareNotebookPage(at: 6, in: itemID)
    XCTAssertNil(model.pages[page.id], "The real addressed preparation must evict the old page in this reproduction")
    XCTAssertTrue(paper.touchView.hasActiveAction)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    touch.point = .init(x: 180, y: 240); touch.sampleTime = 1.01
    paper.touchView.touchesMoved([touch], with: nil)
    coordinator.detach(from: paper)
    XCTAssertEqual(model.pendingPageDrawingReservationCount, 0, "Lift transfers the snapshot; it does not retain a second pin")
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 1)
    await fulfillment(of: [entered], timeout: 2)
    await barrier.releaseNext()
    saved = await model.finishPendingInteraction(); XCTAssertTrue(saved)
    let accepted = try XCTUnwrap(mutation)
    XCTAssertEqual(try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData).activeActions,
      PageInkDrawing(actions: [accepted]).activeActions)
  }

  @MainActor
  func testCancelledAndUnmeasuredContactsReleaseTheirReservation() async throws {
    let barrier = AcceptedInkPreparationBarrier(arrivals: [])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage)
    let coordinator = PencilCanvasView.Coordinator(inputGate: model.inputGate,
      reserveAction: model.reserveDrawingAction,
      releaseAction: { model.releaseDrawingReservation(pageID: $0, stamp: $1) },
      acceptAction: { model.acceptDrawingAction($0, pageID: $1, stamp: $2) })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper); coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.drawingData, pageID: page.id, to: paper)
    await waitForDecodedInput(paper)
    paper.touchView.touchesBegan([AcceptedInputTouch()], with: nil)
    XCTAssertEqual(model.pendingPageDrawingReservationCount, 1)
    paper.touchView.apply(PageInkDrawing())
    XCTAssertEqual(model.pendingPageDrawingReservationCount, 0)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 0)
    XCTAssertFalse(model.inputGate.hasActivePencil)
    XCTAssertTrue(paper.touchView.onActionWillBegin?() == true)
    XCTAssertEqual(model.pendingPageDrawingReservationCount, 1)
    coordinator.detach(from: paper)
    XCTAssertEqual(model.pendingPageDrawingReservationCount, 0)
    let saved = await model.finishPendingInteraction(); XCTAssertTrue(saved)
    XCTAssertTrue(try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData).isEmpty)
  }

  @MainActor
  func testPreviousPagePreparationRemainsOwnedAfterChangingTheMountedPage() async throws {
    try await checkRetiredPagePreparation(detach: false)
  }

  @MainActor
  func testUnmountedPagePreparationRemainsOwnedUntilDurableDrain() async throws {
    try await checkRetiredPagePreparation(detach: true)
  }

  @MainActor
  private func checkRetiredPagePreparation(detach: Bool) async throws {
    let entered = expectation(description: "previous page preparation held")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [entered])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage)
    let itemID = try XCTUnwrap(model.activeItem?.id)
    let coordinator = PencilCanvasView.Coordinator(inputGate: model.inputGate,
      reserveAction: model.reserveDrawingAction,
      releaseAction: { model.releaseDrawingReservation(pageID: $0, stamp: $1) }, acceptAction: { model.acceptDrawingAction($0, pageID: $1, stamp: $2) })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper); coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.drawingData, pageID: page.id, to: paper)
    await waitForDecodedInput(paper)
    let mutation = stroke(y: 90)
    XCTAssertTrue(paper.touchView.onActionWillBegin?() == true)
    coordinator.commit(mutation, on: paper)
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), 1)
    let next = try XCTUnwrap(model.activePage)
    XCTAssertNotEqual(next.id, page.id)
    if detach { coordinator.detach(from: paper) }
    else { coordinator.apply(next.drawingData, pageID: next.id, to: paper) }
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 1,
      "Neither a page change nor unmount transfers accepted work to a disposable UI owner")
    let drainStarted = expectation(description: "model drain started without the old page finisher")
    var releasedPreparation = false
    let drain = Task { @MainActor in
      drainStarted.fulfill()
      let saved = await model.finishPendingPersistence()
      XCTAssertTrue(releasedPreparation, "A changed current page cannot acknowledge the previous page's suspended preparation")
      return saved
    }
    await fulfillment(of: [drainStarted], timeout: 2)
    releasedPreparation = true
    await barrier.releaseNext()
    let saved = await drain.value
    XCTAssertTrue(saved)
    let reopened = NotebookStore(root: root)
    XCTAssertEqual(try PageInkDrawing.decode(reopened.loadPage(page.id).drawingData).activeActions, PageInkDrawing(actions: [mutation]).activeActions)
    XCTAssertTrue(try PageInkDrawing.decode(reopened.loadPage(next.id).drawingData).activeActions.isEmpty)
    if !detach { coordinator.detach(from: paper) }
  }

  @MainActor
  func testPreparationFailureRetainsMeasuredInkAndDependenciesForTheSameRetry() async throws {
    let first = expectation(description: "first accepted stroke held")
    let retry = expectation(description: "same stroke retried")
    let dependent = expectation(description: "dependent stroke prepared after retry")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [first, retry, dependent])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage)
    var mutations: [PageInkAction] = []
    let coordinator = PencilCanvasView.Coordinator(inputGate: model.inputGate,
      reserveAction: model.reserveDrawingAction,
      releaseAction: { model.releaseDrawingReservation(pageID: $0, stamp: $1) }, acceptAction: { action, pageID, stamp in
        mutations.append(action)
        return model.acceptDrawingAction(action, pageID: pageID, stamp: stamp)
      })
    let paper = PaperCanvasContainerView()
    coordinator.attach(to: paper); coordinator.setPageFinisherCurrent(true)
    coordinator.apply(page.drawingData, pageID: page.id, to: paper)
    await waitForDecodedInput(paper)
    write(on: paper, y: 40)
    write(on: paper, y: 80)
    let measuredVertices = paper.inkView.committedVertexCount
    XCTAssertGreaterThan(measuredVertices, 0)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 2)
    await fulfillment(of: [first], timeout: 2)
    await barrier.releaseNext(failing: true)
    let rejected = await model.finishPendingInteraction()
    XCTAssertFalse(rejected)
    XCTAssertNotNil(model.acceptedPageInkFailure)
    XCTAssertNotNil(model.persistenceFailure)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 2)
    XCTAssertEqual(paper.inkView.committedVertexCount, measuredVertices,
      "Preparation failure must not restore the old blank model over accepted measured ink")
    XCTAssertTrue(try PageInkDrawing.decode(model.store.loadPage(page.id).drawingData).activeActions.isEmpty)
    model.retryPendingPersistence()
    await fulfillment(of: [retry], timeout: 2)
    await barrier.releaseNext()
    await fulfillment(of: [dependent], timeout: 2)
    await barrier.releaseNext()
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertNil(model.acceptedPageInkFailure)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 0)
    XCTAssertEqual(try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData).activeActions, PageInkDrawing(actions: mutations).activeActions)
    coordinator.detach(from: paper)
  }

  @MainActor
  func testUndoWaitsForAcceptedPreparationAndUsesTheSameOwner() async throws {
    let append = expectation(description: "append held")
    let remove = expectation(description: "undo held after append")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [append, remove])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage)
    let action = stroke(y: 120)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let delivery = model.acceptDrawingAction(action, pageID: page.id, stamp: stamp)
    await fulfillment(of: [append], timeout: 2)
    let undoStarted = expectation(description: "undo pinned to original page")
    let undo = Task { @MainActor in
      undoStarted.fulfill()
      _ = await model.acceptDrawingUndo().value
    }
    await fulfillment(of: [undoStarted], timeout: 2)
    let itemID = try XCTUnwrap(model.activeItem?.id)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), 1)
    XCTAssertNotEqual(model.activePage?.id, page.id)
    await barrier.releaseNext()
    await fulfillment(of: [remove], timeout: 2)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 1)
    await barrier.releaseNext()
    _ = await delivery.value
    await undo.value
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let drawing = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData)
    XCTAssertTrue(drawing.activeActions.isEmpty)
    XCTAssertEqual(drawing.actions.map(\.id), [action.id], "Undo retains the causal UUID rather than replacing the drawing")
  }

  @MainActor
  func testUndoIsAdmittedBeforeShutdownCanDrainItsPredecessor() async throws {
    let append = expectation(description: "predecessor append held")
    let undo = expectation(description: "accepted undo held")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [append, undo])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage)
    let action = stroke(y: 140)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let appendDelivery = model.acceptDrawingAction(action, pageID: page.id, stamp: stamp)
    await fulfillment(of: [append], timeout: 2)
    XCTAssertTrue(model.isPageOpen)
    model.undoLastSurfaceAction()
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 2,
      "The human undo belongs to the same FIFO before its command callback returns")
    var shutdownFinished = false
    let stop = Task { @MainActor in
      let saved = await model.shutdown()
      shutdownFinished = true
      return saved
    }
    await barrier.releaseNext()
    await fulfillment(of: [undo], timeout: 2)
    XCTAssertFalse(shutdownFinished, "Shutdown must include the already accepted undo, not only its predecessor")
    await barrier.releaseNext()
    _ = await appendDelivery.value
    let saved = await stop.value
    XCTAssertTrue(saved)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    let drawing = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.actions.map(\.id), [action.id])
    XCTAssertTrue(drawing.activeActions.isEmpty)
  }

  @MainActor
  func testUndoPinsItsPageBeforeSelectionAndRealEvictionDuringQueueWait() async throws {
    let append = expectation(description: "append before queued undo held")
    let undo = expectation(description: "undo of evicted original page held")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [append, undo])
    let (model, root) = await makeModel(barrier: barrier)
    let itemID = try XCTUnwrap(model.activeItem?.id)
    for index in 1...7 { XCTAssertEqual(model.selectNotebookPage(index, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), index) }
    var saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.prepareNotebookPage(at: 0, in: itemID)
    XCTAssertEqual(model.selectNotebookPage(0, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), 0)
    saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    await model.prepareNotebookPage(at: 0, in: itemID)
    await model.prepareNotebookPage(at: 3, in: itemID)
    let page = try XCTUnwrap(model.activePage)
    let action = stroke(y: 160)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let appendDelivery = model.acceptDrawingAction(action, pageID: page.id, stamp: stamp)
    await fulfillment(of: [append], timeout: 2)
    model.undoLastSurfaceAction()
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 2)
    await model.prepareNotebookPage(at: 7, in: itemID)
    XCTAssertEqual(model.selectNotebookPage(7, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), 7)
    await model.prepareNotebookPage(at: 6, in: itemID)
    XCTAssertNil(model.pages[page.id], "This is actual bounded-workset eviction, not merely a selection change")
    await barrier.releaseNext()
    await fulfillment(of: [undo], timeout: 2)
    await barrier.releaseNext()
    _ = await appendDelivery.value
    saved = await model.finishPendingInteraction(); XCTAssertTrue(saved)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    XCTAssertNil(model.pages[page.id], "Finishing an offscreen input does not enlarge the scene's read window")
    let drawing = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.actions.map(\.id), [action.id])
    XCTAssertTrue(drawing.activeActions.isEmpty)
  }

  @MainActor
  func testRepeatedUUIDDoesNotBecomeANewUndoContribution() async throws {
    let barrier = AcceptedInkPreparationBarrier(arrivals: [])
    await barrier.open()
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage)
    let first = stroke(y: 180), second = stroke(y: 200)
    for action in [first, second, first] {
      let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
      let delivery = await model.acceptDrawingAction(action, pageID: page.id, stamp: stamp).value
      XCTAssertNotNil(delivery)
    }
    _ = await model.acceptDrawingUndo().value
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let drawing = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.activeActions.map(\.id), [first.id],
      "Repeating the first UUID must not move it above the genuinely newer second stroke in undo history")
    XCTAssertEqual(Set(drawing.actions.map(\.id)), [first.id, second.id])
  }

  @MainActor
  func testRecognizedWorkspaceUndoJoinsTheDrainAlreadyWaitingForItsPredecessor() async throws {
    let append = expectation(description: "append held before recognized command")
    let undo = expectation(description: "recognized undo held in model FIFO")
    let command = expectation(description: "UIKit delivered the recognized command")
    let drainStarted = expectation(description: "drain waiting for append")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [append, undo])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage), action = stroke(y: 220)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let delivery = model.acceptDrawingAction(action, pageID: page.id, stamp: stamp)
    await fulfillment(of: [append], timeout: 2)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene), host = UIViewController()
    let anchor = UIView(frame: .init(x: 0, y: 0, width: 600, height: 800))
    window.rootViewController = host; host.view.addSubview(anchor); window.makeKeyAndVisible()
    let layer = WorkspaceGestureLayer(isEnabled: true, defersHorizontalMotionToPageTurn: true,
      inputGate: model.inputGate, onCamera: { _ in XCTFail("A stationary undo cannot move the camera") },
      onUndo: {
        model.undoLastSurfaceAction()
        XCTAssertEqual(model.pendingAcceptedPageInkCount, 2,
          "The recognized callback must not defer admission through afterPageInput")
        command.fulfill()
      })
    let owner = layer.makeCoordinator()
    owner.install(on: window, inside: anchor)
    defer { owner.uninstall(); window.isHidden = true; oldKeyWindow?.makeKey() }
    let recognizer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? TwoFingerPaperGestureRecognizer }.first)
    var drainFinished = false
    let drain = Task { @MainActor in
      drainStarted.fulfill()
      let saved = await model.finishPendingInteraction()
      drainFinished = true
      return saved
    }
    await fulfillment(of: [drainStarted], timeout: 2)
    let first = AcceptedInputTouch(), second = AcceptedInputTouch(), event = UIEvent()
    first.inputType = .direct; second.inputType = .direct
    first.point = .init(x: 100, y: 300); second.point = .init(x: 300, y: 300)
    recognizer.touchesBegan([first, second], with: event)
    first.sampleTime += 0.05; second.sampleTime += 0.05
    recognizer.touchesEnded([first, second], with: event)
    await fulfillment(of: [command], timeout: 2)
    await barrier.releaseNext()
    await fulfillment(of: [undo], timeout: 2)
    XCTAssertFalse(drainFinished)
    await barrier.releaseNext()
    _ = await delivery.value
    let saved = await drain.value; XCTAssertTrue(saved)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    let drawing = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.actions.map(\.id), [action.id])
    XCTAssertTrue(drawing.activeActions.isEmpty)
  }

  @MainActor
  func testNewUndoIsRejectedDuringPencilButAllowedAfterItsLift() async throws {
    let barrier = AcceptedInkPreparationBarrier(arrivals: [])
    await barrier.open()
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage), action = stroke(y: 240)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    _ = await model.acceptDrawingAction(action, pageID: page.id, stamp: stamp).value
    let pencil = UUID()
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    defer { model.inputGate.endPencilAction(source: pencil) }
    model.undoLastSurfaceAction()
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 0)
    let rejected = await model.acceptDrawingUndo().value; XCTAssertNil(rejected)
    model.inputGate.endPencilAction(source: pencil)
    let accepted = await model.acceptDrawingUndo().value; XCTAssertNotNil(accepted)
    let saved = await model.finishPendingInteraction(); XCTAssertTrue(saved)
    XCTAssertLessThanOrEqual(model.pages.count, 4)
    let drawing = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.actions.map(\.id), [action.id])
    XCTAssertTrue(drawing.activeActions.isEmpty)
  }

  @MainActor
  func testNewUndoIsRejectedAfterShutdownClosesAdmission() async throws {
    let append = expectation(description: "accepted append held during closing")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [append])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage), action = stroke(y: 260)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let delivery = model.acceptDrawingAction(action, pageID: page.id, stamp: stamp)
    await fulfillment(of: [append], timeout: 2)
    let stop = Task { @MainActor in await model.shutdown() }
    let clock = ContinuousClock(), deadline = clock.now + .seconds(2)
    while model.shutdownPhase == .running, clock.now < deadline { await Task.yield() }
    XCTAssertEqual(model.shutdownPhase, .closing)
    model.undoLastSurfaceAction()
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 1)
    let rejected = await model.acceptDrawingUndo().value; XCTAssertNil(rejected)
    await barrier.releaseNext()
    _ = await delivery.value
    let saved = await stop.value; XCTAssertTrue(saved)
    let drawing = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.activeActions.map(\.id), [action.id])
  }

  @MainActor
  func testFailedUndoRetainsItsUUIDAndDependentAppendUntilExplicitRetry() async throws {
    let append = expectation(description: "initial append held")
    let undo = expectation(description: "undo preparation fails")
    let retry = expectation(description: "same undo retried")
    let dependent = expectation(description: "dependent append follows retried undo")
    let barrier = AcceptedInkPreparationBarrier(arrivals: [append, undo, retry, dependent])
    let (model, root) = await makeModel(barrier: barrier)
    let page = try XCTUnwrap(model.activePage), first = stroke(y: 280), second = stroke(y: 300)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let delivery = model.acceptDrawingAction(first, pageID: page.id, stamp: stamp)
    await fulfillment(of: [append], timeout: 2)
    await barrier.releaseNext(); _ = await delivery.value
    let removal = model.acceptDrawingUndo()
    await fulfillment(of: [undo], timeout: 2)
    let nextStamp = try XCTUnwrap(model.reserveDrawingAction(pageID: page.id))
    let next = model.acceptDrawingAction(second, pageID: page.id, stamp: nextStamp)
    await barrier.releaseNext(failing: true)
    let failed = await removal.value; XCTAssertNil(failed)
    let failedDependency = await next.value; XCTAssertNil(failedDependency)
    let unsaved = await model.finishPendingInteraction(); XCTAssertFalse(unsaved)
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 2)
    model.retryPendingPersistence()
    await fulfillment(of: [retry], timeout: 2)
    await barrier.releaseNext()
    await fulfillment(of: [dependent], timeout: 2)
    await barrier.releaseNext()
    let saved = await model.finishPendingInteraction(); XCTAssertTrue(saved)
    let drawing = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(page.id).drawingData)
    XCTAssertEqual(drawing.activeActions.map(\.id), [second.id])
    XCTAssertEqual(Set(drawing.actions.map(\.id)), [first.id, second.id])
    XCTAssertEqual(model.pendingAcceptedPageInkCount, 0)
  }

  @MainActor
  private func makeModel(barrier: AcceptedInkPreparationBarrier) async -> (NotebookAppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preparePageInk: { try await barrier.prepare($0, mutation: $1, stamp: $2) })
    retainNotebookUntilTeardown(model, removing: root)
    addTeardownBlock { @MainActor in
      await barrier.open()
      model.retryPendingPersistence()
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    return (model, root)
  }

  @MainActor
  private func waitForDecodedInput(_ paper: PaperCanvasContainerView) async {
    let clock = ContinuousClock(), deadline = clock.now + .seconds(2)
    while !paper.touchView.isUserInteractionEnabled, clock.now < deadline { await Task.yield() }
    XCTAssertTrue(paper.touchView.isUserInteractionEnabled, "The fixture must finish page decoding before admitting its Pencil")
  }

  @MainActor
  private func write(on paper: PaperCanvasContainerView, y: CGFloat) {
    let touch = AcceptedInputTouch(); touch.point = .init(x: 120, y: y)
    paper.touchView.touchesBegan([touch], with: nil)
    touch.point = .init(x: 180, y: y + 20); touch.sampleTime = 1.01
    paper.touchView.touchesEnded([touch], with: nil)
  }

  private func stroke(y: Double) -> PageInkAction {
    .init(tool: .pen, samples: [
      .init(point: .init(x: 20, y: y), timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1),
      .init(point: .init(x: 180, y: y + 30), timeOffset: 0.01, width: 3, opacity: 1, force: 0.7, azimuth: 0.1, altitude: 1.2),
    ])
  }

}

@MainActor
private final class AcceptedInputTouch: UITouch {
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


private actor AcceptedInkPreparationBarrier {
  private enum Failure: Error { case preparationUnavailable }
  private let arrivals: [XCTestExpectation]
  private var attempt = 0
  private var waiters: [CheckedContinuation<Void, Error>] = []
  private var isOpen = false

  init(arrivals: [XCTestExpectation]) { self.arrivals = arrivals }

  func prepare(_ page: PageDocument, mutation: PageInkMutation, stamp: VersionStamp) async throws -> PreparedPageInkChange {
    let arrival = arrivals.indices.contains(attempt) ? arrivals[attempt] : nil
    attempt += 1
    if !isOpen {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append(continuation)
        arrival?.fulfill()
      }
    } else { arrival?.fulfill() }
    return try await Task.detached(priority: .userInitiated) {
      try page.prepareInkChange(mutation, stamp: stamp)
    }.value
  }

  func releaseNext(failing: Bool = false) {
    guard !waiters.isEmpty else { return }
    let waiter = waiters.removeFirst()
    if failing { waiter.resume(throwing: Failure.preparationUnavailable) }
    else { waiter.resume() }
  }

  func open() {
    isOpen = true
    let pending = waiters; waiters = []
    for waiter in pending { waiter.resume() }
  }
}
