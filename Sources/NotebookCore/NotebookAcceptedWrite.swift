import Foundation

/// The native writer may close a refused slot only after its transaction has
/// proved rollback. A failed storage/commit response keeps the accepted payload.
public struct NotebookAcceptedWriteError: Error, LocalizedError, Sendable {
  public enum Outcome: Sendable { case rejected, storageUnavailable, unresolved }
  public let outcome: Outcome
  public let underlying: Error
  public var errorDescription: String? { underlying.localizedDescription }

  init(_ outcome: Outcome, _ underlying: Error) {
    self.outcome = outcome; self.underlying = underlying
  }

  /// These diagnostics describe command validation, never disk availability.
  /// The successful outer rollback supplies their definitive outcome evidence.
  static func isDomainRefusal(_ error: Error) -> Bool {
    switch error {
    case let error as NotebookAcceptedWriteError: return error.outcome == .rejected
    case let error as NotebookStorageError:
      switch error {
      case .invalidTransaction, .transactionConflict, .readOnlyTransaction, .limitExceeded: return true
      default: return false
      }
    case is NotebookStoreError: return true
    case is PageInkDrawing.InkError: return true
    case let error as CollaborationError:
      switch error.code {
      case "storage_error", "operation_failed", "conversion_required", "unsupported_format",
        "format_checkpoint_required", "publication_pending", "edit_receipt_unavailable",
        "action_version_unavailable", "request_identity_unavailable", "ipc_timeout": return false
      default: return true
      }
    default: return false
    }
  }
}

extension NotebookStore {
  /// Preparation and waiting belong outside this synchronous scope. Nested
  /// Core methods borrow this transaction, so one accepted command commits once.
  public func acceptedWrite<Value>(_ operation: (NotebookStore) throws -> Value) throws -> Value {
    try commandTransaction(attestsAcceptedOutcome: true) { try operation(self) }
  }
}
