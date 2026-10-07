import Foundation

/// An accepted command retains its exact committed output across an uncertain
/// response. Neither element nor placement edits may borrow a newer peer value
/// when their dependent native contact resumes.
public final class NotebookNativeCommand<Source: Sendable>: @unchecked Sendable {
  public typealias Output = (receipt: CollaborationReceipt, sources: [Source])
  private let lock = NSLock()
  private var prepared: Output?
  private let allowance: NotebookNativeWriteAllowance?
  private let workspaceID: UUID?
  private let operation: (NotebookStore, (Output) -> Void) throws -> Output

  init(allowance: NotebookNativeWriteAllowance? = nil, workspaceID: UUID? = nil,
    operation: @escaping (NotebookStore, (Output) -> Void) throws -> Output) {
    self.allowance = allowance
    self.workspaceID = workspaceID
    self.operation = operation
  }

  public func apply(to store: NotebookStore) throws -> Output {
    lock.lock(); defer { lock.unlock() }
    if let allowance {
      return try store.withNativeWriteAllowance(allowance) { try applyRetained(to: store) }
    }
    return try applyRetained(to: store)
  }

  private func applyRetained(to store: NotebookStore) throws -> Output {
    if let workspaceID, try store.storedWorkspaceID() != workspaceID { throw NotebookStoreError.workspaceChanged }
    if let prepared {
      // Absence proves rollback. An unreadable receipt keeps the same command
      // pending; current material is never evidence of its own earlier commit.
      if let saved = try store.collaborationActionIfPresent(prepared.receipt.id) {
        guard saved.action == prepared.receipt.action, saved.author == prepared.receipt.author else {
          throw CollaborationError("action_id_conflict", "Этот ID уже принадлежит другому ходу.")
        }
        return prepared
      }
      self.prepared = nil
    }
    return try operation(store) { self.prepared = $0 }
  }
}
