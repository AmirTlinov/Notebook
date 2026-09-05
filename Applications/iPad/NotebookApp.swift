import SwiftUI
import UIKit

@main
struct NotebookApp: App {
  @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: scenePhase) { _, phase in
          guard phase == .background else { return }
          let task = UIApplication.shared.beginBackgroundTask(withName: "Сохранение принятого ввода")
          Task {
            await model.finishPendingInteraction()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
          }
        }
    }
  }
}
