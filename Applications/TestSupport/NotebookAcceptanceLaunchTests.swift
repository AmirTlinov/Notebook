import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookAcceptanceLaunchTests: XCTestCase {
  private func configuration(root: URL? = nil, socket: String? = nil,
    bundle: String = "com.amirtlinov.notebook.mac.acceptance.012345abcdef") -> NotebookAcceptanceConfiguration {
    let run = UUID()
    let root = root ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("notebook-acceptance-tests/\(run.uuidString.lowercased())/mac", isDirectory: true)
    return .init(version: 1, runID: run, workspaceID: UUID(), actorID: UUID(), role: .mac,
      bundleID: bundle, sourceRevision: String(repeating: "a", count: 40),
      root: root.path, socket: socket ?? "/tmp/notebook-acceptance-\(run.uuidString.lowercased())/bridge.sock",
      codexDirectory: root.appendingPathComponent("Codex").path)
  }

  func testProductionBundleCannotAdmitAcceptanceManifest() throws {
    let value = configuration()
    XCTAssertThrowsError(try value.validate(bundle: "com.amirtlinov.notebook.mac", enabled: true))
    XCTAssertThrowsError(try value.validate(bundle: value.bundleID, enabled: false))
    XCTAssertNoThrow(try value.validate(bundle: value.bundleID, enabled: true))
    XCTAssertFalse(FileManager.default.fileExists(atPath: value.root), "Admission does not create or open storage")
  }

  func testDistinctCheckoutBundlesCannotAdmitEachOthersManifest() throws {
    let value = configuration()
    XCTAssertThrowsError(try value.validate(bundle: "com.amirtlinov.notebook.mac.acceptance.abcdef012345", enabled: true))
    for bundle in ["com.amirtlinov.notebook.mac.acceptance", "com.amirtlinov.notebook.mac.acceptance.bad",
      "com.amirtlinov.notebook.mac.acceptance.012345ABCDEF", "com.amirtlinov.notebook.mac.acceptance.012345abcdef.extra"] {
      let invalid = configuration(bundle: bundle)
      XCTAssertThrowsError(try invalid.validate(bundle: bundle, enabled: true))
      XCTAssertTrue(NotebookAcceptanceConfiguration.requiresManifest(bundleID: bundle, enabled: false))
    }
  }

  func testAcceptanceBundleRequiresManifestEvenIfBuildFlagIsMissing() {
    XCTAssertTrue(NotebookAcceptanceConfiguration.requiresManifest(bundleID: "com.amirtlinov.notebook.acceptance", enabled: false))
    XCTAssertTrue(NotebookAcceptanceConfiguration.requiresManifest(bundleID: "com.amirtlinov.notebook.mac.acceptance.012345abcdef", enabled: false))
    XCTAssertTrue(NotebookAcceptanceConfiguration.requiresManifest(bundleID: "unexpected", enabled: true))
    XCTAssertTrue(NotebookAcceptanceConfiguration.requiresManifest(bundleID: "com.amirtlinov.notebook.mac.acceptance.invalid.suffix", enabled: false),
      "A malformed private identity must fail closed, not open production")
    XCTAssertFalse(NotebookAcceptanceConfiguration.requiresManifest(bundleID: "com.amirtlinov.notebook.preview", enabled: false))
  }

  func testPortableDeviceRootAndUniqueBundleRemainInsidePrivateRun() throws {
    let run = UUID(), home = URL(fileURLWithPath: "/private/isolated-device")
    var value = NotebookAcceptanceConfiguration(version: 1, runID: run, workspaceID: UUID(), actorID: UUID(), role: .iPad,
      bundleID: "com.amirtlinov.notebook.acceptance.gui183", sourceRevision: String(repeating: "a", count: 40),
      root: "Documents/acceptance/\(run.uuidString.lowercased())/store", socket: nil, codexDirectory: nil)
    try value.resolvePortableRoot(home: home)
    XCTAssertEqual(value.root, home.appendingPathComponent("Documents/acceptance/\(run.uuidString.lowercased())/store").path)
    XCTAssertNoThrow(try value.validate(bundle: value.bundleID, enabled: true))
    XCTAssertTrue(NotebookAcceptanceConfiguration.requiresManifest(bundleID: value.bundleID, enabled: false))
    XCTAssertThrowsError(try NotebookAcceptanceConfiguration.manifestURL("Documents/acceptance/../ipad.json", home: home))
    value.root = "Documents/../store"
    XCTAssertThrowsError(try value.resolvePortableRoot(home: home))
    XCTAssertFalse(NotebookAcceptanceConfiguration.isAcceptanceBundle("com.amirtlinov.notebook.acceptance.", role: .iPad))
    XCTAssertFalse(NotebookAcceptanceConfiguration.isAcceptanceBundle("com.amirtlinov.notebook.acceptance.other.suffix", role: .iPad))
  }

  func testProductionStorageAndSocketCannotBeSelected() throws {
    let value = configuration()
    XCTAssertThrowsError(try value.validate(bundle: value.bundleID, enabled: true, productionRoot: value.rootURL))
    let invalid = configuration(socket: NotebookIPC.defaultSocketURL.path)
    XCTAssertThrowsError(try invalid.validate(bundle: invalid.bundleID, enabled: true))
  }

  func testAcceptancePairMustMatchTheAdmittedActorAndRole() throws {
    var value = configuration()
    value.pair = .init(macActorID: UUID(), iPadActorID: UUID(), credentialID: UUID(), secret: Data(repeating: 1, count: 32))
    XCTAssertThrowsError(try value.validate(bundle: value.bundleID, enabled: true))
    value.pair = .init(macActorID: value.actorID, iPadActorID: UUID(), credentialID: UUID(), secret: Data(repeating: 1, count: 31))
    XCTAssertThrowsError(try value.validate(bundle: value.bundleID, enabled: true))
    value.pair = .init(macActorID: value.actorID, iPadActorID: value.actorID, credentialID: UUID(), secret: Data(repeating: 1, count: 32))
    XCTAssertThrowsError(try value.validate(bundle: value.bundleID, enabled: true))
    value.pair = .init(macActorID: value.actorID, iPadActorID: UUID(), credentialID: UUID(), secret: Data(repeating: 1, count: 32))
    XCTAssertNoThrow(try value.validate(bundle: value.bundleID, enabled: true))
    XCTAssertThrowsError(try value.validate(bundle: "com.amirtlinov.notebook.mac", enabled: true))
  }

  func testIsolatedAccountUsesOneCredentialThroughTheNormalDirectoryContract() async throws {
    var mac = configuration()
    let pair = NotebookAcceptanceConfiguration.Pair(macActorID: mac.actorID, iPadActorID: UUID(),
      credentialID: UUID(), secret: Data(repeating: 42, count: 32))
    mac.pair = pair
    let ipad = NotebookAcceptanceConfiguration(version: 1, runID: mac.runID, workspaceID: mac.workspaceID,
      actorID: pair.iPadActorID, role: .iPad, bundleID: "com.amirtlinov.notebook.acceptance", sourceRevision: mac.sourceRevision,
      root: mac.rootURL.deletingLastPathComponent().appendingPathComponent("ipad").path, socket: nil, codexDirectory: nil, pair: pair)
    var results: [NotebookAccountSnapshot] = []
    for config in [mac, ipad] {
      let service = NotebookAcceptanceAccountService(configuration: config, pair: pair)
      let device = NotebookAccountDirectory.Device(identity: .init(deviceID: config.actorID,
        workspaceID: config.workspaceID, displayName: "Actual device name"),
        platform: config.role == .mac ? .mac : .iPad, activation: nil)
      let first = try await service.exchange(device: device, boundAccount: nil, retained: [], spaceName: "unused", publishName: false)
      let credentials = first.directory.credentials(for: device)
      XCTAssertEqual(credentials.count, 1)
      XCTAssertEqual(credentials.first?.1.id, pair.credentialID)
      XCTAssertEqual(credentials.first?.1.secret, pair.secret)
      let second = try await service.exchange(device: device, boundAccount: first.account,
        retained: credentials.map(\.1), spaceName: "unused", publishName: false)
      XCTAssertEqual(first.directory, second.directory, "Reopening must not rotate the installed test credential")
      do {
        _ = try await service.exchange(device: device, boundAccount: "foreign", retained: [], spaceName: "unused", publishName: false)
        XCTFail("A different account must not adopt the retained key")
      } catch { XCTAssertEqual(error as? NotebookAccountError, .changed) }
      do {
        let stale = NotebookAccountDirectory.Pair(id: UUID(), workspaceID: config.workspaceID,
          first: pair.macActorID, second: pair.iPadActorID, secret: pair.secret)
        _ = try await service.exchange(device: device, boundAccount: first.account, retained: [stale], spaceName: "unused", publishName: false)
        XCTFail("A mismatched installed credential must not be silently overwritten")
      } catch { XCTAssertEqual(error as? NotebookAccountError, .invalidDirectory) }
      results.append(first)
    }
    XCTAssertEqual(results[0].account, results[1].account)
    XCTAssertEqual(results[0].directory.pairs, results[1].directory.pairs)
  }

  func testRejectedLaunchNeverFallsBackToTheDefaultWorkspace() async {
    let launch = NotebookApplicationLaunch(failure: "rejected isolated launch")
    await launch.waitForAdmission()
    XCTAssertNil(launch.model)
    XCTAssertEqual(launch.failure, "rejected isolated launch")
    XCTAssertFalse(launch.allowsCodexRegistration)
  }

  func testPreferencesAndActorBelongToTheInjectedRun() async throws {
    let name = "notebook.acceptance.preferences." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let actor = UUID(); defaults.set(actor.uuidString, forKey: "notebook.actor-id")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    let previous = UserDefaults.standard.string(forKey: "notebook.actor-id")
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false, preferences: defaults)
    XCTAssertEqual(model.actorID, actor)
    XCTAssertEqual(UserDefaults.standard.string(forKey: "notebook.actor-id"), previous)
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    try? FileManager.default.removeItem(at: root)
  }

  #if os(iOS)
  func testVoiceSettingsStayInsideTheInjectedRun() throws {
    let name = "notebook.acceptance.voice." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let previous = UserDefaults.standard.string(forKey: "notebook.voice.language")
    defaults.set("ru-RU", forKey: "notebook.voice.language")
    let voice = NotebookVoiceController(preferences: defaults)
    XCTAssertEqual(voice.language, "ru-RU")
    voice.language = "en-US"
    voice.address = "Notebook acceptance"
    XCTAssertEqual(defaults.string(forKey: "notebook.voice.language"), "en-US")
    XCTAssertEqual(defaults.string(forKey: "notebook.voice.address.en-US"), "Notebook acceptance")
    XCTAssertEqual(UserDefaults.standard.string(forKey: "notebook.voice.language"), previous)
  }
  #endif
}
