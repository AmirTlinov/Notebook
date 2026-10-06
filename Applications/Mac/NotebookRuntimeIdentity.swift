import Foundation
import Security

/// Admission follows the signed plugin payload rather than a user's install
/// path. The preserved identifier also preserves Keychain and CloudKit trust.
enum NotebookRuntimeIdentity {
  struct Failure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
  }

  /// A versioned plugin bundle remains immutable for this process's lifetime.
  /// Validate its entire seal once, before any workspace owner is constructed.
  static let admission: Result<Void, Failure> = {
    let bundle = Bundle.main
    let acceptanceEnabled = bundle.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? Bool == true
      || bundle.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? String == "YES"
    guard bundle.object(forInfoDictionaryKey: "NotebookPluginRuntime") as? Bool == true,
      bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true,
      let bundleID = bundle.bundleIdentifier,
      bundleID == "com.amirtlinov.notebook.mac"
        || (acceptanceEnabled && NotebookAcceptanceConfiguration.isAcceptanceBundle(bundleID, role: .mac)),
      bundle.executableURL?.lastPathComponent == "NotebookRuntime" else {
      return .failure(.init(message: "Notebook runtime bundle identity is invalid."))
    }
    func failure(_ stage: String, _ status: OSStatus, _ detail: String? = nil) -> Result<Void, Failure> {
      .failure(.init(message: "Notebook runtime \(stage) failed (\(status)): "
        + (detail ?? (SecCopyErrorMessageString(status, nil) as String?) ?? "Security validation failed.")))
    }
    var code: SecCode?
    var requirement: SecRequirement?
    let identity = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"M94V58FCVP\""
    let selfStatus = SecCodeCopySelf([], &code)
    guard selfStatus == errSecSuccess, let code else { return failure("self identity", selfStatus) }
    let requirementStatus = SecRequirementCreateWithString(identity as CFString, [], &requirement)
    guard requirementStatus == errSecSuccess, let requirement else { return failure("signer requirement", requirementStatus) }
    let offline: SecCSFlags = .noNetworkAccess
    let dynamicStatus = SecCodeCheckValidity(code, offline, requirement)
    guard dynamicStatus == errSecSuccess else { return failure("running identity", dynamicStatus) }
    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(rawValue: kSecCSUseAllArchitectures), &staticCode)
    guard staticStatus == errSecSuccess, let staticCode else { return failure("bundle origin", staticStatus) }
    let flags = offline.union(SecCSFlags(rawValue:
      kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
    var errors: Unmanaged<CFError>?
    let sealStatus = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &errors)
    let detail = errors.map { String(describing: $0.takeRetainedValue()) }
    guard sealStatus == errSecSuccess else { return failure("bundle seal", sealStatus, detail) }
    return .success(())
  }()

  static var isAdmitted: Bool {
    if case .success = admission { return true }
    return false
  }
}
