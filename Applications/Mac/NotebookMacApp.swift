import SwiftUI

@main
struct NotebookMacApp: App {
  @State private var model = NotebookAppModel()

  var body: some Scene {
    WindowGroup {
      MacRootView()
        .environment(model)
        .frame(minWidth: 480, minHeight: 640)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 700, height: 900)
  }
}
