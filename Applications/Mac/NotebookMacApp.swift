import SwiftUI

@main
struct NotebookMacApp: App {
  @NSApplicationDelegateAdaptor(NotebookMacLifecycle.self) private var lifecycle
  @State private var model: NotebookAppModel
  private let isRunningTests: Bool

  init() {
    let isRunningTests = ProcessInfo.processInfo.environment[
      "XCTestConfigurationFilePath"
    ] != nil
    #if DEBUG
      let model = MacDocumentLaunchFixture.isRequested
        ? MacDocumentLaunchFixture.makeModel()
        : NotebookAppModel(startsNearbySync: !isRunningTests)
    #else
      let model = NotebookAppModel(startsNearbySync: !isRunningTests)
    #endif
    if !isRunningTests {
      model.start(pageSize: NotebookAppModel.defaultPageSize)
    }
    self.isRunningTests = isRunningTests
    _model = State(initialValue: model)
  }

  var body: some Scene {
    WindowGroup {
      if isRunningTests {
        Color.clear
      } else {
        MacRootView()
          .environment(model)
          .frame(minWidth: 480, minHeight: 640)
          .onAppear { lifecycle.model = model }
      }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 700, height: 900)
  }
}

/// AppKit keeps the process alive until already accepted edits reach disk.
@MainActor
final class NotebookMacLifecycle: NSObject, NSApplicationDelegate {
  weak var model: NotebookAppModel?
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    Task {
      await model.finishPendingInteraction()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
