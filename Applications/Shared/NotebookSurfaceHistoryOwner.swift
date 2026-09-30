import Foundation
import NotebookCore

/// History intents reserve their inverse before returning to the next contact.
/// The bounded pending directory projects accepted commands until their writer
/// receipts advance the canonical history; it owns no material or scene reads.
@MainActor final class NotebookSurfaceHistoryOwner {
  private struct Command {
    let request: UUID
    let domain: PencilUndoHistory.Domain
    let original: UUID
    let repeated: UUID?
  }
  @MainActor private final class Boundary {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func resolve(_ result: Bool) {
      guard self.result == nil else { return }
      self.result = result; let waiter = waiter; self.waiter = nil
      waiter?.resume(returning: result)
    }
    func wait() async -> Bool {
      if let result { return result }
      return await withCheckedContinuation { waiter = $0 }
    }
  }
  private(set) var pending: Task<Bool, Never>?
  private var tail: Task<Bool, Never>?
  private var boundaries: [UUID: Boundary] = [:]
  private var writerBlocked = false
  private var latestRequest: UUID?
  private var commands: [Command] = []
  private var unreserved: Set<UUID> = []
  private var requestCount = 0

  func accept(redo: Bool, domain: PencilUndoHistory.Domain,
    history: @escaping @MainActor () -> PencilUndoHistory,
    after prepare: (@MainActor () async -> Bool)?,
    apply: @escaping @MainActor (Bool, PencilUndoHistory.Domain, PencilUndoHistory,
      UUID, Task<Bool, Never>?) -> Task<Bool, Never>?,
    onOverflow: @MainActor () -> Void) {
    guard requestCount < 32 else { onOverflow(); return }
    let previous = tail, request = UUID()
    if prepare != nil || !unreserved.isEmpty {
      // Source-editor input has its own commit reservation. Later history
      // cannot occupy the writer ahead of that not-yet-reserved source commit:
      // doing so would make the writer and editor await each other.
      unreserved.insert(request)
      begin(request)
      tail = Task { [self] in
        if let previous, !(await previous.value) { finish(request, result: false); return false }
        if let prepare, !(await prepare()) { finish(request, result: false); return false }
        unreserved.remove(request)
        let cut = projected(history())
        let command = apply(redo, domain, cut, request, nil)
        retain(request, redo: redo, domain: domain, history: cut)
        let result = await command?.value ?? true
        finish(request, result: result)
        return result
      }
      return
    }
    let cut = projected(history())
    let command = apply(redo, domain, cut, request, previous)
    guard let command else { return } // Ink advanced its journal synchronously.
    retain(request, redo: redo, domain: domain, history: cut)
    begin(request)
    tail = Task { [self] in
      let result = await command.value
      finish(request, result: result)
      return result
    }
  }

  private func projected(_ current: PencilUndoHistory) -> PencilUndoHistory {
    var result = current
    for command in commands {
      if let repeated = command.repeated {
        _ = result.recordRepeatedCommand(domain: command.domain,
          originalID: command.original, actionID: repeated)
      } else { result.didUndoCommand(domain: command.domain, actionID: command.original) }
    }
    return result
  }
  private func retain(_ request: UUID, redo: Bool, domain: PencilUndoHistory.Domain, history: PencilUndoHistory) {
    guard let original = redo ? history.lastRedoCommand(for: domain) : history.lastCommand(for: domain) else { return }
    commands.append(.init(request: request, domain: domain, original: original, repeated: redo ? request : nil))
  }
  /// Disk failure releases observers, while accepted commands and their exact
  /// dependencies remain in the writer for retry. Retry installs a fresh wait
  /// for the same tail, never another inverse or another history directory.
  func setWriterBlocked(_ blocked: Bool) {
    guard writerBlocked != blocked else { return }
    writerBlocked = blocked
    if blocked { for boundary in boundaries.values { boundary.resolve(false) } }
    else if let request = latestRequest, boundaries[request] != nil { installBoundary(request) }
  }
  private func begin(_ request: UUID) {
    requestCount += 1; latestRequest = request
    installBoundary(request)
  }
  private func installBoundary(_ request: UUID) {
    let boundary = Boundary(); boundaries[request] = boundary
    if writerBlocked { boundary.resolve(false) }
    pending = Task { await boundary.wait() }
  }
  private func finish(_ request: UUID, result: Bool) {
    boundaries.removeValue(forKey: request)?.resolve(result)
    commands.removeAll { $0.request == request }
    unreserved.remove(request)
    requestCount -= 1
    if latestRequest == request { pending = nil; tail = nil; latestRequest = nil }
  }
}
