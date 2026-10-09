import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookHistoryReadinessSourceTests: XCTestCase {
  func testUnsealedAndRetiredRequestCannotEmitFromTheExistingRuntimeReader() async throws {
    let runtime = try await makeRuntime()
    let initial = try await runtime.observeHistorySource { try $0.replicaInventoryCut() }
    let scope = makeScope(runtime: runtime, cut: initial.value)
    let request = NotebookHistoryReadiness.Request(id: scope.requestID, workspaceID: scope.workspaceID,
      devices: Set(scope.endpoints.map { $0.identity.deviceID }), acceptedGeneration: 0)
    let fleet = try NotebookHistoryFleetObservation(local: scope.endpoint(for: runtime.actorID)!.identity,
      trust: .init(), directory: nil, directoryStatus: .missing, locallyRetired: [], connections: [])
    var witnessed = 0, sent = 0
    let witness = NotebookHistoryFleetWitness(observation: fleet) { witnessed += 1 }

    // A real runtime/reader is available, but neither an open nor a merely
    // draining phase owns its writer seal. A retired request cannot be revived.
    for step in 0..<3 {
      if step == 1 { try runtime.historyReadiness.begin(request) }
      if step == 2 {
        try runtime.historyReadiness.finish(request) { _ in XCTFail("No seal was acquired") }
      }
      do {
        _ = try await runtime.historyReadiness.produceSource(runtime: runtime, request: request,
          scope: scope, fleetWitness: witness) { _ in sent += 1 }
        XCTFail("An unsealed request emitted source evidence")
      } catch let error as NotebookHistoryReadiness.SourceError {
        XCTAssertEqual(error.reason, .phaseChanged)
        XCTAssertEqual(error.section, .acceptedPhysicalHistory)
        XCTAssertNil(error.transactionID)
        XCTAssertNil(error.underlying)
      }
    }
    let after = try await runtime.observeHistorySource { try $0.replicaInventoryCut() }
    XCTAssertEqual(after.connectionLifetimeID, initial.connectionLifetimeID)
    XCTAssertEqual(after.value.controlObservation, initial.value.controlObservation)
    XCTAssertEqual(runtime.historyReadiness.phase, .open)
    XCTAssertEqual(witnessed, 0); XCTAssertEqual(sent, 0)
  }

  func testSourceAnchorNamesTheActualAcceptedRevisionBeforeItsAggregateControlHash() async throws {
    let runtime = try await makeRuntime()
    let initial = try await runtime.observeHistorySource { try $0.replicaInventoryCut() }
    let created = try await createHistoryFixtureItem(runtime, kind: .notebook(NotebookWorkspaceIdentity.defaultPageSize), at: .zero)
    XCTAssertNotNil(created)
    let current = try await runtime.observeHistorySource { try $0.replicaInventoryCut() }
    XCTAssertEqual(current.connectionLifetimeID, initial.connectionLifetimeID)
    XCTAssertNotEqual(current.value.readRevision, initial.value.readRevision)
    XCTAssertNotEqual(current.value.controlObservation, initial.value.controlObservation)
    XCTAssertEqual(NotebookHistoryReadiness.sourceAnchorMismatch(current.value, expected: initial.value), .revisionChanged)
    XCTAssertNil(NotebookHistoryReadiness.sourceAnchorMismatch(current.value, expected: current.value))
  }

  func testReadFailureKeepsItsFirstTransactionAndSafeLimitCauseWithoutAuthoredMessages() async throws {
    let runtime = try await makeRuntime()
    // This fixture disables nearby startup. Initialize its real journal through
    // the same queue before authoring the accepted transaction used below.
    let transport = try await runtime.connection.makeTransportStorage()
    let created = try await createHistoryFixtureItem(runtime, kind: .notebook(NotebookWorkspaceIdentity.defaultPageSize), at: .zero)
    _ = try XCTUnwrap(created)
    let cut = try await runtime.observeHistorySource { try $0.replicaInventoryCut() }
    XCTAssertEqual(cut.value.journalGeneration, transport.journalGeneration)
    let transaction = try XCTUnwrap(cut.value.acceptedLocalPrefix?.transactionID)
    let limit = NotebookStorageError.limitExceeded("agent_command_read")
    let first = try XCTUnwrap(NotebookHistoryReadiness.SourceError.contextualize(limit,
      section: .acceptedPhysicalHistory, transactionID: transaction) as? NotebookHistoryReadiness.SourceError)
    XCTAssertEqual(first.reason, .resourceLimit)
    XCTAssertEqual(first.identifier, "agent_command_read")
    XCTAssertEqual(first.underlying as? NotebookStorageError, limit)
    let afterCleanup = try XCTUnwrap(NotebookHistoryReadiness.SourceError.contextualize(first,
      section: .finalReader, transactionID: UUID()) as? NotebookHistoryReadiness.SourceError)
    XCTAssertEqual(afterCleanup.section, .acceptedPhysicalHistory)
    XCTAssertEqual(afterCleanup.transactionID, transaction)
    XCTAssertEqual(afterCleanup.identifier, "agent_command_read")

    let privateText = "PRIVATE authored text <source>"
    let collaboration = NotebookHistoryReadiness.SourceError.contextualize(
      CollaborationError("resource_limit", privateText, expected: privateText, actual: privateText),
      section: .endpoint, transactionID: nil)
    let classified = try XCTUnwrap(collaboration as? NotebookHistoryReadiness.SourceError)
    XCTAssertEqual(classified.identifier, "resource_limit")
    XCTAssertFalse(classified.localizedDescription.contains(privateText))
    let invalidIdentifier = NotebookHistoryReadiness.SourceError.contextualize(
      NotebookStorageError.limitExceeded(privateText), section: .cache, transactionID: nil)
    XCTAssertNil((invalidIdentifier as? NotebookHistoryReadiness.SourceError)?.identifier)

    let source = NotebookReplicationSource(deviceID: runtime.actorID,
      generation: try XCTUnwrap(cut.value.journalGeneration))
    let peerFirst = NotebookHistoryControl.Refusal(origin: source, code: .resourceLimit,
      reason: .resourceLimit, stage: .reading, sourceSection: .pending, transactionID: transaction)
    XCTAssertEqual(NotebookHistoryReadiness.SourceError.contextualize(peerFirst,
      section: .emissions, transactionID: nil) as? NotebookHistoryControl.Refusal, peerFirst)
    XCTAssertTrue(NotebookHistoryReadiness.SourceError.contextualize(CancellationError(),
      section: .emissions, transactionID: nil) is CancellationError)
  }

  func testSourceReportKeepsExactLargeCountsAndRetirementCursorsInNativeJSON() async throws {
    let runtime = try await makeRuntime()
    let observation = try await runtime.observeHistorySource { try $0.replicaInventoryCut() }
    let scope = makeScope(runtime: runtime, cut: observation.value)
    let source = NotebookReplicationSource(deviceID: runtime.actorID,
      generation: scope.endpoint(for: runtime.actorID)!.journalGeneration)
    // Exercise the native representation with actual accumulator tokens, not
    // a positive sealed-producer fixture or a readiness assertion.
    let exact = UInt64(Int64.max)
    var roots: [NotebookHistoryControl.Root] = [], tokens: [NotebookHistoryConfirmedStream] = []
    for stream in NotebookHistoryStreamAccumulator.streams {
      var accumulator = try NotebookHistoryStreamAccumulator(scope: scope, source: source, stream: stream)
      let entries: [NotebookHistoryControl.Metadata]
      switch stream {
      case .acceptedTransactions, .physicalClosures, .sourceOriginalRoots: entries = []
      case .replicaInventory, .replicaControl, .fleet:
        entries = [.init(hash: String(repeating: "a", count: 64),
          count: stream == .replicaControl ? exact : 1, byteCount: exact)]
      }
      try accumulator.append(.init(requestID: scope.requestID, workspaceID: scope.workspaceID,
        source: source, stream: stream, ordinal: 0, entries: entries, isLast: true))
      let root = try accumulator.completedRoot()
      roots.append(root); tokens.append(try accumulator.confirm(root))
    }
    let peer = scope.endpoints.first { $0.identity.deviceID != runtime.actorID }!.identity.deviceID
    let retirement = try JSONDecoder().decode(NotebookPeerRetirement.self, from: Data("""
      {"peerID":"\(peer.uuidString)","workspaceID":"\(scope.workspaceID.uuidString)",
       "sourceCursor":\(exact),"acknowledgedCursor":\(exact - 1),"date":0}
      """.utf8))
    var counters = NotebookHistoryReadiness.SourceCounters()
    counters.unknownSourceOriginals = exact
    let report = NotebookHistoryReadiness.SourceReport(source: source,
      readerLifetimeID: observation.connectionLifetimeID, controlObservation: observation.value.controlObservation,
      roots: roots, confirmedStreams: tokens, counters: counters,
      blockers: [.init(reason: .unknownSourceOriginal, count: exact)], endpointIDs: [runtime.actorID, peer],
      endpointOverflow: false, retirements: [retirement])
    let projection = try report.projection()
    let roundTrip = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(projection))
    XCTAssertEqual(roundTrip["counters"]?["unknownSourceOriginals"]?.stringValue, String(exact))
    let control = try XCTUnwrap(roundTrip["roots"]?.arrayValues.first { $0["stream"]?.stringValue == "replicaControl" })
    XCTAssertEqual(control["metadataCount"]?.stringValue, String(exact))
    XCTAssertEqual(control["byteCount"]?.stringValue, String(exact))
    let receipt = try XCTUnwrap(roundTrip["retirements"]?.arrayValues.first)
    XCTAssertEqual(receipt["sourceCursor"]?.stringValue, String(exact))
    XCTAssertEqual(receipt["acknowledgedCursor"]?.stringValue, String(exact - 1))
    XCTAssertNil(roundTrip["borrowedSnapshotID"])
  }

  private func makeRuntime() async throws -> NotebookWorkspaceRuntime {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-source-\(UUID())")
    let domain = "Notebook.history-source-tests.\(UUID())"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
    addTeardownBlock { preferences.removePersistentDomain(forName: domain) }
    let store = NotebookStore(root: root)
    let owner = makeHistoryFixtureWorkspace(store: store, preferences: preferences,
      persistence: NotebookPersistenceQueue(store: store))
    retainNotebookUntilTeardown(owner, removing: root)
    await owner.start(pageSize: NotebookWorkspaceIdentity.defaultPageSize)
    await owner.finishStartup()
    XCTAssertEqual(owner.loadState, .ready)
    let saved = await owner.finishPendingInteraction()
    XCTAssertTrue(saved, owner.persistenceFailure ?? "Persistence failed")
    return owner.workspaceRuntime
  }

  private func makeScope(runtime: NotebookWorkspaceRuntime, cut: NotebookReplicaInventoryCut) -> NotebookHistoryControlScope {
    .init(requestID: UUID(), workspaceID: cut.workspaceID, credentialID: UUID(), applicationBuild: "source-tests",
      endpoints: [
        .init(identity: .init(deviceID: runtime.actorID, workspaceID: cut.workspaceID, displayName: "Local"),
          journalGeneration: cut.journalGeneration ?? UUID(), head: cut.acceptedLocalPrefix),
        .init(identity: .init(deviceID: UUID(), workspaceID: cut.workspaceID, displayName: "Peer"),
          journalGeneration: UUID(), head: nil),
      ])
  }
}

/// Shared contracts execute against the shipped host on each native target.
@MainActor
func makeHistoryFixtureWorkspace(store: NotebookStore, preferences: UserDefaults,
  persistence: NotebookPersistenceQueue) -> any NotebookWorkspaceLifecycle {
  #if os(macOS)
    return NotebookHeadlessWorkspace(configuration: .init(store: store, persistence: persistence,
      commandSocketURL: nil, allowsCodexRegistration: false, pairingActivationID: nil,
      opensDefaultAccountWorkspace: false, requiresExistingAccountContent: false,
      expectedWorkspaceID: nil, preferences: preferences), startsNearbySync: false)
  #else
    return NotebookAppModel(store: store, startsNearbySync: false, preferences: preferences,
      persistenceQueue: persistence)
  #endif
}

@MainActor
func createHistoryFixtureItem(_ runtime: NotebookWorkspaceRuntime,
  kind: NotebookNativeItemCreation.Kind, at center: WorldPoint) async throws -> UUID {
  let header = try await runtime.observeHistorySource { try $0.workspaceHeader() }.value
  let plan = try NotebookNativeItemCreation(kind: kind, workspaceID: header.workspaceID,
    boardID: header.rootBoardID, center: center, actor: runtime.actorID)
  let command = plan.command()
  _ = try await runtime.persistence.submit(publishesChanges: true) { try command.apply(to: $0) }
  return plan.itemID
}
