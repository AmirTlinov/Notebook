import Foundation
import NotebookCore
import Observation

/// The application cannot construct a store-owning model before archive
/// activation. Fixtures inject their own model and never inspect production.
@MainActor @Observable
final class NotebookApplicationLaunch {
  private(set) var model: NotebookAppModel?
  private(set) var activation: NotebookArchiveLaunch = .unchanged
  private(set) var failure: String?
  private(set) var isChecking = false
  private let root: URL
  private let target: NotebookArchiveTarget?
  private let makeModel: ((NotebookStore, UUID?) throws -> NotebookAppModel)?
  private let isFixture: Bool
  private enum SwitchCancellation: Error { case acceptedLocalWork }

  init(root: URL = NotebookStore.defaultRoot, target: NotebookArchiveTarget? = nil,
    makeModel: ((NotebookStore, UUID?) throws -> NotebookAppModel)? = nil) {
    self.root = root; self.target = target; self.makeModel = makeModel; isFixture = false
  }

  init(fixture model: NotebookAppModel?) {
    self.model = model; root = URL(fileURLWithPath: "/unused-notebook-fixture")
    target = nil; makeModel = nil; isFixture = true
  }

  init(failure: String) {
    self.failure = failure; root = URL(fileURLWithPath: "/unused-notebook-rejected-launch")
    target = nil; makeModel = nil; isFixture = true
  }

  var message: String {
    if isFixture, let failure { return failure }
    if let failure { return "Не удалось открыть Notebook. Сохранённые материалы не изменены. \(failure)" }
    if case .waitingForPair = activation { return "Архив проверен. Ожидается готовность второго устройства…" }
    return "Открываем Notebook…"
  }

  var canRetry: Bool { !isFixture && failure != nil }

  func start() async {
    guard !isFixture, model == nil, !isChecking else { return }
    isChecking = true; failure = nil
    defer { isChecking = false }
    do {
      let root = root, previous = activation
      let target: NotebookArchiveTarget?
      if FileManager.default.fileExists(atPath: NotebookArchiveActivation.controlURL(for: root).path) {
        target = try self.target ?? Self.installedTarget()
      } else { target = nil }
      let work = Task.detached(priority: .userInitiated) {
        let owner = NotebookArchiveActivation()
        if case .waitingForPair(let receipt) = previous { return try owner.admissionStatus(root: root, receipt: receipt) }
        guard let target else { return NotebookArchiveLaunch.unchanged }
        return try owner.launch(root: root, target: target)
      }
      activation = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
      try Task.checkCancellation()
      switch activation {
      case .unchanged, .admitted:
        try Task.checkCancellation()
        let selectedRoot = try makeModel == nil ? NotebookWorkspaceLibrary(originalRoot: root).selectedRoot() : root
        let store = NotebookStore(root: selectedRoot)
        let fresh = !FileManager.default.fileExists(atPath: store.databaseURL.path)
        model = try makeModel?(store, pairingActivationID) ?? NotebookAppModel(store: store,
          allowsCodexRegistration: allowsCodexRegistration, pairingActivationID: pairingActivationID,
          opensDefaultAccountWorkspace: fresh, requiresExistingAccountContent: selectedRoot != root)
        installWorkspaceSelection()
      case .waitingForPair: break
      }
    } catch is CancellationError {
      // A committed activation remains on disk; cancellation cannot restore old
      // bytes or publish a model after the calling scene has disappeared.
    } catch { failure = error.localizedDescription }
  }

  private func installWorkspaceSelection() {
    guard makeModel == nil, !isFixture else { return }
    model?.openAccountWorkspace = { [weak self] id in
      Task { await self?.openWorkspace(id, automatically: false) }
    }
    model?.openDefaultAccountWorkspace = { [weak self] id in
      Task { await self?.openWorkspace(id, automatically: true) }
    }
    if model?.store.root != root,
      let original = try? NotebookStore(root: root).storedWorkspaceID() {
      model?.returnToLocalWorkspace = { [weak self] in
        Task { await self?.openWorkspace(original, automatically: false) }
      }
    }
  }

  private func openWorkspace(_ id: UUID, automatically: Bool) async {
    guard !isChecking, let previous = model else { return }
    isChecking = true
    var retired = false
    var replacement: NotebookAppModel?
    defer { isChecking = false }
    do {
      let currentID = try previous.store.storedWorkspaceID()
      guard currentID != id else { return }
      if automatically {
        guard await previous.prepareAutomaticWorkspaceSwitch() else { previous.refreshDeviceConnection(); return }
      } else {
        guard await previous.finishPendingInteraction() else { throw NotebookTransportError.storageUnavailable }
      }
      guard await previous.shutdown() else { throw NotebookTransportError.storageUnavailable }
      retired = true
      if automatically, !(try previous.automaticWorkspaceCutIsUnchanged()) { throw SwitchCancellation.acceptedLocalWork }
      let library = NotebookWorkspaceLibrary(originalRoot: root)
      let destination = try await Task.detached { try library.prepare(id) }.value
      let next = NotebookAppModel(store: NotebookStore(root: destination),
        allowsCodexRegistration: allowsCodexRegistration, pairingActivationID: pairingActivationID,
        requiresExistingAccountContent: destination != root)
      replacement = next
      await next.start(pageSize: NotebookAppModel.defaultPageSize)
      guard next.loadState == .ready || next.awaitingAccountContent else { throw NotebookTransportError.storageUnavailable }
      _ = try await Task.detached { try library.select(id) }.value
      model = next; failure = nil; installWorkspaceSelection()
    } catch {
      let cancelledForInput = error is SwitchCancellation
      failure = cancelledForInput ? nil : error.localizedDescription
      previous.workspaceSwitchError = cancelledForInput ? nil : "Не удалось открыть пространство. Текущие материалы остались на этом устройстве."
      guard retired else { return }
      if let replacement, !(await replacement.shutdown()) {
        model = replacement
        replacement.workspaceSwitchError = "Не удалось завершить открытие пространства. Изменения остаются на этом устройстве."
        installWorkspaceSelection()
        return
      }
      // The source was not changed or merged. Reopen its same owner after an
      // unsuccessful switch instead of leaving a stopped model on screen.
      model = NotebookAppModel(store: previous.store, allowsCodexRegistration: allowsCodexRegistration,
        pairingActivationID: pairingActivationID, requiresExistingAccountContent: previous.store.root != root)
      model?.workspaceSwitchError = previous.workspaceSwitchError
      installWorkspaceSelection()
      await model?.start(pageSize: NotebookAppModel.defaultPageSize)
    }
  }

  /// Replacing a pair's delivery journals requires fresh trust, not a new
  /// device identity. The durable receipt keeps that trust stable on restart.
  var pairingActivationID: UUID? {
    if case .admitted(let receipt) = activation { receipt.transitionID } else { nil }
  }

  var allowsCodexRegistration: Bool {
    #if os(macOS)
      guard !isFixture, case .admitted(let receipt) = activation, receipt.target.role == .mac,
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        receipt.target.bundleID == Bundle.main.bundleIdentifier,
        root.standardizedFileURL.resolvingSymlinksInPath() == NotebookStore.defaultRoot.standardizedFileURL.resolvingSymlinksInPath() else { return false }
      let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Notebook.app")
      return Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath() == installed.standardizedFileURL.resolvingSymlinksInPath()
    #else
      return false
    #endif
  }

  /// A one-time activation wait belongs to bootstrap, not an extra database or
  /// IPC watcher. Only two small receipts are read on each waiting iteration.
  func waitForAdmission() async {
    await start()
    while !Task.isCancelled, model == nil, failure == nil, !isFixture {
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      await start()
    }
  }

  private static func installedTarget() throws -> NotebookArchiveTarget {
    guard let bundle = Bundle.main.bundleIdentifier,
      let actor = UserDefaults.standard.string(forKey: "notebook.actor-id").flatMap(UUID.init(uuidString:)) else {
      throw NotebookStorageError.invalidTransaction("existing application identity is missing")
    }
    #if os(iOS)
      return .init(role: .iPad, bundleID: bundle, actorID: actor)
    #else
      return .init(role: .mac, bundleID: bundle, actorID: actor)
    #endif
  }
}
