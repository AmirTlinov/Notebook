import NotebookCore
import Security
import XCTest
@testable import Notebook

@MainActor
final class NotebookArchiveLaunchTests: XCTestCase {
  func testExplicitPeerRetirementIsCheckedBeforeConstructingTheSelectedModel() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("launch-retirement-" + UUID().uuidString)
    let root = base.appendingPathComponent("Notebook"), store = NotebookStore(root: root), peer = UUID()
    defer { try? FileManager.default.removeItem(at: base) }
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let workspace = try store.storedWorkspaceID(), cursor = try store.currentChangeCursor()
    try store.acknowledgePeer(peerID: peer, through: 0)
    _ = try NotebookWorkspaceLibrary(originalRoot: root).select(workspace)
    func arguments(_ id: UUID, _ cut: UInt64) -> [String] {
      ["--notebook-retire-peer", "{\"peerID\":\"\(peer)\",\"workspaceID\":\"\(id)\",\"expectedCursor\":\(cut)}"]
    }
    for request in [arguments(UUID(), cursor), arguments(workspace, cursor - 1)] {
      let refused = NotebookApplicationLaunch(root: root, arguments: request) { _, _ in
        XCTFail("A stale or foreign request must not construct a model")
        throw NotebookStorageError.transactionConflict
      }
      await refused.start()
      XCTAssertNotNil(refused.failure); XCTAssertNil(refused.model)
      XCTAssertTrue(try store.retiredReplicationPeers().isEmpty)
    }
    var constructions = 0
    let launch = NotebookApplicationLaunch(root: root, arguments: arguments(workspace, cursor)) { admitted, _ in
      constructions += 1
      XCTAssertEqual(try admitted.retiredReplicationPeers(), [peer])
      return NotebookAppModel(store: admitted, startsNearbySync: false)
    }
    await launch.start()
    XCTAssertNil(launch.failure); XCTAssertNotNil(launch.model); XCTAssertEqual(constructions, 1)
    XCTAssertEqual(try store.currentChangeCursor(), cursor)
    XCTAssertEqual(try store.peerCursor(peerID: peer, direction: .outgoing), 0)
    let stopped = await launch.shutdown(); XCTAssertTrue(stopped)
    let restart = NotebookApplicationLaunch(root: root, arguments: []) { admitted, _ in
      XCTAssertEqual(try admitted.retiredReplicationPeers(), [peer])
      return NotebookAppModel(store: admitted, startsNearbySync: false)
    }
    await restart.start()
    XCTAssertNil(restart.failure); XCTAssertNotNil(restart.model)
    let restartedStop = await restart.shutdown(); XCTAssertTrue(restartedStop)
  }

  func testNoModelOrDesktopRegistrationBeforeBothActivations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-gate-" + UUID().uuidString)
    let original = root.appendingPathComponent("Notebook"), candidate = root.appendingPathComponent("prepared")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    try Data("old original".utf8).write(to: original.appendingPathComponent("workspace.json"))
    let store = NotebookStore(root: candidate)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    try store.savePresence(.init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)))
    let target = NotebookArchiveTarget(role: .iPad, bundleID: "fixture.ipad", actorID: UUID()), transition = UUID()
    let control = NotebookArchiveActivation.controlURL(for: original)
    _ = try NotebookArchiveActivation().prepare(source: original, candidate: candidate, output: control,
      transitionID: transition, target: target)
    var constructions = 0
    let launch = NotebookApplicationLaunch(root: original, target: target) { store, activationID in
      constructions += 1
      XCTAssertEqual(activationID, transition)
      return NotebookAppModel(store: store, startsNearbySync: false, pairingActivationID: activationID)
    }
    addTeardownBlock { @MainActor in
      if let model = launch.model { _ = await model.shutdown() }
      try FileManager.default.removeItem(at: root)
    }
    await launch.start()
    XCTAssertNil(launch.model); XCTAssertEqual(constructions, 0)
    XCTAssertNil(launch.pairingActivationID)
    XCTAssertFalse(launch.allowsCodexRegistration)
    guard case .waitingForPair(let receipt) = launch.activation else { return XCTFail(launch.message) }
    await launch.start()
    XCTAssertNil(launch.model); XCTAssertEqual(constructions, 0)

    let mac = root.appendingPathComponent("Mac")
    try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: false)
    try Data("Mac original".utf8).write(to: mac.appendingPathComponent("workspace.json"))
    let macTarget = NotebookArchiveTarget(role: .mac, bundleID: "fixture.mac", actorID: UUID())
    let macControl = NotebookArchiveActivation.controlURL(for: mac)
    _ = try NotebookArchiveActivation().prepare(source: mac, candidate: candidate, output: macControl,
      transitionID: transition, target: macTarget)
    guard case .waitingForPair(let macReceipt) = try NotebookArchiveActivation().launch(root: mac, target: macTarget) else {
      return XCTFail("second device must await admission")
    }
    try NotebookArchiveAdmission(receipts: [receipt, macReceipt]).publish(at: control)
    await launch.start()
    XCTAssertNotNil(launch.model); XCTAssertEqual(constructions, 1)
    XCTAssertFalse(launch.allowsCodexRegistration, "An isolated archive cannot repoint the desktop agent to human tools")
    XCTAssertFalse(try XCTUnwrap(launch.model).allowsCodexRegistration)
    XCTAssertEqual(try XCTUnwrap(launch.model).pairingActivationID, transition)
    XCTAssertEqual(launch.pairingActivationID, transition)
    await launch.start()
    XCTAssertEqual(constructions, 1)
    let restart = NotebookApplicationLaunch(root: original, target: target) { store, activationID in
      XCTAssertEqual(activationID, transition, "A cold launch must not discard the newly confirmed pair")
      return NotebookAppModel(store: store, startsNearbySync: false, pairingActivationID: activationID)
    }
    await restart.start()
    XCTAssertNil(restart.failure)
    XCTAssertEqual(restart.model?.pairingActivationID, transition)
    if let model = restart.model { _ = await model.shutdown() }
  }

  func testDamagedPayloadCannotConstructTheDefaultModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-refusal-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Notebook")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let original = Data("untouched old input".utf8)
    try original.write(to: archive.appendingPathComponent("workspace.json"))
    let control = NotebookArchiveActivation.controlURL(for: archive)
    try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
    let launch = NotebookApplicationLaunch(root: archive, target: .init(role: .iPad, bundleID: "fixture", actorID: UUID())) { _, _ in
      XCTFail("failed activation must not construct a model")
      return NotebookAppModel(store: NotebookStore(root: root.appendingPathComponent("must-not-open")), startsNearbySync: false)
    }
    await launch.start()
    XCTAssertNotNil(launch.failure); XCTAssertNil(launch.model)
    XCTAssertFalse(launch.allowsCodexRegistration)
    XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("workspace.json")), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("notebook.sqlite").path))
  }

  func testUnitFixtureDoesNotEnterProductionBootstrap() async {
    let launch = NotebookApplicationLaunch(fixture: nil)
    await launch.waitForAdmission()
    XCTAssertNil(launch.model); XCTAssertNil(launch.failure)
    XCTAssertEqual(launch.activation, .unchanged)
    XCTAssertFalse(launch.allowsCodexRegistration)
    XCTAssertNil(launch.pairingActivationID)
  }

  func testNewActivationHasIndependentDeviceTrustWithoutChangingIdentity() async throws {
    let workspace = UUID(), activation = UUID()
    let identity = NotebookTransportIdentity(deviceID: UUID(), workspaceID: workspace, displayName: "Device")
    let peer = NotebookTrustedDevice(identity: .init(deviceID: UUID(), workspaceID: workspace, displayName: "Mac"),
      credentialID: UUID(), secret: Data(repeating: 11, count: 32))
    let service = "Notebook.tests.activation." + UUID().uuidString
    addTeardownBlock {
      await Task.detached {
        _ = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
      }.value
    }
    let old = NotebookKeychainDeviceStore(service: service)
    let current = NotebookKeychainDeviceStore(activationID: activation, service: service)
    try await old.save(.init(account: "account", records: [peer]), for: identity)
    let oldState = try await old.load(for: identity), empty = try await current.load(for: identity)
    XCTAssertEqual(oldState.records, [peer]); XCTAssertTrue(empty.records.isEmpty)
    let newPeer = NotebookTrustedDevice(identity: peer.identity, credentialID: UUID(), secret: Data(repeating: 12, count: 32))
    try await current.save(.init(account: "account", records: [newPeer]), for: identity)
    let reopened = try await NotebookKeychainDeviceStore(activationID: activation, service: service).load(for: identity)
    let retained = try await old.load(for: identity)
    XCTAssertEqual(reopened.records, [newPeer]); XCTAssertEqual(retained.records, [peer])
  }
}
