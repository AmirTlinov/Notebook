import Foundation
import NotebookCore
#if os(macOS)
import NotebookCodex
#endif

/// Changes launch dependencies only. Content, transport, rendering and agent
/// execution remain the production owners; no receipts or ready states are seeded.
struct NotebookAcceptanceConfiguration: Codable, Equatable {
  enum Role: String, Codable { case mac, iPad }
  let version: Int
  let runID: UUID
  let workspaceID: UUID
  let actorID: UUID
  let role: Role
  let bundleID: String
  let sourceRevision: String
  let root: String
  let socket: String?
  let codexDirectory: String?
  var simulatorContact: String? = nil

  static let environmentKey = "NOTEBOOK_ACCEPTANCE_MANIFEST"
  var rootURL: URL { URL(fileURLWithPath: root, isDirectory: true) }
  var defaultsSuite: String { bundleID + "." + runID.uuidString.lowercased() }
  var keychainService: String { defaultsSuite + ".nearby-pair-v1" }

  func validate(bundle: String?, enabled: Bool, productionRoot: URL = NotebookStore.defaultRoot,
    productionSocket: URL = NotebookIPC.defaultSocketURL) throws {
    if let simulatorContact {
      #if targetEnvironment(simulator)
        guard role == .iPad, simulatorContact == "pencil" else {
          throw NotebookStorageError.invalidTransaction("unknown Simulator contact profile")
        }
      #else
        throw NotebookStorageError.invalidTransaction("simulated contacts are restricted to Simulator")
      #endif
    }
    let allowedBundle = role == .mac
      ? bundleID.wholeMatch(of: /com\.amirtlinov\.notebook\.mac\.acceptance\.[0-9a-f]{12}/) != nil
      : bundleID == "com.amirtlinov.notebook.acceptance"
    guard enabled, version == 1, allowedBundle, bundle == bundleID,
      sourceRevision.count == 40, sourceRevision.allSatisfy({ $0.isHexDigit }),
      root.hasPrefix("/"), rootURL.pathComponents.contains(runID.uuidString.lowercased()) else {
      throw NotebookStorageError.invalidTransaction("invalid isolated acceptance launch")
    }
    let actual = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    let production = productionRoot.standardizedFileURL.resolvingSymlinksInPath().path
    guard actual != production, !actual.hasPrefix(production + "/"),
      !production.hasPrefix(actual + "/") else {
      throw NotebookStorageError.invalidTransaction("acceptance storage overlaps the installed workspace")
    }
    if role == .mac {
      guard let socket, socket.hasPrefix("/"), socket.utf8.count < 104,
        URL(fileURLWithPath: socket).standardizedFileURL.resolvingSymlinksInPath()
          != productionSocket.standardizedFileURL.resolvingSymlinksInPath(),
        socket.contains(runID.uuidString.lowercased()),
        let codexDirectory, codexDirectory.hasPrefix(actual + "/"),
        URL(fileURLWithPath: codexDirectory).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(actual + "/") else {
        throw NotebookStorageError.invalidTransaction("acceptance requires its private socket and Codex directory")
      }
    } else if socket != nil || codexDirectory != nil {
      throw NotebookStorageError.invalidTransaction("iPad cannot own a Mac execution endpoint")
    }
  }

  @MainActor static func requestedLaunch(environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main) -> NotebookApplicationLaunch? {
    let enabled = (bundle.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? Bool) == true
      || (bundle.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? String) == "YES"
    guard let path = environment[environmentKey] else {
      return requiresManifest(bundleID: bundle.bundleIdentifier, enabled: enabled)
        ? NotebookApplicationLaunch(failure: "Для изолированного стенда требуется конфигурация запуска.") : nil
    }
    do {
      guard path.hasPrefix("/"),
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
        size > 0, size <= 16_384 else { throw NotebookStorageError.invalidTransaction("invalid acceptance manifest") }
      let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      try config.validate(bundle: bundle.bundleIdentifier, enabled: enabled)
      #if os(macOS)
        guard config.role == .mac else { throw NotebookStorageError.invalidTransaction("acceptance role mismatch") }
      #else
        guard config.role == .iPad else { throw NotebookStorageError.invalidTransaction("acceptance role mismatch") }
      #endif
      return NotebookApplicationLaunch(root: config.rootURL) { store, _ in
        guard try store.workspaceHeader().workspaceID == config.workspaceID,
          let defaults = UserDefaults(suiteName: config.defaultsSuite) else {
          throw NotebookStorageError.invalidTransaction("acceptance checkpoint identity mismatch")
        }
        let key = "notebook.actor-id"
        if let stored = defaults.string(forKey: key), stored != config.actorID.uuidString {
          throw NotebookStorageError.invalidTransaction("acceptance actor identity changed")
        }
        defaults.set(config.actorID.uuidString, forKey: key)
        return NotebookAppModel(store: store, startsNearbySync: true,
          commandSocketURL: config.socket.map { URL(fileURLWithPath: $0) },
          preferences: defaults, pairingService: config.keychainService, acceptance: config)
      }
    } catch {
      return NotebookApplicationLaunch(failure: "Изолированный стенд не запущен: \(error.localizedDescription)")
    }
  }

  static func requiresManifest(bundleID: String?, enabled: Bool) -> Bool {
    enabled || bundleID == "com.amirtlinov.notebook.mac.acceptance"
      || bundleID?.hasPrefix("com.amirtlinov.notebook.mac.acceptance.") == true
      || bundleID == "com.amirtlinov.notebook.acceptance"
  }
}
