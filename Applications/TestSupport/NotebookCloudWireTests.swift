import CloudKit
import CryptoKit
import Foundation
@testable import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookCloudWireTests: XCTestCase {
  private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  func testExistingAssetMetadataDoesNotRequireAnotherDownloadToDeduplicate() throws {
    let data = Data("Immutable".utf8), hash = hash(data)
    let value = try NotebookCloudRecord.chunk(hash: hash, offset: 0, totalBytes: Int64(data.count))
    let record = CKRecord(recordType: "NotebookBlob", recordID: .init(recordName: value.id))
    record["format"] = 1 as NSNumber; record["hash"] = hash as NSString
    record["offset"] = 0 as NSNumber; record["total"] = data.count as NSNumber; record["digest"] = hash as NSString
    XCTAssertEqual(try NotebookCloudSync.descriptor(record), value)
    // Metadata alone can confirm an existing immutable server record, but it
    // is never sufficient to publish a newly fetched content dependency.
    XCTAssertThrowsError(try NotebookCloudSync.decode(record))
  }

  func testDownloadedAssetMustHaveExactlyTheDeclaredContent() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-asset-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let data = Data("Known content".utf8), hash = hash(data)
    try data.write(to: file)
    let value = try NotebookCloudRecord.chunk(hash: hash, offset: 0, totalBytes: Int64(data.count))
    let record = CKRecord(recordType: "NotebookBlob", recordID: .init(recordName: value.id))
    record["format"] = 1 as NSNumber; record["hash"] = hash as NSString
    record["offset"] = 0 as NSNumber; record["total"] = data.count as NSNumber; record["digest"] = hash as NSString
    record["asset"] = CKAsset(fileURL: file)
    XCTAssertEqual(try NotebookCloudSync.decode(record).1, data)
    try Data("Wrong content".utf8).write(to: file)
    XCTAssertThrowsError(try NotebookCloudSync.decode(record))
  }

  func testEnvelopeRecordNameCommitsToSourceGenerationAndSnapshotBoundary() throws {
    let device = UUID(), generation = UUID()
    let change = NotebookDurableChange(sequence: 50, transactionID: UUID(), manifestHash: String(repeating: "a", count: 64), byteCount: 500)
    let delivery = NotebookReplicationDelivery(source: .init(deviceID: device, generation: generation), change: change, isSnapshot: true)
    let value = try NotebookCloudRecord(delivery: delivery)
    let record = CKRecord(recordType: "NotebookDelivery", recordID: .init(recordName: value.id))
    record["format"] = 1 as NSNumber; record["body"] = try JSONEncoder().encode(delivery) as NSData
    XCTAssertEqual(try NotebookCloudSync.decode(record).0, value)
    record["body"] = try JSONEncoder().encode(NotebookReplicationDelivery(source: delivery.source, change: change)) as NSData
    XCTAssertThrowsError(try NotebookCloudSync.decode(record))
  }

  func testDisabledCloudNeverNeedsContainerEntitlementsOrAnAccount() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-off-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try store.prepareCloudStorage()
    let source = try store.replicationSource(deviceID: actor)
    let cloud = NotebookCloudSync(store: store, writer: NotebookPersistenceQueue(store: store), source: source, workspaceID: header.workspaceID,
      apply: { _, _ in throw NotebookTransportError.disconnected }, waitForInputIdle: { nil }, report: { _ in })
    await cloud.resume()
    XCTAssertFalse(try store.cloudConfiguration().enabled)
    XCTAssertEqual(try store.workspaceHeader().workspaceID, header.workspaceID)
    await cloud.stop()
  }

  func testHeldCloudSourceAllowsIndependentSourceAndOutgoingPlanThenStopRevokesItsIdleWait() async throws {
    let fixture = try await cloudFixture(), model = fixture.model, cloud = fixture.cloud
    let board = CollaborationTarget(kind: .board, id: try model.store.workspaceHeader().rootBoardID)
    let page = CollaborationTarget(kind: .page, id: try XCTUnwrap(model.activePage).id)
    let a = try fixture.snapshot(device: .init(uuidString: "00000000-0000-0000-0000-000000000001")!, target: board, element: "cloud-a")
    let b = try fixture.snapshot(device: .init(uuidString: "10000000-0000-0000-0000-000000000001")!, target: page, element: "cloud-b")
    try await fixture.stage(a); try await fixture.stage(b)
    model.updatePresence(.init(boardID: board.id, mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)), settled: true)
    let contact = UUID()
    XCTAssertTrue(model.inputGate.beginPencilAction(source: contact))
    defer { model.inputGate.endPencilAction(source: contact) }
    try await cloud.activateContent(account: fixture.account)
    await cloud.waitForContentRuns()
    XCTAssertTrue(model.inputGate.hasActivePencil)
    XCTAssertEqual(try model.store.incomingCursor(source: a.delivery.source), 0, "Rejected A has no durable ACK")
    XCTAssertEqual(try model.store.incomingCursor(source: b.delivery.source), b.delivery.change.sequence)
    XCTAssertNotNil(try model.store.readPageElement(pageID: page.id, elementID: "cloud-b"))
    XCTAssertFalse(try model.store.cloudOutbox(account: fixture.account).isEmpty, "Outgoing preparation must finish while A's actual input remains held")
    XCTAssertFalse(try model.store.cloudHasUploadedCurrentContent(account: fixture.account), "A prepared export has no outgoing ACK")
    let c = try fixture.snapshot(device: .init(uuidString: "20000000-0000-0000-0000-000000000001")!, target: page, element: "cloud-after-fetch")
    let account = fixture.account, local = fixture.source, cEnvelope = c.delivery
    try await fixture.writer.submit(writesStore: true) { try $0.stageCloudDelivery(cEnvelope, account: account, localSource: local) }
    await cloud.contentWasFetched(); await cloud.waitForContentRuns()
    XCTAssertEqual(try model.store.incomingCursor(source: c.delivery.source), 0, "An envelope with missing content remains unacknowledged")
    try await fixture.stage(c)
    await cloud.contentWasFetched(); await cloud.waitForContentRuns()
    XCTAssertEqual(try model.store.incomingCursor(source: c.delivery.source), c.delivery.change.sequence)
    XCTAssertEqual(try model.store.incomingCursor(source: a.delivery.source), 0)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    let cursor = try model.store.currentChangeCursor()
    try await fixture.stage(b)
    await cloud.contentWasFetched(); await cloud.waitForContentRuns()
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor, "An already accepted B echo cannot publish another material wake")
    XCTAssertEqual(try model.store.incomingCursor(source: a.delivery.source), 0)
    await cloud.stop()
    let stoppedStatus = model.cloudStatus.message
    await cloud.notifyLocalChanges(); await cloud.waitForContentRuns()
    XCTAssertEqual(model.cloudStatus.message, stoppedStatus, "An accepted material wake after Stop cannot restart account lookup or content scheduling")
    XCTAssertEqual(try model.store.incomingCursor(source: a.delivery.source), 0)
    try await cloud.activateContent(account: fixture.account)
    await cloud.waitForContentRuns()
    XCTAssertTrue(model.inputGate.hasActivePencil)
    XCTAssertEqual(try model.store.incomingCursor(source: a.delivery.source), 0, "The replacement epoch must subscribe to the held contact instead of accepting A early")
    model.inputGate.endPencilAction(source: contact)
    _ = await model.inputGate.waitUntilIdle()
    try await until { try model.store.incomingCursor(source: a.delivery.source) == a.delivery.change.sequence }
    await cloud.waitForContentRuns()
    XCTAssertEqual(try model.store.incomingCursor(source: a.delivery.source), a.delivery.change.sequence)
    XCTAssertTrue(try model.store.cloudInbox(account: fixture.account).isEmpty)
  }

  func testSemanticCloudSourceKeepsItsCursorWithoutStoppingOtherSourcesOrOutgoingWork() async throws {
    let fixture = try await cloudFixture(), model = fixture.model, cloud = fixture.cloud
    let known = try XCTUnwrap(model.store.changeJournal(after: 0).first)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let source = NotebookReplicationSource(deviceID: id, generation: id)
    let rejected = NotebookReplicationDelivery(source: source, change: .init(sequence: known.sequence,
      transactionID: known.transactionID, manifestHash: String(repeating: "c", count: 64), byteCount: known.byteCount), isSnapshot: true)
    let page = CollaborationTarget(kind: .page, id: try XCTUnwrap(model.activePage).id)
    let b = try fixture.snapshot(device: .init(uuidString: "10000000-0000-0000-0000-000000000001")!, target: page, element: "cloud-independent")
    let account = fixture.account, local = fixture.source
    try await fixture.writer.submit(writesStore: true) { try $0.stageCloudDelivery(rejected, account: account, localSource: local) }
    try await fixture.stage(b)
    try await cloud.activateContent(account: account)
    await cloud.waitForContentRuns()
    XCTAssertEqual(try model.store.incomingCursor(source: source), 0)
    XCTAssertEqual(try model.store.cloudInbox(account: account), [rejected])
    XCTAssertEqual(try model.store.incomingCursor(source: b.delivery.source), b.delivery.change.sequence)
    XCTAssertNotNil(try model.store.readPageElement(pageID: page.id, elementID: "cloud-independent"))
    XCTAssertFalse(try model.store.cloudOutbox(account: account).isEmpty)
    let cursor = try model.store.currentChangeCursor(), generation = fixture.writer.acceptedMutationGeneration
    await Task.yield(); await cloud.waitForContentRuns()
    XCTAssertEqual(fixture.writer.acceptedMutationGeneration, generation, "The rejected source and cloud housekeeping must leave scheduling idle")
    try await fixture.stage(b)
    await cloud.contentWasFetched(); await cloud.waitForContentRuns()
    XCTAssertEqual(try model.store.currentChangeCursor(), cursor)
    XCTAssertEqual(try model.store.incomingCursor(source: source), 0)
    XCTAssertEqual(try model.store.cloudInbox(account: account), [rejected])
    await cloud.stop()
  }

  func testOverflowedDeferredGenerationsReachHealthySourceAndKeepTheirInputWakeWithoutAnIdleLoop() async throws {
    let fixture = try await cloudFixture(), model = fixture.model, cloud = fixture.cloud
    let known = try XCTUnwrap(model.store.changeJournal(after: 0).first)
    let board = CollaborationTarget(kind: .board, id: try model.store.workspaceHeader().rootBoardID)
    let page = CollaborationTarget(kind: .page, id: try XCTUnwrap(model.activePage).id)
    let device = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let held = try fixture.snapshot(device: device, target: board, element: "overflow-held")
    // Two devices suffice: B is a prior journal of this same receiving device,
    // whose exact current local source alone is an automatically skipped echo.
    let healthy = try fixture.snapshot(device: model.actorID, target: page, element: "overflow-independent")
    let b = NotebookReplicationDelivery(source: .init(deviceID: model.actorID,
      generation: UUID(uuidString: "f0000000-0000-0000-0000-000000000001")!),
      change: healthy.delivery.change, isSnapshot: true)
    var pending: [NotebookReplicationDelivery] = []
    for ordinal in 0..<144 {
      let generation = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", ordinal + 2)))
      let change = ordinal < 128 ? NotebookDurableChange(sequence: known.sequence, transactionID: known.transactionID,
        manifestHash: String(repeating: "c", count: 64), byteCount: known.byteCount) : held.delivery.change
      pending.append(.init(source: .init(deviceID: device, generation: generation), change: change, isSnapshot: true))
    }
    let account = fixture.account, local = fixture.source
    let heldStore = held.store, heldChange = held.delivery.change, healthyStore = healthy.store, healthyChange = healthy.delivery.change
    let envelopes = pending + [b]
    try await fixture.writer.submit(writesStore: true) { destination in
      try NotebookPeerFixture.stage(heldChange, from: heldStore, to: destination)
      try NotebookPeerFixture.stage(healthyChange, from: healthyStore, to: destination)
      for delivery in envelopes { try destination.stageCloudDelivery(delivery, account: account, localSource: local) }
    }
    model.updatePresence(.init(boardID: board.id, mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)), settled: true)
    let contact = UUID()
    XCTAssertTrue(model.inputGate.beginPencilAction(source: contact))
    defer { model.inputGate.endPencilAction(source: contact) }
    try await cloud.activateContent(account: account)
    try await joinCloudRuns(cloud)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    XCTAssertEqual(try model.store.incomingCursor(source: b.source), b.change.sequence)
    XCTAssertNotNil(try model.store.readPageElement(pageID: page.id, elementID: "overflow-independent"))
    for delivery in pending { XCTAssertEqual(try model.store.incomingCursor(source: delivery.source), 0) }
    let resident = await cloud.deferredSourceCount
    XCTAssertLessThanOrEqual(resident, 128, "The durable inbox carries overflow; resident exact-source reasons stay bounded")
    let flushed = await fixture.writer.flush(); XCTAssertTrue(flushed)
    try await joinCloudRuns(cloud)
    let generation = fixture.writer.acceptedMutationGeneration
    await Task.yield(); try await joinCloudRuns(cloud)
    XCTAssertEqual(fixture.writer.acceptedMutationGeneration, generation, "Joining an idle sweep creates neither another pass nor another writer admission")
    model.inputGate.endPencilAction(source: contact)
    _ = await model.inputGate.waitUntilIdle()
    try await until { try pending.suffix(16).allSatisfy { try model.store.incomingCursor(source: $0.source) == $0.change.sequence } }
    try await joinCloudRuns(cloud)
    for delivery in pending.prefix(128) { XCTAssertEqual(try model.store.incomingCursor(source: delivery.source), 0) }
    let remaining = try model.store.sqlRead { try $0.rows("SELECT COUNT(*) FROM cloud_inbox WHERE account=?", [.text(account)]).first?[0].integer }
    XCTAssertEqual(remaining, 128, "The unresolved semantic backlog remains staged without ACKs")
    await cloud.stop()
  }

  func testActualCloudActorLeavesIdleSpoolPathUntouchedAndResumesAfterALocalEdit() async throws {
    let fixture = try await cloudFixture(), cloud = fixture.cloud, model = fixture.model
    try await cloud.activateContent(account: fixture.account)
    try await fixture.acknowledgeAll()
    let directory = model.store.root.appendingPathComponent("runtime/cloud-upload-plans")
    if FileManager.default.fileExists(atPath: directory.path) {
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
      try FileManager.default.removeItem(at: directory)
    }
    let barrier = Data("No filesystem work while cloud is idle".utf8)
    try barrier.write(to: directory)
    for _ in 0..<3 {
      await cloud.notifyLocalChanges(); await cloud.waitForContentRuns()
      XCTAssertEqual(model.cloudStatus.message, "Изменения отправлены в iCloud.")
      XCTAssertEqual(try Data(contentsOf: directory), barrier)
    }
    try FileManager.default.removeItem(at: directory)
    let page = CollaborationTarget(kind: .page, id: try XCTUnwrap(model.activePage).id), actor = model.actorID
    try await model.performStoreCommand(publishesChanges: true) { store in
      _ = try Self.insert(store, actor: actor, target: page, element: "cloud-after-idle")
    }
    // The accepted result returns before the queue's onCommit callback posts
    // its cloud task. Wait for that real publication, then join owned work.
    try await until { try !model.store.cloudOutbox(account: fixture.account).isEmpty }
    await cloud.waitForContentRuns()
    XCTAssertFalse(try model.store.cloudOutbox(account: fixture.account).isEmpty)
    XCTAssertFalse(try model.store.cloudHasUploadedCurrentContent(account: fixture.account))
    await cloud.stop()
  }

  func testStoppedEpochJoinsAcceptedCloudBeginBeforeReleasingItsSpoolAndRetryUsesTheSameFIFO() async throws {
    let refusal = NotebookPersistenceFenceContract.Signal<Bool>()
    let fixture = try await cloudFixture(cloudBeginRefusal: refusal), cloud = fixture.cloud, queue = fixture.writer, store = fixture.model.store
    let account = fixture.account
    refusal.set(true)
    defer { refusal.set(false); queue.retry() }
    try await cloud.activateContent(account: fixture.account)
    try await until { queue.failure != nil }
    let directory = store.root.appendingPathComponent("runtime/cloud-upload-plans")
    let spools = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "sqlite" }
    let file = try XCTUnwrap(spools.first), plan = try XCTUnwrap(UUID(uuidString: file.deletingPathExtension().lastPathComponent))
    XCTAssertEqual(spools.count, 1)
    var stopEntered = false, stopped = false
    let stop = Task { stopEntered = true; await cloud.stop(); stopped = true }
    try await until { stopEntered }
    await Task.yield()
    XCTAssertFalse(stopped, "Stop must join the accepted begin rather than delete the bytes it still owns")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    do { try await cloud.activateContent(account: fixture.account); XCTFail("A blocked writer cannot activate a replacement") }
    catch { XCTAssertNotNil(queue.failure) }
    refusal.set(false)
    queue.retry(); await stop.value
    let pending = try await queue.submit(writesStore: true) { try $0.pendingCloudUploadPlan(account: account) }
    XCTAssertEqual(pending, plan, "The old epoch's accepted begin retains the exact durable spool")
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    try await cloud.activateContent(account: fixture.account)
    await cloud.waitForContentRuns()
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Only sealing the resumed export releases its spool")
    XCTAssertFalse(try store.cloudOutbox(account: fixture.account).isEmpty)
    XCTAssertFalse(try store.cloudHasUploadedCurrentContent(account: fixture.account))
    XCTAssertNil(queue.failure)
    await cloud.stop()
  }

  @MainActor private struct CloudFixture {
    let model: NotebookAppModel
    let writer: NotebookPersistenceQueue
    let cloud: NotebookCloudSync
    let source: NotebookReplicationSource
    let account: String
    struct Snapshot { let store: NotebookStore; let delivery: NotebookReplicationDelivery }

    func snapshot(device: UUID, target: CollaborationTarget, element: String) throws -> Snapshot {
      let store = NotebookStore(root: model.store.root.appendingPathComponent("author-" + device.uuidString))
      try NotebookPeerFixture.copy(from: model.store, to: store, peerID: model.actorID)
      _ = try NotebookCloudWireTests.insert(store, actor: device, target: target, element: element)
      try store.prepareCloudStorage()
      let source = try store.replicationSource(deviceID: device)
      try store.enableCloud(account: account, source: source)
      let plan = try XCTUnwrap(store.prepareCloudUploadPlan(account: account, source: source))
      XCTAssertTrue(try store.beginCloudUpload(plan, account: account))
      while let batch = try store.prepareCloudUploadBatch(plan.id, account: account) {
        if try store.installCloudUploadBatch(batch, account: account) { break }
      }
      try store.discardCloudUploadSpool(plan.id)
      return .init(store: store, delivery: plan.delivery)
    }
    func stage(_ snapshot: Snapshot) async throws {
      let peer = snapshot.store, delivery = snapshot.delivery, account = account, source = source
      try await writer.submit(writesStore: true) { destination in
        try NotebookPeerFixture.stage(delivery.change, from: peer, to: destination)
        try destination.stageCloudDelivery(delivery, account: account, localSource: source)
      }
    }
    func acknowledgeAll() async throws {
      let account = account
      for _ in 0..<64 {
        await cloud.waitForContentRuns()
        let records = try await writer.submit { try $0.cloudOutbox(account: account) }
        if records.isEmpty, try model.store.cloudHasUploadedCurrentContent(account: account) { return }
        if !records.isEmpty {
          try await writer.submit(writesStore: true) { try $0.acknowledgeCloudRecords(records.map(\.id), account: account) }
        }
        await cloud.notifyLocalChanges()
      }
      XCTFail("The isolated actual cloud outbox failed to drain")
    }
  }

  private func cloudFixture(cloudBeginRefusal: NotebookPersistenceFenceContract.Signal<Bool>? = nil) async throws -> CloudFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-progress-" + UUID().uuidString)
    let store = NotebookStore(root: root, storageFault: { stage in
      guard stage == .beforeCommit, cloudBeginRefusal?.value == true,
        let database = NotebookStore(root: root).currentSQL,
        try !database.rows("SELECT 1 FROM cloud_exports WHERE ready=0 AND blob_cursor=0 AND record_cursor=0 LIMIT 1").isEmpty else { return }
      throw CocoaError(.fileWriteOutOfSpace)
    }), writer = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!, persistenceQueue: writer)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let account = "isolated-native-account", actor = model.actorID
    let source = try await writer.submit(writesStore: true) { store in
      try store.prepareCloudStorage()
      let source = try store.replicationSource(deviceID: actor)
      try store.enableCloud(account: account, source: source)
      return source
    }
    await model.prepareCloudSync()
    return try .init(model: model, writer: writer, cloud: XCTUnwrap(model.cloudSync), source: source, account: account)
  }

  nonisolated private static func insert(_ store: NotebookStore, actor: UUID, target: CollaborationTarget,
    element: String) throws -> CollaborationReceipt {
    var values: [String: JSONValue] = ["kind": .string("graphic"), "source": .string(""),
      "graphic": try .encode(NotebookGraphic(shape: .rectangle)), "frame": try .encode(PageRect(x: 100, y: 100, width: 80, height: 60))]
    if target.kind == .board { values["worldOrigin"] = try .encode(WorldPoint.zero) }
    return try store.applyNativeAction(.init(summary: "Cloud progress", expected: [
      .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .insertElement, target: target, id: element, values: values)]), actor: actor)
  }

  private func until(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !predicate() {
      guard .now < deadline else { XCTFail("Cloud progress deadline"); throw NotebookTransportError.disconnected }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  private func joinCloudRuns(_ cloud: NotebookCloudSync) async throws {
    var joined = false
    let join = Task { await cloud.waitForContentRuns(); joined = true }
    do { try await until { joined } }
    catch { await cloud.stop(); await join.value; throw error }
    await join.value
  }

}
