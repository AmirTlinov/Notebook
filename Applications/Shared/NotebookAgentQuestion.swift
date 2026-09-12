import Foundation
import NotebookCore

/// Immutable evidence attached to NotebookSelectionSession. The composer reads
/// this value from that session; it does not keep another current selection.
struct NotebookAgentQuestion: Equatable, Sendable, Identifiable {
  let contextID: UUID
  let entryID: UUID
  let references: [CollaborationReference]
  var id: UUID { contextID }
}
