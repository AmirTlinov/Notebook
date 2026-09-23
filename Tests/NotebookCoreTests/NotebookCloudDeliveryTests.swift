import CryptoKit
import Foundation
import Testing
@testable import NotebookCore

@Suite("Cloud delivery through the SQLite owner", .serialized)
struct NotebookCloudDeliveryTests {
  private final class Pair {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-contract-" + UUID().uuidString)
    let a: NotebookStore, b: NotebookStore
    let actorA = UUID(), actorB = UUID()
    let sourceA: NotebookReplicationSource, sourceB: NotebookReplicationSource
    let account = "test-private-account"
    init() throws {
      a = NotebookStore(root: root.appendingPathComponent("a")); b = NotebookStore(root: root.appendingPathComponent("b"))
      _ = try a.initializeWorkspace(actor: actorA, pageSize: .init(width: 834, height: 1194))
      try FileManager.default.createDirectory(at: b.root, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: a.databaseURL, to: b.databaseURL)
      sourceA = try a.replicationSource(deviceID: actorA); sourceB = try b.replicationSource(deviceID: actorB)
      for (store, source) in [(a, sourceA), (b, sourceB)] {
        try store.prepareCloudStorage(); try store.enableCloud(account: account, source: source)
      }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
  }
  private struct StoredRecord { let value: NotebookCloudRecord; let bytes: Data? }

  private func upload(_ store: NotebookStore, source: NotebookReplicationSource, account: String) throws -> [StoredRecord] {
    var result: [StoredRecord] = []
    for _ in 0..<100 {
      try store.prepareCloudUpload(account: account, source: source)
      let records = try store.cloudOutbox(account: account)
      guard !records.isEmpty else { return result }
      for record in records {
        let data = try record.hash.map { try store.readBlobChunk(hash: $0, offset: record.offset, maxBytes: max(record.byteCount, 1)) }
        result.append(.init(value: record, bytes: data))
      }
      try store.acknowledgeCloudRecords(records.map(\.id), account: account)
    }
    Issue.record("Outbox failed to drain"); return result
  }

  private func stage(_ records: [StoredRecord], to store: NotebookStore, source: NotebookReplicationSource, account: String) throws {
    for record in records {
      if let delivery = record.value.delivery { try store.stageCloudDelivery(delivery, account: account, localSource: source) }
      else { try store.stageCloudChunk(record.value, data: #require(record.bytes), account: account) }
    }
  }
  private func assemble(_ store: NotebookStore, account: String) throws {
    while let blob = try store.nextCompleteCloudBlob(account: account) {
      let file = store.root.appendingPathComponent("test-cloud-assembly")
      defer { try? FileManager.default.removeItem(at: file) }
      try store.assembleCloudBlob(blob, account: account, file: file)
      try store.installCloudBlob(blob, account: account, file: file)
    }
  }
  private func receive(_ records: [StoredRecord], to store: NotebookStore, source: NotebookReplicationSource, account: String) throws {
    try stage(records, to: store, source: source, account: account); try assemble(store, account: account)
    var progress = true
    while progress {
      progress = false
      for delivery in try store.cloudInbox(account: account) {
        if try store.deliveryNeedsContent(delivery), try !store.missingBlobHashes(for: delivery.change, limit: 1).isEmpty { continue }
        _ = try store.applyCloudDelivery(delivery, account: account); progress = true
      }
    }
  }
  private func rename(_ store: NotebookStore, item: UUID, title: String, actor: UUID) throws {
    let board = CollaborationTarget(kind: .board, id: try store.workspaceHeader().rootBoardID)
    let workspace = CollaborationTarget(kind: .workspace, id: board.id)
    let action = CollaborationAction(summary: "Cloud title", expected: [
      .init(target: workspace, revision: try store.workspaceHeader().stamp.revision),
      .init(target: board, revision: try store.targetContentRevision(target: board))],
      operations: [.init(kind: .renameItem, target: board, id: item.uuidString, values: ["title": .string(title)])])
    _ = try store.applyCollaborationAction(action, actor: actor)
  }

  @Test func retiredCloudSourcesStayUnacknowledgedWithoutStarvingAnActiveSource() throws {
    let pair = try Pair(), cursor = try pair.b.currentChangeCursor()
    try pair.b.acknowledgePeer(peerID: pair.actorA, through: 0)
    let cloud = try upload(pair.a, source: pair.sourceA, account: pair.account)
    let seed = try #require(cloud.compactMap(\.value.delivery).first)
    try stage(cloud.filter { $0.value.delivery == nil }, to: pair.b, source: pair.sourceB, account: pair.account)
    // More than one inbox page of retired generations must not hide an active source.
    for _ in 0..<20 {
      let delivery = NotebookReplicationDelivery(source: .init(deviceID: pair.actorA, generation: UUID()),
        change: seed.change, isSnapshot: true)
      try pair.b.stageCloudDelivery(delivery, account: pair.account, localSource: pair.sourceB)
    }
    let active = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
    let delivery = NotebookReplicationDelivery(source: active, change: seed.change, isSnapshot: true)
    try pair.b.stageCloudDelivery(delivery, account: pair.account, localSource: pair.sourceB)
    try pair.b.retireReplicationPeer(pair.actorA, workspaceID: pair.b.storedWorkspaceID(), expectedCursor: cursor)
    let inbox = try pair.b.cloudInbox(account: pair.account)
    #expect(inbox.count == 1 && inbox.first?.source == active)
    #expect(try pair.b.sqlRead { try $0.rows("SELECT COUNT(*) FROM cloud_inbox").first?[0].integer } == 21)
    #expect(try pair.b.peerCursor(peerID: pair.actorA, direction: .outgoing) == 0)
    #expect(try pair.b.incomingCursor(source: pair.sourceA) == 0)
    try assemble(pair.b, account: pair.account)
    #expect(throws: CollaborationError.self) { try pair.b.applyCloudDelivery(seed, account: pair.account) }
    // Retirement does not prevent an active relay from carrying the same content.
    _ = try pair.b.applyCloudDelivery(delivery, account: pair.account)
    #expect(try pair.b.cloudInbox(account: pair.account).isEmpty)
    #expect(try pair.b.incomingCursor(source: active) == seed.change.sequence)
    #expect(try pair.b.peerCursor(peerID: pair.actorA, direction: .outgoing) == 0)
  }

  @Test func offlineRestartThenCloudOnlyDeliveryMergesInsteadOfReplacing() throws {
    let pair = try Pair(), item = try pair.a.loadIndex().selectedItemID, board = try pair.a.workspaceHeader().rootBoardID
    try rename(pair.a, item: item, title: "На прогулке", actor: pair.actorA)
    #expect(try pair.b.moveWorkspaceItem(itemID: item, in: board, to: .init(x: 700, y: 99), actor: pair.actorB))
    let reopenedPad = NotebookStore(root: pair.a.root)
    #expect(try reopenedPad.readItemHeader(item)?.title == "На прогулке")
    // The immutable server fixture is all Mac can access; the sender is not
    // consulted while it downloads, restarts, or applies its local conflict.
    let cloud = try upload(reopenedPad, source: pair.sourceA, account: pair.account)
    let mac = NotebookStore(root: pair.b.root)
    try receive(Array(cloud.reversed()), to: mac, source: pair.sourceB, account: pair.account)
    #expect(try mac.readItemHeader(item)?.title == "На прогулке")
    #expect(try mac.loadBoard(items: mac.loadIndex().items).board(board)?.freeItems.first(where: { $0.itemID == item })?.center == WorldPoint(x: 700, y: 99))
    #expect(try mac.incomingCursor(source: pair.sourceA) == reopenedPad.currentChangeCursor())
    #expect(try mac.workspaceHeader().workspaceID == pair.a.workspaceHeader().workspaceID)
  }

  @Test func directAndCloudDuplicatesPreserveTheTransactionAcrossRelays() throws {
    let pair = try Pair(), item = try pair.a.loadIndex().selectedItemID
    let seed = try upload(pair.a, source: pair.sourceA, account: pair.account)
    try receive(seed, to: pair.b, source: pair.sourceB, account: pair.account)
    try rename(pair.a, item: item, title: "Exactly once", actor: pair.actorA)
    let cloud = try upload(pair.a, source: pair.sourceA, account: pair.account)
    let delivery = try #require(cloud.compactMap(\.value.delivery).first)
    #expect(!delivery.isSnapshot)
    try stage(cloud, to: pair.b, source: pair.sourceB, account: pair.account); try assemble(pair.b, account: pair.account)
    let before = try pair.b.currentChangeCursor()
    #expect(try pair.b.applyDelivery(delivery) == delivery.change.sequence)
    try receive(Array(cloud.reversed()), to: pair.b, source: pair.sourceB, account: pair.account)
    #expect(try pair.b.currentChangeCursor() == before + 1)
    let relayed = try #require(pair.b.changeJournal(after: before).first)
    #expect(relayed.transactionID == delivery.change.transactionID)
    #expect(relayed.manifestHash == delivery.change.manifestHash)
    #expect(try pair.b.applyDelivery(delivery) == delivery.change.sequence)
    #expect(try pair.b.currentChangeCursor() == before + 1)
    // Returning the same transaction under the relay's stream is not authorship.
    _ = try pair.a.applyDelivery(.init(source: pair.sourceB, change: .init(sequence: 1, transactionID: relayed.transactionID, manifestHash: relayed.manifestHash, byteCount: relayed.byteCount)))
    #expect(try pair.a.currentChangeCursor() == delivery.change.sequence)
  }

  @Test func ownCloudEchoNeverCreatesAnInboxOrAnotherContribution() throws {
    let pair = try Pair(), item = try pair.a.loadIndex().selectedItemID
    let snapshot = try upload(pair.a, source: pair.sourceA, account: pair.account)
    try rename(pair.a, item: item, title: "Local tail", actor: pair.actorA)
    let tail = try upload(pair.a, source: pair.sourceA, account: pair.account)
    let cursor = try pair.a.currentChangeCursor()
    // Deliver the tail before the sender's own snapshot, including a restart.
    try receive(tail, to: pair.a, source: pair.sourceA, account: pair.account)
    let reopened = NotebookStore(root: pair.a.root)
    try receive(snapshot, to: reopened, source: pair.sourceA, account: pair.account)
    #expect(try reopened.sqlRead { try $0.rows("SELECT 1 FROM cloud_inbox").isEmpty })
    #expect(try reopened.currentChangeCursor() == cursor)
    #expect(try reopened.readItemHeader(item)?.title == "Local tail")
  }

  @Test func freshReplicaAdmitsHistoricalAbsenceWithoutCreatingAnUnknownBoardMember() throws {
    let pair = try Pair(), workspace = try pair.a.workspaceHeader()
    let absent = "board.json#/boards/@" + workspace.rootBoardID.uuidString.lowercased() + "/board/retired-collection/@absent"
    // The current board has no such owner. Only its immutable historical
    // removal remains, and a coherent snapshot must not resurrect or decode it.
    try pair.a.commandTransaction {
      try pair.a.currentSQL!.run("INSERT INTO change_records(sequence,address,blob_hash) VALUES(?,?,NULL)",
        [.integer(Int64(try pair.a.currentChangeCursor())), .text(absent)])
    }
    let cloud = try upload(pair.a, source: pair.sourceA, account: pair.account)
    let receiver = NotebookStore(root: pair.root.appendingPathComponent("empty-replica"))
    try receiver.prepareEmptyWorkspace(workspaceID: workspace.workspaceID)
    try receiver.prepareCloudStorage(); try receiver.enableCloud(account: pair.account, source: pair.sourceB)
    try receive(cloud, to: receiver, source: pair.sourceB, account: pair.account)
    #expect(try receiver.workspaceHeader().rootBoardID == workspace.rootBoardID)
    #expect(try receiver.incomingCursor(source: pair.sourceA) == pair.a.currentChangeCursor())
    #expect(try receiver.sqlRead { try $0.rows("SELECT 1 FROM records WHERE address=?", [.text(absent)]).isEmpty })
    #expect(try receiver.cloudInbox(account: pair.account).isEmpty)
  }

  @Test(arguments: [false, true])
  func boundConnectorsKeepTheirDependenciesAndIndependentFieldsAcrossCloud(board: Bool) throws {
    let pair = try Pair(), index = try pair.a.loadIndex()
    let target = try CollaborationTarget(kind: board ? .board : .page,
      id: board ? index.rootBoardID : #require(index.selectedPageID))
    func write(_ store: NotebookStore, actor: UUID, operations: [CollaborationOperation]) throws {
      let revision = try store.targetContentRevision(target: target)
      let action = try CollaborationAction(summary: "Cloud connector",
        references: [.init(target: target, revision: revision)],
        expected: [.init(target: target, revision: revision, inkRevision: store.inkRevision(on: target))],
        operations: operations)
      _ = try store.applyNativeAction(action, actor: actor)
    }
    func insert(_ id: String, graphic: NotebookGraphic, x: Double) throws -> CollaborationOperation {
      var values: [String: JSONValue] = ["kind": .string("graphic"), "source": .string(""),
        "graphic": try .encode(graphic), "frame": try .encode(PageRect(x: x, y: 100, width: 100, height: 100))]
      if board { values["worldOrigin"] = try .encode(WorldPoint.zero) }
      return .init(kind: .insertElement, target: target, id: id, values: values)
    }
    try write(pair.a, actor: pair.actorA, operations: [
      insert("a", graphic: .init(label: "A"), x: 100),
      insert("b", graphic: .init(label: "B"), x: 400),
      insert("edge", graphic: .init(shape: .connector, connection: .init(
        start: .init(point: .zero, binding: .init(elementID: "a")),
        end: .init(point: .init(x: 100, y: 1), binding: .init(elementID: "b")))), x: 250)
    ])
    let initial = try upload(pair.a, source: pair.sourceA, account: pair.account)
    try receive(Array(initial.reversed()), to: pair.b, source: pair.sourceB, account: pair.account)
    #expect(try pair.b.readGraphicResolution(target: target, elementID: "edge").layout != nil)
    func update(_ field: String, value: JSONValue) -> CollaborationOperation {
      .init(kind: .updateElement, target: target, id: "edge",
        values: ["graphic": .object(["connection": .object([field: value])])])
    }
    try write(pair.a, actor: pair.actorA, operations: [update("bend", value: .number(50))])
    try write(pair.b, actor: pair.actorB, operations: [update("endArrowhead", value: .string("diamond"))])
    let fromPad = try upload(pair.a, source: pair.sourceA, account: pair.account)
    let fromMac = try upload(pair.b, source: pair.sourceB, account: pair.account)
    try receive(Array(fromPad.reversed()), to: pair.b, source: pair.sourceB, account: pair.account)
    try receive(Array(fromMac.reversed()), to: pair.a, source: pair.sourceA, account: pair.account)
    let reopened = NotebookStore(root: pair.b.root)
    let graphic = try board ? reopened.readSpatialElement(boardID: target.id, elementID: "edge")?.graphic
      : reopened.readPageElement(pageID: target.id, elementID: "edge")?.graphic
    #expect(graphic?.connection?.bend == 50)
    #expect(graphic?.connection?.endArrowhead == .diamond)
    #expect(graphic?.connection?.start.binding?.elementID == "a")
    #expect(graphic?.connection?.end.binding?.elementID == "b")
    #expect(try reopened.readGraphicResolution(target: target, elementID: "edge")
      == pair.a.readGraphicResolution(target: target, elementID: "edge"))
    let cursor = try reopened.currentChangeCursor()
    for delivery in fromPad.compactMap(\.value.delivery) { _ = try reopened.applyDelivery(delivery) }
    #expect(try reopened.currentChangeCursor() == cursor)
  }

  @Test(arguments: [false, true])
  func snapshotRetainsDeletionEvenWithoutHistoricalDeliveryRows(freshReceiver: Bool) throws {
    let pair = try Pair(), index = try pair.a.loadIndex(), removed = index.selectedItemID, page = try #require(index.selectedPageID)
    let text = "CloudRetainedPageSource"
    var content = try pair.a.loadPage(page)
    let edited = content.replaceElements([.init(id: "retained", kind: .markdown,
      frame: .init(x: 10, y: 20, width: 240, height: 100), source: text, html: "<p>\(text)</p>")], actor: pair.actorA)
    #expect(edited)
    _ = try pair.a.savePage(content)
    #expect(try pair.a.search(text).total == 1)
    var next = index, tree = try pair.a.loadBoard(items: index.items)
    let creation = next.createNotebook(title: "Survivor", actor: pair.actorA, pageSize: .init(width: 834, height: 1194))
    let created = try #require(creation)
    _ = tree.addItem(created.item.id, to: index.rootBoardID, near: .zero, actor: pair.actorA)
    try pair.a.saveWorkspaceBundle(index: next, page: created.page, board: tree)
    _ = try pair.a.deleteWorkspaceItem(itemID: removed, actor: pair.actorA)
    // Prepared replicas can retain causal tombstones but start a fresh journal.
    try pair.a.commandTransaction { try pair.a.currentSQL!.run("DELETE FROM change_records") }
    let cloud = try upload(pair.a, source: pair.sourceA, account: pair.account)
    let receiver = freshReceiver ? NotebookStore(root: pair.root.appendingPathComponent("fresh")) : pair.b
    if freshReceiver {
      try receiver.prepareEmptyWorkspace(workspaceID: pair.a.workspaceHeader().workspaceID)
      try receiver.prepareCloudStorage()
      try receiver.enableCloud(account: pair.account, source: pair.sourceB)
    }
    try receive(cloud, to: receiver, source: pair.sourceB, account: pair.account)
    // Deletion retires public membership, not the admitted PAGE baseline:
    // late human fields and lifecycle undo must keep the same native owner.
    for store in [receiver, NotebookStore(root: receiver.root)] {
      #expect(try store.readItemHeader(removed) == nil)
      #expect(try store.ownerItemID(ofPage: page) == nil)
      #expect(try store.pageSourceOwnerID(ofPage: page) == removed)
      _ = try store.requireRetiredPageBaseline(pageID: page, itemID: removed)
      #expect(try store.storedMember(file: pageFile(page), collection: "elements", id: "retained")?
        .decode(AgentElement.self).source == text)
      #expect(throws: CocoaError(.fileNoSuchFile)) { _ = try store.loadPage(page) }
      #expect(throws: CollaborationError.self) { _ = try store.readContentHeader(target: .init(kind: .page, id: page)) }
      #expect(try store.search(text).total == 0)
    }
  }

  @Test func partialAssetsSurviveRestartAndNeverPublishPartialContent() throws {
    let pair = try Pair(), data = Data(repeating: 77, count: 2_300_000)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let chunkSize = NotebookCloudRecord.chunkBytes
    let last = try NotebookCloudRecord.chunk(hash: hash, offset: Int64(2 * chunkSize), totalBytes: Int64(data.count))
    try pair.b.stageCloudChunk(last, data: data.suffix(data.count - 2 * chunkSize), account: pair.account)
    #expect(try pair.b.nextCompleteCloudBlob(account: pair.account) == nil)
    let reopened = NotebookStore(root: pair.b.root)
    for offset in [chunkSize, 0] {
      let chunk = try NotebookCloudRecord.chunk(hash: hash, offset: Int64(offset), totalBytes: Int64(data.count))
      try reopened.stageCloudChunk(chunk, data: data.subdata(in: offset..<(offset + chunk.byteCount)), account: pair.account)
    }
    #expect(throws: NotebookStorageError.self) { try reopened.blobSize(hash: hash) }
    try assemble(reopened, account: pair.account)
    #expect(try reopened.blobSize(hash: hash) == data.count)
    #expect(try reopened.nextCompleteCloudBlob(account: pair.account) == nil)
  }

  @Test func commitFailureKeepsInboxAndContentAtTheirPreviousBoundary() throws {
    let pair = try Pair(), item = try pair.a.loadIndex().selectedItemID
    try rename(pair.a, item: item, title: "Atomic cloud", actor: pair.actorA)
    let cloud = try upload(pair.a, source: pair.sourceA, account: pair.account)
    try stage(cloud, to: pair.b, source: pair.sourceB, account: pair.account); try assemble(pair.b, account: pair.account)
    let delivery = try #require(pair.b.cloudInbox(account: pair.account).first)
    _ = try pair.b.missingBlobHashes(for: delivery.change)
    let original = try pair.b.readItemHeader(item)?.title
    let failing = NotebookStore(root: pair.b.root, storageFault: { if $0 == .beforeCommit { throw NotebookTransportError.disconnected } })
    #expect(throws: NotebookTransportError.self) { try failing.applyCloudDelivery(delivery, account: pair.account) }
    #expect(try pair.b.readItemHeader(item)?.title == original)
    #expect(try pair.b.incomingCursor(source: pair.sourceA) == 0)
    #expect(try pair.b.cloudInbox(account: pair.account).count == 1)
    try receive([], to: pair.b, source: pair.sourceB, account: pair.account)
    #expect(try pair.b.readItemHeader(item)?.title == "Atomic cloud")
  }

  @Test func disablingAndChangingAccountsCannotReuseAnOutboxAutomatically() throws {
    let pair = try Pair(), item = try pair.a.loadIndex().selectedItemID
    try pair.a.prepareCloudUpload(account: pair.account, source: pair.sourceA)
    let pending = try pair.a.cloudOutbox(account: pair.account)
    #expect(!pending.isEmpty)
    try pair.a.disableCloud()
    #expect(throws: NotebookTransportError.self) { try pair.a.cloudOutbox(account: pair.account) }
    try rename(pair.a, item: item, title: "Still local", actor: pair.actorA)
    #expect(try pair.a.readItemHeader(item)?.title == "Still local")
    #expect(try !pair.a.cloudConfiguration().enabled)
    // No code path binds a new account until this explicit human operation.
    try pair.a.enableCloud(account: "explicit-new-account", source: pair.sourceA)
    #expect(try pair.a.cloudOutbox(account: "explicit-new-account").isEmpty)
    #expect(throws: NotebookTransportError.self) { try pair.a.acknowledgeCloudRecords(pending.map(\.id), account: pair.account) }
    let other = try upload(pair.a, source: pair.sourceA, account: "explicit-new-account")
    #expect(other.compactMap(\.value.delivery).allSatisfy { $0.isSnapshot })
  }

  @Test func concurrentSameFieldUsesTheExistingMergerAndCloudBeforeLANIsIdempotent() throws {
    let pair = try Pair(), item = try pair.a.loadIndex().selectedItemID
    try rename(pair.a, item: item, title: "Pad choice", actor: pair.actorA)
    try rename(pair.b, item: item, title: "Mac choice", actor: pair.actorB)
    let expected = try pair.a.loadIndex().merging(pair.b.loadIndex())
    let fromPad = try upload(pair.a, source: pair.sourceA, account: pair.account)
    let fromMac = try upload(pair.b, source: pair.sourceB, account: pair.account)
    try receive(fromPad, to: pair.b, source: pair.sourceB, account: pair.account)
    try receive(fromMac, to: pair.a, source: pair.sourceA, account: pair.account)
    #expect(try pair.a.loadIndex().items == expected.items)
    #expect(try pair.b.loadIndex().items == expected.items)
    let delivery = try #require(fromPad.compactMap(\.value.delivery).first)
    let before = try pair.b.currentChangeCursor()
    _ = try pair.b.applyDelivery(delivery)
    #expect(try pair.b.currentChangeCursor() == before)
  }

  @Test func cloudCheckpointCoversTheRetiredWireFloorWithoutReplacingLocalState() throws {
    let pair = try Pair(), cursor = try pair.a.currentChangeCursor()
    try pair.a.commandTransaction {
      try pair.a.currentSQL!.run("INSERT INTO metadata(key,value) VALUES('placement_outgoing_floor',?)", [.text(String(cursor))])
    }
    #expect(throws: CollaborationError.self) { try pair.a.changeJournal(after: 0) }
    let cloud = try upload(pair.a, source: pair.sourceA, account: pair.account)
    try receive(cloud, to: pair.b, source: pair.sourceB, account: pair.account)
    #expect(try pair.b.incomingCursor(source: pair.sourceA) == cursor)
    #expect(try pair.b.loadIndex().items == pair.a.loadIndex().items)
  }

  @Test func snapshotCoversOldDeltasWithoutTheirIndividualReceipts() throws {
    let pair = try Pair(), item = try pair.a.loadIndex().selectedItemID
    let before = try pair.a.currentChangeCursor()
    try rename(pair.a, item: item, title: "Before checkpoint", actor: pair.actorA)
    let covered = try #require(pair.a.changeJournal(after: before).first)
    let cloud = try upload(pair.a, source: pair.sourceA, account: pair.account)
    try receive(cloud, to: pair.b, source: pair.sourceB, account: pair.account)
    let delivery = NotebookReplicationDelivery(source: pair.sourceA, change: covered)
    #expect(try !pair.b.deliveryNeedsContent(delivery))
    let cursor = try pair.b.currentChangeCursor()
    _ = try pair.b.applyDelivery(delivery)
    #expect(try pair.b.currentChangeCursor() == cursor)
    try rename(pair.a, item: item, title: "After checkpoint", actor: pair.actorA)
    let tail = try upload(pair.a, source: pair.sourceA, account: pair.account)
    try receive(tail, to: pair.b, source: pair.sourceB, account: pair.account)
    #expect(try pair.b.readItemHeader(item)?.title == "After checkpoint")
  }

  @Test func commitSucceededButAcknowledgementWasLostDoesNotRepeatTheEffect() throws {
    let pair = try Pair(), item = try pair.a.loadIndex().selectedItemID
    try rename(pair.a, item: item, title: "Committed before crash", actor: pair.actorA)
    let cloud = try upload(pair.a, source: pair.sourceA, account: pair.account)
    try stage(cloud, to: pair.b, source: pair.sourceB, account: pair.account); try assemble(pair.b, account: pair.account)
    let delivery = try #require(pair.b.cloudInbox(account: pair.account).first)
    _ = try pair.b.missingBlobHashes(for: delivery.change)
    let failing = NotebookStore(root: pair.b.root, storageFault: { if $0 == .afterCommit { throw NotebookTransportError.disconnected } })
    #expect(throws: NotebookTransportError.self) { try failing.applyCloudDelivery(delivery, account: pair.account) }
    let cursor = try pair.b.currentChangeCursor()
    #expect(try pair.b.readItemHeader(item)?.title == "Committed before crash")
    try receive(cloud, to: pair.b, source: pair.sourceB, account: pair.account)
    #expect(try pair.b.currentChangeCursor() == cursor)
    #expect(try pair.b.cloudInbox(account: pair.account).isEmpty)
  }

  @Test func generationsDoNotShareCursorsAndInstallingCloudPreservesExistingCursor() throws {
    let pair = try Pair()
    try pair.b.commandTransaction {
      try pair.b.currentSQL!.run("INSERT INTO peer_cursors VALUES(?,'incoming',17)", [.text(pair.actorA.uuidString.lowercased())])
    }
    #expect(try pair.b.admitReplicationSource(pair.sourceA) == 17)
    let restarted = NotebookReplicationSource(deviceID: pair.actorA, generation: UUID())
    #expect(try pair.b.admitReplicationSource(restarted) == 0)
    #expect(try pair.b.incomingCursor(source: pair.sourceA) == 17)
    #expect(try pair.b.peerCursor(peerID: pair.actorA, direction: .incoming) == 0)
    #expect(try pair.a.replicationSource(deviceID: pair.actorA) == pair.sourceA)
  }
}
