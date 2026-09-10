import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Agent state changes address their program and state record", .serialized)
struct NotebookAgentDocumentStateProjectionTests {
  private let blockID = "counter/a~b"
  private func fixture(_ body: (NotebookStore, UUID, DocumentDocument) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-document-state-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let target = CollaborationTarget(kind: .board, id: header.rootBoardID), id = UUID()
    let board = try #require(try store.readBoardNodeHeader(header.rootBoardID))
    let create = CollaborationAction(summary: "State fixture", expected: [
      .init(target: target, revision: board.board.stamp.revision),
      .init(target: .init(kind: .workspace, id: header.rootBoardID), revision: header.stamp.revision)], operations: [
        .init(kind: .createDocument, target: target, id: id.uuidString, values: [
          "center": try .encode(WorldPoint.zero), "paperSize": .string("a4"), "blocks": try .encode([
            DocumentBlock.interactive(id: blockID, html: "<button>+</button>", initialState: .number(3)),
            DocumentBlock.markdown(id: "unrequested", source: String(repeating: "x", count: 1_000_000))])])])
    _ = try store.applyCollaborationAction(create, actor: actor)
    try body(store, actor, store.loadDocument(id))
  }

  private func action(_ store: NotebookStore, document: DocumentDocument, value: JSONValue = .number(7)) throws -> CollaborationAction {
    let state = try #require(try store.storedFragments(address: stateFile(document.id) + "#", descendants: false).first)
    let stamp = try #require(state.value["stamp"]).decode(VersionStamp.self)
    let target = CollaborationTarget(kind: .document, id: document.id)
    return .init(summary: "Change one program", expected: [.init(target: target,
      revision: document.contentStamp.revision, stateRevision: stamp.revision)], operations: [
        .init(kind: .setBlockState, target: target, id: blockID, values: ["state": value])])
  }

  @Test func applyUndoAndRetryDoNotReadOtherBlocksOrOneHundredThousandHistoricalStates() throws {
    try fixture { store, actor, document in
      let file = stateFile(document.id), clock = VersionStamp(counter: 100_000, actor: actor)
      try store.commandTransaction {
        for index in 0..<100_000 {
          let record = DocumentStateRecord(id: "retired-\(index)", value: .number(Double(index)), stamp: clock)
          let fragment = NotebookStoredFragment(address: file + "#/records/@" + record.id, file: file,
            parent: file + "#", collection: "records", member: record.id, position: index,
            value: try .encode(record), collections: [])
          try store.writeFragment(fragment, database: store.currentSQL!)
        }
        let root = try #require(try store.storedFragments(address: file + "#", descendants: false).first)
        try store.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(clock))), database: store.currentSQL!)
      }
      let documentRows = try store.storedFragments(address: documentFile(document.id) + "#")
      // Poison AFTER seeding and derived indexes. Neither unrequested body may
      // be decoded by this later command, including its durable commit flush.
      try store.commandTransaction {
        let hash = try store.currentSQL!.putBlob(Data("must not decode an unrequested body".utf8))
        for address in [file + "#/records/@retired-50000", documentFile(document.id) + "#/blocks/@unrequested"] {
          try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)])
        }
      }
      let cursor = try store.currentChangeCursor(), command = try action(store, document: document)
      let receipt = try bounded(store) { try store.applyCollaborationAction(command, actor: UUID()) }
      #expect(receipt.revisions.count == 1)
      let address = file + "#/records/@" + fieldKey([blockID])
      let delivered = try #require(try store.storedFragments(address: address).first).value.decode(DocumentStateRecord.self)
      #expect(delivered.value == .number(7))
      let undo = try bounded(store) { try store.undoCollaborationAction(command.id, actor: actor) }
      #expect(undo.undo?.restored == 1 && undo.undo?.preserved.isEmpty == true)
      let restored = try #require(try store.storedFragments(address: address).first).value.decode(DocumentStateRecord.self)
      #expect(restored.value == .number(3) && restored.stamp > delivered.stamp)
      let after = try store.currentChangeCursor()
      let echo = try bounded(store) { try store.applyCollaborationAction(command, actor: actor) }
      #expect(echo == undo)
      #expect(try store.currentChangeCursor() == after)
      let changes = try store.readChangedAddresses(after: cursor, through: after).addresses
      #expect(Set(changes.filter { $0.hasPrefix(file) }) == [file + "#", address])
      #expect(!changes.contains { $0.hasPrefix(documentFile(document.id)) })
      #expect(try store.storedFragments(address: documentFile(document.id) + "#", descendants: false).first == documentRows.first { $0.parent == nil })
      let count = try store.sqlRead { try $0.rows("SELECT count(*) FROM records WHERE parent=? AND collection='records'", [.text(file + "#")]).first![0].integer }
      #expect(count == 100_001)
    }
  }

  @Test func humanContinuationAndStaleExpectedRevisionRemainProtected() throws {
    try fixture { store, actor, document in
      let command = try action(store, document: document)
      _ = try store.applyCollaborationAction(command, actor: UUID())
      var state = try store.loadDocumentState(document.id)
      let changed = state.commit(blockID: blockID, value: .number(11), actor: actor)
      #expect(changed)
      try store.saveDocumentState(state)
      let undo = try store.undoCollaborationAction(command.id, actor: actor)
      #expect(undo.undo?.restored == 0 && undo.undo?.preserved.count == 1)
      #expect(try store.loadDocumentState(document.id).value(for: blockID) == .number(11))
      let stale = CollaborationAction(summary: "Stale command", expected: command.expected, operations: command.operations)
      let cursor = try store.currentChangeCursor()
      do { _ = try store.applyCollaborationAction(stale, actor: UUID()); Issue.record("Stale state revision was accepted") }
      catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  private enum Fault: Error { case injected }
  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func stateReceiptAndCursorHaveOneFailureBoundary(fault: NotebookStorageFault) throws {
    try fixture { store, actor, document in
      let command = try action(store, document: document), cursor = try store.currentChangeCursor()
      let before = try store.loadDocumentState(document.id)
      let failing = NotebookStore(root: store.root) { point in
        if String(describing: point) == String(describing: fault) { throw Fault.injected }
      }
      #expect(throws: Fault.self) { try failing.applyCollaborationAction(command, actor: actor) }
      if case .afterCommit = fault {
        #expect(try store.loadDocumentState(document.id).value(for: blockID) == .number(7))
        #expect(try store.currentChangeCursor() == cursor + 1)
      } else {
        #expect(try store.loadDocumentState(document.id) == before)
        #expect(try store.currentChangeCursor() == cursor)
        #expect(try !store.hasStoredValue("collaboration/actions/" + command.id.uuidString.lowercased() + ".json"))
      }
      let recovered = try store.applyCollaborationAction(command, actor: actor)
      #expect(recovered.action == command)
      #expect(try store.loadDocumentState(document.id).value(for: blockID) == .number(7))
      #expect(try store.currentChangeCursor() == cursor + 1)
    }
  }

  private final class SQLCounter { var steps = 0 }
  private func bounded<T>(_ store: NotebookStore, _ operation: () throws -> T) throws -> T {
    let counter = SQLCounter()
    let result = try withExtendedLifetime(counter) {
      try store.commandTransaction {
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
          let counter = Unmanaged<SQLCounter>.fromOpaque(raw!).takeUnretainedValue()
          counter.steps += 1
          return counter.steps < 200_000 ? 0 : 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        return try operation()
      }
    }
    #expect(counter.steps > 0 && counter.steps < 200_000)
    print("AGENT_DOCUMENT_STATE_ADDRESSED foreign_states=100000 vm=\(counter.steps)")
    return result
  }
}
