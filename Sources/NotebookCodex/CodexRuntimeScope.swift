import Foundation
import NotebookCore

/// Process-local endpoint and catalogue scope. Account, model and permissions
/// continue to belong to the installed Codex; no global configuration is written.
public struct CodexRuntimeScope: Sendable, Equatable {
  public let directory: URL
  public let toolsEntry: URL
  public let socket: URL

  public init(directory: URL, toolsEntry: URL, socket: URL) throws {
    guard [directory, toolsEntry, socket].allSatisfy(\.isFileURL),
      socket.standardizedFileURL.resolvingSymlinksInPath() != NotebookIPC.defaultSocketURL.standardizedFileURL.resolvingSymlinksInPath() else {
      throw CodexBridgeError.unsafeEndpoint
    }
    self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    self.toolsEntry = toolsEntry.standardizedFileURL.resolvingSymlinksInPath()
    self.socket = socket.standardizedFileURL.resolvingSymlinksInPath()
  }

  func allows(directory path: String) -> Bool {
    URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path == directory.path
  }

  func bootstrapConfiguration(installation: CodexDesktopInstallation) throws -> CodexScopedConfiguration {
    let node = installation.application.appendingPathComponent("Contents/Resources/cua_node/bin/node")
    guard FileManager.default.isExecutableFile(atPath: node.path),
      FileManager.default.fileExists(atPath: toolsEntry.path) else { throw CodexBridgeError.notInstalled }
    return try CodexScopedConfiguration(scope: self, notebook: .object([
      "command": .string(node.path), "args": .array([.string(toolsEntry.path)]),
      "env": .object(["NOTEBOOK_SOCKET": .string(socket.path)]),
      "enabled": .bool(true), "required": .bool(true)]), disabledServers: [])
  }

  /// One TOML basic string, preserving every Unicode scalar in the input.
  /// Escape the complete prohibited control range, including DEL, independently
  /// of JSONEncoder's formatting defaults. Swift strings contain no surrogates.
  static func tomlString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22: result += "\\\""
      case 0x5C: result += "\\\\"
      case 0x08: result += "\\b"
      case 0x09: result += "\\t"
      case 0x0A: result += "\\n"
      case 0x0C: result += "\\f"
      case 0x0D: result += "\\r"
      case 0x00...0x1F, 0x7F:
        let hex = String(scalar.value, radix: 16, uppercase: true)
        result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }

}

/// One immutable capability map for the acceptance process and its threads.
/// Discovery reads configuration before any thread starts; it never writes it.
struct CodexScopedConfiguration: Sendable, Equatable {
  let scope: CodexRuntimeScope
  let notebook: JSONValue
  let disabledServers: [String]

  init(scope: CodexRuntimeScope, notebook: JSONValue, disabledServers: [String]) throws {
    guard disabledServers.count <= 256,
      disabledServers.allSatisfy({ !$0.isEmpty && $0 != "notebook" && $0.utf8.count <= 256 }),
      Set(disabledServers).count == disabledServers.count else { throw CodexBridgeError.unsafeEndpoint }
    self.scope = scope; self.notebook = notebook; self.disabledServers = disabledServers.sorted()
  }

  func disablingInheritedServers(in value: JSONValue) throws -> Self {
    guard let servers = value["config"]?["mcp_servers"]?.object else { throw CodexBridgeError.invalidResponse }
    return try Self(scope: scope, notebook: notebook, disabledServers: servers.keys.filter { $0 != "notebook" })
  }

  var overrides: [String: JSONValue] {
    var servers = Dictionary(uniqueKeysWithValues: disabledServers.map { ($0, JSONValue.object(["enabled": .bool(false)])) })
    servers["notebook"] = notebook
    // Plugin-provided MCP servers are not present in config.mcp_servers. Disable
    // those sources only in this acceptance process, preserving native tools.
    return ["mcp_servers": .object(servers), "features": .object(["plugins": .bool(false), "apps": .bool(false)])]
  }

  func arguments() throws -> [String] {
    let values = try overrides.keys.sorted().flatMap { key in ["-c", key + "=" + (try Self.toml(overrides[key]!))] }
    guard values.reduce(0, { $0 + $1.utf8.count }) <= 131_072 else { throw CodexBridgeError.unsafeEndpoint }
    return values
  }

  /// Preserve the same admitted map when Codex resolves a thread's settings.
  func threadParameters(_ original: [String: JSONValue]) throws -> [String: JSONValue] {
    guard original["config"] == nil,
      original["cwd"] == nil || original["cwd"] == .string(scope.directory.path) else { throw CodexBridgeError.unsafeEndpoint }
    var result = original
    result["cwd"] = .string(scope.directory.path); result["config"] = .object(overrides)
    return result
  }

  func validateEffective(_ value: JSONValue) throws {
    guard let config = value["config"], let servers = config["mcp_servers"]?.object,
      config["features"]?["plugins"] == .bool(false), config["features"]?["apps"] == .bool(false),
      let actual = servers["notebook"], actual["command"] == notebook["command"],
      actual["args"] == notebook["args"], actual["env"]?["NOTEBOOK_SOCKET"] == notebook["env"]?["NOTEBOOK_SOCKET"],
      actual["enabled"] == .bool(true), actual["required"] == .bool(true),
      servers.allSatisfy({ $0.key == "notebook" || $0.value["enabled"] == .bool(false) }) else { throw CodexBridgeError.unsafeEndpoint }
  }

  private static func toml(_ value: JSONValue) throws -> String {
    switch value {
    case .string(let text): return CodexRuntimeScope.tomlString(text)
    case .bool(let flag): return flag ? "true" : "false"
    case .array(let items): return "[" + (try items.map(toml).joined(separator: ",")) + "]"
    case .object(let fields):
      return "{" + (try fields.keys.sorted().map { CodexRuntimeScope.tomlString($0) + "=" + (try toml(fields[$0]!)) }.joined(separator: ",")) + "}"
    default: throw CodexBridgeError.invalidInput
    }
  }
}
