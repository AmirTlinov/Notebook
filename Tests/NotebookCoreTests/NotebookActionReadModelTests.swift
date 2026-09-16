import Foundation
import Testing
@testable import NotebookCore

@Suite("Large action history does not reload its source or inverse", .serialized)
struct NotebookActionReadModelTests {
  private func fixture(_ body: (NotebookStore, UUID, CollaborationReceipt, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("action-read-model-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), documentID = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let blocks = (0..<140).map { DocumentBlock.markdown(id: "part-\($0)",
      source: "# Chapter \($0)\n\n" + String(repeating: "Large source. ", count: 3_800)) }
    let receipt = try store.applyCollaborationAction(.init(summary: "A large document", expected: [
      .init(target: board, revision: store.targetContentRevision(target: board)),
      .init(target: .init(kind: .workspace, id: header.rootBoardID), revision: store.workspaceHeader().stamp.revision)
    ], operations: [.init(kind: .createDocument, target: board, id: documentID.uuidString, values: [
      "title": .string("Large control"), "paperSize": .string("a4"), "center": try .encode(WorldPoint.zero),
      "blocks": try .encode(blocks)])]), actor: actor)
    try body(store, actor, receipt, documentID)
  }

  @Test func closedDocumentMetadataAndDeliveryFitAnAddressedReadWithoutItsFourteenMiBReceipt() throws {
    try fixture { store, _, receipt, _ in
      let fullBytes = try JSONEncoder().encode(receipt)
      #expect(fullBytes.count > 8 * 1_024 * 1_024)
      let beforeCursor = try store.currentChangeCursor()
      let model = try store.readTransaction { _ in
        try store.currentSQL!.limitReads(.init(rows: 100, bytes: 256 * 1_024,
          valueBytes: 128 * 1_024, reason: "compact_action_history"))
        return try store.actionReadModel(receipt.id)
      }
      #expect(try JSONEncoder().encode(model).count < 128 * 1_024)
      #expect(model.actionVersion == (try receipt.deliveryVersion()))
      #expect(model.id == receipt.id && model.revisions == receipt.revisions)
      #expect(try store.currentChangeCursor() == beforeCursor)
      try store.acknowledgeReceivedActions(deviceID: UUID())
      let delivery = try #require(store.deviceActionReceipts(actionIDs: [receipt.id]).first)
      #expect(delivery.matches(model) && !delivery.displayComplete)
      var command = NotebookCommand(command: .actionDetails); command.actionID = receipt.id
      let detail = try #require(NotebookCommandDispatcher(store: store).handle(command).array.first)
      #expect(detail["publication"]?["receivedByIPad"] == .string("confirmed"))
      #expect(detail["publication"]?["shownOnIPad"] == .string("awaiting_display"))
      #expect(try store.collaborationActions().first == receipt)
    }
  }

  @Test func sourceComparisonPreservesHumanContinuationWithoutRetainingTheOldSource() throws {
    try fixture { store, _, receipt, documentID in
      var document = try store.loadDocument(documentID)
      var blocks = document.blocks
      blocks[0] = .markdown(id: "part-0", source: "# Human continuation")
      let changed = document.replaceContent(blocks: blocks, actor: UUID())
      #expect(changed)
      _ = try store.saveMergedDocument(document)
      let content = try store.collaborationContent(), files = try content.sourceFiles()
      let model = try store.actionReadModel(receipt.id)
      #expect(try model.continuations(in: files) == receipt.continuations(in: files))
      #expect(try !model.continuations(in: files).isEmpty)
      #expect(try store.actionContinuations(model) == receipt.continuations(in: files))
      let snapshot = try CollaborationReadSnapshot(store: store, actions: [model], references: [])
      #expect(snapshot.continuations[model.id] == receipt.continuations(in: files))
      #expect(snapshot.results[model.id] == receipt.resultReferences(in: content))
      #expect(model.resultReferences(in: content) == receipt.resultReferences(in: content))
    }
  }

  @Test func schemaAdmissionRebuildsOnlyDerivedDescriptionsAndPreservesAcceptedRecords() throws {
    try fixture { store, _, receipt, _ in
      let cursor = try store.currentChangeCursor(), workspaceID = try store.workspaceHeader().workspaceID
      let readCursor = try store.currentReadCursor()
      let hashes = try store.readTransaction { _ in
        try store.currentSQL!.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] }
      }
      let version = try receipt.deliveryVersion()
      try store.commandTransaction(advancesReadRevision: false) {
        try store.currentSQL!.run("DROP TABLE action_read_models")
        try store.currentSQL!.run("PRAGMA user_version=3")
      }
      let reopened = NotebookStore(root: store.root)
      try reopened.prepare()
      #expect(try reopened.actionReadModel(receipt.id).actionVersion == version)
      #expect(try reopened.currentChangeCursor() == cursor)
      #expect(try reopened.currentReadCursor() == readCursor)
      #expect(try reopened.workspaceHeader().workspaceID == workspaceID)
      let after = try reopened.readTransaction { _ in
        try reopened.currentSQL!.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] }
      }
      #expect(hashes == after)
    }
  }

  @Test func staleDescriptionCannotPublishDeliveryOrMasqueradeAsAnAbsentAction() throws {
    try fixture { store, _, receipt, _ in
      try store.commandTransaction(advancesReadRevision: false) {
        try store.currentSQL!.run("UPDATE action_read_models SET receipt_hash=? WHERE address=?", [
          .text(String(repeating: "0", count: 64)),
          .text("collaboration/actions/" + receipt.id.uuidString.lowercased() + ".json#")])
      }
      let cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.self) { _ = try store.actionReadModel(receipt.id) }
      #expect(throws: NotebookStorageError.self) { try store.acknowledgeReceivedActions(deviceID: UUID()) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.deviceActionReceipts(actionIDs: [receipt.id]).isEmpty)
    }
  }
}
