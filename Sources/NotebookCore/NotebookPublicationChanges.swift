import Foundation

/// A postcommit notice has no projection payload. Readers inspect the local
/// merge journal and its high-water in the same SQLite snapshot.
public struct NotebookPublicationChanges: Sendable {
  public let header: NotebookWorkspaceHeader
  public let pages: Set<UUID>
  public let documents: Set<UUID>
  public let documentStates: Set<UUID>
  public let sceneChanged: Bool
  public let metadataChanged: Bool
  public let needsOwnerRead: Bool
}

extension NotebookStore {
  public func readPublicationChanges(after cursor: UInt64, limit: Int = 256) throws -> NotebookPublicationChanges {
    try readTransaction { _ in
      let header = try workspaceHeader()
      var pages = Set<UUID>(), documents = Set<UUID>(), states = Set<UUID>()
      var scene = false, metadata = false, fallback = false
      do {
        let changes = try readChangedAddresses(after: cursor, through: header.cursor, limit: limit)
        fallback = changes.hasMore
        for record in changes.records where record.beforeHash != record.afterHash {
          let file = record.address.prefix { $0 != "#" }
          let parts = file.split(separator: "/")
          if parts.count == 2, parts[1].hasSuffix(".json"),
            let id = UUID(uuidString: String(parts[1].dropLast(5))) {
            switch parts[0] {
            case "pages": pages.insert(id)
            case "documents": documents.insert(id)
            case "document-states": states.insert(id)
            default: break
            }
          }
          if file == "workspace.json" || file == "board.json" || file == "spatial-ink.json" { scene = true }
          if file.hasPrefix("collaboration/actions/") || file.hasPrefix("collaboration/contexts/")
            || file.hasPrefix("collaboration/delivery/") { metadata = true }
        }
      } catch let error as CollaborationError where error.code == "observation_cursor_expired" {
        fallback = true
      }
      return .init(header: header, pages: pages, documents: documents, documentStates: states,
        sceneChanged: scene, metadataChanged: metadata, needsOwnerRead: fallback)
    }
  }
}
