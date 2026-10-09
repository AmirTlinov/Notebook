import Foundation
import Network
@testable import NotebookCore
import XCTest
@testable import Notebook

#if DEBUG
@MainActor
final class NotebookHistoryReadinessCoordinationTests: XCTestCase {
  func testTwoActualWritersConfirmExhaustiveHistoryThroughTLSAndResumeTheSameOwners() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-coordination-\(UUID())")
    let firstStore = NotebookStore(root: root.appendingPathComponent("first"))
    let secondStore = NotebookStore(root: root.appendingPathComponent("second"))
    let firstWriter = NotebookPersistenceQueue(store: firstStore), secondWriter = NotebookPersistenceQueue(store: secondStore)
    let firstSuite = "Notebook.HistoryCoordination.First.\(UUID())", secondSuite = "Notebook.HistoryCoordination.Second.\(UUID())"
    let firstPreferences = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
    let secondPreferences = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
    let firstOwner = makeHistoryFixtureWorkspace(store: firstStore, preferences: firstPreferences, persistence: firstWriter)
    let secondOwner = makeHistoryFixtureWorkspace(store: secondStore, preferences: secondPreferences, persistence: secondWriter)
    let first = firstOwner.workspaceRuntime, second = secondOwner.workspaceRuntime
    #if os(macOS)
      XCTAssertTrue(firstOwner is NotebookHeadlessWorkspace)
      XCTAssertTrue(secondOwner is NotebookHeadlessWorkspace)
      let physicalOwners = SceneRenderResources.shared.activePhysicalOwnerCount
      let webSurfaces = SceneRenderResources.shared.activeWebSurfaceCount
    #endif
    var listener: NWListener?
    var transports: [NearbySync] = []
    var accountServices: [HistoryCoordinationAccountService] = []
    func cleanup() async {
      listener?.cancel(); listener = nil
      for service in accountServices { service.releaseDirectoryRead() }
      let firstObserver = Task { await first.historyReadiness.stopAndJoin() }
      let secondObserver = Task { await second.historyReadiness.stopAndJoin() }
      await firstObserver.value; await secondObserver.value
      let firstStopped = await firstOwner.shutdown(), secondStopped = await secondOwner.shutdown()
      for transport in transports {
        let drained = await transport.stopAndDrain(); XCTAssertTrue(drained)
      }
      firstPreferences.removePersistentDomain(forName: firstSuite)
      secondPreferences.removePersistentDomain(forName: secondSuite)
      if firstStopped && secondStopped { try? FileManager.default.removeItem(at: root) }
      XCTAssertTrue(firstStopped, first.persistenceFailure ?? "First writer did not join")
      XCTAssertTrue(secondStopped, second.persistenceFailure ?? "Second writer did not join")
    }
    do {
      // Fresh test-only bootstrap follows the existing latency fixture. All
      // observed work below uses these two models' sole Queue/reader adapters.
      let header = try firstStore.initializeWorkspace(actor: first.actorID, pageSize: NotebookWorkspaceIdentity.defaultPageSize)
      try secondStore.prepareEmptyWorkspace(workspaceID: header.workspaceID)
      let initialSource = try firstStore.replicationSource(deviceID: first.actorID)
      _ = try secondStore.admitReplicationSource(initialSource)
      for change in try firstStore.changeJournal(after: 0) {
        var complete = false
        for _ in 0..<16 {
          let missing = try secondStore.missingBlobHashes(for: change)
          if missing.isEmpty { complete = true; break }
          for hash in missing {
            let size = try firstStore.blobSize(hash: hash)
            guard size <= 64 * 1_024 else { throw NotebookTransportError.resourceLimit }
            try secondStore.stageBlob(data: firstStore.readBlobChunk(hash: hash, offset: 0, maxBytes: Int(size)), expectedHash: hash)
          }
        }
        XCTAssertTrue(complete, "The small fresh bootstrap must resolve its actual immutable closure")
        guard complete else { throw NotebookTransportError.invalidBlob }
        _ = try secondStore.applyDelivery(.init(source: initialSource, change: change))
      }
      await firstOwner.start(pageSize: NotebookWorkspaceIdentity.defaultPageSize)
      await secondOwner.start(pageSize: NotebookWorkspaceIdentity.defaultPageSize)
      await firstOwner.finishStartup(); await secondOwner.finishStartup()
      let firstSaved = await firstOwner.finishPendingInteraction(), secondSaved = await secondOwner.finishPendingInteraction()
      XCTAssertTrue(firstSaved); XCTAssertTrue(secondSaved)
      XCTAssertEqual(first.admittedWorkspaceID, header.workspaceID)
      XCTAssertEqual(second.admittedWorkspaceID, header.workspaceID)
      _ = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

      let firstIdentity = NotebookTransportIdentity(deviceID: first.actorID, workspaceID: header.workspaceID, displayName: "First native fixture")
      let secondIdentity = NotebookTransportIdentity(deviceID: second.actorID, workspaceID: header.workspaceID, displayName: "Second native fixture")
      let firstDevice = NotebookAccountDirectory.Device(identity: firstIdentity, platform: .mac, activation: nil)
      let secondDevice = NotebookAccountDirectory.Device(identity: secondIdentity, platform: .iPad, activation: nil)
      let directory = HistoryCoordinationDirectory(workspaceID: header.workspaceID)
      try directory.value.enroll(firstDevice, retained: [], spaceName: "History fixture")
      try directory.value.enroll(secondDevice, retained: [], spaceName: "History fixture")
      let firstService = HistoryCoordinationAccountService(directory: directory)
      let secondService = HistoryCoordinationAccountService(directory: directory)
      accountServices = [firstService, secondService]
      let firstTrust = HistoryCoordinationTrust(device: firstDevice, directory: directory)
      let secondTrust = HistoryCoordinationTrust(device: secondDevice, directory: directory)
      let firstStorage = try await first.connection.makeTransportStorage(), secondStorage = try await second.connection.makeTransportStorage()
      let firstSync = NearbySync(role: .macListener, identity: firstIdentity, storage: firstStorage,
        stagingRoot: firstStore.root.appendingPathComponent("transfer-staging"), trustStore: firstTrust)
      let secondSync = NearbySync(role: .iPadConnector, identity: secondIdentity, storage: secondStorage,
        stagingRoot: secondStore.root.appendingPathComponent("transfer-staging"), trustStore: secondTrust)
      transports = [firstSync, secondSync]
      var observedSeals: Set<UUID> = [], receivedRoots: [UUID: Int] = [:]
      func bind(_ runtime: NotebookWorkspaceRuntime, writer: NotebookPersistenceQueue, sync: NearbySync,
        service: HistoryCoordinationAccountService) {
        runtime.connection.startFixture(sync, service: service)
        // Observe the production callback rather than reimplementing its
        // readiness/connection fanout in this fixture.
        let receive = sync.onHistoryControl
        sync.onHistoryControl = { [weak runtime] control, peer, generation in
          guard let runtime else { return }
          if case .sealed(let request, let seal) = runtime.historyReadiness.phase {
            XCTAssertTrue(writer.ownsWorkspaceSelectionSeal(seal))
            XCTAssertTrue(runtime.ownsHistoryWriterSeal(request: request, seal: seal))
            observedSeals.insert(runtime.actorID)
          }
          if case .root = control { receivedRoots[runtime.actorID, default: 0] += 1 }
          receive?(control, peer, generation)
        }
      }
      await firstSync.start(); await secondSync.start()
      firstSync.browser?.cancel(); secondSync.browser?.cancel()
      bind(first, writer: firstWriter, sync: firstSync, service: firstService)
      bind(second, writer: secondWriter, sync: secondSync, service: secondService)
      try await waitUntil("Both actual account owners install the directory's same saved credential") {
        first.connection.accountConnection?.status == .ready && second.connection.accountConnection?.status == .ready
      }
      let firstAccount = try XCTUnwrap(first.connection.accountConnection), secondAccount = try XCTUnwrap(second.connection.accountConnection)
      let firstCredential = try XCTUnwrap(firstSync.savedTrust.records.first)
      let secondCredential = try XCTUnwrap(secondSync.savedTrust.records.first)
      XCTAssertEqual(firstCredential.credentialID, secondCredential.credentialID)
      XCTAssertEqual(firstCredential.secret, secondCredential.secret)
      let originalFirstTrust = firstSync.savedTrust, originalSecondTrust = secondSync.savedTrust
      let tlsListener = try NWListener(using: NotebookTransportTLS.parameters(keys: [firstCredential.tlsKey], loopback: true))
      listener = tlsListener
      tlsListener.newConnectionHandler = { [weak firstSync, weak first] connection in
        Task { @MainActor in
          guard let firstSync, let first, first.shutdownPhase == .running else { connection.cancel(); return }
          firstSync.addSession(connection: connection, credential: nil)
        }
      }
      tlsListener.start(queue: DispatchQueue(label: "Notebook.HistoryCoordination.Loopback"))
      try await waitUntil("Loopback TLS listener has a real endpoint") { tlsListener.port != nil && tlsListener.port != .any }
      let port = try XCTUnwrap(tlsListener.port)
      let credential = NotebookPeerCredential(credentialID: secondCredential.credentialID,
        secret: secondCredential.secret, expectedPeer: firstIdentity)
      secondSync.addSession(connection: NWConnection(host: "127.0.0.1", port: port,
        using: try NotebookTransportTLS.parameters(keys: [credential.tlsKey], loopback: true)), credential: credential)
      try await waitUntil("Both actual TLS sessions are selected and authenticated") {
        firstSync.historyBoundaryObservation(for: second.actorID)?.remoteSource?.deviceID == second.actorID
          && secondSync.historyBoundaryObservation(for: first.actorID)?.remoteSource?.deviceID == first.actorID
      }
      let firstConnection = try XCTUnwrap(firstSync.historyBoundaryObservation(for: second.actorID)).connectionID
      let secondConnection = try XCTUnwrap(secondSync.historyBoundaryObservation(for: first.actorID)).connectionID
      XCTAssertTrue(try first.historyTransportOwner() === firstSync)
      XCTAssertTrue(try second.historyTransportOwner() === secondSync)
      let firstBorn = try await createHistoryFixtureItem(first, kind: .board, at: .zero), secondBorn = try await createHistoryFixtureItem(second, kind: .board, at: .init(x: 500, y: 0))
      let firstItem = try XCTUnwrap(firstBorn), secondItem = try XCTUnwrap(secondBorn)
      let firstTail = await firstOwner.finishPendingInteraction(), secondTail = await secondOwner.finishPendingInteraction()
      XCTAssertTrue(firstTail); XCTAssertTrue(secondTail)
      let firstRead = try await first.observeHistorySource { try $0.replicaInventoryCut() }
      let secondRead = try await second.observeHistorySource { try $0.replicaInventoryCut() }
      secondService.holdNextDirectoryRead()
      let requestID = UUID()
      let queued = try first.historyReadiness.handle(.init(operation: .start, requestID: requestID,
        deviceIDs: [first.actorID, second.actorID]), runtime: first)
      XCTAssertEqual(queued["state"]?.stringValue, "queued")
      try await waitUntil("The prepared frame enters the same TLS session while its native directory read is held") {
        secondService.directoryReadIsHeld
          && secondSync.historyBoundaryObservation(for: first.actorID)?.peerPrepared?.requestID == requestID
      }
      XCTAssertNil(second.historyReadiness.coordination?.failure)
      XCTAssertEqual(secondSync.historyBoundaryObservation(for: first.actorID)?.connectionID, secondConnection)
      XCTAssertNotNil(second.historyReadiness.coordination?.task)
      secondService.releaseDirectoryRead()
      try await waitUntil("Both real coordinators complete the same request, including explicit resume", seconds: 30) {
        first.historyReadiness.coordination?.id == requestID && second.historyReadiness.coordination?.id == requestID
          && first.historyReadiness.coordination?.task == nil && second.historyReadiness.coordination?.task == nil
      }
      let firstResult = try XCTUnwrap(first.historyReadiness.coordination), secondResult = try XCTUnwrap(second.historyReadiness.coordination)
      XCTAssertEqual(firstResult.state, "completed", String(describing: firstResult.value()))
      XCTAssertEqual(secondResult.state, "completed", String(describing: secondResult.value()))
      XCTAssertNil(firstResult.failure); XCTAssertNil(secondResult.failure)
      XCTAssertEqual(firstResult.scope, secondResult.scope)
      XCTAssertTrue(firstResult.localRootsSent); XCTAssertTrue(secondResult.localRootsSent)
      XCTAssertEqual(firstResult.confirmed.count, 6); XCTAssertEqual(secondResult.confirmed.count, 6)
      XCTAssertEqual(observedSeals, [first.actorID, second.actorID])
      XCTAssertEqual(receivedRoots[first.actorID], 6); XCTAssertEqual(receivedRoots[second.actorID], 6)
      let firstReport = try XCTUnwrap(firstResult.report), secondReport = try XCTUnwrap(secondResult.report)
      XCTAssertEqual(firstReport["acceptedAndPhysicalMetadataMatched"], .bool(true))
      XCTAssertEqual(secondReport["acceptedAndPhysicalMetadataMatched"], .bool(true))
      let jointHash = try XCTUnwrap(firstReport["jointSHA256"]?.stringValue)
      XCTAssertEqual(jointHash.count, 64)
      XCTAssertEqual(jointHash, secondReport["jointSHA256"]?.stringValue)
      XCTAssertEqual(firstReport["roots"]?.arrayValues.count, 12)
      XCTAssertEqual(secondReport["roots"]?.arrayValues.count, 12)
      XCTAssertEqual(firstReport["local"]?["readerLifetimeID"]?.stringValue, firstRead.connectionLifetimeID.uuidString)
      XCTAssertEqual(secondReport["local"]?["readerLifetimeID"]?.stringValue, secondRead.connectionLifetimeID.uuidString)
      XCTAssertEqual(firstReport["formatTransitionAuthorized"], .bool(false))
      XCTAssertEqual(secondReport["formatTransitionAuthorized"], .bool(false))
      let actualHistory = try await first.observeHistorySource { query in
        let page = try query.actionHistoryOccurrencePage(afterTransactionID: nil, limit: 64)
        guard page.next == nil else { throw NotebookTransportError.resourceLimit }
        return UInt64(page.occurrences.count)
      }
      XCTAssertGreaterThan(actualHistory.value, 0)
      for report in [firstReport, secondReport] {
        XCTAssertEqual(report["local"]?["counters"]?["acceptedTransactions"]?.stringValue, String(actualHistory.value))
        for row in report["roots"]?.arrayValues ?? [] where ["acceptedTransactions", "physicalClosures", "sourceOriginalRoots"].contains(row["stream"]?.stringValue ?? "") {
          XCTAssertEqual(row["entryCount"]?.stringValue, String(actualHistory.value))
        }
      }
      let scope = try XCTUnwrap(firstResult.scope)
      for (model, peer, sync, writer) in [(first, second, firstSync, firstWriter), (second, first, secondSync, secondWriter)] {
        let boundary = try XCTUnwrap(sync.historyBoundaryObservation(for: peer.actorID))
        XCTAssertEqual(boundary.peerAcceptedThrough, scope.endpoint(for: model.actorID)?.through)
        XCTAssertEqual(boundary.incomingAcceptedThrough, scope.endpoint(for: peer.actorID)?.through)
        XCTAssertEqual(boundary.pendingDurableWork, 0); XCTAssertFalse(boundary.hasStorageCallback)
        XCTAssertTrue(writer.permitsNewWorkspaceMutation)
        XCTAssertEqual(model.historyReadiness.phase, .open); XCTAssertTrue(model.permitsAuthoredWork)
        let itemIDs = Set(try model.store.loadIndex().items.map(\.id))
        XCTAssertTrue(itemIDs.contains(firstItem)); XCTAssertTrue(itemIDs.contains(secondItem))
      }
      XCTAssertTrue(first.connection.accountConnection === firstAccount); XCTAssertTrue(second.connection.accountConnection === secondAccount)
      XCTAssertEqual(firstSync.savedTrust.records, originalFirstTrust.records)
      XCTAssertEqual(secondSync.savedTrust.records, originalSecondTrust.records)
      XCTAssertEqual(firstSync.savedTrust.account, originalFirstTrust.account)
      XCTAssertEqual(secondSync.savedTrust.account, originalSecondTrust.account)
      XCTAssertEqual(firstSync.historyBoundaryObservation(for: second.actorID)?.connectionID, firstConnection)
      XCTAssertEqual(secondSync.historyBoundaryObservation(for: first.actorID)?.connectionID, secondConnection)
      let resumedBirth = try await createHistoryFixtureItem(first, kind: .board, at: .init(x: 1000, y: 0))
      let resumedItem = try XCTUnwrap(resumedBirth)
      let resumedSaved = await firstOwner.finishPendingInteraction(); XCTAssertTrue(resumedSaved)
      try await waitUntil("The same resumed TLS owner delivers the next accepted native creation") {
        try second.store.readItemHeader(resumedItem) != nil
      }
      XCTAssertTrue(try first.historyTransportOwner() === firstSync)
      XCTAssertTrue(try second.historyTransportOwner() === secondSync)
      let attachment = XCTAttachment(data: try JSONEncoder().encode(firstReport), uniformTypeIdentifier: "public.json")
      attachment.name = "history-coordination-metadata-only"; attachment.lifetime = .keepAlways; add(attachment)

      // A storage failure retains one accepted author and its original queue.
      // Readiness must refuse that unfinished prefix without replacing the
      // headless reader, trust or selected TLS session; Retry saves that author.
      let retryEnabled = NotebookPersistenceFenceContract.Signal<Bool>()
      defer { retryEnabled.set(true); first.retryPendingPersistence() }
      let originalReader = first.commandReader, originalTransportReader = first.connection.transportReader
      let retryPlan = try NotebookNativeItemCreation(kind: .board, workspaceID: header.workspaceID,
        boardID: header.rootBoardID, center: .init(x: 1500, y: 0), actor: first.actorID)
      let retryCommand = retryPlan.command()
      let accepted = Task {
        try await firstWriter.submit(publishesChanges: true) { store in
          guard retryEnabled.value == true else { throw CocoaError(.fileWriteNoPermission) }
          return try retryCommand.apply(to: store)
        }
      }
      try await waitUntil("The original accepted writer reports the actual storage fault") { firstWriter.failure != nil }
      let failedPrefix = await firstWriter.flush(); XCTAssertFalse(failedPrefix)
      let blockedID = UUID()
      _ = try first.historyReadiness.handle(.init(operation: .start, requestID: blockedID,
        deviceIDs: [first.actorID, second.actorID]), runtime: first)
      try await waitUntil("Readiness refuses the unsaved prefix and releases both original owners") {
        first.historyReadiness.coordination?.id == blockedID && first.historyReadiness.coordination?.task == nil
          && second.historyReadiness.coordination?.task == nil
      }
      XCTAssertNotNil(first.historyReadiness.coordination?.failure)
      XCTAssertEqual(first.historyReadiness.phase, .open)
      XCTAssertTrue(first.persistence === firstWriter)
      XCTAssertTrue(first.commandReader === originalReader)
      XCTAssertTrue(first.connection.transportReader === originalTransportReader)
      XCTAssertTrue(try first.historyTransportOwner() === firstSync)
      XCTAssertEqual(firstSync.historyBoundaryObservation(for: second.actorID)?.connectionID, firstConnection)
      retryEnabled.set(true); first.retryPendingPersistence()
      _ = try await accepted.value
      let recovered = try await first.observeHistorySource { try $0.replicaInventoryCut() }
      XCTAssertEqual(recovered.connectionLifetimeID, firstRead.connectionLifetimeID)
      XCTAssertNotNil(try firstStore.readItemHeader(retryPlan.itemID))
      try await waitUntil("The same TLS session delivers the retained author after explicit Retry") {
        try secondStore.readItemHeader(retryPlan.itemID) != nil
      }
      XCTAssertEqual(firstSync.historyBoundaryObservation(for: second.actorID)?.connectionID, firstConnection)
      #if os(macOS)
        XCTAssertEqual(SceneRenderResources.shared.activePhysicalOwnerCount, physicalOwners)
        XCTAssertEqual(SceneRenderResources.shared.activeWebSurfaceCount, webSurfaces)
      #endif

      // Damage one actual accepted raw manifest only on the responder, through
      // its sole queue before observation. Prefix/UUID facts remain authentic;
      // the physical resolver must reject the mismatching immutable bytes.
      try await waitUntil("Both resumed owners have joined the preceding actual delivery") {
        let a = firstSync.historyBoundaryObservation(for: second.actorID)
        let b = secondSync.historyBoundaryObservation(for: first.actorID)
        return a?.pendingDurableWork == 0 && b?.pendingDurableWork == 0
          && a?.hasStorageCallback == false && b?.hasStorageCallback == false
      }
      let poisoned = try await second.observeHistorySource { query in
        let page = try query.actionHistoryOccurrencePage(limit: 64)
        guard let first = page.occurrences.first, page.next == nil else { throw NotebookTransportError.resourceLimit }
        return (first.transactionID, first.manifestHash)
      }
      let poisonedTransaction = poisoned.value.0, poisonedHash = poisoned.value.1
      let originalBytes = try await second.persistence.submit(writesStore: true) { store in
        try Self.replaceFixtureBlob(store: store, hash: poisonedHash, bytes: Data("damaged-history-manifest".utf8))
      }
      // The second directory observation is the actual post-seal fleet read.
      // Keep it suspended until the initiator's nonempty source really crosses
      // TLS; this is not a source-failure injection or another reader.
      secondService.holdNextDirectoryRead(after: 1)
      let refusedID = UUID()
      _ = try first.historyReadiness.handle(.init(operation: .start, requestID: refusedID,
        deviceIDs: [first.actorID, second.actorID]), runtime: first)
      try await waitUntil("The responder holds its actual sealed fleet read while receiving the initiator's pages") {
        guard secondService.directoryReadIsHeld,
          case .sealed = second.historyReadiness.phase,
          let responder = second.historyReadiness.coordination, responder.id == refusedID else { return false }
        return (responder.remote[.acceptedTransactions]?.entryCount ?? 0) > 0
      }
      XCTAssertNil(first.historyReadiness.coordination?.value()["report"],
        "A local source cannot publish success before its peer's actual source/comparison terminates")
      secondService.releaseDirectoryRead()
      try await waitUntil("The ordered source refusal joins both native owners without replacing TLS", seconds: 30) {
        first.historyReadiness.coordination?.id == refusedID && second.historyReadiness.coordination?.id == refusedID
          && first.historyReadiness.coordination?.task == nil && second.historyReadiness.coordination?.task == nil
      }
      let refusedFirst = try XCTUnwrap(first.historyReadiness.coordination)
      let refusedSecond = try XCTUnwrap(second.historyReadiness.coordination)
      let received = try XCTUnwrap(refusedFirst.failure as? NotebookHistoryControl.Refusal)
      XCTAssertEqual(received.origin.deviceID, second.actorID)
      XCTAssertEqual(received.origin.generation, secondSync.historyBoundaryObservation(for: first.actorID)?.localSource?.generation)
      XCTAssertEqual(received.code, .blobHashMismatch); XCTAssertEqual(received.reason, .blobHashMismatch)
      XCTAssertEqual(received.stage, .reading); XCTAssertEqual(received.sourceSection, .acceptedPhysicalHistory)
      XCTAssertEqual(received.transactionID, poisonedTransaction)
      XCTAssertEqual(refusedFirst.firstCause?.originDeviceID, second.actorID)
      XCTAssertEqual(refusedSecond.firstCause?.originDeviceID, second.actorID)
      XCTAssertEqual(refusedFirst.state, "failed"); XCTAssertEqual(refusedSecond.state, "failed")
      XCTAssertFalse(refusedSecond.localRootsSent)
      XCTAssertNil(refusedFirst.report); XCTAssertNil(refusedFirst.value()["report"])
      XCTAssertNil(refusedSecond.report); XCTAssertNil(refusedSecond.value()["report"])
      XCTAssertEqual(refusedFirst.value()["peerStreams"]?.arrayValues.count, 6)
      XCTAssertEqual(refusedFirst.value()["firstCause"]?["originDeviceID"]?.stringValue, second.actorID.uuidString)
      XCTAssertEqual(refusedFirst.value()["firstCause"]?["stage"]?.stringValue, "reading")
      XCTAssertEqual(first.historyReadiness.phase, .open); XCTAssertEqual(second.historyReadiness.phase, .open)
      XCTAssertTrue(try first.historyTransportOwner() === firstSync); XCTAssertTrue(try second.historyTransportOwner() === secondSync)
      XCTAssertEqual(firstSync.historyBoundaryObservation(for: second.actorID)?.connectionID, firstConnection)
      XCTAssertEqual(secondSync.historyBoundaryObservation(for: first.actorID)?.connectionID, secondConnection)
      _ = try await second.persistence.submit(writesStore: true) { store in
        try Self.replaceFixtureBlob(store: store, hash: poisonedHash, bytes: originalBytes)
      }

      // A real cancellation refusal precedes socket teardown. The disconnect
      // must retain that first cause on this same native coordinator.
      secondService.holdNextDirectoryRead()
      let cancelledID = UUID()
      _ = try first.historyReadiness.handle(.init(operation: .start, requestID: cancelledID,
        deviceIDs: [first.actorID, second.actorID]), runtime: first)
      try await waitUntil("The second real request reaches the held responder") {
        secondService.directoryReadIsHeld
          && secondSync.historyBoundaryObservation(for: first.actorID)?.peerPrepared?.requestID == cancelledID
      }
      let cancelled = try XCTUnwrap(second.historyReadiness.coordination)
      let preparation = try XCTUnwrap(first.historyReadiness.coordination?.preparation)
      try firstSync.resumeHistoryPreparation(preparation)
      try await waitUntil("The ordered cancellation reaches the existing native receiver") {
        cancelled.failure as? NotebookTransportError == .historyCutStale
      }
      let disconnected = await secondSync.stopAndDrain(); XCTAssertTrue(disconnected)
      XCTAssertEqual(cancelled.failure as? NotebookTransportError, .historyCutStale,
        "Socket teardown must preserve the earlier semantic history refusal")
      secondService.releaseDirectoryRead()
      await first.historyReadiness.stopAndJoin(); await second.historyReadiness.stopAndJoin()
      XCTAssertEqual(first.historyReadiness.phase, .open); XCTAssertEqual(second.historyReadiness.phase, .open)
    } catch { await cleanup(); throw error }
    await cleanup()
  }

  private func waitUntil(_ reason: String, seconds: Int = 10, _ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let ready = try condition()
    XCTAssertTrue(ready, reason)
    guard ready else { throw NotebookTransportError.historyNotDrained }
  }

  /// Called only inside this isolated model's actual serial queue. No runtime
  /// corruption hook or second writer owner is added to the application.
  nonisolated private static func replaceFixtureBlob(store: NotebookStore, hash: String, bytes: Data) throws -> Data {
    guard let database = store.currentSQL, database.writable, bytes.count <= 65_536 else {
      throw NotebookStorageError.readOnlyTransaction
    }
    guard let original = try database.rows(
      "SELECT CASE WHEN typeof(data)='blob' AND length(data)<=65536 THEN data END FROM blobs WHERE hash=?",
      [.text(hash)]).first?[0].blob else { throw NotebookStorageError.blobMissing(hash) }
    try database.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(bytes), .text(hash)])
    return original
  }
}

@MainActor private final class HistoryCoordinationTrust: NotebookDeviceTrustStore {
  private var state: NotebookDeviceTrustState
  init(device: NotebookAccountDirectory.Device, directory: HistoryCoordinationDirectory) {
    state = .init(account: directory.account, records: directory.value.credentials(for: device).map {
      .init(identity: $0.0.identity, credentialID: $0.1.id, secret: $0.1.secret)
    })
  }
  func load(for identity: NotebookTransportIdentity) async throws -> NotebookDeviceTrustState {
    try state.validate(for: identity); return state
  }
  func save(_ state: NotebookDeviceTrustState, for identity: NotebookTransportIdentity) async throws {
    try state.validate(for: identity); self.state = state
  }
}

@MainActor private final class HistoryCoordinationDirectory {
  let account = "history-coordination-fixture"
  var value: NotebookAccountDirectory
  init(workspaceID: UUID) { value = .init(space: .init(id: workspaceID, name: "History fixture")) }
}

@MainActor private final class HistoryCoordinationAccountService: NotebookAccountService {
  private let directory: HistoryCoordinationDirectory
  private var holdsNextDirectoryRead = false
  private var directoryReadsBeforeHold = 0
  private var directoryRead: CheckedContinuation<Void, Never>?
  var directoryReadIsHeld: Bool { directoryRead != nil }
  init(directory: HistoryCoordinationDirectory) { self.directory = directory }
  func holdNextDirectoryRead(after reads: Int = 0) {
    precondition(directoryRead == nil)
    precondition(reads >= 0)
    directoryReadsBeforeHold = reads
    holdsNextDirectoryRead = true
  }
  func releaseDirectoryRead() {
    holdsNextDirectoryRead = false
    let pending = directoryRead; directoryRead = nil; pending?.resume()
  }
  func exchange(device: NotebookAccountDirectory.Device, boundAccount: String?,
    retained: [NotebookAccountDirectory.Pair], spaceName: String, publishName: Bool) async throws -> NotebookAccountSnapshot {
    guard boundAccount == nil || boundAccount == directory.account else { throw NotebookAccountError.changed }
    try directory.value.enroll(device, retained: retained, spaceName: spaceName)
    return .init(account: directory.account, directory: directory.value)
  }
  func initialWorkspace(proposed: UUID) async throws -> UUID { directory.value.defaultSpaceID ?? proposed }
  func spaces(boundAccount: String?) async throws -> NotebookAccountSnapshot? {
    guard boundAccount == nil || boundAccount == directory.account else { throw NotebookAccountError.changed }
    if holdsNextDirectoryRead {
      if directoryReadsBeforeHold > 0 { directoryReadsBeforeHold -= 1 }
      else {
        holdsNextDirectoryRead = false
        await withCheckedContinuation { directoryRead = $0 }
      }
    }
    try Task.checkCancellation()
    return .init(account: directory.account, directory: directory.value)
  }
  func observe(changed: @escaping @Sendable (Bool) async -> Void) async throws { }
  func stop() async { }
}
#endif
