import Foundation
import NotebookCore

extension NotebookStore {
  /// Fixtures exercise the same retained lifecycle command as the native UI.
  @discardableResult
  func deleteTestItem(itemID: UUID, actor: UUID) throws -> NotebookWorkspaceHeader {
    guard let source = try readItemLifecycle(itemID),
      let placement = try readBoardItem(itemID)?.board.placements.first(where: { $0.id == itemID }) else {
      throw CollaborationError("target_missing", "Fixture item is absent")
    }
    _ = try NotebookNativeCommand(deleting: source, placement: placement, actor: actor).apply(to: self)
    if let presence = try? loadPresence(), presence.selectedItemID == itemID, let replacement = try readItemHeaders(limit: 1).first {
      try savePresence(presence.selecting(itemID: replacement.id, pageID: replacement.firstPageID))
    }
    return try workspaceHeader()
  }
}
