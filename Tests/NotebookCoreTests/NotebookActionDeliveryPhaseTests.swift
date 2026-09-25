import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Delivery acknowledges an exact saved action phase")
struct NotebookActionDeliveryPhaseTests {
  private struct Fixture {
    let store: NotebookStore
    let actor = UUID(), device = UUID()
    let target: CollaborationTarget
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-delivery-\(UUID())"))
      let workspace = try store.loadOrCreate(actor: actor, pageSize: .init(width: 400, height: 600)).0
      target = .init(kind: .board, id: workspace.rootBoardID)
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      _ = try store.applyCollaborationAction(.init(summary: "A real target", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .insertElement, target: target, id: "control", values: ["kind": .string("web"),
          "source": .string("<button>Value</button>"), "state": .number(0),
          "frame": try .encode(PageRect(x: 0, y: 0, width: 200, height: 80)),
          "worldOrigin": try .encode(WorldPoint.zero)])]), actor: actor)
    }
    func clean() { try? FileManager.default.removeItem(at: store.root) }
    func set(_ value: Int) throws -> CollaborationReceipt {
      try store.applyCollaborationAction(.init(summary: "A state contribution", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .setElementState, target: target, id: "control", values: ["state": .number(Double(value))])]), actor: actor)
    }
    func detail(_ action: CollaborationReceipt) throws -> JSONValue {
      var command = NotebookCommand(command: .actionDetails); command.actionID = action.id
      return try #require(NotebookCommandDispatcher(store: store).handle(command).array.first)
    }
    func receipt(_ action: CollaborationReceipt) throws -> DeviceActionReceipt {
      try #require(store.deviceActionReceipts(actionIDs: [action.id]).first)
    }
  }

  @Test func coldDrainAdmitsEveryPendingPhaseAndMigratesAnOlderBacklog() throws {
    let f = try Fixture(); defer { f.clean() }
    var receipts: [CollaborationReceipt] = []
    for value in 1...137 { receipts.append(try f.set(value)) }
    let first = try f.store.acknowledgeReceivedActions(deviceID: f.device)
    #expect(first.processed == 64 && first.published == 64 && first.hasMore)
    let reopened = NotebookStore(root: f.store.root)
    let second = try reopened.acknowledgeReceivedActions(deviceID: f.device)
    let third = try reopened.acknowledgeReceivedActions(deviceID: f.device)
    #expect(second.processed == 64 && second.hasMore)
    #expect(third.processed == 10 && !third.hasMore)
    for receipt in receipts { #expect(try f.receipt(receipt).actionVersion == receipt.deliveryVersion()) }
    let cursor = try reopened.currentChangeCursor()
    try reopened.commandTransaction(advancesReadRevision: false) {
      try reopened.currentSQL!.run("DROP INDEX action_pending_arrivals")
      try reopened.currentSQL!.run("ALTER TABLE action_read_models DROP COLUMN arrival_receipt_hash")
      try reopened.currentSQL!.run("PRAGMA user_version=23")
    }
    let migrated = NotebookStore(root: f.store.root)
    var processed = 0
    while true {
      let batch = try migrated.acknowledgeReceivedActions(deviceID: f.device)
      #expect(batch.processed <= 64 && batch.published == 0)
      processed += batch.processed
      if !batch.hasMore { break }
    }
    #expect(try processed == 138 && migrated.currentChangeCursor() == cursor)
    let undo = try migrated.undoCollaborationAction(receipts[0].id, actor: f.actor)
    let next = try migrated.acknowledgeReceivedActions(deviceID: f.device)
    #expect(next.processed == 1 && next.published == 1 && !next.hasMore)
    #expect(try f.receipt(undo).actionVersion == undo.deliveryVersion())
  }

  @Test(arguments: [71, 1_000])
  func pendingBacklogRestartsAtTheExactCommittedBatchAndRetriesAtomically(count: Int) throws {
    enum Rollback: Error { case interrupted }
    let f = try Fixture(); defer { f.clean() }
    let template = try f.set(0)
    while try f.store.acknowledgeReceivedActions(deviceID: f.device).hasMore {}
    var versions: [UUID: String] = [:]
    // These are valid immutable no-op receipts, admitted by the real fragment
    // writer. Every one remains pending; no delivery or progress is seeded.
    try f.store.commandTransaction {
      for position in 0..<count {
        let id = UUID(), action = CollaborationAction(id: id, summary: template.action.summary,
          expected: template.action.expected, operations: template.action.operations)
        let receipt = CollaborationReceipt(id: id, action: action,
          createdAt: template.createdAt.addingTimeInterval(Double(position)),
          revisions: template.revisions, changes: template.changes)
        let fragment = try #require(NotebookRecordCodec.encode(.encode(receipt),
          file: "collaboration/actions/" + id.uuidString.lowercased() + ".json").first)
        try f.store.writeFragment(fragment, database: f.store.currentSQL!)
        versions[id] = try receipt.deliveryVersion()
      }
    }
    let before = try f.store.currentChangeCursor(), ids = Array(versions.keys)
    #expect(throws: Rollback.self) {
      try f.store.commandTransaction {
        let interrupted = try f.store.acknowledgeReceivedActions(deviceID: f.device)
        #expect(interrupted.processed == 64 && interrupted.published == 64 && interrupted.hasMore)
        throw Rollback.interrupted
      }
    }
    #expect(try f.store.currentChangeCursor() == before)
    #expect(try f.store.deviceActionReceipts(actionIDs: Array(ids.prefix(128))).isEmpty)
    var store = NotebookStore(root: f.store.root), processed = 0, batches = 0
    while processed < count {
      let batch = try store.acknowledgeReceivedActions(deviceID: f.device)
      #expect(batch.processed == min(64, count - processed) && batch.published == batch.processed)
      processed += batch.processed; batches += 1
      #expect(batch.hasMore == (processed < count))
      // Close the logical owner after its first successful commit. The next
      // admission must continue from SQLite, not an in-memory watermark.
      if batches == 1 { store = NotebookStore(root: f.store.root) }
    }
    for offset in stride(from: 0, to: ids.count, by: 128) {
      let page = Array(ids[offset..<min(ids.count, offset + 128)])
      let receipts = try store.deviceActionReceipts(actionIDs: page)
      #expect(receipts.count == page.count)
      for receipt in receipts { #expect(receipt.actionVersion == versions[receipt.id]) }
    }
    let cursor = try store.currentChangeCursor()
    let retry = try NotebookStore(root: f.store.root).acknowledgeReceivedActions(deviceID: f.device)
    #expect(retry.processed == 0 && retry.published == 0 && !retry.hasMore)
    #expect(try store.currentChangeCursor() == cursor)
    #expect(batches == (count + 63) / 64)
    print("ACTION_ARRIVAL_BACKLOG pending=\(count) processed=\(processed) batches=\(batches) interrupted_batch=64 restart_after=64 retry_published=\(retry.published)")
  }

  @Test func aPendingArrivalSeeksPastOneHundredThousandAlreadyAdmittedReceipts() throws {
    let f = try Fixture(); defer { f.clean() }
    let template = try f.set(0)
    while try f.store.acknowledgeReceivedActions(deviceID: f.device).hasMore {}
    let start = ContinuousClock.now
    // Valid immutable no-op receipts pass through the ordinary fragment/index
    // writer. Only the local admission marker is populated directly: this test
    // exercises arrival lookup, not 100000 redundant receipt publications.
    try f.store.commandTransaction {
      for position in 0..<100_000 {
        let id = UUID(), action = CollaborationAction(id: id, summary: template.action.summary,
          expected: template.action.expected, operations: template.action.operations)
        let receipt = CollaborationReceipt(id: id, action: action, createdAt: template.createdAt.addingTimeInterval(Double(position)),
          revisions: template.revisions, changes: template.changes)
        let fragment = try #require(NotebookRecordCodec.encode(.encode(receipt),
          file: "collaboration/actions/" + id.uuidString.lowercased() + ".json").first)
        try f.store.writeFragment(fragment, database: f.store.currentSQL!)
      }
      try f.store.currentSQL!.run("UPDATE action_read_models SET arrival_receipt_hash=receipt_hash")
    }
    let pending = try f.set(1), trace = ArrivalSQLCounter()
    let result = try f.store.commandTransaction { () throws -> NotebookActionArrivalDrain in
      let db = f.store.currentSQL!
      sqlite3_trace_v2(db.handle, UInt32(SQLITE_TRACE_PROFILE), { _, pointer, raw, _ in
        guard let pointer, let raw else { return 0 }
        let statement = OpaquePointer(raw), sql = sqlite3_sql(statement).map { String(cString: $0) } ?? ""
        if sql.hasPrefix("SELECT"), sql.contains("arrival_receipt_hash IS NOT") {
          Unmanaged<ArrivalSQLCounter>.fromOpaque(pointer).takeUnretainedValue().steps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
        }
        return 0
      }, Unmanaged.passUnretained(trace).toOpaque())
      defer { sqlite3_trace_v2(db.handle, 0, nil, nil) }
      return try f.store.acknowledgeReceivedActions(deviceID: f.device)
    }
    #expect(result.processed == 1 && result.published == 1 && !result.hasMore)
    #expect(try f.receipt(pending).actionVersion == pending.deliveryVersion())
    #expect(trace.steps > 0 && trace.steps < 1_000)
    print("ACTION_ARRIVAL_SCALE valid_receipts=100000 pending=1 lookup_vm_steps=\(trace.steps) fixture_and_probe=\(start.duration(to: .now))")
  }

  @Test func originalEmptyAndUndoEmptyRequireDifferentActualArrivals() throws {
    let f = try Fixture(); defer { f.clean() }
    let initial = try f.set(0)
    #expect(initial.revisions.isEmpty && initial.changes.isEmpty)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let first = try f.receipt(initial), originalVersion = try initial.deliveryVersion()
    #expect(first.actionVersion == originalVersion)
    let undo = try f.store.undoCollaborationAction(initial.id, actor: f.actor)
    #expect(undo.undo?.restored == 0 && undo.revisions.isEmpty)
    #expect(try undo.deliveryVersion() != originalVersion)
    #expect(try f.detail(undo)["publication"]?["receivedByIPad"] == .string("awaiting_device"))
    #expect(try f.receipt(undo) == first, "A status read cannot invent a later arrival")
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let second = try f.receipt(undo)
    #expect(second.actionVersion == (try undo.deliveryVersion()))
    #expect(second.receivedAt >= (try #require(undo.undo).completedAt))
    #expect(!second.displayComplete && second.shown.isEmpty && second.visibleRegions.isEmpty)
    #expect(try f.detail(undo)["publication"]?["receivedByIPad"] == .string("confirmed"))
    #expect(try f.detail(undo)["publication"]?["shownOnIPad"] == .string("not_required"))
    let cursor = try f.store.currentChangeCursor()
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.receipt(undo) == second)
  }

  @Test func undoOfAnOldActionReentersDeliveryWithoutReorderingCreationHistory() throws {
    let f = try Fixture(); defer { f.clean() }
    let original = try f.set(1)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let old = try f.receipt(original)
    for _ in 0..<70 { _ = try f.set(1) }
    #expect(try !f.store.actionReadModels(limit: 64).contains { $0.id == original.id })
    let undo = try f.store.undoCollaborationAction(original.id, actor: f.actor)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    while try f.store.acknowledgeReceivedActions(deviceID: f.device).hasMore {}
    let received = try f.receipt(undo)
    #expect(received.actionVersion == (try undo.deliveryVersion()))
    #expect(received.actionVersion != old.actionVersion)
    #expect(!received.displayComplete)
    #expect(try f.detail(undo)["publication"]?["receivedByIPad"] == .string("confirmed"))
    #expect(try !f.store.actionReadModels(limit: 64).contains { $0.id == original.id },
      "Creation-history pagination must not silently become modification order")
    #expect(try f.store.recentActionPhases(limit: 1).first?.actionVersion == undo.deliveryVersion())
    let cursor = try f.store.currentChangeCursor(), readCursor = try f.store.currentReadCursor()
    let workspace = try f.store.workspaceHeader().workspaceID
    let file = "collaboration/actions/" + original.id.uuidString.lowercased() + ".json"
    let before = try f.store.sqlRead {
      try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(file)])
        .map { [$0[0].text!, $0[1].text!] }
    }
    // Existing v11 database: rebuild only the derived phase index on admission.
    try f.store.commandTransaction(advancesReadRevision: false) {
      try f.store.currentSQL!.run("DROP INDEX action_phase_time")
      try f.store.currentSQL!.run("ALTER TABLE action_read_models DROP COLUMN phase_at")
      try f.store.currentSQL!.run("PRAGMA user_version=11")
    }
    let reopened = NotebookStore(root: f.store.root)
    try reopened.prepare()
    #expect(try reopened.recentActionPhases(limit: 1).first?.actionVersion == undo.deliveryVersion())
    #expect(try reopened.currentChangeCursor() == cursor && reopened.currentReadCursor() == readCursor)
    #expect(try reopened.workspaceHeader().workspaceID == workspace)
    #expect(try reopened.sqlRead {
      try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(file)])
        .map { [$0[0].text!, $0[1].text!] }
    } == before)
  }

  @Test func lateOldPhaseCannotOverwriteOrUnionTheCurrentReceipt() throws {
    let f = try Fixture(); defer { f.clean() }
    let initial = try f.set(0)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let old = try f.receipt(initial)
    let undo = try f.store.undoCollaborationAction(initial.id, actor: f.actor)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let current = try f.receipt(undo), cursor = try f.store.currentChangeCursor()
    // A delayed owner-provided display claim; these Core bytes are not a visual test.
    let late = DeviceActionReceipt(id: old.id, deviceID: old.deviceID, receivedAt: Date().addingTimeInterval(60),
      revisions: old.revisions, actionVersion: old.actionVersion, shown: initial.revisions,
      displayComplete: true, visibleRegions: [.init(target: f.target, revision: try f.store.referenceRevision(target: f.target))])
    #expect(try !f.store.saveDeviceActionReceipt(late))
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.receipt(undo) == current)
    let envelope = try CollaborationEnvelope(actions: [undo], delivery: [current])
      .merging(.init(actions: [initial], delivery: [late]))
    #expect(envelope.delivery == [current])
    _ = try f.store.receiveCollaboration(.init(delivery: [late]))
    #expect(try f.receipt(undo) == current)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func writerRejectsWrongRevisionsEvenWithTheCurrentVersion() throws {
    let f = try Fixture(); defer { f.clean() }
    let action = try f.set(1)
    #expect(!action.revisions.isEmpty)
    let counterfeit = DeviceActionReceipt(id: action.id, deviceID: f.device,
      revisions: [], actionVersion: try action.deliveryVersion(), displayComplete: true)
    let cursor = try f.store.currentChangeCursor()
    #expect(try !f.store.saveDeviceActionReceipt(counterfeit))
    #expect(try f.store.deviceActionReceipts(actionIDs: [action.id]).isEmpty)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func historicalVersionlessReceiptsStayReadableButCannotConfirmCurrent() throws {
    let f = try Fixture(); defer { f.clean() }
    let action = try f.set(1)
    #expect(action.requestFingerprint == nil, "No raw request fingerprint may be invented")
    let legacy = DeviceActionReceipt(id: action.id, deviceID: f.device, revisions: action.revisions,
      shown: action.revisions, displayComplete: true, visibleRegions: [.init(target: f.target, revision: try f.store.referenceRevision(target: f.target))])
    let file = "collaboration/delivery/\(action.id.uuidString.lowercased()).json"
    let encoded = try JSONValue.encode(legacy)
    #expect(encoded["actionVersion"] == nil)
    try f.store.publishRecords(writes: [file: encoded]) // Existing historical data, not the current ACK API.
    let before = try f.store.sqlRead {
      try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(file)])
        .map { [$0[0].text!, $0[1].text!] }
    }
    let cursor = try f.store.currentChangeCursor()
    let read = try f.detail(action)
    #expect(read["publication"]?["receivedByIPad"] == .string("awaiting_device"))
    #expect(read["publication"]?["shownOnIPad"] == .string("awaiting_display"))
    #expect(read["delivery"]?.array.first?["sameActionVersion"] == .bool(false))
    #expect(try f.store.sqlRead {
      try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(file)])
        .map { [$0[0].text!, $0[1].text!] }
    } == before && f.store.currentChangeCursor() == cursor)
    #expect(try !f.store.saveDeviceActionReceipt(legacy))
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let fresh = try f.receipt(action)
    #expect(fresh.actionVersion == (try action.deliveryVersion()))
    #expect(!fresh.displayComplete && fresh.shown.isEmpty && fresh.visibleRegions.isEmpty)
    #expect(try f.store.collaborationAction(action.id).requestFingerprint == nil)
    let undo = try f.store.undoCollaborationAction(action.id, actor: f.actor)
    #expect(undo.undo?.restored == 1)
    #expect(try f.store.readSpatialElement(boardID: f.target.id, elementID: "control")?.state == .number(0))
  }

  @Test func canonicalVersionSurvivesEncodingAndChangesWithTheSavedOutcome() throws {
    let f = try Fixture(); defer { f.clean() }
    let action = try f.set(1), version = try action.deliveryVersion()
    let roundTrip = try JSONValue.encode(action).decode(CollaborationReceipt.self)
    #expect(try roundTrip.deliveryVersion() == version)
    #expect(try f.store.collaborationAction(action.id).deliveryVersion() == version)
    let undo = try f.store.undoCollaborationAction(action.id, actor: f.actor)
    #expect(try undo.deliveryVersion() != version)
    let retry = try f.store.undoCollaborationAction(action.id, actor: f.actor)
    #expect(try retry.deliveryVersion() == undo.deliveryVersion())
  }

  private func synchronize(_ source: NotebookStore, _ destination: NotebookStore, peerID: UUID) throws {
    var cursor = try destination.peerCursor(peerID: peerID, direction: .incoming)
    while let change = try source.changeJournal(after: cursor).first {
      while true {
        let hashes = try destination.missingBlobHashes(for: change)
        if hashes.isEmpty { break }
        for hash in hashes {
          let size = try source.blobSize(hash: hash)
          var data = Data()
          while Int64(data.count) < size {
            data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)
          }
          try destination.stageBlob(data: data, expectedHash: hash)
        }
      }
      cursor = try destination.applyRemoteChange(change, peerID: peerID)
    }
  }

  @Test func realReplicationOfALateAckKeepsTheCurrentUndoArrival() throws {
    let f = try Fixture(); defer { f.clean() }
    let initial = try f.set(0)
    let peer = NotebookStore(root: f.store.root.appendingPathComponent("peer"))
    try peer.prepareEmptyWorkspace(workspaceID: f.store.workspaceHeader().workspaceID)
    try synchronize(f.store, peer, peerID: f.actor)
    let remoteInitial = try peer.collaborationAction(initial.id)
    #expect(try remoteInitial.deliveryVersion() == initial.deliveryVersion())
    // The peer is still on the original phase and legitimately queues its ACK.
    let late = DeviceActionReceipt(id: initial.id, deviceID: f.device,
      receivedAt: Date().addingTimeInterval(60), revisions: remoteInitial.revisions,
      actionVersion: try remoteInitial.deliveryVersion(), displayComplete: true)
    #expect(try peer.saveDeviceActionReceipt(late))
    let undo = try f.store.undoCollaborationAction(initial.id, actor: f.actor)
    try f.store.acknowledgeReceivedActions(deviceID: f.device)
    let current = try f.receipt(undo)
    try synchronize(peer, f.store, peerID: f.device)
    #expect(try f.receipt(undo) == current)
    #expect(try f.store.collaborationAction(initial.id) == undo)
    #expect(!current.displayComplete)
    #expect(try f.detail(undo)["publication"]?["receivedByIPad"] == .string("confirmed"))
  }
}

private final class ArrivalSQLCounter { var steps = 0 }
