import Foundation
import NotebookCore

/// The installed workspace owns one serial reader beside its accepted writer.
/// Caller cancellation follows the synchronous SQL operation, including work
/// before its first row. Closing joins that operation and releases the handle.
actor NotebookCommandReader {
  struct Observation<Value: Sendable>: Sendable {
    let connectionLifetimeID: UUID
    let value: Value
  }
  private var session: NotebookReadSession?
  nonisolated private let cancellation: NotebookReadCancellation
  init(store: NotebookStore) {
    let session = NotebookReadSession(store: store)
    self.session = session; cancellation = session.cancellation
  }

  func read<Value: Sendable>(workspaceID: UUID,
    _ operation: @Sendable (NotebookQueryCut) throws -> Value) throws -> Value {
    try observe(workspaceID: workspaceID, operation).value
  }

  func observe<Value: Sendable>(workspaceID: UUID,
    _ operation: @Sendable (NotebookQueryCut) throws -> Value) throws -> Observation<Value> {
    try Task.checkCancellation()
    guard let session else { throw CancellationError() }
    let value = try session.observe { cut in
      guard try cut.storedWorkspaceID() == workspaceID else {
        throw CollaborationError("workspace_changed", "Читатель принадлежит другому рабочему пространству.")
      }
      return try operation(cut)
    }
    try Task.checkCancellation()
    guard let lifetime = session.connectionLifetimeID else {
      throw CollaborationError("read_cut_expired", "Соединение читателя завершено.")
    }
    return .init(connectionLifetimeID: lifetime, value: value)
  }

  nonisolated func stop() { cancellation.cancel() }
  func close() { stop(); session = nil }
}
