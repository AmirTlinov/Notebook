import AppKit
import Foundation
import NotebookCore
import Security

public struct CodexDesktopInstallation: Sendable {
  public let application: URL
  let binary: URL

  @MainActor public static func discover() throws -> Self {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
      throw CodexBridgeError.notInstalled
    }
    return try Self(application: app)
  }

  init(application: URL) throws {
    guard let bundle = Bundle(url: application), bundle.bundleIdentifier == "com.openai.codex" else {
      throw CodexBridgeError.incompatibleVersion
    }
    let binary = application.appendingPathComponent("Contents/Resources/codex")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw CodexBridgeError.notInstalled }
    self.application = application; self.binary = binary
  }

  func validate() throws {
    _ = try Self(application: application)
    var code: SecStaticCode?, requirement: SecRequirement?
    let identity = "anchor apple generic and identifier \"com.openai.codex\" and certificate leaf[subject.OU] = \"2DC432GLL2\""
    guard SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess,
      SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
      let code, let requirement, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
      throw CodexBridgeError.unsafeEndpoint
    }
  }

}
