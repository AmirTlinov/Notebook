import Foundation
import CSQLite
import CryptoKit

/// Disposable recipe output, sealed to its literal extraction input. Only a
/// native document preparation crosses an await; ordinary writers call the
/// same preparation and installation synchronously in their existing cut.
struct NotebookPreparedSearchEntry: Sendable {
  static let maximumRetainedBytes = 64 * 1_024 * 1_024
  let recipe: Int
  let workspaceID: UUID?
  let input: NotebookSearchInput
  let inputHash: String?
  let plain: String
  let folded: String
  let grams: Set<String>
  let retainedBytes: Int

  init(input: NotebookSearchInput, workspaceID: UUID? = nil,
    maximumWorkingBytes: Int = 128 * 1_024 * 1_024, observesCancellation: Bool = true,
    previousFolded: String? = nil) throws {
    self.recipe = NotebookStore.searchRecipe; self.workspaceID = workspaceID; self.input = input
    let sourceBytes = input.source.utf8.count
    // Literal normalization retains one output String. Folding's bounded
    // Unicode expansion and Foundation's UTF16/UTF8 scratch are separate from
    // the later gram table; these two phases do not coexist.
    guard sourceBytes <= NotebookSearchText.maximumTextBytes,
      sourceBytes <= (maximumWorkingBytes - 8_192) / 8 else { throw Self.refusal() }
    if observesCancellation { try Task.checkCancellation() }
    let plain = try input.isHTML
      ? NotebookSearchText.html(input.source, observesCancellation: observesCancellation)
      : NotebookSearchText.plain(input.source, observesCancellation: observesCancellation)
    let folded = NotebookStore.foldedSearchText(plain)
    if observesCancellation { try Task.checkCancellation() }
    let strings = 4_096 + plain.utf8.count * 2 + folded.utf8.count * 2
    let limit = min(Self.maximumRetainedBytes, maximumWorkingBytes)
    guard strings <= limit else { throw Self.refusal() }
    var grams = Set<String>(), retained = strings, previous: Character?, previousBytes = 0, visited = 0
    func insert(_ first: Character?, _ character: Character, bytes: Int) throws {
      // A candidate may be a single very long grapheme. Pay its temporary
      // strings before constructing it; a duplicate consumes no retained slot.
      guard bytes <= (maximumWorkingBytes - retained) / 4 else { throw Self.refusal() }
      let gram = first.map { String($0) + String(character) } ?? String(character)
      if grams.contains(gram) { return }
      // Hash-table growth, control bytes and both String representations.
      let next = 192 + bytes * 2
      guard next <= limit - retained, bytes <= (maximumWorkingBytes - retained - next) / 4 else {
        throw Self.refusal()
      }
      grams.insert(gram); retained += next
    }
    if previousFolded != folded {
      for character in folded {
        var bytes = 0
        for scalar in character.unicodeScalars {
          let value = scalar.value
          bytes += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x1_0000 ? 3 : 4
          visited += 1
          if observesCancellation, visited & 4_095 == 0 { try Task.checkCancellation() }
        }
        try insert(nil, character, bytes: bytes)
        if let previous { try insert(previous, character, bytes: previousBytes + bytes) }
        previous = character; previousBytes = bytes
      }
    }
    let actual = strings + grams.capacity * (MemoryLayout<String>.stride + 32)
      + grams.reduce(0) { $0 + $1.utf8.count * 2 }
    guard actual <= limit else { throw Self.refusal() }
    self.plain = plain; self.folded = folded; self.grams = grams
    self.retainedBytes = actual
    self.inputHash = workspaceID == nil ? nil : try input.hash(observesCancellation: observesCancellation)
  }

  func validate(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws -> NotebookSearchInput {
    guard recipe == NotebookStore.searchRecipe, let inputHash, let actual = try NotebookSearchInput(fragment),
      actual.sameAddress(as: input),
      try actual.hash(observesCancellation: !database.writable) == inputHash else {
      throw NotebookStorageError.invalidTransaction("prepared search source mismatch")
    }
    if let workspaceID {
      guard try database.rows("SELECT value FROM metadata WHERE key='workspace_id'").first?[0].text
        == workspaceID.uuidString.lowercased() else { throw NotebookStoreError.workspaceChanged }
    }
    return actual
  }

  private static func refusal() -> NotebookStorageError { .limitExceeded("search_preparation_memory") }
}

struct NotebookSearchInput: Sendable {
  let address: String
  let kind: String
  let owner: String
  let targetKind: String?
  let targetID: String?
  let elementID: String?
  let source: String
  let isHTML: Bool

  init(documentID: UUID, fileID: String, source: String) {
    let file = documentFile(documentID)
    address = file + "#/files/@" + fieldKey([collaborationIdentity(fileID)])
    kind = "document"; owner = documentID.uuidString.lowercased()
    targetKind = nil; targetID = nil; elementID = fileID; self.source = source; isHTML = false
  }

  init?(_ fragment: NotebookStoredFragment) throws {
    address = fragment.address
    let value = fragment.value
    if fragment.file == "workspace.json", fragment.collection == "items" {
      kind = "item"; owner = fragment.member; targetKind = nil; targetID = nil; elementID = nil
      source = value["title"]?.string ?? ""; isHTML = false
    } else if fragment.file.hasPrefix("documents/"), fragment.collection == "files" {
      kind = "document"; owner = String(fragment.file.dropFirst(10).dropLast(5))
      targetKind = nil; targetID = nil; elementID = value["id"]?.string
      source = value["source"]?.string ?? ""; isHTML = false
    } else {
      if fragment.file.hasPrefix("pages/"), fragment.collection == "elements" {
        kind = "page"; owner = String(fragment.file.dropFirst(6).dropLast(5)); targetKind = nil; targetID = nil
      } else if fragment.file == "board.json", fragment.collection == "board/elements", let parent = fragment.parent,
        let surface = try value["surface"]?.decode(SurfaceID.self), let id = surface.ownerID {
        kind = "spatial"; owner = String(parent.dropFirst("board.json#/boards/@".count))
        targetKind = surface.kind.rawValue; targetID = id.uuidString.lowercased()
      } else { return nil }
      elementID = value["id"]?.string
      switch value["kind"]?.string {
      case "group": source = ""; isHTML = false
      case "graphic":
        let graphic = value["graphic"]
        source = graphic?["visible"] != .bool(false) && graphic?["representation"] != .string("ink")
          ? graphic?["label"]?.string ?? "" : ""
        isHTML = false
      case "nativeText": source = value["source"]?.string ?? ""; isHTML = false
      default:
        let literal = value["source"]?.string ?? ""
        source = literal.isEmpty ? value["html"]?.string ?? "" : literal; isHTML = literal.isEmpty
      }
    }
  }

  func sameAddress(as other: Self) -> Bool {
    address == other.address && kind == other.kind && owner == other.owner
      && targetKind == other.targetKind && targetID == other.targetID
      && elementID.map(collaborationIdentity) == other.elementID.map(collaborationIdentity) && isHTML == other.isHTML
  }

  func hash(observesCancellation: Bool) throws -> String {
    var digest = SHA256()
    let contiguous = try source.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
      for offset in stride(from: 0, to: bytes.count, by: 65_536) {
        if observesCancellation { try Task.checkCancellation() }
        digest.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress!.advanced(by: offset),
          count: min(65_536, bytes.count - offset)))
      }
      return true
    }
    if contiguous == nil {
      // A bridged noncontiguous string uses one fixed scratch block; never a
      // second full Data(source.utf8) allocation inside the writer.
      var buffer: [UInt8] = []; buffer.reserveCapacity(4_096)
      for byte in source.utf8 {
        buffer.append(byte)
        if buffer.count == 4_096 {
          if observesCancellation { try Task.checkCancellation() }
          buffer.withUnsafeBytes { digest.update(bufferPointer: $0) }; buffer.removeAll(keepingCapacity: true)
        }
      }
      buffer.withUnsafeBytes { digest.update(bufferPointer: $0) }
    }
    if observesCancellation { try Task.checkCancellation() }
    return NotebookHexEncoding.encode(digest.finalize())
  }
}

extension NotebookStore {
  static let searchRecipe = 1

  /// A handle opened by a previous recipe cannot mutate the new index after
  /// waiting behind its admission writer. Register once, before schema access.
  static func registerSearchRecipe(on database: NotebookSQLConnection) throws {
    guard sqlite3_create_function_v2(database.handle, "notebook_search_recipe", 0,
      SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, nil, { context, _, _ in
        sqlite3_result_int(context, Int32(NotebookStore.searchRecipe))
      }, nil, nil, nil) == SQLITE_OK else { throw NotebookStorageError.invalidTransaction("search recipe connection") }
  }

  static func requireSearchRecipe(database: NotebookSQLConnection) throws {
    guard try database.rows("SELECT value FROM metadata WHERE key='search_recipe'").first?[0].text == String(searchRecipe) else {
      throw NotebookStorageError.unsupportedFormat
    }
  }

  private static func installSearchRecipe(database: NotebookSQLConnection) throws {
    for event in ["INSERT", "UPDATE", "DELETE"] {
      try database.run("""
        CREATE TRIGGER search_recipe_\(event.lowercased()) BEFORE \(event) ON search_entries BEGIN
        SELECT CASE WHEN notebook_search_recipe()!=\(searchRecipe) THEN RAISE(ABORT,'search recipe mismatch') END;
        END
        """)
    }
    try database.run("INSERT INTO metadata(key,value) VALUES('search_recipe',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(String(searchRecipe))])
  }

  static func createSearchIndex(database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE search_entries(rowid INTEGER PRIMARY KEY,address TEXT NOT NULL UNIQUE REFERENCES records(address) ON DELETE CASCADE,kind TEXT NOT NULL,owner_id TEXT NOT NULL,target_kind TEXT,target_id TEXT,element_id TEXT,plain_text TEXT NOT NULL,folded TEXT NOT NULL)")
    try database.run("CREATE VIRTUAL TABLE search_fts USING fts5(folded,content='search_entries',content_rowid='rowid',tokenize='trigram case_sensitive 1')")
    try database.run("CREATE TABLE search_short(gram TEXT NOT NULL,entry_id INTEGER NOT NULL REFERENCES search_entries(rowid) ON DELETE CASCADE,PRIMARY KEY(gram,entry_id))")
    try database.run("CREATE INDEX search_short_owner ON search_short(entry_id)")
    try database.run("CREATE TRIGGER search_insert AFTER INSERT ON search_entries BEGIN INSERT INTO search_fts(rowid,folded) VALUES(new.rowid,new.folded); END")
    try database.run("CREATE TRIGGER search_delete AFTER DELETE ON search_entries BEGIN INSERT INTO search_fts(search_fts,rowid,folded) VALUES('delete',old.rowid,old.folded); END")
    try database.run("CREATE TRIGGER search_update AFTER UPDATE OF folded ON search_entries WHEN old.folded<>new.folded BEGIN INSERT INTO search_fts(search_fts,rowid,folded) VALUES('delete',old.rowid,old.folded); INSERT INTO search_fts(rowid,folded) VALUES(new.rowid,new.folded); END")
    try installSearchRecipe(database: database)
  }

  /// One physical envelope at a time, in the existing admission writer. Only
  /// disposable search rows change; no source reconstruction or publication.
  func rebuildSearchIndex(database: NotebookSQLConnection) throws {
    try database.run("DELETE FROM search_entries")
    var after = ""
    while let row = try database.rows("""
      SELECT r.address,b.data FROM records r JOIN blobs b ON b.hash=r.hash
      WHERE r.address>? AND ((r.file='workspace.json' AND r.collection='items')
        OR (r.file GLOB 'pages/*' AND r.collection='elements')
        OR (r.file GLOB 'documents/*' AND r.collection='files')
        OR (r.file='board.json' AND r.collection='board/elements'))
      ORDER BY r.address LIMIT 1
      """, [.text(after)]).first {
      after = row[0].text!
      let fragment = try database.decodeFragmentEnvelope(row[1].blob!)
      guard fragment.address == after else { throw NotebookStorageError.corruptRecord(after) }
      try updateSearchIndex(fragment, database: database)
    }
    try Self.installSearchRecipe(database: database)
  }

  static func foldedSearchText(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  func updateSearchIndex(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection,
    prepared: NotebookPreparedSearchEntry? = nil) throws {
    let entry: NotebookPreparedSearchEntry
    let input: NotebookSearchInput
    if let prepared { input = try prepared.validate(fragment, database: database) }
    else { guard let actual = try NotebookSearchInput(fragment) else { return }; input = actual }
    let previous = try database.rows("SELECT folded FROM search_entries WHERE address=?", [.text(input.address)]).first?[0].text
    if let prepared { entry = prepared }
    else {
      entry = try .init(input: input, observesCancellation: !database.writable, previousFolded: previous)
    }
    try installSearchIndex(entry, input: input, previousFolded: previous, database: database)
  }

  private func installSearchIndex(_ entry: NotebookPreparedSearchEntry, input: NotebookSearchInput, previousFolded: String?,
    database: NotebookSQLConnection) throws {
    let folded = entry.folded
    if folded.isEmpty { try database.run("DELETE FROM search_entries WHERE address=?", [.text(input.address)]); return }
    try database.run("INSERT INTO search_entries(address,kind,owner_id,target_kind,target_id,element_id,plain_text,folded) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(address) DO UPDATE SET kind=excluded.kind,owner_id=excluded.owner_id,target_kind=excluded.target_kind,target_id=excluded.target_id,element_id=excluded.element_id,plain_text=excluded.plain_text,folded=excluded.folded", [
      .text(input.address), .text(input.kind), .text(input.owner), input.targetKind.map(NotebookSQLValue.text) ?? .null, input.targetID.map(NotebookSQLValue.text) ?? .null,
      input.elementID.map(NotebookSQLValue.text) ?? .null, .text(entry.plain), .text(folded)])
    if previousFolded != folded {
      let id = try database.rows("SELECT rowid FROM search_entries WHERE address=?", [.text(input.address)])[0][0].integer!
      try database.run("DELETE FROM search_short WHERE entry_id=?", [.integer(id)])
      for gram in entry.grams { try database.run("INSERT INTO search_short(gram,entry_id) VALUES(?,?)", [.text(gram), .integer(id)]) }
    }
  }
}
