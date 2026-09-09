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
      Text(lifecycle.model.isPeerConnected ? "iPad подключён" : "Ожидается iPad")
      if case .failed(let message) = lifecycle.model.loadState {
        Text(message)
      }
      if let failure = lifecycle.model.persistenceFailure {
        Text("Изменения ещё не сохранены: \(failure)")
        Button("Повторить сохранение") { lifecycle.model.retryPendingPersistence() }
      }
      Menu("Сопряжение устройств") {
        Button("Скопировать приглашение для iPad") {
          do {
            let invitation = try lifecycle.model.createPairingInvitation()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(invitation, forType: .string) else {
              throw NotebookTransportError.storageUnavailable
            }
            pairingError = nil
          } catch { pairingError = error.localizedDescription }
        }
        if case .confirmation(let peer, let generation, let locallyConfirmed) = lifecycle.model.pairingState {
          Text(peer.displayName)
          Text("Устройство: \(peer.deviceID.uuidString.lowercased())")
          Text("Архив: \(peer.workspaceID.uuidString.lowercased())")
          if locallyConfirmed { Text("Ожидается подтверждение на iPad") }
          else {
            Button("Разрешить этому iPad доступ") {
              do { try lifecycle.model.confirmPairing(generation: generation); pairingError = nil }
              catch { pairingError = error.localizedDescription }
            }
          }
        }
        if case .failed(let message) = lifecycle.model.pairingState { Text(message) }
        Button("Отменить сопряжение") {
          do { try lifecycle.model.cancelPairing(); pairingError = nil }
          catch { pairingError = error.localizedDescription }
        }
        ForEach(lifecycle.model.pairedPeers, id: \.deviceID) { peer in
          Button("Отозвать доступ: \(peer.displayName)", role: .destructive) {
            do { try lifecycle.model.revokePeer(peer.deviceID); pairingError = nil }
            catch { pairingError = error.localizedDescription }
          }
        }
        if let pairingError { Text(pairingError) }
      }
      Menu("Агент Notebook") {
        if let agent = lifecycle.model.agentCoordinator {
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
          Text(lifecycle.model.agentStartupError ?? "Агент ждёт открытия хранилища")
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
    if !isRunningTests { Task { await model.start(pageSize: NotebookAppModel.defaultPageSize) } }
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
      sender.reply(toApplicationShouldTerminate: await model.shutdown())
    }
    return .terminateLater
  }
}
