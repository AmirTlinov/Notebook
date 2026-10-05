import Foundation
import Security

/// Official, signed executables. No Desktop bundle, copied account or private Node.
public struct CodexRuntimeInstallation: Sendable {
  public let binary: URL
  public let node: URL

  public static func discover() throws -> Self {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("CodexRuntime", isDirectory: true)
    let binary = ([bundled?.appendingPathComponent("codex/bin/codex"),
      home.appendingPathComponent(".local/bin/codex"),
      URL(fileURLWithPath: "/opt/homebrew/bin/codex"), URL(fileURLWithPath: "/usr/local/bin/codex")]
      .compactMap { $0 }).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    let node = ([bundled?.appendingPathComponent("node")].compactMap { $0 }
      + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") })
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    guard let binary, let node else { throw CodexBridgeError.notInstalled }
    let installation = Self(binary: binary.resolvingSymlinksInPath(), node: node.resolvingSymlinksInPath())
    try installation.validate()
    return installation
  }

  public init(binary: URL, node: URL) {
    self.binary = binary.resolvingSymlinksInPath(); self.node = node.resolvingSymlinksInPath()
  }

  func validateVersion() async throws {
    let output = try await Self.configuration(binary: binary, arguments: ["--version"])
    guard output.status == 0, String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli 0.155.0" else {
      throw CodexBridgeError.incompatibleVersion
    }
  }

  func validate() throws {
    try Self.validate(binary, identifier: "codex", team: "2DC432GLL2")
    try Self.validate(node, identifier: "node", team: "HX7739G8FX")
  }

  private static func validate(_ url: URL, identifier: String, team: String) throws {
    guard url.isFileURL, FileManager.default.isExecutableFile(atPath: url.path) else { throw CodexBridgeError.notInstalled }
    var code: SecStaticCode?, requirement: SecRequirement?
    let identity = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
      SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
      let code, let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
      throw CodexBridgeError.unsafeEndpoint
    }
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
