import CryptoKit
import Darwin
import Foundation
import NotebookCore

/// This pin names a tested tool catalogue, not a user-selectable model preference.
enum NotebookAgentRuntimeProfile {
  static let version = "0.153.4"
  static let model = "gpt-5.5"
  static let binarySHA256 = "b973d440acac501fd2594a43e7ca9ce41e0a65b9dfb28d0d7a7837c99e1261e3"
  static let configurationSHA256 = "7213047e619ef7b24e69a8446873450522cf1e5e68ce12433c799a45a4a0b3a6"
  static let disabledFeatures = [
    "apps", "plugins", "remote_plugin", "tool_suggest", "skill_search", "goals", "sleep_tool",
    "view_image", "image_generation", "browser_use", "browser_use_external", "computer_use",
    "code_mode_host", "hooks", "workspace_dependencies", "request_permissions_tool", "multi_agent",
    "shell_tool", "unified_exec", "enable_request_compression", "unbounded_connection_retries"
  ]

  struct Prepared: Sendable {
    let binary: URL
    let home: URL
    let environment: [String: String]
    let catalog: URL
  }

  static func prepare(binary: URL, home: URL, configuration: URL) throws -> Prepared {
    let binary = binary.resolvingSymlinksInPath()
    guard FileManager.default.isExecutableFile(atPath: binary.path),
          try digest(binary) == binarySHA256 else { throw NotebookAgentFailure.unsupportedRuntime }
    let config = try Data(contentsOf: configuration)
    guard config.count < 16_384, hex(SHA256.hash(data: config)) == configurationSHA256 else {
      throw NotebookAgentFailure.unsupportedProfile
    }
    try privateDirectory(home)
    let cwd = home.appendingPathComponent("workspace", isDirectory: true)
    let tmp = home.appendingPathComponent("tmp", isDirectory: true)
    try privateDirectory(cwd); try privateDirectory(tmp)
    let destination = home.appendingPathComponent("config.toml")
    if FileManager.default.fileExists(atPath: destination.path) {
      try requirePrivateFile(destination)
      guard try Data(contentsOf: destination) == config else { throw NotebookAgentFailure.unsupportedProfile }
    } else { try privateWrite(config, to: destination) }
    // No inherited OPENAI_API_KEY, CODEX_HOME, proxy, MCP, or user shell environment.
    return Prepared(binary: binary, home: home,
      environment: ["HOME": home.path, "CODEX_HOME": home.path, "TMPDIR": tmp.path,
                    "PATH": "/usr/bin:/bin", "RUST_LOG": "off"],
      catalog: home.appendingPathComponent("model-catalog.json"))
  }

  static func installBundledCatalog(_ data: Data, prepared: Prepared) throws {
    let value = try JSONDecoder().decode(JSONValue.self, from: data)
    guard case .array(let models) = value["models"],
          let model = models.first(where: { $0["slug"] == .string(Self.model) }),
          model["tool_mode"] == nil || model["tool_mode"] == .null else {
      throw NotebookAgentFailure.unsupportedRuntime
    }
    let pinned = try JSONEncoder().encode(JSONValue.object(["models": .array([model])]))
    if FileManager.default.fileExists(atPath: prepared.catalog.path) {
      try requirePrivateFile(prepared.catalog)
    }
    try privateWrite(pinned, to: prepared.catalog)
  }

  static func validateEffective(_ value: JSONValue, catalog: URL) throws {
    guard let c = value["config"], c["model"] == .string(model), c["model_provider"] == .string("openai"),
          c["forced_login_method"] == .string("chatgpt"), c["approval_policy"] == .string("never"),
          c["sandbox_mode"] == .string("read-only"), c["web_search"] == .string("disabled"),
          samePath(c["model_catalog_json"], catalog),
          c["orchestrator"]?["skills"]?["enabled"] == .bool(false),
          c["orchestrator"]?["mcp"]?["enabled"] == .bool(false),
          c["skills"]?["bundled"]?["enabled"] == .bool(false),
          c["agents"]?["enabled"] == .bool(false),
          c["features"]?["code_mode"]?["enabled"] == .bool(false),
          c["features"]?["code_mode"]?["direct_only_tool_namespaces"] == .array([.string("notebook")]),
          c["mcp_servers"] == .object([:]), c["plugins"] == .object([:]),
          disabledFeatures.allSatisfy({ c["features"]?[$0] == .bool(false) }) else {
      throw NotebookAgentFailure.unsupportedProfile
    }
  }

  static func samePath(_ value: JSONValue?, _ url: URL) -> Bool {
    guard case .string(let path) = value else { return false }
    guard let left = realpath(path, nil) else { return false }
    defer { free(left) }
    guard let right = realpath(url.path, nil) else { return false }
    defer { free(right) }
    return strcmp(left, right) == 0
  }

  static func privateDirectory(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    var status = stat()
    guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR,
          status.st_uid == geteuid(), status.st_mode & 0o077 == 0 else {
      throw NotebookAgentFailure.unsafeRuntimeDirectory
    }
  }

  private static func requirePrivateFile(_ url: URL) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
          status.st_uid == geteuid(), status.st_mode & 0o077 == 0, status.st_nlink == 1 else {
      throw NotebookAgentFailure.unsafeRuntimeDirectory
    }
  }

  private static func privateWrite(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    guard chmod(url.path, 0o600) == 0 else { throw NotebookAgentFailure.unsafeRuntimeDirectory }
  }

  private static func digest(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hash = SHA256()
    while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
    return hex(hash.finalize())
  }

  private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
