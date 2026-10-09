import NotebookCore
import XCTest
@testable import Notebook

final class NotebookDocumentSourcePersistenceTests: XCTestCase {
  @MainActor
  func testOpeningAnUnloadedDocumentReadsItsContentWithoutAnExternalRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    var ids: [UUID] = []
    for _ in 0..<10 {
      let createdDocumentResult = await model.createDocument(at: .zero)
      ids.append(try XCTUnwrap(createdDocumentResult))
    }
    model.selectItem(notebook)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    let id = try XCTUnwrap(ids.first { model.documents[$0] == nil },
      "The bounded working set must leave some document sources unloaded")
    let camera = try XCTUnwrap(model.presence?.camera)
    let expected = try model.store.loadDocument(id)
    let state = try model.store.loadDocumentState(id)

    model.selectItem(id)
    XCTAssertNil(model.documents[id], "Selecting a closed cover does not request its body")
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    let deadline = ContinuousClock.now + .seconds(2)
    while model.documents[id] == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.documents[id], expected, "Opening reads the addressed source, not a later sync event")
    XCTAssertEqual(model.documentStates[id], state)
    XCTAssertEqual(Set(model.documents.keys), [id], "Opening does not read neighbouring books before the chosen document")
    XCTAssertEqual(model.presence?.selectedItemID, id)
    XCTAssertEqual(model.presence?.camera, camera, "Content readiness cannot reposition the paper")
  }

  @MainActor
  func testAcceptedSourceUpdatesOnlyItsProgramAndKeepsHumanSelection() async throws {
    var capturedQueue: NotebookPersistenceQueue?
    let (model, id) = try await makeModel(observeQueue: { capturedQueue = $0 })
    let queue = try XCTUnwrap(capturedQueue)
    let before = try XCTUnwrap(model.documents[id]), state = try model.store.loadDocumentState(id)
    let notebookID = try XCTUnwrap(model.workspace?.items.first { $0.kind == .notebook }?.id)
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html", baseSource: before.files.first { $0.id == "a-html" }!.source,
      baseVersion: before.fileVersion(fileID: "a-html"), source: "<button>Accepted human text</button>", sequence: 1)
    model.saveDocumentDraft(.init(edit: edit))
    let draftSaved = await model.finishPendingPersistence(); XCTAssertTrue(draftSaved, model.persistenceFailure ?? "")
    XCTAssertEqual(queue.admittedOperationCount, 0)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    var firstFinished = false
    let operation = Task { defer { firstFinished = true }; return try await model.commitDocumentSource(edit: edit) }
    defer { operation.cancel() }
    let firstDeadline = ContinuousClock.now + .seconds(5)
    while (queue.admittedOperationCount != 1 || queue.reservedContactCount != 0),
      !firstFinished, .now < firstDeadline { await Task.yield() }
    XCTAssertEqual(queue.admittedOperationCount, 1)
    XCTAssertEqual(queue.reservedContactCount, 0, "The first completed plan has transferred to the existing FIFO")
    XCTAssertFalse(firstFinished, "The actual SQLite writer remains held")
    let secondEdit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "b",
      baseSource: try XCTUnwrap(before.files.first { $0.id == "b" }).source,
      baseVersion: before.fileVersion(fileID: "b"), source: "Independent queued human text", sequence: 1)
    var secondFinished = false
    let secondOperation = Task {
      defer { secondFinished = true }
      return try await model.commitDocumentSource(edit: secondEdit)
    }
    defer { secondOperation.cancel() }
    let secondDeadline = ContinuousClock.now + .seconds(5)
    while (queue.admittedOperationCount != 2 || queue.reservedContactCount != 0),
      !secondFinished, .now < secondDeadline { await Task.yield() }
    XCTAssertEqual(queue.admittedOperationCount, 2,
      "A small accepted tail cannot occupy the next source preparation slot")
    XCTAssertEqual(queue.reservedContactCount, 0)
    XCTAssertFalse(firstFinished); XCTAssertFalse(secondFinished)
    // The source command retains its explicit document even if human
    // navigation happens before its queued SQLite writer is admitted.
    model.selectItem(notebookID)
    try lock.release()
    queue.retry()
    let status = try await operation.value
    XCTAssertEqual(status, .committed)
    let secondStatus = try await secondOperation.value
    XCTAssertEqual(secondStatus, .committed)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let stored = try model.store.loadDocument(id)
    XCTAssertEqual(stored.files.first { $0.id == "a-html" }!.source, edit.source)
    XCTAssertEqual(stored.files.first { $0.id == "a-css" }, before.files.first { $0.id == "a-css" })
    XCTAssertEqual(stored.files.first { $0.id == "b" }!.source, secondEdit.source)
    XCTAssertEqual(try model.store.loadDocumentState(id), state)
    XCTAssertEqual(model.presence?.selectedItemID, notebookID)
    XCTAssertFalse(model.documentEditingSessions.contains { $0.id == edit.sessionID })
    XCTAssertFalse(model.documentEditingSessions.contains { $0.id == secondEdit.sessionID })
    if let retained = model.documents[id] { XCTAssertEqual(retained.files, stored.files) }
  }

  @MainActor
  func testSourceReceiptReachesTheVisibleModelBeforeTheEditorCloses() async throws {
    let (model, id) = try await makeModel()
    let before = try XCTUnwrap(model.documents[id])
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html", baseSource: before.files.first { $0.id == "a-html" }!.source,
      baseVersion: before.fileVersion(fileID: "a-html"), source: "<p>Visible source</p>", sequence: 1)
    let status = try await model.commitDocumentSource(edit: edit)
    XCTAssertEqual(status, .committed)
    let shown = try XCTUnwrap(model.documents[id])
    XCTAssertEqual(shown.files.first { $0.id == "a-html" }!.source, edit.source)
    XCTAssertEqual(shown, try model.store.loadDocument(id))
    let settled = await model.finishPendingPersistence()
    XCTAssertTrue(settled, model.persistenceFailure ?? "")
    let cursor = try model.store.currentChangeCursor()
    let repeated = try await model.commitDocumentSource(edit: edit)
    XCTAssertEqual(repeated, .committed)
    XCTAssertEqual(model.documents[id], shown)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    let state = try model.store.loadDocumentState(id)
    model.undoLastSurfaceAction()
    let undone = await model.finishPendingPersistence()
    XCTAssertTrue(undone, model.persistenceFailure ?? "")
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(try model.store.loadDocument(id).files, before.files)
    XCTAssertEqual(model.documents[id]?.files, before.files)
    XCTAssertEqual(try model.store.loadDocumentState(id), state,
      "Undo of a source field does not undo a live program's independent state")
  }

  @MainActor
  func testSaveJoinsItsReleasedHumanContactWithoutBypassingTheCommonInputBarrier() async throws {
    let (model, id) = try await makeModel()
    let before = try XCTUnwrap(model.documents[id]), contact = UUID()
    model.inputGate.beginContact(source: contact)
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html", baseSource: before.files.first { $0.id == "a-html" }!.source,
      baseVersion: before.fileVersion(fileID: "a-html"), source: "Saved after lifting", sequence: 1)
    let saving = Task { try await model.commitDocumentSource(edit: edit) }
    await Task.yield()
    XCTAssertEqual(try model.store.loadDocument(id).files, before.files)
    model.inputGate.endContact(source: contact)
    let status = try await saving.value
    XCTAssertEqual(status, .committed)
    XCTAssertEqual(try model.store.loadDocument(id).files.first { $0.id == "a-html" }!.source, edit.source)
  }

  @MainActor
  func testShutdownRejectsALateEditorWithoutPublishingADraftOrSource() async throws {
    let (model, id) = try await makeModel()
    let document = try XCTUnwrap(model.documents[id])
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped, model.persistenceFailure ?? "")
    let cursor = try model.store.currentChangeCursor()
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html", baseSource: document.files.first { $0.id == "a-html" }!.source,
      baseVersion: document.fileVersion(fileID: "a-html"), source: "Not admitted", sequence: 1)
    do {
      _ = try await model.commitDocumentSource(edit: edit)
      XCTFail("A closed Notebook admitted new source input")
    } catch is NotebookPersistenceQueue.Failure { }
    XCTAssertEqual(try model.store.loadDocument(id), document)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
  }

  #if DEBUG
  @MainActor
  func testSourcePreparationAdmitsRealPencilAndCancellationJoinsTheWorker() async throws {
    var capturedQueue: NotebookPersistenceQueue?
    let (model, id) = try await makeModel(observeQueue: { capturedQueue = $0 })
    let queue = try XCTUnwrap(capturedQueue)
    let settled = await model.finishPendingPersistence(); XCTAssertTrue(settled, model.persistenceFailure ?? "")
    let before = try XCTUnwrap(model.documents[id])
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html",
      baseSource: try XCTUnwrap(before.files.first { $0.id == "a-html" }).source,
      baseVersion: before.fileVersion(fileID: "a-html"), source: String(repeating: "x", count: 4 * 1_048_576), sequence: 1)
    let initial = try PreparedDocumentSourceEdit.cost(for: edit)
    let entered = expectation(description: "The actual utility source worker has started")
    let gate = SourceWorkerGate(entered: entered)
    NotebookDocumentSourceWriteOwner.onPreparationWorker = { await gate.hold() }
    defer { NotebookDocumentSourceWriteOwner.onPreparationWorker = nil; gate.release() }
    var sourceFinished = false
    let saving = Task { () throws -> DocumentSourceCommitResult.Status in
      defer { sourceFinished = true }
      return try await model.commitDocumentSource(edit: edit)
    }
    defer { saving.cancel() }
    await fulfillment(of: [entered], timeout: 5)
    XCTAssertEqual(queue.pendingCount, 0, "Pure source preparation cannot occupy the writer's head")
    XCTAssertEqual(queue.reservedWriteBytes, initial.bytes)
    XCTAssertEqual(queue.reservedContactCount, 1)
    let secondEdit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: edit.fileID,
      baseSource: edit.baseSource, baseVersion: edit.baseVersion, source: edit.source, sequence: 1)
    let refused = expectation(description: "A second editor cannot reserve another source preparation")
    let secondSaving = Task {
      do { _ = try await model.commitDocumentSource(edit: secondEdit); XCTFail("A second Save entered the preparation window") }
      catch is NotebookPersistenceQueue.Failure { }
      catch { XCTFail("Unexpected second Save refusal: \(error)") }
      refused.fulfill()
    }
    defer { secondSaving.cancel() }
    await fulfillment(of: [refused], timeout: 3)
    XCTAssertEqual(gate.suspendedWorkerCount, 1)
    XCTAssertEqual(queue.pendingCount, 0); XCTAssertEqual(queue.reservedWriteBytes, initial.bytes)
    XCTAssertEqual(queue.reservedContactCount, 1)

    let contact = UUID(), strokeID = UUID()
    let surface = SurfaceID.board(try XCTUnwrap(model.workspace?.rootBoardID))
    XCTAssertTrue(model.inputGate.beginPencilAction(source: contact))
    defer { model.inputGate.endPencilAction(source: contact); model.releaseSpatialDrawingReservation(strokeID) }
    XCTAssertTrue(model.reserveSpatialDrawingAction(strokeID),
      "A legal 4 MiB source worker must leave room for the real 192 MiB Pencil reservation")
    XCTAssertEqual(queue.reservedWriteBytes, initial.bytes + NotebookInkWriteAllowance.maximumCost.bytes)
    let spans: [SpatialInkSpan] = [.init(surface: surface, samples: [.init(point: .init(x: 10, y: 20),
      worldPoint: .init(x: 10, y: 20), timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])]
    let action = try XCTUnwrap(model.appendSpatialInk(tool: .pen, color: .black, spans: spans, id: strokeID))
    model.inputGate.endPencilAction(source: contact)
    let inkSaved = await model.finishPendingPersistence(); XCTAssertTrue(inkSaved, model.persistenceFailure ?? "")
    XCTAssertEqual(try model.store.readSpatialInk(surfaces: [surface]).actions.first { $0.id == action.id }, action,
      "Competing real ink must commit before the source worker is released")
    XCTAssertFalse(sourceFinished)
    XCTAssertEqual(queue.reservedWriteBytes, initial.bytes)

    saving.cancel()
    await Task.yield()
    XCTAssertFalse(sourceFinished, "Logical cancellation cannot complete a still-held physical worker")
    XCTAssertEqual(queue.reservedWriteBytes, initial.bytes)
    XCTAssertEqual(queue.reservedContactCount, 1)
    gate.release()
    do { _ = try await saving.value; XCTFail("A cancelled source preparation was accepted") }
    catch is CancellationError { }
    XCTAssertTrue(sourceFinished)
    XCTAssertEqual(queue.reservedWriteBytes, 0); XCTAssertEqual(queue.admittedOperationCount, 0)
    XCTAssertEqual(try model.store.loadDocument(id).files, before.files)
    XCTAssertFalse(try model.store.documentEditingSessions().contains { $0.id == edit.sessionID })
  }

  @MainActor
  func testShutdownJoinsSourcePreparationWithoutAcceptingItsLateResult() async throws {
    var capturedQueue: NotebookPersistenceQueue?
    let (model, id) = try await makeModel(observeQueue: { capturedQueue = $0 })
    let queue = try XCTUnwrap(capturedQueue)
    let settled = await model.finishPendingPersistence(); XCTAssertTrue(settled, model.persistenceFailure ?? "")
    let before = try XCTUnwrap(model.documents[id])
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: id, fileID: "a-html",
      baseSource: try XCTUnwrap(before.files.first { $0.id == "a-html" }).source,
      baseVersion: before.fileVersion(fileID: "a-html"), source: "Not accepted after closing", sequence: 1)
    let initial = try PreparedDocumentSourceEdit.cost(for: edit)
    let entered = expectation(description: "The source worker is physically held before shutdown")
    let gate = SourceWorkerGate(entered: entered)
    NotebookDocumentSourceWriteOwner.onPreparationWorker = { await gate.hold() }
    defer { NotebookDocumentSourceWriteOwner.onPreparationWorker = nil; gate.release() }
    let saving = Task { try await model.commitDocumentSource(edit: edit) }
    defer { saving.cancel() }
    await fulfillment(of: [entered], timeout: 5)
    let cursor = try model.store.currentChangeCursor()
    var shutdownFinished = false
    let stopping = Task { defer { shutdownFinished = true }; return await model.shutdown() }
    let deadline = ContinuousClock.now + .seconds(5)
    while model.shutdownPhase == .running, .now < deadline { await Task.yield() }
    XCTAssertEqual(model.shutdownPhase, .closing)
    XCTAssertFalse(shutdownFinished, "Shutdown must join the actual source worker before retiring its owner")
    XCTAssertEqual(queue.pendingCount, 0); XCTAssertEqual(queue.reservedWriteBytes, initial.bytes)
    gate.release()
    do { _ = try await saving.value; XCTFail("Shutdown admitted a source prepared for the closing model") }
    catch is CancellationError { }
    let stopped = await stopping.value; XCTAssertTrue(stopped, model.persistenceFailure ?? "")
    XCTAssertTrue(shutdownFinished)
    XCTAssertEqual(queue.reservedWriteBytes, 0); XCTAssertEqual(queue.admittedOperationCount, 0)
    XCTAssertEqual(try model.store.loadDocument(id), before)
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertTrue(try model.store.documentEditingSessions().isEmpty)
  }

  @MainActor
  private final class SourceWorkerGate {
    private let entered: XCTestExpectation
    private var released = false, started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var suspendedWorkerCount: Int { waiters.count }
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() async {
      await withCheckedContinuation { continuation in
        if !started { started = true; entered.fulfill() }
        if released { continuation.resume() } else { waiters.append(continuation) }
      }
    }
    func release() {
      released = true
      let current = waiters; waiters = []
      for waiter in current { waiter.resume() }
    }
  }
  #endif

  @MainActor
  private func makeModel(observeQueue: (@MainActor (NotebookPersistenceQueue) -> Void)? = nil) async throws -> (NotebookAppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    observeQueue?(queue)
    let model = NotebookAppModel(store: store, startsNearbySync: false, persistenceQueue: queue)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let idResult = await model.createDocument(at: .zero)
    let id = try XCTUnwrap(idResult)
    let created = await model.finishPendingPersistence()
    XCTAssertTrue(created, model.persistenceFailure ?? "")
    var document = try model.store.loadDocument(id)
    XCTAssertTrue(document.replaceContent(files: DocumentTestFiles.document(contents: [
      .program(id: "a", html: "<button>A</button>", css: "button{color:blue}", initialState: .number(3)),
      .tex(id: "b", source: "Independent human program")]).files, actor: model.actorID))
    _ = try model.store.saveMergedDocument(document)
    await model.reloadExternalChanges()?.value
    let ready = await model.finishPendingPersistence()
    XCTAssertTrue(ready, model.persistenceFailure ?? "")
    let presence = try XCTUnwrap(model.presence)
    model.selectItem(id)
    model.updatePresence(.init(boardID: presence.boardID, mode: .document,
      camera: presence.camera, viewport: presence.viewport, focusedItemID: id,
      openProgress: 1, selectedItemID: id), settled: true)
    await model.prepareDocumentOpening(id, pageIndex: 0)?.value
    XCTAssertEqual(model.documents[id], document)
    return (model, id)
  }
}
