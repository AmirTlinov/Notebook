import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookReferenceNavigationTests: XCTestCase {
  func testOrdinaryContactDoesNotCancelAnUnrelatedNotebookOpening() async throws {
    let model = try await makeModel()
    var stopped = 0
    model.stopNavigationPresentation = { _ in stopped += 1 }
    model.inputGate.notifyAcceptedContact()
    XCTAssertEqual(stopped, 0, "No reference or return owns this camera; a resting hand must not stop the notebook halfway open")
    model.requestShow(try coverReference(model))
    let before = stopped
    model.inputGate.notifyAcceptedContact()
    XCTAssertNil(model.requestedReference)
    XCTAssertEqual(stopped, before + 1, "Actual pending navigation is still interrupted by a new human contact")
    model.stopNavigationPresentation = nil
  }

  func testAcceptedContactsAreSeparateFromPoseActivityAndRepeatDuringActiveInput() {
    let gate = NotebookInputGate(), pose = UUID(), pencil = UUID()
    var contacts = 0
    gate.onNewAcceptedContact = { contacts += 1 }
    gate.beginContact(source: pose)
    XCTAssertTrue(gate.isActive)
    XCTAssertEqual(contacts, 0, "A programmatic pose tail is not another native down")
    gate.notifyAcceptedContact()
    gate.notifyAcceptedContact()
    XCTAssertEqual(contacts, 2, "Every native down is observed even while activity stays true")
    XCTAssertTrue(gate.beginPencilAction(source: pencil))
    XCTAssertTrue(gate.beginPencilAction(source: pencil))
    XCTAssertEqual(contacts, 3, "A retained Pencil source is the same accepted action")
    gate.bindNewContactAdmission { false }
    gate.notifyAcceptedContact()
    XCTAssertFalse(gate.beginPencilAction(source: UUID()))
    XCTAssertEqual(contacts, 3)
    gate.endPencilAction(source: pencil)
    gate.endContact(source: pose)
  }

  func testLatestShowAndReturnReplaceEachOtherWithoutConsumingCancelledHistory() async throws {
    let model = try await makeModel()
    let original = try XCTUnwrap(model.presence)
    let reference = CollaborationReference(target: .init(kind: .board, id: original.boardID), revision: "test")
    model.requestShow(reference)
    let first = try XCTUnwrap(model.requestedReference)
    XCTAssertEqual(model.returnPlaces.count, 1)
    model.requestReturnToPlace()
    XCTAssertNil(model.requestedReference)
    XCTAssertEqual(model.requestedReturn?.presence, original)
    XCTAssertEqual(model.returnPlaces.count, 1, "Requesting a return does not yet consume it")
    model.requestShow(reference)
    let current = try XCTUnwrap(model.requestedReference)
    XCTAssertNil(model.requestedReturn)
    XCTAssertNotEqual(current.id, first.id)
    model.completeShow(first)
    XCTAssertEqual(model.requestedReference?.id, current.id)
    XCTAssertNil(model.highlightedReference, "A stale completion cannot replace the current selection")
    let pose = UUID()
    model.inputGate.beginContact(source: pose)
    XCTAssertEqual(model.requestedReference?.id, current.id)
    model.inputGate.notifyAcceptedContact()
    XCTAssertNil(model.requestedReference)
    XCTAssertNil(model.requestedReturn)
    XCTAssertEqual(model.returnPlaces.count, 1)
    XCTAssertEqual(model.presence, original)
    model.inputGate.endContact(source: pose)
  }

  func testCancelledNavigationCannotEscapeTheDelayedPageFinisher() async throws {
    let model = try await makeModel()
    let reference = try coverReference(model)
    let source = UUID(), waiting = expectation(description: "navigation reached the page input fence")
    var completions: [NotebookInputCompletion] = []
    model.inputGate.registerPageFinisher(source: source) { _, completion in
      if completions.isEmpty { waiting.fulfill() }
      completions.append(completion)
    }
    model.inputGate.setCurrentPageSource(source, isCurrent: true)
    model.requestShow(reference)
    let requested = try XCTUnwrap(model.requestedReference)
    var applied = false
    let task = Task { await model.resolveReferenceLocation(requested) { _ in applied = true } }
    await fulfillment(of: [waiting], timeout: 2)
    model.inputGate.notifyAcceptedContact()
    model.inputGate.unregisterPageFinisher(source: source)
    for completion in completions { completion() }
    await task.value
    XCTAssertFalse(applied)
    XCTAssertNil(model.requestedReference)
  }

  func testCancelledNavigationDoesNotJoinLaterWorkAfterItsInputFinisher() async throws {
    let model = try await makeModel(), source = UUID()
    let reachedInput = expectation(description: "navigation awaits accepted input")
    let finishedNavigation = expectation(description: "cancelled navigation stops before later persistence")
    var completions: [NotebookInputCompletion] = []
    model.inputGate.registerPageFinisher(source: source) { _, completion in
      if completions.isEmpty { reachedInput.fulfill() }
      completions.append(completion)
    }
    model.inputGate.setCurrentPageSource(source, isCurrent: true)
    model.requestShow(try coverReference(model))
    let requested = try XCTUnwrap(model.requestedReference)
    var applied = false
    let navigation = Task {
      await model.resolveReferenceLocation(requested) { _ in applied = true }
      finishedNavigation.fulfill()
    }
    await fulfillment(of: [reachedInput], timeout: 2)
    model.inputGate.notifyAcceptedContact()
    let later = NotebookPersistenceFenceContract.Blocker()
    defer { later.release() }
    let acceptedLater = Task {
      try await model.performStoreCommand { _ in try later.hold(); return true }
    }
    try await NotebookPersistenceFenceContract.until { later.entered.value == true }
    model.inputGate.unregisterPageFinisher(source: source)
    for completion in completions { completion() }
    await fulfillment(of: [finishedNavigation], timeout: 2)
    XCTAssertFalse(applied)
    XCTAssertNil(model.requestedReference)
    later.release()
    let stored = try await acceptedLater.value
    XCTAssertTrue(stored, "Stopping an obsolete navigation cannot discard later accepted work")
    await navigation.value
  }

  func testNavigationReadsTheMovedAddressAfterAnExistingPencilFinishes() async throws {
    let model = try await makeModel()
    let reference = try coverReference(model), pencil = UUID()
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let itemID = reference.target.id
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    model.requestShow(reference)
    let requested = try XCTUnwrap(model.requestedReference)
    let started = expectation(description: "navigation begins while Pencil owns the page")
    var result: NotebookReferenceLocation?
    let task = Task {
      started.fulfill()
      await model.resolveReferenceLocation(requested) { result = $0; model.completeShow(requested) }
    }
    await fulfillment(of: [started], timeout: 2)
    let center = WorldPoint(x: 91_000, y: -72_000), actor = UUID()
    try await model.performStoreCommand { store in
      _ = try store.moveWorkspaceItem(itemID: itemID, in: boardID, to: center, actor: actor)
    }
    XCTAssertNil(result, "A navigation read cannot apply while accepted Pencil is active")
    model.inputGate.endPencilAction(source: pencil)
    await task.value
    XCTAssertEqual(result, .item(boardID: boardID, id: itemID, center: center, geometry: .notebook))
    XCTAssertEqual(model.highlightedReference?.id, requested.id)
  }

  func testNewPencilCancelsAnOlderShowButItsOwnTailDoesNotCancelANewerShow() async throws {
    let model = try await makeModel(), pencil = UUID()
    let reference = try coverReference(model)
    model.requestShow(reference)
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    XCTAssertNil(model.requestedReference)
    model.requestShow(reference)
    let requested = try XCTUnwrap(model.requestedReference)
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    XCTAssertEqual(model.requestedReference?.id, requested.id)
    model.inputGate.endPencilAction(source: pencil)
    var applied = false
    await model.resolveReferenceLocation(requested) { _ in applied = true; model.completeShow(requested) }
    XCTAssertTrue(applied)
  }

  func testOffscreenDocumentAndBoardSurviveSettlementUntilSQLResolvesTheirOwner() async throws {
    let model = try await makeModel()
    let (boardID, itemID, center) = try await addDistantDocument(model)
    XCTAssertNil(model.boardHierarchy?.board(boardID))
    XCTAssertNil(model.workspace?.item(id: itemID))
    let viewport = try XCTUnwrap(model.presence?.viewport)
    let requested = SessionPresence(boardID: boardID, mode: .document,
      camera: .init(center: center, scale: WorkspaceItemGeometry.document(.a4).fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: itemID, openProgress: 1, selectedItemID: itemID)
    model.updatePresence(requested, settled: true)
    XCTAssertEqual(model.presence, requested, "A bounded cache cannot turn an addressed document into root-board overview")
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.presence, requested)
    XCTAssertNotNil(model.documents[itemID])
    let actor = UUID()
    try await model.performStoreCommand { store in _ = try store.deleteWorkspaceItem(itemID: itemID, actor: actor) }
    await model.reloadExternalChanges()?.value
    XCTAssertNotEqual(model.presence?.focusedItemID, itemID, "An actual SQL deletion still invalidates focus")
    XCTAssertNil(model.documents[itemID])
  }

  func testReturnResolvesAnOffscreenBoardAndConsumesHistoryOnlyWhenApplied() async throws {
    let model = try await makeModel()
    let initial = try XCTUnwrap(model.presence)
    let (boardID, _, center) = try await addDistantDocument(model)
    let saved = SessionPresence(boardID: boardID, mode: .board, camera: .init(center: center, scale: 0.31),
      viewport: initial.viewport, selectedItemID: initial.selectedItemID, notebookPageID: initial.notebookPageID)
    model.updatePresence(saved, settled: true)
    model.requestShow(.init(target: .init(kind: .board, id: initial.boardID), revision: "test"))
    model.completeShow(try XCTUnwrap(model.requestedReference))
    model.updatePresence(initial, settled: true)
    await model.reloadExternalChanges()?.value
    XCTAssertNil(model.boardHierarchy?.board(boardID))
    model.requestReturnToPlace()
    model.cancelRequestedNavigation()
    XCTAssertEqual(model.returnPlaces.last?.presence, saved)
    model.requestReturnToPlace()
    let place = try XCTUnwrap(model.requestedReturn)
    var destination: SessionPresence?
    await model.resolveReturnToPlace(place, viewport: initial.viewport) { resolved, completed in
      destination = resolved
      model.updatePresence(resolved, settled: true)
      completed()
    }
    XCTAssertEqual(destination, saved)
    XCTAssertEqual(model.presence, saved)
    XCTAssertNil(model.requestedReturn)
    XCTAssertTrue(model.returnPlaces.isEmpty)
  }

  func testInterruptedReturnKeepsHistoryAndItsLateAnimationCannotFinishTheNextReturn() async throws {
    let model = try await makeModel()
    let initial = try XCTUnwrap(model.presence)
    model.requestShow(.init(target: .init(kind: .board, id: initial.boardID), revision: "test"))
    model.completeShow(try XCTUnwrap(model.requestedReference))
    model.requestReturnToPlace()
    let first = try XCTUnwrap(model.requestedReturn)
    var finishFirst: (@MainActor () -> Void)?
    await model.resolveReturnToPlace(first, viewport: initial.viewport) { _, completed in finishFirst = completed }
    XCTAssertNotNil(finishFirst)
    XCTAssertEqual(model.returnPlaces.count, 1, "A running animation has not yet restored the saved place")
    model.inputGate.notifyAcceptedContact()
    XCTAssertEqual(model.returnPlaces.count, 1)
    model.requestReturnToPlace()
    let generation = model.navigationGeneration
    finishFirst?()
    XCTAssertEqual(model.navigationGeneration, generation)
    XCTAssertNotNil(model.requestedReturn)
    XCTAssertEqual(model.returnPlaces.count, 1, "A previous animation cannot consume the same history entry's later request")
  }

  func testSQLSceneRejectsAnIncompatibleSemanticModeWithoutChangingItsItemKind() async throws {
    let model = try await makeModel()
    let current = try XCTUnwrap(model.presence)
    let invalidMode = SessionPresence(boardID: current.boardID, mode: .document,
      camera: current.camera, viewport: current.viewport, focusedItemID: current.selectedItemID,
      openProgress: 1, selectedItemID: current.selectedItemID, notebookPageID: current.notebookPageID)
    let state = try await model.performStoreCommand { store in
      try NotebookSceneState.read(store: store, presence: invalidMode, viewport: current.viewport, loadsLiveContent: false)
    }
    XCTAssertEqual(state.workspace.selectedItem.kind, .notebook)
    XCTAssertEqual(state.presence.mode, .board)
    XCTAssertNil(state.presence.focusedItemID)
  }

  private func makeModel() async throws -> NotebookAppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reference-navigation-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    return model
  }

  private func coverReference(_ model: NotebookAppModel) throws -> CollaborationReference {
    .init(target: .init(kind: .cover, id: try XCTUnwrap(model.presence?.selectedItemID),
      boardID: try XCTUnwrap(model.presence?.boardID)), revision: "historical")
  }

  private func addDistantDocument(_ model: NotebookAppModel) async throws -> (UUID, UUID, WorldPoint) {
    try await model.performStoreCommand { store in
      let actor = UUID(), header = try store.workspaceHeader()
      var index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
      let board = try XCTUnwrap(index.createBoard(title: "Distant board", actor: actor))
      XCTAssertTrue(hierarchy.createBoard(board.id, in: header.rootBoardID,
        near: .init(x: 900_000, y: -700_000), actor: actor))
      let document = try XCTUnwrap(index.createDocument(title: "Distant document", actor: actor))
      let center = WorldPoint(x: 90_000, y: -70_000)
      XCTAssertTrue(hierarchy.addItem(document.id, to: board.id, near: center, actor: actor))
      try store.saveDocumentWorkspaceBundle(index: index,
        document: .init(id: document.id, actor: actor, paperSize: .a4,
          blocks: [.markdown(id: "text", source: "Real distant document")]),
        state: .init(id: document.id, actor: actor), board: hierarchy)
      return (board.id, document.id, center)
    }
  }
}
