import CloudKit
import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookAccountConnectionTests: XCTestCase {
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
      acknowledgePeer: { _, _ in }, blobSize: { _ in 0 }, readBlobChunk: { _, _, _ in Data() },
      stageBlob: { _, _, _ in }, missingBlobHashes: { _, _, _ in [] }, applyRemoteChange: { _ in 0 })
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
  var entered: (() -> Void)?
  private var gate: CheckedContinuation<Void, Never>?
  init(_ directory: AccountTestDirectory) { self.directory = directory }
  func exchange(device: NotebookAccountDirectory.Device, boundAccount: String?, retained: [NotebookAccountDirectory.Pair], spaceName: String, publishName: Bool) async throws -> NotebookAccountSnapshot {
    guard boundAccount == nil || boundAccount == directory.account else { throw NotebookAccountError.changed }
    if hold { entered?(); await withCheckedContinuation { gate = $0 } }
    let before = directory.value
    try directory.value.enroll(device, retained: retained, spaceName: "Space")
    directory.enrollments += 1
    if before != directory.value { for callback in directory.observers.values { Task { await callback(false) } } }
    return .init(account: directory.account, directory: directory.value)
  }
  func initialWorkspace(proposed: UUID) async throws -> UUID { directory.value.defaultSpaceID ?? proposed }
  func observe(changed: @escaping @Sendable (Bool) async -> Void) async throws {
    if directory.observers[id] == nil {
      directory.observers[id] = changed
      Task { await changed(false) }
    }
  }
  func stop() async { directory.observers[id] = nil; gate?.resume(); gate = nil }
}
