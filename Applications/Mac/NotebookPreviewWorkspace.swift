import Foundation
import NotebookCore

/// An explicit image request borrows source identity and the accepted writer.
/// Offscreen rendering does not require a mounted native scene.
@MainActor
protocol NotebookPreviewWorkspace: AnyObject {
  var store: NotebookStore { get }
  var workspaceHeader: NotebookWorkspaceHeader? { get }
  var observedPresence: SessionPresence? { get }
  var observedPresencePhase: PresencePhase { get }
  var isPeerConnected: Bool { get }
  var permitsBackgroundPreparation: Bool { get }
  var permitsOptionalPreparation: Bool { get }
  func readCommandCut<Value: Sendable>(
    _ operation: @escaping @Sendable (NotebookQueryCut) throws -> Value) async throws -> Value
  func capturePreviewReadFence() -> NotebookPersistenceQueue.ReadFence
  func performStoreCommand<T: Sendable>(publishesChanges: Bool,
    _ operation: @escaping @Sendable (NotebookStore) throws -> T) async throws -> T
}
extension NotebookPreviewWorkspace {
  func performStoreCommand<T: Sendable>(
    _ operation: @escaping @Sendable (NotebookStore) throws -> T) async throws -> T {
    try await performStoreCommand(publishesChanges: false, operation)
  }
}
extension NotebookAppModel: NotebookPreviewWorkspace {}
