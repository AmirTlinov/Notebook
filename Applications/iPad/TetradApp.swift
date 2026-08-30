import SwiftUI

@main
struct TetradApp: App {
  @State private var model: TetradAppModel

  init() {
    #if DEBUG && targetEnvironment(simulator)
      if SimulatorDrawingFixture.isRequested {
        _model = State(initialValue: SimulatorDrawingFixture.makeModel())
      } else {
        _model = State(initialValue: TetradAppModel())
      }
    #else
      _model = State(initialValue: TetradAppModel())
    #endif
  }

  var body: some Scene {
    WindowGroup {
      TetradRootView()
        .environment(model)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
  }
}
