import SwiftUI
import ServiceManagement
import NotebookCore

@main
struct NotebookMacApp: App {
  @Environment(\.openWindow) private var openWindow
  @NSApplicationDelegateAdaptor(NotebookMacLifecycle.self) private var lifecycle

  var body: some Scene {
    Window("Notebook", id: "workspace") {
      NotebookMacWorkspaceRoot(lifecycle: lifecycle)
    }
    .defaultSize(width: 1100, height: 780)
    .defaultLaunchBehavior(lifecycle.presentsWorkspaceAtLaunch ? .presented : .suppressed)
    .commands {
      CommandGroup(after: .newItem) {
        Button("Открыть Notebook") { openWindow(id: "workspace"); NSApp.activate() }
          .keyboardShortcut("0", modifiers: .command)
      }
    }
    MenuBarExtra("Notebook", image: "NotebookStatusIcon") {
      Button("Открыть Notebook") { openWindow(id: "workspace"); NSApp.activate() }
      Divider()
      if let model = lifecycle.launch.model {
        Text(model.deviceStatusMessage)
        if case .failed(let message) = model.loadState {
          Text(message)
        }
        if let failure = model.persistenceFailure {
          Text("Изменения ещё не сохранены: \(failure)")
          Button("Повторить сохранение") { model.retryPendingPersistence() }
        }
        Button("Вставить…") { lifecycle.showPaste() }
          .accessibilityIdentifier("clipboard-paste-open")
          .disabled(model.pasteDestinations.isEmpty)
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
      Button("Пространства…") { lifecycle.showWorkspaces() }
        .accessibilityIdentifier("workspaces-open")
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
  @ObservationIgnored var openWorkspace: (() -> Void)?
  private var launchTask: Task<Void, Never>?
  @ObservationIgnored private(set) var devicesWindowController: NotebookMacDevicesWindowController?
  @ObservationIgnored private var workspacesWindow: NSWindow?
  @ObservationIgnored private var pasteWindow: NotebookMacPasteWindow?
  private(set) var launchesAtLogin = false
  private(set) var loginError: String?
  private let isRunningTests: Bool
  private let isFixture: Bool
  private let isAcceptance: Bool

  override init() {
    isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #if DEBUG
      isFixture = MacDocumentLaunchFixture.isRequested
    #else
      isFixture = false
    #endif
    // The explicit DEBUG smoke fixture owns fresh temporary content, not an
    // acceptance manifest or the installed workspace. These are distinct launches.
    let isolated = isFixture ? nil : NotebookAcceptanceConfiguration.requestedLaunch()
    isAcceptance = isolated != nil
    #if DEBUG
      launch = isFixture ? NotebookApplicationLaunch(fixture: MacDocumentLaunchFixture.makeModel())
        : isolated ?? (isRunningTests ? NotebookApplicationLaunch(fixture: nil) : NotebookApplicationLaunch())
    #else
      launch = isolated ?? (isRunningTests ? NotebookApplicationLaunch(fixture: nil) : NotebookApplicationLaunch())
    #endif
    super.init()
    if !isRunningTests || isAcceptance { start() }
  }

  var presentsWorkspaceAtLaunch: Bool { !isRunningTests || isFixture || isAcceptance }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    #if DEBUG
      if isFixture, let model = launch.model { Task { await MacDocumentLaunchFixture.writeProof(model: model) } }
    #endif
    guard !isRunningTests, !isFixture, !isAcceptance else { return }
    let enabled = UserDefaults.standard.object(forKey: "notebook.launch-at-login") as? Bool ?? true
    setLaunchesAtLogin(enabled)
  }

  func start() {
    guard launchTask == nil else { return }
    launchTask = Task {
      defer { launchTask = nil }
      await launch.waitForAdmission()
      guard !Task.isCancelled else { return }
      guard let model = launch.model else { if launch.hasNoWorkspace { showWorkspaces() }; return }
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
    }
  }

  /// Closing the working window never terminates the process-owned sync/MCP.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let openWorkspace { openWorkspace(); sender.activate(); return false }
    return true
  }

  func showWorkspaces() {
    if workspacesWindow == nil {
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 500),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      window.title = "Notebook — Пространства"
      window.identifier = .init("notebook.workspaces.window")
      window.setAccessibilityIdentifier("notebook.workspaces.window")
      window.isReleasedWhenClosed = false
      // AppKit owns this resizable utility window. A flexible SwiftUI List has
      // no intrinsic preferred size and must not collapse it to one pixel.
      let content = NSHostingController(rootView: NotebookWorkspacesView(launch: launch))
      content.sizingOptions = []
      window.contentViewController = content
      window.contentMinSize = .init(width: 460, height: 360)
      window.setContentSize(.init(width: 560, height: 500))
      window.center(); workspacesWindow = window
    }
    workspacesWindow?.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
    Task { await launch.refreshWorkspaces() }
  }

  func showPaste() {
    guard let model=launch.model, !model.pasteDestinations.isEmpty else { return }
    // A new explicit paste captures a new clipboard and destination snapshot.
    pasteWindow?.close()
    pasteWindow=NotebookMacPasteWindow(model:model)
    pasteWindow?.present()
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
