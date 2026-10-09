import Foundation
import CSQLite

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
      try database.run("DROP TRIGGER IF EXISTS search_recipe_\(event.lowercased())")
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

  func updateSearchIndex(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws {
    let kind: String, owner: String, targetKind: String?, targetID: String?, elementID: String?, plain: String
    let value = fragment.value
    if fragment.file == "workspace.json", fragment.collection == "items" {
      kind = "item"; owner = fragment.member; targetKind = nil; targetID = nil; elementID = nil; plain = try NotebookSearchText.plain(value["title"]?.string ?? "")
    } else if fragment.file.hasPrefix("pages/"), fragment.collection == "elements" {
      kind = "page"; owner = String(fragment.file.dropFirst(6).dropLast(5)); targetKind = nil; targetID = nil; elementID = value["id"]?.string
      plain = try NotebookSearchText.element(value)
    } else if fragment.file.hasPrefix("documents/"), fragment.collection == "files" {
      kind = "document"; owner = String(fragment.file.dropFirst(10).dropLast(5)); targetKind = nil; targetID = nil; elementID = value["id"]?.string; plain = try NotebookSearchText.plain(value["source"]?.string ?? "")
    } else if fragment.file == "board.json", fragment.collection == "board/elements", let parent = fragment.parent,
      let surface = try value["surface"]?.decode(SurfaceID.self), let id = surface.ownerID {
      kind = "spatial"; owner = String(parent.dropFirst("board.json#/boards/@".count)); targetKind = surface.kind.rawValue; targetID = id.uuidString.lowercased(); elementID = value["id"]?.string
      plain = try NotebookSearchText.element(value)
    } else { return }
    let folded = Self.foldedSearchText(plain)
    if folded.isEmpty { try database.run("DELETE FROM search_entries WHERE address=?", [.text(fragment.address)]); return }
    let previous = try database.rows("SELECT rowid,folded FROM search_entries WHERE address=?", [.text(fragment.address)]).first
    try database.run("INSERT INTO search_entries(address,kind,owner_id,target_kind,target_id,element_id,plain_text,folded) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(address) DO UPDATE SET kind=excluded.kind,owner_id=excluded.owner_id,target_kind=excluded.target_kind,target_id=excluded.target_id,element_id=excluded.element_id,plain_text=excluded.plain_text,folded=excluded.folded", [
      .text(fragment.address), .text(kind), .text(owner), targetKind.map(NotebookSQLValue.text) ?? .null, targetID.map(NotebookSQLValue.text) ?? .null,
      elementID.map(NotebookSQLValue.text) ?? .null, .text(plain), .text(folded)])
    if previous?[1].text != folded {
      let id = try database.rows("SELECT rowid FROM search_entries WHERE address=?", [.text(fragment.address)])[0][0].integer!
      try database.run("DELETE FROM search_short WHERE entry_id=?", [.integer(id)])
      var grams = Set<String>(), last: Character?
      for character in folded {
        grams.insert(String(character))
        if let last { grams.insert(String(last) + String(character)) }
        last = character
      }
      for gram in grams { try database.run("INSERT INTO search_short(gram,entry_id) VALUES(?,?)", [.text(gram), .integer(id)]) }
    }
  }
}
