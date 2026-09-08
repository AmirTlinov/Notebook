import SwiftUI
import ServiceManagement

@main
struct NotebookMacApp: App {
  @NSApplicationDelegateAdaptor(NotebookMacLifecycle.self) private var lifecycle

  var body: some Scene {
    MenuBarExtra("Notebook", systemImage: "book.closed") {
      Text(lifecycle.model.isPeerConnected ? "iPad подключён" : "Ожидается iPad")
      if case .failed(let message) = lifecycle.model.loadState {
        Text(message)
      }
      if let failure = lifecycle.model.persistenceFailure {
        Text("Изменения ещё не сохранены: \(failure)")
        Button("Повторить сохранение") { lifecycle.model.retryPendingPersistence() }
      }
      if let loginError = lifecycle.loginError { Text(loginError) }
      Toggle("Запускать при входе", isOn: Binding(
        get: { lifecycle.launchesAtLogin },
        set: { lifecycle.setLaunchesAtLogin($0) }
      ))
      Divider()
      Button("Завершить Notebook") { NSApplication.shared.terminate(nil) }
    }
    .menuBarExtraStyle(.menu)
  }
}

/// The process owns delivery and publication before any menu is opened.
@MainActor
@Observable
final class NotebookMacLifecycle: NSObject, NSApplicationDelegate {
  let model: NotebookAppModel
  private(set) var launchesAtLogin = false
  private(set) var loginError: String?
  private let isRunningTests: Bool
  private let isFixture: Bool

  override init() {
    isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #if DEBUG
      isFixture = MacDocumentLaunchFixture.isRequested
      model = isFixture ? MacDocumentLaunchFixture.makeModel() : NotebookAppModel(startsNearbySync: !isRunningTests)
    #else
      isFixture = false
      model = NotebookAppModel(startsNearbySync: !isRunningTests)
    #endif
    super.init()
    if !isRunningTests { model.start(pageSize: NotebookAppModel.defaultPageSize) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    #if DEBUG
      if isFixture { Task { await MacDocumentLaunchFixture.writeProof(model: model) } }
    #endif
    guard !isRunningTests, !isFixture else { return }
    let enabled = UserDefaults.standard.object(forKey: "notebook.launch-at-login") as? Bool ?? true
    setLaunchesAtLogin(enabled)
  }

  func setLaunchesAtLogin(_ enabled: Bool) {
    guard !isRunningTests, !isFixture else { return }
    do {
      if enabled, SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
      if !enabled, SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
      launchesAtLogin = SMAppService.mainApp.status == .enabled
      loginError = SMAppService.mainApp.status == .requiresApproval ? "Разрешите автозапуск Notebook в настройках входа macOS." : nil
      UserDefaults.standard.set(enabled, forKey: "notebook.launch-at-login")
    } catch {
      launchesAtLogin = SMAppService.mainApp.status == .enabled
      loginError = "Не удалось изменить автозапуск: \(error.localizedDescription)"
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      let saved = await model.finishPendingInteraction()
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
}
