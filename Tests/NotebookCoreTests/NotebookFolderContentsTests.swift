import Foundation
import Testing
@testable import NotebookCore

@Suite("Folder contents are independent of the visible board window")
struct NotebookFolderContentsTests {
  private func fixture(_ body: (NotebookStore, UUID, WorkspaceIndex, BoardHierarchy, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), tree = try store.loadBoard(items: index.items)
    let created = index.createBoard(title: "Исследования", actor: actor)
    let folder = try #require(created)
    let createdBoard = tree.createBoard(folder.id, in: header.rootBoardID, near: .zero, actor: actor)
    #expect(createdBoard)
    try store.saveBoardWorkspaceBundle(index: index, board: tree, boardID: folder.id)
    #expect(try !store.boardHasContent(folder.id))
    try body(store, actor, index, tree, folder.id)
  }

  @Test(arguments: [WorkspaceItemKind.notebook, .document, .board])
  func everyChildKindMarksTheFolderAndRemovingItRestoresEmpty(kind: WorkspaceItemKind) throws {
    try fixture { store, actor, original, originalTree, folder in
      var index = original, tree = originalTree
      let id: UUID
      switch kind {
      case .notebook:
        let created = index.createNotebook(title: "Тетрадь", actor: actor, pageSize: .init(width: 834, height: 1194))
        let notebook = try #require(created)
        id = notebook.item.id
        let addedNotebook = tree.addItem(id, to: folder, near: .init(x: 90_000, y: -90_000), actor: actor)
        #expect(addedNotebook)
        try store.saveWorkspaceBundle(index: index, page: notebook.page, board: tree)
      case .document:
        let created = index.createDocument(title: "Документ", actor: actor)
        id = try #require(created).id
        let addedDocument = tree.addItem(id, to: folder, near: .init(x: 90_000, y: -90_000), actor: actor)
        #expect(addedDocument)
        try store.saveDocumentWorkspaceBundle(index: index, document: .init(id: id, actor: actor),
          state: .init(id: id, actor: actor), board: tree)
      case .board:
        let created = index.createBoard(title: "Вложенная папка", actor: actor)
        id = try #require(created).id
        let createdChild = tree.createBoard(id, in: folder, near: .init(x: 90_000, y: -90_000), actor: actor)
        #expect(createdChild)
        try store.saveBoardWorkspaceBundle(index: index, board: tree, boardID: id)
      }
      #expect(try store.boardHasContent(folder))
      _ = try store.deleteTestItem(itemID: id, actor: actor)
      #expect(try !store.boardHasContent(folder), "Placement tombstones are not content")
    }
  }

  @Test func distantTextAndDrawingCountButCoverInkAndInactiveInkDoNot() throws {
    try fixture { store, actor, index, originalTree, folder in
      var tree = originalTree
      let element = SpatialElement(id: "far-away", surface: .board(folder), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 200, height: 60), worldOrigin: .init(x: 100_000, y: 100_000),
        source: "Не только тетради", stamp: .init(counter: 0, actor: actor))
      let insertedText = tree.upsertElement(element, in: folder, expected: nil, actor: actor)
      #expect(insertedText)
      try store.saveBoard(tree, items: index.items)
      #expect(try store.boardHasContent(folder))
      let removedText = tree.removeElements(ids: [element.id], from: folder, actor: actor)
      #expect(removedText == 1)
      try store.saveBoard(tree, items: index.items)
      #expect(try !store.boardHasContent(folder))
      func span(_ surface: SurfaceID) -> SpatialInkSpan {
        .init(surface: surface, samples: [.init(point: .init(x: 10, y: 20),
          worldPoint: surface.kind == .board ? .init(x: 100_000, y: 100_000) : nil,
          timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
      }
      var ink = try store.readSpatialInk(surfaces: [.board(folder), .cover(folder)])
      _ = ink.append(tool: .pen, spans: [span(.cover(folder))], actor: actor)
      _ = ink.append(tool: .eraser, spans: [span(.board(folder))], actor: actor)
      try store.saveSpatialInk(ink)
      #expect(try !store.boardHasContent(folder))
      let appended = ink.append(tool: .pen, spans: [span(.board(folder))], actor: actor)
      let pen = try #require(appended)
      try store.saveSpatialInk(ink)
      #expect(try store.boardHasContent(folder))
      let deactivatedPen = ink.deactivate(pen.id, actor: actor)
      #expect(deactivatedPen)
      try store.saveSpatialInk(ink)
      #expect(try !store.boardHasContent(folder))
    }
  }

  @Test func oneHundredThousandDistantElementsDoNotEnterTheFolderCoverRead() throws {
    try fixture { store, actor, _, _, folder in
      let parent = "board.json#/boards/@" + folder.uuidString.lowercased()
      try store.commandTransaction {
        for index in 0..<100_000 {
          let element = SpatialElement(id: "distant-\(index)", surface: .board(folder), kind: .nativeText,
            frame: .init(x: 0, y: 0, width: 40, height: 20),
            worldOrigin: .init(x: Double(index + 1) * 5000, y: 100_000), source: "Текст",
            stamp: .init(counter: 0, actor: actor))
          try store.writeFragment(.init(address: parent + "/board/elements/@" + element.id,
            file: "board.json", parent: parent, collection: "board/elements", member: element.id,
            position: index, value: try .encode(element), collections: []), database: store.currentSQL!)
        }
      }
      let started = ContinuousClock.now
      for _ in 0..<100 { #expect(try store.boardHasContent(folder)) }
      print("FOLDER_CONTENTS_SCALE elements=100000 reads=100 elapsed=\(started.duration(to: .now))")
      #expect(try store.readBoardNodeHeader(folder)?.board.elements.isEmpty == true)
    }
  }
}
