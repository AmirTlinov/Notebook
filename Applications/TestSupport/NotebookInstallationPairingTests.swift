import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookInstallationPairingTests: XCTestCase {
  @MainActor private struct Pair {
    let base: URL
    let roots: [URL]
    let receipts: [NotebookArchiveActivationReceipt]
    let admission: NotebookArchiveAdmission
    let grant: NotebookInstallationPairingGrant

    init() throws {
      base = FileManager.default.temporaryDirectory.appendingPathComponent("installation-pairing-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      let seed = NotebookStore(root: base.appendingPathComponent("seed"))
      _ = try seed.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
      try seed.savePresence(.init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)))
      let transition = UUID(), activation = NotebookArchiveActivation()
      var roots: [URL] = [], receipts: [NotebookArchiveActivationReceipt] = []
      for (name, role) in [("iPad", NotebookArchiveTarget.Role.iPad), ("Mac", .mac)] {
        let root = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("opaque original".utf8).write(to: root.appendingPathComponent("workspace.json"))
        let target = NotebookArchiveTarget(role: role, bundleID: "fixture." + name, actorID: UUID())
        _ = try activation.prepare(source: root, candidate: seed.root,
          output: NotebookArchiveActivation.controlURL(for: root), transitionID: transition, target: target)
        guard case .waitingForPair(let receipt) = try activation.launch(root: root, target: target) else {
          throw NotebookTransportError.storageUnavailable
        }
        roots.append(root); receipts.append(receipt)
      }
      self.roots = roots; self.receipts = receipts
      admission = try .init(receipts: receipts)
      grant = try .init(admission: admission)
      for root in roots { try admission.publish(at: NotebookArchiveActivation.controlURL(for: root)) }
    }
    func identity(_ index: Int) -> NotebookTransportIdentity {
      .init(deviceID: receipts[index].target.actorID, workspaceID: receipts[index].content.workspaceID, displayName: "Fixture")
    }
    func keychain(_ index: Int) -> NotebookKeychainPairingStore {
      .init(activationID: receipts[index].transitionID)
    }
    func file(_ index: Int) -> URL {
      NotebookArchiveActivation.controlURL(for: roots[index]).appendingPathComponent(NotebookInstallationPairingGrant.fileName)
    }
    func remove() throws {
      for index in roots.indices { try keychain(index).saveState(.init(), for: identity(index)) }
      try FileManager.default.removeItem(at: base)
    }
  }

  func testInstallerPreparesReciprocalKeysBeforeConstructingModel() async throws {
    let pair = try Pair(); defer { try? pair.remove() }
    for i in pair.roots.indices {
      try pair.grant.publish(at: pair.file(i))
      var checked = false
      let launch = NotebookApplicationLaunch(root: pair.roots[i], target: pair.receipts[i].target) { store, activation in
        let records = try? pair.keychain(i).load(for: pair.identity(i))
        XCTAssertEqual(records?.count, 1)
        XCTAssertEqual(records?.first?.identity.deviceID, pair.receipts[1 - i].target.actorID)
        XCTAssertEqual(records?.first?.pairingID, pair.grant.pairingID)
        XCTAssertEqual(records?.first?.secret, pair.grant.secret)
        XCTAssertTrue(records?.first?.isConfirmed == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pair.file(i).path))
        checked = true
        return NotebookAppModel(store: store, startsNearbySync: false, pairingActivationID: activation)
      }
      await launch.start()
      XCTAssertTrue(checked, launch.message); XCTAssertNotNil(launch.model)
      if let model = launch.model { _ = await model.shutdown() }
    }
  }

  func testRevocationAndInterruptedConsumptionCannotReplayInstallerAuthority() throws {
    let pair = try Pair(); defer { try? pair.remove() }
    let keychain = pair.keychain(0), identity = pair.identity(0)
    try pair.grant.publish(at: pair.file(0))
    // Emulate termination after the atomic Keychain update but before unlink.
    var state = NotebookPairingTrustState()
    try state.install(pair.grant, receipt: pair.receipts[0], admission: pair.admission)
    try keychain.saveState(state, for: identity)
    try keychain.consumeInstallationGrant(root: pair.roots[0], receipt: pair.receipts[0])
    XCTAssertEqual(try keychain.load(for: identity).count, 1)
    try keychain.save([], for: identity)
    XCTAssertEqual(try keychain.load(for: identity), [])
    try pair.grant.publish(at: pair.file(0))
    try keychain.consumeInstallationGrant(root: pair.roots[0], receipt: pair.receipts[0])
    XCTAssertEqual(try keychain.load(for: identity), [], "Restoring an installer file must not undo revocation")
    XCTAssertFalse(FileManager.default.fileExists(atPath: pair.file(0).path))
  }

  func testDifferentGrantNeverRotatesCredentialsSilently() throws {
    let pair = try Pair(); defer { try? pair.remove() }
    var state = NotebookPairingTrustState()
    try state.install(pair.grant, receipt: pair.receipts[0], admission: pair.admission)
    let before = state
    let other = try NotebookInstallationPairingGrant(admission: pair.admission)
    XCTAssertThrowsError(try state.install(other, receipt: pair.receipts[0], admission: pair.admission))
    XCTAssertEqual(state, before)
  }

  func testForeignGrantBlocksModelAndPreservesFile() async throws {
    let pair = try Pair(), foreign = try Pair()
    defer { try? pair.remove(); try? foreign.remove() }
    try foreign.grant.publish(at: pair.file(0))
    let launch = NotebookApplicationLaunch(root: pair.roots[0], target: pair.receipts[0].target) { _, _ in
      XCTFail("Unverified grant must not reach the model")
      return NotebookAppModel(store: .init(root: pair.roots[0]), startsNearbySync: false)
    }
    await launch.start()
    XCTAssertNil(launch.model); XCTAssertNotNil(launch.failure)
    XCTAssertEqual(try pair.keychain(0).load(for: pair.identity(0)), [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: pair.file(0).path))
  }

  func testGrantCannotOverwriteExistingManualApproval() throws {
    let pair = try Pair(); defer { try? pair.remove() }
    var state = NotebookPairingTrustState()
    let peer = NotebookTrustedPeer(identity: pair.identity(1), pairingID: UUID(), secret: Data(repeating: 1, count: 32),
      locallyConfirmed: true, remotelyConfirmed: false)
    state.records = [peer]
    XCTAssertThrowsError(try state.install(pair.grant, receipt: pair.receipts[0], admission: pair.admission))
    XCTAssertEqual(state.records, [peer]); XCTAssertNil(state.installedGrantSHA256)
  }
  func testDanglingSymlinkIsNotAnAbsentGrant() async throws {
    let pair = try Pair(); defer { try? pair.remove() }
    try FileManager.default.createSymbolicLink(at: pair.file(0), withDestinationURL: pair.base.appendingPathComponent("missing"))
    let launch = NotebookApplicationLaunch(root: pair.roots[0], target: pair.receipts[0].target) { _, _ in
      XCTFail("A malformed installation payload must block model construction")
      return NotebookAppModel(store: .init(root: pair.roots[0]), startsNearbySync: false)
    }
    await launch.start()
    XCTAssertNil(launch.model); XCTAssertNotNil(launch.failure)
    XCTAssertEqual(try pair.keychain(0).load(for: pair.identity(0)), [])
  }

}
