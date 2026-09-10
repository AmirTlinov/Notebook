import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Agent source edits preserve unrequested programs and causal history", .serialized)
struct NotebookAgentDocumentSourceProjectionTests {
  private let blockID = "counter/a~😀"

  private func fixture(_ body: (NotebookStore, UUID, DocumentDocument) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-document-source-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let created = index.createDocument(title: "Addressed source", actor: actor)
    let item = try #require(created)
    let added = board.addItem(item.id, to: header.rootBoardID, near: .zero, actor: actor)
    #expect(added)
    try store.saveDocumentWorkspaceBundle(index: index, document: .init(id: item.id, actor: actor,
      blocks: [.interactive(id: blockID, html: "<button>Before</button>", initialState: .number(3)),
        .markdown(id: "unrequested", source: String(repeating: "x", count: 1_000_000)),
        .markdown(id: "counter/a~😀/child", source: "Not the parent's program")]),
      state: .init(id: item.id, actor: actor), board: board)
    try body(store, actor, store.loadDocument(item.id))
  }

  private func command(_ document: DocumentDocument, operations: [CollaborationOperation]? = nil) -> CollaborationAction {
    let target = CollaborationTarget(kind: .document, id: document.id)
    return .init(summary: "Edit only the named source", expected: [.init(target: target, revision: document.contentStamp.revision)],
      operations: operations ?? [.init(kind: .updateBlock, target: target, id: blockID, values: ["html": .string("<button>After</button>")])])
  }

  @Test func applyUndoAndRetryDoNotDecodeForeignSourceOrNinetyNineThousandCausalFields() throws {
    try fixture { store, actor, document in
      let file = documentFile(document.id), root = file + "#"
      try store.commandTransaction {
        for index in 0..<99_000 {
          let key = fieldKey(["blocks", "retired-\(index)", "content"])
          let version = ContentFieldVersion(stamp: document.contentStamp, human: true)
          try store.writeFragment(.init(address: root + "/collaboration/fields/@" + fieldKey([key]), file: file,
            parent: root, collection: "collaboration/fields", member: key, position: 0,
            value: try .encode(version), collections: []), database: store.currentSQL!)
        }
      }
      let foreignField = root + "/collaboration/fields/@" + fieldKey([fieldKey(["blocks", "retired-50000", "content"])])
      let foreignBlock = root + "/blocks/@unrequested"
      try poison(store, addresses: [foreignField, foreignBlock])
      let untouched = try store.sqlRead { try $0.rows("SELECT address,hash,position FROM records WHERE file=? ORDER BY address", [.text(file)]).map { [$0[0].text!, $0[1].text!, String($0[2].integer!)] } }
      let cursor = try store.currentChangeCursor(), action = command(document)
      let receipt = try bounded(store) { try store.applyCollaborationAction(action, actor: UUID()) }
      #expect(receipt.changes.count == 2)
      #expect(try store.readDocumentBlock(documentID: document.id, blockID: blockID)?.block.html == "<button>After</button>")
      let committed = try store.currentChangeCursor()
      #expect(try bounded(store) { try store.applyCollaborationAction(action, actor: actor) } == receipt)
      #expect(try store.currentChangeCursor() == committed)
      let undo = try bounded(store) { try store.undoCollaborationAction(action.id, actor: actor) }
      #expect(undo.undo?.restored == 2 && undo.undo?.preserved.isEmpty == true)
      #expect(try store.readDocumentBlock(documentID: document.id, blockID: blockID)?.block.html == "<button>Before</button>")
      let finalCursor = try store.currentChangeCursor()
      #expect(try bounded(store) { try store.undoCollaborationAction(action.id, actor: actor) } == undo)
      #expect(try store.currentChangeCursor() == finalCursor && finalCursor == cursor + 2)
      let changes = Set(try store.readChangedAddresses(after: cursor, through: finalCursor).addresses)
      let final = try store.sqlRead { try $0.rows("SELECT address,hash,position FROM records WHERE file=? ORDER BY address", [.text(file)]).map { [$0[0].text!, $0[1].text!, String($0[2].integer!)] } }
      #expect(final.count == untouched.count)
      #expect(final.filter { !changes.contains($0[0]) } == untouched.filter { !changes.contains($0[0]) })
      #expect(!changes.contains(foreignField) && !changes.contains(foreignBlock))
      #expect(!changes.contains { $0.hasPrefix(stateFile(document.id)) })
      #expect(try store.sqlRead { try $0.rows("SELECT member,position FROM records WHERE parent=? AND collection='blocks' ORDER BY position", [.text(root)]) }.compactMap { $0[0].text }
        == document.blocks.map { collaborationIdentity($0.id) })

      // A missing implicit clock cannot use the tiny projection's field count
      // to overfill an otherwise full causal owner. The index count is needed
      // only on allocation, not the addressed replacement measured above.
      let contentKey = fieldKey(["blocks", blockID, "content"])
      try store.commandTransaction {
        try store.removeFragment(root + "/collaboration/fields/@" + fieldKey([contentKey]), database: store.currentSQL!)
        let count = try store.currentSQL!.rows("SELECT count(*) FROM records WHERE parent=? AND collection='collaboration/fields'", [.text(root)]).first![0].integer!
        for index in Int(count)..<CollaborativeContent.maximumFieldCount {
          let key = fieldKey(["blocks", "filled-\(index)", "content"])
          try store.writeFragment(.init(address: root + "/collaboration/fields/@" + fieldKey([key]), file: file,
            parent: root, collection: "collaboration/fields", member: key, position: 0,
            value: try .encode(ContentFieldVersion(stamp: document.contentStamp, human: true)), collections: []), database: store.currentSQL!)
        }
      }
      let read = try #require(try store.readDocumentBlock(documentID: document.id, blockID: blockID))
      let overflowing = CollaborationAction(summary: "An implicit clock needs its actual owner's budget",
        expected: [.init(target: .init(kind: .document, id: document.id), revision: read.contentStamp.revision)], operations: action.operations)
      let beforeOverflow = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.limitExceeded("document_causal_fields")) {
        try store.applyCollaborationAction(overflowing, actor: actor)
      }
      #expect(try store.currentChangeCursor() == beforeOverflow)
      #expect(try store.readDocumentBlock(documentID: document.id, blockID: blockID) == read)
    }
  }

  @Test func mixedStateSourceAndPreambleKeepUnrequestedMembersAndTheirOrder() throws {
    try fixture { store, actor, document in
      let target = CollaborationTarget(kind: .document, id: document.id)
      let state = try store.loadDocumentState(document.id)
      let action = CollaborationAction(summary: "Two kinds of values, one transaction", expected: [
        .init(target: target, revision: document.contentStamp.revision, stateRevision: state.stamp.revision)], operations: [
          .init(kind: .updateBlock, target: target, id: document.blocks[2].id, values: ["source": .string("Last changed first")]),
          .init(kind: .setBlockState, target: target, id: blockID, values: ["state": .number(9)]),
          .init(kind: .setPreamble, target: target, values: ["preamble": .string("New preamble")]),
          .init(kind: .updateBlock, target: target, id: blockID, values: ["css": .string("button{color:red}")])])
      _ = try store.applyCollaborationAction(action, actor: UUID())
      let updated = try store.loadDocument(document.id)
      #expect(updated.blocks.map(\.id) == document.blocks.map(\.id))
      #expect(updated.blocks[1] == document.blocks[1] && updated.preamble == "New preamble")
      #expect(updated.blocks[0].html == document.blocks[0].html && updated.blocks[0].css == "button{color:red}")
      #expect(updated.blocks[2].source == "Last changed first")
      #expect(try store.loadDocumentState(document.id).value(for: blockID) == .number(9))
      #expect(updated.collaboration?.fields[fieldKey(["blocks", "unrequested", "content"])] == document.collaboration?.fields[fieldKey(["blocks", "unrequested", "content"])])
      let undo = try store.undoCollaborationAction(action.id, actor: actor)
      #expect(undo.undo?.preserved.isEmpty == true)
      #expect(try store.loadDocument(document.id).blocks == document.blocks)
      #expect(try store.loadDocument(document.id).preamble == document.preamble)
      #expect(try store.loadDocumentState(document.id).value(for: blockID) == .number(3))
    }
  }

  @Test func humanAdoptionAndEvenReturningToTheAgentTextPreventUndo() throws {
    try fixture { store, actor, original in
      let action = command(original)
      _ = try store.applyCollaborationAction(action, actor: UUID())
      var document = try store.loadDocument(original.id)
      let edited = document.replaceBlockSource(id: blockID, source: "Human meaning", actor: actor)
      #expect(edited)
      _ = try store.saveMergedDocument(document)
      let returned = document.replaceBlockSource(id: blockID, source: "<button>After</button>", actor: actor)
      #expect(returned)
      _ = try store.saveMergedDocument(document)
      let undo = try store.undoCollaborationAction(action.id, actor: actor)
      #expect(undo.undo?.restored == 0 && undo.undo?.preserved.count == 2)
      #expect(try store.loadDocument(original.id).blocks[0].source == "<button>After</button>")
      let stale = CollaborationAction(summary: "Stale source", expected: action.expected, operations: action.operations)
      let cursor = try store.currentChangeCursor()
      do { _ = try store.applyCollaborationAction(stale, actor: UUID()); Issue.record("A stale source changed the document") }
      catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test(arguments: ["", " ", String(repeating: "x", count: 121)])
  func invalidSourceIDsFailBeforeReadingPrograms(id: String) throws {
    try fixture { store, actor, document in
      try poison(store, addresses: [documentFile(document.id) + "#/blocks/@unrequested"])
      let target = CollaborationTarget(kind: .document, id: document.id)
      let action = command(document, operations: [.init(kind: .updateBlock, target: target,
        id: id, values: ["source": .string("No target")])])
      let cursor = try store.currentChangeCursor()
      do { _ = try store.applyCollaborationAction(action, actor: actor); Issue.record("An invalid source address was admitted") }
      catch let error as CollaborationError { #expect(error.code == "invalid_operation") }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func fullSourceOperationsStillOwnTheirActualSequenceAndKeepHistory() throws {
    try fixture { store, actor, original in
      let target = CollaborationTarget(kind: .document, id: original.id)
      let reordered = Array(original.blocks.reversed())
      let action = command(original, operations: [.init(kind: .reorderBlocks, target: target,
        values: ["ids": .array(reordered.map { .string($0.id) })])])
      _ = try store.applyCollaborationAction(action, actor: actor)
      #expect(try store.loadDocument(original.id).blocks == reordered)
      _ = try store.undoCollaborationAction(action.id, actor: actor)
      #expect(try store.loadDocument(original.id).blocks == original.blocks)
    }
  }

  @Test(arguments: ["bytes", "fragments"])
  func readBudgetRefusesBeforeDecodingAnAddressedSourceBody(kind: String) throws {
    try fixture { store, actor, original in
      var document = original
      let nested: JSONValue = kind == "bytes" ? .string(String(repeating: "x", count: 4 * 1_024 * 1_024))
        : .object(["blocks": .array((0..<4_096).map { .object(["id": .string("child-\($0)")]) })])
      let changed = document.replaceContent(blocks: [.interactive(id: blockID, html: "<p>Large state</p>", initialState: nested)], actor: actor)
      #expect(changed)
      document = try store.saveMergedDocument(document)
      let root = documentFile(document.id) + "#/blocks/@" + fieldKey([blockID])
      // The fragment case keeps its 4,096 children but corrupts the first
      // program header. The bytes case needs its large first body for admission.
      if kind == "fragments" { try poison(store, addresses: [root]) }
      let cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.limitExceeded("document_source_command")) {
        try store.applyCollaborationAction(command(document), actor: actor)
      }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func severalDocumentsShareOneReadBudgetBeforeTheFirstProgramIsDecoded() throws {
    try fixture { store, actor, _ in
      var documents: [DocumentDocument] = []
      for _ in 0..<2 {
        var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
        let created = index.createDocument(title: "Budget", actor: actor)
        let item = try #require(created)
        let added = board.addItem(item.id, to: index.rootBoardID, near: .zero, actor: actor)
        #expect(added)
        let document = DocumentDocument(id: item.id, actor: actor, blocks: [
          .interactive(id: "large", html: "<p>Program</p>", initialState: .string(String(repeating: "x", count: 2_200_000)))])
        try store.saveDocumentWorkspaceBundle(index: index, document: document, state: .init(id: item.id, actor: actor), board: board)
        documents.append(try store.loadDocument(item.id))
      }
      let action = CollaborationAction(summary: "One budget across two owners", expected: documents.map {
        .init(target: .init(kind: .document, id: $0.id), revision: $0.contentStamp.revision)
      }, operations: documents.map { .init(kind: .updateBlock, target: .init(kind: .document, id: $0.id),
        id: "large", values: ["html": .string("<p>Changed</p>")]) })
      // Keep both lengths over the limit while making either early decode fail.
      try store.commandTransaction {
        let hash = try store.currentSQL!.putBlob(Data(String(repeating: "{", count: 2_200_000).utf8))
        for document in documents {
          try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(documentFile(document.id) + "#/blocks/@large")])
        }
      }
      let cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.limitExceeded("document_source_command")) {
        try store.applyCollaborationAction(action, actor: actor)
      }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func UUIDSourceVersionUsesTheSameCanonicalIdentityAsStorage() throws {
    try fixture { store, actor, original in
      let id = UUID().uuidString
      var document = original
      let changed = document.replaceContent(blocks: [.markdown(id: id, source: "Before")], actor: actor)
      #expect(changed)
      document = try store.saveMergedDocument(document)
      let target = CollaborationTarget(kind: .document, id: document.id)
      _ = try store.applyCollaborationAction(command(document, operations: [.init(kind: .updateBlock, target: target,
        id: id, values: ["source": .string("After")])]), actor: UUID())
      let final = try store.loadDocument(document.id)
      let version = try #require(final.collaboration?.fields[fieldKey(["blocks", id.lowercased(), "content"])])
      #expect(!version.human)
      #expect(final.sourceVersion(blockID: id) == version && final.sourceVersion(blockID: id.lowercased()) == version)
    }
  }

  @Test func escapedSourceDeliveryCarriesUntouchedFieldVersionsSoConcurrentCSSSurvives() throws {
    try fixture { a, actor, document in
      let b = NotebookStore(root: a.root.appendingPathComponent("peer"))
      let workspace = try a.workspaceHeader()
      try b.prepareEmptyWorkspace(workspaceID: workspace.workspaceID)
      for change in try a.changeJournal(after: 0) { try deliver(change, from: a, to: b, peerID: actor) }
      let prior = try a.currentChangeCursor(), target = CollaborationTarget(kind: .document, id: document.id)
      let css = "button{color:rgb(37,114,9)}"
      _ = try b.applyCollaborationAction(command(document, operations: [.init(kind: .updateBlock, target: target,
        id: blockID, values: ["css": .string(css)])]), actor: UUID())
      _ = try a.applyCollaborationAction(command(document), actor: UUID())
      let change = try #require(try a.changeJournal(after: prior).first)
      let requiredKey = fieldKey(["blocks", blockID, "css"])
      let cssAddress = documentFile(document.id) + "#/collaboration/fields/@" + fieldKey([requiredKey])
      let manifest = try a.commandTransaction { try JSONDecoder().decode(NotebookChangeManifest.self, from: a.currentSQL!.blob(change.manifestHash)) }
      #expect(manifest.records.contains { $0.address == cssAddress }, "An unchanged source field still carries the author's version with its program body")
      try deliver(change, from: a, to: b, peerID: actor)
      let joined = try b.loadDocument(document.id)
      #expect(joined.blocks[0].html == "<button>After</button>" && joined.blocks[0].css == css)
      #expect(joined.blocks[1] == document.blocks[1] && joined.blocks[2] == document.blocks[2])
      let cursor = try b.currentChangeCursor()
      try deliver(change, from: a, to: b, peerID: actor)
      #expect(try b.currentChangeCursor() == cursor && b.loadDocument(document.id) == joined)
      // Whole-source native publication uses the same escaped causal address.
      var native = try a.loadDocument(document.id)
      let changed = native.replaceBlockSource(id: blockID, source: "<button>Native</button>", actor: actor)
      #expect(changed)
      _ = try a.saveMergedDocument(native)
      let next = try #require(try a.changeJournal(after: change.sequence).first)
      let nextManifest = try a.commandTransaction { try JSONDecoder().decode(NotebookChangeManifest.self, from: a.currentSQL!.blob(next.manifestHash)) }
      #expect(nextManifest.records.contains { $0.address == cssAddress })
      try deliver(next, from: a, to: b, peerID: actor)
      #expect(try b.loadDocument(document.id).blocks[0].css == css)
      #expect(try b.loadDocument(document.id).blocks[0].html == "<button>Native</button>")
    }
  }

  private func deliver(_ change: NotebookDurableChange, from a: NotebookStore, to b: NotebookStore, peerID: UUID) throws {
    while true {
      let missing = try b.missingBlobHashes(for: change)
      if missing.isEmpty { break }
      for hash in missing {
        let size = try a.blobSize(hash: hash)
        var data = Data()
        while Int64(data.count) < size { data += try a.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576) }
        try b.stageBlob(data: data, expectedHash: hash)
      }
    }
    _ = try b.applyRemoteChange(change, peerID: peerID)
  }

  private enum Fault: Error { case injected }
  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func sourceReceiptAndCursorHaveOneFailureBoundary(fault: NotebookStorageFault) throws {
    try fixture { store, actor, document in
      let action = command(document), cursor = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root) { point in
        if String(describing: point) == String(describing: fault) { throw Fault.injected }
      }
      #expect(throws: Fault.self) { try failing.applyCollaborationAction(action, actor: actor) }
      if case .afterCommit = fault {
        #expect(try store.loadDocument(document.id).blocks[0].html == "<button>After</button>")
        #expect(try store.currentChangeCursor() == cursor + 1)
      } else {
        #expect(try store.loadDocument(document.id) == document)
        #expect(try store.currentChangeCursor() == cursor)
      }
      #expect(try store.applyCollaborationAction(action, actor: actor).action == action)
      #expect(try store.currentChangeCursor() == cursor + 1)
    }
  }

  private func poison(_ store: NotebookStore, addresses: [String]) throws {
    try store.commandTransaction {
      let hash = try store.currentSQL!.putBlob(Data("must not decode an unrelated source".utf8))
      for address in addresses { try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)]) }
    }
  }

  private final class SQLCounter { var steps = 0 }
  private func bounded<T>(_ store: NotebookStore, _ operation: () throws -> T) throws -> T {
    let counter = SQLCounter()
    let result = try withExtendedLifetime(counter) {
      try store.commandTransaction {
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
          let counter = Unmanaged<SQLCounter>.fromOpaque(raw!).takeUnretainedValue()
          counter.steps += 1; return counter.steps < 200_000 ? 0 : 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        return try operation()
      }
    }
    #expect(counter.steps > 0 && counter.steps < 200_000)
    print("AGENT_DOCUMENT_SOURCE_ADDRESSED foreign_fields=99000 vm=\(counter.steps)")
    return result
  }
}
