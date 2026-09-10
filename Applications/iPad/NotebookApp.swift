import SwiftUI
import UIKit

@main
struct NotebookApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var launch: NotebookApplicationLaunch

  init() {
    #if DEBUG && targetEnvironment(simulator)
      let launch = NotebookSimulatorLaunch(arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment)
      _launch = State(initialValue: launch == .workspace ? NotebookApplicationLaunch() : NotebookApplicationLaunch(fixture: launch.makeModel()))
    #else
      _launch = State(initialValue: NotebookApplicationLaunch())
    #endif
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let model = launch.model { workspace(model) }
        else {
          VStack(spacing: 16) {
            Text(launch.message).multilineTextAlignment(.center)
            if launch.failure != nil { Button("Повторить проверку") { Task { await launch.waitForAdmission() } } }
            else { ProgressView() }
          }.padding(32)
        }
      }.task { await launch.waitForAdmission() }
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
