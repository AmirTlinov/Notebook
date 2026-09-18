import Foundation
import Testing
@testable import NotebookCore

@Suite("Notebook deletion retains concurrent human page continuation", .serialized)
struct NotebookLifecycleConcurrentPageTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-concurrent-page-\(UUID())")
    let a: NotebookStore, b: NotebookStore
    let peerA = UUID(), peerB = UUID(), agent = UUID(), human = UUID()
    let itemID: UUID, pageID: UUID, boardID: UUID
    let original = "Before deletion", continuation = "Human continuation from the other device"

    init() throws {
      a = NotebookStore(root: root.appendingPathComponent("a"))
      b = NotebookStore(root: root.appendingPathComponent("b"))
      let size = PageSize(width: 834, height: 1194)
      let header = try a.initializeWorkspace(actor: human, pageSize: size)
      var index = try a.loadIndex()
      itemID = index.selectedItemID; pageID = try #require(index.selectedPageID)
      boardID = header.rootBoardID
      // A second live notebook makes deletion legitimate, rather than testing
      // the unrelated rule that a workspace must retain one item.
      var tree = try a.loadBoard(items: index.items)
      let created = index.createNotebook(title: "Surviving neighbor", actor: human, pageSize: size)
      let neighbor = try #require(created)
      let placed = tree.addItem(neighbor.item.id, to: boardID, near: .zero, actor: human)
      #expect(placed)
      try a.saveWorkspaceBundle(index: index, page: neighbor.page, board: tree)
      try write(on: a, text: original, actor: human)
      try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
      try send(from: a, to: b, peer: peerA)
      // Drain the initial relay before branching, so each peer has a contiguous
      // incoming cursor for the other device's later authored changes.
      try send(from: b, to: a, peer: peerB)
      #expect(try a.loadPage(pageID) == b.loadPage(pageID))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(on store: NotebookStore, text: String, actor: UUID) throws {
      var page = try store.loadPage(pageID)
      let frame = page.elements.first { $0.id == "label" }?.frame
        ?? PageRect(x: 10, y: 10, width: 220, height: 100)
      let element = AgentElement(id: "label", kind: .markdown, frame: frame,
        source: text, html: "<p>\(text)</p>")
      let changed = page.replaceElements([element], actor: actor)
      #expect(changed)
      _ = try store.savePage(page)
      let version = try #require(try store.loadPage(pageID).collaboration?.fields["elements/label/content"])
      #expect(version.human && version.stamp.actor == actor)
    }

    func deleteThroughNativeOwner() throws {
      // This is the exact content owner called by an admitted agent delete.
      // It intentionally bypasses action/inverse machinery to isolate sync.
      try a.commandTransaction {
        try a.deleteWorkspaceItemContent(itemID: itemID, actor: agent, human: false)
      }
      #expect(try a.readItemHeader(itemID) == nil)
      #expect(try a.ownerItemID(ofPage: pageID) == nil)
      #expect(throws: (any Error).self) { _ = try a.readContentHeader(target: .init(kind: .page, id: pageID)) }
    }

    func deleteThroughAction() throws -> CollaborationReceipt {
      let extent = try #require(try a.readItemLifecycle(itemID))
      let query = try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(itemID)])
        .decode(NotebookReadQuery.self)
      var read = NotebookCommand(command: .read)
      read.queries = [query]; read.readSnapshots = true
      let result = try #require(try NotebookCommandDispatcher(store: a).handle(read).array.first)
      let basis = try #require(try result["basis"]?.decode(NotebookReadBasis.self))
      let operation = CollaborationOperation(kind: .deleteItem, target: extent.target)
      let expected = try a.expectations(base: basis, operations: [operation])
      let receipt = try a.applyCollaborationAction(.init(additionalOwners: [extent.target], summary: "Delete notebook before a remote continuation arrives",
        expected: expected, operations: [operation]), actor: agent)
      #expect(receipt.author == .agent)
      #expect(try a.readItemHeader(itemID) == nil)
      return receipt
    }

    func send(from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws {
      let cursor = try destination.peerCursor(peerID: peer, direction: .incoming)
      let changes = try source.changeJournal(after: cursor)
      for change in changes { try transfer(change, from: source, to: destination, peer: peer) }
    }

    func transfer(_ change: NotebookDurableChange, from source: NotebookStore,
      to destination: NotebookStore, peer: UUID) throws {
      for _ in 0..<64 {
        let missing = try destination.missingBlobHashes(for: change)
        if missing.isEmpty {
          let accepted = try destination.applyRemoteChange(change, peerID: peer)
          #expect(accepted == change.sequence)
          return
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
      throw NotebookStorageError.invalidTransaction("fixture dependency discovery did not terminate")
    }

    func expectAccessibleContinuation(on store: NotebookStore) throws {
      // A hash still present in blobs is not a readable notebook or a page.
      #expect(try store.readItemHeader(itemID)?.kind == .notebook,
        "Accepted human continuation must retain a user-accessible notebook owner")
      #expect(try store.ownerBoardID(of: itemID) == boardID,
        "Retained content must have a visible board placement")
      #expect(try store.ownerItemID(ofPage: pageID) == itemID,
        "A detached page payload is not a retained notebook page")
      let exists = try store.hasStoredValue(pageFile(pageID))
      #expect(exists, "Delivery must not discard the only live human page payload")
      if exists {
        #expect(try store.loadPage(pageID).elements.first { $0.id == "label" }?.source == continuation,
          "The pre-delete inverse must not replace a later accepted human source")
      }
    }
  }

  @Test func deliveryAfterNativeAgentDeleteAdvancesTheCursorWithoutAutomaticallyResurrectingTheNotebook() throws {
    let f = try Fixture()
    try f.deleteThroughNativeOwner()
    // B has not received the deletion. Its authoring cut is concurrent, even
    // though the test executes its native edit after A's local deletion.
    try f.write(on: f.b, text: f.continuation, actor: f.human)
    let editedCursor = try f.b.currentChangeCursor()
    try f.send(from: f.b, to: f.a, peer: f.peerB)
    #expect(try f.a.peerCursor(peerID: f.peerB, direction: .incoming) == editedCursor)
    #expect(try f.a.readItemHeader(f.itemID) == nil)
    #expect(try f.a.ownerItemID(ofPage: f.pageID) == nil)
    // Observation, not a retention guarantee: acceptance does not automatically
    // resurrect the notebook. The undo test below must recover the human source;
    // a retained raw hash alone cannot satisfy that end-to-end requirement.
  }

  @Test func anAlreadyReceivedHumanPageEditCanThenBeExplicitlyDeleted() throws {
    let f = try Fixture()
    try f.write(on: f.b, text: f.continuation, actor: f.human)
    try f.send(from: f.b, to: f.a, peer: f.peerB)
    try f.expectAccessibleContinuation(on: f.a)
    // Control: a fresh native deletion may intentionally remove content it has
    // already received. This is not an unobserved concurrent continuation.
    try f.deleteThroughNativeOwner()
    try f.send(from: f.a, to: f.b, peer: f.peerA)
    #expect(try f.b.readItemHeader(f.itemID) == nil)
    #expect(try f.b.ownerItemID(ofPage: f.pageID) == nil)
    #expect(throws: (any Error).self) { _ = try f.b.readContentHeader(target: .init(kind: .page, id: f.pageID)) }
  }

  @Test func ordinaryConcurrentHumanPageFieldsRetainBothEdits() throws {
    let f = try Fixture()
    let aCursor = try f.a.currentChangeCursor(), bCursor = try f.b.currentChangeCursor()
    let moved = PageRect(x: 330, y: 260, width: 220, height: 100)
    var page = try f.a.loadPage(f.pageID)
    let label = try #require(page.elements.first { $0.id == "label" })
    let changed = page.replaceElements([label.updating(frame: moved)], actor: UUID())
    #expect(changed)
    _ = try f.a.savePage(page)
    try f.write(on: f.b, text: f.continuation, actor: f.human)
    let changesA = try f.a.changeJournal(after: aCursor), changesB = try f.b.changeJournal(after: bCursor)
    for change in changesB { try f.transfer(change, from: f.b, to: f.a, peer: f.peerB) }
    for change in changesA { try f.transfer(change, from: f.a, to: f.b, peer: f.peerA) }
    for store in [f.a, f.b] {
      try f.expectAccessibleContinuation(on: store)
      #expect(try store.loadPage(f.pageID).elements.first { $0.id == "label" }?.frame == moved)
    }
    #expect(try f.a.loadPage(f.pageID) == f.b.loadPage(f.pageID))
  }

  @Test func undoAfterConcurrentHumanPageDeliveryDoesNotRestoreTheStalePreDeleteSource() throws {
    let f = try Fixture()
    let deletion = try f.deleteThroughAction()
    try f.write(on: f.b, text: f.continuation, actor: f.human)
    let editedCursor = try f.b.currentChangeCursor()
    try f.send(from: f.b, to: f.a, peer: f.peerB)
    #expect(try f.a.peerCursor(peerID: f.peerB, direction: .incoming) == editedCursor)
    _ = try f.a.undoCollaborationAction(deletion.id, actor: UUID())
    try f.expectAccessibleContinuation(on: f.a)
    try f.send(from: f.a, to: f.b, peer: f.peerA)
    try f.expectAccessibleContinuation(on: f.b)
    // Read through fresh store instances as well, not an in-memory page cache.
    try f.expectAccessibleContinuation(on: NotebookStore(root: f.a.root))
    try f.expectAccessibleContinuation(on: NotebookStore(root: f.b.root))
  }
}
