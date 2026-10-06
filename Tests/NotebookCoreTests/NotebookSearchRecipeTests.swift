import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Search selects authored text and atomically admits its recipe")
struct NotebookSearchRecipeTests {
  private final class Fixture {
    let store: NotebookStore, actor = UUID()
    let pageID: UUID, documentID = UUID(), boardID: UUID
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("search-recipe-\(UUID())"))
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      boardID = header.rootBoardID
      var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
      pageID = try #require(index.selectedPageID)
      _ = index.createDocument(title: "<TitleNeedle>", actor: actor, documentID: documentID)
      _ = board.addItem(documentID, to: boardID, near: .zero, actor: actor)
      try store.saveDocumentWorkspaceBundle(index: index,
        document: .init(id: documentID, actor: actor, files: [.init(id: "source", path: "main.tex", source: "vector<DocumentNeedle> <script>AuthorNeedle</script>")]),
        state: .init(id: documentID, actor: actor), board: board)
      let frame = PageRect(x: 10, y: 10, width: 100, height: 100)
      var page = try store.loadPage(pageID)
      page.replaceElements([
        .init(id: "native", kind: .nativeText, frame: frame, source: "vector<PageNeedle>", html: "<p>decoy</p>"),
        .init(id: "markdown", kind: .markdown, frame: frame, source: "<MarkdownNeedle>", html: "<p>decoy</p>"),
        .init(id: "graphic", kind: .graphic, frame: frame, source: "", html: "", graphic: .init(shape: .rectangle, label: "<PageGraphicNeedle>")),
        .init(id: "hidden", kind: .graphic, frame: frame, source: "", html: "", graphic: .init(shape: .rectangle, label: "HiddenNeedle", visible: false)),
        .init(id: "html", kind: .web, frame: frame, source: "", html: "<p data-x='QuotedNeedle > decoy'>HTML<span>Needle</span> &lt;LiteralNeedle&gt; Caf&eacute;</p><script>ScriptNeedle</script>")
      ], actor: actor)
      try store.savePage(page)
      let before = try store.loadBoard(items: index.items)
      var after = before
      for (id, kind, source, graphic) in [
        ("native", SpatialElementKind.nativeText, "<SpatialNeedle>", Optional<NotebookGraphic>.none),
        ("graphic", .graphic, "", .some(.init(shape: .rectangle, label: "<GraphicNeedle>")))
      ] {
        _ = after.upsertElement(.init(id: id, surface: .board(boardID), kind: kind,
          frame: .init(x: 0, y: 0, width: 100, height: 100), worldOrigin: .zero,
          source: source, graphic: graphic, stamp: .init(counter: 0, actor: actor)), in: boardID, expected: nil, actor: actor)
      }
      _ = try store.saveBoardEdits(before: before, after: after)
    }
    deinit { try? FileManager.default.removeItem(at: store.root) }

    func requireHits() throws {
      for word in ["TitleNeedle", "DocumentNeedle", "AuthorNeedle", "PageNeedle", "MarkdownNeedle", "SpatialNeedle", "GraphicNeedle", "PageGraphicNeedle", "HTMLNeedle", "LiteralNeedle", "cafe"] {
        #expect(try store.search(word).total > 0, "The authored or visible word survives: \(word)")
      }
      for word in ["QuotedNeedle", "ScriptNeedle", "HiddenNeedle", "decoy"] { #expect(try store.search(word).total == 0) }
    }

    /// A pre-recipe28 disposable index, with the old normalization applied to
    /// the same real immutable sources. Fixture changes never publish content.
    func retireTo28() throws {
      let database = try store.prepareDatabase()
      try database.run("BEGIN IMMEDIATE")
      do {
        for event in ["insert", "update", "delete"] { try database.run("DROP TRIGGER search_recipe_" + event) }
        let rows = try database.rows("SELECT s.address,b.data FROM search_entries s JOIN records r ON r.address=s.address JOIN blobs b ON b.hash=r.hash")
        for row in rows {
          let fragment = try database.decodeFragmentEnvelope(row[1].blob!), value = fragment.value
          let source = value["source"]?.string ?? ""
          let text = fragment.collection == "items" ? value["title"]?.string ?? "" : source.isEmpty ? value["html"]?.string ?? "" : source
          let old = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
          if old.isEmpty { try database.run("DELETE FROM search_entries WHERE address=?", [.text(fragment.address)]) }
          else { try database.run("UPDATE search_entries SET plain_text=?,folded=? WHERE address=?",
            [.text(old), .text(NotebookStore.foldedSearchText(old)), .text(fragment.address)]) }
        }
        try database.run("DELETE FROM metadata WHERE key='search_recipe'")
        try database.run("PRAGMA user_version=28")
        try database.run("COMMIT")
      } catch { try? database.run("ROLLBACK"); throw error }
    }
  }

  @Test func authoredAnglesAndVisibleLabelsAgreeWithSearchAndReferencePreviews() throws {
    let fixture = try Fixture(), store = fixture.store
    try fixture.requireHits()
    let result = try #require(try store.search("<PageNeedle>").results.first)
    #expect(result.preview == "vector<PageNeedle>" && result.elementID == "native")
    #expect(result.reference.label == result.preview)
    #expect(result.reference.revision == (try store.referenceRevision(target: result.target, elementID: result.elementID)))
    #expect(try store.search("<").results.contains { $0.elementID == "graphic" })
    #expect(try store.readPageElement(pageID: fixture.pageID, elementID: "native")?.source == "vector<PageNeedle>")
    #expect(try store.readPageElement(pageID: fixture.pageID, elementID: "graphic")?.graphic?.label == "<PageGraphicNeedle>")
  }

  @Test func current28RebuildChangesOnlyTheDisposableIndexAndRejectsOldContinuation() throws {
    let fixture = try Fixture(), store = fixture.store
    let token = try #require(try store.search("Needle", limit: 1).coverage.next)
    let tokenBytes = try #require(Data(base64Encoded: token))
    let oldToken = try JSONDecoder().decode(JSONValue.self, from: tokenBytes)
      .setting("version", .number(1))
    try fixture.retireTo28()
    let before = try rawSnapshot(NotebookSQLConnection(url: store.databaseURL, writable: false))
    _ = try NotebookStore(root: store.root).prepareDatabase()
    #expect(try snapshot(store) == before)
    try fixture.requireHits()
    #expect(try store.sqlRead { try $0.rows("PRAGMA user_version").first?[0].integer } == 29)
    #expect(try store.sqlRead { try $0.rows("SELECT value FROM metadata WHERE key='search_recipe'").first?[0].text } == "1")
    let stale = try JSONEncoder().encode(oldToken).base64EncodedString()
    do { _ = try store.search("Needle", limit: 1, next: stale); Issue.record("A cursor from the previous recipe was accepted") }
    catch let error as CollaborationError { #expect(error.code == "invalid_search_cursor") }
    let page = try store.search("Needle", limit: 1)
    let next = try #require(page.coverage.next)
    #expect(try store.search("Needle", limit: 2, next: next).results.first?.reference.id != page.results.first?.reference.id)
  }

  @Test func interruptedRebuildRollsBackItsIndexRecipeAndAdmissionVersionTogether() throws {
    let fixture = try Fixture(), store = fixture.store
    try fixture.retireTo28()
    // Read through raw SQLite, so this assertion cannot itself start admission.
    let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
    let sourceBefore = try rawSnapshot(database), indexBefore = try database.rows("SELECT address,plain_text,folded FROM search_entries ORDER BY address").map { $0.map { $0.text! } }
    let failed = NotebookStore(root: store.root) { if $0 == .beforeCommit { throw CocoaError(.fileWriteUnknown) } }
    #expect(throws: CocoaError.self) { _ = try failed.prepareDatabase() }
    #expect(try rawSnapshot(database) == sourceBefore)
    #expect(try database.rows("SELECT address,plain_text,folded FROM search_entries ORDER BY address").map { $0.map { $0.text! } } == indexBefore)
    #expect(try database.rows("PRAGMA user_version").first?[0].integer == 28)
    #expect(try database.rows("SELECT value FROM metadata WHERE key='search_recipe'").isEmpty)
    #expect(try database.rows("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'search_recipe_%'").isEmpty)
    _ = try store.prepareDatabase()
    try fixture.requireHits()
  }

  enum OldMutation: String, Sendable { case insert, update, delete, foreignKeyDelete }
  @Test(arguments: [OldMutation.insert, .update, .delete, .foreignKeyDelete])
  func anAlreadyOpened28HandleCannotPublishAnOldRecipeAfter29Commits(mutation: OldMutation) throws {
    let fixture = try Fixture(), store = fixture.store
    try fixture.retireTo28()
    var old: OpaquePointer?
    #expect(sqlite3_open_v2(store.databaseURL.path, &old, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
    let legacy = try #require(old)
    defer { sqlite3_close(legacy) }
    #expect(sqlite3_exec(legacy, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK)
    let address = pageFile(fixture.pageID) + "#/elements/@native"
    let sql: String
    switch mutation {
    case .insert: sql = "INSERT INTO search_entries(address,kind,owner_id,plain_text,folded) VALUES('\(address)','page','\(fixture.pageID)','old','old') ON CONFLICT(address) DO UPDATE SET plain_text=excluded.plain_text,folded=excluded.folded"
    case .update: sql = "UPDATE search_entries SET plain_text='old',folded='old' WHERE address='\(address)'"
    case .delete: sql = "DELETE FROM search_entries WHERE address='\(address)'"
    case .foreignKeyDelete: sql = "DELETE FROM records WHERE address='\(address)'"
    }
    var oldStatement: OpaquePointer?
    #expect(sqlite3_prepare_v2(legacy, sql, -1, &oldStatement, nil) == SQLITE_OK)
    let prepared = try #require(oldStatement)
    defer { sqlite3_finalize(prepared) }
    _ = try store.prepareDatabase()
    let before = try snapshot(store)
    #expect(sqlite3_exec(legacy, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_exec(legacy, "UPDATE blobs SET data=x'00' WHERE hash=(SELECT hash FROM records WHERE address='\(address)')", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_step(prepared) != SQLITE_DONE)
    #expect(String(cString: sqlite3_errmsg(legacy)).contains("notebook_search_recipe"))
    sqlite3_reset(prepared)
    #expect(sqlite3_exec(legacy, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    #expect(try snapshot(store) == before)
    try fixture.requireHits()
    var document = try store.loadDocument(fixture.documentID)
    let changed = document.replaceContent(files: [.init(id: "source", path: "main.tex", source: "<CurrentWriterNeedle>")], actor: fixture.actor)
    #expect(changed)
    _ = try store.saveMergedDocument(document)
    #expect(try store.search("CurrentWriterNeedle").total == 1)
    #expect(try store.search("DocumentNeedle").total == 0)
  }

  @Test func aCurrentDatabaseWithAnUnknownRecipeFailsAdmissionBeforeWriting() throws {
    let fixture = try Fixture(), store = fixture.store, database = try store.prepareDatabase()
    try database.run("UPDATE metadata SET value='999' WHERE key='search_recipe'")
    #expect(throws: NotebookStorageError.unsupportedFormat) { _ = try store.prepareDatabase() }
    #expect(try database.rows("PRAGMA user_version").first?[0].integer == 29)
  }

  private func snapshot(_ store: NotebookStore) throws -> [[String]] {
    try store.sqlRead(rawSnapshot)
  }
  private func rawSnapshot(_ database: NotebookSQLConnection) throws -> [[String]] {
    let rows = try database.rows("SELECT address,hash,position FROM records ORDER BY address")
      + database.rows("SELECT hash,data FROM blobs ORDER BY hash")
      + database.rows("SELECT key,value FROM metadata WHERE key<>'search_recipe' ORDER BY key")
      + database.rows("SELECT sequence,transaction_id,manifest_hash,byte_count FROM change_log ORDER BY sequence")
      + database.rows("SELECT peer_id,direction,sequence FROM peer_cursors ORDER BY peer_id,direction")
    return rows.map { $0.map { $0.text ?? $0.integer.map(String.init) ?? $0.blob?.base64EncodedString() ?? "null" } }
  }
}
