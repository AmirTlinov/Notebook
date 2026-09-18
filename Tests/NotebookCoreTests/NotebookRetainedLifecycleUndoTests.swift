import Foundation
import Testing
@testable import NotebookCore

@Suite("Whole-action undo preserves received retained PAGE sources", .serialized)
struct NotebookRetainedLifecycleUndoTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retained-lifecycle-undo-\(UUID())")
    let a: NotebookStore, b: NotebookStore
    let peerA = UUID(), peerB = UUID(), agent = UUID(), human = UUID()
    let size = PageSize(width: 834, height: 1194)
    let itemID: UUID, pageID: UUID, boardID: UUID
    let originalFrame = PageRect(x: 10, y: 20, width: 240, height: 100)
    let movedFrame = PageRect(x: 330, y: 260, width: 240, height: 100)
    let original = "Original source", continuation = "Human continuation must survive whole-action undo"

    init() throws {
      a = NotebookStore(root: root.appendingPathComponent("a"))
      b = NotebookStore(root: root.appendingPathComponent("b"))
      let header = try a.initializeWorkspace(actor: human, pageSize: size)
      var index = try a.loadIndex()
      itemID = index.selectedItemID; pageID = try #require(index.selectedPageID); boardID = header.rootBoardID
      var board = try a.loadBoard(items: index.items)
      let creation = index.createNotebook(title: "Unchanged neighbor", actor: human, pageSize: size)
      let neighbor = try #require(creation)
      let placed = board.addItem(neighbor.item.id, to: boardID, near: .zero, actor: human)
      #expect(placed)
      try a.saveWorkspaceBundle(index: index, page: neighbor.page, board: board)
      try write(on: a, pageID: pageID, text: original)
      try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
      try send(from: a, to: b, peer: peerA)
      try send(from: b, to: a, peer: peerB)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var cover: CollaborationTarget { .init(kind: .cover, id: itemID, boardID: boardID) }

    func write(on store: NotebookStore, pageID: UUID, text: String) throws {
      var page = try store.loadPage(pageID)
      let frame = page.elements.first { $0.id == "label" }?.frame ?? originalFrame
      let changed = page.replaceElements([.init(id: "label", kind: .markdown, frame: frame,
        source: text, html: "<p>\(text)</p>")], actor: human)
      #expect(changed)
      _ = try store.savePage(page)
    }

    func apply(_ operations: [CollaborationOperation], pageRead: Bool = false) throws -> CollaborationReceipt {
      var command = NotebookCommand(command: .read); command.readSnapshots = true
      command.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(itemID)])
        .decode(NotebookReadQuery.self)]
      let lifecycle = try #require(try NotebookCommandDispatcher(store: a).handle(command).array.first?["basis"]?.decode(NotebookReadBasis.self))
      let basis: NotebookReadBasis
      if pageRead { basis = try NotebookReadBasis.merging([lifecycle, a.readBasis(targets: [.init(kind: .page, id: pageID)])]) }
      else { basis = lifecycle }
      let expected = try a.expectations(base: basis, operations: operations)
      let owners = pageRead ? [cover, CollaborationTarget(kind: .page, id: pageID)] : [cover]
      return try a.applyCollaborationAction(.init(additionalOwners: owners, summary: "One action edits and deletes a notebook",
        expected: expected, operations: operations), actor: agent)
    }

    func send(from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws {
      let cursor = try destination.peerCursor(peerID: peer, direction: .incoming)
      for change in try source.changeJournal(after: cursor) {
        try transfer(change, from: source, to: destination, peer: peer)
      }
    }

    func transfer(_ change: NotebookDurableChange, from source: NotebookStore,
      to destination: NotebookStore, peer: UUID) throws {
      for _ in 0..<64 {
        let missing = try destination.missingBlobHashes(for: change)
        if missing.isEmpty {
          let accepted = try destination.applyRemoteChange(change, peerID: peer)
          #expect(accepted == change.sequence); return
        }
        for hash in missing {
          let size = try source.blobSize(hash: hash)
          var bytes = Data()
          while Int64(bytes.count) < size {
            bytes += try source.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576)
          }
          try destination.stageBlob(data: bytes, expectedHash: hash)
        }
      }
      throw NotebookStorageError.invalidTransaction("retained lifecycle fixture dependency discovery")
    }

    func pagePacket(_ page: PageDocument) throws -> NotebookDurableChange {
      try b.commandTransaction {
        let rows = try NotebookRecordCodec.encode(.encode(page.materializingCausalVersions()), file: pageFile(page.id))
        let records = try rows.map { row in
          NotebookRecordMutation(address: row.address,
            blobHash: try b.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(row)))
        }
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: try b.workspaceHeader().workspaceID,
          records: records)
        let bytes = try NotebookStore.storageEncoder.encode(manifest)
        let hash = try b.currentSQL!.putBlob(bytes)
        return .init(sequence: 1, transactionID: manifest.transactionID, manifestHash: hash, byteCount: bytes.count)
      }
    }

    func undoStore(freshPeer: Bool) throws -> NotebookStore {
      guard freshPeer else { return NotebookStore(root: a.root) }
      let peer = NotebookStore(root: root.appendingPathComponent("fresh"))
      try peer.prepareEmptyWorkspace(workspaceID: a.workspaceHeader().workspaceID)
      try send(from: a, to: peer, peer: peerA)
      return NotebookStore(root: peer.root)
    }

    func expectRestored(_ store: NotebookStore, pageID: UUID, source: String, pageCount: Int) throws {
      #expect(try store.readItemHeader(itemID)?.pageCount == pageCount)
      #expect(try store.ownerBoardID(of: itemID) == boardID)
      #expect(try store.ownerItemID(ofPage: pageID) == itemID)
      let page = try store.loadPage(pageID)
      #expect(page.elements.first { $0.id == "label" }?.source == source,
        "Receipt preimage must not replace an accepted later human source")
    }
  }

  @Test(arguments: [false, true])
  func anEditThenDeletionUndoKeepsReceivedHumanContentButRevertsItsOwnFrame(freshPeer: Bool) throws {
    let f = try Fixture(), page = CollaborationTarget(kind: .page, id: f.pageID)
    let action = try f.apply([
      .init(kind: .updateElement, target: page, id: "label", values: [
        "source": .string("Agent transient source"), "html": .string("<p>Agent transient source</p>"), "frame": try .encode(f.movedFrame)]),
      .init(kind: .deleteItem, target: f.cover)
    ], pageRead: true)
    #expect(try f.a.readItemHeader(f.itemID) == nil)
    // B has not observed either edit or deletion. This PAGE is genuinely
    // concurrent with the entire action, not a mutation of restored content.
    try f.write(on: f.b, pageID: f.pageID, text: f.continuation)
    let received = try f.b.currentChangeCursor()
    try f.send(from: f.b, to: f.a, peer: f.peerB)
    #expect(try f.a.peerCursor(peerID: f.peerB, direction: .incoming) == received)
    #expect(try f.a.readItemHeader(f.itemID) == nil, "PAGE acceptance is not automatic notebook resurrection")
    #expect(try f.a.ownerItemID(ofPage: f.pageID) == nil)
    let undoStore = try f.undoStore(freshPeer: freshPeer)
    _ = try undoStore.undoCollaborationAction(action.id, actor: UUID())
    for store in [undoStore, NotebookStore(root: undoStore.root)] {
      try f.expectRestored(store, pageID: f.pageID, source: f.continuation, pageCount: 1)
      let label = try #require(try store.loadPage(f.pageID).elements.first { $0.id == "label" })
      #expect(label.frame == f.originalFrame, "Human content does not adopt the independent agent-authored frame")
      #expect(label.html == "<p>\(f.continuation)</p>")
    }
  }

  @Test func appendThenDeleteUndoDoesNotResurrectAnUnadoptedTransientPage() throws {
    let f = try Fixture(), appended = UUID()
    let before = try f.a.loadPage(f.pageID)
    let receipt = try f.apply([.init(kind: .appendPage, target: f.cover, id: appended.uuidString),
      .init(kind: .deleteItem, target: f.cover)])
    #expect(try f.a.readItemHeader(f.itemID) == nil)
    let reopened = NotebookStore(root: f.a.root)
    _ = try reopened.undoCollaborationAction(receipt.id, actor: UUID())
    #expect(try reopened.readItemHeader(f.itemID)?.pageCount == 1)
    #expect(try reopened.pageID(at: 0, in: f.itemID) == f.pageID)
    #expect(try reopened.ownerItemID(ofPage: appended) == nil)
    #expect(try !reopened.hasStoredValue(pageFile(appended)), "No adopted source remains to justify this transient page")
    #expect(try reopened.loadPage(f.pageID) == before)
    #expect(throws: (any Error).self) {
      _ = try reopened.readContentHeader(target: .init(kind: .page, id: appended))
    }
  }

  @Test(arguments: [false, true])
  func appendThenDeleteUndoRestoresAnAccessibleTransientPageOnlyWhenItsSourceWasAdopted(freshPeer: Bool) throws {
    let f = try Fixture(), appended = UUID()
    let receipt = try f.apply([.init(kind: .appendPage, target: f.cover, id: appended.uuidString),
      .init(kind: .deleteItem, target: f.cover)])
    #expect(try f.a.readItemHeader(f.itemID) == nil)
    let birthKey = fieldKey(["items", f.itemID.uuidString.lowercased(), "pageIDs", appended.uuidString.lowercased()])
    let birthAddress = "workspace.json#/collaboration/fields/@" + fieldKey([birthKey])
    #expect(try !f.a.storedFragments(address: birthAddress, descendants: false).isEmpty)
    // Source-admission safety fixture, not a claim that UI published the middle
    // of an atomic action: branch from the exact native append's empty PAGE
    // birth (same UUID, size and actor), then receive an independently authored
    // human PAGE through the real remote manifest. No orphan save or catalogue
    // resurrection is used to smuggle this source into the destination.
    var authored = PageDocument(id: appended, size: f.size, actor: f.agent)
    let changed = authored.replaceElements([.init(id: "label", kind: .markdown, frame: f.originalFrame,
      source: f.continuation, html: "<p>\(f.continuation)</p>")], actor: f.human)
    #expect(changed)
    let packet = try f.pagePacket(authored), sourcePeer = UUID()
    try f.transfer(packet, from: f.b, to: f.a, peer: sourcePeer)
    #expect(try f.a.peerCursor(peerID: sourcePeer, direction: .incoming) == packet.sequence)
    #expect(try f.a.readItemHeader(f.itemID) == nil, "PAGE delivery alone must not republish the deleted notebook")
    #expect(try f.a.ownerItemID(ofPage: appended) == nil)
    let undoStore = try f.undoStore(freshPeer: freshPeer)
    _ = try undoStore.undoCollaborationAction(receipt.id, actor: UUID())
    for store in [undoStore, NotebookStore(root: undoStore.root)] {
      try f.expectRestored(store, pageID: appended, source: f.continuation, pageCount: 2)
      #expect(try store.pageID(at: 0, in: f.itemID) == f.pageID)
      #expect(try store.pageID(at: 1, in: f.itemID) == appended,
        "The adopted transient page follows every restored pre-action page")
      #expect(try store.loadPage(f.pageID).elements.first { $0.id == "label" }?.source == f.original)
    }
  }
}
