import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookArchiveLaunchTests: XCTestCase {
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

  func testNewActivationRequiresFreshKeychainConfirmationWithoutChangingDeviceIdentity() throws {
    let workspace = UUID(), activation = UUID()
    let device = NotebookTransportIdentity(deviceID: UUID(), workspaceID: workspace, displayName: "activation fixture")
    let peer = NotebookTransportIdentity(deviceID: UUID(), workspaceID: workspace, displayName: "independent peer")
    let old = NotebookKeychainPairingStore()
    let current = NotebookKeychainPairingStore(activationID: activation)
    let next = NotebookKeychainPairingStore(activationID: UUID())
    addTeardownBlock { @MainActor in
      try old.save([], for: device)
      try current.save([], for: device)
      try next.save([], for: device)
    }
    let previous = NotebookTrustedPeer(identity: peer, pairingID: UUID(), secret: Data(repeating: 11, count: 32),
      locallyConfirmed: true, remotelyConfirmed: true)
    try old.save([previous], for: device)
    XCTAssertEqual(try old.load(for: device), [previous])
    XCTAssertEqual(try current.load(for: device), [], "The retained actor and workspace cannot reuse pre-activation trust")

    var accepted = NotebookTrustedPeer(identity: peer, pairingID: UUID(), secret: Data(repeating: 23, count: 32),
      locallyConfirmed: true, remotelyConfirmed: false)
    try current.save([accepted], for: device)
    let reopened = NotebookKeychainPairingStore(activationID: activation)
    XCTAssertEqual(try reopened.load(for: device), [accepted])
    XCTAssertFalse(try XCTUnwrap(reopened.load(for: device).first).isConfirmed)
    accepted.remotelyConfirmed = true
    try reopened.save([accepted], for: device)
    XCTAssertTrue(try XCTUnwrap(current.load(for: device).first).isConfirmed)
    XCTAssertEqual(try old.load(for: device), [previous], "Fresh trust never overwrites another activation's credentials")
    XCTAssertEqual(try next.load(for: device), [])
    try current.save([], for: device)
    XCTAssertEqual(try reopened.load(for: device), [])
    XCTAssertEqual(try old.load(for: device), [previous])
  }
}
