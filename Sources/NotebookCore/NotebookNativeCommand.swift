import Foundation

/// An accepted command retains its exact committed output across an uncertain
/// response. Neither element nor placement edits may borrow a newer peer value
/// when their dependent native contact resumes.
public final class NotebookNativeCommand<Source: Sendable>: @unchecked Sendable {
  public typealias Output = (receipt: CollaborationReceipt, sources: [Source])
  private let lock = NSLock()
  private var prepared: Output?
  private let operation: (NotebookStore, (Output) -> Void) throws -> Output

  init(operation: @escaping (NotebookStore, (Output) -> Void) throws -> Output) {
    self.operation = operation
  }

  public func apply(to store: NotebookStore) throws -> Output {
    lock.lock(); defer { lock.unlock() }
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
