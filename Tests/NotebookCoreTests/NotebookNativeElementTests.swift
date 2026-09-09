import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed native element commands")
struct NotebookNativeElementTests {
  private func fixture(id: String = "editor", _ body: (NotebookStore, UUID, UUID, SpatialElement) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let index = try store.loadIndex(), before = try store.loadBoard(items: index.items)
    let element = SpatialElement(id: id, surface: .cover(index.items[0].id), kind: .nativeText,
      frame: .init(x: 10, y: 20, width: 200, height: 90), source: "original", stamp: .init(counter: 0, actor: actor))
    var after = before
    _ = after.upsertElement(element, in: header.rootBoardID, expected: nil, actor: actor)
    _ = try store.saveBoardEdits(before: before, after: after)
    try body(store, actor, header.rootBoardID, element)
  }

  @Test func AddressedElementIDsNormalizeOnlyUUIDsAndKeepCaseSensitiveNames() throws {
    for id in [UUID().uuidString, "CamelCaseElement"] {
      try fixture(id: id) { store, actor, board, element in
        #expect(try store.readSpatialElement(boardID: board, elementID: id) == element)
        let window = try store.readSceneWindow(boardID: board, bounds: .init(origin: .zero, width: 1, height: 1), limit: 2, pinnedElementIDs: [id])
        #expect(window.boards[0].board.elements.map(\.id) == [id])
        #expect(try store.updateNativeSpatialText(boardID: board, elementID: id, text: "changed", finish: false, actor: actor)?.source == "changed")
        if UUID(uuidString: id) == nil { #expect(try store.readSpatialElement(boardID: board, elementID: id.lowercased()) == nil) }
      }
    }
  }

  @Test func finishingTextWorksWithoutAMountedOwnerAndLateInputCannotRecreateIt() throws {
    try fixture { store, actor, board, _ in
      let start = try store.currentChangeCursor()
      let updated = try store.updateNativeSpatialText(boardID: board, elementID: "editor", text: "after navigation", finish: true, actor: actor)
      #expect(updated?.source == "after navigation")
      #expect(try store.readSpatialElement(boardID: board, elementID: "editor") == updated)
      _ = try store.updateNativeSpatialText(boardID: board, elementID: "editor", text: "", finish: false, actor: actor)
      #expect(try store.readSpatialElement(boardID: board, elementID: "editor")?.source == "")
      #expect(try store.updateNativeSpatialText(boardID: board, elementID: "editor", text: "", finish: true, actor: actor) == nil)
      let deleted = try store.currentChangeCursor()
      #expect(try store.updateNativeSpatialText(boardID: board, elementID: "editor", text: "late", finish: true, actor: actor) == nil)
      #expect(try store.currentChangeCursor() == deleted)
      let addresses = try store.readChangedAddresses(after: start, through: deleted, limit: 1)
      #expect(addresses.addresses.count == 1 && addresses.hasMore)
    }
  }

  @Test func stateReadsCurrentGeometryAndRejectsAnOldProgram() throws {
    try fixture { store, actor, board, rendered in
      let index = try store.loadIndex(), before = try store.loadBoard(items: index.items)
      var current = try #require(try store.readSpatialElement(boardID: board, elementID: rendered.id))
      let frame = SpatialRect(x: 70, y: 80, width: 240, height: 100)
      _ = current.update(frame: frame, actor: UUID())
      var moved = before
      _ = moved.upsertElement(current, in: board, expected: rendered.stamp, actor: actor)
      _ = try store.saveBoardEdits(before: before, after: moved)
      let state: JSONValue = .object(["value": .number(19)])
      let committed = try store.commitSpatialElementState(boardID: board, rendered: rendered, state: state, actor: actor)
      #expect(committed?.state == state && committed?.frame == frame)
      _ = try store.updateNativeSpatialText(boardID: board, elementID: rendered.id, text: "new source", finish: false, actor: actor)
      let cursor = try store.currentChangeCursor()
      #expect(throws: CollaborationError.self) { try store.commitSpatialElementState(boardID: board, rendered: rendered, state: .number(20), actor: actor) }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func offscreenPinsRetainTheirCarrierAndRejectAnInsufficientBudget() throws {
    try fixture { store, actor, board, element in
      let owner = try #require(element.surface.ownerID)
      #expect(try store.moveWorkspaceItem(itemID: owner, in: board, to: .init(x: 50_000, y: 60_000), actor: actor))
      let bounds = WorkspaceSpatialBounds(origin: .init(x: -100, y: -100), width: 200, height: 200)
      let window = try store.readSceneWindow(boardID: board, bounds: bounds, limit: 2, pinnedElementIDs: [element.id])
      #expect(window.items.map(\.id) == [owner])
      #expect(window.boards[0].board.elements.map(\.id) == [element.id])
      #expect(window.boards[0].board.collaboration?.fields["elements/editor/exists"] != nil)
      #expect(window.totalMatches == 2)
      #expect(throws: NotebookStorageError.limitExceeded("scene_pins")) {
        try store.readSceneWindow(boardID: board, bounds: bounds, limit: 1, pinnedElementIDs: [element.id])
      }
      #expect(try store.moveWorkspaceItem(itemID: owner, in: UUID(), to: .zero, actor: actor) == false)
    }
  }

  @Test func changedRecordsBindBothHistoricalVersionsIncludingTombstones() throws {
    try fixture { store, actor, board, _ in
      let start = try store.currentChangeCursor()
      let address = "board.json#/boards/@" + board.uuidString.lowercased() + "/board/elements/@editor"
      let original = try #require(try store.currentRecordHash(address))
      _ = try store.updateNativeSpatialText(boardID: board, elementID: "editor", text: "updated", finish: false, actor: actor)
      let updatedCursor = try store.currentChangeCursor(), updated = try #require(try store.currentRecordHash(address))
      _ = try store.updateNativeSpatialText(boardID: board, elementID: "editor", text: "", finish: true, actor: actor)
      let deletedCursor = try store.currentChangeCursor()
      let historical = try #require(try store.readChangedAddresses(after: start, through: updatedCursor).records.first { $0.address == address })
      #expect(historical.beforeHash == original && historical.afterHash == updated)
      let removed = try #require(try store.readChangedAddresses(after: updatedCursor, through: deletedCursor).records.first { $0.address == address })
      #expect(removed.beforeHash == updated && removed.afterHash == nil)
      let creation = try #require(try store.readChangedAddresses(after: 0, through: start).records.first { $0.address == address })
      #expect(creation.beforeHash == nil && creation.afterHash == original)
    }
  }
}

private extension NotebookStore {
  func currentRecordHash(_ address: String) throws -> String? {
    try sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text }
  }
}
