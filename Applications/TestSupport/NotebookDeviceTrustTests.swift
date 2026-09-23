import CloudKit
import Foundation
import NotebookCore
import Security
import XCTest
@testable import Notebook

@MainActor
final class NotebookDeviceTrustTests: XCTestCase {
  private func identity(_ space: UUID = UUID()) -> NotebookTransportIdentity {
    .init(deviceID: UUID(), workspaceID: space, displayName: "Own device")
  }

  func testInstalledCredentialUpgradePreservesOnlyEstablishedKeys() throws {
    let local = identity(), peer = identity(local.workspaceID), id = UUID(), secret = Data(repeating: 7, count: 32)
    let record: [String: Any] = ["identity": ["deviceID": peer.deviceID.uuidString,
      "workspaceID": peer.workspaceID.uuidString, "displayName": peer.displayName],
      "pairingID": id.uuidString, "secret": secret.base64EncodedString(), "locallyConfirmed": true, "remotelyConfirmed": true]
    var pending = record
    pending["remotelyConfirmed"] = false
    let data = try JSONSerialization.data(withJSONObject: ["format": 1, "records": [record, pending], "installedGrantSHA256": String(repeating: "a", count: 64)])
    let state = try JSONDecoder().decode(NotebookDeviceTrustState.self, from: data)
    try state.validate(for: local)
    XCTAssertEqual(state.records.count, 1); XCTAssertEqual(state.records[0].credentialID, id)
    XCTAssertEqual(state.records[0].secret, secret); XCTAssertEqual(state.format, 2)
    let rewritten = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
    XCTAssertNil(rewritten?["installedGrantSHA256"])
  }

  func testKeychainReadbackPersistsAccountBlockAndExactCredential() async throws {
    let local = identity(), peer = NotebookTrustedDevice(identity: identity(local.workspaceID), credentialID: UUID(), secret: Data(repeating: 9, count: 32))
    let service = "Notebook.tests.devices." + UUID().uuidString
    addTeardownBlock {
      await Task.detached {
        _ = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
      }.value
    }
    let owner = NotebookKeychainDeviceStore(service: service)
    let state = NotebookDeviceTrustState(account: "account-A", records: [peer], blocked: [peer.identity.deviceID])
    try await owner.save(state, for: local)
    let reopened = try await NotebookKeychainDeviceStore(service: service).load(for: local)
    XCTAssertEqual(reopened, state)
  }

  func testAccountEnrollmentIsSavedBeforeDeviceDiscoveryAndKeepsExistingKey() async throws {
    let local = identity(), peer = NotebookTrustedDevice(identity: identity(local.workspaceID), credentialID: UUID(), secret: Data(repeating: 5, count: 32))
    let store = DeviceMemoryTrust(), sync = makeSync(local, store)
    defer { sync.stop() }
    await sync.start()
    try await sync.applyAccountTrust(account: "A", devices: [peer])
    XCTAssertEqual(store.state.account, "A"); XCTAssertEqual(store.state.records, [peer])
    XCTAssertEqual(sync.pairedPeers, [peer.identity]); XCTAssertNotNil(sync.browser)
    try await sync.applyAccountTrust(account: "A", devices: [peer])
    XCTAssertEqual(store.saves, 1, "Repeated directory delivery is not another Keychain write")
    do { try await sync.applyAccountTrust(account: "B", devices: []); XCTFail("Different account must not adopt saved trust") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .identityMismatch) }
    XCTAssertEqual(store.state.account, "A"); XCTAssertEqual(store.state.records, [peer])
  }

  func testDisconnectedDeviceIsNotReauthorizedByDirectoryRefresh() async throws {
    let local = identity(), peer = NotebookTrustedDevice(identity: identity(local.workspaceID), credentialID: UUID(), secret: Data(repeating: 5, count: 32))
    let store = DeviceMemoryTrust(), sync = makeSync(local, store)
    defer { sync.stop() }
    await sync.start(); try await sync.applyAccountTrust(account: "A", devices: [peer])
    try await sync.setDeviceAllowed(peer.identity.deviceID, allowed: false)
    try await sync.applyAccountTrust(account: "A", devices: [peer])
    XCTAssertTrue(sync.pairedPeers.isEmpty); XCTAssertEqual(store.state.records, [peer])
    sync.stop(); await sync.start()
    XCTAssertTrue(sync.pairedPeers.isEmpty)
    try await sync.setDeviceAllowed(peer.identity.deviceID, allowed: true)
    XCTAssertEqual(sync.pairedPeers, [peer.identity])
  }

  func testNewAccountAdmittedActivationReplacesAStaleLocalKey() async throws {
    let local = identity(), peer = identity(local.workspaceID)
    let old = NotebookTrustedDevice(identity: peer, credentialID: UUID(), secret: Data(repeating: 1, count: 32))
    let replacement = NotebookTrustedDevice(identity: peer, credentialID: UUID(), secret: Data(repeating: 2, count: 32))
    let store = DeviceMemoryTrust(), sync = makeSync(local, store)
    defer { sync.stop() }
    await sync.start()
    try await sync.applyAccountTrust(account: "A", devices: [old])
    try await sync.applyAccountTrust(account: "A", devices: [replacement])
    XCTAssertEqual(store.state.records, [replacement])
    XCTAssertEqual(sync.savedTrust.records, [replacement])
    XCTAssertEqual(store.saves, 2)
  }

  func testRetiredPeerCannotReconnectOrBeRevivedBySettingsAndKeepsOtherKeys() async throws {
    let local = identity(), retired = NotebookTrustedDevice(identity: identity(local.workspaceID),
      credentialID: UUID(), secret: Data(repeating: 3, count: 32))
    let active = NotebookTrustedDevice(identity: identity(local.workspaceID),
      credentialID: UUID(), secret: Data(repeating: 4, count: 32))
    let store = DeviceMemoryTrust(), sync = makeSync(local, store, retired: [retired.identity.deviceID])
    defer { sync.stop() }
    await sync.start(); try await sync.applyAccountTrust(account: "A", devices: [retired, active])
    XCTAssertEqual(sync.pairedPeers, [active.identity]); XCTAssertEqual(sync.knownPeers, [active.identity])
    do { try await sync.setDeviceAllowed(retired.identity.deviceID, allowed: true); XCTFail("Retirement is not an automatic-connection toggle") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .identityMismatch) }
    sync.stop(); await sync.start()
    try await sync.applyAccountTrust(account: "A", devices: [retired, active])
    XCTAssertEqual(sync.pairedPeers, [active.identity]); XCTAssertEqual(store.state.records, [retired, active])
  }

  func testASettingsActionCannotRestartTransportAfterAccountSuspension() async throws {
    let local = identity(), peer = NotebookTrustedDevice(identity: identity(local.workspaceID),
      credentialID: UUID(), secret: Data(repeating: 4, count: 32))
    let store = DeviceMemoryTrust(), sync = makeSync(local, store)
    await sync.start(); try await sync.applyAccountTrust(account: "A", devices: [peer])
    sync.stop()
    do { try await sync.setDeviceAllowed(peer.identity.deviceID, allowed: true); XCTFail("Account suspension must remain in force") }
    catch { XCTAssertEqual(error as? NotebookTransportError, .disconnected) }
    XCTAssertNil(sync.browser); XCTAssertEqual(store.saves, 1)
  }

  func testCloudDirectoryMustUseEncryptedPrivateZoneField() throws {
    let directory = NotebookAccountDirectory(space: .init(id: UUID(), name: "Space"))
    let id = CKRecord.ID(recordName: NotebookAccountCloud.recordName,
      zoneID: .init(zoneName: NotebookAccountCloud.zoneName, ownerName: CKCurrentUserDefaultName))
    let record = CKRecord(recordType: "NotebookDevices", recordID: id)
    record["format"] = 1 as NSNumber
    record["directory"] = try JSONEncoder().encode(directory) as NSData
    XCTAssertThrowsError(try NotebookAccountCloud.decode(record), "Unencrypted metadata is never a credential source")
    let encrypted = CKRecord(recordType: "NotebookDevices", recordID: id)
    encrypted["format"] = 1 as NSNumber
    encrypted.encryptedValues["directory"] = try JSONEncoder().encode(directory) as NSData
    XCTAssertEqual(try NotebookAccountCloud.decode(encrypted), directory)
  }

  func testOpeningAnotherSpaceKeepsTheOriginalDatabaseAndSelection() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("Notebook-spaces-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), original = NotebookStore(root: root)
    let first = UUID(), second = UUID()
    try original.prepareEmptyWorkspace(workspaceID: first)
    _ = try original.loadOrCreate(actor: UUID(), pageSize: .init(width: 800, height: 1000))
    let before = try original.workspaceHeader(), library = NotebookWorkspaceLibrary(originalRoot: root)
    XCTAssertEqual(try library.selectedRoot(), root)
    let other = try library.select(second)
    XCTAssertNotEqual(other, root)
    XCTAssertEqual(try NotebookStore(root: other).storedWorkspaceID(), second)
    XCTAssertFalse(try NotebookStore(root: other).hasWorkspaceContent())
    XCTAssertEqual(try original.workspaceHeader(), before)
    XCTAssertEqual(try library.selectedRoot(), other)
    XCTAssertEqual(try library.select(first), root)
    XCTAssertEqual(try library.selectedRoot(), root)
  }

  private func makeSync(_ local: NotebookTransportIdentity, _ trust: DeviceMemoryTrust, retired: Set<UUID> = []) -> NearbySync {
    let storage = NotebookTransportStorage(changes: { _, _ in [] }, incomingCursor: { _ in 0 },
      acknowledgePeer: { _, _ in }, readBlobChunk: { hash, offset, _ in .init(hash: hash, offset: offset, totalBytes: 0, data: Data()) },
      stageBlobs: { _ in }, missingBlobHashes: { _, _, _ in [] }, applyRemoteChange: { _ in 0 })
    return NearbySync(role: .iPadConnector, identity: local, storage: storage,
      stagingRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), trustStore: trust, retiredPeers: retired)
  }
}

@MainActor
private final class DeviceMemoryTrust: NotebookDeviceTrustStore {
  var state = NotebookDeviceTrustState()
  var saves = 0
  func load(for identity: NotebookTransportIdentity) async throws -> NotebookDeviceTrustState { state }
  func save(_ state: NotebookDeviceTrustState, for identity: NotebookTransportIdentity) async throws {
    try state.validate(for: identity); self.state = state; saves += 1
  }
}
