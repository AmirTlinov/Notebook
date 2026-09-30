import Foundation

/// Early program preparation owns accepted immutable source, while bootstrap
/// still owns durable presence and the account cut. Authored state messages
/// retain their existing completion/credit until that one boundary resolves.
@MainActor
final class NotebookBootstrapAdmission {
  private struct ProgramWrite {
    let id: UUID
    let accept: @MainActor () -> Void
    let reject: @MainActor () -> Void
  }
  private var pending: [ProgramWrite] = []
  private var outcome: Bool?
  var wasAccepted: Bool { outcome == true }

  func deferProgramWrite(accept: @escaping @MainActor () -> Void,
    reject: @escaping @MainActor () -> Void) -> Bool {
    guard outcome == nil else { return false }
    pending.append(.init(id: UUID(), accept: accept, reject: reject))
    return true
  }

  /// Document state enters through an async writer. Cancellation withdraws
  /// this admission wait; it never retracts a subsequently accepted disk write.
  func waitForProgramWrites() async -> Bool {
    guard !Task.isCancelled else { return false }
    if let outcome { return outcome }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: false); return }
        if let outcome { continuation.resume(returning: outcome); return }
        pending.append(.init(id: id, accept: { continuation.resume(returning: true) },
          reject: { continuation.resume(returning: false) }))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelProgramWait(id) }
    }
  }

  private func cancelProgramWait(_ id: UUID) {
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
    pending.remove(at: index).reject()
  }

  func resolve(acceptsWrites: Bool) {
    guard outcome == nil else { return }
    outcome = acceptsWrites
    let writes = pending; pending.removeAll()
    for write in writes {
      if acceptsWrites { write.accept() } else { write.reject() }
    }
  }

  isolated deinit {
    for write in pending { write.reject() }
  }
}
