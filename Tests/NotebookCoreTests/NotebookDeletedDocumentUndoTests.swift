import Foundation
import Testing
@testable import NotebookCore

@Suite("Deleted documents retain independent source and state undo ownership", .serialized)
struct NotebookDeletedDocumentUndoTests {
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    var store: NotebookStore { content.store }
    let id: UUID, boardID: UUID
    let agent = UUID(), human = UUID(), peerA = UUID(), peerB = UUID()
    let block = "counter/a~😀", originalPreamble = "Original preamble"
    let humanHTML = "<button>Accepted human source</button>"

    init() throws {
      content = try NotebookItemLifecycleTests.Fixture()
      var index = try content.store.loadIndex(), board = try content.store.loadBoard(items: index.items)
      boardID = index.rootBoardID
      let created = index.createDocument(title: "Lifecycle document", actor: human)
      let item = try #require(created); id = item.id
      let added = board.addItem(id, to: boardID, near: .init(x: 900, y: 450), actor: human)
      #expect(added)
      var state = DocumentStateJournal(id: id, actor: human)
      let seeded = state.commit(blockID: block, value: .number(3), actor: human)
      #expect(seeded)
      try content.store.saveDocumentWorkspaceBundle(index: index,
        document: .init(id: id, actor: human, preamble: originalPreamble, blocks: [
          .interactive(id: block, html: "<button>Original</button>", css: "button{color:black}",
            javaScript: "window.original = true", initialState: .number(0)),
          .markdown(id: "neighbor", source: "Keep this other block")]), state: state, board: board)
    }

    var cover: CollaborationTarget { .init(kind: .cover, id: id, boardID: boardID) }
    var document: CollaborationTarget { .init(kind: .document, id: id) }

    func basis() throws -> NotebookReadBasis {
      var read = NotebookCommand(command: .read); read.readSnapshots = true
      read.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(id)]).decode(NotebookReadQuery.self)]
      let extent = try #require(try NotebookCommandDispatcher(store: store).handle(read).array.first?["basis"]?.decode(NotebookReadBasis.self))
      return try .merging([extent, store.readBasis(targets: [document])])
    }

    func action(edits: Bool, basis frozen: NotebookReadBasis? = nil) throws -> CollaborationAction {
      let operations = (edits ? [
        CollaborationOperation(kind: .updateBlock, target: document, id: block,
          values: ["html": .string("<button>Agent transient</button>"), "css": .string("button{color:red}")]),
        .init(kind: .setPreamble, target: document, values: ["preamble": .string("Agent transient preamble")]),
        .init(kind: .setBlockState, target: document, id: block, values: ["state": .number(9)])
      ] : []) + [.init(kind: .deleteItem, target: cover)]
      let base = try frozen ?? basis()
      return try .init(additionalOwners: [cover, document], summary: "Delete document through one admitted action",
        expected: store.expectations(base: base, operations: operations), operations: operations)
    }

    func humanEdit(_ destination: NotebookStore, source: Bool, state: Bool) throws {
      if source {
        var document = try destination.loadDocument(id)
        let changed = document.replaceBlockSource(id: block, source: humanHTML, actor: human)
        #expect(changed)
        _ = try destination.saveMergedDocument(document)
      }
      if state {
        var journal = try destination.loadDocumentState(id)
        let changed = journal.commit(blockID: block, value: .number(77), actor: human)
        #expect(changed)
        try destination.saveDocumentState(journal)
      }
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
        if !delivered { throw NotebookStorageError.invalidTransaction("document undo fixture dependencies") }
      }
    }

    func replica(_ name: String) throws -> NotebookStore {
      let peer = NotebookStore(root: store.root.appendingPathComponent(name))
      try peer.prepareEmptyWorkspace(workspaceID: store.workspaceHeader().workspaceID)
      try send(from: store, to: peer, peer: peerA)
      return peer
    }
  }

  @Test(arguments: [false, true])
  func deletingThenUndoingRestoresTheProgramPreambleAndStateFromBeforeTheWholeAction(earlierEdits: Bool) throws {
    let f = try Fixture(), original = try f.store.loadDocument(f.id), state = try f.store.loadDocumentState(f.id)
    let action = try f.action(edits: earlierEdits)
    _ = try f.store.applyCollaborationAction(action, actor: f.agent)
    #expect(try f.store.readItemHeader(f.id) == nil)
    #expect(throws: (any Error).self) { _ = try f.store.readContentHeader(target: f.document) }
    let reopened = NotebookStore(root: f.store.root)
    let undo = try reopened.undoCollaborationAction(action.id, actor: UUID())
    #expect(undo.undo?.lifecycleChanges?.contains { $0.kind == .restoreItem && $0.target == f.cover } == true)
    #expect(try reopened.readItemHeader(f.id)?.kind == .document)
    #expect(try reopened.ownerBoardID(of: f.id) == f.boardID)
    #expect(try reopened.loadDocument(f.id).blocks == original.blocks)
    #expect(try reopened.loadDocument(f.id).preamble == original.preamble)
    #expect(try reopened.loadDocumentState(f.id).value(for: f.block) == state.value(for: f.block))
  }

  @Test(arguments: [false, true])
  func aStaleSourceOrStateBasisRejectsEveryEarlierOperationAtomically(stateChange: Bool) throws {
    let f = try Fixture(), frozen = try f.basis(), action = try f.action(edits: true, basis: frozen)
    try f.humanEdit(f.store, source: !stateChange, state: stateChange)
    let document = try f.store.loadDocument(f.id), state = try f.store.loadDocumentState(f.id)
    let cursor = try f.store.currentChangeCursor()
    do { _ = try f.store.applyCollaborationAction(action, actor: f.agent); Issue.record("A stale destructive extent must reject the complete action") }
    catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.loadDocument(f.id) == document)
    #expect(try f.store.loadDocumentState(f.id) == state)
    #expect(try f.store.readItemHeader(f.id)?.kind == .document)
    #expect(try f.store.collaborationActionIfPresent(action.id) == nil)
  }

  @Test func deletedDocumentRejectsStaleLocalReadsAndWritesWithoutChangingItsRetainedSource() throws {
    let f = try Fixture()
    var stale = try f.store.loadDocument(f.id), state = try f.store.loadDocumentState(f.id)
    let sourceChanged = stale.replaceBlockSource(id: f.block, source: "Stale queued local write", actor: f.human)
    let stateChanged = state.commit(blockID: f.block, value: .number(101), actor: f.human)
    #expect(sourceChanged && stateChanged)
    let action = try f.action(edits: false)
    _ = try f.store.applyCollaborationAction(action, actor: f.agent)
    let reopened = NotebookStore(root: f.store.root), cursor = try reopened.currentChangeCursor()
    #expect(throws: (any Error).self) { _ = try reopened.loadDocument(f.id) }
    #expect(throws: (any Error).self) { _ = try reopened.loadDocumentState(f.id) }
    #expect(throws: (any Error).self) { _ = try reopened.readContentHeader(target: f.document) }
    #expect(throws: (any Error).self) { _ = try reopened.readDocumentBlock(documentID: f.id, blockID: f.block) }
    #expect(throws: (any Error).self) { try reopened.saveDocument(stale) }
    #expect(throws: (any Error).self) { _ = try reopened.saveMergedDocument(stale) }
    #expect(throws: (any Error).self) { try reopened.saveDocumentState(state) }
    #expect(try reopened.currentChangeCursor() == cursor)
    #expect(try reopened.readItemHeader(f.id) == nil)
  }

  @Test(arguments: [false, true])
  func lateHumanSourceAndStateSurviveUndoWithoutResurrectingOnDelivery(freshPeer: Bool) throws {
    let f = try Fixture(), peer = try f.replica("authoring-peer")
    try f.send(from: peer, to: f.store, peer: f.peerB)
    let original = try f.store.loadDocument(f.id), action = try f.action(edits: true)
    _ = try f.store.applyCollaborationAction(action, actor: f.agent)
    // The other author has received neither the source edits nor deletion.
    try f.humanEdit(peer, source: true, state: true)
    let humanState = try #require(try peer.loadDocumentState(f.id).records.first { $0.id == f.block })
    let received = try peer.currentChangeCursor()
    try f.send(from: peer, to: f.store, peer: f.peerB)
    #expect(try f.store.peerCursor(peerID: f.peerB, direction: .incoming) == received)
    #expect(try f.store.readItemHeader(f.id) == nil)
    #expect(try f.store.ownerBoardID(of: f.id) == nil)
    #expect(throws: (any Error).self) { _ = try f.store.readContentHeader(target: f.document) }
    let destination: NotebookStore
    if freshPeer { destination = try f.replica("fresh-receiver") }
    else { destination = NotebookStore(root: f.store.root) }
    let reopened = NotebookStore(root: destination.root)
    _ = try reopened.undoCollaborationAction(action.id, actor: UUID())
    for store in [reopened, NotebookStore(root: reopened.root)] {
      #expect(try store.readItemHeader(f.id)?.kind == .document)
      #expect(try store.ownerBoardID(of: f.id) == f.boardID)
      let restored = try store.loadDocument(f.id)
      #expect(restored.blocks.first { $0.id == f.block }?.html == f.humanHTML)
      #expect(restored.blocks.first { $0.id == f.block }?.css == original.blocks.first { $0.id == f.block }?.css)
      #expect(restored.preamble == f.originalPreamble)
      #expect(restored.blocks.first { $0.id == "neighbor" } == original.blocks.first { $0.id == "neighbor" })
      let restoredState = try #require(try store.loadDocumentState(f.id).records.first { $0.id == f.block })
      #expect(restoredState.value == humanState.value)
      #expect(restoredState.valueVersion.stamp == humanState.valueVersion.stamp && restoredState.valueVersion.human,
        "Restoring a document owner must not replace a received state value or its human source dot")
    }
  }
}
