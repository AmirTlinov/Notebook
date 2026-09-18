import CloudKit
import Foundation
import Network
import NotebookCore
import Observation
import OSLog

/// One lifecycle owns account enrollment, retry and teardown. It does not own
/// content or a second LAN connection, and never treats discovery as authority.
@MainActor @Observable
final class NotebookAccountConnection {
  enum Status: Equatable { case checking, ready, waitingForNetwork, needsAccount, accountChanged, failed(String) }
  private(set) var status: Status = .checking
  private(set) var spaces: [NotebookAccountDirectory.Space] = []
  private(set) var account: String?
  private let device: NotebookAccountDirectory.Device
  private let sync: NearbySync
  private let service: any NotebookAccountService
  private let initialBoundAccount: String?
  private let shouldOpenDefault: @MainActor () async -> Bool
  private let openWorkspace: @MainActor (UUID) -> Void
  private let accountReady: @MainActor (String) async -> Void
  private let accountUnavailable: @MainActor () async -> Void
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var retry: Task<Void, Never>?
  @ObservationIgnored private var notifications: Task<Void, Never>?
  @ObservationIgnored private var path: NWPathMonitor?
  private var active = false
  private var epoch = UUID()
  private var again = false
  private var retryDelay: Double = 2
  private let logger = Logger(subsystem: "com.amirtlinov.notebook", category: "AccountConnection")

  init(device: NotebookAccountDirectory.Device, sync: NearbySync,
    service: any NotebookAccountService = NotebookAccountCloud(),
    initialBoundAccount: String? = nil,
    shouldOpenDefault: @escaping @MainActor () async -> Bool = { false },
    openWorkspace: @escaping @MainActor (UUID) -> Void = { _ in },
    accountReady: @escaping @MainActor (String) async -> Void,
    accountUnavailable: @escaping @MainActor () async -> Void) {
    self.device = device; self.sync = sync; self.service = service
    self.initialBoundAccount = initialBoundAccount
    self.shouldOpenDefault = shouldOpenDefault; self.openWorkspace = openWorkspace
    self.accountReady = accountReady; self.accountUnavailable = accountUnavailable
  }

  func start() {
    guard !active else { refresh(); return }
    active = true
    notifications = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
        guard !Task.isCancelled, let self else { return }
        self.accountChanged()
      }
    }
    let monitor = NWPathMonitor(); path = monitor
    monitor.pathUpdateHandler = { [weak self] value in
      guard value.status == .satisfied else { return }
      Task { @MainActor in self?.refresh() }
    }
    monitor.start(queue: DispatchQueue(label: "Notebook.AccountNetwork"))
    refresh()
  }

  func refresh() {
    guard active else { return }
    again = true
    guard work == nil else { return }
    retry?.cancel(); retry = nil
    let token = epoch
    work = Task { [weak self] in
      guard let self else { return }
      defer { if self.epoch == token { self.work = nil } }
      while self.again, self.active, self.epoch == token, !Task.isCancelled {
        self.again = false
        do {
          if await self.shouldOpenDefault() {
            let id = try await self.service.initialWorkspace(proposed: self.device.identity.workspaceID)
            guard self.active, self.epoch == token, !Task.isCancelled else { return }
            if id != self.device.identity.workspaceID, await self.shouldOpenDefault() {
              self.openWorkspace(id)
              return
            }
          }
          let trust = self.sync.savedTrust
          let retained = trust.records.map {
            NotebookAccountDirectory.Pair(id: $0.credentialID, workspaceID: self.device.identity.workspaceID,
              first: self.device.identity.deviceID, second: $0.identity.deviceID, secret: $0.secret)
          }
          let result = try await self.service.exchange(device: self.device, boundAccount: trust.account ?? self.initialBoundAccount, retained: retained)
          guard self.active, self.epoch == token, !Task.isCancelled else { return }
          let devices = result.directory.credentials(for: self.device).map {
            NotebookTrustedDevice(identity: $0.0.identity, credentialID: $0.1.id, secret: $0.1.secret)
          }
          try await self.sync.applyAccountTrust(account: result.account, devices: devices)
          guard self.active, self.epoch == token, !Task.isCancelled else { return }
          self.account = result.account; self.spaces = result.directory.spaces; self.status = .ready; self.retryDelay = 2
          await self.accountReady(result.account)
          guard self.active, self.epoch == token, !Task.isCancelled else { return }
          try await self.service.observe { [weak self] accountChanged in
            await self?.cloudChanged(accountChanged: accountChanged)
          }
        } catch is CancellationError { return }
        catch {
          guard self.active, self.epoch == token, !Task.isCancelled else { return }
          let cloudCode = (error as? CKError)?.code
          self.logger.error("Account enrollment failed: cloud code \(cloudCode?.rawValue ?? -1), type \(String(reflecting: type(of: error)), privacy: .public)")
          if error as? NotebookAccountError == .unavailable || error as? NotebookAccountError == .changed || cloudCode == .notAuthenticated {
            self.sync.stop()
            self.account = nil; self.spaces = []
            self.status = error as? NotebookAccountError == .changed ? .accountChanged : .needsAccount
            await self.accountUnavailable()
          } else if let error = error as? CKError,
            [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverRecordChanged].contains(error.code) {
            self.status = .waitingForNetwork
          } else if let error = error as? NotebookAccountError {
            self.status = .failed(error.localizedDescription)
          } else if cloudCode == .quotaExceeded {
            self.status = .failed("В iCloud закончилось свободное место. Материалы сохранены на устройстве.")
          } else if cloudCode == .permissionFailure {
            self.status = .failed("Notebook не получил доступ к iCloud. Проверьте доступ в системных настройках.")
          } else {
            self.status = .failed("Не удалось подготовить автоматическое подключение. Попытка повторится; сохранение на устройстве работает.")
          }
          guard self.active, self.epoch == token else { return }
          self.scheduleRetry(token: token)
          return
        }
      }
    }
  }

  private func cloudChanged(accountChanged: Bool) async {
    if accountChanged { self.accountChanged() } else { refresh() }
    await work?.value
  }

  private func accountChanged() {
    guard active else { return }
    // Suspend direct access synchronously, before looking up the new account.
    // A late operation from the old account cannot publish or resume this owner.
    epoch = UUID(); work?.cancel(); work = nil; retry?.cancel(); retry = nil
    sync.stop(); account = nil; spaces = []; status = .checking
    let token = epoch
    work = Task { [weak self] in
      guard let self else { return }
      await self.service.stop(); await self.accountUnavailable()
      guard self.active, self.epoch == token else { return }
      self.work = nil; self.refresh()
    }
  }

  private func scheduleRetry(token: UUID) {
    let delay = retryDelay; retryDelay = min(300, retryDelay * 2)
    retry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self, self.active, self.epoch == token else { return }
      self.retry = nil; self.refresh()
    }
  }

  func stop() async {
    active = false; epoch = UUID(); again = false
    let task = work; work = nil; task?.cancel()
    retry?.cancel(); retry = nil; notifications?.cancel(); notifications = nil
    path?.cancel(); path = nil
    await service.stop()
    await task?.value
  }
}
