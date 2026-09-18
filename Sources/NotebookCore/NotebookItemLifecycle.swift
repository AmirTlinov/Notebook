import CryptoKit
import Foundation

/// A destructive read names the complete item extent, independently of its
/// visible cover. It is a precondition, never authority to delete the item.
public struct NotebookItemLifecycle: Codable, Equatable, Sendable {
  public let item: NotebookItemHeader
  public let target: CollaborationTarget
  public let revision: String
  public let bodyRecordCount: Int
}

extension NotebookStore {
  public func readItemLifecycle(_ id: UUID) throws -> NotebookItemLifecycle? {
    try readTransaction { _ in
      if let database = currentSQL, database.writable { try refreshItemLifecycleIndex(database: database) }
      guard let item = try readItemHeader(id), let board = try ownerBoardID(of: id) else { return nil }
      let target = CollaborationTarget(kind: .cover, id: id, boardID: board)
      let itemID = id.uuidString.lowercased(), database = currentSQL!
      let extent = try database.rows("SELECT digest,file_count,record_count FROM lifecycle_items WHERE item_id=?", [.text(itemID)]).first
      let fileCount = extent?[1].integer ?? 0, count = extent?[2].integer ?? 0
      guard count >= 0, item.kind != .notebook || fileCount == Int64(item.pageCount) else {
        throw NotebookStorageError.corruptRecord("item lifecycle extent")
      }
      let headers = try database.rows("SELECT address,hash FROM records WHERE address IN (?,?) ORDER BY address",
        [.text("workspace.json#/items/@" + itemID), .text("workspace.json#/pageOrders/@" + itemID)])
      let value: JSONValue = .object([
        "format": .number(1), "itemID": .string(itemID),
        "headers": .array(headers.map { .array([.string($0[0].text!), .string($0[1].text!)]) }),
        "bodyDigest": .string((extent?[0].blob ?? Data(repeating: 0, count: 32)).hexadecimal),
        "bodyRecordCount": .number(Double(count)), "fileCount": .number(Double(fileCount)),
        "coverRevision": .string(try referenceRevision(target: target)),
        "childBoardRevision": try item.kind == .board ? boardContentRevision(id).map(JSONValue.string) ?? .null : .null
      ])
      return try .init(item: item, target: target, revision: collaborationHash(value), bodyRecordCount: Int(count))
    }
  }

  static func createItemLifecycleIndex(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE IF NOT EXISTS lifecycle_files(file TEXT PRIMARY KEY,digest BLOB NOT NULL CHECK(length(digest)=32),record_count INTEGER NOT NULL CHECK(record_count>0))")
    try database.run("CREATE TABLE IF NOT EXISTS lifecycle_members(file TEXT PRIMARY KEY,item_id TEXT NOT NULL,hash TEXT NOT NULL,record_count INTEGER NOT NULL)")
    try database.run("CREATE INDEX IF NOT EXISTS lifecycle_member_item ON lifecycle_members(item_id,file)")
    try database.run("CREATE TABLE IF NOT EXISTS lifecycle_items(item_id TEXT PRIMARY KEY,digest BLOB NOT NULL CHECK(length(digest)=32),file_count INTEGER NOT NULL CHECK(file_count>=0),record_count INTEGER NOT NULL CHECK(record_count>=0))")
  }

  /// Fold raw addressed hashes, including causal metadata. A page edit never
  /// visits another page, and a header read never visits any page body.
  func noteItemLifecycleChange(address: String, file: String, collection: String, member: String,
    previous: String?, next: String?, database: NotebookSQLConnection) throws {
    if file == "workspace.json", collection == "pageIDs", let id = UUID(uuidString: member) {
      try database.noteOwner(.lifecycleFile, pageFile(id))
    }
    if file == "workspace.json", collection == "items", let id = UUID(uuidString: member) {
      try database.noteOwner(.lifecycleFile, documentFile(id))
      try database.noteOwner(.lifecycleFile, stateFile(id))
    }
    guard Self.lifecycleFileID(file) != nil, previous != next else { return }
    let old = try database.rows("SELECT digest,record_count FROM lifecycle_files WHERE file=?", [.text(file)]).first
    var digest = old?[0].blob ?? Data(repeating: 0, count: 32)
    let count = (old?[1].integer ?? 0) + (next == nil ? 0 : 1) - (previous == nil ? 0 : 1)
    guard count >= 0 else { throw NotebookStorageError.corruptRecord("item lifecycle record count") }
    for hash in [previous, next].compactMap({ $0 }) { Self.xorLifecycle(&digest, address: address, hash: hash) }
    if count == 0 { try database.run("DELETE FROM lifecycle_files WHERE file=?", [.text(file)]) }
    else {
      try database.run("INSERT INTO lifecycle_files(file,digest,record_count) VALUES(?,?,?) ON CONFLICT(file) DO UPDATE SET digest=excluded.digest,record_count=excluded.record_count",
        [.text(file), .blob(digest), .integer(count)])
    }
    try database.noteOwner(.lifecycleFile, file)
  }

  /// The membership cut is resolved after all writes, so either ordering of
  /// page birth and membership is valid. Removed memberships retain their old
  /// contribution here until it has been subtracted from its previous owner.
  func refreshItemLifecycleIndex(database: NotebookSQLConnection) throws {
    while let file = try database.takeOwner(.lifecycleFile) {
      guard let id = Self.lifecycleFileID(file) else { throw NotebookStorageError.corruptRecord("item lifecycle file") }
      let old = try database.rows("SELECT item_id,hash,record_count FROM lifecycle_members WHERE file=?", [.text(file)]).first
      let body = try database.rows("SELECT digest,record_count FROM lifecycle_files WHERE file=?", [.text(file)]).first
      let owner: UUID?
      if body == nil { owner = nil }
      else if file.hasPrefix("pages/") { owner = try ownerItemID(ofPage: id) }
      else {
        owner = try storedFragments(address: "workspace.json#/items/@" + id.uuidString.lowercased(), descendants: false)
          .first?.value["kind"] == .string("document") ? id : nil
      }
      let item = owner?.uuidString.lowercased()
      let hash = body.map { Self.lifecycleHash(Data(("item-file-v1\n" + file + "\n").utf8) + $0[0].blob!) }
      let count = body?[1].integer ?? 0
      if old?[0].text == item, old?[1].text == hash, old?[2].integer == count { continue }
      if let old {
        try adjustItemLifecycle(old[0].text!, file: file, hash: old[1].text!, records: old[2].integer!, adding: false, database: database)
      }
      if let item, let hash {
        try adjustItemLifecycle(item, file: file, hash: hash, records: count, adding: true, database: database)
        try database.run("INSERT INTO lifecycle_members(file,item_id,hash,record_count) VALUES(?,?,?,?) ON CONFLICT(file) DO UPDATE SET item_id=excluded.item_id,hash=excluded.hash,record_count=excluded.record_count",
          [.text(file), .text(item), .text(hash), .integer(count)])
      } else { try database.run("DELETE FROM lifecycle_members WHERE file=?", [.text(file)]) }
    }
  }

  private func adjustItemLifecycle(_ item: String, file: String, hash: String, records: Int64,
    adding: Bool, database: NotebookSQLConnection) throws {
    let old = try database.rows("SELECT digest,file_count,record_count FROM lifecycle_items WHERE item_id=?", [.text(item)]).first
    var digest = old?[0].blob ?? Data(repeating: 0, count: 32)
    Self.xorLifecycle(&digest, address: file, hash: hash)
    let count = (old?[1].integer ?? 0) + (adding ? 1 : -1)
    let recordCount = (old?[2].integer ?? 0) + (adding ? records : -records)
    guard count >= 0, recordCount >= 0 else { throw NotebookStorageError.corruptRecord("item lifecycle contribution") }
    if count == 0 { try database.run("DELETE FROM lifecycle_items WHERE item_id=?", [.text(item)]) }
    else {
      try database.run("INSERT INTO lifecycle_items(item_id,digest,file_count,record_count) VALUES(?,?,?,?) ON CONFLICT(item_id) DO UPDATE SET digest=excluded.digest,file_count=excluded.file_count,record_count=excluded.record_count",
        [.text(item), .blob(digest), .integer(count), .integer(recordCount)])
    }
  }

  static let lifecycleScanSQL = "SELECT file,address,hash FROM records INDEXED BY record_files WHERE (file,address)>(?,?) AND file<? ORDER BY file,address LIMIT 256"

  /// Schema admission reads only record metadata. Stream one file at a time;
  /// neither migration nor later reads load notebook/document bodies.
  func rebuildItemLifecycleIndex(database: NotebookSQLConnection) throws {
    for table in ["lifecycle_members", "lifecycle_items", "lifecycle_files"] { try database.run("DELETE FROM " + table) }
    for prefix in ["pages/", "documents/", "document-states/"] {
      var afterFile = prefix, afterAddress = "", currentFile: String?
      var digest = Data(repeating: 0, count: 32), count: Int64 = 0
      func flush() throws {
        guard let file = currentFile else { return }
        try database.run("INSERT INTO lifecycle_files(file,digest,record_count) VALUES(?,?,?)", [.text(file), .blob(digest), .integer(count)])
        try database.noteOwner(.lifecycleFile, file)
      }
      while true {
        try Task.checkCancellation()
        let rows = try database.rows(Self.lifecycleScanSQL,
          [.text(afterFile), .text(afterAddress), .text(prefix + "\u{10ffff}")])
        guard let last = rows.last else { break }
        for row in rows {
          let file = row[0].text!
          guard Self.lifecycleFileID(file) != nil else { throw NotebookStorageError.corruptRecord("item lifecycle file") }
          if currentFile != file { try flush(); currentFile = file; digest = Data(repeating: 0, count: 32); count = 0 }
          Self.xorLifecycle(&digest, address: row[1].text!, hash: row[2].text!); count += 1
        }
        afterFile = last[0].text!; afterAddress = last[1].text!
      }
      try flush()
    }
    try refreshItemLifecycleIndex(database: database)
  }

  private static func lifecycleFileID(_ file: String) -> UUID? {
    let parts = file.split(separator: "/")
    guard parts.count == 2, ["pages", "documents", "document-states"].contains(parts[0]), parts[1].hasSuffix(".json") else { return nil }
    return UUID(uuidString: String(parts[1].dropLast(5)))
  }
  private static func xorLifecycle(_ digest: inout Data, address: String, hash: String) {
    let contribution = SHA256.hash(data: Data(("item-record-v1\n" + address + "\n" + hash).utf8))
    for (index, byte) in contribution.enumerated() { digest[index] ^= byte }
  }
  private static func lifecycleHash(_ data: Data) -> String { Data(SHA256.hash(data: data)).hexadecimal }
}

private extension Data {
  var hexadecimal: String { map { String(format: "%02x", $0) }.joined() }
}
