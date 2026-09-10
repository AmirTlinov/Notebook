import Foundation
import NotebookCore

extension CodexDesktopInstallation {
  /// Registration belongs to Codex's config writer. Call only after the app's
  /// pair-activation admission; a development archive must not redirect live tools.
  public func registerNotebookTools(entry: URL, socket: URL) async throws {
    try validate()
    let node = application.appendingPathComponent("Contents/Resources/cua_node/bin/node")
    guard FileManager.default.isExecutableFile(atPath: node.path),
      FileManager.default.fileExists(atPath: entry.path), socket.isFileURL else { throw CodexBridgeError.notInstalled }
    let current = try await Self.configuration(binary: binary, arguments: ["mcp", "get", "notebook", "--json"])
    if current.status == 0 {
      let value = try JSONDecoder().decode(JSONValue.self, from: current.data)
      // Explicit user restrictions are never removed by automatic maintenance.
      guard value["enabled"] == .bool(true),
        value["enabled_tools"] == nil || value["enabled_tools"] == .null,
        value["disabled_tools"] == nil || value["disabled_tools"] == .null else { throw CodexBridgeError.unsupportedRequest }
      if value["transport"]?["command"] == .string(node.path),
        value["transport"]?["args"] == .array([.string(entry.path)]),
        value["transport"]?["env"]?["NOTEBOOK_SOCKET"] == .string(socket.path) { return }
    } else {
      // A failed read is not proof that registration is absent. Only a valid
      // catalogue can authorize first installation without overwriting settings.
      let listing = try await Self.configuration(binary: binary, arguments: ["mcp", "list", "--json"])
      guard listing.status == 0,
        let entries = try JSONDecoder().decode(JSONValue.self, from: listing.data).array,
        entries.allSatisfy({ $0["name"]?.string != nil }),
        !entries.contains(where: { $0["name"] == .string("notebook") }) else { throw CodexBridgeError.unavailable }
    }
    let saved = try await Self.configuration(binary: binary, arguments: ["mcp", "add", "notebook",
      "--env", "NOTEBOOK_SOCKET=\(socket.path)", "--", node.path, entry.path])
    guard saved.status == 0 else { throw CodexBridgeError.unavailable }
    let readback = try await Self.configuration(binary: binary, arguments: ["mcp", "get", "notebook", "--json"])
    let value = try JSONDecoder().decode(JSONValue.self, from: readback.data)
    guard readback.status == 0, value["transport"]?["command"] == .string(node.path),
      value["transport"]?["args"] == .array([.string(entry.path)]),
      value["transport"]?["env"]?["NOTEBOOK_SOCKET"] == .string(socket.path) else { throw CodexBridgeError.invalidResponse }
  }

  private static func configuration(binary: URL, arguments: [String]) async throws -> (status: Int32, data: Data) {
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
