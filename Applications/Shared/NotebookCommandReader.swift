import Foundation
import NotebookCore

/// The installed workspace owns one serial reader beside its accepted writer.
/// Caller cancellation follows the synchronous SQL operation, including work
/// before its first row. Closing joins that operation and releases the handle.
actor NotebookCommandReader {
  private var session: NotebookReadSession?
  nonisolated private let cancellation: NotebookReadCancellation
  init(store: NotebookStore) {
    let session = NotebookReadSession(store: store)
    self.session = session; cancellation = session.cancellation
  }

  func read<Value: Sendable>(workspaceID: UUID,
    _ operation: @Sendable (NotebookQueryCut) throws -> Value) throws -> Value {
    try Task.checkCancellation()
    guard let session else { throw CancellationError() }
    let value = try session.observe { cut in
      guard try cut.storedWorkspaceID() == workspaceID else {
        throw CollaborationError("workspace_changed", "Читатель принадлежит другому рабочему пространству.")
      }
      return try operation(cut)
    }
    try Task.checkCancellation()
    return value
  }

  nonisolated func stop() { cancellation.cancel() }
  func close() { stop(); session = nil }
}
