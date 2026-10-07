import Foundation
import NotebookCore

/// Accepted native writes have one order. Storage failure retains that accepted
/// head and its result; a definitive domain refusal closes only its own slot.
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

    var writesStore: Bool {
      if case .command(let kind) = self { return NotebookCommand(command: kind).changesStore }
      return true
    }

    var publishesDurableChanges: Bool {
      switch self {
      case .page, .pageInk, .document, .documentState, .board, .spatialInk, .elementState: true
      case .presence, .peerPresence, .inputActivity, .documentDraft, .documentReading,
        .fileDraft, .fileWindow, .chatPanel, .runCommand, .peerSession: false
      case .command(let kind):
        switch kind {
        case .apply, .commitAction, .undo, .point, .panelEdit, .panelUndo: true
        case .admitAction, .prepareAction, .action, .actions, .continuations, .search, .contexts,
          .delivery, .referenceStatus, .referenceStatuses, .actionDetails, .reference,
          .placement, .render, .pageVision, .read, .artifact, .presentation,
          .script, .scriptContext, .scriptArtifact, .importProgram, .importDocument, .importDocumentResource, .panelRead, .panelPresentation,
          .runtimeStatus, .runtimeWorkspace: false
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

  private struct Outcome: Sendable {
    let merged: Bool
    let succeeded: Bool
    var changed = true
    var rejection: CollaborationError? = nil
  }

  private struct Write {
    enum Lifetime { case accepted, observation }
    let owner: Owner?
    var isOrderingFence = true
    var lifetime: Lifetime = .accepted
    var hasStarted = false
    var admissionCharge: UUID? = nil
    let operation: @Sendable (NotebookStore) async throws -> Outcome
    var onBlocked: (@Sendable (String) -> Void)? = nil
    var boardBaseline: BoardHierarchy? = nil
    var notifiesCommit = true
    var onCompleted: (@Sendable () -> Void)? = nil
    var onRejected: (@MainActor @Sendable (CollaborationError) -> Void)? = nil
  }

  /// Completed slots release their closures immediately. Occasional compaction
  /// is amortized; a long accepted prefix never shifts the remaining FIFO at each commit.
  private struct PendingWrites: Sequence {
    private var values: [Write?] = []
    private var head = 0
    var count: Int { values.count - head }
    var isEmpty: Bool { count == 0 }
    var indices: Range<Int> { head..<values.count }
    var first: Write? { isEmpty ? nil : values[head] }
    subscript(index: Int) -> Write {
      get { values[index]! }
      set { values[index] = newValue }
    }
    mutating func append(_ write: Write) { values.append(write) }
    mutating func removeFirst() -> Write {
      let write = values[head]!
      values[head] = nil; head += 1
      if head == values.count { values.removeAll(keepingCapacity: true); head = 0 }
      else if head >= 1_024 && head >= values.count / 2 { values.removeFirst(head); head = 0 }
      return write
    }
    mutating func removeAll(where predicate: (Write) -> Bool) -> [Write] {
      var removed: [Write] = [], retained: [Write?] = []
      retained.reserveCapacity(count)
      for index in indices {
        let write = values[index]!
        if predicate(write) { removed.append(write) } else { retained.append(write) }
      }
      values = retained; head = 0
      return removed
    }
    func makeIterator() -> AnyIterator<Write> {
      var index = head
      return AnyIterator {
        guard index < values.count else { return nil }
        defer { index += 1 }; return values[index]!
      }
    }
  }

  struct Failure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
  }

  private let store: NotebookStore
  private let acceptedWitnesses: NotebookAcceptedWriteWitnesses
  private var pending = PendingWrites()
  private let admission: NotebookPersistenceAdmission
  private var task: Task<Void, Never>?
  private var lifecycleWaiters: [AnyHashable: [UUID: WaitCompletion<Bool>]] = [:]
  private(set) var acceptedMutationGeneration: UInt64 = 0
  private var workspaceSelectionSeal: UUID?
  var permitsNewWorkspaceMutation: Bool { workspaceSelectionSeal == nil }

  /// The source's actual FIFO, including old uncharged commands, determines
  /// quiescence. An observation or retained cache credit is not a mutation.
  func sealWorkspaceSelection(expectedGeneration: UInt64) -> UUID? {
    guard workspaceSelectionSeal == nil, failure == nil,
      acceptedMutationGeneration == expectedGeneration,
      !pending.contains(where: { $0.lifetime == .accepted }) else { return nil }
    let seal = UUID(); workspaceSelectionSeal = seal; return seal
  }
  func finishWorkspaceSelection(_ seal: UUID) {
    guard workspaceSelectionSeal == seal else { return }
    workspaceSelectionSeal = nil
  }
  private func requireMutationAdmission() throws {
    guard permitsNewWorkspaceMutation else {
      throw CollaborationError("workspace_selection_pending", "Выбор пространства ещё сохраняется. Текущее действие осталось в прежнем пространстве.")
    }
  }
  private(set) var failure: String?
  var onFailureChange: ((String?) -> Void)?
  var onContentMerged: (() -> Void)?
  var onCommit: ((Owner?) -> Void)?

  init(store: NotebookStore, admissionLimits: NotebookPersistenceAdmission.Limits = .init(),
    acceptedWitnessLease: NotebookIPCProcessLease? = nil) {
    self.store = store; admission = .init(limits: admissionLimits)
    acceptedWitnesses = .init(root: store.root, processLease: acceptedWitnessLease)
  }

  var pendingCount: Int { pending.count }
  var observedLifecycleTaskCount: Int { lifecycleWaiters.count }
  var acceptedPayloadBytes: Int { admission.acceptedPayloadBytes }
  var acceptedCompletionBytes: Int { admission.acceptedCompletionBytes }
  var reservedWriteBytes: Int { admission.occupiedBytes }
  var admittedOperationCount: Int { admission.operationCount }
  var reservedContactCount: Int { admission.reservedContactCount }

  func reserveWrite(_ maximumCost: NotebookPersistenceAdmission.Cost) -> NotebookPersistenceAdmission.Reservation? {
    admission.reserve(maximumCost)
  }

  func releaseWriteReservation(_ reservation: NotebookPersistenceAdmission.Reservation) {
    admission.release(reservation)
  }

  func resizeWriteReservation(_ reservation: NotebookPersistenceAdmission.Reservation,
    to cost: NotebookPersistenceAdmission.Cost) throws {
    try admission.resize(reservation, to: cost)
  }

  func extendPreparationReservation(_ reservation: NotebookPersistenceAdmission.Reservation,
    to cost: NotebookPersistenceAdmission.Cost) throws {
    try admission.extendPreparation(reservation, to: cost)
  }

  /// All preparation runs before this synchronous transfer. A valid admitted
  /// contact can enqueue even while storage is blocked, using its own reserve.
  func enqueueReserved(owner: Owner, reservation: NotebookPersistenceAdmission.Reservation,
    cost: NotebookPersistenceAdmission.Cost,
    onRejected: (@MainActor @Sendable (CollaborationError) -> Void)? = nil,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Bool) throws {
    try requireMutationAdmission()
    let charge = try admission.transfer(reservation, retaining: cost)
    enqueueChange(owner: owner, isOrderingFence: owner.isOrderingFence,
      admissionCharge: charge, onRejected: onRejected) { .init(merged: try operation($0)) }
  }
  var pendingPageInkCount: Int {
    pending.reduce(into:0) { count,write in if case .pageInk? = write.owner { count += 1 } }
  }

  /// A nil owner is an ordering fence (creation, deletion, or publication).
  /// Coalescing never crosses it or replaces an already attempted write.
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
    admissionCharge: UUID? = nil,
    onRejected: (@MainActor @Sendable (CollaborationError) -> Void)? = nil,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Change) {
    guard permitsNewWorkspaceMutation else {
      if let admissionCharge { admission.releaseCharge(admissionCharge) }
      onRejected?(.init("workspace_selection_pending", "Выбор пространства ещё сохраняется.")); return
    }
    acceptedMutationGeneration &+= 1
    let accepted = NotebookAcceptedWrite(witnesses: acceptedWitnesses, operation)
    let write = Write(owner: owner, isOrderingFence: isOrderingFence, admissionCharge: admissionCharge, operation: { store in
      do {
        let result = try accepted.apply(to: store)
        return .init(merged: result.merged, succeeded: true, changed: result.changed)
      } catch {
        guard let refusal = Self.definitiveRejection(error) else { throw error }
        let rejection = refusal as? CollaborationError
          ?? CollaborationError("mutation_rejected", refusal.localizedDescription)
        // Reconcile accepted presentation with the causal owner. A rejected
        // inverse is not a disk failure and must not block subsequent ink.
        return .init(merged: true, succeeded: false, changed: false, rejection: rejection)
      }
    }, notifiesCommit: owner?.publishesDurableChanges ?? true, onRejected: onRejected)
    if !isOrderingFence, let owner, let index = coalescingIndex(for: owner) {
      releaseAdmission(pending[index])
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
    guard permitsNewWorkspaceMutation else { return }
    acceptedMutationGeneration &+= 1
    let index = coalescingIndex(for: .board)
    let baseline = index.flatMap { pending[$0].boardBaseline } ?? before
    let accepted = NotebookAcceptedWrite(witnesses: acceptedWitnesses) {
      try $0.saveBoardEdits(before: baseline, after: after)
    }
    let write = Write(owner: .board, isOrderingFence: false, operation: { store in
      .init(merged: try accepted.apply(to: store) != after, succeeded: true)
    }, boardBaseline: baseline)
    if let index { releaseAdmission(pending[index]); pending[index] = write } else { pending.append(write) }
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
        guard !pending[index].isOrderingFence, !pending[index].hasStarted else { break }
        // Contact release must not jump ahead of content accepted during that
        // contact. Only consecutive activity updates may replace each other.
        if case .inputActivity = owner, pending[index].owner != owner { break }
        if case .inputActivity? = pending[index].owner, pending[index].owner != owner { break }
        if pending[index].owner == owner {
          return index
        }
      }
    return nil
  }

  func discardPending(owner: Owner) {
    // Existing provisional full-page replacements are discardable. A contact
    // whose admission transferred to the writer is already accepted.
    let removed = pending.removeAll { $0.owner == owner && !$0.hasStarted && $0.admissionCharge == nil }
    for write in removed { releaseAdmission(write) }
  }

  func retry() {
    failure = nil
    onFailureChange?(nil)
    startIfNeeded()
  }

  enum LifecycleResult<Value: Sendable>: Sendable {
    case completed(Value)
    case blocked
  }

  /// Observe an already owned lifecycle task without abandoning its accepted
  /// writes. A storage fault releases the caller so it can request Retry; the
  /// same task still owns startup/teardown and its eventual result.
  func waitForLifecycle<Value: Sendable>(_ work: Task<Value, Never>) async -> LifecycleResult<Value> {
    guard !Task.isCancelled, failure == nil else { return .blocked }
    let key = AnyHashable(work), id = UUID(), completion = WaitCompletion<Bool>()
    if lifecycleWaiters[key] == nil {
      lifecycleWaiters[key] = [:]
      // One monitor per owned task, including repeated fail/Retry cycles.
      Task { [weak self] in
        _ = await work.value
        if let observers = self?.lifecycleWaiters.removeValue(forKey: AnyHashable(work)) {
          for observer in observers.values { observer.resolve(true) }
        }
      }
    }
    let finished = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        lifecycleWaiters[key]?[id] = completion
      }
    } onCancel: {
      completion.resolve(false)
      Task { @MainActor [weak self] in self?.lifecycleWaiters[AnyHashable(work)]?.removeValue(forKey: id) }
    }
    guard finished else { return .blocked }
    return .completed(await work.value)
  }

  /// Capture the already accepted prefix synchronously, before the reader
  /// suspends. Only this empty ordering slot enters the writer; SQL decoding
  /// runs on the workspace reader after it completes.
  struct ReadFence: Sendable {
    fileprivate let result: AcceptedResult<Void>
    func wait() async throws {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await result.value()
        try Task.checkCancellation()
      } onCancel: { result.resolve(.failure(CancellationError())) }
    }
  }

  func captureReadFence() -> ReadFence {
    let result = AcceptedResult<Void>()
    if let failure { result.resolve(.failure(Failure(message: failure))) }
    else {
      pending.append(Write(owner: nil, lifetime: .observation,
        operation: { _ in .init(merged: false, succeeded: true, changed: false) },
        onBlocked: { result.resolve(.failure(Failure(message: $0))) },
        notifiesCommit: false, onCompleted: { result.resolve(.success(())) }))
      startIfNeeded()
    }
    return .init(result: result)
  }

  /// A mutation keeps this result waiter across storage failure; Retry resumes
  /// the same accepted operation. Save/shutdown waits report the blocked owner.
  /// `writesStore` is an internal effect declaration for nonpublishing writes,
  /// pending the separate reader/writer capabilities. It is never wire input.
  func submit<Value: Sendable>(
    publishesChanges: Bool = false,
    writesStore: Bool = false,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value
  ) async throws -> Value {
    return try await withCheckedThrowingContinuation { continuation in
      enqueueCommand(publishesChanges: publishesChanges, writesStore: writesStore,
        operation) { continuation.resume(with: $0) }
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
    writesStore: Bool = false,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value,
    completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
    enqueueCommand(owner: nil, notifiesCommit: publishesChanges,
      writesStore: writesStore || publishesChanges, operation, completion: completion)
  }

  func enqueueCommand<Value: Sendable>(owner: Owner,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value,
    completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
    enqueueCommand(owner: owner, notifiesCommit: owner.publishesDurableChanges,
      writesStore: owner.writesStore, operation, completion: completion)
  }

  func enqueueCommand<Value: Sendable>(owner: Owner,
    reservation: NotebookPersistenceAdmission.Reservation, cost: NotebookPersistenceAdmission.Cost,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value,
    completion: @escaping @Sendable (Result<Value, Error>) -> Void) throws {
    try requireMutationAdmission()
    guard owner.writesStore else {
      throw CollaborationError("invalid_operation","Резерв принятой записи принадлежит изменению хранилища.")
    }
    let charge=try admission.transfer(reservation, retaining:cost)
    enqueueCommand(owner:owner,notifiesCommit:owner.publishesDurableChanges,
      writesStore:owner.writesStore,admissionCharge:charge,operation,completion:completion)
  }

  private func enqueueCommand<Value: Sendable>(owner: Owner?, notifiesCommit: Bool, writesStore: Bool,
    admissionCharge:UUID? = nil,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value,
    completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
    if writesStore, !permitsNewWorkspaceMutation {
      if let admissionCharge { admission.releaseCharge(admissionCharge) }
      completion(.failure(CollaborationError("workspace_selection_pending", "Выбор пространства ещё сохраняется."))); return
    }
    if !writesStore, let failure { completion(.failure(Failure(message: failure))); return }
    let accepted: NotebookAcceptedWrite<Value>? = writesStore
      ? NotebookAcceptedWrite(witnesses: acceptedWitnesses, operation) : nil
    let execute: @Sendable (NotebookStore) async throws -> Outcome = { store in
      do {
        let value: Value
        if let accepted { value = try accepted.apply(to: store) }
        else { value = try operation(store) }
        completion(.success(value))
        return Outcome(merged: false, succeeded: true)
      } catch {
        // A read observer can fail without changing the accepted writer. A
        // mutation owns its exact closure and waiter until its outcome is known.
        let refusal = Self.definitiveRejection(error)
        guard !writesStore || refusal != nil else { throw error }
        completion(.failure(refusal ?? error))
        return Outcome(merged: false, succeeded: false, changed: false)
      }
    }
    let onBlocked: (@Sendable (String) -> Void)?
    if writesStore { onBlocked = nil }
    else { onBlocked = { message in completion(.failure(Failure(message: message))) } }
    let lifetime: Write.Lifetime = writesStore ? .accepted : .observation
    let write = Write(owner: owner, lifetime: lifetime, admissionCharge: admissionCharge,
      operation: execute, onBlocked: onBlocked, notifiesCommit: notifiesCommit)
    if writesStore { acceptedMutationGeneration &+= 1 }
    pending.append(write)
    startIfNeeded()
  }

  /// Reserve the ordinary FIFO at lift, before material preparation suspends.
  /// Later Pencil writes keep their order without blocking their live input.
  /// A rejected preparation/command releases its caller; a storage failure
  /// retains this accepted command and its result channel for explicit retry.
  struct PreparedCommand<Value: Sendable>: Sendable {
    let cost: NotebookPersistenceAdmission.Cost
    let operation: @Sendable (NotebookStore) throws -> Value
  }

  /// Acquire the reservation before creating the body worker. FIFO acceptance
  /// transfers its full credit; completion of preparation can reduce it to the
  /// actual retained body plus simultaneous execution/encoding workspace.
  func enqueuePreparedCommand<Value: Sendable>(
    reservation: NotebookPersistenceAdmission.Reservation,
    _ preparation: Task<PreparedCommand<Value>, Error>,
    publishesChanges: Bool = false) throws -> Task<Value, Error> {
    try requireMutationAdmission()
    let charge = try admission.transfer(reservation)
    let measured = Task { [admission] in
      let prepared = try await preparation.value
      try admission.resizeCharge(charge, to: prepared.cost)
      return prepared.operation
    }
    return enqueuePreparedCommand(admissionCharge: charge, publishesChanges: publishesChanges) { try await measured.value }
  }

  private func enqueuePreparedCommand<Value: Sendable>(admissionCharge: UUID, publishesChanges: Bool,
    _ prepare: @escaping @Sendable () async throws -> (@Sendable (NotebookStore) throws -> Value)) -> Task<Value, Error> {
    let channel = AcceptedResult<Value>()
    let witnesses = acceptedWitnesses
    // This worker caches one typed accepted instance, including its exact
    // output. Retry never rebuilds it from the completed preparation task.
    let accepted = Task {
      NotebookAcceptedWrite(witnesses: witnesses, try await prepare())
    }
    acceptedMutationGeneration &+= 1
    pending.append(Write(owner:nil, admissionCharge: admissionCharge, operation:{ store in
      let command: NotebookAcceptedWrite<Value>
      do { command=try await accepted.value }
      catch {
        channel.resolve(.failure(error))
        return .init(merged:false,succeeded:false)
      }
      do {
        let value=try command.apply(to: store)
        channel.resolve(.success(value))
        return .init(merged:false,succeeded:true)
      } catch {
        guard let rejection = Self.definitiveRejection(error) else { throw error }
        channel.resolve(.failure(rejection))
        return .init(merged:false,succeeded:false)
      }
      // All other execution failures reach the existing failed-write owner.
      // Do not finish the channel or let a dependent accepted edit overtake it.
    },notifiesCommit:publishesChanges))
    startIfNeeded()
    // Cancelling a presentation waiter cannot close an accepted result stream
    // or revoke the write. The result task remains readable by dependencies.
    return Task { try await channel.value() }
  }

  /// Program transfer credit follows its accepted writer through a disk retry.
  /// Unlike a navigation waiter, this cut is not cancelled or removed on I/O
  /// failure: releasing it early would move an unbounded queue into native RAM.
  func finishAcceptedProgramWrites() async {
    let witnesses = acceptedWitnesses
    await withCheckedContinuation { continuation in
      pending.append(Write(owner: nil, operation: { store in
        try witnesses.flush(in: store)
        return .init(merged: false, succeeded: true)
      },
        notifiesCommit: false, onCompleted: { continuation.resume() }))
      startIfNeeded()
    }
  }

  @discardableResult
  func flush() async -> Bool {
    guard !Task.isCancelled, failure == nil else { return false }
    let completion = WaitCompletion<Bool>()
    let witnesses = acceptedWitnesses
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion.install(continuation)
        // This nil-owner command is the accepted FIFO cut. Register it before
        // suspending: later writes and coalescing cannot move ahead of it.
        pending.append(Write(owner: nil, lifetime: .observation, operation: { store in
          try witnesses.flush(in: store)
          return .init(merged: false, succeeded: true)
        },
          onBlocked: { _ in completion.resolve(false) }, notifiesCommit: false,
          onCompleted: { completion.resolve(true) }))
        startIfNeeded()
      }
    } onCancel: {
      // Cancellation abandons this wait, never an accepted write or its order.
      completion.resolve(false)
    }
  }

  private final class WaitCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func install(_ continuation: CheckedContinuation<Value, Never>) {
      lock.lock()
      if let result { lock.unlock(); continuation.resume(returning: result) }
      else { self.continuation = continuation; lock.unlock() }
    }

    func resolve(_ result: Value) {
      lock.lock()
      guard self.result == nil else { lock.unlock(); return }
      self.result = result
      let continuation = continuation; self.continuation = nil
      lock.unlock()
      continuation?.resume(returning: result)
    }
  }

  fileprivate final class AcceptedResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
      }
    }

    func resolve(_ result: Result<Value, Error>) {
      lock.lock()
      guard self.result == nil else { lock.unlock(); return }
      self.result = result
      let continuation = continuation; self.continuation = nil
      lock.unlock()
      continuation?.resume(with: result)
    }
  }

  /// Only the Core transaction owner can attest that a domain refusal rolled
  /// back. The UI observer and protocol error name cannot close a writer slot.
  nonisolated private static func definitiveRejection(_ error: Error) -> Error? {
    guard let failure = error as? NotebookAcceptedWriteError, failure.outcome == .rejected else { return nil }
    return failure.underlying
  }

  private func startIfNeeded() {
    guard task == nil, failure == nil, !pending.isEmpty else { return }
    task = Task { await drain() }
  }

  private func drain() async {
    while let next = pending.first {
      // An attempted slot owns its exact outcome across Retry. Even a
      // coalescible draft cannot replace/discard that instance after failure.
      pending[pending.indices.lowerBound].hasStarted = true
      let store = store
      let operation = next.operation
      let result = await Task.detached(priority: .utility) {
        do { return .success(try await operation(store)) as Result<Outcome,Error> }
        catch { return .failure(error) }
      }.value
      switch result {
      case .success(let outcome):
        releaseAdmission(pending.removeFirst())
        if let rejection = outcome.rejection { next.onRejected?(rejection) }
        if outcome.merged { onContentMerged?() }
        if next.notifiesCommit && outcome.succeeded && outcome.changed { onCommit?(next.owner) }
        next.onCompleted?()
      case .failure(let error):
        failure = error.localizedDescription
        onFailureChange?(failure)
        for key in Array(lifecycleWaiters.keys) {
          let waiters = lifecycleWaiters[key]!
          lifecycleWaiters[key]?.removeAll()
          for waiter in waiters.values { waiter.resolve(false) }
        }
        for write in pending { write.onBlocked?(error.localizedDescription) }
        let removed = pending.removeAll { $0.lifetime == .observation }
        for write in removed { releaseAdmission(write) }
        task = nil
        return
      }
    }
    task = nil
  }

  private func releaseAdmission(_ write: Write) {
    if let charge = write.admissionCharge { admission.releaseCharge(charge) }
  }
}
