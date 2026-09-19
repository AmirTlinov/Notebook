import Foundation
import NotebookCore
#if os(macOS)
import NotebookCodex
#endif

/// Changes launch dependencies only. Content, transport, rendering and agent
/// execution remain the production owners; no receipts or ready states are seeded.
struct NotebookAcceptanceConfiguration: Codable, Equatable, Sendable {
  enum Role: String, Codable, Sendable { case mac, iPad }
  struct Pair: Codable, Equatable, Sendable {
    let macActorID: UUID
    let iPadActorID: UUID
    let credentialID: UUID
    let secret: Data
  }
  let version: Int
  let runID: UUID
  let workspaceID: UUID
  let actorID: UUID
  let role: Role
  let bundleID: String
  let sourceRevision: String
  var root: String
  let socket: String?
  let codexDirectory: String?
  var simulatorContact: String? = nil
  var pair: Pair? = nil

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
    guard enabled, version == 1, bundle == bundleID, Self.isAcceptanceBundle(bundleID, role: role),
      sourceRevision.count == 40, sourceRevision.allSatisfy({ $0.isHexDigit }),
      root.hasPrefix("/"), rootURL.pathComponents.contains(runID.uuidString.lowercased()) else {
      throw NotebookStorageError.invalidTransaction("invalid isolated acceptance launch")
    }
    if let pair {
      guard pair.macActorID != pair.iPadActorID, pair.secret.count == 32,
        actorID == (role == .mac ? pair.macActorID : pair.iPadActorID) else {
        throw NotebookStorageError.invalidTransaction("acceptance pair identity mismatch")
      }
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
      let manifest = try Self.manifestURL(path)
      guard let size = try FileManager.default.attributesOfItem(atPath: manifest.path)[.size] as? Int,
        size > 0, size <= 16_384 else { throw NotebookStorageError.invalidTransaction("invalid acceptance manifest") }
      var config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: manifest))
      try config.resolvePortableRoot()
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

  // Physical device containers have an installation-owned UUID. Portable input
  // is limited to this run's Documents subtree and is resolved before admission.
  static func manifestURL(_ path: String, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws -> URL {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == "Documents", parts[1] == "acceptance",
      UUID(uuidString: String(parts[2])) != nil, parts[3] == "ipad.json" else {
      throw NotebookStorageError.invalidTransaction("invalid portable acceptance manifest")
    }
    return home.appendingPathComponent(path)
  }

  mutating func resolvePortableRoot(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws {
    guard !root.hasPrefix("/") else { return }
    guard role == .iPad, root == "Documents/acceptance/\(runID.uuidString.lowercased())/store" else {
      throw NotebookStorageError.invalidTransaction("invalid portable acceptance root")
    }
    root = home.appendingPathComponent(root).path
  }

  static func isAcceptanceBundle(_ bundle: String, role: Role) -> Bool {
    if role == .mac {
      return bundle.wholeMatch(of: /com\.amirtlinov\.notebook\.mac\.acceptance\.[0-9a-f]{12}/) != nil
    }
    let base = "com.amirtlinov.notebook.acceptance"
    if bundle == base { return true }
    guard bundle.hasPrefix(base + ".") else { return false }
    let suffix = bundle.dropFirst(base.count + 1)
    return !suffix.isEmpty && suffix.count <= 64 && suffix.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
  }

  static func requiresManifest(bundleID: String?, enabled: Bool) -> Bool {
    enabled || bundleID.map { value in
      ["com.amirtlinov.notebook.acceptance", "com.amirtlinov.notebook.mac.acceptance"]
        .contains { value == $0 || value.hasPrefix($0 + ".") }
    } == true
  }
}

/// Substitutes only the unavailable CloudKit account directory in the isolated
/// stand. The normal account connection, Keychain, TLS and delivery still run.
/// These credentials cannot be admitted by a production bundle or another run.
struct NotebookAcceptanceAccountService: NotebookAccountService {
  let configuration: NotebookAcceptanceConfiguration
  let pair: NotebookAcceptanceConfiguration.Pair

  func exchange(device: NotebookAccountDirectory.Device, boundAccount: String?,
    retained: [NotebookAccountDirectory.Pair], spaceName: String, publishName: Bool) async throws -> NotebookAccountSnapshot {
    let config = configuration, account = "acceptance:" + config.runID.uuidString.lowercased()
    try config.validate(bundle: config.bundleID, enabled: true)
    guard config.pair == pair, device.identity.deviceID == config.actorID,
      device.identity.workspaceID == config.workspaceID, device.activation == nil,
      device.platform.rawValue == config.role.rawValue,
      boundAccount == nil || boundAccount == account else { throw NotebookAccountError.changed }
    let credential = NotebookAccountDirectory.Pair(id: pair.credentialID, workspaceID: config.workspaceID,
      first: pair.macActorID, second: pair.iPadActorID, secret: pair.secret)
    guard retained.allSatisfy({ $0 == credential }) else { throw NotebookAccountError.invalidDirectory }
    var directory = NotebookAccountDirectory(space: .init(id: config.workspaceID, name: "Acceptance"))
    for (id, platform, name) in [(pair.macActorID, NotebookAccountDirectory.Device.Platform.mac, "Acceptance Mac"),
      (pair.iPadActorID, .iPad, "Acceptance iPad")] {
      let member = id == config.actorID ? device : .init(identity: .init(deviceID: id,
        workspaceID: config.workspaceID, displayName: name), platform: platform, activation: nil)
      try directory.enroll(member, retained: [credential], spaceName: "Acceptance")
    }
    return .init(account: account, directory: directory)
  }
  func initialWorkspace(proposed: UUID) async throws -> UUID { configuration.workspaceID }
  func observe(changed: @escaping @Sendable (Bool) async -> Void) async throws {}
  func stop() async {}
}
