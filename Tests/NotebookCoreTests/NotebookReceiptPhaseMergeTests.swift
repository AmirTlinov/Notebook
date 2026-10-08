import CryptoKit
import Foundation
import Testing
@testable import NotebookCore

@Suite("Receipt phases preserve one exact original and one completed Undo", .serialized)
struct NotebookReceiptPhaseMergeTests {
  private struct Model: Equatable {
    let address: String, hash: String
    let arrival: String?
    let value: Data
  }
  private struct State: Equatable {
    let records: [[String]]
    let models: [Model]
    let received: [[String]]
    let change: UInt64, read: UInt64, incoming: UInt64
  }
  private struct Fixture {
    let root: URL
    let origin: NotebookStore, replica: NotebookStore
    let actor: UUID, device: UUID, itemID: UUID
    let page: CollaborationTarget, board: CollaborationTarget, workspace: CollaborationTarget
    let source: NotebookReplicationSource
    let original: CollaborationReceipt
    let future: JSONValue?

    init(unknown: Bool = false) throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-phase-" + UUID().uuidString)
      origin = NotebookStore(root: root.appendingPathComponent("origin"))
      replica = NotebookStore(root: root.appendingPathComponent("replica"))
      actor = UUID(); device = UUID(); source = .init(deviceID: actor, generation: actor)
      let index = try origin.loadOrCreate(actor: actor, pageSize: .init(width: 400, height: 600)).0
      _ = try origin.loadOrCreateSpatialInk(actor: actor)
      itemID = index.selectedItemID
      page = .init(kind: .page, id: try #require(index.selectedPageID))
      board = .init(kind: .board, id: index.rootBoardID)
      workspace = .init(kind: .workspace, id: index.rootBoardID)
      let action = try CollaborationAction(summary: "Original authored element", expected: [
        .init(target: page, revision: origin.targetContentRevision(target: page))], operations: [
        .init(kind: .insertElement, target: page, id: "original", values: ["kind": .string("web"),
          "source": .string("Original"), "html": .string("<p>Original</p>"),
          "frame": .object(["x": .number(20), "y": .number(30), "width": .number(100), "height": .number(80)])])])
      future = unknown ? .object(["measurement": .number(0), "records": .array([
        .object(["id": .string("future-child"), "authored": .string("Retained unknown body")])])]) : nil
      let store = origin, author = actor, authoredFuture = future
      original = try store.commandTransaction {
        let receipt = try store.applyCollaborationAction(action, actor: author)
        if let authoredFuture {
          let file = "collaboration/actions/" + receipt.id.uuidString.lowercased() + ".json"
          try store.publishRecords(writes: [file: .encode(receipt).setting("future", authoredFuture)])
        }
        return receipt
      }
      try replica.prepareEmptyWorkspace(workspaceID: origin.storedWorkspaceID())
      try deliverNew()
      _ = try replica.acknowledgeReceivedActions(deviceID: device)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
    func file(_ id: UUID) -> String { "collaboration/actions/" + id.uuidString.lowercased() + ".json" }
    func raw(_ store: NotebookStore) throws -> JSONValue { try #require(try store.storedValue(file(original.id))) }
    func deliverNew() throws {
      let cursor = try replica.incomingCursor(source: source)
      for change in try origin.changeJournal(after: cursor) {
        try receiveFixtureChanges(.init(source: source, change: change), from: origin, to: replica)
      }
    }
    func stage(_ change: NotebookDurableChange) throws {
      while true {
        let missing = try replica.missingBlobHashes(for: change)
        if missing.isEmpty { return }
        for hash in missing {
          let size = try origin.blobSize(hash: hash)
          var data = Data()
          while Int64(data.count) < size {
            data += try origin.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
          }
          try replica.stageBlob(data: data, expectedHash: hash)
        }
      }
    }
    func undoAndDeliver() throws -> CollaborationReceipt {
      let receipt = try origin.commandTransaction {
        let receipt = try origin.undoCollaborationAction(original.id, actor: actor)
        if let future {
          let value = try JSONValue.encode(receipt).setting("future", future)
          let undo = try #require(value["undo"]).setting("futureProof", .string("Exact first Undo witness"))
          try origin.publishRecords(writes: [file(original.id): value.setting("undo", undo)])
        }
        return receipt
      }
      try deliverNew()
      _ = try replica.acknowledgeReceivedActions(deviceID: device)
      return receipt
    }
    func packet(_ value: JSONValue) throws -> NotebookReplicationDelivery {
      let cursor = try origin.currentChangeCursor()
      try origin.commandTransaction {
        let action = try CollaborationAction(summary: "Material before conflicting receipt", expected: [
          .init(target: workspace, revision: origin.targetContentRevision(target: workspace)),
          .init(target: board, revision: origin.targetContentRevision(target: board))], operations: [
          .init(kind: .renameItem, target: board, id: itemID.uuidString, values: ["title": .string("Incoming rename")])])
        _ = try origin.applyCollaborationAction(action, actor: actor)
        try origin.publishRecords(writes: [file(original.id): value])
      }
      let change = try #require(origin.changeJournal(after: cursor).first)
      try stage(change)
      return .init(source: source, change: change)
    }
    func packetWithInvalidReceiptIdentity(_ value: JSONValue) throws -> NotebookReplicationDelivery {
      // Preserve a genuine material transaction. The sender's content writer
      // correctly rejects a misplaced receipt, so authenticate that malformed
      // transport fragment without publishing it into the sender's records.
      let delivery = try packet(raw(origin))
      let originalManifest = try origin.readTransaction { _ in try origin.validatedManifest(delivery.change) }
      try #require(originalManifest.parts.isEmpty)
      let receiptFile = file(original.id)
      var records = originalManifest.records.filter { !$0.address.hasPrefix(receiptFile + "#") }
      for fragment in try NotebookRecordCodec.encode(value, file: receiptFile) {
        let data = try NotebookStore.storageEncoder.encode(fragment)
        let hash = NotebookHexEncoding.encode(SHA256.hash(data: data))
        try replica.stageBlob(data: data, expectedHash: hash)
        records.append(.init(address: fragment.address, blobHash: hash))
      }
      let transactionID = UUID()
      let manifest = NotebookChangeManifest(transactionID: transactionID, workspaceID: originalManifest.workspaceID,
        records: records, pageOrderRoots: originalManifest.pageOrderRoots)
      let data = try NotebookStore.storageEncoder.encode(manifest)
      let hash = NotebookHexEncoding.encode(SHA256.hash(data: data))
      try replica.stageBlob(data: data, expectedHash: hash)
      return .init(source: source, change: .init(sequence: delivery.change.sequence,
        transactionID: transactionID, manifestHash: hash, byteCount: data.count))
    }
    func state(_ store: NotebookStore) throws -> State {
      try store.readTransaction { _ in
        let database = try #require(store.currentSQL)
        let records = try database.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] }
        let models = try database.rows("SELECT address,receipt_hash,arrival_receipt_hash,value FROM action_read_models ORDER BY address")
          .map { Model(address: $0[0].text!, hash: $0[1].text!, arrival: $0[2].text, value: $0[3].blob!) }
        let received = try database.rows("SELECT transaction_id,manifest_hash,peer_id,sequence FROM received_transactions ORDER BY transaction_id")
          .map { [$0[0].text!, $0[1].text!, $0[2].text!, String($0[3].integer!)] }
        return .init(records: records, models: models, received: received,
          change: try store.currentChangeCursor(), read: try store.currentReadCursor(), incoming: try store.incomingCursor(source: source))
      }
    }
  }

  @Test(arguments: ["createdAt", "changes", "fingerprint", "author", "revisions"])
  func originalFieldsCannotBeReplacedInHeldOrDiskMerge(field: String) throws {
    let f = try Fixture(); defer { f.clean() }
    var value = try JSONValue.encode(f.original)
    switch field {
    case "createdAt": value = value.setting("createdAt", .number(f.original.createdAt.timeIntervalSinceReferenceDate + 1))
    case "changes": value = value.setting("changes", .array([]))
    case "fingerprint": value = value.setting("requestFingerprint", .string(String(repeating: "a", count: 64)))
    case "author": value = value.setting("author", .string("human"))
    default: value = value.setting("revisions", try .encode([CollaborationExpectation(target: f.page, revision: "changed-cut")]))
    }
    let changed = try value.decode(CollaborationReceipt.self), before = try f.state(f.origin)
    #expect(throws: CollaborationError.self) { try CollaborationEnvelope(actions: [f.original]).merging(.init(actions: [changed])) }
    #expect(throws: CollaborationError.self) { try f.origin.mergeCollaborationContent(nil, actions: [changed]) }
    #expect(try f.state(f.origin) == before)
    #expect(try f.origin.collaborationAction(f.original.id) == f.original)
  }

  @Test(arguments: ["restored", "preserved", "completedAt", "restorations", "redoGates", "dependencies", "revisions"])
  func completedUndoCannotSelectADivergentCut(field: String) throws {
    let f = try Fixture(); defer { f.clean() }
    let saved = try f.undoAndDeliver()
    var value = try JSONValue.encode(saved), undo = try #require(value["undo"])
    switch field {
    case "restored": undo = undo.setting("restored", .number(Double(try #require(saved.undo).restored + 1)))
    case "preserved": undo = undo.setting("preserved", try .encode(f.original.changes))
    case "completedAt": undo = undo.setting("completedAt", .number(try #require(saved.undo).completedAt.timeIntervalSinceReferenceDate + 1))
    case "restorations", "redoGates": undo = undo.setting(field, .null)
    case "dependencies": undo = undo.setting("dependencies", try .encode([
      CollaborationPreservedDependency(file: pageFile(f.page.id), path: [.field("elements")], dependsOn: [.field("title")])]))
    default: value = value.setting("revisions", try .encode([CollaborationExpectation(target: f.page, revision: "changed-undo-cut")]))
    }
    value = value.setting("undo", undo)
    let changed = try value.decode(CollaborationReceipt.self), before = try f.state(f.origin)
    #expect(throws: CollaborationError.self) { try CollaborationEnvelope(actions: [saved]).merging(.init(actions: [changed])) }
    #expect(throws: CollaborationError.self) { try f.origin.mergeCollaborationContent(nil, actions: [changed]) }
    #expect(try f.state(f.origin) == before)
    #expect(try f.origin.collaborationAction(saved.id) == saved)
  }

  @Test(arguments: ["createdAt", "undo", "unknownOriginal", "unknownUndo", "signedZero", "receiptID"])
  func rawConflictsRollBackMaterialReceiptAndAcknowledgements(kind: String) throws {
    let f = try Fixture(unknown: kind == "unknownOriginal" || kind == "unknownUndo" || kind == "signedZero")
    defer { f.clean() }
    if kind == "undo" || kind == "unknownUndo" { _ = try f.undoAndDeliver() }
    let saved = try f.raw(f.origin)
    var value = saved
    switch kind {
    case "createdAt": value = value.setting("createdAt", .number(f.original.createdAt.timeIntervalSinceReferenceDate + 1))
    case "undo": value = value.setting("undo", try #require(value["undo"]).setting("completedAt", .number(1)))
    case "unknownOriginal": value = value.setting("future", try #require(value["future"]).setting("newAuthoredField", .string("Unproved replacement")))
    case "unknownUndo": value = value.setting("undo", try #require(value["undo"]).setting("futureProof", .string("Different Undo witness")))
    case "signedZero":
      value = value.setting("future", try #require(value["future"]).setting("measurement", .number(-0.0)))
      #expect(value == saved, "Ordinary Double equality hides the bit change")
      #expect(try collaborationHash(value) != collaborationHash(saved))
      let encoded = try NotebookStore.storageEncoder.encode(value)
      let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
      let number = try #require(decoded["future"]?["measurement"])
      guard case .number(let signedZero) = number else { Issue.record("Missing signed zero"); return }
      #expect(signedZero.bitPattern == (-0.0 as Double).bitPattern)
    default:
      let id = UUID().uuidString
      value = value.setting("id", .string(id)).setting("action", try #require(value["action"]).setting("id", .string(id)))
        .setting("lifecycleInverse", nil)
    }
    let delivery = try kind == "receiptID" ? f.packetWithInvalidReceiptIdentity(value) : f.packet(value)
    let before = try f.state(f.replica)
    #expect(try f.origin.readItemHeader(f.itemID)?.title == "Incoming rename")
    if kind == "receiptID" {
      // Identity discovery refuses before any material owner is applied.
      #expect(throws: NotebookStorageError.invalidTransaction("inverse receipt identity")) { try f.replica.applyDelivery(delivery) }
    } else {
      #expect(throws: NotebookStorageError.transactionConflict) { try f.replica.applyDelivery(delivery) }
    }
    #expect(try f.state(f.replica) == before)
    #expect(try f.replica.deliveryNeedsContent(delivery))
    let drain = try f.replica.acknowledgeReceivedActions(deviceID: f.device)
    #expect(drain.processed == 0 && drain.published == 0 && !drain.hasMore)
    #expect(try f.state(f.replica) == before)
    #expect(try f.raw(f.replica) == saved)
  }

  @Test func rawSelectedPhaseRetainsUnknownsAndLateOriginalDoesNotRewriteMaterial() throws {
    let f = try Fixture(unknown: true); defer { f.clean() }
    let born = try f.raw(f.origin)
    let undone = try f.undoAndDeliver(), selected = try f.raw(f.origin)
    #expect(try f.raw(f.replica) == selected)
    #expect(selected["future"] == born["future"])
    #expect(selected["undo"]?["futureProof"] == .string("Exact first Undo witness"))
    let before = try f.state(f.replica), cursor = try f.origin.currentChangeCursor()
    try f.origin.publishRecords(writes: [f.file(f.original.id): born])
    let change = try #require(f.origin.changeJournal(after: cursor).first)
    try f.stage(change)
    let delivery = NotebookReplicationDelivery(source: f.source, change: change)
    #expect(try f.replica.applyDelivery(delivery) == change.sequence)
    let accepted = try f.state(f.replica)
    #expect(accepted.records == before.records && accepted.models == before.models && accepted.change == before.change)
    #expect(accepted.read == before.read + 1 && accepted.incoming == change.sequence)
    #expect(try f.raw(f.replica) == selected)
    #expect(try f.replica.applyDelivery(delivery) == change.sequence)
    #expect(try f.state(f.replica) == accepted)
    let held = try CollaborationEnvelope(actions: [undone]).merging(.init(actions: [f.original]))
    #expect(held.actions == [undone])
  }

  @Test func damagedStoredReceiptIsNotTreatedAsAbsent() throws {
    let f = try Fixture(); defer { f.clean() }
    try f.origin.fixtureWrite(Data("unreadable receipt".utf8), to: f.origin.collaborationActionsURL.appendingPathComponent(f.original.id.uuidString.lowercased() + ".json"))
    let before = try f.state(f.origin)
    #expect(throws: (any Error).self) { try f.origin.mergeCollaborationContent(nil, actions: [f.original]) }
    #expect(try f.state(f.origin) == before)
    #expect(try f.origin.storedValue(f.file(f.original.id)) == .string("deliberately damaged typed owner"))
  }

  @Test func exactOriginalAndUndoReplaysKeepTheSameDiskCut() throws {
    let f = try Fixture(); defer { f.clean() }
    let born = try f.state(f.origin)
    _ = try f.origin.mergeCollaborationContent(nil, actions: [f.original])
    #expect(try f.state(f.origin) == born)
    let undone = try f.undoAndDeliver(), completed = try f.state(f.origin)
    _ = try f.origin.mergeCollaborationContent(nil, actions: [undone])
    _ = try f.origin.mergeCollaborationContent(nil, actions: [f.original])
    #expect(try f.state(f.origin) == completed)
    #expect(try f.origin.collaborationAction(f.original.id) == undone)
  }

  @Test func typedEncodingBorrowsAndLatchesOuterJSONCreditBeforeEncoding() throws {
    let f = try Fixture(); defer { f.clean() }
    let id = UUID(), action = CollaborationAction(id: id, summary: "Unaffordable encoding", expected: [], operations: [
      .init(kind: .setElementState, target: f.page, id: "original", values: ["state": .number(.nan)])])
    let invalid = CollaborationReceipt(id: id, action: action, createdAt: Date(), revisions: [], changes: [])
    let before = try f.state(f.origin)
    let allowance = NotebookSQLReadAllowance(rows: 1_000, bytes: 1_048_576, valueBytes: 1_048_576,
      reason: "phase_merge_budget", jsonDecodeBytes: 0)
    do {
      try f.origin.commandTransaction(readAllowance: allowance) {
        let database = try #require(f.origin.currentSQL)
        do {
          _ = try NotebookReceiptPhaseMerge.merging(invalid, into: nil as JSONValue?, database: database)
          Issue.record("Typed JSON was allocated without its outer allowance")
        } catch let error as NotebookStorageError {
          #expect(error == .limitExceeded("phase_merge_budget"))
        }
        try database.run("UPDATE metadata SET value='unadmitted' WHERE key='workspace_id'")
      }
      Issue.record("A caught allocation refusal did not latch the writer")
    } catch let error as NotebookStorageError { #expect(error == .limitExceeded("phase_merge_budget")) }
    #expect(try f.state(f.origin) == before)
  }

  @Test func anExisting8192PointReceiptRetainsItsExactBodyUnderDefaultDelivery() throws {
    let f = try Fixture(); defer { f.clean() }
    let points = (0..<8_192).map { index in JSONValue.object([
      "x": .number(Double(index % 300)), "y": .number(Double(index % 400)),
      "width": .number(2), "opacity": .number(0.7), "timeOffset": .number(Double(index) / 120),
      "force": .number(0.5), "azimuth": .number(0.25), "altitude": .number(0.75)]) }
    let stroke = CollaborationOperation(kind: .appendInkStroke, target: f.page, id: UUID().uuidString,
      values: ["width": .number(2), "points": .array(points)])
    let request = CollaborationAction(id: UUID(), summary: "Measured author contact", expected: [], operations: [stroke])
    _ = try f.origin.applyNativeAction(request, actor: f.actor)
    try f.deliverNew()
    let file = f.file(request.id), before = try f.state(f.replica)
    let raw = try #require(try f.origin.storedValue(file))
    let records = try f.origin.sqlRead { try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(file)]) }
      .map { NotebookRecordMutation(address: $0[0].text!, blobHash: $0[1].text!) }
    let transaction = UUID()
    let manifest = NotebookChangeManifest(transactionID: transaction, workspaceID: try f.origin.storedWorkspaceID(), records: records)
    let data = try NotebookStore.storageEncoder.encode(manifest), hash = NotebookHexEncoding.encode(SHA256.hash(data: data))
    try f.replica.stageBlob(data: data, expectedHash: hash)
    let change = NotebookDurableChange(sequence: before.incoming + 1, transactionID: transaction, manifestHash: hash, byteCount: data.count)
    let delivery = NotebookReplicationDelivery(source: f.source, change: change)
    #expect(try f.replica.applyDelivery(delivery) == change.sequence)
    let accepted = try f.state(f.replica)
    #expect(accepted.records == before.records && accepted.models == before.models && accepted.change == before.change)
    let retained = try #require(try f.replica.storedValue(file))
    #expect(try collaborationHash(retained) == collaborationHash(raw))
    #expect(try f.replica.applyDelivery(delivery) == change.sequence)
    #expect(try f.state(f.replica) == accepted)
  }
}
