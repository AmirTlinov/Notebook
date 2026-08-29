import SwiftUI

@main
struct TetradApp: App {
  @State private var model = TetradAppModel()

  var body: some Scene {
    WindowGroup {
      TetradRootView()
        .environment(model)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
  }
}
