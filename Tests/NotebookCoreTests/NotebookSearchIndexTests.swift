import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Search follows addressed committed sources")
struct NotebookSearchIndexTests {
  private final class SQLWork {
    var steps: Int64 = 0
    func attach(_ database: NotebookSQLConnection) {
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_PROFILE), { _, pointer, raw, _ in
        guard let pointer, let raw else { return 0 }
        let work = Unmanaged<SQLWork>.fromOpaque(pointer).takeUnretainedValue()
        work.steps += Int64(sqlite3_stmt_status(OpaquePointer(raw), SQLITE_STMTSTATUS_VM_STEP, 1))
        return 0
      }, Unmanaged.passUnretained(self).toOpaque())
    }
  }
  private func fixture(_ body: (NotebookStore, UUID, UUID, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let page = index.items[0].pageIDs[0], document = UUID()
    _ = index.createDocument(title: "Ёжик внутри Каталога", actor: actor, documentID: document)
    _ = board.addItem(document, to: header.rootBoardID, near: .zero, actor: actor)
    try store.saveDocumentWorkspaceBundle(index: index, document: .init(id: document, actor: actor, files: [DocumentFile(id: "CamelCaseBlock", path: "CamelCaseBlock" + ".tex", source: "Café. Приветствие русского ТЕКСТА.")]), state: .init(id: document, actor: actor), board: board)
    let before = try store.loadBoard(items: index.items)
    var after = before
    _ = after.upsertElement(.init(id: "CamelCaseElement", surface: .board(header.rootBoardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 200, height: 120), worldOrigin: .zero, source: "Непрерывность движения", stamp: .init(counter: 0, actor: actor)), in: header.rootBoardID, expected: nil, actor: actor)
    _ = try store.saveBoardEdits(before: before, after: after)
    try body(store, actor, header.rootBoardID, document, page)
  }

  @Test func RussianMixedCaseAccentsAndOneOrTwoCharacterSubstringsKeepTheirMeaning() throws {
    try fixture { store, _, board, document, _ in
      for query in ["ж", "ри", "нут", "катАЛО", "ежик"] {
        #expect(try store.search(query).results.contains { $0.target == .init(kind: .cover, id: document, boardID: board) })
      }
      for query in ["ПрИвЕт", "ВЕТСТВ", "ТЕ", "а", "cafe", "é"] {
        let hits = try store.search(query)
        #expect(hits.results.contains { $0.elementID == "CamelCaseBlock" && $0.target.kind == .document })
      }
      let limited = try store.search("р", limit: 1)
      #expect(limited.results.count == 1 && limited.total >= 3 && limited.truncated)
      let semantic = try store.search("движен").results.first
      #expect(semantic?.target == .init(kind: .board, id: board))
      #expect(try semantic?.reference.revision == store.referenceRevision(target: .init(kind: .board, id: board), elementID: "CamelCaseElement"))
    }
  }

  @Test func AQueryDoesNotDecodeUnrelatedPaperAndRollbackDoesNotPublishItsIndex() throws {
    try fixture { store, actor, board, document, page in
      try store.fixtureWrite(Data("damaged unrelated page".utf8), to: store.pageURL(page))
      #expect(try store.search("Café").results.first?.target.id == document)
      let cursor = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root) { point in if point == .beforeCommit { throw CocoaError(.fileWriteUnknown) } }
      #expect(throws: CocoaError.self) { try updateTestNativeText(store:failing,boardID: board, elementID: "CamelCaseElement", text: "Новый исходник", finish: false, actor: actor) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.search("движения").total == 1)
      #expect(try store.search("Новый").total == 0)
      _ = try updateTestNativeText(store:store,boardID: board, elementID: "CamelCaseElement", text: "Новый исходник", finish: false, actor: actor)
      #expect(try store.search("движения").total == 0)
      #expect(try store.search("НОВ").total == 1)
      _ = try store.deleteTestItem(itemID: document, actor: actor)
      #expect(try store.search("cafe").total == 0)
      #expect(try store.search("каталог").total == 0)
    }
  }

  @Test func limitedSearchExposesAContinuationInsteadOfHidingMatches() throws {
    try fixture { store, _, _, _, _ in
      let result = try JSONValue.encode(store.search("р", limit: 1))
      #expect(result["coverage"]?["complete"] == .bool(false))
      #expect(result["coverage"]?["next"]?.string != nil)
    }
  }

  @Test(arguments: [1, 4, 7])
  func allMatchingFilesAreReachableWithStableTieBreakersAndChangingPageSizes(size: Int) throws {
    try fixture { store, actor, board, documentID, _ in
      var document = try store.loadDocument(documentID)
      let files = (0..<23).map { DocumentFile(id: String(format: "part-%02d", $0), path: String(format: "part-%02d.tex", $0), source: "needle одинаковый текст") }
      let changed = document.replaceContent(files: files, actor: actor)
      #expect(changed)
      _ = try store.saveMergedDocument(document)
      let filters = NotebookSearchFilters(kinds: [.document], target: .init(kind: .document, id: documentID))
      var next: String?, found: [String] = [], calls = 0
      repeat {
        let result = try store.search("NEEDLE", limit: calls.isMultiple(of: 2) ? size : 3, filters: filters, next: next)
        found += result.results.compactMap(\.elementID)
        #expect(result.total == 23)
        #expect(result.coverage.complete == (result.coverage.next == nil))
        next = result.coverage.next; calls += 1
        // Local presence is not a source commit and must not invalidate search.
        try store.savePresence(.init(boardID: board, mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)))
        #expect(calls <= 23)
      } while next != nil && calls <= 23
      #expect(found == files.map(\.id))
      #expect(Set(found).count == 23)
      let empty = try store.search("absent-needle", limit: size, filters: filters)
      #expect(empty.results.isEmpty && empty.total == 0 && empty.coverage.complete && empty.coverage.next == nil)
    }
  }

  @Test func sourceChangesInvalidateContinuationRatherThanMixingSnapshots() throws {
    try fixture { store, actor, board, _, _ in
      let page = try store.search("р", limit: 1), next = try #require(page.coverage.next)
      _ = try updateTestNativeText(store:store,boardID: board, elementID: "CamelCaseElement", text: "Другой материал", finish: false, actor: actor)
      do { _ = try store.search("р", limit: 1, next: next); Issue.record("A stale cursor was accepted") }
      catch let error as CollaborationError { #expect(error.code == "search_cursor_stale") }
    }
  }

  @Test func continuationRejectsDifferentQueryFiltersWorkspaceAndMalformedTokens() throws {
    try fixture { store, _, _, _, _ in
      let next = try #require(try store.search("р", limit: 1).coverage.next)
      for operation in [
        { try store.search("д", next: next) },
        { try store.search("р", filters: .init(kinds: [.document]), next: next) },
      ] {
        do { _ = try operation(); Issue.record("Mismatched search cursor accepted") }
        catch let error as CollaborationError { #expect(error.code == "search_cursor_mismatch") }
      }
      try fixture { other, _, _, _, _ in
        do { _ = try other.search("р", next: next); Issue.record("Foreign workspace accepted") }
        catch let error as CollaborationError { #expect(error.code == "search_cursor_mismatch") }
      }
      for token in ["broken", "e30=", String(repeating: "x", count: 16_385)] {
        do { _ = try store.search("р", next: token); Issue.record("Malformed token accepted") }
        catch let error as CollaborationError { #expect(error.code == "invalid_search_cursor") }
      }
      #expect(throws: CollaborationError.self) { try store.search("р", filters: .init(kinds: [])) }
    }
  }

  @Test(arguments: [true, false])
  func insertingOrRemovingAMatchInvalidatesTheOldPage(insert: Bool) throws {
    try fixture { store, actor, _, documentID, _ in
      let next = try #require(try store.search("р", limit: 1).coverage.next)
      var document = try store.loadDocument(documentID)
      let changed = document.replaceContent(files: insert ? document.files + [DocumentFile(id: "new", path: "new" + ".tex", source: "Результат")]
        : [], actor: actor)
      #expect(changed)
      _ = try store.saveMergedDocument(document)
      do { _ = try store.search("р", next: next); Issue.record("Changed membership mixed search pages") }
      catch let error as CollaborationError { #expect(error.code == "search_cursor_stale") }
    }
  }

  @Test func countAndPageSelectionDoNotDecodeUnselectedMatchingBodies() throws {
    try fixture { store, actor, _, documentID, _ in
      var document = try store.loadDocument(documentID)
      let changed = document.replaceContent(files: (0..<512).map {
        .init(id: String(format: "match-%04d", $0), path: String(format: "match-%04d.tex", $0), source: "needle \($0)")
      }, actor: actor)
      #expect(changed)
      _ = try store.saveMergedDocument(document)
      try store.commandTransaction {
        try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
          [.blob(Data("unselected matching body".utf8)), .text(documentFile(documentID) + "#/files/@match-0511")])
      }
      let counter = SQLWork()
      let page = try store.readTransaction { _ in
        counter.attach(store.currentSQL!)
        defer { sqlite3_trace_v2(store.currentSQL!.handle, 0, nil, nil) }
        return try store.search("needle", limit: 1)
      }
      #expect(page.total == 512 && page.results.count == 1 && !page.coverage.complete)
      #expect(page.results.first?.elementID == "match-0000")
      #expect(counter.steps > 0 && counter.steps < 100_000)
      print("Search 512 matches: total+keys+one body SQL instructions=\(counter.steps)")
    }
  }

  @Test(arguments: ["source", "address", "workspace"])
  func aPreparedIndexCannotInstallAgainstDifferentAuthoredInputs(mismatch: String) throws {
    try fixture { store, _, _, documentID, _ in
      let address = documentFile(documentID) + "#/files/@CamelCaseBlock"
      let input = NotebookSearchInput(documentID: documentID, fileID: "CamelCaseBlock", source: "PreparedOnlyNeedle")
      let workspace = mismatch == "workspace" ? UUID() : try store.storedWorkspaceID()
      let prepared = try NotebookPreparedSearchEntry(input: input, workspaceID: workspace)
      let original = try #require(try store.storedFragments(address: address, descendants: false).first)
      let value = original.value.setting("source", .string(mismatch == "source" ? "DifferentLiteralNeedle" : input.source))
      let changed: NotebookStoredFragment
      if mismatch == "address" {
        changed = .init(address: documentFile(documentID) + "#/files/@DifferentBlock", file: original.file,
          parent: original.parent, collection: original.collection, member: "DifferentBlock", position: 0,
          value: value.setting("id", .string("DifferentBlock")), collections: original.collections)
      } else { changed = original.replacing(value: value) }
      let revision = try store.currentReadCursor(), cursor = try store.currentChangeCursor()
      let previous = try store.sqlRead { try $0.rows("SELECT plain_text FROM search_entries WHERE address=?", [.text(address)]).first?[0].text }
      do {
        try store.commandTransaction {
          _ = try store.writeFragment(changed, database: store.currentSQL!, preparedSearch: prepared)
        }
        Issue.record("A prepared index accepted a different literal source or owner")
      } catch let error as NotebookStorageError {
        #expect(mismatch != "workspace" && error == .invalidTransaction("prepared search source mismatch"))
      } catch let error as NotebookStoreError {
        if case .workspaceChanged = error { #expect(mismatch == "workspace") }
        else { Issue.record("The prepared owner refused for an unrelated store error") }
      }
      #expect(try store.storedFragments(address: address, descendants: false).first == original)
      #expect(try store.storedFragments(address: documentFile(documentID) + "#/files/@DifferentBlock", descendants: false).isEmpty)
      #expect(try store.currentReadCursor() == revision && store.currentChangeCursor() == cursor)
      #expect(try store.sqlRead { try $0.rows("SELECT plain_text FROM search_entries WHERE address=?", [.text(address)]).first?[0].text } == previous)
      #expect(try store.search("PreparedOnlyNeedle").total == 0)
      #expect(try store.search("DifferentLiteralNeedle").total == 0)
    }
  }

  @Test func nativeSourceAdmissionRejectsRetainedRegisterBodiesBeforeCapture() throws {
    let version = ContentFieldVersion(stamp: .init(counter: 1, actor: UUID()), human: true)
      .retainingValue(.string(String(repeating: "x", count: 9 * 1_024 * 1_024)))
    let edit = DocumentSourceEdit(sessionID: UUID(), documentID: UUID(), fileID: "main",
      baseSource: "before", baseVersion: version, source: "after", sequence: 1)
    #expect(version.isValid && version.hasRetainedAlternatives)
    #expect(throws: NotebookStorageError.limitExceeded("document_source_preparation")) {
      try PreparedDocumentSourceEdit.cost(for: edit)
    }
  }

  @Test(arguments: [false, true])
  func actualDistinctGramAndEscapedFinishCostsRefuseBeforeSourcePublication(escaped: Bool) throws {
    try fixture { store, _, _, documentID, _ in
      let original = try #require(try store.readDocumentFile(documentID: documentID, fileID: "CamelCaseBlock"))
      let source: String
      if escaped { source = String(repeating: "\0", count: 3 * 1_024 * 1_024) }
      else {
        // All supplementary scalars are valid. Their distinctness forces the
        // actual gram table's growth rather than a small repeated-text Set.
        var value = String(); value.reserveCapacity(DocumentFile.maximumSourceLength)
        for codepoint in 0x1_0000..<0x11_0000 { value.unicodeScalars.append(Unicode.Scalar(codepoint)!) }
        source = value
      }
      #expect(source.utf8.count <= DocumentFile.maximumSourceLength)
      let edit = DocumentSourceEdit(sessionID: UUID(), documentID: documentID, fileID: original.file.id,
        baseSource: original.file.source, baseVersion: original.sourceVersion, source: source, sequence: 1)
      let initial = try PreparedDocumentSourceEdit.cost(for: edit)
      #expect(initial.bytes <= PreparedDocumentSourceEdit.maximumPreparationBytes)
      let cursor = try store.currentChangeCursor(), revision = try store.currentReadCursor()
      do {
        _ = try PreparedDocumentSourceEdit(edit: edit, workspaceID: store.storedWorkspaceID())
        Issue.record("An actual oversized gram table or escaped writer finish was admitted")
      } catch let error as NotebookStorageError {
        #expect(error == .limitExceeded(escaped ? "document_source_preparation" : "search_preparation_memory"))
      }
      #expect(try store.readDocumentFile(documentID: documentID, fileID: original.file.id) == original)
      #expect(try store.currentReadCursor() == revision && store.currentChangeCursor() == cursor)
      #expect(try store.documentEditingSessions().isEmpty)
      #expect(try store.search("cafe").total == 1)
    }
  }
}
