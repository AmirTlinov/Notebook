import Foundation
import NotebookCore
import Observation
import os

/// Remote contact admission and its publication subscriptions share one lifetime.
/// Scope lookup remains a writer fence: a preceding accepted carrier move must
/// become durable before its ancestry can be used to admit a native installation.
@MainActor @Observable final class NotebookPeerPublication {
  private enum Resolution {
    case idle
    case resolving(UUID, OSAllocatedUnfairLock<Bool>)
    case resolved([NotebookInputScope])
    case failed(Error)
  }
  private struct Contact {
    let activity: NotebookInputActivity
    var resolution: Resolution
  }
  private struct Waiter {
    let target: CollaborationTarget
    let carrier: UUID?
    let scope: NotebookInputScope?
    let opening: UUID?
    let navigation: UInt64?
    let continuation: CheckedContinuation<Void, Error>
  }

  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  @ObservationIgnored private let actorID: UUID
  @ObservationIgnored private var contacts: [UUID: Contact] = [:]
  @ObservationIgnored private var waiters: [UUID: Waiter] = [:]
  @ObservationIgnored private var navigation: UInt64 = 0
  @ObservationIgnored private var stopped = false
  @ObservationIgnored var scopes: [CollaborationTarget: NotebookInputScope] = [:] {
    didSet { resumeWaiters() }
  }
  private(set) var isActive = false
  var onChange: (() -> Void)?
  var onFailure: ((Error) -> Void)?

  init(persistence: NotebookPersistenceQueue, actorID: UUID) {
    self.persistence = persistence; self.actorID = actorID
  }

  @discardableResult
  func receive(_ activity: NotebookInputActivity) -> Bool {
    guard !stopped, activity.deviceID != actorID else { return false }
    if let previous = contacts[activity.deviceID]?.activity,
      previous.sessionID == activity.sessionID, previous.sequence >= activity.sequence { return false }
    cancelLookup(activity.deviceID)
    contacts[activity.deviceID] = .init(activity: activity, resolution: .idle)
    resolve(activity)
    return true
  }

  func disconnect(_ peerID: UUID) {
    cancelLookup(peerID)
    contacts[peerID] = nil
    changed()
  }

  func retry() {
    for contact in Array(contacts.values) {
      if case .failed = contact.resolution { resolve(contact.activity) }
    }
  }

  func allows(_ target: CollaborationTarget, carrier suppliedCarrier: UUID? = nil,
    scope suppliedScope: NotebookInputScope? = nil) -> Bool {
    guard !stopped else { return false }
    var held: [NotebookInputScope] = []
    for contact in contacts.values {
      switch contact.resolution {
      case .resolving, .failed: return false
      case .resolved(let scopes): held.append(contentsOf: scopes)
      case .idle: break
      }
    }
    guard !held.isEmpty else { return true }
    let key = CollaborationTarget(kind: target.kind, id: target.id)
    let scope: NotebookInputScope
    if let prepared = suppliedScope ?? scopes[key] { scope = prepared }
    else {
      let carrier = suppliedCarrier ?? target.id
      // A newly created page may inherit its already admitted notebook scope.
      // Never reconstruct a partial ancestor chain from the visible UI tree.
      if let cover = scopes[.init(kind: .cover, id: carrier)] {
        scope = .init(target: target, carrier: carrier, boards: cover.boards)
      } else if let board = target.boardID.flatMap({ scopes[.init(kind: .board, id: $0)] }) {
        scope = .init(target: target, carrier: carrier, boards: board.boards)
      } else { return false }
    }
    return !held.contains { $0.overlaps(scope) }
  }

  func wait(to target: CollaborationTarget, carrier: UUID? = nil,
    scope: NotebookInputScope? = nil, opening: UUID? = nil, navigation: UInt64? = nil) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let waiter = Waiter(target: target, carrier: carrier, scope: scope,
          opening: opening, navigation: navigation, continuation: continuation)
        if let result = result(for: waiter) { continuation.resume(with: result) }
        else { waiters[id] = waiter }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(id, with: .failure(CancellationError())) }
    }
  }

  func cancelOpening(_ id: UUID) {
    for (key, waiter) in waiters where waiter.opening == id {
      finish(key, with: .failure(CancellationError()))
    }
  }

  func navigationChanged(to generation: UInt64) {
    navigation = generation
    resumeWaiters()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    onChange = nil; onFailure = nil
    for id in contacts.keys { cancelLookup(id) }
    contacts.removeAll(); scopes.removeAll(); isActive = false
    for id in waiters.keys { finish(id, with: .failure(CancellationError())) }
  }

  private func resolve(_ activity: NotebookInputActivity) {
    guard activity.isActive else {
      contacts[activity.deviceID]?.resolution = .idle
      changed()
      return
    }
    let operation = UUID(), cancelled = OSAllocatedUnfairLock(initialState: false)
    contacts[activity.deviceID]?.resolution = .resolving(operation, cancelled)
    changed()
    persistence.enqueueCommand { store in
      guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
      return try store.inputScopes(for: activity.targets)
    } completion: { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self, !stopped, let contact = contacts[activity.deviceID],
          contact.activity == activity, case .resolving(let current, _) = contact.resolution,
          current == operation else { return }
        switch result {
        case .success(let scopes): contacts[activity.deviceID]?.resolution = .resolved(scopes)
        case .failure(let error):
          contacts[activity.deviceID]?.resolution = .failed(error)
          onFailure?(error)
        }
        changed()
      }
    }
  }

  private func cancelLookup(_ id: UUID) {
    if case .resolving(_, let cancelled) = contacts[id]?.resolution {
      cancelled.withLock { $0 = true }
    }
  }

  private func changed() {
    isActive = contacts.values.contains { $0.activity.isActive }
    resumeWaiters()
    onChange?()
  }

  private func result(for waiter: Waiter) -> Result<Void, Error>? {
    if stopped || waiter.navigation.map({ $0 != navigation }) == true { return .failure(CancellationError()) }
    for contact in contacts.values {
      if case .failed(let error) = contact.resolution { return .failure(error) }
    }
    return allows(waiter.target, carrier: waiter.carrier, scope: waiter.scope) ? .success(()) : nil
  }

  private func resumeWaiters() {
    for (id, waiter) in waiters {
      if let result = result(for: waiter) { finish(id, with: result) }
    }
  }

  private func finish(_ id: UUID, with result: Result<Void, Error>) {
    waiters.removeValue(forKey: id)?.continuation.resume(with: result)
  }

  isolated deinit { stop() }
}
