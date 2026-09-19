import Foundation
import NotebookCore

extension CodexRuntimeInstallation {
  /// Only explicit external Desktop/CLI setup calls this writer. The built-in
  /// runtime uses workspace configuration and never edits the user's profile.
  public func registerNotebookTools(entry: URL, socket: URL) async throws {
    try validate()
    guard FileManager.default.fileExists(atPath: entry.path), socket.isFileURL else { throw CodexBridgeError.notInstalled }
    let rpc = CodexRPC(channel: try CodexChannel.appServer(binary: binary,
      directory: FileManager.default.homeDirectoryForCurrentUser))
    do {
      try await rpc.start()
      let before = try await rpc.request("config/read", params: .object(["includeLayers": .bool(true)]))
      let current = before["config"]?["mcp_servers"]?["notebook"]
      try CodexNotebookToolPolicy.requireEnabled(current)
      guard current?["url"] == nil || current?["url"] == .null else {
        throw CodexNotebookToolPolicy.externalTransport
      }
      let endpoint: [String: JSONValue] = ["command": .string(node.path),
        "args": .array([.string(entry.path)]), "env.NOTEBOOK_SOCKET": .string(socket.path)]
      if current?["command"] == endpoint["command"], current?["args"] == endpoint["args"],
        current?["env"]?["NOTEBOOK_SOCKET"] == endpoint["env.NOTEBOOK_SOCKET"] {
        await rpc.stop(); return
      }
      guard let user = before["layers"]?.array?.first(where: {
        $0["name"]?["type"] == .string("user") && ($0["name"]?["profile"] == nil || $0["name"]?["profile"] == .null)
      }), let path = user["name"]?["file"]?.string, let version = user["version"]?.string else {
        throw CodexBridgeError.invalidResponse
      }
      // Targeted, version-checked edits preserve filters, timeouts and all other
      // preferences. `mcp add` replaces the whole entry, so it is not a repair API.
      _ = try await rpc.request("config/batchWrite", params: .object([
        "filePath": .string(path), "expectedVersion": .string(version),
        "edits": .array(endpoint.keys.sorted().map { key in .object([
          "keyPath": .string("mcp_servers.notebook." + key), "value": endpoint[key]!,
          "mergeStrategy": .string("replace")]) })]))
      let after = try await rpc.request("config/read", params: .object(["includeLayers": .bool(false)]))
      let actual = after["config"]?["mcp_servers"]?["notebook"]
      guard actual?["command"] == endpoint["command"], actual?["args"] == endpoint["args"],
        actual?["env"]?["NOTEBOOK_SOCKET"] == endpoint["env.NOTEBOOK_SOCKET"] else {
        throw CodexNotebookToolPolicy.overriddenConfiguration
      }
      await rpc.stop()
    } catch { await rpc.stop(); throw error }
  }

  static func configuration(binary: URL, arguments: [String]) async throws -> (status: Int32, data: Data) {
    try await Task.detached(priority: .utility) {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-codex-config-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent("output")
      FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
      let process = Process(); process.executableURL = binary; process.arguments = arguments
      process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
      try process.run()
      let deadline = ContinuousClock.now + .seconds(10)
      while process.isRunning {
        if Task.isCancelled || ContinuousClock.now >= deadline {
          process.terminate(); throw CodexBridgeError.timeout
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        if size > 65536 { process.terminate(); throw CodexBridgeError.historyLimit }
        try await Task.sleep(for: .milliseconds(50))
      }
      let data = try Data(contentsOf: url)
      guard data.count <= 65536 else { throw CodexBridgeError.historyLimit }
      return (process.terminationStatus, data)
    }.value
  }
}

/// Codex remains the policy owner. Replacing only the endpoint must not widen
/// a user's tool policy, even when the external integration is not installed.
enum CodexNotebookToolPolicy: Error, LocalizedError {
  case disabled, externalTransport, overriddenConfiguration
  var errorDescription: String? {
    switch self {
    case .disabled: "Notebook отключён в конфигурации Codex (mcp_servers.notebook.enabled=false). Включите его в настройках Codex, если хотите разрешить интеграцию. Настройки не изменены."
    case .externalTransport: "Имя notebook уже занято сетевым MCP-сервером. Измените эту запись в конфигурации Codex явно; Notebook её не заменяет."
    case .overriddenConfiguration: "Адрес Notebook перекрыт другим слоем конфигурации Codex. Проверьте настройки профиля или администратора; повторной записи нет."
    }
  }
  static func requireEnabled(_ entry: JSONValue?) throws {
    if entry?["enabled"] == .bool(false) { throw Self.disabled }
  }
  static func scoped(_ endpoint: JSONValue, inheriting effective: JSONValue) throws -> JSONValue {
    guard let config = effective["config"]?.object, let endpoint = endpoint.object else { throw CodexBridgeError.invalidResponse }
    let inherited = config["mcp_servers"]?["notebook"]
    try requireEnabled(inherited)
    var result = inherited?.object ?? [:]
    // Do not forward another transport's credentials or working directory.
    for key in ["url", "bearer_token_env_var", "http_headers", "env_http_headers", "env_vars", "cwd"] { result.removeValue(forKey: key) }
    for (key, value) in endpoint { result[key] = value }
    return .object(result)
  }
}
