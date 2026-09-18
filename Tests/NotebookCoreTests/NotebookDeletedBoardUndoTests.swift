import Foundation
import Testing
@testable import NotebookCore

@Suite("Empty board deletion undo preserves its original portal owner", .serialized)
struct NotebookDeletedBoardUndoTests {
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    var store: NotebookStore { content.store }
    let id: UUID, parent: UUID
    let agent = UUID(), human = UUID(), peerA = UUID(), peerB = UUID()
    var target: CollaborationTarget { .init(kind: .cover, id: id, boardID: parent) }

    init() throws {
      content = try NotebookItemLifecycleTests.Fixture()
      let before = try content.store.loadIndex(), hierarchy = try content.store.loadBoard(items: before.items)
      var after = before, next = hierarchy
      parent = before.rootBoardID
      let created = after.createBoard(title: "A portal to an empty board", actor: content.actor)
      let item = try #require(created); id = item.id
      let placed = next.createBoard(id, in: parent, near: .init(x: 3500, y: -1250), actor: content.actor)
      #expect(placed)
      let camera = next.updatePortalCamera(.init(center: .init(x: 730, y: -240), scale: 0.64), for: id, actor: content.actor)
      #expect(camera)
      _ = try content.store.saveWorkspaceEdits(before: before, after: after, boardBefore: hierarchy, boardAfter: next)
    }

    func send(from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws {
      let cursor = try destination.peerCursor(peerID: peer, direction: .incoming)
      for change in try source.changeJournal(after: cursor) {
        var delivered = false
        for _ in 0..<64 {
          let missing = try destination.missingBlobHashes(for: change)
          if missing.isEmpty {
            let accepted = try destination.applyRemoteChange(change, peerID: peer)
            #expect(accepted == change.sequence); delivered = true; break
          }
          for hash in missing {
            let count = try source.blobSize(hash: hash)
            var data = Data()
            while Int64(data.count) < count {
              data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
            }
            try destination.stageBlob(data: data, expectedHash: hash)
          }
        }
        #expect(delivered)
        if !delivered { throw NotebookStorageError.invalidTransaction("board undo fixture dependencies") }
      }
    }

    func replica(_ name: String) throws -> NotebookStore {
      let peer = NotebookStore(root: store.root.appendingPathComponent(name))
      try peer.prepareEmptyWorkspace(workspaceID: store.workspaceHeader().workspaceID)
      try send(from: store, to: peer, peer: peerA)
      return peer
    }

    func stroke() -> SpatialInkAction {
      .init(tool: .pen, spans: [.init(surface: .board(id), samples: [
        .init(point: .init(x: 20, y: 30), worldPoint: .init(x: 20, y: 30),
          timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      ])], stamp: .init(counter: 100, actor: human))
    }

    func action() throws -> CollaborationAction {
      var read = NotebookCommand(command: .read); read.readSnapshots = true
      read.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(id)]).decode(NotebookReadQuery.self)]
      let basis = try #require(try NotebookCommandDispatcher(store: store).handle(read).array.first?["basis"]?.decode(NotebookReadBasis.self))
      let operations = [CollaborationOperation(kind: .deleteItem, target: target)]
      return try .init(additionalOwners: [target], summary: "Delete only an empty board",
        expected: store.expectations(base: basis, operations: operations), operations: operations)
    }
  }

  @Test func undoRestoresTheExactEmptyBoardPortalAndItsPlacement() throws {
    let f = try Fixture(), node = try #require(try f.store.readBoardNode(f.id))
    let pose = try #require(try f.store.readBoardItem(f.id)?.board.placements.first { $0.itemID == f.id }?.pose)
    let header = try #require(try f.store.readItemHeader(f.id)), action = try f.action()
    _ = try f.store.applyCollaborationAction(action, actor: f.agent)
    #expect(try f.store.readItemHeader(f.id) == nil)
    #expect(try f.store.readBoardNode(f.id) == nil)
    let reopened = NotebookStore(root: f.store.root), undo = try reopened.undoCollaborationAction(action.id, actor: UUID())
    #expect(undo.undo?.lifecycleChanges?.contains { $0.kind == .restoreItem && $0.target == f.target } == true)
    #expect(try reopened.readItemHeader(f.id) == header)
    #expect(try reopened.ownerBoardID(of: f.id) == f.parent)
    let restored = try #require(try reopened.readBoardNode(f.id))
    #expect(restored.portalCamera == node.portalCamera && restored.portalStamp == node.portalStamp)
    #expect(restored.board.itemIDs.isEmpty && restored.board.elements.isEmpty)
    #expect(try reopened.readBoardItem(f.id)?.board.placements.first { $0.itemID == f.id }?.pose == pose)
    #expect(try reopened.readItemHeader(f.content.itemID) != nil)
  }

  @Test func aBoardWithAChildItemRefusesDeletionWithoutAnyPartialEffect() throws {
    let f = try Fixture(), target = CollaborationTarget(kind: .board, id: f.id)
    let basis = try f.store.readBasis(targets: [target, .init(kind: .workspace, id: f.parent)])
    let child = UUID()
    _ = try f.store.applyCollaborationAction(.init(summary: "Child prevents parent deletion", expected: basis.owners, operations: [
      .init(kind: .createNotebook, target: target, id: child.uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])
    ]), actor: f.agent)
    let action = try f.action(), node = try f.store.readBoardNode(f.id), header = try f.store.readItemHeader(f.id)
    let cursor = try f.store.currentChangeCursor()
    #expect(throws: (any Error).self) { _ = try f.store.applyCollaborationAction(action, actor: f.agent) }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.readBoardNode(f.id) == node)
    #expect(try f.store.readItemHeader(f.id) == header)
    #expect(try f.store.ownerBoardID(of: child) == f.id)
    #expect(try f.store.collaborationActionIfPresent(action.id) == nil)
  }

  @Test func aForeignHumanTombstonePreservesTheBoardDeletionInsteadOfRestoringItsPortal() throws {
    let f = try Fixture(), action = try f.action()
    _ = try f.store.applyCollaborationAction(action, actor: f.agent)
    let before = try f.store.loadBoard(items: f.store.loadIndex().items)
    var after = before
    let authored = after.restorePlacement(itemID: f.id, on: f.parent, pose: nil, actor: UUID())
    #expect(authored)
    _ = try f.store.saveBoardEdits(before: before, after: after)
    let tombstone = try f.store.readBoardNode(f.parent)?.board.placements.first { $0.itemID == f.id }
    let undone = try f.store.undoCollaborationAction(action.id, actor: UUID())
    #expect(undone.undo?.preservedLifecycle == [f.target])
    #expect(undone.undo?.lifecycleChanges?.isEmpty ?? true)
    #expect(try f.store.readItemHeader(f.id) == nil)
    #expect(try f.store.readBoardNode(f.id) == nil)
    #expect(try f.store.readBoardNode(f.parent)?.board.placements.first { $0.itemID == f.id } == tombstone)
  }


  @Test(arguments: [false, true])
  func latePortalElementAndInkRemainHiddenUntilUndoThenSurviveOnReopenOrFreshPeer(freshPeer: Bool) throws {
    let f = try Fixture(), peer = try f.replica("authoring-peer")
    try f.send(from: peer, to: f.store, peer: f.peerB)
    let action = try f.action()
    _ = try f.store.applyCollaborationAction(action, actor: f.agent)
    let index = try peer.loadIndex(), before = try peer.loadBoard(items: index.items)
    var after = before
    let camera = BoardPortalCamera(center: .init(x: -890, y: 670), scale: 1.35)
    let changedCamera = after.updatePortalCamera(camera, for: f.id, actor: f.human)
    let element = SpatialElement(id: "late-human", surface: .board(f.id), kind: .web,
      frame: .init(x: 0, y: 0, width: 200, height: 80), worldOrigin: .zero,
      source: "<p>Human source accepted after deletion</p>", stamp: .init(counter: 100, actor: f.human))
    let inserted = after.upsertElement(element, in: f.id, expected: nil, actor: f.human)
    #expect(changedCamera && inserted)
    _ = try peer.saveBoardEdits(before: before, after: after)
    let stroke = f.stroke()
    _ = try peer.commitSpatialInk(.append(stroke, journalStamp: stroke.stamp))
    let expectedNode = try #require(try peer.readBoardNode(f.id))
    let expectedElement = try #require(try peer.readSpatialElement(boardID: f.id, elementID: element.id))
    let received = try peer.currentChangeCursor()
    try f.send(from: peer, to: f.store, peer: f.peerB)
    #expect(try f.store.peerCursor(peerID: f.peerB, direction: .incoming) == received)
    #expect(try f.store.readItemHeader(f.id) == nil)
    #expect(try f.store.readBoardNode(f.id) == nil, "Retained board continuation is not a live scene")
    let destination: NotebookStore
    if freshPeer { destination = try f.replica("fresh-receiver") }
    else { destination = NotebookStore(root: f.store.root) }
    _ = try destination.undoCollaborationAction(action.id, actor: UUID())
    for store in [destination, NotebookStore(root: destination.root)] {
      #expect(try store.readItemHeader(f.id)?.kind == .board)
      #expect(try store.ownerBoardID(of: f.id) == f.parent)
      let restored = try #require(try store.readBoardNode(f.id))
      #expect(restored.portalCamera == camera && restored.portalStamp == expectedNode.portalStamp)
      #expect(try store.readSpatialElement(boardID: f.id, elementID: element.id) == expectedElement)
      #expect(try store.readSpatialInk(surfaces: [.board(f.id)]).actions.first { $0.id == stroke.id } == stroke)
    }
  }

  @Test func aLateChildPlacementIntoADeletedBoardIsRejectedBeforeAcknowledgement() throws {
    let f = try Fixture(), peer = try f.replica("authoring-peer")
    try f.send(from: peer, to: f.store, peer: f.peerB)
    let action = try f.action()
    _ = try f.store.applyCollaborationAction(action, actor: f.agent)
    let child = UUID(), board = CollaborationTarget(kind: .board, id: f.id)
    let basis = try peer.readBasis(targets: [board, .init(kind: .workspace, id: f.parent)])
    _ = try peer.applyCollaborationAction(.init(summary: "Unobserved late child", expected: basis.owners, operations: [
      .init(kind: .createNotebook, target: board, id: child.uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])
    ]), actor: f.human)
    let acknowledged = try f.store.peerCursor(peerID: f.peerB, direction: .incoming), cursor = try f.store.currentChangeCursor()
    #expect(throws: (any Error).self) { try f.send(from: peer, to: f.store, peer: f.peerB) }
    #expect(try f.store.peerCursor(peerID: f.peerB, direction: .incoming) == acknowledged)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.readItemHeader(child) == nil)
    #expect(try f.store.readBoardNode(f.id) == nil)
  }

  @Test func aDeletedBoardRejectsLocalSceneReadsAndQueuedPortalOrInkWrites() throws {
    let f = try Fixture(), staleItems = try f.store.loadIndex().items
    let before = try f.store.loadBoard(items: staleItems)
    var after = before
    let edited = after.updatePortalCamera(.init(center: .init(x: 123, y: 456), scale: 1.7), for: f.id, actor: f.human)
    #expect(edited)
    let action = try f.action()
    _ = try f.store.applyCollaborationAction(action, actor: f.agent)
    let reopened = NotebookStore(root: f.store.root), cursor = try reopened.currentChangeCursor()
    let bounds = WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)
    #expect(try reopened.readBoardNode(f.id) == nil)
    #expect(try reopened.boardContentRevision(f.id) == nil)
    #expect(try reopened.loadBoard(items: reopened.loadIndex().items).board(f.id) == nil)
    #expect(try reopened.loadBoard(items: staleItems).board(f.id) == nil, "A stale native catalogue cannot expose a retained hidden board")
    #expect(throws: (any Error).self) { _ = try reopened.readSceneWindow(boardID: f.id, bounds: bounds) }
    #expect(throws: (any Error).self) { _ = try reopened.readScenePaintOrder(boardID: f.id, bounds: bounds) }
    #expect(throws: (any Error).self) { _ = try reopened.saveBoardEdits(before: before, after: after) }
    #expect(throws: (any Error).self) { try reopened.saveBoard(after, items: staleItems) }
    let stroke = f.stroke()
    #expect(throws: (any Error).self) { _ = try reopened.commitSpatialInk(.append(stroke, journalStamp: stroke.stamp)) }
    #expect(try reopened.currentChangeCursor() == cursor)
    #expect(try reopened.readItemHeader(f.id) == nil)
  }


  @Test(arguments: [false, true])
  func deletingAChildThenItsEmptyParentUndoesInOwnerOrderOrPreservesBothWhenParentIsAdopted(foreignTombstone: Bool) throws {
    let f = try Fixture(), board = CollaborationTarget(kind: .board, id: f.id), child = UUID(), page = UUID()
    let createBasis = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: f.parent)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Child inside nested board", expected: createBasis.owners, operations: [
      .init(kind: .createNotebook, target: board, id: child.uuidString,
        values: ["center": try .encode(WorldPoint(x: 300, y: 600)), "pageID": try .encode(page)])
    ]), actor: f.agent)
    let childTarget = CollaborationTarget(kind: .cover, id: child, boardID: f.id)
    let childBody = try f.store.loadPage(page)
    let childPose = try #require(try f.store.readBoardItem(child)?.board.placements.first { $0.itemID == child }?.pose)
    let parentPose = try #require(try f.store.readBoardItem(f.id)?.board.placements.first { $0.itemID == f.id }?.pose)
    var read = NotebookCommand(command: .read); read.readSnapshots = true
    read.queries = try [child, f.id].map { id in
      try JSONValue.object(["kind": .string("itemLifecycle"), "id": .encode(id)]).decode(NotebookReadQuery.self)
    }
    let bases = try NotebookCommandDispatcher(store: f.store).handle(read).array.map {
      try #require(try $0["basis"]?.decode(NotebookReadBasis.self))
    }
    let operations = [CollaborationOperation(kind: .deleteItem, target: childTarget),
      CollaborationOperation(kind: .deleteItem, target: f.target)]
    let expected = try f.store.expectations(base: .merging(bases), operations: operations)
    let receipt = try f.store.applyCollaborationAction(.init(additionalOwners: [childTarget, f.target],
      summary: "Delete child then its now-empty parent atomically", expected: expected, operations: operations), actor: f.agent)
    #expect(try f.store.readItemHeader(child) == nil && f.store.readItemHeader(f.id) == nil)
    if foreignTombstone {
      let before = try f.store.loadBoard(items: f.store.loadIndex().items)
      var after = before
      let changed = after.restorePlacement(itemID: f.id, on: f.parent, pose: nil, actor: UUID())
      #expect(changed)
      _ = try f.store.saveBoardEdits(before: before, after: after)
    }
    let reopened = NotebookStore(root: f.store.root)
    let undone = try reopened.undoCollaborationAction(receipt.id, actor: UUID())
    if foreignTombstone {
      #expect(Set(undone.undo?.preservedLifecycle ?? []) == Set([f.target, childTarget]))
      #expect(undone.undo?.lifecycleChanges?.isEmpty ?? true)
      #expect(try reopened.readItemHeader(f.id) == nil)
      #expect(try reopened.readItemHeader(child) == nil)
      #expect(try reopened.ownerItemID(ofPage: page) == nil)
    } else {
      #expect(undone.undo?.preservedLifecycle?.isEmpty ?? true)
      #expect(try reopened.readItemHeader(f.id)?.kind == .board)
      #expect(try reopened.ownerBoardID(of: f.id) == f.parent)
      #expect(try reopened.readItemHeader(child)?.kind == .notebook)
      #expect(try reopened.ownerBoardID(of: child) == f.id)
      #expect(try reopened.ownerItemID(ofPage: page) == child)
      #expect(try reopened.loadPage(page) == childBody)
      #expect(try reopened.readBoardItem(child)?.board.placements.first { $0.itemID == child }?.pose == childPose)
      #expect(try reopened.readBoardItem(f.id)?.board.placements.first { $0.itemID == f.id }?.pose == parentPose)
    }
  }


  @Test func removingTheLastElementThenDeletingItsBoardUndoesBothEffects() throws {
    let f = try Fixture(), boardTarget = CollaborationTarget(kind: .board, id: f.id)
    let before = try f.store.loadBoard(items: f.store.loadIndex().items)
    var after = before
    let element = SpatialElement(id: "last-original", surface: .board(f.id), kind: .web,
      frame: .init(x: 0, y: 0, width: 190, height: 90), worldOrigin: .init(x: 350, y: 700),
      source: "<button>Original board program</button>", state: .number(7), stamp: .init(counter: 100, actor: f.human))
    let inserted = after.upsertElement(element, in: f.id, expected: nil, actor: f.human)
    #expect(inserted)
    _ = try f.store.saveBoardEdits(before: before, after: after)
    let original = try #require(try f.store.readSpatialElement(boardID: f.id, elementID: element.id))
    let deletion = try f.action()
    let base = try NotebookReadBasis.merging([
      NotebookReadBasis(workspaceID: f.store.workspaceHeader().workspaceID, owners: deletion.expected),
      f.store.readBasis(targets: [boardTarget])
    ])
    let operations = [CollaborationOperation(kind: .removeElement, target: boardTarget, id: element.id),
      CollaborationOperation(kind: .deleteItem, target: f.target)]
    let receipt = try f.store.applyCollaborationAction(.init(additionalOwners: [boardTarget, f.target],
      summary: "Remove the last element then delete its empty board",
      expected: f.store.expectations(base: base, operations: operations), operations: operations), actor: f.agent)
    #expect(try f.store.readItemHeader(f.id) == nil)
    let reopened = NotebookStore(root: f.store.root)
    _ = try reopened.undoCollaborationAction(receipt.id, actor: UUID())
    #expect(try reopened.readItemHeader(f.id)?.kind == .board)
    let restored = try #require(try reopened.readSpatialElement(boardID: f.id, elementID: element.id))
    #expect(restored.surface == original.surface && restored.frame == original.frame && restored.worldOrigin == original.worldOrigin)
    #expect(restored.source == original.source && restored.state == original.state)
  }
}
