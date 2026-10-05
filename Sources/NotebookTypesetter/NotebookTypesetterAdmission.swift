import Foundation
import CNotebookTypesetter

/// A single request keeps its completion across scheduling yields. Its native
/// cancellation ticket and preparation task are joined before another admission.
final class NotebookTypesetterWork: @unchecked Sendable {
  enum Completion { case finished, cancelled, retry, deadline }
  private let lock = NSLock()
  private var cancelled = false
  private var yielded = false
  private var remaining: Duration = .seconds(30)
  private var started: ContinuousClock.Instant?
  private var task: Task<Void, Never>?
  private var attempt: UUID?
  private var tex: OpaquePointer?
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func prepareAttempt() -> UUID {
    let id = UUID(); lock.lock(); attempt = id; lock.unlock(); return id
  }
  func begin() throws {
    lock.lock(); defer { lock.unlock() }
    if cancelled || yielded { throw CancellationError() }
    guard remaining > .zero else { throw NotebookTypesetterError("typesetter_deadline") }
    started = .now
  }
  func attach(_ task: Task<Void, Never>, attempt: UUID) {
    lock.lock()
    guard self.attempt == attempt else { lock.unlock(); return }
    self.task = task; let stop = cancelled || yielded; lock.unlock()
    if stop { task.cancel() }
  }
  func cancel() { stop(yielding: false)?.cancel() }
  // Admission fences this flag against completion; cancelling the task happens
  // after its lock is released because callbacks may themselves change demand.
  func requestYield() -> Task<Void, Never>? { stop(yielding: true) }
  private func stop(yielding: Bool) -> Task<Void, Never>? {
    lock.lock()
    if yielding { yielded = true } else { cancelled = true }
    if let tex { nb_typesetter_cancel(tex) }
    let task = task; lock.unlock(); return task
  }
  func check() throws {
    lock.lock(); defer { lock.unlock() }
    if cancelled || yielded { throw CancellationError() }
    if let started, started.duration(to: .now) >= remaining { throw NotebookTypesetterError("typesetter_deadline") }
  }
  func remainingMilliseconds() throws -> UInt64 {
    try check(); lock.lock(); defer { lock.unlock() }
    let duration = remaining - (started?.duration(to: .now) ?? .zero), c = duration.components
    return max(1, UInt64(max(0, c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)))
  }
  func withTeX<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try check()
    guard let ticket = nb_typesetter_cancel_create() else { throw NotebookTypesetterError("typesetter_resource_limit") }
    lock.lock(); tex = ticket; if cancelled || yielded { nb_typesetter_cancel(ticket) }; lock.unlock()
    defer { lock.lock(); tex = nil; nb_typesetter_cancel_destroy(ticket); lock.unlock() }
    return try body(ticket)
  }
  func complete(succeeded: Bool) -> Completion {
    lock.lock(); defer { lock.unlock() }
    if let started { remaining -= started.duration(to: .now) }
    started = nil; task = nil; attempt = nil
    if cancelled { return .cancelled }
    // A completed result wins over a scheduling change at its finishing edge.
    if succeeded { yielded = false; return .finished }
    if yielded { yielded = false; return remaining > .zero ? .retry : .deadline }
    return .finished
  }
}

/// Owns the only print admission queue, including resource materialization.
/// Pending requests retain immutable sources; only one prepares bytes or runs a VM.
final class NotebookTypesetterAdmission: @unchecked Sendable {
  private struct Pending: Sendable {
    let id: UUID
    let demand: NotebookTypesetterDemand
    let work: NotebookTypesetterWork
    let order: UInt64
    var queuedAt: ContinuousClock.Instant = .now
    let start: @Sendable () -> Void
    let cancel: @Sendable () -> Void
  }
  private let lock = NSLock()
  private var pending: [Pending] = []
  private var active: Pending?
  private var activeStarted: ContinuousClock.Instant?
  private var running = false
  private var sequence: UInt64 = 0
  private var preferredAdmissions = 0
  private var protectedTurn = false

  func perform<T: Sendable>(demand: NotebookTypesetterDemand,
    operation: @escaping @Sendable (NotebookTypesetterWork) async throws -> T) async throws -> T {
    let id = UUID(), work = NotebookTypesetterWork()
    let observer = demand.observe { [weak self] in self?.priorityChanged() }
    defer { demand.removeObserver(observer) }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if work.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        // Count requests across running, waiting and yielded states. Preserve
        // the former total bound (one running + 32 waiting), with space for a
        // running current request and its successor even after a yield.
        let limit = demand.current == .current ? 33 : 31
        guard pending.count + (active == nil ? 0 : 1) < limit else {
          lock.unlock(); continuation.resume(throwing: NotebookTypesetterError("typesetter_queue_full")); return
        }
        sequence &+= 1
        let item = Pending(id: id, demand: demand, work: work, order: sequence, start: {
          let attempt = work.prepareAttempt()
          let task = Task.detached(priority: .userInitiated) {
            let result: Result<T, Error>
            do { try work.begin(); result = .success(try await operation(work)) }
            catch { result = .failure(error) }
            self.completed(id: id, result: result, continuation: continuation)
          }
          work.attach(task, attempt: attempt)
        }, cancel: { continuation.resume(throwing: CancellationError()) })
        pending.append(item)
        demand.record("queue", milliseconds: 0, accumulating: true)
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { startNext() } else { priorityChanged() }
      }
    } onCancel: {
      work.cancel()
      self.lock.lock()
      let index = self.pending.firstIndex { $0.id == id }
      let removed = index.map { self.pending.remove(at: $0) }
      self.lock.unlock()
      removed?.cancel()
    }
  }
  private func priorityChanged() {
    lock.lock()
    let task = !protectedTurn && active?.demand.mayYield == true
      && pending.contains(where: { $0.demand.current == .current }) ? active?.work.requestYield() : nil
    lock.unlock()
    task?.cancel()
  }
  private func startNext() {
    lock.lock()
    guard !pending.isEmpty else { running = false; lock.unlock(); return }
    let oldest = pending.indices.min { pending[$0].order < pending[$1].order }!
    let preferred = pending.indices.min {
      pending[$0].demand.current.rawValue == pending[$1].demand.current.rawValue
        ? pending[$0].order < pending[$1].order
        : pending[$0].demand.current.rawValue < pending[$1].demand.current.rawValue
    }!
    protectedTurn = preferredAdmissions >= 8
    let index = protectedTurn ? oldest : preferred
    preferredAdmissions = index == oldest ? 0 : preferredAdmissions + 1
    let item = pending.remove(at: index)
    active = item; activeStarted = .now
    lock.unlock()
    item.demand.record("queue", since: item.queuedAt, accumulating: true)
    item.start()
  }
  private func completed<T: Sendable>(id: UUID, result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
    lock.lock()
    guard var item = active, item.id == id else { preconditionFailure("Print attempt lost its admission") }
    let succeeded: Bool
    if case .success = result { succeeded = true } else { succeeded = false }
    let completion = item.work.complete(succeeded: succeeded)
    let admittedAt = activeStarted
    active = nil; activeStarted = nil
    if case .retry = completion { item.queuedAt = .now; pending.append(item) }
    lock.unlock()
    switch completion {
    case .retry:
      if let admittedAt { item.demand.record("yieldedWork", since: admittedAt, accumulating: true) }
    case .cancelled: continuation.resume(throwing: CancellationError())
    case .deadline: continuation.resume(throwing: NotebookTypesetterError("typesetter_deadline"))
    case .finished: continuation.resume(with: result)
    }
    startNext()
  }
}
