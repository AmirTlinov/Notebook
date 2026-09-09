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
      #expect(throws: CocoaError.self) { try failing.updateNativeSpatialText(boardID: board, elementID: "CamelCaseElement", text: "Новый исходник", finish: false, actor: actor) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.search("движения").total == 1)
      #expect(try store.search("Новый").total == 0)
      _ = try store.updateNativeSpatialText(boardID: board, elementID: "CamelCaseElement", text: "Новый исходник", finish: false, actor: actor)
      #expect(try store.search("движения").total == 0)
      #expect(try store.search("НОВ").total == 1)
      _ = try store.deleteWorkspaceItem(itemID: document, actor: actor)
      #expect(try store.search("cafe").total == 0)
      #expect(try store.search("каталог").total == 0)
    }
  }
}
