@testable import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPersistenceQueueTests: XCTestCase {
  private enum StorageUnavailable: Error { case unavailable }

  private final class CompletionProbe<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Value, Error>] = []

    func record(_ result: Result<Value, Error>) {
      lock.lock(); defer { lock.unlock() }
      results.append(result)
    }

    var values: [Result<Value, Error>] {
      lock.lock(); defer { lock.unlock() }
      return results
    }
  }

  @MainActor
  func testDomainRejectionWithoutAnObserverClosesOnlyItsAcceptedSlot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = NotebookPersistenceQueue(store: .init(root: root))
    var commits = 0, reconciliations = 0
    queue.onCommit = { _ in commits += 1 }
    queue.onContentMerged = { reconciliations += 1 }
    queue.enqueue(owner: .pageInk(UUID())) { _ in
      throw CollaborationError("revision_conflict", "The accepted inverse lost its source")
    }
    queue.enqueue(owner: .pageInk(UUID())) { _ in false }
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertNil(queue.failure)
    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(reconciliations, 1, "Reconciliation follows the refusal, even without a UI callback")
  }

  @MainActor
  func testStorageErrorBridgeRetainsTheHeadEvenWhenARejectionObserverExists() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ready = root.appendingPathComponent("ready")
    let queue = NotebookPersistenceQueue(store: .init(root: root))
    var refusals = 0, commits = 0
    queue.onCommit = { _ in commits += 1 }
    queue.enqueue(owner: .pageInk(UUID()), onRejected: { _ in refusals += 1 }) { _ in
      guard FileManager.default.fileExists(atPath: ready.path) else {
        // Dispatcher uses this bridge for corrupt/unavailable stored source.
        throw CollaborationError("storage_error", "The addressed source is unreadable")
      }
      return false
    }
    queue.enqueue(owner: .pageInk(UUID())) { _ in false }
    let blocked = await queue.flush()
    XCTAssertFalse(blocked)
    XCTAssertNotNil(queue.failure)
    XCTAssertEqual(queue.pendingCount, 2)
    XCTAssertEqual(refusals, 0)
    XCTAssertEqual(commits, 0)
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(commits, 2)
    XCTAssertEqual(refusals, 0)
    XCTAssertEqual(queue.pendingCount, 0)
  }

  @MainActor
  func testMutatingCommandRetainsItsCompletionAndFIFOAcrossStorageRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ready = root.appendingPathComponent("ready"), order = root.appendingPathComponent("order")
    let queue = NotebookPersistenceQueue(store: .init(root: root))
    let first = CompletionProbe<Int>(), second = CompletionProbe<Int>(), read = CompletionProbe<Int>()
    queue.enqueueCommand(writesStore: true, { _ in
      guard FileManager.default.fileExists(atPath: ready.path) else { throw StorageUnavailable.unavailable }
      try Data("first".utf8).write(to: order)
      return 7
    }, completion: first.record)
    queue.enqueueCommand(publishesChanges: true, { _ in
      let before = try String(contentsOf: order, encoding: .utf8)
      XCTAssertEqual(before, "first")
      try Data((before + " second").utf8).write(to: order)
      return 8
    }, completion: second.record)
    queue.enqueueCommand({ _ in XCTFail("The blocked reader cannot overtake accepted storage"); return 0 }, completion: read.record)
    let blocked = await queue.flush()
    XCTAssertFalse(blocked)
    XCTAssertEqual(queue.pendingCount, 2, "Only disposable read/save observations leave the failed prefix")
    XCTAssertTrue(first.values.isEmpty)
    XCTAssertTrue(second.values.isEmpty)
    XCTAssertEqual(read.values.count, 1)
    if case .failure(let error) = try XCTUnwrap(read.values.first) { XCTAssertTrue(error is NotebookPersistenceQueue.Failure) }
    else { XCTFail("The failed reader needs an explicit blocked result") }
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(first.values.count, 1)
    XCTAssertEqual(second.values.count, 1)
    XCTAssertEqual(try first.values[0].get(), 7)
    XCTAssertEqual(try second.values[0].get(), 8)
    XCTAssertEqual(try String(contentsOf: order, encoding: .utf8), "first second")
    XCTAssertEqual(queue.pendingCount, 0)
  }

  @MainActor
  func testPublishingSubmitKeepsTheSameWaiterUntilItsStorageRetryFinishes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ready = root.appendingPathComponent("ready")
    let queue = NotebookPersistenceQueue(store: .init(root: root)), result = CompletionProbe<UUID>()
    let blocked = expectation(description: "The accepted writer reports its blocked storage")
    queue.onFailureChange = { error in if error != nil { blocked.fulfill() } }
    let actionID = UUID()
    let accepted = Task {
      do {
        let id = try await queue.submit(publishesChanges: true) { _ in
          guard FileManager.default.fileExists(atPath: ready.path) else { throw StorageUnavailable.unavailable }
          return actionID
        }
        result.record(.success(id))
      } catch { result.record(.failure(error)) }
    }
    await fulfillment(of: [blocked], timeout: 2)
    XCTAssertEqual(queue.pendingCount, 1)
    XCTAssertTrue(result.values.isEmpty, "A retained operation cannot release this caller to mint a new action")
    let failedSave = await queue.flush()
    XCTAssertFalse(failedSave)
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    await accepted.value
    XCTAssertEqual(result.values.count, 1)
    XCTAssertEqual(try result.values[0].get(), actionID)
  }

  @MainActor
  func testTypedEffectKeepsNonpublishingMutationAndReleasesReadObserver() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ready = root.appendingPathComponent("ready")
    let queue = NotebookPersistenceQueue(store: .init(root: root))
    let mutation = CompletionProbe<Int>(), read = CompletionProbe<Int>()
    queue.enqueue { _ in
      guard FileManager.default.fileExists(atPath: ready.path) else { throw StorageUnavailable.unavailable }
      return false
    }
    queue.enqueueCommand(owner: .command(.render), { _ in 3 }, completion: mutation.record)
    queue.enqueueCommand(owner: .command(.read), { _ in 4 }, completion: read.record)
    let blocked = await queue.flush()
    XCTAssertFalse(blocked)
    XCTAssertEqual(queue.pendingCount, 2)
    XCTAssertTrue(mutation.values.isEmpty)
    XCTAssertEqual(read.values.count, 1)
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(try mutation.values[0].get(), 3)
  }

  @MainActor
  func testNonpublishingScriptAdmissionReturnsItsOriginalResultAfterUnknownCommitAndRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = NotebookStore(root: root)
    _ = try peer.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let ready = root.appendingPathComponent("reply-ready")
    let store = NotebookStore(root: root, storageFault: { phase in
      if phase == .afterCommit, !FileManager.default.fileExists(atPath: ready.path) {
        throw StorageUnavailable.unavailable
      }
    })
    let queue = NotebookPersistenceQueue(store: store)
    let executions = CompletionProbe<NotebookScriptRun>(), result = CompletionProbe<NotebookScriptRun>()
    let blocked = expectation(description: "The nonpublishing accepted write retains an unknown commit")
    queue.onFailureChange = { error in if error != nil { blocked.fulfill() } }
    var publications = 0
    queue.onCommit = { _ in publications += 1 }
    let request = NotebookScriptRequest(op: .start, runID: UUID(), code: "return 7")
    let accepted = Task {
      do {
        let run = try await queue.submit(writesStore: true) { store in
          let run = try store.admitScriptRun(request)
          executions.record(.success(run))
          return run
        }
        result.record(.success(run))
      } catch { result.record(.failure(error)) }
    }
    await fulfillment(of: [blocked], timeout: 2)
    XCTAssertEqual(queue.pendingCount, 1)
    XCTAssertTrue(result.values.isEmpty, "A local effect needs its original accepted result before the caller can continue")
    let original = try XCTUnwrap(peer.scriptRun(request.runID))
    XCTAssertEqual(original.state, .queued)
    _ = try peer.setScriptRunState(request.runID, state: .cancelled)
    let changeCursor = try peer.currentChangeCursor(), readCursor = try peer.currentReadCursor()
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    await accepted.value
    XCTAssertEqual(result.values.count, 1)
    XCTAssertEqual(try result.values[0].get(), original,
      "Retry must return the original queued result even after the saved effect advances")
    XCTAssertEqual(executions.values.count, 1, "The witnessed local effect body is never reexecuted")
    XCTAssertEqual(try peer.scriptRun(request.runID)?.state, .cancelled)
    XCTAssertEqual(try peer.currentChangeCursor(), changeCursor)
    XCTAssertEqual(try peer.currentReadCursor(), readCursor)
    XCTAssertEqual(publications, 0, "Local bookkeeping does not notify content publication")
  }

  @MainActor
  func testCancellingPreparedResultWaitDoesNotDiscardItsResultOrDependentWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let ready = root.appendingPathComponent("ready")
    let queue = NotebookPersistenceQueue(store: .init(root: root))
    let accepted = queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> Int in
      { _ in
        guard FileManager.default.fileExists(atPath: ready.path) else { throw StorageUnavailable.unavailable }
        return 11
      }
    }, publishesChanges: true)
    let blocked = await queue.flush()
    XCTAssertFalse(blocked)
    accepted.cancel()
    let dependent = queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> Int in
      let exactPredecessor = try await accepted.value
      return { _ in exactPredecessor + 1 }
    }, publishesChanges: true)
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    let first = try await accepted.value, second = try await dependent.value
    XCTAssertEqual(first, 11)
    XCTAssertEqual(second, 12)
    XCTAssertEqual(queue.pendingCount, 0)
  }

  @MainActor
  func testDeterministicLimitRefusalDoesNotBecomeAnInfiniteStorageRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = NotebookPersistenceQueue(store: .init(root: root))
    let refused = CompletionProbe<Int>(), independent = CompletionProbe<Int>()
    queue.enqueueCommand(publishesChanges: true, { _ in
      throw CollaborationError("resource_limit", "The complete reorder exceeds its declared allowance")
    }, completion: refused.record)
    queue.enqueueCommand(publishesChanges: true, { _ in 1 }, completion: independent.record)
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertNil(queue.failure)
    if case .failure(let error) = try XCTUnwrap(refused.values.first) {
      XCTAssertEqual((error as? CollaborationError)?.code, "resource_limit")
    } else { XCTFail("The limit refusal needs a recoverable terminal result") }
    XCTAssertEqual(try independent.values[0].get(), 1)
  }

  @MainActor
  func testTypedCompletionAndItsCreditStayPendingUntilTheOuterCommitOutcomeIsKnown() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let peer=NotebookStore(root:root), actor=UUID()
    _ = try peer.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let pageID=try XCTUnwrap(peer.loadIndex().selectedPageID)
    var page=try peer.loadPage(pageID)
    let inserted=page.replaceElements([
      .init(id:"program",kind:.web,frame:.init(x:0,y:0,width:100,height:100),
        source:"Original",html:"<button>Run</button>",state:.number(0))
    ],actor:actor)
    XCTAssertTrue(inserted)
    try peer.savePage(page)
    let basis=try XCTUnwrap(page.programStateBasis("program"))
    let ready=root.appendingPathComponent("reply-ready")
    let store=NotebookStore(root:root,storageFault:{ phase in
      if case .afterCommit=phase,!FileManager.default.fileExists(atPath:ready.path) { throw StorageUnavailable.unavailable }
    })
    let queue=NotebookPersistenceQueue(store:store),result=CompletionProbe<NotebookPageProgramStateReceipt>()
    let cost=NotebookPersistenceAdmission.Cost(payloadBytes:128,completionBytes:128)
    let reservation=try XCTUnwrap(queue.reserveWrite(cost))
    try queue.enqueueCommand(owner:.documentState(pageID),reservation:reservation,cost:cost,{ store in
      try store.commitPageProgramState(pageID:pageID,elementID:"program",state:.number(1),basis:basis,actor:actor)
    },completion:result.record)
    let blocked=await queue.flush()
    XCTAssertFalse(blocked)
    XCTAssertTrue(result.values.isEmpty,"Returning from a nested SQL write cannot acknowledge its unconfirmed outer COMMIT")
    XCTAssertEqual(queue.reservedWriteBytes,cost.bytes)
    let original=try XCTUnwrap(peer.loadPage(pageID).programStateBasis("program"))
    _ = try peer.commitPageProgramState(pageID:pageID,elementID:"program",state:.number(2),basis:basis,actor:UUID())
    let changeCursor=try peer.currentChangeCursor(),readCursor=try peer.currentReadCursor()
    try Data().write(to:ready)
    queue.retry()
    let saved=await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(result.values.count,1)
    let receipt=try result.values[0].get()
    XCTAssertEqual(receipt.basis,original)
    XCTAssertTrue(receipt.changed,"Retry returns the original publication receipt")
    XCTAssertEqual(try peer.loadPage(pageID).element(id:"program")?.state,.number(2),
      "The same accepted state 1 must not acquire a fresh dot over peer state 2")
    XCTAssertEqual(try peer.currentChangeCursor(),changeCursor)
    XCTAssertEqual(try peer.currentReadCursor(),readCursor,"Witness retirement is local bookkeeping")
    XCTAssertEqual(queue.reservedWriteBytes,0)
  }

  @MainActor
  func testPreparedCommandKeepsOneAcceptedInstanceAndExactResultAfterUnknownCommitAndPeer() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let peer=NotebookStore(root:root)
    _ = try peer.initializeWorkspace(actor:UUID(),pageSize:.init(width:834,height:1194))
    let ready=root.appendingPathComponent("reply-ready")
    let store=NotebookStore(root:root,storageFault:{ phase in
      if phase == .afterCommit,!FileManager.default.fileExists(atPath:ready.path) { throw StorageUnavailable.unavailable }
    })
    let queue=NotebookPersistenceQueue(store:store)
    let accepted=queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> Int in
      { store in
        try store.publishRecords(writes:["prepared-state.json":.object(["state":.number(1)])])
        return 1
      }
    },publishesChanges:true)
    let blocked=await queue.flush()
    XCTAssertFalse(blocked)
    accepted.cancel()
    try peer.publishRecords(writes:["prepared-state.json":.object(["state":.number(2)])])
    let cursor=try peer.currentChangeCursor()
    try Data().write(to:ready)
    queue.retry()
    let saved=await queue.flush()
    XCTAssertTrue(saved)
    let exact=try await accepted.value
    XCTAssertEqual(exact,1)
    XCTAssertEqual(try peer.storedValue("prepared-state.json")?["state"],.number(2))
    XCTAssertEqual(try peer.currentChangeCursor(),cursor)
  }

  @MainActor
  func testCoalescingAndDiscardCannotReplaceAnAlreadyAttemptedAcceptedHead() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let peer=NotebookStore(root:root)
    _ = try peer.initializeWorkspace(actor:UUID(),pageSize:.init(width:834,height:1194))
    let ready=root.appendingPathComponent("reply-ready")
    let store=NotebookStore(root:root,storageFault:{ phase in
      if phase == .afterCommit,!FileManager.default.fileExists(atPath:ready.path) { throw StorageUnavailable.unavailable }
    })
    let queue=NotebookPersistenceQueue(store:store),owner=NotebookPersistenceQueue.Owner.fileDraft("isolated")
    queue.enqueue(owner:owner) { store in
      try store.publishRecords(writes:["draft-state.json":.object(["state":.number(1)])])
      return false
    }
    let blocked=await queue.flush()
    XCTAssertFalse(blocked)
    queue.enqueue(owner:owner) { store in
      try store.publishRecords(writes:["draft-state.json":.object(["state":.number(3)])])
      return false
    }
    XCTAssertEqual(queue.pendingCount,2,"A newer provisional value must keep the unknown accepted head")
    queue.discardPending(owner:owner)
    XCTAssertEqual(queue.pendingCount,1,"Discard retires the unstarted draft, retaining the attempted accepted identity")
    try peer.publishRecords(writes:["draft-state.json":.object(["state":.number(2)])])
    let cursor=try peer.currentChangeCursor()
    try Data().write(to:ready)
    queue.retry()
    let saved=await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(try peer.storedValue("draft-state.json")?["state"],.number(2))
    XCTAssertEqual(try peer.currentChangeCursor(),cursor)
  }
}
