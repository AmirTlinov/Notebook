import Foundation
import NotebookCore
@testable import Notebook

extension NotebookWorkspaceLibrary {
  /// Fixture setup completes the same retained ticket API as launch.
  func selectFixture(_ id: UUID, name: String? = nil) throws -> URL {
    let ticket = try prepareSelection(id, name: name)
    switch commitSelection(ticket) {
    case .committed: finishSelection(ticket); return ticket.root
    case .rejected(let message), .unresolved(let message): throw NotebookStorageError.invalidTransaction(message)
    }
  }
}
