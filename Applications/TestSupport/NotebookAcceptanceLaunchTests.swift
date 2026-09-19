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
    XCTAssertFalse(NotebookAcceptanceConfiguration.requiresManifest(bundleID: "com.amirtlinov.notebook.preview", enabled: false))
  }

  func testProductionStorageAndSocketCannotBeSelected() throws {
    let value = configuration()
    XCTAssertThrowsError(try value.validate(bundle: value.bundleID, enabled: true, productionRoot: value.rootURL))
    let invalid = configuration(socket: NotebookIPC.defaultSocketURL.path)
    XCTAssertThrowsError(try invalid.validate(bundle: invalid.bundleID, enabled: true))
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
