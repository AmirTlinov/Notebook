import Foundation
import OSLog
import Security

/// Admission follows the signed headless payload. The preserved identifier
/// also preserves Keychain and CloudKit trust.
enum NotebookRuntimeIdentity {
  private static let startupBegan = ContinuousClock.now
  private static let startupLog = Logger(subsystem: "com.amirtlinov.notebook", category: "RuntimeStartup")

  /// Bounded phase marks share this process's existing admission/logging path.
  /// They carry only monotonic time, PID and public stage/status identifiers.
  static func recordStartup(_ stage: String, status: OSStatus? = nil) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    let elapsed = startupBegan.duration(to: .now).components
    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    let pid = ProcessInfo.processInfo.processIdentifier
    if let status {
      startupLog.notice("startup stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds, format: .fixed(precision: 3), privacy: .public) pid=\(pid) status=\(status)")
    } else {
      startupLog.notice("startup stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds, format: .fixed(precision: 3), privacy: .public) pid=\(pid)")
    }
  }

  struct Failure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
  }

  /// The signed runtime bundle remains immutable for this process's lifetime.
  /// Validate its entire seal once, before any workspace owner is constructed.
  static let admission: Result<Void, Failure> = {
    let bundle = Bundle.main
    let acceptanceEnabled = bundle.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? Bool == true
      || bundle.object(forInfoDictionaryKey: "NotebookAcceptanceEnabled") as? String == "YES"
    guard bundle.object(forInfoDictionaryKey: "NotebookHeadlessRuntime") as? Bool == true,
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
    recordStartup("signature.dynamic.begin")
    let dynamicStatus = SecCodeCheckValidity(code, offline, requirement)
    recordStartup("signature.dynamic.end", status: dynamicStatus)
    guard dynamicStatus == errSecSuccess else { return failure("running identity", dynamicStatus) }
    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(rawValue: kSecCSUseAllArchitectures), &staticCode)
    guard staticStatus == errSecSuccess, let staticCode else { return failure("bundle origin", staticStatus) }
    let flags = offline.union(SecCSFlags(rawValue:
      kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
    var errors: Unmanaged<CFError>?
    recordStartup("signature.static.begin")
    let sealStatus = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &errors)
    recordStartup("signature.static.end", status: sealStatus)
    let detail = errors.map { String(describing: $0.takeRetainedValue()) }
    guard sealStatus == errSecSuccess else { return failure("bundle seal", sealStatus, detail) }
    return .success(())
  }()

  static var isAdmitted: Bool {
    if case .success = admission { return true }
    return false
  }
}
