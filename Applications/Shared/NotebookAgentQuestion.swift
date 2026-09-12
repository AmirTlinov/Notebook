import Foundation
import NotebookCore

/// A composer keeps the physical address of its own question. Receiving an
/// answer changes neither first responder nor the current camera/selection.
struct NotebookAgentQuestion: Equatable, Sendable, Identifiable {
  let contextID: UUID
  let entryID: UUID
  let references: [CollaborationReference]
  var id: UUID { contextID }
}
