import Foundation

/// A document program addresses one state record. The admitted scene value
/// can exceed a raster window; its writer still owns a finite decode/codec cut.
public struct NotebookDocumentStateWriteAllowance: Sendable {
  public static let maximumExecutionBytes = 192 * 1_024 * 1_024
  public let executionBytes: Int

  public init(executionBytes: Int) { self.executionBytes = executionBytes }

  func readAllowance() throws -> NotebookSQLReadAllowance {
    guard executionBytes > 0, executionBytes <= Self.maximumExecutionBytes else {
      throw CollaborationError("resource_limit", "Состояние программы превышает резерв записи.")
    }
    // allocationCost includes the wire buffers inside its eightfold estimate.
    // SQL and decoding are phase caps over the same accepted finish credit.
    let source = executionBytes / 2
    return .init(rows: min(4_096, source / 64), bytes: source, valueBytes: source,
      reason: "resource_limit", jsonDecodeBytes: executionBytes)
  }
}

extension NotebookStore {
  public func withDocumentStateWriteAllowance<T>(_ allowance: NotebookDocumentStateWriteAllowance,
    _ body: () throws -> T) throws -> T {
    do { return try commandTransaction(readAllowance: allowance.readAllowance(), body) }
    catch NotebookStorageError.limitExceeded {
      throw CollaborationError("resource_limit", "Состояние программы превышает резерв записи.")
    }
  }
}
