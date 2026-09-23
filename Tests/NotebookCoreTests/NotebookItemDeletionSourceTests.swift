import Foundation
import Testing
@testable import NotebookCore

@Suite("Item deletion owns physical sources, not a paint window", .serialized)
struct NotebookItemDeletionSourceTests {
  @Test func contentDeletionKeepsSessionSelectionAndUsesTheAdmittedAuthor() throws {
    let f = try NotebookItemLifecycleTests.Fixture(), neighborID = UUID()
    let header = try f.store.workspaceHeader(), board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let base = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Retained neighbor", expected: base.owners, operations: [
      .init(kind: .createNotebook, target: board, id: neighborID.uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": .string(UUID().uuidString)])
    ]), actor: f.actor)
    let presence = try f.store.loadPresence(), agent = UUID()
    try f.store.commandTransaction {
      try f.store.deleteWorkspaceItemContent(itemID: f.itemID, actor: agent, human: false)
    }
    #expect(try f.store.loadPresence() == presence, "Content does not author a user's selection")
    let item = f.itemID.uuidString.lowercased()
    let exists = "workspace.json#/collaboration/fields/@" + fieldKey([fieldKey(["items", item, "exists"])])
    let version = try #require(try f.store.storedFragments(address: exists, descendants: false).first?.value.decode(ContentFieldVersion.self))
    #expect(version.human == false)
    #expect(version.stamp.actor == agent)
    let placement = "board.json#/boards/@" + header.rootBoardID.uuidString.lowercased() + "/board/placements/@" + item
    let tombstone = try #require(try f.store.storedFragments(address: placement, descendants: false).first?.value.decode(WorkspacePlacement.self))
    #expect(tombstone.pose == nil)
    #expect(tombstone.heads.allSatisfy { !$0.version.human && $0.version.stamp.actor == agent })
  }

  @Test func deletionIncludesASourcePublishedEarlierInTheSameOuterTransaction() throws {
    let f = try NotebookItemLifecycleTests.Fixture(), neighborID = UUID()
    let header = try f.store.workspaceHeader(), board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let base = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Keep another item", expected: base.owners, operations: [
      .init(kind: .createNotebook, target: board, id: neighborID.uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": .string(UUID().uuidString)])
    ]), actor: f.actor)
    let parent = "board.json#/boards/@" + header.rootBoardID.uuidString.lowercased(), id = "not-yet-indexed"
    let address = parent + "/board/elements/@" + id
    try f.store.commandTransaction {
      let source = SpatialElement(id: id, surface: .cover(f.itemID), kind: .graphic,
        frame: .init(x: 10, y: 10, width: 30, height: 30), source: "",
        graphic: .init(shape: .rectangle, visible: false), stamp: header.stamp)
      try f.store.writeFragment(.init(address: address, file: "board.json", parent: parent,
        collection: "board/elements", member: id, position: 0, value: try .encode(source), collections: []), database: f.store.currentSQL!)
      let indexed = try f.store.currentSQL!.rows("SELECT 1 FROM reference_element_order WHERE address=?", [.text(address)])
      #expect(indexed.isEmpty, "The source-owner refresh is still pending in this outer command")
      _ = try f.store.deleteTestItem(itemID: f.itemID, actor: f.actor)
    }
    #expect(try f.store.storedFragments(address: address, descendants: false).isEmpty)
    #expect(try f.store.readItemHeader(neighborID) != nil)
  }

  @Test func nativeDeletionRemovesHiddenCoverGraphicsAcrossMoreThanOneReadPage() throws {
    let f = try NotebookItemLifecycleTests.Fixture(), neighborID = UUID(), neighborPageID = UUID()
    let header = try f.store.workspaceHeader(), board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let catalog = CollaborationTarget(kind: .workspace, id: header.rootBoardID)
    let create = CollaborationOperation(kind: .createNotebook, target: board, id: neighborID.uuidString,
      values: ["center": try .encode(WorldPoint.zero), "pageID": .string(neighborPageID.uuidString)])
    let initial = try f.store.readBasis(targets: [catalog, board])
    _ = try f.store.applyCollaborationAction(.init(summary: "Keep a neighboring notebook", expected: initial.owners, operations: [create]), actor: f.actor)
    let neighbor = try f.store.referenceRevision(target: .init(kind: .page, id: neighborPageID))
    let cover = CollaborationTarget(kind: .cover, id: f.itemID, boardID: header.rootBoardID)
    let ids = (0..<70).map { String(format: "hidden-%03d", $0) }
    let operations = try ids.map { id in
      CollaborationOperation(kind: .insertElement, target: cover, id: id, values: [
        "kind": .string("graphic"), "source": .string(""),
        "frame": try .encode(PageRect(x: 10, y: 10, width: 30, height: 30)),
        "graphic": try .encode(NotebookGraphic(shape: .rectangle, visible: false))])
    }
    let base = try f.store.readBasis(targets: [cover])
    _ = try f.store.applyCollaborationAction(.init(summary: "Hidden sources", expected: base.owners, operations: operations), actor: f.actor)
    for id in [ids.first!, ids.last!] {
      #expect(try f.store.readSpatialElement(boardID: header.rootBoardID, elementID: id)?.graphic?.visible == false)
      #expect(try f.store.readScenePaintPosition(boardID: header.rootBoardID, coverID: f.itemID, id: .element(id)) == nil)
    }
    _ = try f.store.deleteTestItem(itemID: f.itemID, actor: f.actor)
    #expect(try f.store.readItemHeader(f.itemID) == nil)
    for id in ids {
      #expect(try f.store.readSpatialElement(boardID: header.rootBoardID, elementID: id) == nil)
    }
    #expect(try f.store.referenceRevision(target: .init(kind: .page, id: neighborPageID)) == neighbor)
    #expect(try f.store.readItemHeader(neighborID) != nil)
  }
}
