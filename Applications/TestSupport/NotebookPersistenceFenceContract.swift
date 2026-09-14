import Foundation
import NotebookCore
#if !NOTEBOOK_QUEUE_STANDALONE
@testable import Notebook
#endif

/// The same controlled FIFO cases run as native XCTest and a CPU-only executable.
/// Blocking happens only in synthetic store operations, never on MainActor.
@MainActor enum NotebookPersistenceFenceContract {
  enum Failure: Error { case contract(String), deadline }
  final class Signal<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
    var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
  }
  final class Blocker: @unchecked Sendable {
    let entered = Signal<Bool>()
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() throws {
      entered.set(true)
      guard semaphore.wait(timeout: .now() + 5) == .success else { throw Failure.deadline }
    }
    func release() { semaphore.signal() }
  }
  static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure.contract(message) }
  }
  static func until(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
      guard ContinuousClock.now < deadline else { throw Failure.deadline }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
  static func fixture(_ body: (NotebookStore, NotebookPersistenceQueue, URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-writer-fence-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try store.prepare()
    try await body(store, NotebookPersistenceQueue(store: store), root.appendingPathComponent("durable-order"))
  }
  nonisolated static func append(_ text: String, _ path: URL) throws {
    let before = (try? Data(contentsOf: path)) ?? Data()
    try (before + Data(text.utf8)).write(to: path)
  }

  static func acceptedPrefixExcludesLaterWorkAndCoalescing() async throws {
    try await fixture { _, queue, path in
      let first = Blocker(), future = Blocker(), owner = UUID(), result = Signal<Bool>()
      defer { first.release(); future.release() }
      queue.enqueue { _ in try first.hold(); return false }
      queue.enqueue(owner: .page(owner)) { _ in try append("accepted\n", path); return false }
      var entered = false
      let waiter = Task { @MainActor in entered = true; result.set(await queue.flush()) }
      try await until { entered }
      queue.enqueue(owner: .page(owner)) { _ in try future.hold(); try append("future\n", path); return false }
      first.release()
      try await until { future.entered.value == true }
      try await until { result.value != nil }
      try check(result.value == true, "The accepted prefix must finish while future work is held")
      try check(try String(contentsOf: path, encoding: .utf8) == "accepted\n", "Coalescing must not replace the accepted side of the fence")
      future.release(); await waiter.value
      let saved = await queue.flush()
      try check(saved && queue.pendingCount == 0, "Final accepted future write must finish")
      try check(try String(contentsOf: path, encoding: .utf8) == "accepted\nfuture\n", "Both durable writes survive in FIFO order")
    }
  }

  static func cancellationReleasesOnlyTheWaiter() async throws {
    try await fixture { _, queue, path in
      let first = Blocker(), result = Signal<Bool>()
      defer { first.release() }
      queue.enqueue { _ in try first.hold(); try append("accepted\n", path); return false }
      var entered = false
      let waiter = Task { @MainActor in entered = true; result.set(await queue.flush()) }
      try await until { entered && first.entered.value == true }
      waiter.cancel()
      try await until { result.value != nil }
      try check(result.value == false, "Cancellation must finish without waiting for a held write")
      queue.enqueue { _ in try append("last\n", path); return false }
      first.release(); await waiter.value
      let saved = await queue.flush()
      try check(saved && queue.pendingCount == 0, "Cancelled waiting must not remove accepted writes")
      try check(try String(contentsOf: path, encoding: .utf8) == "accepted\nlast\n", "Final write survives cancellation")
    }
  }

  static func failedPredecessorRemainsRetryable() async throws {
    try await fixture { _, queue, path in
      let repaired = Signal<Bool>()
      queue.enqueue { _ in
        guard repaired.value == true else { throw Failure.contract("unavailable") }
        try append("repaired\n", path); return false
      }
      queue.enqueue { _ in try append("last\n", path); return false }
      let failed = await queue.flush()
      try check(!failed && queue.failure != nil && queue.pendingCount == 2, "Failure releases its fence while retaining both accepted writes")
      repaired.set(true); queue.retry()
      let saved = await queue.flush()
      try check(saved && queue.failure == nil && queue.pendingCount == 0, "Retry drains the retained prefix")
      try check(try String(contentsOf: path, encoding: .utf8) == "repaired\nlast\n", "Retry preserves order and the final write")
    }
  }

  static func laterFailureCannotRevokeCompletedPrefix() async throws {
    try await fixture { _, queue, path in
      let first = Blocker(), repaired = Signal<Bool>(), result = Signal<Bool>()
      defer { first.release() }
      queue.enqueue { _ in try first.hold(); try append("accepted\n", path); return false }
      var entered = false
      let waiter = Task { @MainActor in entered = true; result.set(await queue.flush()) }
      try await until { entered }
      queue.enqueue { _ in
        guard repaired.value == true else { throw Failure.contract("later failure") }
        try append("later\n", path); return false
      }
      first.release(); await waiter.value
      try await until { queue.failure != nil }
      try check(result.value == true, "A later failing write is outside the completed fence")
      try check(queue.pendingCount == 1, "Only the failed later write remains")
      repaired.set(true); queue.retry()
      let saved = await queue.flush()
      try check(saved && queue.pendingCount == 0, "Later failure can be repaired independently")
      try check(try String(contentsOf: path, encoding: .utf8) == "accepted\nlater\n", "No prefix write is replayed")
    }
  }

  static func emptyFenceDoesNotPublishACommit() async throws {
    try await fixture { _, queue, _ in
      var commits = 0
      queue.onCommit = { _ in commits += 1 }
      for _ in 0..<20 {
        let saved = await queue.flush()
        try check(saved && queue.pendingCount == 0, "An empty fence removes its own marker before completing")
      }
      try check(commits == 0, "A fence cannot wake delivery or announce a content commit")
    }
  }
}
