import NotebookCore
import UIKit
import XCTest
@testable import Notebook

/// Two real SQLite writers and the production TLS session, with the recipient's
/// real mounted scene. Loopback isolates application delay; it is NOT a Mac/iPad
/// radio or two-screen measurement. The sending owner has no rendered scene.
@MainActor
final class NotebookCollaborationLatencyTests: XCTestCase {
  func testReturningKnownChangeAcknowledgesItsPeerWithoutRebuildingTheScene() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("transport-echo-\(UUID())")
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let change = try XCTUnwrap(store.changeJournal(after: 0).first)
    let peer = NotebookReplicationSource(deviceID: UUID(), generation: UUID())
    _ = try store.admitReplicationSource(peer)
    let sceneCursor = model.sceneContentCursor, header = model.workspaceHeader
    let contentCursor = try store.currentChangeCursor()
    let received = try await model.applyDurableDelivery(.init(source: peer, change: change))
    let settled = await model.finishPendingPersistence(); XCTAssertTrue(settled)
    XCTAssertEqual(received, change.sequence)
    XCTAssertEqual(try store.incomingCursor(source: peer), change.sequence)
    XCTAssertEqual(try store.currentChangeCursor(), contentCursor)
    XCTAssertEqual(model.sceneContentCursor, sceneCursor,
      "A cursor-only ACK cannot schedule another scene read before the next peer edit")
    XCTAssertEqual(model.workspaceHeader, header)
  }

  func testCommittedTransportOffersAndBytesDoNotWaitBehindTheNextNativeWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("transport-read-\(UUID())")
    let store = NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!, persistenceQueue: queue)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let storage = try await model.makeTransportStorage()
    let change = try XCTUnwrap(store.changeJournal(after: 0).last)
    let pause = AsyncStream<Void>.makeStream()
    defer { pause.continuation.finish() }
    let later = queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> Int in
      for await _ in pause.stream { break }
      return { _ in 1 }
    })
    await Task.yield()
    XCTAssertGreaterThan(queue.pendingCount, 0)
    var received = false
    let start = ContinuousClock.now
    let read = Task {
      let offered = try await storage.changes(change.sequence - 1, 16)
      XCTAssertEqual(offered.first, change, "Committed content must be offered before its bytes can be requested")
      let result = try await storage.readBlobWindow([.init(hash: change.manifestHash)])
      received = true; return result
    }
    try await assertUX("committed-offer-and-bytes-during-native-preparation", since: start) { received }
    XCTAssertGreaterThan(queue.pendingCount, 0, "The read cannot obtain a fast result by releasing native preparation")
    pause.continuation.finish()
    let chunks = try await read.value, value = try await later.value
    XCTAssertEqual(chunks.first?.hash, change.manifestHash); XCTAssertEqual(value, 1)
  }

  func testHeadlessPeerChangeReachesIPadPixelsAndReturnsExactShownReceipt() async throws {
    let pair = try await fixture()
    var samples: [String] = []
    var measurements: [String: [Double]] = [:]
    defer { attach(samples, name: "peer-to-ipad-stages", measurements: measurements) }
    for index in 0..<10 {
      let id = UUID(), element = "peer-\(index)", x = 130.0 + Double(index) * 50
      let start = ContinuousClock.now
      let action = try await insert(pair, id: id, element: element, x: x)
      let version = try action.deliveryVersion(), revision = try XCTUnwrap(action.revisions.first).revision
      let cut = try pair.owner.store.currentChangeCursor()
      var stages = ["saved": start.duration(to: .now)]
      // A long diagnostic wait records the actual late result. It never changes
      // the per-stage ceilings or resets the clock after save/receive/render.
      while start.duration(to: .now) < .seconds(2), stages["shown-returned"] == nil || stages["pixels"] == nil {
        if let staged = pair.arrivals.cuts[cut] { stages["staged"] = start.duration(to: staged) }
        // Observe both durable ends in bounded read snapshots off main. A
        // measuring loop must not freeze the same actor that receives TLS and
        // installs the page; the clock still includes the entire awaited read.
        let padStore = pair.pad.store, ownerStore = pair.owner.store, deviceID = pair.pad.actorID
        let durable = try await Task.detached {
          let received = try padStore.readTransaction { store in
            try store.collaborationActionIfPresent(id)?.deliveryVersion() == version
          }
          let shown = try ownerStore.readTransaction { store in
            try store.deviceActionReceipts(actionIDs: [id]).contains {
              $0.deviceID == deviceID && $0.matches(action, version: version) && $0.displayComplete
            }
          }
          return (received, shown)
        }.value
        if stages["received"] == nil, durable.0 { stages["received"] = start.duration(to: .now) }
        if stages["installed"] == nil, pair.pad.activePage?.agentStamp.revision == revision,
          let page = pair.pad.activePage, pair.pad.pagePresentations.isPresented(page) {
          stages["installed"] = start.duration(to: .now)
        }
        if stages["installed"] != nil, stages["pixels"] == nil,
          try pair.scene.pixels([(.init(x: x + 15, y: 330), .red)]) {
          stages["pixels"] = start.duration(to: .now)
        }
        if stages["shown-returned"] == nil, durable.1 { stages["shown-returned"] = start.duration(to: .now) }
        try await Task.sleep(for: .milliseconds(16))
      }
      let identity = "sample=\(index),action=\(id),version=\(version),revision=\(revision)"
      samples.append(identity + "," + stages.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\(ms($0.value))ms" }.joined(separator: ","))
      for (stage, elapsed) in stages { measurements[stage, default: []].append(ms(elapsed)) }
      assertStage(stages["received"], ceiling: .milliseconds(100), identity + " received")
      assertStage(stages["pixels"], ceiling: .milliseconds(200), identity + " current pixels")
      assertStage(stages["shown-returned"], ceiling: .milliseconds(250), identity + " exact shown round trip")
      XCTAssertNil(pair.owner.compositionTiles.published, "iPad publication cannot require a source window or Mac rendering")
      guard stages["shown-returned"] != nil, stages["pixels"] != nil else {
        add(XCTAttachment(image: try NotebookUXObservation.Pixels(window: pair.scene.window).image))
        return // One missing result is a failure, not ten tests against an invalid fixture.
      }
    }
  }

  func testPencilLiftReachesTheHeadlessPeerWithoutWaitingForAnotherGesture() async throws {
    let pair = try await fixture()
    var samples: [String] = []
    var times: [Double] = []
    defer { attach(samples, name: "ipad-to-peer-ink", measurements: ["received": times]) }
    for index in 0..<10 {
      try await pair.scene.readyPencil(self)
      let y = 650.0 + Double(index) * 24
      pair.scene.beginPencil(.init(x: 160, y: y))
      pair.scene.movePencil(.init(x: 300, y: y))
      let start = ContinuousClock.now
      pair.scene.endPencil()
      pair.arrivals.record("pad.lift.\(index)", since: start)
      let page = try XCTUnwrap(pair.pad.activePage)
      let ink = try page.inkDrawing(), stroke = try XCTUnwrap(ink.actions.last)
      let revision = page.drawingStamp.revision
      var elapsed: Duration?
      while start.duration(to: .now) < .seconds(2) {
        let store = pair.owner.store, pageID = page.id
        let matches = try await Task.detached {
          try store.readTransaction { store in
            let delivered = try store.loadPage(pageID)
            guard delivered.drawingStamp.revision == revision else { return false }
            return try delivered.inkDrawing().actions.contains { $0.id == stroke.id && $0 == stroke }
          }
        }.value
        if matches { elapsed = start.duration(to: .now); break }
        try await Task.sleep(for: .milliseconds(5))
      }
      samples.append("sample=\(index),stroke=\(stroke.id),revision=\(revision),received=\(elapsed.map(ms) ?? -1)ms")
      if let elapsed { times.append(ms(elapsed)) }
      assertStage(elapsed, ceiling: .milliseconds(100), "Pencil lift → exact durable peer ink \(index)")
      XCTAssertEqual(pair.pad.activePage?.drawingStamp.revision, revision, "The returning echo cannot replace local ink")
      guard elapsed != nil else { return }
    }
  }

  func testIncomingIndependentPageChangeIsNotHeldBehindABoardContact() async throws {
    let pair = try await fixture()
    // The contact is on the root board; the remote change is in a page. Keep
    // the real admission owner active until AFTER the deadline, not before it.
    let board = try XCTUnwrap(pair.pad.workspace?.rootBoardID)
    pair.pad.updatePresence(.init(boardID: board, mode: .board, camera: .init(),
      viewport: .init(x: 834, y: 1194)), settled: true)
    let contact = UUID()
    XCTAssertTrue(pair.pad.inputGate.beginPencilAction(source: contact))
    defer { pair.pad.inputGate.endPencilAction(source: contact) }
    let id = UUID()
    let action = try await insert(pair, id: id, element: "independent", x: 160)
    let version = try action.deliveryVersion()
    let cut = try pair.owner.store.currentChangeCursor()
    let arrived = try await assertUX("independent-packet-staged", since: .now, budget: .seconds(2)) {
      pair.arrivals.cuts[cut] != nil
    }
    guard arrived.passed else { return }
    // Isolate admission AFTER TLS/hash staging. Otherwise a slow network could
    // fail the test before the packet even reached the alleged contact barrier.
    let start = try XCTUnwrap(pair.arrivals.cuts[cut])
    let result = try await assertUX("independent-delivery-during-contact", since: start, budget: .milliseconds(100)) {
      try pair.pad.store.collaborationActionIfPresent(id)?.deliveryVersion() == version
    }
    XCTAssertTrue(pair.pad.inputGate.hasActivePencil, "The test must not obtain a fast result by releasing the user's contact")
    if !result.passed {
      pair.pad.inputGate.endPencilAction(source: contact)
      // Establish the cause, not just a timeout: the same packet arrives after
      // lift without a retry, another command, or an explicit scene reload.
      try await assertUX("delivery-after-unblocking-contact", since: .now, budget: .seconds(2)) {
        try pair.pad.store.collaborationActionIfPresent(id)?.deliveryVersion() == version
      }
    }
  }

  func testIncomingSamePageChangeRetainsTheContactUntilItsAcceptedTailFinishes() async throws {
    let pair = try await fixture(), contact = UUID(), id = UUID()
    XCTAssertEqual(pair.pad.presence?.mode, .page)
    XCTAssertTrue(pair.pad.inputGate.beginPencilAction(source: contact))
    defer { pair.pad.inputGate.endPencilAction(source: contact) }
    let action = try await insert(pair, id: id, element: "same-page", x: 160)
    let version = try action.deliveryVersion(), cut = try pair.owner.store.currentChangeCursor()
    let arrived = try await assertUX("same-page-packet-staged", since: .now, budget: .seconds(2)) {
      pair.arrivals.cuts[cut] != nil
    }
    guard arrived.passed else { return }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(try pair.pad.store.collaborationActionIfPresent(id), "A blocked physical owner has no durable ACK")
    XCTAssertFalse(pair.pad.activePage?.elements.contains { $0.id == "same-page" } == true)
    XCTAssertTrue(pair.pad.inputGate.hasActivePencil)
    let start = ContinuousClock.now
    pair.pad.inputGate.endPencilAction(source: contact)
    try await assertUX("same-page-delivery-after-lift", since: start, budget: .milliseconds(100)) {
      try pair.pad.store.collaborationActionIfPresent(id)?.deliveryVersion() == version
    }
  }

  func testChatRoundTripDoesNotWaitForABlockedDurableCommit() async throws {
    let pair = try NotebookTransportTestPair(withChange: true, holdCommit: true)
    defer { pair.stop() }
    let blocked = expectation(description: "The bulk receive is inside its durable commit")
    await pair.serverStorage.setCommitObserver { blocked.fulfill() }
    try pair.start()
    await fulfillment(of: [blocked], timeout: 5)
    var replies: [UUID: ContinuousClock.Instant] = [:]
    pair.onTransient = { value, peer in
      guard case .codex(let envelope) = value else { return }
      switch envelope.body {
      case .request(.job(let input)):
        XCTAssertEqual(peer.deviceID, pair.clientIdentity.deviceID)
        pair.server?.sendTransient(.codex(.init(id: envelope.id, body: .reply(.job(.init(input: input))))))
      case .reply(.job): replies[envelope.id] = .now
      default: XCTFail("Unexpected control response")
      }
    }
    var samples: [String] = []
    var times: [Double] = []
    defer { attach(samples, name: "chat-under-backpressure", measurements: ["roundtrip": times]) }
    for index in 0..<10 {
      let input = NotebookChatInput(author: pair.clientIdentity.deviceID,
        action: .send(threadID: "10000000-0000-0000-0000-000000000001", text: "request-\(index)", context: ""))
      let envelope = NotebookChatEnvelope(body: .request(.job(input))), start = ContinuousClock.now
      XCTAssertTrue(envelope.isValid(from: pair.clientIdentity.deviceID))
      pair.client?.sendTransient(.codex(envelope))
      let deadline = start + .seconds(1)
      while replies[envelope.id] == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
      let elapsed = replies[envelope.id].map { start.duration(to: $0) }
      samples.append("sample=\(index),request=\(envelope.id),roundtrip=\(elapsed.map(ms) ?? -1)ms")
      if let elapsed { times.append(ms(elapsed)) }
      assertStage(elapsed, ceiling: .milliseconds(100), "Chat request/reply while bulk commit is held")
    }
    await pair.serverStorage.releaseCommit()
  }

  private struct Pair {
    let owner: NotebookAppModel
    let pad: NotebookAppModel
    let scene: NotebookInteractionUXTests.Scene
    let pageID: UUID
    let arrivals: Arrivals
  }

  @MainActor private final class Arrivals {
    var cuts: [UInt64: ContinuousClock.Instant] = [:]
    let start = ContinuousClock.now
    var stages: [String] = []
    func record(_ operation: String, since began: ContinuousClock.Instant, completed: ContinuousClock.Instant? = nil) {
      func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
      }
      let recorded = ContinuousClock.now, finished = completed ?? recorded
      stages.append("\(operation),start_ms=\(ms(start.duration(to: began))),elapsed_ms=\(ms(began.duration(to: finished))),record_delay_ms=\(ms(finished.duration(to: recorded)))")
    }
    func observing(_ original: NotebookTransportStorage, name: String) -> NotebookTransportStorage {
      var result = original
      result.changes = { cursor, limit in
        let began = ContinuousClock.now
        let changes = try await original.changes(cursor, limit)
        await self.record("\(name).offer.\(cursor).\(changes.count)", since: began, completed: .now)
        return changes
      }
      result.stageBlobs = { batch in
        let began = ContinuousClock.now
        try await original.stageBlobs(batch)
        await self.record("\(name).stageBlobs.\(batch.count).\(batch.reduce(Int64(0), { $0 + $1.byteCount }))", since: began)
      }
      result.prepareIncoming = { delivery, batch in
        let began = ContinuousClock.now
        let hashes = try await original.prepareIncoming(delivery, batch)
        await self.record("\(name).prepare.\(delivery.change.sequence).\(batch.count).\(hashes.count)", since: began)
        return hashes
      }
      result.readBlobWindow = { requests in
        let began = ContinuousClock.now
        let chunks = try await original.readBlobWindow(requests)
        await self.record("\(name).readBlobs.\(chunks.count).\(chunks.reduce(0) { $0 + $1.data.count })", since: began)
        return chunks
      }
      result.applyRemoteChange = { delivery in
        let began = ContinuousClock.now
        let cursor = try await original.applyRemoteChange(delivery)
        await self.record("\(name).apply.\(delivery.change.sequence)", since: began)
        return cursor
      }
      return result
    }
  }

  private func fixture() async throws -> Pair {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("collaboration-latency-\(UUID())")
    let a = NotebookStore(root: root.appendingPathComponent("source")), b = NotebookStore(root: root.appendingPathComponent("ipad"))
    let aWriter = NotebookPersistenceQueue(store: a), bWriter = NotebookPersistenceQueue(store: b)
    let owner = NotebookAppModel(store: a, startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!, persistenceQueue: aWriter)
    let pad = NotebookAppModel(store: b, startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!, persistenceQueue: bWriter)
    retainNotebookUntilTeardown(owner, removing: a.root); retainNotebookUntilTeardown(pad, removing: b.root)
    // Bootstrap only fresh fixture data; timed changes below use real TLS and
    // the app adapter. Never copy an installed container or historical archive.
    let header = try a.initializeWorkspace(actor: owner.actorID, pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(a.loadIndex().items.first), pageID = try XCTUnwrap(item.pageIDs.first)
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let source = try a.replicationSource(deviceID: owner.actorID)
    _ = try b.admitReplicationSource(source)
    for change in try a.changeJournal(after: 0) {
      while true {
        let hashes = try b.missingBlobHashes(for: change)
        if hashes.isEmpty { break }
        for hash in hashes {
          let size = try a.blobSize(hash: hash)
          XCTAssertLessThan(size, 64 * 1_024, "This fixture is a small ready-channel scenario, not bulk bootstrap")
          try b.stageBlob(data: a.readBlobChunk(hash: hash, offset: 0, maxBytes: Int(size)), expectedHash: hash)
        }
      }
      _ = try b.applyDelivery(.init(source: source, change: change))
    }
    await pad.start(pageSize: NotebookAppModel.defaultPageSize)
    let viewport = SpatialPoint(x: 834, y: 1194)
    let center = pad.boardHierarchy?.focusedCenter(of: item.id, in: header.rootBoardID) ?? .zero
    pad.updatePresence(.init(boardID: header.rootBoardID, mode: .page,
      camera: .init(center: center, scale: WorkspaceItemGeometry.notebook.fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: item.id, openProgress: 1), settled: true)
    pad.selectPenColor(.black); pad.selectPenWidth(12)
    // The root owns automatic collaboration detail preparation. Mounting just
    // SpatialWorkspaceView would omit that live path and fabricate a missing ACK.
    let window = try await mountNotebookScene(pad, fullRoot: true)
    let scene = try NotebookInteractionUXTests.Scene(model: pad, window: window)
    let arrivals = Arrivals()
    var receiving = try await arrivals.observing(pad.makeTransportStorage(), name: "pad")
    let apply = receiving.applyRemoteChange
    receiving.applyRemoteChange = { delivery in
      await MainActor.run { arrivals.cuts[delivery.change.sequence] = .now }
      return try await apply(delivery)
    }
    let pair = try await NotebookTransportTestPair(
      serverIdentity: .init(deviceID: owner.actorID, workspaceID: header.workspaceID, displayName: "Headless source"),
      clientIdentity: .init(deviceID: pad.actorID, workspaceID: header.workspaceID, displayName: "Mounted iPad"),
      contentBytes: 0, serverAdapter: arrivals.observing(owner.makeTransportStorage(), name: "peer"), clientAdapter: receiving)
    addTeardownBlock { @MainActor in
      let attachment = XCTAttachment(string: arrivals.stages.joined(separator: "\n"))
      attachment.name = "transport-storage-stages"; attachment.lifetime = .keepAlways; self.add(attachment)
    }
    let originalA = aWriter.onCommit, originalB = bWriter.onCommit
    aWriter.onCommit = { value in originalA?(value); pair.server?.notifyDurableChanges() }
    bWriter.onCommit = { value in originalB?(value); pair.client?.notifyDurableChanges() }
    pair.onFailure = { XCTFail("Production TLS failed: \($0)") }
    addTeardownBlock { @MainActor in
      aWriter.onCommit = originalA; bWriter.onCommit = originalB; pair.stop()
    }
    try pair.start()
    let ready = try await assertUX("trusted-channel-ready", since: .now, budget: .seconds(5)) {
      guard pair.server?.isReady == true, pair.client?.isReady == true else { return false }
      let receivedA = try b.peerCursor(peerID: owner.actorID, direction: .incoming) >= a.currentChangeCursor()
      let receivedB = try a.peerCursor(peerID: pad.actorID, direction: .incoming) >= b.currentChangeCursor()
      return receivedA && receivedB
    }
    guard ready.passed else { throw CollaborationError("fixture_not_ready", "The latency fixture never became ready") }
    return Pair(owner: owner, pad: pad, scene: scene, pageID: pageID, arrivals: arrivals)
  }

  private func insert(_ pair: Pair, id: UUID, element: String, x: Double) async throws -> CollaborationReceipt {
    let target = CollaborationTarget(kind: .page, id: pair.pageID), actor = pair.owner.actorID
    return try await pair.owner.performStoreCommand(publishesChanges: true) { store in
      try store.applyCollaborationAction(.init(id: id, summary: "Small visible peer edit", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
          .init(kind: .insertElement, target: target, id: element, values: ["kind": .string("graphic"), "source": .string(""),
            "frame": try .encode(PageRect(x: x, y: 280, width: 30, height: 100)),
            "graphic": try .encode(NotebookGraphic(shape: .rectangle, style: .init(fill: .init(red: 1, green: 0.2, blue: 0.1))))])]), actor: actor)
    }
  }

  private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
  }
  private func assertStage(_ elapsed: Duration?, ceiling: Duration, _ description: String,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNotNil(elapsed, "Missing evidence: \(description)", file: file, line: line)
    if let elapsed { XCTAssertLessThanOrEqual(elapsed, ceiling, "\(description): \(ms(elapsed)) ms", file: file, line: line) }
  }
  private func attach(_ samples: [String], name: String, measurements: [String: [Double]]) {
    let statistics = measurements.sorted(by: { $0.key < $1.key }).map { name, values -> String in
      let sorted = values.sorted()
      guard !sorted.isEmpty else { return "\(name): missing" }
      func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
      return "\(name): n=\(sorted.count), p50=\(percentile(0.5))ms, p95=\(percentile(0.95))ms, max=\(sorted.last!)ms"
    }
    let text = "Ready TLS loopback on physical iPad; window observation includes capture, not photon timing.\n"
      + (statistics + samples).joined(separator: "\n")
    print(text)
    let attachment = XCTAttachment(string: text); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
}
