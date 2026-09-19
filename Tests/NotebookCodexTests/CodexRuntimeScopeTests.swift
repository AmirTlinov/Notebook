import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Isolated Codex endpoint and catalogue admission")
struct CodexRuntimeScopeTests {
  private func configuration() throws -> CodexScopedConfiguration {
    let scope = try CodexRuntimeScope(directory: URL(fileURLWithPath: "/tmp/acceptance-test/run"),
      toolsEntry: URL(fileURLWithPath: "/tmp/acceptance-test/tools.mjs"), socket: URL(fileURLWithPath: "/tmp/acceptance-test/bridge.sock"))
    return try .init(scope: scope, notebook: .object([
      "command": .string("/signed/node"), "args": .array([.string(scope.toolsEntry.path)]),
      "env": .object(["NOTEBOOK_SOCKET": .string(scope.socket.path)]), "enabled": .bool(true), "required": .bool(true)]), disabledServers: [])
  }

  @Test func inheritedDiscoveryIsBoundedAndOnlyOverridesExternalToolSources() throws {
    let inherited: JSONValue = .object(["config": .object(["mcp_servers": .object([
      "notebook": .object([:]), "server.with.dots": .object(["enabled": .bool(true)]),
      "already-disabled": .object(["enabled": .bool(false)])])])])
    let value = try configuration().disablingInheritedServers(in: inherited)
    #expect(value.disabledServers == ["already-disabled", "server.with.dots"])
    #expect(Set(value.overrides.keys) == ["mcp_servers", "features"])
    #expect(value.overrides["features"] == .object(["apps": .bool(false), "plugins": .bool(false)]))
    #expect(value.overrides["mcp_servers"]?["server.with.dots"]?["enabled"] == .bool(false))
    #expect(try value.arguments().contains { $0.contains("\"server.with.dots\"={\"enabled\"=false}") })
    let tooMany = JSONValue.object(["config": .object(["mcp_servers": .object(Dictionary(uniqueKeysWithValues: (0...256).map { ("server\($0)", .object([:])) }))])])
    #expect(throws: CodexBridgeError.unsafeEndpoint) { try value.disablingInheritedServers(in: tooMany) }
    #expect(throws: CodexBridgeError.invalidResponse) { try value.disablingInheritedServers(in: .object([:])) }
  }

  @Test func strictFinalReadRejectsNewEnabledServersAndReenabledExternalSources() throws {
    let value = try configuration()
    let admitted = JSONValue.object(["config": .object(value.overrides)])
    try value.validateEffective(admitted)
    for entry: JSONValue in [.object(["enabled": .bool(true)]), .object([:])] {
      var config = value.overrides, servers = config["mcp_servers"]!.object!
      servers["unexpected"] = entry; config["mcp_servers"] = .object(servers)
      #expect(throws: CodexBridgeError.unsafeEndpoint) { try value.validateEffective(.object(["config": .object(config)])) }
    }
    for source in ["apps", "plugins"] {
      var config = value.overrides, features = config["features"]!.object!
      features[source] = .bool(true); config["features"] = .object(features)
      #expect(throws: CodexBridgeError.unsafeEndpoint) { try value.validateEffective(.object(["config": .object(config)])) }
    }
  }

  @Test func scopedThreadStartAndResumeCarryTheSameMapAndCannotRedirectCWD() throws {
    let value = try configuration()
    for original: [String: JSONValue] in [["ephemeral": .bool(false)], ["threadId": .string(UUID().uuidString), "excludeTurns": .bool(true)]] {
      let bound = try value.threadParameters(original)
      #expect(bound["cwd"] == .string(value.scope.directory.path))
      #expect(bound["config"] == .object(value.overrides))
      for (key, item) in original { #expect(bound[key] == item) }
    }
    #expect(throws: CodexBridgeError.unsafeEndpoint) { try value.threadParameters(["cwd": .string("/tmp/foreign")]) }
    #expect(throws: CodexBridgeError.unsafeEndpoint) { try value.threadParameters(["config": .object([:])]) }
  }

  @Test(arguments: [
    ("", "\"\""),
    ("/path with space/file", "\"/path with space/file\""),
    ("a\"b\\c", "\"a\\\"b\\\\c\""),
    ("Кириллица 🧪 e\u{301}", "\"Кириллица 🧪 e\u{301}\""),
    ("\t\n\r\u{8}\u{C}", "\"\\t\\n\\r\\b\\f\""),
    ("\0\u{1F}\u{7F}", "\"\\u0000\\u001F\\u007F\""),
    ("\u{85}\u{2028}\u{2029}", "\"\u{85}\u{2028}\u{2029}\"")
  ])
  func tomlBasicStringsPreservePathAndUnicodeBoundaries(_ pair: (String, String)) {
    #expect(CodexRuntimeScope.tomlString(pair.0) == pair.1)
  }

  @Test func noLiteralForbiddenControlOrJSONSlashEscapeCanEnterConfiguration() throws {
    let controls = String(String.UnicodeScalarView((0...31).map { UnicodeScalar($0)! } + [UnicodeScalar(127)!]))
    let encoded = CodexRuntimeScope.tomlString(controls + "/quoted\"path\\tail")
    #expect(encoded.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
    #expect(!encoded.contains("\\/"))
    // The emitted subset is also valid JSON; this independently checks that
    // escapes preserve values, including every C0 character and DEL.
    #expect(try JSONDecoder().decode(String.self, from: Data(encoded.utf8)) == controls + "/quoted\"path\\tail")
  }

  @Test func rejectsProductionSocket() {
    #expect(throws: CodexBridgeError.unsafeEndpoint) {
      try CodexRuntimeScope(directory: URL(fileURLWithPath: "/tmp/acceptance"),
        toolsEntry: URL(fileURLWithPath: "/tmp/tools.mjs"), socket: NotebookIPC.defaultSocketURL)
    }
  }

  @Test func onlyTheExplicitWorkingDirectoryBelongsToThisRun() throws {
    let scope = try CodexRuntimeScope(directory: URL(fileURLWithPath: "/tmp/acceptance-test/run"),
      toolsEntry: URL(fileURLWithPath: "/tmp/tools.mjs"), socket: URL(fileURLWithPath: "/tmp/acceptance-test/bridge.sock"))
    #expect(scope.allows(directory: "/tmp/acceptance-test/run"))
    #expect(!scope.allows(directory: "/tmp/acceptance-test/run-neighbor"))
    #expect(!scope.allows(directory: "/tmp/acceptance-test/run/../foreign"))
    #expect(!scope.allows(directory: FileManager.default.homeDirectoryForCurrentUser.path))
  }

  /// Opt-in integration with the installed signed Codex. Only the explicit
  /// acceptance endpoint is admitted; this never starts a task or model turn.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["NOTEBOOK_CODEX_SCOPE_PROBE_MANIFEST"] != nil))
  @MainActor func actualSwiftArgumentsRoundTripThroughPrivateCodex() async throws {
    let environment = ProcessInfo.processInfo.environment
    let manifestPath = try #require(environment["NOTEBOOK_CODEX_SCOPE_PROBE_MANIFEST"])
    let toolsPath = try #require(environment["NOTEBOOK_CODEX_SCOPE_PROBE_TOOLS"])
    let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
    let runID = try #require(manifest["runID"]?.string.flatMap(UUID.init(uuidString:)))
    let privateRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/NotebookAcceptance/" + runID.uuidString.lowercased())
    let directory = privateRoot.appendingPathComponent("mac/Codex")
    let socket = URL(fileURLWithPath: "/tmp/notebook-acceptance-" + runID.uuidString.lowercased() + "/bridge.sock")
    try #require(manifest["role"] == .string("mac"))
    let bundle = try #require(manifest["bundleID"]?.string)
    try #require(bundle.wholeMatch(of: /com\.amirtlinov\.notebook\.mac\.acceptance\.[0-9a-f]{12}/) != nil)
    try #require(manifest["codexDirectory"] == .string(directory.path))
    try #require(manifest["socket"] == .string(socket.path))
    let installation = try CodexDesktopInstallation.discover()
    try installation.validate()
    let scope = try CodexRuntimeScope(directory: directory, toolsEntry: URL(fileURLWithPath: toolsPath), socket: socket)
    let bootstrap = try scope.bootstrapConfiguration(installation: installation)
    let discovery = CodexRPC(channel: try CodexChannel.appServer(binary: installation.binary,
      directory: directory, configuration: bootstrap.arguments()))
    let configuration: CodexScopedConfiguration
    do {
      try await discovery.start()
      let inherited = try await discovery.request("config/read", params: .object([
        "includeLayers": .bool(false), "cwd": .string(directory.path)]))
      configuration = try bootstrap.disablingInheritedServers(in: inherited)
      await discovery.stop()
    } catch { await discovery.stop(); throw error }
    let arguments = try configuration.arguments()
    let controls = String(String.UnicodeScalarView((0...31).map { UnicodeScalar($0)! } + [UnicodeScalar(127)!]))
    let boundary = " /путь с пробелами/\"quoted\"\\backslash 🧪\u{2028}\u{2029}" + controls
    // First process uses exactly the application's argv. The second also asks
    // the real TOML parser to round-trip every boundary through one inert env value.
    for extra in [false, true] {
      let invocation = arguments + (extra ? ["-c", "mcp_servers.notebook.env.NOTEBOOK_ENCODING_PROBE=" + CodexRuntimeScope.tomlString(boundary)] : [])
      let channel = try CodexChannel.appServer(binary: installation.binary, directory: directory, configuration: invocation)
      let rpc = CodexRPC(channel: channel)
      do {
        try await rpc.start()
        let effective = try await rpc.request("config/read", params: .object(["includeLayers": .bool(false)]))
        try configuration.validateEffective(effective)
        if extra { #expect(effective["config"]?["mcp_servers"]?["notebook"]?["env"]?["NOTEBOOK_ENCODING_PROBE"] == .string(boundary)) }
        let catalogue = try await rpc.request("thread/list", params: .object([
          "limit": .number(8), "sortKey": .string("updated_at"), "sortDirection": .string("desc"),
          "useStateDbOnly": .bool(true), "modelProviders": .array([]),
          "sourceKinds": .array([.string("appServer"), .string("cli"), .string("vscode")]),
          "archived": .bool(false), "cwd": .array([.string(directory.path)])]))
        let rows = try #require(catalogue["data"]?.array)
        #expect(rows.count <= 8)
        #expect(rows.allSatisfy { $0["cwd"] == .string(directory.path) })
        await rpc.stop()
      } catch { await rpc.stop(); throw error }
    }
    // Exercise the application owner too, including concurrent readers awaiting
    // the same bootstrap. Both must receive the installed scoped connection.
    let server = CodexAppServer(installation: installation, scope: scope)
    do {
      async let first = server.tasks()
      async let second = server.tasks()
      let pages = try await [first, second]
      #expect(pages.allSatisfy { $0.tasks.allSatisfy { scope.allows(directory: $0.cwd) } })
      await server.close()
    } catch { await server.close(); throw error }
  }
}
