import SwiftUI

@main
struct NotebookMacApp: App {
  @State private var model: NotebookAppModel
  private let isRunningTests: Bool

  init() {
    let isRunningTests = ProcessInfo.processInfo.environment[
      "XCTestConfigurationFilePath"
    ] != nil
    let model = NotebookAppModel(startsNearbySync: !isRunningTests)
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
      }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 700, height: 900)
  }
}
