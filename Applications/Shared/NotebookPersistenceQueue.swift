import Foundation
import NotebookCore

/// Accepted native writes have one order. A failed write remains at the head:
/// dependent content cannot overtake creation, and shutdown cannot report success.
@MainActor
final class NotebookPersistenceQueue {
  enum Owner: Hashable {
    case fileDraft(String), fileWindow(UUID?), chatPanel(UUID?), runCommand(String)
    case page(UUID), pageInk(UUID), document(UUID), documentState(UUID), documentDraft(UUID), documentReading(UUID)
    case board, spatialInk(UUID), presence, peerPresence(UUID), inputActivity(UUID)
    case elementState(UUID, String)
    case peerSession(UUID), command(NotebookCommand.Kind)

    var isOrderingFence: Bool {
      switch self { case .peerSession, .command: true; default: false }
    }

    var publishesDurableChanges: Bool {
      switch self {
      case .page, .pageInk, .document, .documentState, .board, .spatialInk, .elementState: true
      case .presence, .peerPresence, .inputActivity, .documentDraft, .documentReading,
        .fileDraft, .fileWindow, .chatPanel, .runCommand, .peerSession: false
      case .command(let kind):
        switch kind {
        case .apply, .commitAction, .undo, .point: true
        case .admitAction, .prepareAction, .action, .actions, .continuations, .search, .contexts,
          .delivery, .referenceStatus, .referenceStatuses, .actionDetails, .reference,
          .placement, .render, .pageVision, .read, .artifact, .presentation,
          .script, .scriptContext, .scriptArtifact, .importProgram: false
        }
      }
    }
  }

  /// Whether a successful write actually changed its content, independently
  /// of whether that owner's content belongs to the durable journal.
  struct Change: Sendable {
    let merged: Bool
    var changed = true
  }

  private struct Outcome {
    let merged: Bool
    let succeeded: Bool
    var changed = true
    var rejection: CollaborationError? = nil
  }

  private struct Write {
    let id = UUID()
    let owner: Owner?
    var isOrderingFence = true
    let operation: @Sendable (NotebookStore) async throws -> Outcome
    var onBlocked: (@Sendable (String) -> Void)? = nil
    var boardBaseline: BoardHierarchy? = nil
    var notifiesCommit = true
    var onCompleted: (@Sendable () -> Void)? = nil
    var onRejected: (@MainActor @Sendable (CollaborationError) -> Void)? = nil
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
  var pendingPageInkCount: Int {
    pending.reduce(into:0) { count,write in if case .pageInk? = write.owner { count += 1 } }
  }

  /// A nil owner is an ordering fence (creation, deletion, or publication).
  /// Coalescing never crosses it or replaces a write already executing.
  func enqueue(owner: Owner? = nil,
    onRejected: (@MainActor @Sendable (CollaborationError) -> Void)? = nil,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Bool) {
    enqueueChange(owner: owner, onRejected: onRejected) { .init(merged: try operation($0)) }
  }

  /// A typed local write can still be an ordering fence, rather than a draft
  /// that may be replaced by the next value for the same owner.
  func enqueueFence(owner: Owner,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Bool) {
    enqueueChange(owner: owner, isOrderingFence: true) { .init(merged: try operation($0)) }
  }

  func enqueueChange(owner: Owner?,
    onRejected: (@MainActor @Sendable (CollaborationError) -> Void)? = nil,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Change) {
    enqueueChange(owner: owner, isOrderingFence: owner?.isOrderingFence ?? true,
      onRejected: onRejected, operation)
  }

  private func enqueueChange(owner: Owner?, isOrderingFence: Bool,
    onRejected: (@MainActor @Sendable (CollaborationError) -> Void)? = nil,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Change) {
    let handlesRejection = onRejected != nil
    let write = Write(owner: owner, isOrderingFence: isOrderingFence, operation: { store in
      do {
        let result = try operation(store)
        return .init(merged: result.merged, succeeded: true, changed: result.changed)
      } catch let rejection as CollaborationError where handlesRejection {
        // Reconcile accepted presentation with the causal owner. A rejected
        // inverse is not a disk failure and must not block subsequent ink.
        return .init(merged: true, succeeded: false, changed: false, rejection: rejection)
      }
    }, notifiesCommit: owner?.publishesDurableChanges ?? true, onRejected: onRejected)
    if !isOrderingFence, let owner, let index = coalescingIndex(for: owner) {
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
    let write = Write(owner: .board, isOrderingFence: false, operation: { store in
      .init(merged: try store.saveBoardEdits(before: baseline, after: after) != after, succeeded: true)
    }, boardBaseline: baseline)
    if let index { pending[index] = write } else { pending.append(write) }
    startIfNeeded()
  }

  private func coalescingIndex(for owner: Owner) -> Int? {
      // Addressed commands carry only their accepted contact/block, not a full
      // replacement journal. Coalescing would drop an earlier value or undo.
      if case .spatialInk = owner { return nil }
      if case .pageInk = owner { return nil }
      if case .documentState = owner { return nil }
      if case .elementState = owner { return nil }
      for index in pending.indices.reversed() {
        guard !pending[index].isOrderingFence else { break }
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

  func submit<Value: Sendable>(owner: Owner,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      enqueueCommand(owner: owner, operation) { continuation.resume(with: $0) }
    }
  }

  /// Registers the fence before returning to UIKit. A later contact may start
  /// immediately, but neither its write nor coalescing can overtake this cut.
  func enqueueCommand<Value: Sendable>(publishesChanges: Bool = false,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value,
    completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
    enqueueCommand(owner: nil, notifiesCommit: publishesChanges, operation, completion: completion)
  }

  func enqueueCommand<Value: Sendable>(owner: Owner,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value,
    completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
    enqueueCommand(owner: owner, notifiesCommit: owner.publishesDurableChanges, operation, completion: completion)
  }

  private func enqueueCommand<Value: Sendable>(owner: Owner?, notifiesCommit: Bool,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value,
    completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
    if let failure { completion(.failure(Failure(message: failure))); return }
    let write = Write(owner: owner, operation: { store in
      let result = Result { try operation(store) }
      completion(result)
      switch result {
      case .success: return .init(merged: false, succeeded: true)
      case .failure: return .init(merged: false, succeeded: false)
      }
    }, onBlocked: { completion(.failure(Failure(message: $0))) }, notifiesCommit: notifiesCommit)
    pending.append(write)
    startIfNeeded()
  }

  /// Reserve the ordinary FIFO at lift, before material preparation suspends.
  /// Later Pencil writes keep their order without blocking their live input.
  /// A rejected preparation/command releases its caller; a storage failure
  /// retains this accepted command and its result channel for explicit retry.
  func enqueuePreparedCommand<Value:Sendable>(
    _ preparation:Task<@Sendable (NotebookStore) throws -> Value,Error>,
    publishesChanges:Bool = false) -> Task<Value,Error> {
    let channel=AsyncThrowingStream<Value,Error>.makeStream(bufferingPolicy:.bufferingNewest(1))
    pending.append(Write(owner:nil,operation:{ store in
      let operation: @Sendable (NotebookStore) throws -> Value
      do { operation=try await preparation.value }
      catch {
        channel.continuation.finish(throwing:error)
        return .init(merged:false,succeeded:false)
      }
      do {
        let value=try operation(store)
        channel.continuation.yield(value);channel.continuation.finish()
        return .init(merged:false,succeeded:true)
      } catch let rejection as CollaborationError {
        channel.continuation.finish(throwing:rejection)
        return .init(merged:false,succeeded:false)
      }
      // All other execution failures reach the existing failed-write owner.
      // Do not finish the channel or let a dependent accepted edit overtake it.
    },notifiesCommit:publishesChanges))
    startIfNeeded()
    return Task {
      for try await value in channel.stream { return value }
      throw CancellationError()
    }
  }

  /// Program transfer credit follows its accepted writer through a disk retry.
  /// Unlike a navigation waiter, this cut is not cancelled or removed on I/O
  /// failure: releasing it early would move an unbounded queue into native RAM.
  func finishAcceptedProgramWrites() async {
    await withCheckedContinuation { continuation in
      pending.append(Write(owner: nil, operation: { _ in .init(merged: false, succeeded: true) },
        notifiesCommit: false, onCompleted: { continuation.resume() }))
      startIfNeeded()
    }
  }

  @discardableResult
  func flush() async -> Bool {
    guard !Task.isCancelled, failure == nil else { return false }
    let completion = FlushCompletion()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        // This nil-owner command is the accepted FIFO cut. Register it before
        // suspending: later writes and coalescing cannot move ahead of it.
        pending.append(Write(owner: nil, operation: { _ in .init(merged: false, succeeded: true) },
          onBlocked: { _ in completion.resolve(false) }, notifiesCommit: false,
          onCompleted: { completion.resolve(true) }))
        startIfNeeded()
      }
    } onCancel: {
      // Cancellation abandons this wait, never an accepted write or its order.
      completion.resolve(false)
    }
  }

  private final class FlushCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
      lock.lock()
      if let result { lock.unlock(); continuation.resume(returning: result) }
      else { self.continuation = continuation; lock.unlock() }
    }

    func resolve(_ result: Bool) {
      lock.lock()
      guard self.result == nil else { lock.unlock(); return }
      self.result = result
      let continuation = continuation; self.continuation = nil
      lock.unlock()
      continuation?.resume(returning: result)
    }
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
        do { return .success(try await operation(store)) as Result<Outcome,Error> }
        catch { return .failure(error) }
      }.value
      executingID = nil
      switch result {
      case .success(let outcome):
        pending.removeFirst()
        if let rejection = outcome.rejection { next.onRejected?(rejection) }
        if outcome.merged { onContentMerged?() }
        if next.notifiesCommit && outcome.succeeded && outcome.changed { onCommit?(next.owner) }
        next.onCompleted?()
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
