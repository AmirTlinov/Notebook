import Foundation
import NotebookCore

/// Accepted native writes have one order. A failed write remains at the head:
/// dependent content cannot overtake creation, and shutdown cannot report success.
@MainActor
final class NotebookPersistenceQueue {
  enum Owner: Hashable {
    case page(UUID), document(UUID), documentState(UUID), documentDraft(UUID)
    case board, spatialInk(UUID), presence, inputActivity(UUID)
    case nativeText(UUID, String), elementState(UUID, String)
  }

  private struct Outcome {
    let merged: Bool
    let succeeded: Bool
  }

  private struct Write {
    let id = UUID()
    let owner: Owner?
    let operation: @Sendable (NotebookStore) throws -> Outcome
    var onBlocked: (@Sendable (String) -> Void)? = nil
    var boardBaseline: BoardHierarchy? = nil
    var notifiesCommit = true
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
  var onCommit: ((Owner?) -> Void)?

  init(store: NotebookStore) { self.store = store }

  var pendingCount: Int { pending.count }

  /// A nil owner is an ordering fence (creation, deletion, or publication).
  /// Coalescing never crosses it or replaces a write already executing.
  func enqueue(owner: Owner? = nil,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Bool) {
    let write = Write(owner: owner, operation: { .init(merged: try operation($0), succeeded: true) })
    if let owner, let index = coalescingIndex(for: owner) {
      pending[index] = write
      startIfNeeded()
      return
    }
    pending.append(write)
    startIfNeeded()
  }

  /// Coalesced deltas keep the first unsaved baseline. Replacing that baseline
  /// with the next visible frame would lose an earlier insertion or deletion.
  func enqueueBoardEdit(before: BoardHierarchy, after: BoardHierarchy) {
    let index = coalescingIndex(for: .board)
    let baseline = index.flatMap { pending[$0].boardBaseline } ?? before
    let write = Write(owner: .board, operation: { store in
      .init(merged: try store.saveBoardEdits(before: baseline, after: after) != after, succeeded: true)
    }, boardBaseline: baseline)
    if let index { pending[index] = write } else { pending.append(write) }
    startIfNeeded()
  }

  private func coalescingIndex(for owner: Owner) -> Int? {
      // Addressed commands carry only their accepted contact/block, not a full
      // replacement journal. Coalescing would drop an earlier value or undo.
      if case .spatialInk = owner { return nil }
      if case .documentState = owner { return nil }
      for index in pending.indices.reversed() {
        guard pending[index].owner != nil else { break }
        // Contact release must not jump ahead of content accepted during that
        // contact. Only consecutive activity updates may replace each other.
        if case .inputActivity = owner, pending[index].owner != owner { break }
        if case .inputActivity? = pending[index].owner, pending[index].owner != owner { break }
        if pending[index].owner == owner, pending[index].id != executingID {
          return index
        }
      }
    return nil
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
    publishesChanges: Bool = false,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value
  ) async throws -> Value {
    return try await withCheckedThrowingContinuation { continuation in
      enqueueCommand(publishesChanges: publishesChanges, operation) { continuation.resume(with: $0) }
    }
  }

  /// Registers the fence before returning to UIKit. A later contact may start
  /// immediately, but neither its write nor coalescing can overtake this cut.
  func enqueueCommand<Value: Sendable>(publishesChanges: Bool = false,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value,
    completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
    if let failure { completion(.failure(Failure(message: failure))); return }
    let write = Write(owner: nil, operation: { store in
      let result = Result { try operation(store) }
      completion(result)
      switch result {
      case .success: return .init(merged: false, succeeded: true)
      case .failure: return .init(merged: false, succeeded: false)
      }
    }, onBlocked: { completion(.failure(Failure(message: $0))) }, notifiesCommit: publishesChanges)
    pending.append(write)
    startIfNeeded()
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
      case .success(let outcome):
        pending.removeFirst()
        if outcome.merged { onContentMerged?() }
        if next.notifiesCommit && outcome.succeeded { onCommit?(next.owner) }
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
