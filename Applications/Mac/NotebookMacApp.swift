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
        Button("Задачи Codex…") { openWindow(id: "codex-tasks"); NSApp.activate() }
          .keyboardShortcut("1", modifiers: .command)
      }
    }
    Window("Задачи Codex", id: "codex-tasks") {
      if let model = lifecycle.launch.model {
        NotebookMacCodexView(model: model).id(model.workspaceHeader?.workspaceID)
      } else { Text(lifecycle.launch.message).padding() }
    }.defaultSize(width: 980, height: 720)
    Window("Подключение внешнего Codex", id: "codex-integration") {
      if let model = lifecycle.launch.model {
        NotebookMacCodexIntegrationView(model: model)
      } else { Text(lifecycle.launch.message).padding() }
    }.defaultSize(width: 480, height: 280)
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
          Button("Задачи Codex…") { openWindow(id: "codex-tasks"); NSApp.activate() }
          Button("Подключение внешнего Codex…") { openWindow(id: "codex-integration"); NSApp.activate() }
          if let error = model.agentStartupError { Text(error) }
          Text("Разговор, модель и разрешения принадлежат Codex")
        }
      } else {
        Text(lifecycle.launch.message)
        if lifecycle.launch.failure != nil {
          Button("Повторить проверку") { lifecycle.start() }
        }
      }
      Button("Аккаунт Codex…") { lifecycle.showCodexAccount() }
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
  @ObservationIgnored private var accountWindow: NSWindow?
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

  func showCodexAccount() {
    if accountWindow == nil {
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 600),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.title = "Notebook — Codex"; window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(rootView: NotebookCodexAccountView { [weak self] query in
        guard let self else { throw NotebookTransportError.disconnected }
        return try await launch.codexHost.account(query)
      })
      window.center(); accountWindow = window
    }
    accountWindow?.makeKeyAndOrderFront(nil)
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
    launch.workspaceTab = .devices
    showWorkspaces()
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

  func applicationDidResignActive(_ notification: Notification) {
    launch.model?.setPreparationForeground(false)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    launch.model?.setPreparationForeground(true)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      launchTask?.cancel()
      await launchTask?.value
      if await launch.codexHost.hasActiveWork() {
        let alert = NSAlert()
        alert.messageText = "Завершить Notebook и отключить исполнителя?"
        alert.informativeText = "Активная работа Codex и терминалы могут быть прерваны. Чтобы оставить их работать, закройте только окно. Повторный запуск команд после выхода не выполняется."
        alert.addButton(withTitle: "Оставить работать"); alert.addButton(withTitle: "Завершить")
        guard alert.runModal() == .alertSecondButtonReturn else { sender.reply(toApplicationShouldTerminate: false); return }
      }
      let saved = await launch.shutdown()
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
}


private struct NotebookMacCodexIntegrationView: View {
  let model: NotebookAppModel
  @State private var busy = false
  @State private var message: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Codex Desktop / CLI → Notebook").font(.headline)
      Text("Настроить инструменты Notebook в общем профиле Codex. Это нужно только для работы из внешнего Codex; встроенная панель Notebook работает независимо.")
      Text("Настройка обновляет адрес MCP, сохраняя ограничения инструментов. Уже открытой внешней задаче может потребоваться повторное подключение MCP.").font(.callout).foregroundStyle(.secondary)
      if let message { Text(message).textSelection(.enabled) }
      Button(busy ? "Настраиваю…" : "Настроить внешнее подключение") {
        busy = true; message = nil
        Task {
          defer { busy = false }
          do { try await model.registerExternalCodexTools(); message = "Подключение настроено. Ограничения общего профиля сохранены." }
          catch { message = NotebookCodexSidecar.message(error) }
        }
      }.disabled(busy).accessibilityIdentifier("notebook-external-codex-setup")
    }.padding(24).frame(minWidth: 420)
  }
}
