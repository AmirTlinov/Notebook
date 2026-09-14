import Foundation
import Testing
@testable import NotebookCore

@Suite("Navigation resolves physical addresses outside scene coverage", .serialized)
struct NotebookReferenceLocationTests {
  private func fixture(_ body: (NotebookStore, UUID, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reference-location-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
    let created = index.createDocument(title: "Distant document", actor: actor)
    let item = try #require(created)
    let added = hierarchy.addItem(item.id, to: header.rootBoardID, near: .init(x: 90_000, y: -70_000), actor: actor)
    #expect(added)
    try store.saveDocumentWorkspaceBundle(index: index,
      document: .init(id: item.id, actor: actor, paperSize: .a4,
        blocks: [.markdown(id: "unrequested", source: "Not needed to find the document")]),
      state: .init(id: item.id, actor: actor), board: hierarchy)
    try body(store, actor, header.rootBoardID, item.id)
  }

  @Test func distantCoverAndDocumentResolveWithoutDecodingTheirBody() throws {
    try fixture { store, _, boardID, itemID in
      let expected = try #require(try store.readBoardItem(itemID)?.board.focusedCenter(of: itemID))
      // A corrupt unrequested block makes accidental eager document decoding
      // observable, instead of merely checking the resolver's return value.
      try store.commandTransaction {
        let hash = try store.currentSQL!.putBlob(Data("must not decode".utf8))
        try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash),
          .text(documentFile(itemID) + "#/blocks/@unrequested")])
      }
      let cursor = try store.currentChangeCursor()
      for kind in [CollaborationTarget.Kind.cover, .document] {
        let reference = CollaborationReference(target: .init(kind: kind, id: itemID, boardID: boardID), revision: "historical")
        #expect(try store.readReferenceLocation(reference) == .item(boardID: boardID, id: itemID,
          center: expected, geometry: .document(.a4)))
      }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func storedMovementWinsOverTheReferencesHistoricalBoardHint() throws {
    try fixture { store, actor, boardID, itemID in
      let reference = CollaborationReference(target: .init(kind: .cover, id: itemID, boardID: UUID()),
        revision: "old", label: "Historical attention")
      let index = try store.loadIndex()
      var hierarchy = try store.loadBoard(items: index.items)
      let center = WorldPoint(x: -40_000, y: 120_000)
      let moved = hierarchy.moveItem(itemID, in: boardID, to: center, actor: actor)
      #expect(moved)
      try store.saveBoard(hierarchy, items: index.items)
      #expect(try store.readReferenceLocation(reference) == .item(boardID: boardID, id: itemID,
        center: center, geometry: .document(.a4)))
    }
  }

  @Test func addressedBoardElementOverridesStaleRegionAndOrigin() throws {
    try fixture { store, actor, boardID, _ in
      let target = CollaborationTarget(kind: .board, id: boardID)
      let origin = WorldPoint(x: 120_000, y: -90_000)
      let frame = PageRect(x: 12, y: 34, width: 200, height: 100)
      _ = try store.applyCollaborationAction(.init(summary: "Distant control",
        expected: [.init(target: target, revision: #require(try store.boardContentRevision(boardID)))],
        operations: [.init(kind: .insertElement, target: target, id: "distant", values: [
          "kind": .string("nativeText"), "source": .string("Actual address"),
          "worldOrigin": try .encode(origin), "frame": try .encode(frame)])]), actor: actor)
      let reference = CollaborationReference(target: target, elementID: "distant",
        region: .init(x: 0, y: 0, width: 1, height: 1), worldOrigin: .zero, revision: "old")
      #expect(try store.readReferenceLocation(reference) == .board(id: boardID,
        center: #require(origin.addressOffset(x: 112, y: 84)), region: frame))
      #expect(throws: CollaborationError.self) {
        try store.readReferenceLocation(.init(target: target, elementID: "deleted", revision: "old"))
      }
    }
  }

  @Test func missingTargetIsExplicitAndNeverFallsBackToCameraOrigin() throws {
    try fixture { store, _, boardID, _ in
      let target = CollaborationTarget(kind: .document, id: UUID(), boardID: boardID)
      #expect(throws: CollaborationError("reference_unavailable", "Место больше недоступно.", target: target)) {
        try store.readReferenceLocation(.init(target: target, revision: "old"))
      }
    }
  }
}
