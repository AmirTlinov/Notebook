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
