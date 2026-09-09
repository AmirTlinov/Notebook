import CSQLite
import CryptoKit
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum NotebookSQLValue {
  case text(String), integer(Int64), real(Double), blob(Data), null
  var text: String? { if case .text(let value) = self { value } else { nil } }
  var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
  var blob: Data? { if case .blob(let value) = self { value } else { nil } }
}

/// A connection is owned by one synchronous reader/command segment. Nested
/// typed APIs borrow it; no connection or SQLite statement crosses an await.
final class NotebookSQLConnection {
  let handle: OpaquePointer
  let writable: Bool
  var changes: [String: NotebookRecordMutation] = [:]
  var dirtyBoardNodes = Set<String>()
  var dirtyReferenceRoots = Set<String>()
  var touchedItemIDs = Set<UUID>()
  var touchedCoverAddresses = Set<String>()
  var pageOrderRoots = Set<String>()
  var touchedPageOrders = Set<String>()
  var touchedPageMemberships = Set<String>()
  var capturedPageOrderRoots = Set<String>()
  var previousPageOrderRoots: [String: String] = [:]
  private var statements: [String: OpaquePointer] = [:]

  init(url: URL, writable: Bool, create: Bool = false) throws {
    var pointer: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
    guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
      if let pointer { sqlite3_close(pointer) }
      throw NotebookStorageError.corruptRecord("database")
    }
    handle = pointer; self.writable = writable
    sqlite3_busy_timeout(handle, 4_000)
    try run("PRAGMA foreign_keys=ON")
    try run("PRAGMA synchronous=FULL")
  }

  deinit {
    for statement in statements.values { sqlite3_finalize(statement) }
    sqlite3_close(handle)
  }

  private func statement(_ sql: String, _ values: [NotebookSQLValue]) throws -> OpaquePointer {
    let statement: OpaquePointer
    if let previous = statements[sql] { statement = previous; sqlite3_reset(previous); sqlite3_clear_bindings(previous) }
    else {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure(sql) }
      statements[sql] = prepared; statement = prepared
    }
    guard sqlite3_bind_parameter_count(statement) == Int32(values.count) else { throw NotebookStorageError.invalidTransaction("SQL bind count") }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let status: Int32
      switch value {
      case .text(let string): status = sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
      case .integer(let number): status = sqlite3_bind_int64(statement, index, number)
      case .real(let number): status = sqlite3_bind_double(statement, index, number)
      case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64(data.count), sqliteTransient) }
      case .null: status = sqlite3_bind_null(statement, index)
      }
      guard status == SQLITE_OK else { throw failure(sql) }
    }
    return statement
  }

  func run(_ sql: String, _ values: [NotebookSQLValue] = []) throws {
    let statement = try statement(sql, values)
    defer { sqlite3_reset(statement) }
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW { status = sqlite3_step(statement) }
    guard status == SQLITE_DONE else { throw failure(sql) }
  }

  func rows(_ sql: String, _ values: [NotebookSQLValue] = []) throws -> [[NotebookSQLValue]] {
    let statement = try statement(sql, values)
    defer { sqlite3_reset(statement) }
    var result: [[NotebookSQLValue]] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return result }
      guard status == SQLITE_ROW else { throw failure(sql) }
      var row: [NotebookSQLValue] = []
      for index in 0..<sqlite3_column_count(statement) {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, index)))
        case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, index))))
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, index))
          row.append(.blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: count)))
        default: row.append(.null)
        }
      }
      result.append(row)
    }
  }

  private func failure(_ operation: String) -> Error {
    let status = sqlite3_errcode(handle)
    if status == SQLITE_BUSY || status == SQLITE_LOCKED {
      return CollaborationError("publication_pending", "Предыдущая транзакция ещё записывается. Повторите запрос.")
    }
    return NotebookStorageError.invalidTransaction("\(operation.prefix(80)): \(String(cString: sqlite3_errmsg(handle)))")
  }

  func putBlob(_ data: Data) throws -> String {
    guard data.count <= 256 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("blob_too_large") }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try run("INSERT OR IGNORE INTO blobs(hash,data) VALUES(?,?)", [.text(hash), .blob(data)])
    return hash
  }

  func blob(_ hash: String) throws -> Data {
    guard let value = try rows("SELECT data FROM blobs WHERE hash=?", [.text(hash)]).first?.first?.blob else {
      throw NotebookStorageError.blobMissing(hash)
    }
    return value
  }
}

struct NotebookStoredCollection: Codable, Equatable {
  enum Kind: String, Codable { case array, dictionary, value, pageInk }
  let path: [String]
  let kind: Kind
}

/// One physical SQL row carries an addressed member; large values are immutable
/// content-addressed blobs. Parent records never carry a full member-ID array.
struct NotebookStoredFragment: Codable, Equatable {
  let address: String
  let file: String
  let parent: String?
  let collection: String
  let member: String
  let position: Int
  let value: JSONValue
  let collections: [NotebookStoredCollection]
}

struct NotebookRecordCodec {
  static func encode(_ value: JSONValue, file: String) throws -> [NotebookStoredFragment] {
    var rows: [NotebookStoredFragment] = []
    func make(_ original: JSONValue, address: String, parent: String?, collection: String, member: String, position: Int) throws {
      var collections: [NotebookStoredCollection] = []
      func strip(_ value: JSONValue, path: [String]) throws -> JSONValue {
        guard case .object(let fields) = value else { return value }
        var output: [String: JSONValue] = [:]
        for key in fields.keys.sorted() {
          let value = fields[key]!, location = path + [key]
          let collectionKey = fieldKey(location)
          if ((key == "fields" && path.last == "collaboration")
            || (file == "workspace.json" && path.isEmpty && ["pageOrders", "pageOrderNodes"].contains(key))),
            case .object(let versions) = value {
            collections.append(.init(path: location, kind: .dictionary))
            for member in versions.keys.sorted() {
              try make(versions[member]!, address: address + "/" + collectionKey + "/@" + fieldKey([member]),
                parent: address, collection: collectionKey, member: member, position: 0)
            }
          } else if case .array(let values) = value,
            ["items", "boards", "freeItems", "stacks", "elements", "blocks", "records", "actions", "entries", "pageIDs"].contains(key),
            values.allSatisfy({ $0.memberIdentity != nil || (key == "pageIDs" && $0.string != nil) }) {
            let ids = values.compactMap { $0.memberIdentity ?? $0.string?.lowercased() }
            guard Set(ids).count == ids.count else { throw NotebookStorageError.invalidTransaction("duplicate IDs in \(file)/\(collectionKey)") }
            collections.append(.init(path: location, kind: .array))
            for (offset, value) in values.enumerated() {
              let member = ids[offset]
              try make(value, address: address + "/" + collectionKey + "/@" + fieldKey([member]),
                parent: address, collection: collectionKey, member: member, position: offset)
            }
          } else if key == "drawingData", file.hasPrefix("pages/") {
            let drawing = try PageInkDrawing.decode(value.decode(Data.self))
            collections.append(.init(path: location, kind: .pageInk))
            try make(.encode(drawing), address: address + "/" + collectionKey, parent: address,
              collection: collectionKey, member: "", position: 0)
          } else if (key == "samples" && file.hasPrefix("pages/") && address.contains("#/drawingData/actions/@") && path.isEmpty)
            || (key == "baselinePNG" && file.hasPrefix("pages/") && collection == "drawingData" && path.isEmpty)
            || (key == "spans" && file == "spatial-ink.json" && collection == "actions" && path.isEmpty) {
            collections.append(.init(path: location, kind: .value))
            try make(value, address: address + "/" + collectionKey, parent: address,
              collection: collectionKey, member: "", position: 0)
          } else if file == "workspace.json", path.isEmpty, key == "isProjection" {
            // Projection is a typed read/command envelope, never durable state.
            output[key] = .bool(false)
          } else { output[key] = try strip(value, path: location) }
        }
        return .object(output)
      }
      let stripped = try strip(original, path: [])
      rows.append(.init(address: address, file: file, parent: parent, collection: collection,
        member: member, position: position, value: stripped, collections: collections))
    }
    try make(value, address: file + "#", parent: nil, collection: "", member: "", position: 0)
    return rows
  }

  static func decode(_ rows: [NotebookStoredFragment], root: String) throws -> JSONValue {
    let byAddress = Dictionary(rows.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
    guard byAddress.count == rows.count else { throw NotebookStorageError.corruptRecord(root) }
    let children = Dictionary(grouping: rows.filter { $0.parent != nil }, by: { $0.parent! })
    var visiting = Set<String>()
    func assemble(_ address: String) throws -> JSONValue {
      guard let row = byAddress[address], visiting.insert(address).inserted else { throw NotebookStorageError.corruptRecord(address) }
      defer { visiting.remove(address) }
      var value = row.value
      for collection in row.collections {
        if row.file.hasPrefix("pages/"), collection.path == ["drawingData"], collection.kind != .pageInk {
          throw NotebookStorageError.unsupportedFormat
        }
        let members = (children[address] ?? []).filter { $0.collection == fieldKey(collection.path) }
        let matching: [NotebookStoredFragment]
        if row.file == "spatial-ink.json", collection.path == ["actions"] {
          // Contact order is authored by its creation stamp and UUID, not by
          // arrival or SQL slot. An addressed insertion never renumbers peers.
          var stamped: [(row: NotebookStoredFragment, stamp: VersionStamp)] = []
          for member in members {
            guard let stamp = try member.value["stamp"]?.decode(VersionStamp.self) else {
              throw NotebookStorageError.corruptRecord(member.address)
            }
            stamped.append((member, stamp))
          }
          stamped.sort { left, right in
            left.stamp == right.stamp ? left.row.member < right.row.member : left.stamp < right.stamp
          }
          matching = stamped.map(\.row)
        } else {
          matching = members.sorted { $0.position == $1.position ? $0.member < $1.member : $0.position < $1.position }
        }
        let content: JSONValue
        switch collection.kind {
        case .array: content = .array(try matching.map { try assemble($0.address) })
        case .dictionary:
          var fields: [String: JSONValue] = [:]
          for member in matching {
            guard fields[member.member] == nil else { throw NotebookStorageError.corruptRecord(member.address) }
            fields[member.member] = try assemble(member.address)
          }
          content = .object(fields)
        case .value, .pageInk:
          guard matching.count == 1 else { throw NotebookStorageError.corruptRecord(address) }
          let stored = try assemble(matching[0].address)
          if collection.kind == .pageInk {
            let drawing = try stored.decode(PageInkDrawing.self)
            guard drawing.isValid else { throw NotebookStorageError.corruptRecord(address) }
            content = try .encode(drawing.dataRepresentation())
          } else { content = stored }
        }
        guard let restored = value.setting(at: collection.path.map { .field($0) }[...], to: content) else { throw NotebookStorageError.corruptRecord(address) }
        value = restored
      }
      return value
    }
    return try assemble(root)
  }
}

extension NotebookStore {
  public var databaseURL: URL { root.appendingPathComponent("notebook.sqlite") }
  private var connectionKey: String { "Notebook.SQL." + root.standardizedFileURL.path }
  var currentSQL: NotebookSQLConnection? { Thread.current.threadDictionary[connectionKey] as? NotebookSQLConnection }

  func prepareDatabase(initialWorkspaceID: UUID? = nil) throws {
    if currentSQL != nil { guard initialWorkspaceID == nil else { throw NotebookStorageError.invalidTransaction("workspace identity already initialized") }; return }
    let manager = FileManager.default
    // Rejection happens before mkdir/open; the external converter is the only
    // component permitted to read an old catalog or replay an old journal.
    let legacy = ["workspace.json", "board.json", "spatial-ink.json", "last-context.json", "pages", "documents", "document-states", "collaboration"]
    guard !legacy.contains(where: { manager.fileExists(atPath: root.appendingPathComponent($0).path) }) else {
      throw NotebookStorageError.legacyStoreRequiresConversion
    }
    guard initialWorkspaceID == nil || !manager.fileExists(atPath: databaseURL.path) else { throw NotebookStorageError.invalidTransaction("workspace identity already initialized") }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try NotebookSQLConnection(url: databaseURL, writable: true, create: true)
    let applicationID = try database.rows("PRAGMA application_id").first?.first?.integer ?? 0
    let version = try database.rows("PRAGMA user_version").first?.first?.integer ?? 0
    guard applicationID == 0 || (applicationID == 1_313_999_665 && version == 2) else { throw NotebookStorageError.unsupportedFormat }
    try database.run("PRAGMA journal_mode=WAL")
    try database.run("PRAGMA wal_autocheckpoint=1000")
    if applicationID == 0 {
      guard try database.rows("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw NotebookStorageError.unsupportedFormat }
      try database.run("BEGIN IMMEDIATE")
      do {
        try database.run("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try database.run("INSERT INTO metadata(key,value) VALUES('workspace_id',?)", [.text((initialWorkspaceID ?? UUID()).uuidString.lowercased())])
        try database.run("INSERT INTO metadata(key,value) VALUES('item_count','0'),('read_revision','0')")
        try database.run("CREATE TABLE blobs(hash TEXT PRIMARY KEY CHECK(length(hash)=64), data BLOB NOT NULL)")
        try database.run("CREATE TABLE records(address TEXT PRIMARY KEY, file TEXT NOT NULL, parent TEXT, collection TEXT NOT NULL, member TEXT NOT NULL, position INTEGER NOT NULL, hash TEXT NOT NULL REFERENCES blobs(hash))")
        try database.run("CREATE INDEX record_files ON records(file,address)")
        try database.run("CREATE INDEX record_members ON records(parent,collection,member)")
        try database.run("CREATE INDEX record_identity ON records(file,collection,member)")
        try database.run("CREATE INDEX record_order ON records(parent,collection,position,member)")
        try Self.createSearchIndex(database: database)
        try database.run("CREATE TABLE change_log(sequence INTEGER PRIMARY KEY AUTOINCREMENT, transaction_id TEXT NOT NULL UNIQUE, manifest_hash TEXT NOT NULL REFERENCES blobs(hash), byte_count INTEGER NOT NULL)")
        try database.run("CREATE TABLE change_records(sequence INTEGER NOT NULL REFERENCES change_log(sequence),address TEXT NOT NULL,blob_hash TEXT,PRIMARY KEY(sequence,address))")
        try database.run("CREATE INDEX change_record_history ON change_records(address,sequence)")
        try database.run("CREATE TABLE manifests(hash TEXT PRIMARY KEY REFERENCES blobs(hash), transaction_id TEXT NOT NULL,order_node_count INTEGER NOT NULL DEFAULT 0,order_node_bytes INTEGER NOT NULL DEFAULT 0)")
        try database.run("CREATE TABLE manifest_records(manifest_hash TEXT NOT NULL REFERENCES manifests(hash), address TEXT NOT NULL, blob_hash TEXT, PRIMARY KEY(manifest_hash,address))")
        try database.run("CREATE TABLE manifest_parts(manifest_hash TEXT NOT NULL REFERENCES manifests(hash), part_hash TEXT NOT NULL, loaded INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(manifest_hash,part_hash))")
        try database.run("CREATE INDEX manifest_blobs ON manifest_records(manifest_hash,blob_hash)")
        try database.run("CREATE TABLE manifest_order_nodes(manifest_hash TEXT NOT NULL REFERENCES manifests(hash),hash TEXT NOT NULL,expanded INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(manifest_hash,hash))")
        try database.run("CREATE INDEX manifest_order_pending ON manifest_order_nodes(manifest_hash,expanded,hash)")
        try database.run("CREATE TABLE page_order_nodes(hash TEXT PRIMARY KEY REFERENCES blobs(hash),height INTEGER NOT NULL,count INTEGER NOT NULL)")
        try database.run("CREATE TABLE received_transactions(transaction_id TEXT PRIMARY KEY, manifest_hash TEXT NOT NULL, peer_id TEXT NOT NULL, sequence INTEGER NOT NULL)")
        try database.run("CREATE TABLE peer_cursors(peer_id TEXT NOT NULL, direction TEXT NOT NULL, sequence INTEGER NOT NULL, PRIMARY KEY(peer_id,direction))")
        try database.run("CREATE TABLE item_page_counts(address TEXT PRIMARY KEY REFERENCES records(address) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,count INTEGER NOT NULL CHECK(count>=0))")
        try database.run("CREATE TABLE metadata_index(address TEXT PRIMARY KEY REFERENCES records(address) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, kind TEXT NOT NULL, context_id TEXT, created_at REAL NOT NULL,status TEXT)")
        try database.run("CREATE INDEX metadata_time ON metadata_index(kind,created_at DESC,address DESC)")
        try database.run("CREATE INDEX metadata_context_time ON metadata_index(kind,context_id,created_at DESC,address DESC)")
        try database.run("CREATE INDEX metadata_pending ON metadata_index(kind,status,created_at,address)")
        try database.run("CREATE TABLE reference_owners(owner_key TEXT PRIMARY KEY,digest BLOB NOT NULL CHECK(length(digest)=32),hash TEXT,parent TEXT)")
        try database.run("CREATE TABLE reference_contributions(address TEXT NOT NULL,owner_key TEXT NOT NULL,hash TEXT NOT NULL,PRIMARY KEY(address,owner_key))")
        try database.run("CREATE TABLE reference_element_order(address TEXT PRIMARY KEY,owner_key TEXT NOT NULL,position INTEGER NOT NULL,member TEXT NOT NULL)")
        try database.run("CREATE INDEX reference_element_neighbors ON reference_element_order(owner_key,position,member)")
        try database.run("CREATE INDEX reference_owner_contributions ON reference_contributions(owner_key,address)")
        try database.run("CREATE TABLE board_nodes(node_id TEXT PRIMARY KEY, digest BLOB NOT NULL CHECK(length(digest)=32))")
        try database.run("CREATE TABLE board_frontier(prefix TEXT PRIMARY KEY,parent TEXT,hash TEXT NOT NULL)")
        try database.run("CREATE INDEX board_frontier_parent ON board_frontier(parent,prefix)")
        try database.run("CREATE TABLE spatial_entries(entry_id TEXT PRIMARY KEY, address TEXT NOT NULL REFERENCES records(address) ON DELETE CASCADE, board_id TEXT NOT NULL, owner_id TEXT NOT NULL, kind TEXT NOT NULL, layer INTEGER NOT NULL, z_index REAL NOT NULL, paint_key TEXT NOT NULL, min_tx INTEGER NOT NULL, min_ty INTEGER NOT NULL, min_x REAL NOT NULL, min_y REAL NOT NULL, max_tx INTEGER NOT NULL, max_ty INTEGER NOT NULL, max_x REAL NOT NULL, max_y REAL NOT NULL)")
        try database.run("CREATE INDEX spatial_board_tiles ON spatial_entries(board_id,min_tx,min_ty,layer,z_index,paint_key)")
        try database.run("CREATE INDEX spatial_address ON spatial_entries(address)")
        try database.run("CREATE INDEX spatial_owner ON spatial_entries(owner_id,board_id)")
        try database.run("CREATE TABLE item_owners(item_id TEXT PRIMARY KEY, board_id TEXT NOT NULL, address TEXT NOT NULL REFERENCES records(address) ON DELETE CASCADE)")
        try database.run("CREATE INDEX item_parent ON item_owners(board_id,item_id)")
        try database.run("CREATE INDEX item_placement ON item_owners(address,item_id)")
        try database.run("CREATE TABLE ink_surfaces(address TEXT NOT NULL REFERENCES records(address) ON DELETE CASCADE, kind TEXT NOT NULL, owner_id TEXT NOT NULL, PRIMARY KEY(address,kind,owner_id))")
        try database.run("CREATE INDEX ink_owner ON ink_surfaces(kind,owner_id,address)")
        try database.run("PRAGMA application_id=1313999665")
        try database.run("PRAGMA user_version=2")
        try database.run("COMMIT")
      } catch { try? database.run("ROLLBACK"); throw error }
    }
  }

  /// All typed reads in the closure observe the same WAL snapshot. A read
  /// transaction cannot be upgraded into a command behind the caller's back.
  public func readTransaction<T>(_ read: (NotebookStore) throws -> T) throws -> T {
    if currentSQL != nil { return try read(self) }
    try prepareDatabase()
    let database = try NotebookSQLConnection(url: databaseURL, writable: false)
    try database.run("BEGIN DEFERRED")
    Thread.current.threadDictionary[connectionKey] = database
    defer { Thread.current.threadDictionary.removeObject(forKey: connectionKey) }
    do { let result = try read(self); try database.run("COMMIT"); return result }
    catch { try? database.run("ROLLBACK"); throw error }
  }

  func commandTransaction<T>(_ operation: () throws -> T) throws -> T {
    if let currentSQL {
      guard currentSQL.writable else { throw NotebookStorageError.readOnlyTransaction }
      return try operation()
    }
    try prepareDatabase()
    let database = try NotebookSQLConnection(url: databaseURL, writable: true)
    try database.run("BEGIN IMMEDIATE")
    Thread.current.threadDictionary[connectionKey] = database
    defer { Thread.current.threadDictionary.removeObject(forKey: connectionKey) }
    var committed = false
    do {
      let result = try operation()
      try validateChangedPageOrders(database: database)
      try validateChangedOwnership(database: database)
      try refreshBoardFrontier(database: database)
      try refreshReferenceIndex(database: database)
      if sqlite3_total_changes64(database.handle) > 0 {
        let revision = try currentReadCursor()
        guard revision < UInt64(Int64.max) else { throw NotebookStorageError.limitExceeded("read_revision") }
        try database.run("UPDATE metadata SET value=? WHERE key='read_revision'", [.text(String(revision + 1))])
      }
      try storageFault?(.afterRecordWrites)
      if !database.changes.isEmpty {
        let transactionID = UUID()
        guard let workspaceID = try database.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text.flatMap(UUID.init(uuidString:)),
          database.changes.count <= 8_388_608 else { throw NotebookStorageError.limitExceeded("change_manifest") }
        let records = database.changes.values.sorted { $0.address < $1.address }
        var parts: [String] = []
        if records.count > 16_384 {
          for start in stride(from: 0, to: records.count, by: 16_384) {
            let part = NotebookChangeManifest(transactionID: transactionID, workspaceID: workspaceID,
              records: Array(records[start..<min(start + 16_384, records.count)]))
            let data = try Self.storageEncoder.encode(part)
            guard data.count <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("change_manifest_part") }
            parts.append(try database.putBlob(data))
          }
        }
        let manifest = NotebookChangeManifest(transactionID: transactionID, workspaceID: workspaceID,
          records: parts.isEmpty ? records : [], parts: parts, pageOrderRoots: database.pageOrderRoots.sorted())
        let data = try Self.storageEncoder.encode(manifest)
        guard data.count <= 64 * 1024 * 1024 else { throw NotebookStorageError.limitExceeded("change_manifest") }
        let hash = try database.putBlob(data)
        try database.run("INSERT INTO change_log(transaction_id,manifest_hash,byte_count) VALUES(?,?,?)", [.text(transactionID.uuidString.lowercased()), .text(hash), .integer(Int64(data.count))])
        let sequence = try database.rows("SELECT last_insert_rowid()").first![0].integer!
        for record in records {
          try database.run("INSERT INTO change_records(sequence,address,blob_hash) VALUES(?,?,?)", [.integer(sequence), .text(record.address), record.blobHash.map(NotebookSQLValue.text) ?? .null])
        }
      }
      try storageFault?(.beforeCommit)
      try database.run("COMMIT"); committed = true
      try storageFault?(.afterCommit)
      return result
    } catch { if !committed { try? database.run("ROLLBACK") }; throw error }
  }

  static var storageEncoder: JSONEncoder {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
  }

  func sqlRead<T>(_ read: (NotebookSQLConnection) throws -> T) throws -> T {
    if let currentSQL { return try read(currentSQL) }
    return try readTransaction { try read($0.currentSQL!) }
  }

  func storedValue(_ file: String) throws -> JSONValue? {
    try sqlRead { database in
      let fragments = try database.rows("SELECT b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.file=?", [.text(file)]).map {
        try JSONDecoder().decode(NotebookStoredFragment.self, from: $0[0].blob!)
      }
      guard !fragments.isEmpty else { return nil }
      return try NotebookRecordCodec.decode(fragments, root: file + "#")
    }
  }

  func storedData(_ file: String) throws -> Data {
    guard let value = try storedValue(file) else { throw CocoaError(.fileNoSuchFile) }
    return try Self.storageEncoder.encode(value)
  }

  func hasStoredValue(_ file: String) throws -> Bool {
    try sqlRead { try !$0.rows("SELECT 1 FROM records WHERE address=?", [.text(file + "#")]).isEmpty }
  }

  func storedValues(prefix: String) throws -> [JSONValue] {
    try sqlRead { database in
      let files = try database.rows("SELECT file FROM records WHERE parent IS NULL AND file>=? AND file<? ORDER BY file", [.text(prefix), .text(prefix + "\u{10ffff}")]).compactMap { $0[0].text }
      return try files.compactMap { try storedValue($0) }
    }
  }

  func publishRecords(writes: [String: JSONValue], removals: [String] = []) throws {
    try commandTransaction {
      guard let database = currentSQL else { throw NotebookStorageError.invalidTransaction("missing command") }
      for file in removals {
        try removeFragment(file + "#", database: database)
      }
      func rank(_ file: String) -> String {
        if file == "workspace.json" { return "0" }
        if file.hasPrefix("documents/") { return "1" + file }
        if file == "board.json" { return "3" }
        return "2" + file
      }
      for file in writes.keys.sorted(by: { rank($0) < rank($1) }) {
        guard !file.hasPrefix("/"), !file.contains(".."), file.hasSuffix(".json") else { throw NotebookStorageError.invalidTransaction("logical address") }
        var value = writes[file]!
        if file.hasPrefix("documents/"), value["collaboration"] == nil {
          let document = try value.decode(DocumentDocument.self)
          guard document.isValid else { throw NotebookStorageError.corruptRecord(file) }
          var metadata = CollaborativeContent()
          metadata.materializeVersions(in: value, fallback: document.contentStamp)
          value = value.setting("collaboration", try .encode(metadata))
        }
        let fragments = try NotebookRecordCodec.encode(value, file: file)
        if file == "workspace.json" { try value.decode(WorkspaceIndex.self).validatePageOrderWitness() }
        let oldRows = try database.rows("SELECT address,hash FROM records WHERE file=?", [.text(file)])
        var old = Dictionary(uniqueKeysWithValues: oldRows.map { ($0[0].text!, $0[1].text!) })
        for fragment in fragments {
          let data = try Self.storageEncoder.encode(fragment)
          let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
          if old.removeValue(forKey: fragment.address) == hash { continue }
          try writeFragment(fragment, data: data, hash: hash, database: database)
        }
        let affected = Set(fragments.compactMap { member -> String? in
          guard database.changes[member.address] != nil, !member.member.isEmpty,
            !member.collection.hasSuffix("collaboration/fields"), let parent = member.parent else { return nil }
          return parent + "|" + member.collection.components(separatedBy: "/").last! + "/" + member.member
        })
        for version in fragments where version.collection.hasSuffix("collaboration/fields") && database.changes[version.address] == nil {
          let parts = version.member.split(separator: "/", maxSplits: 2)
          guard parts.count >= 2, let parent = version.parent,
            affected.contains(parent + "|" + parts[0] + "/" + parts[1]) else { continue }
          if let hash = try database.rows("SELECT hash FROM records WHERE address=?", [.text(version.address)]).first?[0].text {
            database.changes[version.address] = .init(address: version.address, blobHash: hash)
          }
        }
        for address in old.keys where !address.hasPrefix("workspace.json#/pageOrderNodes/@") {
          try removeFragment(address, database: database)
        }
      }
    }
  }

  static func localRecord(_ file: String) -> Bool {
    file == "last-context.json" || file == "presence.json" || file.hasPrefix("collaboration/render-requests/") || file.hasPrefix("runtime/") || file.hasPrefix("document-drafts/") || file.hasPrefix("local/")
  }

  public func currentReadCursor() throws -> UInt64 {
    try sqlRead { UInt64(try $0.rows("SELECT value FROM metadata WHERE key='read_revision'").first?[0].text ?? "0") ?? 0 }
  }

  public func currentChangeCursor() throws -> UInt64 {
    try sqlRead { UInt64(try $0.rows("SELECT COALESCE(MAX(sequence),0) FROM change_log").first![0].integer!) }
  }

  public func changeJournal(after cursor: UInt64, limit: Int = 16) throws -> [NotebookDurableChange] {
    guard cursor <= UInt64(Int64.max), (1...16).contains(limit) else { throw NotebookStorageError.limitExceeded("journal_page") }
    return try sqlRead { database in
      try database.rows("SELECT sequence,transaction_id,manifest_hash,byte_count FROM change_log WHERE sequence>? ORDER BY sequence LIMIT ?", [.integer(Int64(cursor)), .integer(Int64(limit))]).map {
        .init(sequence: UInt64($0[0].integer!), transactionID: UUID(uuidString: $0[1].text!)!, manifestHash: $0[2].text!, byteCount: Int($0[3].integer!))
      }
    }
  }

  public func readBlobChunk(hash: String, offset: Int64, maxBytes: Int) throws -> Data {
    guard offset >= 0, offset < Int64.max, (1...1_048_576).contains(maxBytes) else { throw NotebookStorageError.limitExceeded("blob_chunk") }
    return try sqlRead { database in
      guard let data = try database.rows("SELECT substr(data,?,?) FROM blobs WHERE hash=?", [.integer(offset + 1), .integer(Int64(maxBytes)), .text(hash)]).first?.first?.blob else { throw NotebookStorageError.blobMissing(hash) }
      return data
    }
  }

  public func blobSize(hash: String) throws -> Int64 {
    try sqlRead { database in
      guard let count = try database.rows("SELECT length(data) FROM blobs WHERE hash=?", [.text(hash)]).first?.first?.integer else { throw NotebookStorageError.blobMissing(hash) }
      return count
    }
  }

  public func stageBlob(data: Data, expectedHash: String) throws {
    try commandTransaction {
      let hash = try currentSQL!.putBlob(data)
      guard hash == expectedHash else { throw NotebookStorageError.blobHashMismatch }
    }
  }

  public func peerCursor(peerID: UUID, direction: NotebookPeerCursorDirection) throws -> UInt64 {
    try sqlRead { UInt64(try $0.rows("SELECT sequence FROM peer_cursors WHERE peer_id=? AND direction=?", [.text(peerID.uuidString.lowercased()), .text(direction.rawValue)]).first?.first?.integer ?? 0) }
  }

  public func acknowledgePeer(peerID: UUID, through sequence: UInt64) throws {
    guard sequence <= UInt64(Int64.max) else { throw NotebookStorageError.limitExceeded("cursor") }
    try commandTransaction {
      guard sequence <= (try currentChangeCursor()) else { throw NotebookStorageError.invalidTransaction("acknowledges an unpublished change") }
      try currentSQL!.run("INSERT INTO peer_cursors(peer_id,direction,sequence) VALUES(?,'outgoing',?) ON CONFLICT(peer_id,direction) DO UPDATE SET sequence=MAX(sequence,excluded.sequence)", [.text(peerID.uuidString.lowercased()), .integer(Int64(sequence))])
    }
  }
}

extension NotebookStore {
  func logicalAddress(_ url: URL) -> String {
    let prefix = root.standardizedFileURL.path + "/"
    let path = url.standardizedFileURL.path
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
  }
  func storedData(at url: URL) throws -> Data { try storedData(logicalAddress(url)) }
  func hasStoredValue(at url: URL) throws -> Bool { try hasStoredValue(logicalAddress(url)) }
}

extension NotebookStore {
  /// Creates an empty new-format workspace with an explicitly chosen identity.
  /// This is bootstrap, not adoption: an existing database is never retargeted.
  public func prepareEmptyWorkspace(workspaceID: UUID) throws {
    try prepareDatabase(initialWorkspaceID: workspaceID)
  }
}

extension NotebookStore {
  public func readChangedAddresses(after: UInt64, through: UInt64, limit: Int = 4096) throws -> NotebookChangedAddresses {
    guard after <= through, through <= UInt64(Int64.max), (1...4096).contains(limit) else { throw NotebookStorageError.limitExceeded("changed_addresses") }
    return try readTransaction { _ in
      guard through <= (try currentChangeCursor()) else { throw NotebookStorageError.transactionConflict }
      let rows = try currentSQL!.rows("SELECT DISTINCT address FROM change_records WHERE sequence>? AND sequence<=? ORDER BY address LIMIT ?", [.integer(Int64(after)), .integer(Int64(through)), .integer(Int64(limit + 1))])
      let records = try rows.prefix(limit).compactMap { row -> NotebookChangedRecord? in
        guard let address = row[0].text else { return nil }
        func hash(at cursor: UInt64) throws -> String? {
          try currentSQL!.rows("SELECT blob_hash FROM change_records WHERE address=? AND sequence<=? ORDER BY sequence DESC LIMIT 1", [.text(address), .integer(Int64(cursor))]).first?[0].text
        }
        return try .init(address: address, beforeHash: hash(at: after), afterHash: hash(at: through))
      }
      return .init(records: records, hasMore: rows.count > limit)
    }
  }
}
