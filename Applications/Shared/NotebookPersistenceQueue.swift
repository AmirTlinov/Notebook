import Foundation
import NotebookCore

/// Accepted native writes have one order. A failed write remains at the head:
/// dependent content cannot overtake creation, and shutdown cannot report success.
@MainActor
final class NotebookPersistenceQueue {
  enum Owner: Hashable {
    case page(UUID), document(UUID), documentState(UUID), documentDraft(UUID)
    case board, spatialInk, presence, inputActivity(UUID)
  }

  private struct Write {
    let id = UUID()
    let owner: Owner?
    let operation: @Sendable (NotebookStore) throws -> Bool
    var onBlocked: (@Sendable (String) -> Void)? = nil
  }

  struct Failure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
  }

  private let store: NotebookStore
  private var pending: [Write] = []
  private var task: Task<Void, Never>?
  private var executingID: UUID?
  private(set) var failure: String?
  var onFailureChange: ((String?) -> Void)?
  var onContentMerged: (() -> Void)?

  init(store: NotebookStore) { self.store = store }

  var pendingCount: Int { pending.count }

  /// A nil owner is an ordering fence (creation, deletion, or publication).
  /// Coalescing never crosses it or replaces a write already executing.
  func enqueue(owner: Owner? = nil,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Bool) {
    let write = Write(owner: owner, operation: operation)
    if let owner {
      for index in pending.indices.reversed() {
        guard pending[index].owner != nil else { break }
        // Contact release must not jump ahead of content accepted during that
        // contact. Only consecutive activity updates may replace each other.
        if case .inputActivity = owner, pending[index].owner != owner { break }
        if case .inputActivity? = pending[index].owner, pending[index].owner != owner { break }
        if pending[index].owner == owner, pending[index].id != executingID {
          pending[index] = write
          startIfNeeded()
          return
        }
      }
    }
    pending.append(write)
    startIfNeeded()
  }

  func discardPending(owner: Owner) {
    pending.removeAll { $0.owner == owner && $0.id != executingID }
  }

  func retry() {
    failure = nil
    onFailureChange?(nil)
    startIfNeeded()
  }

  /// A command returns its domain result in the same order as durable writes.
  /// On a storage failure callers are released, while their preceding drafts
  /// remain queued; retrying a command must revalidate its expectations.
  func submit<Value: Sendable>(
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value
  ) async throws -> Value {
    if let failure { throw Failure(message: failure) }
    return try await withCheckedThrowingContinuation { continuation in
      let write = Write(owner: nil, operation: { store in
        continuation.resume(with: Result { try operation(store) })
        return false
      }, onBlocked: { message in
        continuation.resume(throwing: Failure(message: message))
      })
      pending.append(write)
      startIfNeeded()
    }
  }

  @discardableResult
  func flush() async -> Bool {
    while let task { await task.value }
    return failure == nil && pending.isEmpty
  }

  private func startIfNeeded() {
    guard task == nil, failure == nil, !pending.isEmpty else { return }
    task = Task { await drain() }
  }

  private func drain() async {
    while let next = pending.first {
      executingID = next.id
      let store = store
      let operation = next.operation
      let result = await Task.detached(priority: .utility) {
        Result { try operation(store) }
      }.value
      executingID = nil
      switch result {
      case .success(let merged):
        pending.removeFirst()
        if merged { onContentMerged?() }
      case .failure(let error):
        failure = error.localizedDescription
        onFailureChange?(failure)
        for write in pending { write.onBlocked?(error.localizedDescription) }
        pending.removeAll { $0.onBlocked != nil }
        task = nil
        return
      }
    }
    task = nil
  }
}
