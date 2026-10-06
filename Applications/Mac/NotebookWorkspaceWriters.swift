import Foundation
import NotebookCore

/// Workspace lifetime owns durable ordering independently of any agent route
/// or mounted surface. Every client of the same canonical root borrows its FIFO.
@MainActor
final class NotebookWorkspaceWriters {
  private var writers: [String: NotebookPersistenceQueue] = [:]
  private var processLease: NotebookIPCProcessLease?

  /// Bind the already claimed runtime lease before constructing store owners.
  /// Retry keeps the same registry, descriptor and accepted witness scopes.
  func bindAcceptedWitnessLease(_ lease: NotebookIPCProcessLease) {
    precondition(writers.isEmpty || processLease === lease)
    processLease = lease
  }

  /// Read-only dependencies for process-wide admission checks, including
  /// workspaces whose executor route has not finished starting.
  var persistenceQueues: [NotebookPersistenceQueue] { Array(writers.values) }

  /// Observe one already owned process drain across every admitted writer.
  /// Failure releases only this caller; accepted work and its drain keep the
  /// same task/queues until Retry supplies their original outcomes.
  func waitForLifecycle<Value: Sendable>(_ task: Task<Value, Never>) async -> NotebookPersistenceQueue.LifecycleResult<Value> {
    let queues = persistenceQueues
    guard !queues.isEmpty else { return .completed(await task.value) }
    return await withTaskGroup(of: NotebookPersistenceQueue.LifecycleResult<Value>.self) { group in
      for queue in queues { group.addTask { await queue.waitForLifecycle(task) } }
      let result = await group.next()!
      group.cancelAll()
      return result
    }
  }

  func persistence(for store: NotebookStore) -> NotebookPersistenceQueue {
    let root = NotebookStore.canonicalWorkspacePath(store.root)
    if let writer = writers[root] { return writer }
    let writer = NotebookPersistenceQueue(store: store, acceptedWitnessLease: processLease)
    writers[root] = writer
    return writer
  }

  /// Call after the workspace closes service and input admission. A failed
  /// accepted write keeps its exact queue available to repair and retry.
  func remove(root: URL) async throws {
    let root = NotebookStore.canonicalWorkspacePath(root)
    guard let writer = writers[root] else { return }
    guard await writer.flush() else { throw NotebookTransportError.storageUnavailable }
    writers.removeValue(forKey: root)
  }

  func shutdown() async -> Bool {
    for writer in writers.values {
      guard await writer.flush() else { return false }
    }
    writers.removeAll()
    return true
  }
}
