import SwiftUI
import UIKit

@main
struct NotebookApp: App {
  @Environment(\.scenePhase) private var scenePhase
  #if DEBUG && targetEnvironment(simulator)
    @State private var model: NotebookAppModel?
  #else
    @State private var model: NotebookAppModel
  #endif

  init() {
    #if DEBUG && targetEnvironment(simulator)
      let launch = NotebookSimulatorLaunch(arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment)
      _model = State(initialValue: launch.makeModel())
    #else
      _model = State(initialValue: NotebookAppModel())
    #endif
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG && targetEnvironment(simulator)
        if let model { workspace(model) }
      #else
        workspace(model)
      #endif
    }
  }

  private func workspace(_ model: NotebookAppModel) -> some View {
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

#if DEBUG && targetEnvironment(simulator)
  @MainActor
  enum NotebookSimulatorLaunch: Equatable {
    case workspace, drawingFixture, unitTestHost

    init(arguments: [String], environment: [String: String]) {
      if arguments.contains(SimulatorDrawingFixture.launchArgument) {
        self = .drawingFixture
      } else if environment["XCTestConfigurationFilePath"] != nil {
        self = .unitTestHost
      } else {
        self = .workspace
      }
    }

    func makeModel() -> NotebookAppModel? {
      switch self {
      case .workspace: NotebookAppModel()
      case .drawingFixture: SimulatorDrawingFixture.makeModel()
      // Hosted unit tests own their stores, models and windows. Constructing the
      // default model here would read another archive and compete for the same
      // raster/ink budget before the first isolated fixture publishes.
      case .unitTestHost: nil
      }
    }
  }
#endif
