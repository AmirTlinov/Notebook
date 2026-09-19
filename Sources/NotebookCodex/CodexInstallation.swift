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
}
