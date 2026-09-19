import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Search follows addressed committed sources")
struct NotebookSearchIndexTests {
  private func fixture(_ body: (NotebookStore, UUID, UUID, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let page = index.items[0].pageIDs[0], document = UUID()
    _ = index.createDocument(title: "Ёжик внутри Каталога", actor: actor, documentID: document)
    _ = board.addItem(document, to: header.rootBoardID, near: .zero, actor: actor)
    try store.saveDocumentWorkspaceBundle(index: index, document: .init(id: document, actor: actor, blocks: [.markdown(id: "CamelCaseBlock", source: "Café. Приветствие русского ТЕКСТА.")]), state: .init(id: document, actor: actor), board: board)
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
      _ = try store.deleteWorkspaceItem(itemID: document, actor: actor)
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
  func allMatchingBlocksAreReachableWithStableTieBreakersAndChangingPageSizes(size: Int) throws {
    try fixture { store, actor, board, documentID, _ in
      var document = try store.loadDocument(documentID)
      let blocks = (0..<23).map { DocumentBlock.markdown(id: String(format: "block-%02d", $0), source: "needle одинаковый текст") }
      let changed = document.replaceContent(blocks: blocks, actor: actor)
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
      #expect(found == blocks.map(\.id))
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
      let changed = document.replaceContent(blocks: insert ? document.blocks + [.markdown(id: "new", source: "Результат")]
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
      let changed = document.replaceContent(blocks: (0..<512).map {
        .markdown(id: String(format: "match-%04d", $0), source: "needle \($0)")
      }, actor: actor)
      #expect(changed)
      _ = try store.saveMergedDocument(document)
      try store.commandTransaction {
        try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
          [.blob(Data("unselected matching body".utf8)), .text(documentFile(documentID) + "#/blocks/@match-0511")])
      }
      let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
      counter.initialize(to: 0); defer { counter.deinitialize(count: 1); counter.deallocate() }
      let page = try store.readTransaction { _ in
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { pointer in
          let counter = pointer!.assumingMemoryBound(to: Int.self)
          counter.pointee += 1; return counter.pointee > 100_000 ? 1 : 0
        }, counter)
        defer { sqlite3_progress_handler(store.currentSQL!.handle, 0, nil, nil) }
        return try store.search("needle", limit: 1)
      }
      #expect(page.total == 512 && page.results.count == 1 && !page.coverage.complete)
      #expect(page.results.first?.elementID == "match-0000")
      print("Search 512 matches: total+keys+one body SQL instructions=\(counter.pointee)")
    }
  }
}
