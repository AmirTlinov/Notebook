import Foundation
import Testing
@testable import NotebookCore

@Suite("Large action history does not reload its source or inverse", .serialized)
struct NotebookActionReadModelTests {
  private final class DeliverySamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(UUID?, Int)] = []
    func record(_ id: UUID?, bytes: Int) { lock.lock(); defer { lock.unlock() }; samples.append((id, bytes)) }
    func passes(for id: UUID) -> Int { lock.lock(); defer { lock.unlock() }; return samples.filter { $0.0 == id }.count }
    func bytes(for id: UUID) -> Int {
      lock.lock(); defer { lock.unlock() }; return samples.reduce(0) { $0 + ($1.0 == id ? $1.1 : 0) }
    }
  }

  private func fixture(_ body: (NotebookStore, UUID, CollaborationReceipt, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("action-read-model-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), documentID = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let files = (0..<140).map { DocumentFile(id: "part-\($0)", path: "part-\($0).tex",
      source: "# Chapter \($0)\n\n" + String(repeating: "Large source. ", count: 3_800)) }
    let receipt = try store.applyCollaborationAction(.init(summary: "A large document", expected: [
      .init(target: board, revision: store.targetContentRevision(target: board)),
      .init(target: .init(kind: .workspace, id: header.rootBoardID), revision: store.workspaceHeader().stamp.revision)
    ], operations: [.init(kind: .createDocument, target: board, id: documentID.uuidString, values: [
      "title": .string("Large control"), "center": try .encode(WorldPoint.zero),
      "files": try .encode(files)])]), actor: actor)
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
      var editedFiles = document.files
      editedFiles[0] = .init(id: "part-0", path: "part-0.tex", source: "# Human continuation")
      let changed = document.replaceContent(files: editedFiles, actor: UUID())
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
        let database = store.currentSQL!
        try database.run("DROP TABLE action_read_models")
        // A pre-recipe database has neither the recipe guards nor its marker.
        // Keep authored records intact while reproducing that derived schema.
        for event in ["insert", "update", "delete"] {
          try database.run("DROP TRIGGER search_recipe_" + event)
        }
        try database.run("DELETE FROM metadata WHERE key='search_recipe'")
        try database.run("PRAGMA user_version=3")
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

  @Test(arguments: ["missingRoot", "missingModel", "staleHash", "malformedModel", "invalidVersion",
    "author", "fingerprint", "revisions", "phase", "parentAllowance"])
  func frozenResultRefusesAnUnboundModelAndRollsBackItsWholeWriterCut(fault: String) throws {
    let f = try NotebookItemLifecycleTests.Fixture()
    try f.write(f.pageID, text: "Before")
    let target = CollaborationTarget(kind: .page, id: f.pageID)
    let basis = try f.store.readBasis(targets: [target])
    let action = CollaborationAction(summary: "Bound frozen result", expected: basis.owners,
      operations: [.init(kind: .updateElement, target: target, id: "label",
        values: ["source": .string("Accepted source"), "html": .string("")])])
    let receipt = try f.store.applyNativeAction(action, actor: f.actor,
      requestFingerprint: String(repeating: "a", count: 64))
    #expect(receipt.author == .human)
    let model = try f.store.actionReadModel(receipt.id), result = try #require(try f.store.savedActionResult(receipt.id))
    let cursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    let page = try f.store.loadPage(f.pageID)
    let hashes = try f.store.readTransaction { store in
      try store.currentSQL!.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] }
    }
    let address = "collaboration/actions/" + receipt.id.uuidString.lowercased() + ".json#"
    do {
      try f.store.commandTransaction {
        try f.write(f.pageID, text: "This content must roll back with frozen evidence")
        let database = f.store.currentSQL!
        switch fault {
        case "missingRoot": try database.run("DELETE FROM records WHERE address=?", [.text(address)])
        case "missingModel": try database.run("DELETE FROM action_read_models WHERE address=?", [.text(address)])
        case "staleHash": try database.run("UPDATE action_read_models SET receipt_hash=? WHERE address=?",
          [.text(String(repeating: "0", count: 64)), .text(address)])
        case "malformedModel": try database.run("UPDATE action_read_models SET value=? WHERE address=?",
          [.blob(Data("not JSON".utf8)), .text(address)])
        case "parentAllowance":
          try database.limitReads(.init(rows: 0, bytes: 0, valueBytes: 0, reason: "frozen_result_parent"))
        default:
          var value = try JSONValue.encode(model)
          switch fault {
          case "invalidVersion": value = value.setting("actionVersion", .string("not a digest"))
          case "author": value = value.setting("author", .string("agent"))
          case "fingerprint": value = value.setting("requestFingerprint", .string(String(repeating: "b", count: 64)))
          case "revisions": value = value.setting("revisions", .array([]))
          case "phase": value = value.setting("undo", .object(["restored": .number(0),
            "preserved": .array([]), "completedAt": .number(0)]))
          default: Issue.record("Unexpected model fault"); throw CancellationError()
          }
          try database.run("UPDATE action_read_models SET value=? WHERE address=?",
            [.blob(try NotebookStore.storageEncoder.encode(value)), .text(address)])
        }
        try f.store.freezeActionResult(receipt, changed: receipt.changes)
      }
      Issue.record("Frozen evidence must refuse even when its prior result already exists")
    } catch let error as NotebookStorageError {
      if fault == "parentAllowance" { #expect(error == .limitExceeded("frozen_result_parent")) }
      else if case .corruptRecord = error {} else { Issue.record("Expected an unavailable/corrupt indexed model, got \(error)") }
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.currentReadCursor() == readCursor)
    #expect(try f.store.loadPage(f.pageID) == page)
    #expect(try f.store.actionReadModel(receipt.id) == model)
    #expect(try f.store.savedActionResult(receipt.id) == result)
    let after = try f.store.readTransaction { store in
      try store.currentSQL!.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] }
    }
    #expect(after == hashes)
  }

  @Test(arguments: [String(repeating: "東", count: 682), String(repeating: "東", count: 683), String(repeating: "\0", count: 400)])
  func frozenResultKeepsTheExactOmissionBoundaryAndDigestsActualUndo(source: String) throws {
    let f = try NotebookItemLifecycleTests.Fixture(), beforeSource = "Before"
    try f.write(f.pageID, text: beforeSource)
    let target = CollaborationTarget(kind: .page, id: f.pageID)
    let basis = try f.store.readBasis(targets: [target])
    let action = CollaborationAction(summary: "Actual frozen source", expected: basis.owners,
      operations: [.init(kind: .updateElement, target: target, id: "label",
        values: ["source": .string(source), "html": .string("")])])
    let receipt: CollaborationReceipt
    #if DEBUG
    let samples = DeliverySamples()
    receipt = try NotebookActionDeliveryObservation.withObserver({ samples.record($0.actionID, bytes: $0.framedBytes) }) {
      try f.store.applyNativeAction(action, actor: f.actor)
    }
    #expect(samples.passes(for: action.id) == 1)
    let framed = JSONValue.object(["domain": .string("notebook.action-delivery.v1"), "receipt": try .encode(receipt)])
    #expect(samples.bytes(for: action.id) == (try NotebookStore.storageEncoder.encode(framed).count))
    #else
    receipt = try f.store.applyNativeAction(action, actor: f.actor)
    #endif
    let original = try #require(try f.store.savedActionResult(receipt.id))
    let field = try #require(receipt.changes.first { $0.path.last == .field("source") })
    let changed = try #require(original["changed"]?.array.first { $0["path"] == (try? JSONValue.encode(field.path)) })
    let bytes = try NotebookStore.storageEncoder.encode(JSONValue.string(source)).count
    #expect((changed["value"] == .string(source)) == (bytes <= 2048))
    #expect((changed["valueOmitted"] == .bool(true)) == (bytes > 2048))
    let undone = try f.store.undoNativeAction(receipt.id, actor: f.actor)
    let model = try f.store.actionReadModel(receipt.id)
    let result = try #require(try f.store.savedActionResult(receipt.id, version: model.actionVersion))
    let inverse = try #require(result["changed"]?.array.first { $0["path"] == (try? JSONValue.encode(field.path)) })
    let restoredDigest = try NotebookActionReadModel.Field.digest(.string(beforeSource), file: field.file, path: field.path)
    let originalDigest = try #require(model.changes.first { $0.file == field.file && $0.path == field.path }).afterDigest
    #expect(inverse["value"] == .string(beforeSource))
    #expect(inverse["afterDigest"] == restoredDigest.map(JSONValue.string))
    #expect(restoredDigest != originalDigest)
    #expect(undone.undo != nil && result["actionVersion"] != original["actionVersion"])
    #expect(try f.store.savedActionResult(receipt.id) == original)
  }
}
