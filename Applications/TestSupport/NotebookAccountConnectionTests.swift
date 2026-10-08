import CloudKit
import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookAccountConnectionTests: XCTestCase {
  func testHistoryDirectoryIncludesBlockedAndTrustOnlyEndpointsWithoutEnrollment() async throws {
    let space = UUID(), directory = AccountTestDirectory(space: space)
    let mac = makeDevice(space, .mac), pad = makeDevice(space, .iPad), blocked = makeDevice(space, .iPad)
    for device in [mac, pad, blocked] { try directory.value.enroll(device, retained: [], spaceName: "Space") }
    let trustOnly = makeDevice(space, .mac), trust = AccountMemoryTrust()
    trust.state.account = directory.account
    trust.state.records = directory.value.credentials(for: mac).map {
      .init(identity: $0.0.identity, credentialID: $0.1.id, secret: $0.1.secret)
    }
    trust.state.records.append(.init(identity: trustOnly.identity, credentialID: UUID(), secret: Data(repeating: 17, count: 32)))
    trust.state.blocked = [blocked.identity.deviceID]
    let sync = makeSync(mac.identity, trust)
    await sync.start()
    defer { sync.stop() }
    let owner = NotebookAccountConnection(device: mac, sync: sync, service: AccountTestService(directory),
      accountReady: { _ in XCTFail("A readonly directory read cannot enroll") }, accountUnavailable: {})
    let before = directory.value, saves = trust.saves
    let directorySnapshot = try await owner.historyDirectory()
    let snapshot = try XCTUnwrap(directorySnapshot)
    let observation = try sync.historyFleetObservation(directory: snapshot, directoryStatus: .verified)
    XCTAssertEqual(observation.observedDeviceIDs, Set([mac, pad, blocked, trustOnly].map { $0.identity.deviceID }))
    XCTAssertEqual(observation.blockedDevices, [blocked.identity.deviceID])
    XCTAssertFalse(sync.pairedPeers.contains { $0.deviceID == blocked.identity.deviceID })
    XCTAssertTrue(observation.workspaceEnrolled)
    XCTAssertEqual(observation.accountScopeHash, observation.directoryAccountScopeHash)
    XCTAssertEqual(directory.value, before)
    XCTAssertEqual(directory.enrollments, 0)
    XCTAssertEqual(trust.saves, saves)
    let projection = try JSONEncoder().encode(observation.projection())
    let publicReport = String(decoding: projection, as: UTF8.self)
    for credential in trust.state.records {
      XCTAssertFalse(publicReport.contains(credential.secret.base64EncodedString()))
    }
    directory.account = "another-account"
    do { _ = try await owner.historyDirectory(); XCTFail("Another account changed the readiness scope") }
    catch let error as NotebookAccountError { XCTAssertEqual(error, .changed) }
  }

  func testTwoOwnDevicesEnrollWithoutUIAndPersistTheSameCredential() async throws {
    let space = UUID(), directory = AccountTestDirectory(space: space)
    let mac = makeDevice(space, .mac), pad = makeDevice(space, .iPad)
    let firstTrust = AccountMemoryTrust(), secondTrust = AccountMemoryTrust()
    let first = makeSync(mac.identity, firstTrust), second = makeSync(pad.identity, secondTrust)
    let macReady = expectation(description: "Mac learns its own iPad"), padReady = expectation(description: "iPad learns its own Mac")
    var firstNotified = false, secondNotified = false
    first.onStateChange = { _ in
      if !firstNotified, !first.pairedPeers.isEmpty { firstNotified = true; macReady.fulfill() }
    }
    second.onStateChange = { _ in
      if !secondNotified, !second.pairedPeers.isEmpty { secondNotified = true; padReady.fulfill() }
    }
    await first.start(); await second.start()
    let firstAccount = NotebookAccountConnection(device: mac, sync: first, service: AccountTestService(directory),
      accountReady: { _ in }, accountUnavailable: {})
    let secondAccount = NotebookAccountConnection(device: pad, sync: second, service: AccountTestService(directory),
      accountReady: { _ in }, accountUnavailable: {})
    firstAccount.start(); secondAccount.start()
    await fulfillment(of: [macReady, padReady], timeout: 5)
    await firstAccount.stop(); await secondAccount.stop(); first.stop(); second.stop()
    let a = try XCTUnwrap(firstTrust.state.records.first), b = try XCTUnwrap(secondTrust.state.records.first)
    XCTAssertEqual(a.secret, b.secret); XCTAssertEqual(a.credentialID, b.credentialID)
    XCTAssertEqual(a.identity, pad.identity); XCTAssertEqual(b.identity, mac.identity)
    XCTAssertEqual(firstTrust.state.account, "A"); XCTAssertEqual(secondTrust.state.account, "A")
  }

  func testDifferentAccountCannotReceiveRetainedCredentialsOrRestartDiscovery() async throws {
    let space = UUID(), directory = AccountTestDirectory(space: space), device = makeDevice(space, .iPad)
    let trust = AccountMemoryTrust(); trust.state.account = "A"
    directory.account = "B"
    let sync = makeSync(device.identity, trust); await sync.start()
    let rejected = expectation(description: "New account cannot adopt the old workspace")
    var reported = false
    let service = AccountTestService(directory)
    let owner = NotebookAccountConnection(device: device, sync: sync, service: service,
      accountReady: { _ in XCTFail("No authorization for another account") }, accountUnavailable: {
        if !reported { reported = true; rejected.fulfill() }
      })
    owner.start(); await fulfillment(of: [rejected], timeout: 3)
    await owner.stop(); sync.stop()
    XCTAssertEqual(owner.status, .accountChanged); XCTAssertEqual(trust.state.account, "A")
    XCTAssertEqual(directory.enrollments, 0); XCTAssertEqual(trust.saves, 0)
  }

  func testStopRejectsAnEnrollmentThatFinishesAfterCancellation() async throws {
    let space = UUID(), directory = AccountTestDirectory(space: space), device = makeDevice(space, .iPad)
    let trust = AccountMemoryTrust(), sync = makeSync(device.identity, trust), service = AccountTestService(directory)
    let entered = expectation(description: "Cloud lookup started")
    service.hold = true; service.entered = { entered.fulfill() }
    await sync.start()
    let owner = NotebookAccountConnection(device: device, sync: sync, service: service,
      accountReady: { _ in XCTFail("Stopped owner cannot publish account readiness") }, accountUnavailable: {})
    owner.start(); await fulfillment(of: [entered], timeout: 3)
    await owner.stop(); sync.stop()
    XCTAssertEqual(trust.saves, 0); XCTAssertNil(owner.account); XCTAssertTrue(owner.spaces.isEmpty)
  }

  func testHistoryStopJoinsTheAccountWorkRetiredByAnAccountChange() async {
    let space = UUID(), directory = AccountTestDirectory(space: space), device = makeDevice(space, .iPad)
    let trust = AccountMemoryTrust(), sync = makeSync(device.identity, trust), service = AccountTestService(directory)
    let entered = expectation(description: "The original account exchange owns a dispatched cloud request")
    let changed = expectation(description: "Account change stops the same service before joining the retired work")
    let historyStop = expectation(description: "History stop reaches the same service while its previous exchange remains held")
    let exchanged = expectation(description: "The dispatched exchange physically completes")
    let prematureStop = expectation(description: "History stop cannot return before the retired exchange")
    prematureStop.isInverted = true
    var stopObservation: XCTestExpectation? = prematureStop, stopReturned = false, stopCalls = 0
    service.hold = true; service.releasesExchangeOnStop = false
    service.entered = { entered.fulfill() }; service.heldExchangeFinished = { exchanged.fulfill() }
    service.onStopped = {
      stopCalls += 1
      if stopCalls == 1 { changed.fulfill() }
      if stopCalls == 2 { historyStop.fulfill() }
    }
    await sync.start()
    let owner = NotebookAccountConnection(device: device, sync: sync, service: service,
      accountReady: { _ in XCTFail("A retired enrollment cannot authorize the resumed owner") }, accountUnavailable: {})
    owner.start(); await fulfillment(of: [entered], timeout: 3)
    let generation = owner.catalogGeneration
    service.hold = false
    NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
    await fulfillment(of: [changed], timeout: 3)
    XCTAssertNotEqual(owner.catalogGeneration, generation)
    let stopping = Task { await owner.stop(); stopReturned = true; stopObservation?.fulfill() }
    await fulfillment(of: [historyStop], timeout: 3)
    await fulfillment(of: [prematureStop], timeout: 0.1)
    stopObservation = nil
    XCTAssertFalse(stopReturned)
    XCTAssertEqual(directory.enrollments, 0); XCTAssertEqual(trust.saves, 0)
    service.releaseExchange()
    await fulfillment(of: [exchanged], timeout: 3)
    await stopping.value
    XCTAssertTrue(stopReturned)
    XCTAssertEqual(directory.enrollments, 1, "The already dispatched physical result is joined rather than rolled back")
    XCTAssertEqual(trust.saves, 0); XCTAssertNil(owner.account); XCTAssertTrue(owner.spaces.isEmpty)
    service.onStopped = nil; await owner.stop(); sync.stop()
  }

  #if DEBUG
  func testAccountReadyRechecksActualEpochAfterHeldNameCallbackBeforeConnectingCloud() async throws {
    for retiresEpoch in [false, true] { try await exerciseHeldNameCallback(retiresEpoch: retiresEpoch) }
  }

  private func exerciseHeldNameCallback(retiresEpoch: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-ready-source-" + UUID().uuidString)
    let suite = "Notebook.AccountReady." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false, preferences: preferences)
    var held: CheckedContinuation<Void, Never>?
    var stopping: Task<Void, Never>?
    let previousHook = NotebookAppModel.onAccountCloudConnection
    var service: AccountTestService?
    func cleanup() async {
      held?.resume(); held = nil
      service?.onStopped = nil
      await stopping?.value
      let stopped = await model.shutdown(); XCTAssertTrue(stopped)
      NotebookAppModel.onAccountCloudConnection = previousHook
      preferences.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    do {
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      await model.finishStartup()
      let space = try XCTUnwrap(model.admittedWorkspaceID)
      let directory = AccountTestDirectory(space: space), device = makeDevice(space, .iPad)
      let trust = AccountMemoryTrust(), sync = makeSync(device.identity, trust), selectedService = AccountTestService(directory)
      service = selectedService
      await sync.start()
      let entered = expectation(description: "The actual accountReady callback awaits its source-bound name publication")
      let connected = retiresEpoch ? nil
        : expectation(description: "The current account generation reaches the Cloud connect boundary")
      var didHold = false, connections: [String] = []
      model.accountWorkspaceNameSaved = { _, _ in
        guard !didHold else { return }
        didHold = true
        await withCheckedContinuation { continuation in held = continuation; entered.fulfill() }
      }
      NotebookAppModel.onAccountCloudConnection = { account in
        connections.append(account)
        if connections.count == 1 { connected?.fulfill() }
      }
      model.startFixtureAccountConnection(sync, service: selectedService)
      await fulfillment(of: [entered], timeout: 3)
      let owner = try XCTUnwrap(model.accountConnection), generation = owner.catalogGeneration
      XCTAssertEqual(owner.account, "A")
      if retiresEpoch {
        let stopEntered = expectation(description: "Account stop advances the same owner's epoch before joining the held callback")
        selectedService.onStopped = { stopEntered.fulfill() }
        stopping = Task { await owner.stop() }
        await fulfillment(of: [stopEntered], timeout: 3)
        selectedService.onStopped = nil
        XCTAssertNotEqual(owner.catalogGeneration, generation)
        XCTAssertTrue(model.accountConnection === owner)
        XCTAssertEqual(owner.account, "A", "Identity and account text alone cannot attest the pending callback's authority")
        XCTAssertEqual(model.admittedWorkspaceID, space)
        XCTAssertEqual(model.shutdownPhase, .running)
        held?.resume(); held = nil
        await stopping?.value
        XCTAssertTrue(connections.isEmpty, "A retired account callback resumed Cloud after its name observer returned")
      } else {
        held?.resume(); held = nil
        await fulfillment(of: [try XCTUnwrap(connected)], timeout: 3)
        XCTAssertEqual(owner.catalogGeneration, generation)
        XCTAssertEqual(connections.first, "A")
      }
      sync.stop()
    } catch { await cleanup(); throw error }
    await cleanup()
  }
  #endif

  func testInstalledCloudBindingProtectsKeysBeforeTheirFirstDirectoryEnrollment() async throws {
    let space = UUID(), directory = AccountTestDirectory(space: space), device = makeDevice(space, .mac)
    directory.account = "B"
    let trust = AccountMemoryTrust()
    trust.state.records = [.init(identity: makeDevice(space, .iPad).identity,
      credentialID: UUID(), secret: Data(repeating: 3, count: 32))]
    let original = trust.state, sync = makeSync(device.identity, trust)
    await sync.start()
    let rejected = expectation(description: "Existing cloud binding checked before credentials leave the device")
    var reported = false
    let owner = NotebookAccountConnection(device: device, sync: sync, service: AccountTestService(directory),
      initialBoundAccount: "A", accountReady: { _ in XCTFail("Foreign account") }, accountUnavailable: {
        if !reported { reported = true; rejected.fulfill() }
      })
    owner.start(); await fulfillment(of: [rejected], timeout: 3)
    await owner.stop(); sync.stop()
    XCTAssertEqual(directory.enrollments, 0); XCTAssertEqual(trust.state, original)
    XCTAssertNil(sync.browser)
  }

  func testFreshDeviceOpensTheAccountSpaceInsteadOfRegisteringAnotherEmptySpace() async throws {
    let existing = UUID(), local = UUID(), directory = AccountTestDirectory(space: existing)
    let device = makeDevice(local, .iPad), trust = AccountMemoryTrust(), sync = makeSync(device.identity, trust)
    await sync.start()
    let selected = expectation(description: "Known account space selected without setup")
    var opened = false
    let owner = NotebookAccountConnection(device: device, sync: sync, service: AccountTestService(directory),
      shouldOpenDefault: { true }, openWorkspace: { id in
        XCTAssertEqual(id, existing)
        if !opened { opened = true; selected.fulfill() }
      },
      accountReady: { _ in XCTFail("The placeholder cannot publish a separate workspace") }, accountUnavailable: {})
    owner.start(); await fulfillment(of: [selected], timeout: 3)
    await owner.stop(); sync.stop()
    XCTAssertEqual(directory.enrollments, 0); XCTAssertEqual(trust.saves, 0)
  }

  func testInputDuringAccountLookupKeepsTheLocalSpaceInsteadOfSwitchingIt() async throws {
    let existing = UUID(), local = UUID(), directory = AccountTestDirectory(space: existing)
    let device = makeDevice(local, .iPad), trust = AccountMemoryTrust(), sync = makeSync(device.identity, trust)
    await sync.start()
    let ready = expectation(description: "The newly used local space stays independent")
    var checks = 0, reported = false
    let owner = NotebookAccountConnection(device: device, sync: sync, service: AccountTestService(directory),
      shouldOpenDefault: { checks += 1; return checks == 1 },
      openWorkspace: { _ in XCTFail("Accepted local work must not disappear") },
      accountReady: { _ in if !reported { reported = true; ready.fulfill() } }, accountUnavailable: {})
    owner.start(); await fulfillment(of: [ready], timeout: 3)
    await owner.stop(); sync.stop()
    XCTAssertTrue(directory.value.spaces.contains { $0.id == local })
    XCTAssertEqual(directory.value.defaultSpaceID, existing)
  }

  func testOneCloudEngineKeepsAccountDiscoveryWhenContentSyncIsOff() {
    let content = CKRecordZone.ID(zoneName: "Notebook-test", ownerName: CKCurrentUserDefaultName)
    let account = CKRecordZone.ID(zoneName: NotebookAccountCloud.zoneName, ownerName: CKCurrentUserDefaultName)
    XCTAssertEqual(NotebookCloudSync.fetchZoneIDs(workspaceID: content, contentEnabled: false), [account])
    XCTAssertEqual(NotebookCloudSync.fetchZoneIDs(workspaceID: content, contentEnabled: true), [account, content])
    XCTAssertEqual(NotebookCloudSync.fetchZoneIDs(workspaceID: content, contentEnabled: true, requested: .zoneIDs([account])), [account])
    XCTAssertEqual(NotebookCloudSync.fetchZoneIDs(workspaceID: content, contentEnabled: false, requested: .zoneIDs([content])), [])
  }

  private func makeDevice(_ space: UUID, _ platform: NotebookAccountDirectory.Device.Platform) -> NotebookAccountDirectory.Device {
    .init(identity: .init(deviceID: UUID(), workspaceID: space, displayName: platform.rawValue), platform: platform, activation: nil)
  }
  private func makeSync(_ local: NotebookTransportIdentity, _ trust: AccountMemoryTrust) -> NearbySync {
    let storage = NotebookTransportStorage(changes: { _, _ in [] }, incomingCursor: { _ in 0 },
      acknowledgePeer: { _, _ in }, readBlobWindow: { _ in throw NotebookTransportError.invalidBlob },
      stageBlobs: { _ in }, prepareIncoming: { _, _ in [] }, applyRemoteChange: { _ in 0 })
    return NearbySync(role: .iPadConnector, identity: local, storage: storage,
      stagingRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), trustStore: trust)
  }
}

@MainActor private final class AccountMemoryTrust: NotebookDeviceTrustStore {
  var state = NotebookDeviceTrustState(), saves = 0
  func load(for identity: NotebookTransportIdentity) async throws -> NotebookDeviceTrustState { state }
  func save(_ state: NotebookDeviceTrustState, for identity: NotebookTransportIdentity) async throws { self.state = state; saves += 1 }
}

@MainActor private final class AccountTestDirectory {
  var value: NotebookAccountDirectory
  var account = "A"
  var enrollments = 0
  var observers: [UUID: @Sendable (Bool) async -> Void] = [:]
  init(space: UUID) { value = .init(space: .init(id: space, name: "My space")) }
}

@MainActor private final class AccountTestService: NotebookAccountService {
  let directory: AccountTestDirectory
  private let id = UUID()
  var hold = false
  var releasesExchangeOnStop = true
  var entered: (() -> Void)?
  var heldExchangeFinished: (() -> Void)?
  var onStopped: (() -> Void)?
  private var gate: CheckedContinuation<Void, Never>?
  init(_ directory: AccountTestDirectory) { self.directory = directory }
  func exchange(device: NotebookAccountDirectory.Device, boundAccount: String?, retained: [NotebookAccountDirectory.Pair], spaceName: String, publishName: Bool) async throws -> NotebookAccountSnapshot {
    guard boundAccount == nil || boundAccount == directory.account else { throw NotebookAccountError.changed }
    let held = hold
    defer { if held { heldExchangeFinished?() } }
    if held { entered?(); await withCheckedContinuation { gate = $0 } }
    let before = directory.value
    try directory.value.enroll(device, retained: retained, spaceName: "Space")
    directory.enrollments += 1
    if before != directory.value { for callback in directory.observers.values { Task { await callback(false) } } }
    return .init(account: directory.account, directory: directory.value)
  }
  func initialWorkspace(proposed: UUID) async throws -> UUID { directory.value.defaultSpaceID ?? proposed }
  func spaces(boundAccount: String?) async throws -> NotebookAccountSnapshot? {
    guard boundAccount == nil || boundAccount == directory.account else { throw NotebookAccountError.changed }
    return .init(account: directory.account, directory: directory.value)
  }
  func observe(changed: @escaping @Sendable (Bool) async -> Void) async throws {
    if directory.observers[id] == nil {
      directory.observers[id] = changed
      Task { await changed(false) }
    }
  }
  func releaseExchange() { let held = gate; gate = nil; held?.resume() }
  func stop() async {
    onStopped?(); directory.observers[id] = nil
    if releasesExchangeOnStop { releaseExchange() }
  }
}
