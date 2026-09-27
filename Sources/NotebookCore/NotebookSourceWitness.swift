import Foundation

/// Bounded source identities from one WAL cut. Metadata, transport receipts and
/// camera clocks do not invalidate a prepared body. Missing owners are witnesses
/// too, so removal/transfer and insertion cannot resurrect a retired surface.
public struct NotebookSourceWitness: Sendable {
  struct Item: Equatable, Sendable {
    let header: NotebookItemHeader?
    let owner: UUID?
    let order: String?
  }
  let workspaceID: UUID
  let rootBoardID: UUID
  let items: [UUID: Item]
  let pages: [UUID: String]
  let files: [String: String]
  let boards: [UUID: String]

  public func isCurrent(_ store: NotebookStore) throws -> Bool {
    try store.readTransaction { _ in
      let current = try store.readSourceWitness(itemIDs: Set(items.keys), pageIDs: Set(pages.keys),
        boardIDs: Set(boards.keys), documentIDs: [])
      guard workspaceID == current.workspaceID, rootBoardID == current.rootBoardID, items == current.items,
        pages == current.pages, boards == current.boards else { return false }
      for (file, digest) in files where try store.sourceFileIdentity(file) != digest { return false }
      return true
    }
  }
}

extension NotebookStore {
  func sourceFileIdentity(_ file: String) throws -> String {
    guard let row = try currentSQL!.rows("SELECT digest,record_count FROM lifecycle_files WHERE file=?", [.text(file)]).first else { return "missing" }
    guard let count = row[1].integer, count > 0, let digest = row[0].blob, digest.count == 32 else {
      throw NotebookStorageError.corruptRecord("prepared source identity")
    }
    return String(count) + ":" + NotebookHexEncoding.encode(digest)
  }

  public func readSourceWitness(itemIDs: Set<UUID>, pageIDs: Set<UUID>, boardIDs: Set<UUID>, documentIDs: Set<UUID>) throws -> NotebookSourceWitness {
    try readTransaction { _ in
      var items: [UUID: NotebookSourceWitness.Item] = [:], pages: [UUID: String] = [:]
      var files: [String: String] = [:], boards: [UUID: String] = [:]
      for id in itemIDs.union(documentIDs) {
        let header = try readItemHeader(id)
        items[id] = try .init(header: header, owner: ownerBoardID(of: id),
          order: header?.kind == .notebook ? readNotebookPageWindow(itemID: id, pages: []).header.visibleRoot : nil)
      }
      for id in pageIDs { pages[id] = try pageSourceRevision(id) ?? "missing" }
      for id in documentIDs {
        for file in [documentFile(id), stateFile(id)] { files[file] = try sourceFileIdentity(file) }
      }
      for id in boardIDs { boards[id] = try boardContentRevision(id) ?? "missing" }
      return try .init(workspaceID: workspaceHeader().workspaceID, rootBoardID: workspaceHeader().rootBoardID, items: items, pages: pages, files: files, boards: boards)
    }
  }
}
