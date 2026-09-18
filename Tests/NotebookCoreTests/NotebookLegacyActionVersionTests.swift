import Foundation
import Testing
@testable import NotebookCore

@Suite("Legacy action history exact-version continuation", .serialized)
struct NotebookLegacyActionVersionTests {
  private final class Fixture {
    let source: NotebookObservationReadTests.Fixture
    let receipt: CollaborationReceipt
    var file: String { "collaboration/actions/" + receipt.id.uuidString.lowercased() + ".json" }

    init() throws {
      let source = try NotebookObservationReadTests.Fixture()
      self.source = source
      let operations = (0..<40).map { index in
        CollaborationOperation(kind: .updateElement, target: source.target, id: "node-\(index)",
          values: ["source": .string("Historical source \(index)")])
      }
      let action = CollaborationAction(summary: "Accepted before SDK v2", expected: [], operations: operations)
      receipt = CollaborationReceipt(id: action.id, action: action, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        revisions: [], changes: (0..<40).map { index in
          .init(file: pageFile(source.pageID), path: [.field("elements"), .member("node-\(index)"), .field("source")],
            before: .string("Earlier source \(index)"), after: .string("Historical source \(index)"))
        })
      // A genuine legacy persisted shape: only the accepted receipt. No v2
      // action-result files are created, removed, or synthesized by this fixture.
      try source.store.publishCollaboration(writes: [file: try .encode(receipt)])
    }

    func reopened() throws -> NotebookStore {
      let store = NotebookStore(root: source.store.root)
      try store.prepare()
      return store
    }

    func read(_ store: NotebookStore, version: String? = nil,
      section: NotebookActionDetailsPage.Section? = nil, offset: Int = 0) throws -> JSONValue {
      var command = NotebookCommand(command: .actionDetails)
      command.actionID = receipt.id; command.readSnapshots = true
      if section != nil || version != nil {
        var page = NotebookActionDetailsPage(section: section, offset: offset)
        page.actionVersion = version; command.actionPage = page
      }
      return try #require(NotebookCommandDispatcher(store: store).handle(command)["data"])
    }

    func hashes(_ store: NotebookStore) throws -> [[String]] {
      try store.readTransaction { _ in
        try store.currentSQL!.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] }
      }
    }
  }

  @Test func summaryContinuesBothLegacySectionsAfterReopenWithoutCreatingV2Results() throws {
    let f = try Fixture(), store = try f.reopened()
    #expect(try store.savedActionResult(f.receipt.id) == nil)
    let summary = try f.read(store)
    let version = try #require(summary["actionVersion"]?.string)
    #expect(version == (try f.receipt.deliveryVersion()))
    #expect(summary["receipt"]?["action"]?["operations"]?.array.count == 32)
    #expect(summary["receipt"]?["changes"]?.array.count == 32)
    #expect(summary["pages"]?["operations"]?["nextOffset"] == .number(32))
    #expect(summary["pages"]?["changes"]?["nextOffset"] == .number(32))

    // Current content may change, but receipt sections must not acquire fresh
    // source values or replay the historical operation to reconstruct results.
    try f.source.put("node-39", source: "LATEST HUMAN BODY")
    let reopened = try f.reopened(), hashes = try f.hashes(reopened)
    let cursor = try reopened.currentChangeCursor(), readCursor = try reopened.currentReadCursor()
    let operations = try f.read(reopened, version: version, section: .operations, offset: 32)
    #expect(operations["actionVersion"] == .string(version))
    #expect(operations["page"]?["items"]?.array.compactMap { $0["id"]?.string } == (32..<40).map { "node-\($0)" })
    #expect(operations["page"]?["nextOffset"] == .null)
    let changes = try f.read(reopened, version: version, section: .changes, offset: 32)
    #expect(changes["page"]?["items"]?.array.count == 8)
    #expect(changes["page"]?["items"]?.array.first?["path"] == (try .encode(f.receipt.changes[32].path)))
    #expect(changes["page"]?["nextOffset"] == .null)
    let encoded = try String(decoding: JSONEncoder().encode([operations, changes]), as: UTF8.self)
    #expect(!encoded.contains("LATEST HUMAN BODY") && !encoded.contains("Historical source"))
    #expect(try reopened.readPageElement(pageID: f.source.pageID, elementID: "node-39")?.source == "LATEST HUMAN BODY")
    #expect(try reopened.savedActionResult(f.receipt.id, version: version) == nil)
    #expect(try f.hashes(reopened) == hashes)
    #expect(try reopened.currentChangeCursor() == cursor)
    #expect(try reopened.currentReadCursor() == readCursor)
  }

  @Test func changedLegacyReceiptNeverSubstitutesItsCurrentVersionForAnEarlierCut() throws {
    let f = try Fixture(), store = try f.reopened()
    let version = try #require(f.read(store)["actionVersion"]?.string)
    var completed = f.receipt
    completed.undo = .init(restored: 0, preserved: completed.changes, completedAt: Date(timeIntervalSince1970: 1_700_000_100))
    try store.publishCollaboration(writes: [f.file: try .encode(completed)])
    let reopened = try f.reopened(), hashes = try f.hashes(reopened)
    do {
      _ = try f.read(reopened, version: version, section: .changes, offset: 32)
      Issue.record("An unavailable historical receipt version must not use the latest model")
    } catch let error as CollaborationError { #expect(error.code == "action_version_unavailable") }
    let current = try #require(f.read(reopened)["actionVersion"]?.string)
    #expect(current != version)
    let page = try f.read(reopened, version: current, section: .undo, offset: 32)
    #expect(page["page"]?["items"]?.array.count == 8)
    #expect(page["actionVersion"] == .string(current))
    #expect(try f.hashes(reopened) == hashes)
  }

  @Test func fallbackRequiresTheExistingReceiptHashBoundReadModel() throws {
    let f = try Fixture(), store = try f.reopened(), version = try f.receipt.deliveryVersion()
    try store.commandTransaction(advancesReadRevision: false) {
      try store.currentSQL!.run("UPDATE action_read_models SET receipt_hash=? WHERE address=?",
        [.text(String(repeating: "0", count: 64)), .text(f.file + "#")])
    }
    #expect(throws: NotebookStorageError.self) { _ = try store.actionVersionModel(f.receipt.id, version: version) }
  }
}
