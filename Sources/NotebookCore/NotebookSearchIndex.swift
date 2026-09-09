import Foundation

extension NotebookStore {
  static func createSearchIndex(database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE search_entries(rowid INTEGER PRIMARY KEY,address TEXT NOT NULL UNIQUE REFERENCES records(address) ON DELETE CASCADE,kind TEXT NOT NULL,owner_id TEXT NOT NULL,target_kind TEXT,target_id TEXT,element_id TEXT,plain_text TEXT NOT NULL,folded TEXT NOT NULL)")
    try database.run("CREATE VIRTUAL TABLE search_fts USING fts5(folded,content='search_entries',content_rowid='rowid',tokenize='trigram case_sensitive 1')")
    try database.run("CREATE TABLE search_short(gram TEXT NOT NULL,entry_id INTEGER NOT NULL REFERENCES search_entries(rowid) ON DELETE CASCADE,PRIMARY KEY(gram,entry_id))")
    try database.run("CREATE INDEX search_short_owner ON search_short(entry_id)")
    try database.run("CREATE TRIGGER search_insert AFTER INSERT ON search_entries BEGIN INSERT INTO search_fts(rowid,folded) VALUES(new.rowid,new.folded); END")
    try database.run("CREATE TRIGGER search_delete AFTER DELETE ON search_entries BEGIN INSERT INTO search_fts(search_fts,rowid,folded) VALUES('delete',old.rowid,old.folded); END")
    try database.run("CREATE TRIGGER search_update AFTER UPDATE OF folded ON search_entries WHEN old.folded<>new.folded BEGIN INSERT INTO search_fts(search_fts,rowid,folded) VALUES('delete',old.rowid,old.folded); INSERT INTO search_fts(rowid,folded) VALUES(new.rowid,new.folded); END")
  }

  static func searchableText(_ value: String) -> String {
    value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
      .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  static func foldedSearchText(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }

  func updateSearchIndex(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws {
    let kind: String, owner: String, targetKind: String?, targetID: String?, elementID: String?, text: String
    let value = fragment.value
    if fragment.file == "workspace.json", fragment.collection == "items" {
      kind = "item"; owner = fragment.member; targetKind = nil; targetID = nil; elementID = nil; text = value["title"]?.string ?? ""
    } else if fragment.file.hasPrefix("pages/"), fragment.collection == "elements" {
      kind = "page"; owner = String(fragment.file.dropFirst(6).dropLast(5)); targetKind = nil; targetID = nil; elementID = value["id"]?.string
      let source = value["source"]?.string ?? ""; text = source.isEmpty ? value["html"]?.string ?? "" : source
    } else if fragment.file.hasPrefix("documents/"), fragment.collection == "blocks" {
      kind = "document"; owner = String(fragment.file.dropFirst(10).dropLast(5)); targetKind = nil; targetID = nil; elementID = value["id"]?.string; text = value["source"]?.string ?? ""
    } else if fragment.file == "board.json", fragment.collection == "board/elements", let parent = fragment.parent,
      let surface = try value["surface"]?.decode(SurfaceID.self), let id = surface.ownerID {
      kind = "spatial"; owner = String(parent.dropFirst("board.json#/boards/@".count)); targetKind = surface.kind.rawValue; targetID = id.uuidString.lowercased(); elementID = value["id"]?.string
      let source = value["source"]?.string ?? ""; text = source.isEmpty ? value["html"]?.string ?? "" : source
    } else { return }
    let plain = Self.searchableText(text), folded = Self.foldedSearchText(plain)
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
