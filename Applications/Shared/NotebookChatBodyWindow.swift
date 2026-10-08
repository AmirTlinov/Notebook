#if os(iOS)
import Foundation
import NotebookCore

/// Numeric lifetime of the existing chat's bodies. Controller and physical WK
/// publication share ARC credits; neither owns another transcript here.
final class NotebookChatBodyWindow: @unchecked Sendable {
  static let maximumBytes = 16 * 1_048_576
  private let lock = NSLock()
  private var bodies: [UUID: Int] = [:]
  private var bytes = 0
  private var assembly: UUID?
  private struct Waiter {
    let id: UUID, bytes: Int
    let continuation: CheckedContinuation<Credit, Error>
  }
  private var waiter: Waiter?
  var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }

  func reserve(_ count: Int) -> Credit? {
    lock.lock(); defer { lock.unlock() }
    guard count > 0, count <= Self.maximumBytes - bytes else { return nil }
    return insert(count)
  }
  func reserveAfterPublicationDrain(_ count: Int) async throws -> Credit {
    guard count > 0, count <= CodexMessageTransfer.maximumBytes else { throw NotebookTransportError.invalidAcknowledgement }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()) }
        else if count <= Self.maximumBytes - bytes {
          let credit = insert(count); lock.unlock(); continuation.resume(returning: credit)
        } else if waiter == nil {
          // One existing contentRead can wait for its old physical publication.
          waiter = .init(id: id, bytes: count, continuation: continuation); lock.unlock()
        } else { lock.unlock(); continuation.resume(throwing: NotebookTransportError.invalidAcknowledgement) }
      }
    } onCancel: { self.cancelWaiter(id) }
  }
  func reserveAssembly() throws -> Assembly {
    lock.lock(); defer { lock.unlock() }
    guard assembly == nil else { throw NotebookTransportError.invalidAcknowledgement }
    let id = UUID(); assembly = id; return Assembly(owner: self, id: id)
  }
  private func insert(_ count: Int) -> Credit {
    let id = UUID(); bodies[id] = count; bytes += count
    return Credit(owner: self, id: id)
  }
  private func release(_ id: UUID) {
    lock.lock()
    if let count = bodies.removeValue(forKey: id) { bytes -= count }
    let ready = waiter.flatMap { $0.bytes <= Self.maximumBytes - bytes ? $0 : nil }
    let credit = ready.map { insert($0.bytes) }
    if ready != nil { waiter = nil }
    lock.unlock()
    if let ready, let credit { ready.continuation.resume(returning: credit) }
  }
  private func cancelWaiter(_ id: UUID) {
    lock.lock(); let current = waiter?.id == id ? waiter : nil
    if current != nil { waiter = nil }; lock.unlock()
    current?.continuation.resume(throwing: CancellationError())
  }
  private func releaseAssembly(_ id: UUID) {
    lock.lock(); defer { lock.unlock() }; if assembly == id { assembly = nil }
  }
  final class Credit: Sendable {
    private let owner: NotebookChatBodyWindow
    private let id: UUID
    fileprivate init(owner: NotebookChatBodyWindow, id: UUID) { self.owner = owner; self.id = id }
    deinit { owner.release(id) }
  }
  final class Assembly: Sendable {
    private let owner: NotebookChatBodyWindow
    private let id: UUID
    fileprivate init(owner: NotebookChatBodyWindow, id: UUID) { self.owner = owner; self.id = id }
    deinit { owner.releaseAssembly(id) }
  }
}
#endif
