import Foundation
import NotebookCore

/// Current-view and target previews use the existing ordered writer. Revocation
/// may refuse queued output; admitted output retains its exact files/receipt
/// through an I/O retry. The lock never covers preparation or disk operations.
final class NotebookPreviewPublication<Prepared: Sendable>: @unchecked Sendable {
  private enum State { case queued, revoked, admitted(Prepared) }
  private let lock = NSLock()
  private var state = State.queued

  func revoke() {
    lock.withLock { if case .queued = state { state = .revoked } }
  }

  /// Both initial execution and Retry belong to the same writer slot. Repeating
  /// source validation after a partial file write could abandon its counterpart.
  func publish(preparing prepare: () throws -> Prepared, writing write: (Prepared) throws -> Void) throws {
    let output: Prepared
    switch lock.withLock({ state }) {
    case .revoked: throw Self.cancelled
    case .admitted(let prepared): output = prepared
    case .queued:
      let prepared = try prepare()
      output = try lock.withLock {
        switch state {
        case .revoked: throw Self.cancelled
        case .admitted(let retained): return retained
        case .queued: state = .admitted(prepared); return prepared
        }
      }
    }
    try write(output)
  }

  private static var cancelled: CollaborationError {
    .init("snapshot_cancelled", "Подготовка прежнего изображения отменена.")
  }
}
