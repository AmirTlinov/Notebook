import Foundation
import Testing
@testable import NotebookCore

@Suite("Lifecycle operations share the existing atomic action", .serialized)
struct NotebookLifecycleActionTests {
  private typealias Fixture = NotebookItemLifecycleTests.Fixture

  private func operation(_ kind: String, target: CollaborationTarget, id: UUID? = nil,
    values: [String: JSONValue] = [:]) throws -> CollaborationOperation {
    var raw: [String: JSONValue] = ["kind": .string(kind), "target": try .encode(target), "values": .object(values)]
    raw["id"] = id.map { .string($0.uuidString) }
    return try JSONValue.object(raw).decode(CollaborationOperation.self)
  }

  private func basis(_ f: Fixture) throws -> NotebookReadBasis {
    let query = try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(f.itemID)]).decode(NotebookReadQuery.self)
    var command = NotebookCommand(command: .read); command.queries = [query]; command.readSnapshots = true
    return try #require(try NotebookCommandDispatcher(store: f.store).handle(command).array.first?["basis"]?.decode(NotebookReadBasis.self))
  }

  private func neighbor(_ f: Fixture) throws -> UUID {
    let header = try f.store.workspaceHeader(), id = UUID(), board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let base = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Neighbor", expected: base.owners, operations: [
      .init(kind: .createNotebook, target: board, id: id.uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])
    ]), actor: f.actor)
    return id
  }

  @Test func renameAppendRenameHasOneReceiptAndPreservesEveryExistingPage() throws {
    let f = try Fixture(), last = try f.append(), added = UUID(), extent = try #require(try f.store.readItemLifecycle(f.itemID))
    let board = CollaborationTarget(kind: .board, id: extent.target.boardID!), base = try basis(f)
    let oldPage = try f.store.loadPage(last), presence = try f.store.loadPresence()
    let action = try CollaborationAction(summary: "Rename, append, rename", expected: base.owners, operations: [
      .init(kind: .renameItem, target: board, id: f.itemID.uuidString, values: ["title": .string("Intermediate")]),
      operation("appendPage", target: extent.target, id: added),
      .init(kind: .renameItem, target: board, id: f.itemID.uuidString, values: ["title": .string("Final")])
    ])
    let receipt = try f.store.applyCollaborationAction(action, actor: f.actor)
    #expect(try f.store.readItemHeader(f.itemID)?.title == "Final")
    #expect(try f.store.pageCount(in: f.itemID) == 3)
    #expect(try f.store.pageID(at: 0, in: f.itemID) == f.pageID)
    #expect(try f.store.pageID(at: 1, in: f.itemID) == last)
    #expect(try f.store.pageID(at: 2, in: f.itemID) == added)
    #expect(try f.store.loadPage(last) == oldPage)
    #expect(try f.store.loadPresence() == presence)
    let version = try receipt.deliveryVersion(), cursor = try f.store.currentChangeCursor()
    let replay = try f.store.applyCollaborationAction(action, actor: f.actor)
    #expect(try replay.deliveryVersion() == version)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.savedActionResult(action.id)?["actionVersion"] == .string(version))
  }

  @Test func appendedPageCanReceiveItsFirstStrokeInTheSameAction() throws {
    let f = try Fixture(), page = UUID(), stroke = UUID(), extent = try #require(try f.store.readItemLifecycle(f.itemID))
    let base = try basis(f), target = CollaborationTarget(kind: .page, id: page)
    let operations = try [operation("appendPage", target: extent.target, id: page),
      CollaborationOperation(kind: .appendInkStroke, target: target, id: stroke.uuidString,
        values: ["points": .array([.object(["x": .number(20), "y": .number(20)])])])]
    let expected = try f.store.expectations(base: base, operations: operations)
    let receipt = try f.store.applyCollaborationAction(.init(summary: "Page and first stroke", expected: expected, operations: operations), actor: f.actor)
    let drawing = try PageInkDrawing.decode(f.store.loadPage(page).drawingData)
    #expect(drawing.actions.contains { $0.id == stroke && $0.isActive })
    #expect(receipt.revisions.contains { $0.target == target && $0.inkRevision != nil })
  }

  @Test func anInvalidOperationAfterAppendRollsBackItsWholeAction() throws {
    let f = try Fixture(), page = UUID(), extent = try #require(try f.store.readItemLifecycle(f.itemID)), base = try basis(f)
    let append = try operation("appendPage", target: extent.target, id: page)
    let action = CollaborationAction(summary: "Must roll back", expected: base.owners, operations: [append,
      .init(kind: .updateElement, target: .init(kind: .page, id: page), id: "absent", values: ["source": .string("No owner")])])
    let cursor = try f.store.currentChangeCursor()
    do { _ = try f.store.applyCollaborationAction(action, actor: f.actor); Issue.record("The late invalid operation must refuse the action") }
    catch let error as CollaborationError { #expect(error.operation?.index == 1) }
    #expect(try f.store.pageCount(in: f.itemID) == 1)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try !f.store.hasStoredValue(pageFile(page)))
    #expect(try f.store.collaborationActionIfPresent(action.id) == nil)
  }

  @Test func deletionRequiresAnExplicitCompleteLifecycleBasis() throws {
    let f = try Fixture(); _ = try neighbor(f)
    let extent = try #require(try f.store.readItemLifecycle(f.itemID)), destructive = try operation("deleteItem", target: extent.target)
    let full = try basis(f)
    let incomplete = NotebookReadBasis(workspaceID: full.workspaceID, owners: full.owners.map {
      .init(target: $0.target, revision: $0.revision, stateRevision: $0.stateRevision, sourceRevision: $0.sourceRevision, inkRevision: $0.inkRevision)
    })
    let cursor = try f.store.currentChangeCursor()
    do { _ = try f.store.expectations(base: incomplete, operations: [destructive]); Issue.record("Do not refresh a missing destructive basis") }
    catch let error as CollaborationError { #expect(error.code == "basis_incomplete"); #expect(error.operation?.index == 0) }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.readItemHeader(f.itemID) != nil)
  }

  @Test func renamePageEditDeleteUndoRestoresThePreActionNotThePreDeleteContent() throws {
    let f = try Fixture(); _ = try neighbor(f); try f.write(f.pageID, text: "Before the action")
    let extent = try #require(try f.store.readItemLifecycle(f.itemID)), title = extent.item.title
    let board = CollaborationTarget(kind: .board, id: extent.target.boardID!), page = CollaborationTarget(kind: .page, id: f.pageID)
    let base = try NotebookReadBasis.merging([basis(f), f.store.readBasis(targets: [page])])
    let action = try CollaborationAction(additionalOwners: [extent.target], summary: "Edit then delete", expected: base.owners, operations: [
      .init(kind: .renameItem, target: board, id: f.itemID.uuidString, values: ["title": .string("Transient title")]),
      .init(kind: .updateElement, target: page, id: "label", values: ["source": .string("Transient source"), "html": .string("<p>Transient source</p>")]),
      operation("deleteItem", target: extent.target)
    ])
    _ = try f.store.applyCollaborationAction(action, actor: f.actor)
    #expect(try f.store.readItemHeader(f.itemID) == nil)
    _ = try f.store.undoCollaborationAction(action.id, actor: UUID())
    #expect(try f.store.readItemHeader(f.itemID)?.title == title)
    #expect(try f.store.loadPage(f.pageID).elements.first { $0.id == "label" }?.source == "Before the action")
  }

  @Test func createAppendDeleteDoesNotResurrectTransientContentOnUndo() throws {
    let f = try Fixture(), header = try f.store.workspaceHeader(), item = UUID(), first = UUID(), second = UUID()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID), cover = CollaborationTarget(kind: .cover, id: item, boardID: header.rootBoardID)
    let base = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    let operations = try [CollaborationOperation(kind: .createNotebook, target: board, id: item.uuidString,
      values: ["center": .encode(WorldPoint.zero), "pageID": .encode(first)]),
      operation("appendPage", target: cover, id: second), operation("deleteItem", target: cover)]
    let expected = try f.store.expectations(base: base, operations: operations)
    let receipt = try f.store.applyCollaborationAction(.init(summary: "Transient notebook", expected: expected, operations: operations), actor: f.actor)
    #expect(try f.store.readItemHeader(item) == nil)
    _ = try f.store.undoCollaborationAction(receipt.id, actor: UUID())
    #expect(try f.store.readItemHeader(item) == nil)
    #expect(try f.store.ownerItemID(ofPage: first) == nil)
    #expect(try f.store.ownerItemID(ofPage: second) == nil)
    #expect(throws: (any Error).self) { _ = try f.store.loadPage(first) }
    #expect(throws: (any Error).self) { _ = try f.store.loadPage(second) }
    #expect(try f.store.readItemHeader(f.itemID) != nil)
  }

  @Test(arguments: [false, true])
  func undoOfCreatedNeighborAndDeletedItemUsesTheSamePreUndoOwnershipCut(hasOtherNotebook: Bool) throws {
    let f = try Fixture()
    if hasOtherNotebook { _ = try neighbor(f) }
    let extent = try #require(try f.store.readItemLifecycle(f.itemID)), created = UUID()
    let before = try f.store.loadIndex().items.map(\.id)
    let board = CollaborationTarget(kind: .board, id: extent.target.boardID!)
    let action = CollaborationAction(additionalOwners: [extent.target], summary: "Replace an item atomically", expected: try basis(f).owners, operations: [
      .init(kind: .createNotebook, target: board, id: created.uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())]),
      .init(kind: .deleteItem, target: extent.target)
    ])
    _ = try f.store.applyCollaborationAction(action, actor: f.actor)
    _ = try f.store.undoCollaborationAction(action.id, actor: UUID())
    #expect(try f.store.readItemHeader(created) == nil)
    #expect(try f.store.loadIndex().items.map(\.id) == before,
      "Our inverse of the neighbor must not be mistaken for a foreign catalogue-order edit")
  }

  @Test(arguments: [false, true])
  func undoOfDeletionRetainsTheEarlierTitlesCausalUndoOwnership(onPeer: Bool) throws {
    let f = try Fixture(); _ = try neighbor(f)
    let extent = try #require(try f.store.readItemLifecycle(f.itemID)), originalTitle = extent.item.title
    let board = CollaborationTarget(kind: .board, id: extent.target.boardID!)
    let earlier = try f.store.applyCollaborationAction(.init(summary: "Earlier title", expected: basis(f).owners, operations: [
      .init(kind: .renameItem, target: board, id: f.itemID.uuidString, values: ["title": .string("Earlier contribution")])
    ]), actor: f.actor)
    let deletion = try f.store.applyCollaborationAction(.init(additionalOwners: [extent.target], summary: "Later rename and deletion",
      expected: basis(f).owners, operations: [
        .init(kind: .renameItem, target: board, id: f.itemID.uuidString, values: ["title": .string("Deleted contribution")]),
        operation("deleteItem", target: extent.target)
      ]), actor: f.actor)
    _ = try f.store.undoCollaborationAction(deletion.id, actor: UUID())
    #expect(try f.store.readItemHeader(f.itemID)?.title == "Earlier contribution")
    let peerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-provenance-peer-\(UUID())")
    defer { try? FileManager.default.removeItem(at: peerRoot) }
    let store: NotebookStore
    if onPeer {
      let peer = NotebookStore(root: peerRoot), peerID = UUID()
      try peer.prepareEmptyWorkspace(workspaceID: f.store.workspaceHeader().workspaceID)
      for change in try f.store.changeJournal(after: 0) {
        var delivered = false
        for _ in 0..<64 {
          let missing = try peer.missingBlobHashes(for: change)
          if missing.isEmpty { _ = try peer.applyRemoteChange(change, peerID: peerID); delivered = true; break }
          for hash in missing {
            let size = try f.store.blobSize(hash: hash)
            var data = Data()
            while Int64(data.count) < size {
              data += try f.store.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
            }
            try peer.stageBlob(data: data, expectedHash: hash)
          }
        }
        #expect(delivered)
      }
      // This replica did not run the inverse helper. Provenance is rebuilt
      // solely from the admitted receipt and its immutable dependencies.
      store = NotebookStore(root: peerRoot)
    } else { store = NotebookStore(root: f.store.root) }
    _ = try store.undoCollaborationAction(earlier.id, actor: UUID())
    #expect(try store.readItemHeader(f.itemID)?.title == originalTitle,
      "The inverse writer is a receipt-backed restoration, not an independent human adoption")
  }
}
