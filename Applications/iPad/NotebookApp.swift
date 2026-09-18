import SwiftUI
import UIKit

@main
struct NotebookApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var launch: NotebookApplicationLaunch

  init() {
    if let isolated = NotebookAcceptanceConfiguration.requestedLaunch() {
      _launch = State(initialValue: isolated)
      return
    }
    #if DEBUG
      let launch = NotebookDebugLaunch(arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment)
      _launch = State(initialValue: launch.makeLaunch())
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
            if launch.canRetry { Button("Повторить проверку") { Task { await launch.waitForAdmission() } } }
            else if launch.failure == nil { ProgressView() }
          }.padding(32)
        }
      }
      .background {
        NotebookSystemTraceIdentitySurface()
          .frame(width: 1, height: 1)
          .allowsHitTesting(false)
      }
      .task { await launch.waitForAdmission() }
    }
  }

  private func workspace(_ model: NotebookAppModel) -> some View {
    NotebookRootView()
      .environment(model)
      .defaultAppStorage(model.preferences)
      .statusBarHidden(true)
      .persistentSystemOverlays(.hidden)
      .onChange(of: scenePhase, initial: true) { _, phase in
        model.chat?.dictation.setForeground(phase != .background)
        model.setPreparationForeground(phase == .active)
        model.setSelectionSurfaceActive(phase == .active)
        guard phase == .background else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Сохранение принятого ввода")
        Task {
          await model.finishPendingInteraction()
          if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
      }
  }
}

#if DEBUG
  @MainActor
  enum NotebookDebugLaunch: Equatable {
    case workspace, drawingFixture, unitTestHost

    init(arguments: [String], environment: [String: String]) {
      if arguments.contains(NotebookDrawingFixture.launchArgument) {
        self = .drawingFixture
      } else if environment["XCTestConfigurationFilePath"] != nil {
        self = .unitTestHost
      } else {
        self = .workspace
      }
    }

    func makeLaunch() -> NotebookApplicationLaunch {
      switch self {
      case .workspace: NotebookApplicationLaunch()
      case .drawingFixture: NotebookApplicationLaunch(fixture: NotebookDrawingFixture.makeModel())
      // Hosted unit tests own their stores, models and windows. Constructing the
      // default model here would read another archive and compete for the same
      // raster/ink budget before the first isolated fixture publishes.
      case .unitTestHost: NotebookApplicationLaunch(fixture: nil)
      }
    }
  }
#endif
