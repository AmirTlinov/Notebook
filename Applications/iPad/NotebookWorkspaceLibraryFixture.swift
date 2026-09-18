#if DEBUG
import Foundation
import NotebookCore

@MainActor enum NotebookWorkspaceLibraryFixture {
  static let argument = "--workspace-library-fixture"
  static func makeLaunch() -> NotebookApplicationLaunch {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WorkspaceLibraryFixture", isDirectory: true)
    if ProcessInfo.processInfo.arguments.contains("--reset-workspace-library-fixture") {
      try? FileManager.default.removeItem(at: base)
    }
    return .init(root: base.appendingPathComponent("Notebook"), makeModel: { store, _ in
      NotebookAppModel(store: store, startsNearbySync: false)
    })
  }
}
#endif
