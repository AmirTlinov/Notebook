import Foundation

// The lifecycle regression owns no signed payload. Admission is exercised
// separately with the production identity and a signed, data-free bundle.
enum NotebookRuntimeIdentity {
  static let admission: Result<Void, NSError> = .success(())
  static func recordStartup(_ stage: String) {}
}

// The real NotebookRuntime entry point and AppKit lifecycle are compiled with
// this isolated saved-work owner. No workspace, SQLite, network or keys exist.
@MainActor private enum LifecycleFixture {
  static let mode = CommandLine.arguments[1]
  static let events = URL(fileURLWithPath: CommandLine.arguments[2])
  static func record(_ event: String) {
    let file = try! FileHandle(forWritingTo: events)
    try! file.seekToEnd()
    try! file.write(contentsOf: Data((event + "\n").utf8))
    try! file.close()
  }
}

@MainActor final class NotebookAppModel {
  static let defaultPageSize = 1
  func start(pageSize: Int) async { LifecycleFixture.record("ready") }
}

@MainActor final class NotebookApplicationLaunch {
  let model: NotebookAppModel?
  var existingRuntimeSocketURL: URL? {
    LifecycleFixture.mode == "existing-owner" ? URL(fileURLWithPath: "/unused-existing-owner") : nil
  }
  init(fixture: NotebookAppModel? = nil) {
    LifecycleFixture.record("constructed")
    model = fixture ?? NotebookAppModel()
  }
  func waitForAdmission() async { LifecycleFixture.record("admitted") }
  func shutdown() async -> Bool {
    LifecycleFixture.record("saving")
    try? await Task.sleep(for: .milliseconds(25))
    LifecycleFixture.record("saved")
    return true
  }
}

enum NotebookAcceptanceConfiguration {
  @MainActor static func requestedLaunch() -> NotebookApplicationLaunch? { nil }
}
