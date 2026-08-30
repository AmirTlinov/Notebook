import SwiftUI

@main
struct NotebookApp: App {
  @State private var model: NotebookAppModel

  init() {
    #if DEBUG && targetEnvironment(simulator)
      if SimulatorDrawingFixture.isRequested {
        _model = State(initialValue: SimulatorDrawingFixture.makeModel())
      } else {
        _model = State(initialValue: NotebookAppModel())
      }
    #else
      _model = State(initialValue: NotebookAppModel())
    #endif
  }

  var body: some Scene {
    WindowGroup {
      NotebookRootView()
        .environment(model)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
  }
}
