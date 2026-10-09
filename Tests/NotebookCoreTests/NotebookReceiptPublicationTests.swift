import Foundation
import Testing
@testable import NotebookCore

@Suite("Local receipt publication keeps the physical root authoritative", .serialized)
struct NotebookReceiptPublicationTests {
  private func receipt() -> CollaborationReceipt {
    let target = CollaborationTarget(kind: .document, id: UUID())
    let source = "Cafe\u{301}", key = "cafe\u{301}"
    let action = CollaborationAction(summary: "Literal source", expected: [], operations: [
      .init(kind: .patchDocumentFile, target: target, id: "source", values: [
        "source": .string(source), "expectedText": .string(source), key: .bool(true), "zero": .number(0)])])
    return .init(id: action.id, action: action, createdAt: Date(timeIntervalSinceReferenceDate: 0),
      revisions: [], changes: [.init(file: "documents/" + target.id.uuidString.lowercased() + ".json",
        path: [.field("files"), .member("source"), .field("source")], before: .string("Before"),
        after: .string(source))])
  }

  @Test(arguments: [-1, 0, 17, 1_000_000, 1_000_000_000_000, 1_000_000_000_000_000, Int(VersionStamp.maximumCounter)])
  func requiredCanonicalEncodingKeepsTheExactLegacyFrameAcrossScalarSpellings(index: Int) throws {
    let target = CollaborationTarget(kind: .document, id: UUID()), actor = UUID()
    let source = "Cafe\u{301}/</script>\n\"\\\0\u{2028}\u{2029}\u{1d11e}"
    let action = CollaborationAction(summary: "Literal framing", references: [
      .init(target: target, pageIndex: index, revision: "r")], expected: [], operations: [
        .init(kind: .patchDocumentFile, target: target, id: "source", values: [
          "source": .string(source), "expectedText": .string(source), "cafe\u{301}": .bool(true),
          "zero": .number(-0.0), "tiny": .number(Double.leastNonzeroMagnitude),
          "large": .number(Double.greatestFiniteMagnitude)])])
    var original = CollaborationReceipt(id: action.id, action: action,
      createdAt: .init(timeIntervalSinceReferenceDate: -0.125), revisions: [], changes: [
        .init(file: documentFile(target.id), path: [.field("files"), .member("source"), .field("source")],
          before: .string("Before"), after: .string(source))])
    original.changes[0].afterVersion = ContentFieldVersion(stamp: .init(counter: UInt64(abs(index)), actor: actor),
      human: true, observed: [actor.uuidString.lowercased(): UInt64(abs(index))]).retainingValue(.string(source))
    original.lifecycleInverse = .init(rootHash: String(repeating: "a", count: 64), recordCount: abs(index))
    let legacy = try collaborationHash(JSONValue.object(["domain": .string("notebook.action-delivery.v1"),
      "receipt": .encode(original)]))
    let publication = try NotebookReceiptPublication(original)
    let fragment = try #require(NotebookRecordCodec.encode(publication.value, file: publication.file).first)
    let root = try #require(publication.root(for: fragment, hash: String(repeating: "a", count: 64)))
    #expect(try root.deliveryVersion() == legacy)
    #expect(try NotebookActionReadModel(root) == NotebookActionReadModel(original))
    #expect(DocumentFile.sourcesAreEqual(try #require(publication.value["changes"]?.array.first?["after"]?.string), source))
  }

  @Test func requiredReceiptBufferRemovesTheDeliveryEncodeAndUndoKeepsValueFraming() throws {
    var original = receipt()
    original.lifecycleInverse = .init(rootHash: String(repeating: "a", count: 64), recordCount: 1)
    let legacy = try original.deliveryVersion()
    #if DEBUG
    let samples = NotebookPublicationCodecSamples()
    try NotebookPublicationCodecObservation.withObserver(samples.record) {
      let publication = try NotebookReceiptPublication(original)
      let fragment = try #require(NotebookRecordCodec.encode(publication.value, file: publication.file).first)
      let root = try #require(publication.root(for: fragment, hash: String(repeating: "a", count: 64)))
      #expect(try root.deliveryVersion() == legacy)
    }
    let encoded = samples.snapshot()
    #expect(encoded.receiptEncode.passes == 1 && encoded.documentSourceDigest.passes == 1)
    #expect(encoded.deliveryEncode.passes == 0)

    var undone = original
    undone.undo = .init(restored: 1, preserved: [], completedAt: .init(timeIntervalSinceReferenceDate: 1))
    let undoVersion = try undone.deliveryVersion(), undoSamples = NotebookPublicationCodecSamples()
    try NotebookPublicationCodecObservation.withObserver(undoSamples.record) {
      let publication = try NotebookReceiptPublication(undone)
      let fragment = try #require(NotebookRecordCodec.encode(publication.value, file: publication.file).first)
      let root = try #require(publication.root(for: fragment, hash: String(repeating: "a", count: 64)))
      #expect(try root.deliveryVersion() == undoVersion)
    }
    #expect(undoSamples.snapshot().deliveryEncode.passes == 1)
    #expect(undoVersion != legacy)
    #endif
  }

  @Test func sourceDigestRequiresTheLiteralOriginalFieldAndUndoKeepsItsOwnDigest() throws {
    var original = receipt()
    let originalField = original.changes[0]
    original.changes[0] = .init(file: originalField.file,
      path: [.field("files"), .member("cafe\u{301}"), .field("source")],
      before: originalField.before, after: originalField.after)
    let publication: NotebookReceiptPublication
    #if DEBUG
    let samples = NotebookPublicationCodecSamples()
    publication = try NotebookPublicationCodecObservation.withObserver(samples.record) {
      let publication = try NotebookReceiptPublication(original)
      _ = try NotebookActionReadModel.Field(original.changes[0], sourceDigest: publication.sourceDigest)
      return publication
    }
    #expect(samples.snapshot().documentSourceDigest.passes == 1)
    #else
    publication = try NotebookReceiptPublication(original)
    #endif
    let digest = try #require(publication.sourceDigest), field = original.changes[0]
    #expect(digest.digest(for: field) == (try NotebookActionReadModel.Field.digest(field.after, file: field.file, path: field.path)))

    func changed(file: String? = nil, path: [CollaborationPathComponent]? = nil,
      after: JSONValue?) -> CollaborationFieldChange {
      .init(file: file ?? field.file, path: path ?? field.path, before: field.before, after: after,
        beforeVersion: field.beforeVersion, afterVersion: field.afterVersion)
    }
    var other = changed(after: .string("Caf\u{e9}"))
    #expect(other.after == field.after)
    #expect(digest.digest(for: other) == nil)
    #expect(try NotebookActionReadModel.Field(other, sourceDigest: digest).afterDigest == NotebookActionReadModel.Field.digest(other.after, file: other.file, path: other.path))
    other = changed(path: [.field("files"), .member("caf\u{e9}"), .field("source")], after: field.after)
    #expect(other.path == field.path)
    #expect(digest.digest(for: other) == nil)
    other = changed(file: documentFile(UUID()), after: field.after)
    #expect(digest.digest(for: other) == nil)
    other = changed(after: nil)
    #expect(digest.digest(for: other) == nil)

    original.undo = .init(restored: 1, preserved: [], completedAt: .init(timeIntervalSinceReferenceDate: 1))
    #expect(try NotebookReceiptPublication(original).sourceDigest == nil)
  }

  @Test func freshSourceDigestNeverBorrowsAPoisonedPersistedModel() throws {
    let f = try NotebookItemLifecycleTests.Fixture(), publication = try NotebookReceiptPublication(receipt())
    try f.store.publishRecords(writes: [publication.file: publication.value], receiptPublication: publication)
    let model = try f.store.actionReadModel(publication.receipt.id)
    let cursor = try f.store.currentChangeCursor(), read = try f.store.currentReadCursor()
    #expect(throws: NotebookStorageError.corruptRecord("frozen action model: " + publication.receipt.id.uuidString.lowercased())) {
      try f.store.commandTransaction {
        var value = try JSONValue.encode(model), fields = try #require(value["changes"]?.array)
        fields[0] = fields[0].setting("afterDigest", .string(String(repeating: "b", count: 64)))
        value = value.setting("changes", .array(fields))
        try f.store.currentSQL!.run("UPDATE action_read_models SET value=? WHERE address=?",
          [.blob(try NotebookStore.storageEncoder.encode(value)), .text(publication.file + "#")])
        try f.store.freezeActionResult(publication.receipt, changed: publication.receipt.changes, publication: publication)
      }
    }
    #expect(try f.store.actionReadModel(publication.receipt.id) == model)
    #expect(try f.store.savedActionResult(publication.receipt.id) == nil)
    #expect(try f.store.currentChangeCursor() == cursor && f.store.currentReadCursor() == read)

    let field = publication.receipt.changes[0]
    let actual = CollaborationFieldChange(file: field.file, path: field.path, before: field.before,
      after: .string("Actual different source"), beforeVersion: field.beforeVersion, afterVersion: field.afterVersion)
    try f.store.commandTransaction {
      try f.store.freezeActionResult(publication.receipt, changed: [actual], publication: publication)
    }
    let result = try #require(try f.store.savedActionResult(publication.receipt.id))
    let changed = try #require(result["changed"]?.array.first)
    #expect(changed["afterDigest"] == (try NotebookActionReadModel.Field.digest(actual.after, file: actual.file, path: actual.path)).map(JSONValue.string))
  }

  @Test func reuseRequiresTheLiteralWholeRootAndLosslessTypedMetadata() throws {
    let publication = try NotebookReceiptPublication(receipt())
    let fragment = try #require(NotebookRecordCodec.encode(publication.value, file: publication.file).first)
    let hash = String(repeating: "a", count: 64)
    let root = try #require(publication.root(for: fragment, hash: hash))
    #expect(try NotebookActionReadModel(root) == NotebookActionReadModel(publication.receipt))

    let action = try #require(publication.value["action"])
    let operation = try #require(action["operations"]?.array.first)
    let values = try #require(operation["values"]?.object)
    func replacingValues(_ values: [String: JSONValue]) -> JSONValue {
      publication.value.setting("action", action.setting("operations", .array([
        operation.setting("values", .object(values))])))
    }
    for field in ["source", "expectedText"] {
      var changed = values; changed[field] = .string("Caf\u{e9}")
      let value = replacingValues(changed)
      #expect(value == publication.value)
      #expect(publication.root(for: fragment.replacing(value: value), hash: hash) == nil)
    }
    var changedKey = values
    changedKey.removeValue(forKey: "cafe\u{301}"); changedKey["caf\u{e9}"] = .bool(true)
    let keyValue = replacingValues(changedKey)
    #expect(keyValue == publication.value)
    #expect(publication.root(for: fragment.replacing(value: keyValue), hash: hash) == nil)
    var signedZero = values; signedZero["zero"] = .number(-0.0)
    let zeroValue = replacingValues(signedZero)
    #expect(zeroValue == publication.value)
    #expect(publication.root(for: fragment.replacing(value: zeroValue), hash: hash) == nil)
    #expect(publication.root(for: fragment.replacing(value: publication.value.setting("unknown", .bool(true))), hash: hash) == nil)

    var lossyClock = publication.receipt
    lossyClock.changes[0].afterVersion = .init(stamp: .init(counter: VersionStamp.maximumCounter + 2, actor: UUID()), human: true)
    let lossyPublication = try NotebookReceiptPublication(lossyClock)
    let lossyFragment = try #require(NotebookRecordCodec.encode(lossyPublication.value, file: lossyPublication.file).first)
    #expect(lossyPublication.root(for: lossyFragment, hash: hash) == nil)
  }

  @Test func rawSplitRootsKeepTheirEnvelopeAndAHashMismatchRollsBackTheWriter() throws {
    let f = try NotebookItemLifecycleTests.Fixture()
    let publication = try NotebookReceiptPublication(receipt())
    try f.store.publishRecords(writes: [publication.file: publication.value], receiptPublication: publication)
    let model = try f.store.actionReadModel(publication.receipt.id)
    #expect(model == (try NotebookActionReadModel(publication.receipt)))
    let fragment = try #require(NotebookRecordCodec.encode(publication.value, file: publication.file).first)
    let wrongRoot = try #require(publication.root(for: fragment, hash: String(repeating: "0", count: 64)))
    let page = try f.store.loadPage(f.pageID), cursor = try f.store.currentChangeCursor()
    #expect(throws: NotebookStorageError.self) {
      try f.store.commandTransaction {
        try f.write(f.pageID, text: "This write must roll back with the receipt binding")
        try f.store.indexActionReadModel(publication.receipt, address: wrongRoot.address,
          database: f.store.currentSQL!, receiptRoot: wrongRoot)
      }
    }
    #expect(try f.store.loadPage(f.pageID) == page)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.actionReadModel(publication.receipt.id) == model)

    let raw = publication.value.setting("extension", .object(["label": .string("Keep this envelope"),
      "files": .array([.object(["id": .string("unknown"), "source": .string("Unknown authored data")])])]))
    let split = try NotebookRecordCodec.encode(raw, file: publication.file)
    let splitRoot = try #require(split.first { $0.parent == nil })
    #expect(!splitRoot.collections.isEmpty)
    #expect(publication.root(for: splitRoot, hash: String(repeating: "a", count: 64)) == nil)
    try f.store.publishRecords(writes: [publication.file: raw], receiptPublication: publication)
    #expect(try f.store.storedValue(publication.file) == raw)
    #expect(try f.store.actionReadModel(publication.receipt.id) == model)
    let splitCursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    #expect(throws: DecodingError.self) {
      try f.store.commandTransaction {
        try f.write(f.pageID, text: "This write must roll back with malformed raw metadata")
        try f.store.publishRecords(writes: [publication.file: raw.setting("createdAt", .string("invalid date"))],
          receiptPublication: publication)
      }
    }
    #expect(try f.store.storedValue(publication.file) == raw)
    #expect(try f.store.loadPage(f.pageID) == page)
    #expect(try f.store.currentChangeCursor() == splitCursor)
    #expect(try f.store.currentReadCursor() == readCursor)
    #expect(try f.store.actionReadModel(publication.receipt.id) == model)
    #expect(try f.store.readTransaction { store in
      let row = try #require(store.currentSQL!.rows("SELECT r.hash,m.receipt_hash FROM records r JOIN action_read_models m ON m.address=r.address WHERE r.address=?",
        [.text(publication.file + "#")]).first)
      return row[0].text == row[1].text
    })
  }

  @Test(arguments: [9_007_199_254_740_993, Int.max])
  func realRenamePreservesTheExistingIntegerDecodeAndOverflowRollback(pageIndex: Int) throws {
    let f = try NotebookItemLifecycleTests.Fixture(), header = try f.store.workspaceHeader()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let context = try f.store.appendContext(references: [], author: .human, actor: f.actor, text: "Existing context")
    let basis = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    let title = try #require(try f.store.readItemHeader(f.itemID)?.title)
    let cursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    let action = CollaborationAction(contextID: context.id, summary: "Rename with a retained reference",
      references: [.init(target: board, pageIndex: pageIndex, revision: basis.owners[0].revision)],
      expected: basis.owners, operations: [.init(kind: .renameItem, target: board, id: f.itemID.uuidString,
        values: ["title": .string("Renamed")])])
    if pageIndex == Int.max {
      #expect(throws: DecodingError.self) { _ = try f.store.applyCollaborationAction(action, actor: f.actor) }
    } else {
      // The old decoder rounds the reference. The frozen-result owner then
      // refuses the mismatch with this original request and rolls back.
      #expect(throws: NotebookStorageError.self) { _ = try f.store.applyCollaborationAction(action, actor: f.actor) }
    }
    #expect(try f.store.readItemHeader(f.itemID)?.title == title)
    #expect(try f.store.actionReadModelIfPresent(action.id) == nil)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.currentReadCursor() == readCursor)
  }
}
