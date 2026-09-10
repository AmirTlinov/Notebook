import SwiftUI
import ServiceManagement
import NotebookCore

@main
struct NotebookMacApp: App {
  @NSApplicationDelegateAdaptor(NotebookMacLifecycle.self) private var lifecycle
  @State private var pairingError: String?
  @State private var agentLoginError: String?

  var body: some Scene {
    MenuBarExtra("Notebook", systemImage: "book.closed") {
      if let model = lifecycle.launch.model {
        Text(model.isPeerConnected ? "iPad подключён" : "Ожидается iPad")
        if case .failed(let message) = model.loadState {
          Text(message)
        }
        if let failure = model.persistenceFailure {
          Text("Изменения ещё не сохранены: \(failure)")
          Button("Повторить сохранение") { model.retryPendingPersistence() }
        }
        Menu("Сопряжение устройств") {
          Button("Скопировать приглашение для iPad") {
            do {
              let invitation = try model.createPairingInvitation()
              NSPasteboard.general.clearContents()
              guard NSPasteboard.general.setString(invitation, forType: .string) else {
                throw NotebookTransportError.storageUnavailable
              }
              pairingError = nil
            } catch { pairingError = error.localizedDescription }
          }
          if case .confirmation(let peer, let generation, let locallyConfirmed) = model.pairingState {
            Text(peer.displayName)
            Text("Устройство: \(peer.deviceID.uuidString.lowercased())")
            Text("Архив: \(peer.workspaceID.uuidString.lowercased())")
            if locallyConfirmed { Text("Ожидается подтверждение на iPad") }
            else {
              Button("Разрешить этому iPad доступ") {
                do { try model.confirmPairing(generation: generation); pairingError = nil }
                catch { pairingError = error.localizedDescription }
              }
            }
          }
          if case .failed(let message) = model.pairingState { Text(message) }
          Button("Отменить сопряжение") {
            do { try model.cancelPairing(); pairingError = nil }
            catch { pairingError = error.localizedDescription }
          }
          ForEach(model.pairedPeers, id: \.deviceID) { peer in
            Button("Отозвать доступ: \(peer.displayName)", role: .destructive) {
              do { try model.revokePeer(peer.deviceID); pairingError = nil }
              catch { pairingError = error.localizedDescription }
            }
          }
          if let pairingError { Text(pairingError) }
        }
        Menu("Агент Notebook") {
          if let agent = model.agentCoordinator {
            if agent.isCheckingAvailability { Text("Проверяется совместимость агента…") }
            switch agent.availability {
            case .ready:
              Text(agent.isRunning ? "Рассматривает вопрос с iPad" : "Готов к вопросам с iPad")
            case .signInRequired:
              Text("Нужен отдельный вход ChatGPT для Notebook")
              Button("Войти через ChatGPT") {
                Task {
                  do {
                    let url = try await agent.signIn()
                    guard NSWorkspace.shared.open(url) else { throw NotebookAgentFailure.signInRequired }
                    agentLoginError = nil
                  } catch { agentLoginError = "Не удалось открыть вход ChatGPT: \(error.localizedDescription)" }
                }
              }
            case .unavailable:
              Text("Исполнитель недоступен: ограничения не ослабляются")
            }
            if let error = agent.lastError { Text(error) }
            if let agentLoginError { Text(agentLoginError) }
            Button("Проверить готовность агента") { Task { await agent.refreshAvailability() } }
          } else {
            Text(model.agentStartupError ?? "Агент ждёт открытия хранилища")
          }
        }
      } else {
        Text(lifecycle.launch.message)
        if lifecycle.launch.failure != nil {
          Button("Повторить проверку") { lifecycle.start() }
        }
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
  let launch: NotebookApplicationLaunch
  private var launchTask: Task<Void, Never>?
  private(set) var launchesAtLogin = false
  private(set) var loginError: String?
  private let isRunningTests: Bool
  private let isFixture: Bool

  override init() {
    isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #if DEBUG
      isFixture = MacDocumentLaunchFixture.isRequested
      launch = isFixture ? NotebookApplicationLaunch(fixture: MacDocumentLaunchFixture.makeModel())
        : isRunningTests ? NotebookApplicationLaunch(fixture: nil) : NotebookApplicationLaunch()
    #else
      isFixture = false
      launch = isRunningTests ? NotebookApplicationLaunch(fixture: nil) : NotebookApplicationLaunch()
    #endif
    super.init()
    if !isRunningTests { start() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    #if DEBUG
      if isFixture, let model = launch.model { Task { await MacDocumentLaunchFixture.writeProof(model: model) } }
    #endif
    guard !isRunningTests, !isFixture else { return }
    let enabled = UserDefaults.standard.object(forKey: "notebook.launch-at-login") as? Bool ?? true
    setLaunchesAtLogin(enabled)
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
      launchTask?.cancel()
      await launchTask?.value
      let saved = await launch.model?.shutdown() ?? true
      sender.reply(toApplicationShouldTerminate: saved)
    }
    return .terminateLater
  }
}
