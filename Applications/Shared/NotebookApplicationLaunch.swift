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
  private let makeModel: ((NotebookStore, UUID?) -> NotebookAppModel)?
  private let isFixture: Bool

  init(root: URL = NotebookStore.defaultRoot, target: NotebookArchiveTarget? = nil,
    makeModel: ((NotebookStore, UUID?) -> NotebookAppModel)? = nil) {
    self.root = root; self.target = target; self.makeModel = makeModel; isFixture = false
  }

  init(fixture model: NotebookAppModel?) {
    self.model = model; root = URL(fileURLWithPath: "/unused-notebook-fixture")
    target = nil; makeModel = nil; isFixture = true
  }

  var message: String {
    if let failure { return "Перенос не завершён. Исходные копии сохранены. \(failure)" }
    if case .waitingForPair = activation { return "Архив проверен. Ожидается готовность второго устройства…" }
    return "Проверяется сохранённый архив…"
  }

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
        if case .admitted(let receipt) = activation {
          try NotebookKeychainPairingStore(activationID: receipt.transitionID)
            .consumeInstallationGrant(root: root, receipt: receipt)
        }
        let store = NotebookStore(root: root)
        model = makeModel?(store, pairingActivationID) ?? NotebookAppModel(store: store,
          allowsCodexRegistration: allowsCodexRegistration, pairingActivationID: pairingActivationID)
      case .waitingForPair: break
      }
    } catch is CancellationError {
      // A committed activation remains on disk; cancellation cannot restore old
      // bytes or publish a model after the calling scene has disappeared.
    } catch { failure = error.localizedDescription }
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
