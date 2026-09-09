import Foundation

/// An index belongs to one immutable visible order and one completed SQL read.
/// A caller retaining a prepared page keeps its UUID, not just its former slot.
public struct NotebookPagePosition: Codable, Equatable, Sendable {
  public let itemID: UUID
  public let pageID: UUID
  public let index: Int
  public let visibleRoot: String
  public let readCursor: UInt64
}

public enum NotebookPageReadTarget: Codable, Equatable, Sendable {
  case index(Int)
  case page(UUID)
  case selection
}

/// A read projection only. Selection still belongs to SessionPresence; a
/// removed selected UUID remains visible here with no resolved index.
public struct NotebookPageWindowHeader: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let item: NotebookItemHeader
  public let visibleRoot: String
  public let readCursor: UInt64
  public let selectedPageID: UUID?
  public let selectedPageIndex: Int?
}

public struct NotebookPageWindowEntry: Codable, Equatable, Sendable {
  public let position: NotebookPagePosition
  public let document: PageDocument
}

public struct NotebookPageWindow: Codable, Equatable, Sendable {
  public let header: NotebookPageWindowHeader
  public let pages: [NotebookPageWindowEntry]
}

/// A directory row reads only the page's root fragment, never its ink,
/// elements, or causal field collection.
public struct NotebookPageMetadata: Codable, Equatable, Sendable {
  public let position: NotebookPagePosition
  public let size: PageSize
  public let drawingStamp: VersionStamp
  public let agentStamp: VersionStamp
}

public struct NotebookPageDirectory: Codable, Equatable, Sendable {
  public let header: NotebookPageWindowHeader
  public let pages: [NotebookPageMetadata]
  public let nextIndex: Int?
}

extension NotebookStore {
  /// Resolves every requested identity before reading any PageDocument. Missing
  /// requests and duplicate resolved UUIDs fail; no blank substitute is ready.
  public func readNotebookPageWindow(itemID: UUID, pages: [NotebookPageReadTarget],
    expectedVisibleRoot: String? = nil) throws -> NotebookPageWindow {
    guard pages.count <= 4 else { throw NotebookStorageError.limitExceeded("notebook_page_window") }
    return try readTransaction { _ in
      let snapshot = try NotebookPageReadSnapshot(store: self, itemID: itemID, expectedVisibleRoot: expectedVisibleRoot)
      var positions: [NotebookPagePosition] = [], identities = Set<UUID>()
      for target in pages {
        let position: NotebookPagePosition?
        switch target {
        case .index(let index): position = try snapshot.position(at: index)
        case .page(let id): position = try snapshot.position(of: id)
        case .selection:
          position = try snapshot.header.selectedPageID.flatMap { try snapshot.position(of: $0) }
        }
        guard let position else { throw snapshot.missingPage() }
        guard identities.insert(position.pageID).inserted else {
          throw NotebookStorageError.invalidTransaction("duplicate requested notebook pages")
        }
        positions.append(position)
      }
      let documents = try positions.map { position in
        NotebookPageWindowEntry(position: position, document: try loadPage(position.pageID))
      }
      return .init(header: snapshot.header, pages: documents)
    }
  }

  /// A cursor in this directory is an index plus header.visibleRoot. Supplying
  /// that root rejects a reordered sequence rather than repeating/skipping IDs.
  public func readNotebookPageDirectory(itemID: UUID, from index: Int = 0, limit: Int = 32,
    expectedVisibleRoot: String? = nil) throws -> NotebookPageDirectory {
    guard index >= 0 else { throw NotebookStorageError.invalidTransaction("negative page index") }
    guard (1...64).contains(limit) else { throw NotebookStorageError.limitExceeded("notebook_page_directory") }
    return try readTransaction { _ in
      let snapshot = try NotebookPageReadSnapshot(store: self, itemID: itemID, expectedVisibleRoot: expectedVisibleRoot)
      let rows = try currentSQL!.rows("SELECT member,position FROM records INDEXED BY record_order WHERE parent=? AND collection='pageIDs' AND position>=? ORDER BY position,member LIMIT ?",
        [.text(snapshot.itemAddress), .integer(Int64(index)), .integer(Int64(limit))])
      let expectedCount = index < snapshot.header.item.pageCount ? min(limit, snapshot.header.item.pageCount - index) : 0
      guard rows.count == expectedCount else { throw NotebookStorageError.corruptRecord(snapshot.itemAddress) }
      var pages: [NotebookPageMetadata] = []
      for (offset, row) in rows.enumerated() {
        guard let pageID = row[0].text.flatMap(UUID.init(uuidString:)), row[1].integer == Int64(index + offset),
          let position = try snapshot.position(at: index + offset), position.pageID == pageID else {
          throw NotebookStorageError.corruptRecord(snapshot.itemAddress)
        }
        pages.append(try snapshot.metadata(at: position))
      }
      let end = index + pages.count
      return .init(header: snapshot.header, pages: pages, nextIndex: end < snapshot.header.item.pageCount ? end : nil)
    }
  }

  /// Resolves this UUID through its indexed membership, then checks the same
  /// immutable vector slot. A removed UUID is absent, not the new slot occupant.
  public func resolveNotebookPage(_ pageID: UUID, in itemID: UUID,
    expectedVisibleRoot: String? = nil) throws -> NotebookPagePosition? {
    try readTransaction { _ in
      try NotebookPageReadSnapshot(store: self, itemID: itemID, expectedVisibleRoot: expectedVisibleRoot).position(of: pageID)
    }
  }
}

/// Borrows the enclosing synchronous WAL reader. This cache is only a finite
/// read workset; the register/vector and SQL membership remain the order owners.
private final class NotebookPageReadSnapshot {
  let store: NotebookStore
  let itemID: UUID
  let itemAddress: String
  private let workspaceID: UUID
  private let item: NotebookItemHeader
  private let visibleRoot: String
  private let readCursor: UInt64
  private var selectedPageID: UUID?
  private var selectedPageIndex: Int?
  private var nodes: [String: NotebookPageOrderNode] = [:]
  var header: NotebookPageWindowHeader {
    .init(workspaceID: workspaceID, item: item, visibleRoot: visibleRoot, readCursor: readCursor,
      selectedPageID: selectedPageID, selectedPageIndex: selectedPageIndex)
  }

  init(store: NotebookStore, itemID: UUID, expectedVisibleRoot: String?) throws {
    self.store = store; self.itemID = itemID
    itemAddress = "workspace.json#/items/@" + itemID.uuidString.lowercased()
    guard let item = try store.readItemHeader(itemID), item.kind == .notebook else {
      throw CollaborationError("target_missing", "Указанная тетрадь отсутствует.", target: .init(kind: .cover, id: itemID))
    }
    let order = try store.readPageOrder(itemID)
    guard expectedVisibleRoot == nil || expectedVisibleRoot == order.visibleRoot else { throw NotebookStorageError.transactionConflict }
    guard let workspaceID = try store.currentSQL!.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:)) else {
      throw NotebookStorageError.corruptRecord("workspace identity")
    }
    self.workspaceID = workspaceID; self.item = item; visibleRoot = order.visibleRoot
    readCursor = try store.currentReadCursor()
    let root = try node(order.visibleRoot)
    guard root.count == item.pageCount, let first = try position(at: 0), first.pageID == item.firstPageID else {
      throw NotebookStorageError.corruptRecord(itemAddress)
    }
    let presence = try store.hasStoredValue("last-context.json") ? store.loadPresence() : nil
    selectedPageID = presence?.selectedItemID == itemID ? presence?.notebookPageID : nil
    selectedPageIndex = try selectedPageID.flatMap { try position(of: $0)?.index }
  }

  func missingPage() -> CollaborationError {
    .init("target_missing", "Запрошенный лист больше не принадлежит указанной тетради.", target: .init(kind: .cover, id: itemID))
  }

  private func node(_ hash: String) throws -> NotebookPageOrderNode {
    if let node = nodes[hash] { return node }
    // At most 64 directory slots plus first/selection, each at most four
    // nodes. This cache cannot expand to the notebook's full vector.
    guard nodes.count < 264 else { throw NotebookStorageError.limitExceeded("notebook_page_read_nodes") }
    let node = try store.readPageOrderNode(hash)
    nodes[hash] = node; return node
  }

  func position(at index: Int) throws -> NotebookPagePosition? {
    guard index >= 0 else { throw NotebookStorageError.invalidTransaction("negative page index") }
    guard let id = try NotebookPageOrderVector.pageID(at: index, in: header.visibleRoot, read: node) else { return nil }
    let address = itemAddress + "/pageIDs/@" + id.uuidString.lowercased()
    guard try store.currentSQL!.rows("SELECT position FROM records WHERE address=?", [.text(address)]).first?[0].integer == Int64(index) else {
      throw NotebookStorageError.corruptRecord(address)
    }
    return .init(itemID: itemID, pageID: id, index: index, visibleRoot: header.visibleRoot, readCursor: header.readCursor)
  }

  func position(of id: UUID) throws -> NotebookPagePosition? {
    let address = itemAddress + "/pageIDs/@" + id.uuidString.lowercased()
    guard let index = try store.currentSQL!.rows("SELECT position FROM records WHERE address=?", [.text(address)]).first?[0].integer else { return nil }
    guard index >= 0, index < Int64(header.item.pageCount), let position = try position(at: Int(index)), position.pageID == id else {
      throw NotebookStorageError.corruptRecord(address)
    }
    return position
  }

  func metadata(at position: NotebookPagePosition) throws -> NotebookPageMetadata {
    let address = pageFile(position.pageID) + "#"
    guard let value = try store.storedFragments(address: address, descendants: false).first?.value,
      try value["format"]?.decode(Int.self) == PageDocument.formatVersion,
      value["id"]?.string.flatMap(UUID.init(uuidString:)) == position.pageID,
      let size = try value["size"]?.decode(PageSize.self), size.isValid,
      let drawing = try value["drawingStamp"]?.decode(VersionStamp.self), drawing.counter <= VersionStamp.maximumCounter,
      let agent = try value["agentStamp"]?.decode(VersionStamp.self), agent.counter <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.corruptRecord(address)
    }
    return .init(position: position, size: size, drawingStamp: drawing, agentStamp: agent)
  }
}
