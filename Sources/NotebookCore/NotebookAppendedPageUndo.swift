import Foundation

struct NotebookAppendedPageUndoPreparation {
  struct Page {
    let target: CollaborationTarget
    let pageID: UUID
    let position: Int
  }
  let pages: [Page]
  let preserved: [CollaborationTarget]
  fileprivate let connection: ObjectIdentifier
}

extension NotebookStore {
  /// Must precede this action's own ordinary/ink inverses. The whole physical
  /// page, including hidden sources and losing causal observations, is checked
  /// against the authenticated postimage before any of our undo edits occur.
  func prepareAppendedNotebookPageUndo(receipt: CollaborationReceipt) throws -> NotebookAppendedPageUndoPreparation {
    guard let database = currentSQL, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    let appended = (receipt.lifecycleChanges ?? []).filter { $0.kind == .appendPage }
    guard appended.count <= 512 else { throw NotebookStorageError.limitExceeded("appended_page_undo_count") }
    guard !appended.isEmpty else { return .init(pages: [], preserved: [], connection: ObjectIdentifier(database)) }
    guard let inverse = receipt.lifecycleInverse else { throw NotebookStorageError.invalidTransaction("missing appended page inverse") }
    let evidence = AppendedPageUndoEvidence(store: self, database: database, receipt: receipt)
    try evidence.prepare(inverse)
    defer { try? evidence.clear() }
    var pages: [NotebookAppendedPageUndoPreparation.Page] = [], preserved: [CollaborationTarget] = [], seen = Set<UUID>()
    func preserve(_ target: CollaborationTarget) { if !preserved.contains(target) { preserved.append(target) } }
    for change in appended {
      guard let pageID = change.pageID, seen.insert(pageID).inserted else {
        throw NotebookStorageError.invalidTransaction("duplicate appended page inverse")
      }
      if let page = try evidence.preflight(change) { pages.append(page) }
      else { preserve(change.target) }
    }
    // A later edit may have removed the old pages. Even then an undo cannot
    // leave the surviving notebook empty. Descending positions also ensure
    // that removal of one planned page never shifts another planned slot.
    pages.sort { $0.target.id == $1.target.id ? $0.position > $1.position : $0.target.id.uuidString < $1.target.id.uuidString }
    var remaining: [UUID: Int] = [:], allowed: [NotebookAppendedPageUndoPreparation.Page] = []
    for page in pages {
      let count = try remaining[page.target.id] ?? pageCount(in: page.target.id)
      if count > 1 { allowed.append(page); remaining[page.target.id] = count - 1 }
      else { preserve(page.target) }
    }
    return .init(pages: allowed, preserved: preserved, connection: ObjectIdentifier(database))
  }

  /// Called inside the same writer and its existing combined undo capture.
  /// It does not open a capture, refresh a read basis, or mutate local presence.
  func publishAppendedNotebookPageUndo(_ prepared: NotebookAppendedPageUndoPreparation,
    actor: UUID) throws -> [NotebookLifecycleUndoChange] {
    guard let database = currentSQL, database.writable, ObjectIdentifier(database) == prepared.connection,
      database.activeActionRecordCapture != nil else { throw NotebookStorageError.invalidTransaction("appended page undo writer") }
    var changes: [NotebookLifecycleUndoChange] = []
    for page in prepared.pages {
      let itemID = page.target.id, item = itemID.uuidString.lowercased(), id = page.pageID.uuidString.lowercased()
      let parent = "workspace.json#/items/@" + item, address = parent + "/pageIDs/@" + id
      guard let membership = try storedFragments(address: address, descendants: false).first,
        try ownerItemID(ofPage: page.pageID) == itemID, try ownerBoardID(of: itemID) == page.target.boardID,
        try pageCount(in: itemID) > 1,
        let workspace = try storedFragments(address: "workspace.json#", descendants: false).first,
        let currentStamp = try workspace.value["stamp"]?.decode(VersionStamp.self) else {
        throw NotebookStorageError.invalidTransaction("prepared page undo owner changed")
      }
      let order = try readPageOrder(itemID)
      guard try NotebookPageOrderVector.pageID(at: membership.position, in: order.visibleRoot,
        read: { try readPageOrderNode($0) }) == page.pageID else {
        throw NotebookStorageError.invalidTransaction("prepared page undo position")
      }
      let keys = [fieldKey(["items", item, "exists"]), fieldKey(["items", item, "pageIDs"]), fieldKey(["items", item, "pageIDs", id])]
      let versions = try keys.map { key in
        try storedFragments(address: AppendedPageUndoEvidence.fieldAddress(key), descendants: false).first?.value.decode(ContentFieldVersion.self)
      }
      guard versions.allSatisfy({ $0?.isValid == true }) else { throw NotebookStorageError.invalidTransaction("page undo causal fields") }
      var counter = currentStamp.counter
      for version in versions.compactMap({ $0 }) + order.heads.map(\.version) {
        counter = max(counter, max(version.stamp.counter, version.observed.values.max() ?? 0))
      }
      guard let stamp = VersionStamp(counter: counter, actor: actor).advanced(by: actor) else { throw NotebookStorageError.limitExceeded("page_undo_clock") }
      let root = try NotebookPageOrderVector.remove(at: membership.position, from: order.visibleRoot,
        read: { try readPageOrderNode($0) }, write: { try writePageOrderNode($0) })
      try removeFragment(pageFile(page.pageID) + "#", database: database)
      try removeFragment(address, database: database)
      // Positions are derived slots. Rewrite only the displaced suffix, one
      // addressed batch at a time; an unchanged prefix is never enumerated.
      var position = membership.position
      while true {
        let rows = try database.rows("SELECT address,position FROM records INDEXED BY record_order WHERE parent=? AND collection='pageIDs' AND position>? ORDER BY position,member LIMIT 64",
          [.text(parent), .integer(Int64(position))])
        guard let last = rows.last?[1].integer else { break }
        for row in rows {
          let member = try storedFragments(address: row[0].text!, descendants: false).first!
          try writeFragment(member.replacing(value: member.value, position: member.position - 1), database: database)
        }
        position = Int(last)
      }
      let next = try NotebookPageOrderRegister.authored(root: root, stamp: stamp, human: true, previous: order)
      try writePageOrder(next, itemID: itemID)
      for (offset, key) in keys.enumerated() {
        let version = offset == 1 ? next.fieldVersion : ContentFieldVersion(stamp: stamp, human: true, previous: versions[offset])
        guard version.isValid else { throw NotebookStorageError.limitExceeded("page_undo_causal_actors") }
        try writeFragment(.init(address: AppendedPageUndoEvidence.fieldAddress(key), file: "workspace.json", parent: "workspace.json#",
          collection: "collaboration/fields", member: key, position: 0, value: .encode(version), collections: []), database: database)
      }
      try writeFragment(workspace.replacing(value: workspace.value.setting("stamp", try .encode(stamp))), database: database)
      changes.append(.init(kind: .removePage, target: page.target, pageID: page.pageID, item: try readItemHeader(itemID)))
    }
    return changes
  }
}

private final class AppendedPageUndoEvidence {
  let store: NotebookStore
  let database: NotebookSQLConnection
  let receipt: CollaborationReceipt

  init(store: NotebookStore, database: NotebookSQLConnection, receipt: CollaborationReceipt) {
    self.store = store; self.database = database; self.receipt = receipt
  }

  static func fieldAddress(_ key: String) -> String { "workspace.json#/collaboration/fields/@" + fieldKey([key]) }

  func prepare(_ inverse: NotebookLifecycleInverseReference) throws {
    try database.run("CREATE TEMP TABLE IF NOT EXISTS appended_page_undo_inverse(address TEXT PRIMARY KEY,file TEXT NOT NULL,before_hash TEXT,after_hash TEXT) WITHOUT ROWID")
    try database.run("CREATE INDEX IF NOT EXISTS appended_page_undo_inverse_file ON appended_page_undo_inverse(file,address)")
    try clear()
    try store.visitLifecycleInverse(reference: inverse, actionID: receipt.id) { record in
      let file = String(record.address.prefix { $0 != "#" })
      try database.run("INSERT INTO appended_page_undo_inverse VALUES(?,?,?,?)", [.text(record.address), .text(file),
        record.beforeHash.map(NotebookSQLValue.text) ?? .null, record.afterHash.map(NotebookSQLValue.text) ?? .null])
    }
  }

  func clear() throws { try database.run("DELETE FROM appended_page_undo_inverse") }

  private func born(_ address: String) throws -> NotebookStoredFragment {
    guard let row = try database.rows("SELECT before_hash,after_hash FROM appended_page_undo_inverse WHERE address=?", [.text(address)]).first,
      row[0].text == nil, let hash = row[1].text else { throw NotebookStorageError.invalidTransaction("unauthenticated page birth") }
    return try store.readLifecycleInverseFragment(hash: hash, address: address)
  }

  func preflight(_ change: NotebookLifecycleChange) throws -> NotebookAppendedPageUndoPreparation.Page? {
    guard change.target.kind == .cover, let boardID = change.target.boardID, let pageID = change.pageID,
      change.afterItem?.id == change.target.id, change.afterItem?.kind == .notebook,
      receipt.action.operations.contains(where: { $0.kind == .appendPage && $0.target == change.target && $0.id.flatMap(UUID.init(uuidString:)) == pageID }) else {
      throw NotebookStorageError.invalidTransaction("appended page inverse target")
    }
    let item = change.target.id.uuidString.lowercased(), id = pageID.uuidString.lowercased()
    let parent = "workspace.json#/items/@" + item, address = parent + "/pageIDs/@" + id, file = pageFile(pageID)
    let membership = try born(address), page = try born(file + "#")
    guard membership.parent == parent, membership.collection == "pageIDs", membership.member == id,
      membership.value.string.flatMap(UUID.init(uuidString:)) == pageID, membership.collections.isEmpty,
      page.value["id"]?.string.flatMap(UUID.init(uuidString:)) == pageID,
      page.value["format"] == .number(Double(PageDocument.formatVersion)),
      try page.value["size"]?.decode(PageSize.self).isValid == true,
      page.collections.contains(.init(path: ["drawingData"], kind: .pageInk)),
      page.collections.contains(.init(path: ["elements"], kind: .array)) else {
      throw NotebookStorageError.invalidTransaction("appended page source identity")
    }
    _ = try born(file + "#/drawingData")
    guard try database.rows("SELECT 1 FROM appended_page_undo_inverse WHERE file=? AND before_hash IS NOT NULL LIMIT 1", [.text(file)]).isEmpty else {
      throw NotebookStorageError.invalidTransaction("appended page had prior content")
    }
    let birthKey = fieldKey(["items", item, "pageIDs", id]), birthAddress = Self.fieldAddress(birthKey)
    let birth = try born(birthAddress).value.decode(ContentFieldVersion.self)
    guard birth.isValid else { throw NotebookStorageError.invalidTransaction("appended page birth version") }
    guard try store.ownerBoardID(of: change.target.id) == boardID,
      try store.ownerItemID(ofPage: pageID) == change.target.id,
      let currentMembership = try store.storedFragments(address: address, descendants: false).first,
      currentMembership.value == membership.value else { return nil }
    let currentBirth = try store.storedFragments(address: birthAddress, descendants: false).first?.value.decode(ContentFieldVersion.self)
    guard try store.fieldIsOwned(currentBirth, by: .init(file: "workspace.json",
      path: [.field("collaboration"), .field("fields"), .field(birthKey)], before: nil, after: nil, afterVersion: birth),
      requiringExactVersion: true) else { return nil }
    let order = try store.readPageOrder(change.target.id)
    guard try NotebookPageOrderVector.pageID(at: currentMembership.position, in: order.visibleRoot,
      read: { try store.readPageOrderNode($0) }) == pageID else { throw NotebookStorageError.invalidTransaction("appended page live membership") }
    // Compare both directions, including newly inserted, removed and changed
    // causal/source rows. No decoded/rendered winner substitutes for provenance.
    let changed = try database.rows("SELECT 1 FROM records r LEFT JOIN appended_page_undo_inverse i ON i.address=r.address WHERE r.file=? AND (i.after_hash IS NULL OR r.hash!=i.after_hash) LIMIT 1", [.text(file)])
    let missing = try database.rows("SELECT 1 FROM appended_page_undo_inverse i LEFT JOIN records r ON r.address=i.address WHERE i.file=? AND i.after_hash IS NOT NULL AND (r.hash IS NULL OR r.hash!=i.after_hash) LIMIT 1", [.text(file)])
    guard changed.isEmpty, missing.isEmpty else { return nil }
    return .init(target: change.target, pageID: pageID, position: currentMembership.position)
  }
}
