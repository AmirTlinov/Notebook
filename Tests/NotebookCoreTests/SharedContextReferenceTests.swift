import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Context references are addressed scopes, not full history reads")
struct SharedContextReferenceTests {
  private func fixture(_ body: (NotebookStore, UUID, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-reference-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor, try #require(try store.loadIndex().selectedPageID), header.rootBoardID)
  }

  @Test func aHundredThousandRepeatedReferencesDoNotReadTheirRepliesOrExpandAuthority() throws {
    try fixture { store, actor, pageID, boardID in
      let target = CollaborationTarget(kind: .page, id: pageID), files = try store.referenceSourceFiles(target: target)
      let reference = CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 120, height: 120),
        revision: try NotebookStore.referenceRevision(target: target, files: files))
      let first = try store.appendContext(references: [reference], author: .human, actor: actor, text: "Human scope")
      let source = try AgentPinnedSource.capture(requestID: first.id, reference: reference, files: files)
        .withVisual(nil, unavailable: "no_fixture_pixels")
      let file = store.contextFile(first.id), root = store.contextFile(first.id) + "#"
      let forged = CollaborationReference(target: target, region: .init(x: 150, y: 150, width: 120, height: 120), revision: reference.revision)
      var corrupted = ""
      try store.commandTransaction {
        let database = store.currentSQL!
        for index in 1..<100_000 {
          let references = index == 50_000 ? [] : index == 99_999 ? [forged] : [reference]
          let entry = SharedContextEntry(author: .agent, references: references, replyTo: first.entry.id,
            text: "Reply \(index)", stamp: .init(counter: UInt64(index + 1), actor: actor))
          let address = root + "/entries/@" + entry.id.uuidString.lowercased()
          try store.writeFragment(.init(address: address, file: file, parent: root, collection: "entries", member: entry.id.uuidString.lowercased(),
            position: index, value: .encode(entry), collections: []), database: database)
          if index == 50_000 { corrupted = address }
        }
        let bad = try database.putBlob(Data("this reply is not requested".utf8))
        try database.run("UPDATE records SET hash=? WHERE address=?", [.text(bad), .text(corrupted)])
      }
      try store.commandTransaction { () throws -> Void in
        let database = store.currentSQL!
        sqlite3_progress_handler(database.handle, 50_000, { _ in 1 }, nil)
        defer { sqlite3_progress_handler(database.handle, 0, nil, nil) }
        let references = try store.contextReferences(first.id)
        #expect(references.count == 2)
        #expect(references.contains(reference) && references.contains(forged))
        #expect(try store.firstHumanContextEntry(first.id) == first.entry)
        #expect(try !store.contextContainsHumanReference(forged, contextID: first.id))
        try store.saveAttentionEvidence([source], contextID: first.id)
        #expect(try store.hasAttentionEvidence(contextID: first.id))
        #expect(try store.attentionEvidence(contextID: first.id, referenceID: reference.id) == source)
      }
      let itemID = try #require(try store.ownerItemID(ofPage: pageID))
      let action = try CollaborationAction(contextID: first.id, summary: "Move only the indicated notebook",
        expected: [.init(target: .init(kind: .board, id: boardID), revision: try store.targetContentRevision(target: .init(kind: .board, id: boardID)))],
        operations: [.init(kind: .moveItem, target: .init(kind: .board, id: boardID), id: itemID.uuidString,
          values: ["center": .encode(WorldPoint(x: 42, y: 73))])])
      let cursor = try store.sharedContextPage(contextID: first.id, limit: 1).readCursor
      let receipt = try store.applyCollaborationAction(action, actor: actor)
      #expect(receipt.id == action.id)
      #expect(try store.sharedContextPage(contextID: first.id, limit: 1).readCursor == cursor)
      #expect(try store.undoCollaborationAction(receipt.id, actor: actor).undo != nil)
    }
  }

  @Test(arguments: ["references", "bytes"])
  func oversizedScopeRefusesBeforeAnyActionOrReceiptIsPublished(boundary: String) throws {
    try fixture { store, actor, pageID, boardID in
      let target = CollaborationTarget(kind: .page, id: pageID)
      let first = try store.appendContext(references: [], author: .human, actor: actor, text: "Question")
      let count = boundary == "references" ? 17 : 5
      for _ in 0..<count {
        let references = (0..<(boundary == "references" ? 32 : 1)).map { _ in CollaborationReference(target: target, revision: "reference") }
        _ = try store.appendContext(references: references, author: .human, actor: actor,
          contextID: first.id, replyTo: first.entry.id, text: boundary == "bytes" ? String(repeating: "x", count: 1_048_576) : "Scoped")
      }
      let cursor = try store.currentChangeCursor(), board = try #require(try store.readBoardNodeHeader(boardID))
      let itemID = try #require(try store.ownerItemID(ofPage: pageID))
      let action = try CollaborationAction(contextID: first.id, summary: "Must fail atomically",
        expected: [.init(target: .init(kind: .board, id: boardID), revision: try store.targetContentRevision(target: .init(kind: .board, id: boardID)))],
        operations: [.init(kind: .moveItem, target: .init(kind: .board, id: boardID), id: itemID.uuidString,
          values: ["center": .encode(WorldPoint(x: 10, y: 10))])])
      do { _ = try store.applyCollaborationAction(action, actor: actor); Issue.record("Oversized context was accepted") }
      catch let error as CollaborationError { #expect(error.code == "context_reference_budget") }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try !store.hasStoredValue("collaboration/actions/" + action.id.uuidString.lowercased() + ".json"))
      #expect(try store.readBoardNodeHeader(boardID) == board)
    }
  }

  @Test func externalIndexValidationChecksReferenceIdentityAndAuthorWithoutChangingCanonicalBytes() throws {
    try fixture { store, actor, pageID, _ in
      let reference = CollaborationReference(target: .init(kind: .page, id: pageID), revision: "immutable")
      let first = try store.appendContext(references: [reference], author: .human, actor: actor, text: "Human")
      let proof = try store.readTransaction { _ in try store.archiveContentProof() }
      try store.commandTransaction { try store.currentSQL!.run("UPDATE context_references SET author='agent'") }
      var rejected = false
      do { try store.readTransaction { _ in try store.validateContextOrderIndex() } }
      catch NotebookStorageError.corruptRecord(let address) {
        #expect(address.hasPrefix("context reference index:"))
        rejected = true
      }
      #expect(rejected)
      try store.prepareContextOrderIndexForTransfer()
      try store.readTransaction { _ in try store.validateContextOrderIndex() }
      #expect(try store.readTransaction { _ in try store.archiveContentProof() } == proof)
      #expect(try store.readTransaction { _ in try store.contextContainsHumanReference(reference, contextID: first.id) })
      #expect(try store.readTransaction { _ in try store.contextReferences(first.id) } == [reference])
    }
  }
}
