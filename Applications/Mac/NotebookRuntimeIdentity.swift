import Foundation
import Security

/// Admission follows the signed plugin payload rather than a user's install
/// path. The preserved identifier also preserves Keychain and CloudKit trust.
enum NotebookRuntimeIdentity {
  static let isAdmitted: Bool = {
    let bundle = Bundle.main
    guard bundle.object(forInfoDictionaryKey: "NotebookPluginRuntime") as? Bool == true,
      bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true,
      bundle.bundleIdentifier == "com.amirtlinov.notebook.mac",
      bundle.executableURL?.lastPathComponent == "NotebookRuntime" else { return false }
    var code: SecCode?
    var requirement: SecRequirement?
    let identity = "anchor apple generic and identifier \"com.amirtlinov.notebook.mac\" and certificate leaf[subject.OU] = \"M94V58FCVP\""
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(identity as CFString, [], &requirement) == errSecSuccess,
      let requirement else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
  }()
}
