import SwiftUI
import ServiceManagement
import NotebookCore

@main
struct NotebookMacApp: App {
  @NSApplicationDelegateAdaptor(NotebookMacLifecycle.self) private var lifecycle

  var body: some Scene {
    MenuBarExtra("Notebook", image: "NotebookStatusIcon") {
      if let model = lifecycle.launch.model {
        Text(model.deviceStatusMessage)
        if case .failed(let message) = model.loadState {
          Text(message)
        }
        if let failure = model.persistenceFailure {
          Text("Изменения ещё не сохранены: \(failure)")
          Button("Повторить сохранение") { model.retryPendingPersistence() }
        }
        Button("Вставить из tldraw…") { lifecycle.showTldrawImport() }
          .accessibilityIdentifier("tldraw-paste-open")
          .disabled(model.tldrawDestinations.isEmpty)
        Menu("Codex") {
          Text(model.agentStartupError ?? "Задачи Codex доступны из Notebook на iPad")
          Text("Разговор, модель и разрешения принадлежат Codex")
        }
      } else {
        Text(lifecycle.launch.message)
        if lifecycle.launch.failure != nil {
          Button("Повторить проверку") { lifecycle.start() }
        }
      }
      Button("Устройства…") { lifecycle.showDevices() }
        .accessibilityIdentifier("notebook.devices.open")
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
  let launch: NotebookApplicationLaunch
  private var launchTask: Task<Void, Never>?
  @ObservationIgnored private(set) var devicesWindowController: NotebookMacDevicesWindowController?
  @ObservationIgnored private var tldrawWindow: NotebookMacTldrawWindow?
  private(set) var launchesAtLogin = false
  private(set) var loginError: String?
  private let isRunningTests: Bool
  private let isFixture: Bool
  private let isAcceptance: Bool

  override init() {
    isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let isolated = NotebookAcceptanceConfiguration.requestedLaunch()
    isAcceptance = isolated != nil
    #if DEBUG
      isFixture = MacDocumentLaunchFixture.isRequested
      launch = isolated ?? (isFixture ? NotebookApplicationLaunch(fixture: MacDocumentLaunchFixture.makeModel())
        : isRunningTests ? NotebookApplicationLaunch(fixture: nil) : NotebookApplicationLaunch()
      )
    #else
      isFixture = false
      launch = isolated ?? (isRunningTests ? NotebookApplicationLaunch(fixture: nil) : NotebookApplicationLaunch())
    #endif
    super.init()
    if !isRunningTests || isAcceptance { start() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    #if DEBUG
      if isFixture, let model = launch.model { Task { await MacDocumentLaunchFixture.writeProof(model: model) } }
    #endif
    guard !isRunningTests, !isFixture, !isAcceptance else { return }
    NSApplication.shared.registerForRemoteNotifications()
    let enabled = UserDefaults.standard.object(forKey: "notebook.launch-at-login") as? Bool ?? true
    setLaunchesAtLogin(enabled)
  }

  func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
    guard NotebookAccountPush.matches(userInfo) else { return }
    Task { await NotebookAccountPush.refresh() }
  }

  func start() {
    guard launchTask == nil else { return }
    launchTask = Task {
      defer { launchTask = nil }
      await launch.waitForAdmission()
      guard !Task.isCancelled, let model = launch.model else { return }
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
    }
  }

  /// Reopening shows status; connection never depends on opening a window.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showDevices()
    return false
  }

  func showTldrawImport() {
    guard let model=launch.model, !model.tldrawDestinations.isEmpty else { return }
    // A new explicit paste captures a new clipboard and destination snapshot.
    tldrawWindow?.close()
    tldrawWindow=NotebookMacTldrawWindow(model:model)
    tldrawWindow?.present()
  }

  func showDevices() {
    if devicesWindowController == nil {
      devicesWindowController = NotebookMacDevicesWindowController(launch: launch) { [weak self] in self?.start() }
    }
    devicesWindowController?.showDevices()
  }

  func setLaunchesAtLogin(_ enabled: Bool) {
    guard !isRunningTests, !isFixture, !isAcceptance else { return }
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
      launchTask?.cancel()
      await launchTask?.value
      let saved = await launch.model?.shutdown() ?? true
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
}
