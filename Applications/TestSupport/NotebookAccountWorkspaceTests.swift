import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookAccountWorkspaceTests: XCTestCase {
  func testOpeningAccountSpaceWaitsForItsRealMaterialInsteadOfCreatingAnotherNotebook() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("account-workspace-" + UUID().uuidString)
    let suite = "Notebook.tests.account-workspace." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
    let source = NotebookStore(root: base.appendingPathComponent("source")), actor = UUID()
    let notebook = UUID(), page = UUID()
    let header = try source.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize,
      initialNotebookID: notebook, initialPageID: page)
    let receiver = NotebookStore(root: base.appendingPathComponent("receiver"))
    try receiver.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let model = NotebookAppModel(store: receiver, startsNearbySync: false, preferences: preferences,
      requiresExistingAccountContent: true)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertTrue(model.awaitingAccountContent)
    XCTAssertNil(model.workspaceHeader)
    XCTAssertEqual(model.admittedWorkspaceID, header.workspaceID)
    XCTAssertFalse(try receiver.hasWorkspaceContent())
    XCTAssertEqual(try receiver.currentChangeCursor(), 0)
    try await NotebookPeerFixture.deliver(from: source, to: model, peerID: actor)
    for _ in 0..<250 where model.loadState != .ready { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(model.loadState, .ready)
    XCTAssertFalse(model.awaitingAccountContent)
    XCTAssertEqual(model.workspaceHeader?.workspaceID, header.workspaceID)
    XCTAssertEqual(try receiver.readItemHeaders(limit: 10).map(\.id), [notebook])
    XCTAssertNil(try receiver.readItemHeader(NotebookAppModel.initialNotebookID))
    let saved = await model.shutdown()
    XCTAssertTrue(saved)
  }

  func testWaitingForAccountMaterialCanShutDownWithoutHangingOrCreatingContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-wait-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepareEmptyWorkspace(workspaceID: UUID())
    let model = NotebookAppModel(store: store, startsNearbySync: false, requiresExistingAccountContent: true)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertTrue(model.awaitingAccountContent)
    let saved = await model.shutdown()
    XCTAssertTrue(saved)
    XCTAssertFalse(try store.hasWorkspaceContent())
  }

  func testAcceptedLocalWorkCancelsAutomaticSelectionAndKeepsInputOpen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-local-input-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false,
      opensDefaultAccountWorkspace: true)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let initiallyEmpty = await model.mayAutomaticallySwitchWorkspace()
    XCTAssertTrue(initiallyEmpty)
    let created = try XCTUnwrap(model.createNotebook(at: .zero))
    let accepted = await model.prepareAutomaticWorkspaceSwitch()
    XCTAssertNil(accepted)
    XCTAssertEqual(model.shutdownPhase, .running)
    XCTAssertNotNil(try model.store.readItemHeader(created))
    let saved = await model.shutdown()
    XCTAssertTrue(saved)
  }

  func testContactDuringAutomaticPreparationCancelsOnlyItsOwnTransition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-transition-contact-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false,
      opensDefaultAccountWorkspace: true)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let prepared = await model.prepareAutomaticWorkspaceSwitch()
    let original = try XCTUnwrap(prepared)
    XCTAssertEqual(model.shutdownPhase, .running)
    XCTAssertTrue(model.inputGate.permitsNewContact)
    XCTAssertFalse(model.permitsBackgroundPreparation, "One prepared transition revokes derived admission while keeping source input open")
    model.inputGate.notifyAcceptedContact()
    XCTAssertEqual(try model.store.currentChangeCursor(), original.cursor)
    XCTAssertFalse(try model.freezeAutomaticWorkspaceSwitch(original))
    model.rollbackAutomaticWorkspaceSwitch(original)
    model.rollbackAutomaticWorkspaceSwitch(original)
    XCTAssertTrue(model.permitsExternalWork)
    XCTAssertTrue(model.permitsBackgroundPreparation)
    let nextPreparation = await model.prepareAutomaticWorkspaceSwitch()
    let next = try XCTUnwrap(nextPreparation)
    XCTAssertTrue(try model.freezeAutomaticWorkspaceSwitch(next))
    XCTAssertFalse(model.permitsExternalWork)
    XCTAssertFalse(model.inputGate.permitsNewContact)
    model.rollbackAutomaticWorkspaceSwitch(original)
    XCTAssertFalse(model.permitsExternalWork)
    XCTAssertFalse(model.permitsBackgroundPreparation, "An obsolete rollback cannot resume another transition's derived producers")
    model.rollbackAutomaticWorkspaceSwitch(next)
    XCTAssertTrue(model.permitsExternalWork)
    XCTAssertTrue(model.permitsBackgroundPreparation)
    XCTAssertTrue(model.inputGate.permitsNewContact)
    XCTAssertEqual(model.shutdownPhase, .running)
    let created = try XCTUnwrap(model.createNotebook(at: .zero))
    let saved = await model.shutdown()
    XCTAssertTrue(saved)
    XCTAssertNotNil(try model.store.readItemHeader(created))
  }

  func testReadFencePreservesAutomaticCutButAcceptedNoOpMutationCancelsIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-transition-cut-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false,
      opensDefaultAccountWorkspace: true, persistenceQueue: queue)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let preparation = await model.prepareAutomaticWorkspaceSwitch()
    let readCut = try XCTUnwrap(preparation)
    let observed = try await queue.submit { try $0.currentChangeCursor() }
    let readFinished = await queue.flush()
    XCTAssertTrue(readFinished); XCTAssertEqual(observed, readCut.cursor)
    XCTAssertEqual(queue.acceptedMutationGeneration, readCut.mutationGeneration)
    let reading = expectation(description: "A later pure read borrows the drained source without becoming an accepted write")
    let releaseRead = DispatchSemaphore(value: 0)
    defer { releaseRead.signal() }
    let observer = Task {
      try await queue.submit { store in
        try store.readTransaction { _ in
          let cursor = try store.currentChangeCursor()
          reading.fulfill()
          guard releaseRead.wait(timeout: .now() + 5) == .success else { throw NotebookTransportError.storageUnavailable }
          return cursor
        }
      }
    }
    await fulfillment(of: [reading], timeout: 3)
    XCTAssertGreaterThan(queue.pendingCount, 0)
    XCTAssertEqual(queue.acceptedMutationGeneration, readCut.mutationGeneration)
    let frozeWithObserver = try model.freezeAutomaticWorkspaceSwitch(readCut)
    releaseRead.signal()
    let observedAfterCut = try await observer.value
    XCTAssertTrue(frozeWithObserver, "The source writer prefix is drained even while a later read remains active")
    XCTAssertEqual(observedAfterCut, readCut.cursor)
    model.rollbackAutomaticWorkspaceSwitch(readCut)
    let nextPreparation = await model.prepareAutomaticWorkspaceSwitch()
    let mutationCut = try XCTUnwrap(nextPreparation)
    _ = try await queue.submit(writesStore: true) { try $0.currentChangeCursor() }
    let mutationFinished = await queue.flush()
    XCTAssertTrue(mutationFinished)
    XCTAssertEqual(try model.store.currentChangeCursor(), mutationCut.cursor)
    XCTAssertGreaterThan(queue.acceptedMutationGeneration, mutationCut.mutationGeneration)
    XCTAssertFalse(try model.freezeAutomaticWorkspaceSwitch(mutationCut))
    model.rollbackAutomaticWorkspaceSwitch(mutationCut)
    XCTAssertEqual(model.shutdownPhase, .running)
    XCTAssertTrue(model.inputGate.permitsNewContact)
    let saved = await model.shutdown()
    XCTAssertTrue(saved)
  }

  #if os(macOS) && DEBUG
  func testJoinedPageVisionWorkerCannotAdmitAfterAutomaticCutAndSameOwnerResumesOnRollback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-transition-page-worker-" + UUID().uuidString)
    let store = NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false,
      opensDefaultAccountWorkspace: true, persistenceQueue: queue)
    var heldWorker: CheckedContinuation<Void, Never>?
    addTeardownBlock { @MainActor in
      heldWorker?.resume(); heldWorker = nil
      CurrentViewPreviewWriter.onPageVisionPrepared = nil
      let saved = await model.shutdown()
      XCTAssertTrue(saved)
      try FileManager.default.removeItem(at: root)
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let sourceID = try XCTUnwrap(model.admittedWorkspaceID)
    let pageID = try XCTUnwrap(model.workspace?.selectedPageID), page = try store.loadPage(pageID)
    // This exact request stays with the held caller instead of entering the
    // background request directory. The real page worker still reads/renders
    // its canonical source and prepares the ordinary typed result.
    let request = TargetRenderRequest(id: UUID(), target: .init(kind: .page, id: pageID),
      sourceRevision: try NotebookStore.pageVisionSourceRevision(page), region: nil, worldOrigin: nil,
      pageIndex: 0, pageVisionRevision: page.drawingStamp.revision, createdAt: Date())
    let workerPrepared = expectation(description: "The actual page worker has joined before derived writer admission")
    CurrentViewPreviewWriter.onPageVisionPrepared = { id in
      guard id == request.id else { return }
      await withCheckedContinuation { continuation in
        heldWorker = continuation; workerPrepared.fulfill()
      }
    }
    let producer = Task { @MainActor () -> Bool in
      do { try await CurrentViewPreviewWriter.writeTarget(request, model: model); return false }
      catch { return true }
    }
    await fulfillment(of: [workerPrepared], timeout: 3)
    guard heldWorker != nil else { _ = await producer.value; XCTFail("The actual page output must reach the held boundary"); return }
    let preparation = await model.prepareAutomaticWorkspaceSwitch()
    let cut = try XCTUnwrap(preparation)
    XCTAssertFalse(model.permitsBackgroundPreparation)
    XCTAssertTrue(model.permitsExternalWork && model.inputGate.permitsNewContact)
    let release = heldWorker; heldWorker = nil; release?.resume()
    let refused = await producer.value
    XCTAssertTrue(refused, "A late, uncancelled producer checks source admission before reserving the FIFO")
    XCTAssertEqual(queue.acceptedMutationGeneration, cut.mutationGeneration)
    XCTAssertNil(try store.loadTargetRenderReceipt(request.id))
    XCTAssertTrue(try model.freezeAutomaticWorkspaceSwitch(cut))
    model.rollbackAutomaticWorkspaceSwitch(cut)
    XCTAssertTrue(model.permitsBackgroundPreparation)
    XCTAssertEqual(model.admittedWorkspaceID, sourceID)
    XCTAssertEqual(model.shutdownPhase, .running)
    CurrentViewPreviewWriter.onPageVisionPrepared = nil
    try await CurrentViewPreviewWriter.writeTarget(request, model: model)
    let resumed = try XCTUnwrap(try store.loadTargetRenderReceipt(request.id))
    XCTAssertEqual(resumed.request, request)
    XCTAssertEqual(resumed.status, "ready")
    XCTAssertGreaterThan(queue.acceptedMutationGeneration, cut.mutationGeneration)
    let accepted = try XCTUnwrap(model.createNotebook(at: .zero))
    let sourceSaved = await model.finishPendingInteraction(boundary: .acceptedInput)
    XCTAssertTrue(sourceSaved)
    XCTAssertNotNil(try store.readItemHeader(accepted))
    XCTAssertEqual(model.admittedWorkspaceID, sourceID)
  }
  #endif
}
