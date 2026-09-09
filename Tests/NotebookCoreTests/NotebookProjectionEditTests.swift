import Foundation
import Testing
@testable import NotebookCore

@Suite("Projection order does not replace durable sequence order")
struct NotebookProjectionEditTests {
  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-projection-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor)
  }

  @Test(arguments: [WorkspaceItemKind.board, .notebook])
  func appendingAnOwnerAfterEnteringASortedPortalProjection(kind: WorkspaceItemKind) throws {
    try fixture { store, actor in
      let initial = try store.loadIndex(), initialBoard = try store.loadBoard(items: initial.items)
      let childID = UUID(uuidString: "09D24E83-E542-4708-8228-F536139EB698")!
      var first = initial, firstBoard = initialBoard
      #expect(first.createBoard(title: "", actor: actor, boardID: childID) != nil)
      let created = firstBoard.createBoard(childID, in: initial.rootBoardID, near: .zero, actor: actor)
      #expect(created)
      _ = try store.saveWorkspaceEdits(before: initial, after: first, boardBefore: initialBoard, boardAfter: firstBoard)
      var camera = firstBoard
      let changed = camera.updatePortalCamera(.init(center: .init(x: 1234, y: -567), scale: 0.8), for: childID, actor: actor)
      #expect(changed)
      _ = try store.saveBoardEdits(before: firstBoard, after: camera)

      // SceneState sorts the bounded values by UUID, not by their durable slots.
      let before = try store.workspaceProjection(items: first.items.sorted { $0.id.uuidString < $1.id.uuidString },
        selectedItemID: childID, selectedPageID: nil)
      let boardBefore = BoardHierarchy(rootBoardID: initial.rootBoardID,
        boards: camera.boards.sorted { $0.id.uuidString < $1.id.uuidString }, stamp: camera.stamp)
      #expect(boardBefore.boards.map(\.id) == [childID, initial.rootBoardID])
      var after = before, boardAfter = boardBefore
      var pages: [PageDocument] = []
      let nextID = UUID(uuidString: "19D24E83-E542-4708-8228-F536139EB698")!
      if kind == .board {
        #expect(after.createBoard(title: "", actor: actor, boardID: nextID) != nil)
        let inserted = boardAfter.createBoard(nextID, in: childID, near: .zero, actor: actor)
        #expect(inserted)
      } else {
        let result = after.createNotebook(title: "", actor: actor, pageSize: .init(width: 834, height: 1194), itemID: nextID)
        pages = [try #require(result).page]
        let inserted = boardAfter.addItem(nextID, to: childID, near: .zero, actor: actor)
        #expect(inserted)
      }
      _ = try store.saveWorkspaceEdits(before: before, after: after, boardBefore: boardBefore, boardAfter: boardAfter, pages: pages)
      let durable = try store.loadIndex(), board = try store.loadBoard(items: durable.items)
      #expect(durable.items.map(\.id) == initial.items.map(\.id) + [childID, nextID])
      #expect(board.isValid(items: durable.items))
      #expect(board.portalCamera(childID) == camera.portalCamera(childID))
      let cursor = try store.currentChangeCursor()
      _ = try store.saveWorkspaceEdits(before: before, after: after, boardBefore: boardBefore, boardAfter: boardAfter, pages: pages)
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  private func elements(_ ids: [String], store: NotebookStore, actor: UUID) throws -> BoardHierarchy {
    let index = try store.loadIndex(), before = try store.loadBoard(items: index.items)
    var after = before
    for id in ids {
      let element = SpatialElement(id: id, surface: .board(index.rootBoardID), kind: .markdown,
        frame: .init(x: 0, y: 0, width: 20, height: 20), worldOrigin: .zero, source: id, stamp: .init(counter: 0, actor: actor))
      let changed = after.upsertElement(element, in: index.rootBoardID, expected: nil, actor: actor)
      #expect(changed)
    }
    _ = try store.saveBoardEdits(before: before, after: after)
    return try store.loadBoard(items: index.items)
  }

  private func projection(_ ids: [String], from hierarchy: BoardHierarchy) throws -> BoardHierarchy {
    let node = try #require(hierarchy.boards.first)
    let chosen = ids.compactMap { id in node.board.elements.first { $0.id == id } }
    #expect(chosen.count == ids.count)
    let value = try JSONValue.encode(node.board).setting("elements", .encode(chosen)).setting("freeItems", .array([]))
    return try .init(rootBoardID: hierarchy.rootBoardID, boards: [.init(id: node.id, board: value.decode(BoardDocument.self),
      portalCamera: node.portalCamera, portalStamp: node.portalStamp)], stamp: hierarchy.stamp)
  }

  private func replacingElements(_ ids: [String], in before: BoardHierarchy, actor: UUID) throws -> BoardHierarchy {
    let node = try #require(before.boards.first), stamp = try #require(node.board.stamp.advanced(by: actor))
    let members = ids.map { id in node.board.elements.first { $0.id == id } ?? SpatialElement(id: id,
      surface: .board(node.id), kind: .markdown, frame: .init(x: 0, y: 0, width: 20, height: 20), worldOrigin: .zero, source: id, stamp: stamp) }
    let original = try JSONValue.encode(node.board)
    var value = try original.setting("elements", .encode(members)).setting("stamp", .encode(stamp))
    var metadata = node.board.collaboration ?? CollaborativeContent()
    metadata.record(before: original, after: value, beforeStamp: node.board.stamp, stamp: stamp, human: true)
    value = try value.setting("collaboration", .encode(metadata))
    return try .init(rootBoardID: before.rootBoardID, boards: [.init(id: node.id, board: value.decode(BoardDocument.self),
      portalCamera: node.portalCamera, portalStamp: node.portalStamp)], stamp: stamp)
  }

  private func positions(_ store: NotebookStore) throws -> [String: Int64] {
    try store.readTransaction { _ in
      Dictionary(uniqueKeysWithValues: try store.currentSQL!.rows("SELECT member,position FROM records WHERE collection='board/elements'").map { ($0[0].text!, $0[1].integer!) })
    }
  }

  @Test(arguments: [false, true])
  func sortedAppendAndRemovalKeepExistingAndUnseenSlots(removesMember: Bool) throws {
    try fixture { store, actor in
      let full = try elements(["z", "a", "unseen"], store: store, actor: actor)
      let before = try projection(["a", "z"], from: full), slots = try positions(store)
      let after = try replacingElements(removesMember ? ["a", "new"] : ["a", "z", "new"], in: before, actor: actor)
      _ = try store.saveBoardEdits(before: before, after: after)
      let next = try positions(store)
      #expect(next["a"] == slots["a"])
      #expect(next["unseen"] == slots["unseen"])
      #expect(next["z"] == (removesMember ? nil : slots["z"]))
      #expect(next["new"] == 3)
    }
  }

  @Test(arguments: [["new", "a", "z"], ["a", "new", "z"], ["z", "a"]])
  func explicitInsertionAndReorderPreserveTheUnseenSlot(order: [String]) throws {
    try fixture { store, actor in
      let full = try elements(["a", "unseen", "z"], store: store, actor: actor)
      let before = try projection(["a", "z"], from: full), slots = try positions(store)
      let after = try replacingElements(order, in: before, actor: actor)
      _ = try store.saveBoardEdits(before: before, after: after)
      let next = try positions(store)
      #expect(next["unseen"] == slots["unseen"])
      #expect(order.sorted { next[$0]! < next[$1]! } == order)
      let cursor = try store.currentChangeCursor()
      _ = try store.saveBoardEdits(before: before, after: after)
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func aConflictingExplicitReorderRollsBackTheEntireCommand() throws {
    try fixture { store, actor in
      let full = try elements(["a", "unseen", "b", "c"], store: store, actor: actor)
      let before = try projection(["a", "b", "c"], from: full)
      let concurrent = try replacingElements(["b", "a", "c"], in: before, actor: UUID())
      _ = try store.saveBoardEdits(before: before, after: concurrent)
      let intended = try replacingElements(["c", "b", "a"], in: before, actor: actor)
      let slots = try positions(store), cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.transactionConflict) { try store.saveBoardEdits(before: before, after: intended) }
      #expect(try positions(store) == slots)
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func errorsNameTheFailedContractInsteadOfAnUnstableEnumNumber() {
    let errors: [NotebookStorageError] = [.legacyStoreRequiresConversion, .unsupportedFormat, .corruptRecord("board.json"),
      .invalidTransaction("board cycle"), .transactionConflict, .readOnlyTransaction, .limitExceeded("scene_window"),
      .blobMissing(String(repeating: "a", count: 64)), .blobHashMismatch]
    #expect(Set(errors.map(\.localizedDescription)).count == errors.count)
    #expect(NotebookStorageError.transactionConflict.localizedDescription.contains("transaction_conflict"))
    #expect(errors.allSatisfy { !$0.localizedDescription.contains("NotebookStorageError error") })
    #expect(NotebookStorageError.invalidTransaction(String(repeating: "a", count: 10_000)).localizedDescription.count < 300)
  }
}
