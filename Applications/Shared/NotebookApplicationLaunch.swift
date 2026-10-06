import Foundation
import CryptoKit
import Network
import NotebookCore
import Observation
import OSLog

/// The application cannot construct a store-owning model before archive
/// activation. Fixtures inject their own model and never inspect production.
@MainActor @Observable
final class NotebookApplicationLaunch {
  private(set) var model: NotebookAppModel?
  private(set) var activation: NotebookArchiveLaunch = .unchanged
  private(set) var failure: String?
  private(set) var isChecking = false
  var showsWorkspaces = false
  var workspaceTab: NotebookWorkspaceTab = .spaces
  private(set) var workspaceList: [Workspace] = []
  private(set) var workspaceError: String?
  private(set) var catalogError: String?
  private(set) var catalogAccount: String?
  private(set) var hasNoWorkspace = false
  private var readingCatalog = false
  private var retiredWorkspaces: Set<UUID> = []
  private var catalogGeneration = UUID()
  @ObservationIgnored private var deletionNetwork: NWPathMonitor?
  private let catalogCloud = NotebookAccountCloud()
  typealias Workspace = NotebookRuntimeWorkspace
  private var library: NotebookWorkspaceLibrary { .init(originalRoot: root) }
  var selectedWorkspaceID: UUID? { model?.admittedWorkspaceID }
  private var runtimeLease: NotebookIPCProcessLease?
  private let runtimeSocketURL: URL?
  private struct WorkspaceOpening {
    enum Stage { case opening, retiring(NotebookAppModel, discardCandidate: Bool) }
    let id: UUID
    let model: NotebookAppModel
    let previous: NotebookAppModel?
    let transition: NotebookAppModel.AutomaticWorkspaceTransition?
    let creating: Bool
    let task: Task<Void, Never>
    var stage: Stage = .opening

    var retirementOwner: NotebookAppModel? {
      if case .retiring(let owner, _) = stage { owner } else { nil }
    }
  }
  @ObservationIgnored private var workspaceOpening: WorkspaceOpening?
  var hasPendingWorkspaceRetirement: Bool { workspaceOpening?.retirementOwner != nil }
  var canRetryWorkspaceTransition: Bool { workspaceOpening != nil && !isChecking }

  /// Every lifecycle operation visits the same retained model owners, even
  /// before a candidate is selected or after its source starts retirement.
  private var ownedWorkspaceModels: [NotebookAppModel] {
    var owners = model.map { [$0] } ?? []
    #if os(macOS)
      owners.append(contentsOf: retainedModels.values)
    #endif
    if let opening = workspaceOpening {
      owners.append(opening.model)
      if let retiring = opening.retirementOwner { owners.append(retiring) }
    }
    var seen = Set<ObjectIdentifier>()
    return owners.filter { seen.insert(ObjectIdentifier($0)).inserted }
  }

  #if os(macOS)
    private let workspaceWriters = NotebookWorkspaceWriters()
    @ObservationIgnored private(set) lazy var codexHost = NotebookCodexHost(workspaceWriters: workspaceWriters)
    private var retainedModels: [UUID: NotebookAppModel] = [:]
    private var defaultCommandServer: NotebookIPCServer?
    private(set) var existingRuntimeSocketURL: URL?
    private var archiveAdmitted = false
    private var runtimeIsStopping = false
    private var runtimeNeedsRecovery = false
    private final class WorkspaceDrain {
      var models: [NotebookAppModel]
      var task: Task<Void, Never>?
      init(models: [NotebookAppModel]) { self.models = models }
    }
    @ObservationIgnored private var workspaceDrain: WorkspaceDrain?
    private var recoveryWorkspaceModels: [NotebookAppModel] {
      var seen = Set<ObjectIdentifier>()
      // Retirement can remove a candidate from the live registry before its
      // host's published FileWork reports a storage failure. Retry still owns
      // that exact model and writer through the retained process drain.
      return (ownedWorkspaceModels + (workspaceDrain?.models ?? []))
        .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
    private var isBootstrapping = false
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []
  #endif

  private let root: URL
  private let target: NotebookArchiveTarget?
  private let makeModel: ((NotebookStore, UUID?) throws -> NotebookAppModel)?
  private let isFixture: Bool
  private let arguments: [String]
  private enum SwitchCancellation: Error { case acceptedLocalWork }

  init(root: URL = NotebookStore.defaultRoot, target: NotebookArchiveTarget? = nil,
    arguments: [String] = ProcessInfo.processInfo.arguments,
    runtimeSocketURL: URL? = nil,
    makeModel: ((NotebookStore, UUID?) throws -> NotebookAppModel)? = nil) {
    self.root = root; self.target = target; self.makeModel = makeModel; isFixture = false
    self.arguments = arguments
    #if os(macOS)
      self.runtimeSocketURL = NotebookStore.canonicalWorkspacePath(root)
        == NotebookStore.canonicalWorkspacePath(NotebookStore.defaultRoot)
          ? NotebookIPC.defaultSocketURL : runtimeSocketURL
    #else
      self.runtimeSocketURL = runtimeSocketURL ?? (makeModel == nil ? Self.acceptedWitnessLeaseEndpoint(root: root) : nil)
    #endif
  }

  init(fixture model: NotebookAppModel?) {
    self.model = model; root = URL(fileURLWithPath: "/unused-notebook-fixture")
    target = nil; makeModel = nil; isFixture = true; arguments = []
    runtimeSocketURL = nil
    installWorkspaceSelection()
  }

  init(failure: String) {
    self.failure = failure; root = URL(fileURLWithPath: "/unused-notebook-rejected-launch")
    target = nil; makeModel = nil; isFixture = true; arguments = []
    runtimeSocketURL = nil
  }

  var message: String {
    if isFixture, let failure { return failure }
    if hasNoWorkspace { return "Выберите или создайте пространство." }
    if let failure { return "Не удалось открыть Notebook. Сохранённые материалы не изменены. \(failure)" }
    if case .waitingForPair = activation { return "Архив проверен. Ожидается готовность второго устройства…" }
    return "Открываем Notebook…"
  }

  var canRetry: Bool { !isFixture && failure != nil }

  func start() async {
    #if os(macOS)
      guard !runtimeIsStopping, !runtimeNeedsRecovery else { return }
      if isBootstrapping {
        await awaitCurrentWorkspaceOperation()
        return
      }
    #endif
    guard !isFixture, model == nil, !isChecking, !hasNoWorkspace else { return }
    isChecking = true; failure = nil
    #if os(macOS)
      isBootstrapping = true
    #endif
    defer {
      #if os(macOS)
        isBootstrapping = false
      #endif
      finishOperation()
    }
    do {
      try claimRuntime()
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
        #if os(macOS)
          archiveAdmitted = true
        #endif
        try retireRequestedPeer()
        try library.finishRemovals()
        guard let selectedRoot = try library.selectedRoot() else {
          hasNoWorkspace = true
          await refreshWorkspaces()
          return
        }
        hasNoWorkspace = false
        let store = NotebookStore(root: selectedRoot)
        let fresh = !FileManager.default.fileExists(atPath: store.databaseURL.path)
        model = try makeWorkspaceModel(store: store,
          opensDefaultAccountWorkspace: fresh, requiresExistingAccountContent: selectedRoot != root,
          expectedWorkspaceID: try library.catalog().selectedID)
        installWorkspaceSelection()
      case .waitingForPair: break
      }
    } catch is CancellationError {
      // A committed activation remains on disk; cancellation cannot restore old
      // bytes or publish a model after the calling scene has disappeared.
    } catch {
      Logger(subsystem: "com.amirtlinov.notebook", category: "WorkspaceLifecycle")
        .error("Workspace launch failed: \(String(reflecting: error), privacy: .public)")
      failure = error.localizedDescription
    }
  }

  private var mayAccessWorkspace: Bool {
    guard workspaceOpening == nil else { return false }
    #if os(macOS)
      return !runtimeIsStopping && !runtimeNeedsRecovery && (isFixture || archiveAdmitted) && (runtimeSocketURL == nil || runtimeLease != nil)
    #else
      return isFixture || runtimeSocketURL == nil || runtimeLease != nil
    #endif
  }

  #if os(macOS)
    func executeRuntimeCommand(_ command: NotebookCommand) async throws -> JSONValue {
      guard runtimeLease != nil, defaultCommandServer != nil else {
        throw CollaborationError("runtime_owner_required", "Запрос требует действующего владельца Notebook runtime.")
      }
      switch command.command {
      case .runtimeStatus: return try .encode(runtimeStatus())
      case .runtimeWorkspace:
        guard let request = command.runtimeWorkspace else {
          throw CollaborationError("invalid_runtime_workspace", "Нужно действие пространства.")
        }
        try request.validate()
        if request.action == .retry, isBootstrapping { await start() }
        if request.action == .list, runtimeNeedsRecovery, !runtimeIsStopping {
          return try .encode(NotebookRuntimeWorkspaceResponse(status: runtimeStatus(),
            workspaces: workspaceList, error: workspaceError, catalogError: catalogError))
        }
        guard !runtimeIsStopping, !isChecking, !runtimeNeedsRecovery || request.action == .retry else {
          throw CollaborationError("owner_unavailable", "Notebook завершает текущий переход пространства.")
        }
        guard workspaceOpening == nil || request.action == .retry || request.action == .list else {
          throw CollaborationError("owner_unavailable", "Сначала завершите восстановление открываемого пространства.")
        }
        guard archiveAdmitted || request.action == .retry else {
          throw CollaborationError("owner_unavailable", "Пространства доступны после допуска текущих данных.")
        }
        workspaceError = nil
        var error: String?
        var selectedModel: NotebookAppModel?
        do {
          switch request.action {
          case .list: await refreshWorkspaces()
          case .create:
            let id = request.id!, catalog = try library.catalog()
            if catalog.entries.contains(where: { $0.id == id }) {
              await openWorkspace(id)
            } else {
              guard !catalog.deleting.contains(id), catalog.pendingCloudDeletion[id] == nil else {
                throw CollaborationError("workspace_missing", "Удаление этого пространства ещё не завершено.")
              }
              await openWorkspace(id, creatingName: try NotebookWorkspaceLibrary.name(request.name!))
            }
            selectedModel = workspaceModel(id)
            if selectedModel == nil { error = workspaceError ?? failure ?? "Не удалось создать пространство." }
          case .select, .rename:
            let id = request.id!
            if id != selectedWorkspaceID && !workspaceList.contains(where: { $0.id == id && !$0.deleting }) {
              guard try library.catalog().entries.contains(where: { $0.id == id }) else {
                throw CollaborationError("workspace_missing", "Выберите пространство из текущего списка.")
              }
            }
            if request.action == .select {
              await openWorkspace(id)
              selectedModel = workspaceModel(id)
              if selectedModel == nil { error = workspaceError ?? failure ?? "Не удалось открыть пространство." }
            } else if !(await renameWorkspace(id, name: request.name!)) { error = workspaceError ?? "Не удалось переименовать пространство." }
          case .retry:
            let originalOpeningID = workspaceOpening?.id
            await retryRuntimeWorkspace()
            if let id = request.id {
              if workspaceModel(id) == nil {
                if originalOpeningID == id {
                  // The retained automatic attempt can roll back after new
                  // source input. Its Retry must not create a manual successor.
                  selectedModel = model
                  break
                }
                guard mayAccessWorkspace, try library.catalog().entries.contains(where: { $0.id == id }) else {
                  throw CollaborationError("workspace_missing", "Пространство этой панели недоступно.")
                }
                await openWorkspace(id)
              }
              selectedModel = workspaceModel(id)
              if selectedModel == nil { error = workspaceError ?? failure ?? "Не удалось восстановить пространство этой панели." }
            }
            if let owner = selectedModel ?? model, owner.allowsCodexRegistration || owner.acceptance != nil {
              await owner.startCodexSidecar()
            }
          }
        } catch let failure { error = failure.localizedDescription }
        let responseModel = selectedModel ?? model
        return try .encode(NotebookRuntimeWorkspaceResponse(status: runtimeStatus(model: responseModel),
          workspaces: workspaceList,
          error: error ?? workspaceError ?? failure, catalogError: catalogError))
      default:
        guard !runtimeIsStopping, !runtimeNeedsRecovery, allowsCodexRegistration, let model else {
          throw CollaborationError("owner_unavailable", "Notebook ещё открывает пространство.")
        }
        return try await model.executeLocalCommand(command)
      }
    }

    private func workspaceModel(_ id: UUID) -> NotebookAppModel? {
      if workspaceOpening?.id == id { return workspaceOpening?.model }
      if model?.admittedWorkspaceID == id { return model }
      return retainedModels[id]
    }

    private var persistenceRecoveryMessage: String? {
      recoveryWorkspaceModels.lazy.compactMap(\.persistenceFailure).first
        ?? workspaceWriters.persistenceQueues.lazy.compactMap(\.failure).first
    }

    private func runtimeStatus(model observedModel: NotebookAppModel? = nil) -> NotebookRuntimeBootstrapStatus {
      let model = observedModel ?? self.model
      let state: NotebookRuntimeBootstrapStatus.State
      let detail: String?
      if runtimeIsStopping { state = .failed; detail = "Notebook завершает работу." }
      else if runtimeNeedsRecovery { state = .failed; detail = "Сохранение не завершено. Повторите попытку, чтобы восстановить пространство." }
      else if let failure { state = .failed; detail = failure }
      else if let model, case .failed(let reason) = model.loadState { state = .failed; detail = reason }
      else if let reason = persistenceRecoveryMessage { state = .failed; detail = "Изменения ещё не сохранены. \(reason)" }
      else if hasNoWorkspace { state = .workspaceRequired; detail = message }
      else if let model, model.loadState == .ready {
        if model.runtimeSocketKey != nil { state = .ready; detail = nil }
        else if model.runtimeStartupPending { state = .opening; detail = message }
        else { state = .failed; detail = model.agentStartupError ?? "Не удалось открыть локальное подключение пространства." }
      }
      else { state = .opening; detail = message }
      return .init(ready: !runtimeIsStopping, pid: Int(ProcessInfo.processInfo.processIdentifier),
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown", state: state,
        workspaceID: model?.admittedWorkspaceID, socketKey: model?.runtimeSocketKey, message: detail)
    }

    private func retryRuntimeWorkspace() async {
      workspaceError = nil
      guard await retryRetiringWorkspace() else { return }
      if runtimeNeedsRecovery {
        isChecking = true; catalogGeneration = UUID()
        for owner in recoveryWorkspaceModels { owner.retryPendingPersistence() }
        for writer in workspaceWriters.persistenceQueues { writer.retry() }
        let drained = await drainWorkspaceOwners()
        if drained {
          if let opening = workspaceOpening {
            guard case .completed = await opening.model.waitForPersistenceLifecycle(opening.task) else {
              finishOperation(); return
            }
          }
          model = nil; retainedModels.removeAll()
          codexHost = NotebookCodexHost(workspaceWriters: workspaceWriters)
          runtimeNeedsRecovery = false
        } else { workspaceError = "Сохранение ещё не завершено. Принятые изменения остаются у прежнего владельца." }
        finishOperation()
        guard drained, !runtimeIsStopping else { return }
      }
      // Bootstrap can itself own a retained accepted write. Repair its writer
      // before joining startup or completing the addressed workspace selection.
      guard await retrySavedWork() else { return }
      if let opening = workspaceOpening {
        guard case .completed = await opening.model.waitForPersistenceLifecycle(opening.task),
          await retryRetiringWorkspace() else { return }
      }
      let needsRestart = model.map { model in
        if case .failed = model.loadState { return true }
        return model.loadState == .ready && !model.runtimeStartupPending && model.runtimeSocketKey == nil
      } ?? false
      if let previous = model, needsRestart {
        isChecking = true
        let stopped = await previous.shutdown()
        finishOperation()
        guard stopped, mayAccessWorkspace else {
          if !stopped { runtimeNeedsRecovery = true }
          workspaceError = "Не удалось завершить прежнюю попытку открытия. Сохранение остаётся у того же владельца."
          return
        }
        model = nil
      }
      failure = nil
      await start()
      await model?.start(pageSize: NotebookAppModel.defaultPageSize)
      if hasNoWorkspace { await refreshWorkspaces() }
    }

    private func retrySavedWork() async -> Bool {
      let owners = recoveryWorkspaceModels.filter { $0.persistenceFailure != nil }
      let writers = workspaceWriters.persistenceQueues.filter { $0.failure != nil }
      guard !owners.isEmpty || !writers.isEmpty else { return true }
      isChecking = true
      defer { finishOperation() }
      for owner in owners { owner.retryPendingPersistence() }
      for writer in writers { writer.retry() }
      var saved = true
      for owner in owners {
        if !(await owner.finishPendingInteraction()) { saved = false }
      }
      for writer in writers { if !(await writer.flush()) { saved = false } }
      if !saved { workspaceError = persistenceRecoveryMessage ?? "Сохранение ещё не завершено. Принятые изменения остаются у прежнего владельца." }
      return saved
    }

    private func awaitCurrentWorkspaceOperation() async {
      guard isChecking || readingCatalog else { return }
      await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func resumeWorkspaceOperationWaiters() {
      guard !isChecking, !readingCatalog else { return }
      let waiters = operationWaiters; operationWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }

    /// Recovery runs inside IPC, so only the process termination path may
    /// drain the default server. Both paths retire the same workspace owners.
    private func drainWorkspaceOwners() async -> Bool {
      let drain: WorkspaceDrain
      if let existing = workspaceDrain { drain = existing }
      else {
        // Retirement/startup may remove a candidate from the live registry
        // while we await it. Its model still owns weak host/source callbacks.
        drain = .init(models: ownedWorkspaceModels)
        workspaceDrain = drain
      }
      if drain.task == nil {
        guard await drainWorkspaceModels(drain.models) else { return false }
        guard workspaceDrain === drain else { return false }
        var models = Set(drain.models.map { ObjectIdentifier($0) })
        drain.models.append(contentsOf: ownedWorkspaceModels.filter { models.insert(ObjectIdentifier($0)).inserted })
        // Another shutdown observer can finish the same model join first.
        // Recheck ownership after that await before constructing the host task.
        if drain.task == nil {
          let sourceModels = drain.models
          var seen = Set<ObjectIdentifier>()
          let hosts = (sourceModels.compactMap(\.codexHost) + [codexHost])
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
          drain.task = Task {
            for host in hosts { await host.shutdown() }
            // Keep weak model/source callbacks backed through every host and
            // FileWork await, even if the Launch itself loses its last view.
            withExtendedLifetime(sourceModels) { }
          }
        }
      }
      guard let task = drain.task else { return false }
      // Injected model writers and the registry use the same queue lifecycle
      // boundary. A failure may first occur in FileWork AFTER Model.shutdown.
      let models = drain.models
      let hasRegisteredWriters = !workspaceWriters.persistenceQueues.isEmpty
      let joined: Bool
      if models.isEmpty && !hasRegisteredWriters {
        await task.value; joined = true
      } else {
        joined = await withTaskGroup(of: Bool.self) { group in
          if hasRegisteredWriters {
            group.addTask { [workspaceWriters] in
              if case .completed = await workspaceWriters.waitForLifecycle(task) { return true }
              return false
            }
          }
          for model in models {
            group.addTask {
              if case .completed = await model.waitForPersistenceLifecycle(task) { return true }
              return false
            }
          }
          let result = await group.next()!
          group.cancelAll()
          return result
        }
      }
      guard joined, await workspaceWriters.shutdown() else { return false }
      if workspaceDrain === drain { workspaceDrain = nil }
      return true
    }

  #endif

  /// Claim the existing process lease before archive/catalog/store access.
  /// iPad keeps its stable owner file beside the switchable workspace root;
  /// both platforms retain this descriptor through a failed shutdown/Retry.
  private func claimRuntime() throws {
    guard runtimeLease == nil, let runtimeSocketURL else { return }
    #if os(macOS)
      existingRuntimeSocketURL = nil
      do {
        let lease = try NotebookIPCProcessLease(socketURL: runtimeSocketURL)
        let server = NotebookIPCServer(socketURL: runtimeSocketURL) { [weak self] command in
          guard let self else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
          return try await self.executeRuntimeCommand(command)
        }
        try server.start()
        workspaceWriters.bindAcceptedWitnessLease(lease)
        defaultCommandServer = server; runtimeLease = lease
      } catch {
        if (error as? CollaborationError)?.code == "ipc_owner_running" { existingRuntimeSocketURL = runtimeSocketURL }
        throw error
      }
    #else
      if runtimeSocketURL == Self.acceptedWitnessLeaseEndpoint(root: root) {
        // Application Support may not exist on a first iPad launch. Prepare
        // only its platform parent; the lease still validates/creates its own
        // private directory before any workspace or catalog is opened.
        try FileManager.default.createDirectory(at: runtimeSocketURL.deletingLastPathComponent().deletingLastPathComponent(),
          withIntermediateDirectories: true)
      }
      runtimeLease = try NotebookIPCProcessLease(socketURL: runtimeSocketURL)
    #endif
  }

  #if !os(macOS)
    static func acceptedWitnessLeaseEndpoint(root: URL) -> URL {
      let canonical = URL(fileURLWithPath: NotebookStore.canonicalWorkspacePath(root), isDirectory: true)
      let identity = SHA256.hash(data: Data(canonical.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
      return canonical.deletingLastPathComponent().appendingPathComponent(".notebook-runtime", isDirectory: true)
        .appendingPathComponent(identity + ".sock")
    }
  #endif

  /// Explicit maintenance of the selected workspace, performed only by its
  /// installed application after archive admission and before model/migration.
  /// The request is pinned to the observed workspace and cursor, not a path.
  private func retireRequestedPeer() throws {
    let flag = "--notebook-retire-peer"
    guard let index = arguments.firstIndex(of: flag) else { return }
    struct Request: Decodable { let peerID: UUID; let workspaceID: UUID; let expectedCursor: UInt64 }
    guard arguments.filter({ $0 == flag }).count == 1, index + 1 < arguments.count,
      arguments[index + 1].utf8.count <= 1024 else { throw NotebookStorageError.invalidTransaction("peer retirement request") }
    let request = try JSONDecoder().decode(Request.self, from: Data(arguments[index + 1].utf8))
    let catalog = try library.catalog()
    guard catalog.selectedID == request.workspaceID, !catalog.deleting.contains(request.workspaceID),
      catalog.pendingCloudDeletion[request.workspaceID] == nil else { throw NotebookStorageError.transactionConflict }
    try NotebookStore(root: library.root(for: request.workspaceID)).retireReplicationPeer(request.peerID,
      workspaceID: request.workspaceID, expectedCursor: request.expectedCursor)
  }

  private func makeWorkspaceModel(store: NotebookStore, opensDefaultAccountWorkspace: Bool = false,
    requiresExistingAccountContent: Bool = false, expectedWorkspaceID: UUID? = nil) throws -> NotebookAppModel {
    if let makeModel {
      let model = try makeModel(store, pairingActivationID)
      if let expectedWorkspaceID { try model.admitWorkspaceIdentity(expectedWorkspaceID) }
      return model
    }
    #if os(macOS)
      let writer: NotebookPersistenceQueue? = workspaceWriters.persistence(for: store)
      let socketID = SHA256.hash(data: Data(store.root.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
      let socket = NotebookIPC.defaultSocketURL.deletingLastPathComponent().appendingPathComponent(socketID + ".sock")
    #else
      let writer = NotebookPersistenceQueue(store: store, acceptedWitnessLease: runtimeLease)
    #endif
    #if os(macOS)
      let model = NotebookAppModel(store: store, commandSocketURL: socket, allowsCodexRegistration: allowsCodexRegistration,
        pairingActivationID: pairingActivationID, opensDefaultAccountWorkspace: opensDefaultAccountWorkspace,
        requiresExistingAccountContent: requiresExistingAccountContent, expectedWorkspaceID: expectedWorkspaceID,
        persistenceQueue: writer)
    #else
    let model = NotebookAppModel(store: store, allowsCodexRegistration: allowsCodexRegistration,
      pairingActivationID: pairingActivationID, opensDefaultAccountWorkspace: opensDefaultAccountWorkspace,
      requiresExistingAccountContent: requiresExistingAccountContent, expectedWorkspaceID: expectedWorkspaceID,
      persistenceQueue: writer)
    #endif
    #if os(macOS)
      model.codexHost = codexHost
    #endif
    return model
  }

  func shutdown() async -> Bool {
    #if os(macOS)
      runtimeIsStopping = true
      deletionNetwork?.cancel(); deletionNetwork = nil
      await awaitCurrentWorkspaceOperation()
      guard await drainWorkspaceOwners() else {
        runtimeNeedsRecovery = true; runtimeIsStopping = false
        return false
      }
      retainedModels.removeAll()
      await defaultCommandServer?.stopAndDrain(); defaultCommandServer = nil
      // Process ownership outlives shutdown acknowledgement. Any suspended
      // launch/catalog call still retains this owner; ARC/process exit releases
      // its lease only after that lifetime ends.
    #else
      guard await drainWorkspaceModels(ownedWorkspaceModels) else { return false }
    #endif
    return true
  }

  private func drainWorkspaceModels(_ owners: [NotebookAppModel]) async -> Bool {
    for owner in owners { guard await owner.shutdown() else { return false } }
    if let opening = workspaceOpening {
      guard case .completed = await opening.model.waitForPersistenceLifecycle(opening.task) else { return false }
    }
    return await finishRetiringWorkspace()
  }

  private func installWorkspaceSelection() {
    guard let model else { return }
    model.openWorkspaceLibrary = { [weak self] tab in self?.workspaceTab = tab; self?.showsWorkspaces = true }
    guard !isFixture else { return }
    if let id = model.admittedWorkspaceID, let entry = try? library.catalog().entries.first(where: { $0.id == id }) {
      model.workspaceName = entry.name
      model.publishesWorkspaceName = entry.needsNamePublication
    }
    model.accountWorkspaceNameSaved = { [weak self, weak model] name, deleted in
      guard let self, let model, let id = model.admittedWorkspaceID else { return }
      do {
        for entry in try self.library.catalog().entries where deleted.contains(entry.id) { self.retireWorkspace(entry.id) }
        try self.library.acknowledgeName(id, name: name)
        let pending = try self.library.catalog().entries.first(where: { $0.id == id })?.needsNamePublication ?? false
        if !pending { model.workspaceName = name; model.publishesWorkspaceName = false; model.accountConnection?.publishName = false }
      } catch { self.workspaceError = error.localizedDescription }
    }
    model.workspaceDeleted = { [weak self, weak model] in
      guard let self, let model, let id = model.admittedWorkspaceID else { return }
      self.retireWorkspace(id)
    }
    model.openDefaultAccountWorkspace = { [weak self] id in
      Task { await self?.openWorkspace(id, automatically: true) }
    }

  }

  func openWorkspace(_ id: UUID, automatically: Bool = false, creatingName: String? = nil) async {
    guard mayAccessWorkspace, !isChecking else { return }
    let previous = model
    isChecking = true; catalogGeneration = UUID()
    var transition: NotebookAppModel.AutomaticWorkspaceTransition?
    var openingOwnsTransition = false
    defer {
      if !openingOwnsTransition, let transition { previous?.rollbackAutomaticWorkspaceSwitch(transition) }
      finishOperation()
    }
    do {
      guard try library.catalog().pendingCloudDeletion[id] == nil else {
        throw NotebookStorageError.invalidTransaction("Удаление этого пространства ещё не завершено.")
      }
      let currentID = previous?.admittedWorkspaceID
      guard currentID != id else { showsWorkspaces = false; return }
      if let previous, automatically {
        guard let prepared = await previous.prepareAutomaticWorkspaceSwitch() else {
          previous.refreshDeviceConnection(); return
        }
        transition = prepared
      } else if let previous {
        guard await previous.finishPendingInteraction(boundary: .acceptedInput) else { throw NotebookTransportError.storageUnavailable }
      }
      #if os(macOS)
      if previous != nil, currentID != nil, retainedModels.count >= 7, retainedModels[id] == nil {
        var evicted = false
        for (candidate, retained) in retainedModels where !(await codexHost.hasActiveWork(workspace: candidate)) {
          guard await retained.shutdown() else { throw NotebookTransportError.storageUnavailable }
          try await codexHost.removeWorkspace(candidate)
          try await workspaceWriters.remove(root: retained.store.root)
          retainedModels.removeValue(forKey: candidate); evicted = true; break
        }
        guard evicted else { throw NotebookTransportError.resourceLimit }
      }
      #endif
      let library = NotebookWorkspaceLibrary(originalRoot: root)
      let destination = try await Task.detached { try library.prepare(id) }.value
      #if os(macOS)
      let wasRetained = retainedModels[id] != nil
      let next = try retainedModels[id] ?? makeWorkspaceModel(store: NotebookStore(root: destination),
        requiresExistingAccountContent: creatingName == nil && destination != root, expectedWorkspaceID: id)
      #else
      let wasRetained = false
      let next = try makeWorkspaceModel(store: NotebookStore(root: destination),
        requiresExistingAccountContent: creatingName == nil && destination != root, expectedWorkspaceID: id)
      #endif
      next.workspaceName = creatingName ?? workspaceList.first(where: { $0.id == id })?.name
        ?? (try? library.catalog().entries.first(where: { $0.id == id })?.name) ?? "Моё пространство"
      next.publishesWorkspaceName = creatingName != nil || ((try? library.catalog().entries.first(where: { $0.id == id })?.needsNamePublication) ?? false)
      let preparedTransition = transition
      // One retained startup task owns this selection through a storage fault.
      // The previous source stays live until the final synchronous commit.
      let task = Task { [self] in
        await next.start(pageSize: NotebookAppModel.defaultPageSize)
        await next.finishStartup()
        do {
          guard next.loadState == .ready || next.awaitingAccountContent else { throw NotebookTransportError.storageUnavailable }
          if let preparedTransition, let previous {
            guard try previous.freezeAutomaticWorkspaceSwitch(preparedTransition) else { throw SwitchCancellation.acceptedLocalWork }
          }
          _ = try library.select(id, name: next.workspaceName, publishName: next.publishesWorkspaceName)
          #if os(macOS)
            if let previous, let currentID { retainedModels[currentID] = previous }
            retainedModels.removeValue(forKey: id)
          #endif
          model = next; failure = nil; workspaceError = nil
          hasNoWorkspace = false; showsWorkspaces = false
          if let preparedTransition { previous?.commitAutomaticWorkspaceSwitch(preparedTransition) }
          installWorkspaceSelection()
          if next.accountConnection?.spaces.first(where: { $0.id == id })?.name == next.workspaceName {
            do { try library.acknowledgeName(id, name: next.workspaceName) }
            catch { workspaceError = error.localizedDescription }
          }
          let row = Workspace(id: id, name: next.workspaceName, local: true,
            remote: workspaceList.contains(where: { $0.id == id && $0.remote }) || next.accountConnection?.spaces.contains(where: { $0.id == id }) == true,
            deleting: false)
          if let index = workspaceList.firstIndex(where: { $0.id == id }) { workspaceList[index] = row }
          else { workspaceList.append(row) }
          #if !os(macOS)
            if let previous {
              workspaceOpening?.stage = .retiring(previous, discardCandidate: false)
              _ = await finishRetiringWorkspace()
              return
            }
          #endif
          clearWorkspaceOpening(next)
        } catch {
          if let preparedTransition { previous?.rollbackAutomaticWorkspaceSwitch(preparedTransition) }
          workspaceError = error is SwitchCancellation || error is CancellationError ? nil : error.localizedDescription
          if previous == nil { failure = workspaceError }
          // A failed destination never replaces or reconstructs the source.
          // Its accepted startup is joined before discarding its owner.
          if !wasRetained {
            workspaceOpening?.stage = .retiring(next, discardCandidate: true)
            _ = await finishRetiringWorkspace()
          } else { clearWorkspaceOpening(next) }
        }
      }
      workspaceOpening = .init(id: id, model: next, previous: previous, transition: preparedTransition,
        creating: creatingName != nil, task: task)
      openingOwnsTransition = true
      guard case .completed = await next.waitForPersistenceLifecycle(task) else {
        workspaceError = next.persistenceFailure ?? "Открытие ожидает восстановления сохранения."
        return
      }
    } catch {
      workspaceError = error is SwitchCancellation || error is CancellationError ? nil : error.localizedDescription
      if previous == nil { failure = workspaceError }
    }
  }

  private func clearWorkspaceOpening(_ candidate: NotebookAppModel) {
    guard workspaceOpening?.model === candidate else { return }
    workspaceOpening = nil
  }

  /// The same transition retains a committed source or a failed destination
  /// until its accepted tail actually drains. Retry never constructs a model.
  @discardableResult
  func finishRetiringWorkspace() async -> Bool {
    guard let opening = workspaceOpening,
      case .retiring(let owner, let discardCandidate) = opening.stage else { return true }
    guard await owner.shutdown() else {
      workspaceError = "Сохранение прежнего владельца ещё не завершено. Повторите сохранение."
      return false
    }
    if discardCandidate {
      #if os(macOS)
        do {
          try await codexHost.removeWorkspace(opening.id)
          try await workspaceWriters.remove(root: owner.store.root)
        } catch { workspaceError = error.localizedDescription; return false }
      #endif
      if opening.creating {
        do { try library.remove(opening.id) }
        catch { workspaceError = error.localizedDescription; return false }
      }
    }
    clearWorkspaceOpening(opening.model)
    return true
  }

  @discardableResult
  func retryRetiringWorkspace() async -> Bool {
    workspaceOpening?.retirementOwner?.retryPendingPersistence()
    let finished = await finishRetiringWorkspace()
    if finished { workspaceError = nil }
    return finished
  }

  /// A user retry attaches to the accepted transition. It opens no new model,
  /// task or writer, including when the destination has not published a scene.
  @discardableResult
  func retryWorkspaceTransition() async -> Bool {
    guard canRetryWorkspaceTransition, let opening = workspaceOpening else { return false }
    #if os(macOS)
      await retryRuntimeWorkspace()
      return workspaceOpening == nil
    #else
      isChecking = true; workspaceError = nil
      defer { finishOperation() }
      if opening.retirementOwner != nil { return await retryRetiringWorkspace() }
      opening.model.retryPendingPersistence()
      guard await opening.model.finishPendingInteraction(boundary: .acceptedInput),
        case .completed = await opening.model.waitForPersistenceLifecycle(opening.task) else {
        workspaceError = opening.model.persistenceFailure ?? "Открытие ожидает восстановления сохранения."
        return false
      }
      return await retryRetiringWorkspace()
    #endif
  }

  /// A confirmed offline deletion resumes on connectivity, not a timer or a
  /// ritual "sync now" button. No catalog monitor exists without pending work.
  private func observePendingDeletions() {
    guard !isFixture, mayAccessWorkspace else { return }
    let pending = (try? library.catalog().pendingCloudDeletion.isEmpty) == false
    guard pending else { deletionNetwork?.cancel(); deletionNetwork = nil; return }
    guard deletionNetwork == nil else { return }
    let monitor = NWPathMonitor(); deletionNetwork = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor in await self?.refreshWorkspaces() }
    }
    monitor.start(queue: DispatchQueue(label: "Notebook.WorkspaceDeletion"))
  }

  private func finishOperation() {
    isChecking = false
    observePendingDeletions()
    if let id = retiredWorkspaces.first {
      retiredWorkspaces.remove(id)
      Task { await self.removeWorkspace(id, everywhere: false) }
    }
    #if os(macOS)
      resumeWorkspaceOperationWaiters()
    #endif
  }

  private func retireWorkspace(_ id: UUID) {
    retiredWorkspaces.insert(id)
    if !isChecking { finishOperation() }
  }

  func refreshWorkspaces() async {
    guard !isFixture, mayAccessWorkspace, !readingCatalog else { return }
    readingCatalog = true
    defer {
      readingCatalog = false; observePendingDeletions()
      #if os(macOS)
        resumeWorkspaceOperationWaiters()
      #endif
    }
    do {
      if let id = selectedWorkspaceID, let model {
        _ = try library.select(id, name: model.workspaceName)
      }
      var local = try library.catalog()
      // Retry a durable, explicitly confirmed deletion, never an inferred one.
      for (id, _) in local.pendingCloudDeletion where !isChecking {
        await removeWorkspace(id, everywhere: true)
      }
      local = try library.catalog()
      workspaceList = local.entries.map { .init(id: $0.id, name: $0.name, local: true, remote: false,
        deleting: local.pendingCloudDeletion[$0.id] != nil) }
      for (id, deletion) in local.pendingCloudDeletion where !workspaceList.contains(where: { $0.id == id }) {
        workspaceList.append(.init(id: id, name: deletion.name, local: false, remote: true, deleting: true))
      }
      guard !isChecking else { return }
      let generation = catalogGeneration
      let bound = try? model?.store.cloudConfiguration().account
      if let snapshot = try await catalogCloud.spaces(boundAccount: bound) {
        guard catalogGeneration == generation else { return }
        catalogAccount = snapshot.account
        catalogError = nil
        // A confirmed deletion on another device is authoritative, including
        // for a replica which was offline when that confirmation happened.
        for entry in local.entries where snapshot.directory.deletedSpaceIDs.contains(entry.id) && local.pendingCloudDeletion[entry.id] == nil {
          await removeWorkspace(entry.id, everywhere: false)
        }
        local = try library.catalog()
        var rows = local.entries.map { entry -> Workspace in
          let remote = snapshot.directory.spaces.first { $0.id == entry.id }
          return .init(id: entry.id, name: entry.needsNamePublication ? entry.name : remote?.name ?? entry.name, local: true,
            remote: remote != nil, deleting: local.pendingCloudDeletion[entry.id] != nil)
        }
        for space in snapshot.directory.spaces where !rows.contains(where: { $0.id == space.id }) {
          rows.append(.init(id: space.id, name: space.name, local: false, remote: true, deleting: false))
        }
        for (id, deletion) in local.pendingCloudDeletion where !rows.contains(where: { $0.id == id }) {
          rows.append(.init(id: id, name: deletion.name, local: false, remote: true, deleting: true))
        }
        workspaceList = rows
        for row in rows where row.local && local.entries.first(where: { $0.id == row.id })?.needsNamePublication != true { try library.rename(row.id, name: row.name) }
        if let name = rows.first(where: { $0.id == selectedWorkspaceID })?.name { model?.workspaceName = name }
      }
    } catch { catalogError = "iCloud недоступен. Локальные пространства остаются доступны." }
  }

  @discardableResult func createWorkspace(name: String) async -> Bool {
    workspaceError = nil
    do {
      let name = try NotebookWorkspaceLibrary.name(name), id = UUID()
      await openWorkspace(id, creatingName: name)
      return selectedWorkspaceID == id
    } catch { workspaceError = error.localizedDescription; return false }
  }

  @discardableResult func renameWorkspace(_ id: UUID, name: String) async -> Bool {
    guard mayAccessWorkspace, !isChecking else { return false }
    isChecking = true; catalogGeneration = UUID(); workspaceError = nil
    defer { finishOperation() }
    do {
      let name = try NotebookWorkspaceLibrary.name(name)
      let bound = try? NotebookStore(root: library.root(for: id)).cloudConfiguration().account
      let registered = workspaceList.first(where: { $0.id == id })?.remote == true || bound != nil
      if registered {
        guard let account = bound ?? catalogAccount else { throw NotebookAccountError.unavailable }
        try await catalogCloud.renameSpace(id, name: name, account: account)
      }
      try library.rename(id, name: name, publish: !registered)
      if selectedWorkspaceID == id {
        model?.workspaceName = name; model?.publishesWorkspaceName = !registered
        model?.accountConnection?.spaceName = name; model?.accountConnection?.publishName = !registered
        model?.refreshDeviceConnection()
      }
      if let index = workspaceList.firstIndex(where: { $0.id == id }) {
        let old = workspaceList[index]
        workspaceList[index] = .init(id: id, name: name, local: old.local, remote: old.remote, deleting: false)
      }
      return true
    } catch { workspaceError = "Не удалось переименовать пространство. \(error.localizedDescription)"; return false }
  }

  func removeWorkspace(_ id: UUID, everywhere: Bool) async {
    guard mayAccessWorkspace else { return }
    guard !isChecking else { if !everywhere { retiredWorkspaces.insert(id) }; return }
    isChecking = true; catalogGeneration = UUID(); workspaceError = nil
    defer { finishOperation() }
    do {
      #if os(macOS)
        guard !(await codexHost.hasActiveWork(workspace: id)) else { throw NotebookTransportError.resourceLimit }
        if let retained = retainedModels[id] {
          guard await retained.shutdown() else { throw NotebookTransportError.storageUnavailable }
          retainedModels.removeValue(forKey: id)
        }
      #endif
      let pending = try library.catalog().pendingCloudDeletion[id]
      guard everywhere || pending == nil else { return }
      let account = pending?.account ?? catalogAccount
      if everywhere {
        guard let account else { throw NotebookAccountError.unavailable }
        try library.beginCloudRemoval(id, account: account, name: workspaceList.first(where: { $0.id == id })?.name ?? "Пространство")
      }
      if selectedWorkspaceID == id {
        guard await model?.finishPendingInteraction() ?? true,
          await model?.shutdown() ?? true else { throw NotebookTransportError.storageUnavailable }
        model = nil; hasNoWorkspace = true; showsWorkspaces = false
      }
      #if os(macOS)
        try await codexHost.removeWorkspace(id)
        try await workspaceWriters.remove(root: library.root(for: id))
      #endif
      if everywhere, let account { try await catalogCloud.deleteSpace(id, account: account) }
      try library.remove(id)
      workspaceList.removeAll { $0.id == id }
    } catch { workspaceError = "Не удалось завершить удаление. Удаление ожидает завершения; повторная попытка продолжит его, когда появится сеть. \(error.localizedDescription)" }
  }

  /// Replacing a pair's delivery journals requires fresh trust, not a new
  /// device identity. The durable receipt keeps that trust stable on restart.
  var pairingActivationID: UUID? {
    if case .admitted(let receipt) = activation { receipt.transitionID } else { nil }
  }

  var allowsCodexRegistration: Bool {
    #if os(macOS)
      guard !isFixture,
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        NotebookStore.canonicalWorkspacePath(root) == NotebookStore.canonicalWorkspacePath(NotebookStore.defaultRoot) else { return false }
      switch activation {
      case .admitted(let receipt): guard receipt.target.role == .mac, receipt.target.bundleID == Bundle.main.bundleIdentifier else { return false }
      case .unchanged: guard !FileManager.default.fileExists(atPath: NotebookArchiveActivation.controlURL(for: root).path) else { return false }
      case .waitingForPair: return false
      }
      return NotebookRuntimeIdentity.isAdmitted
    #else
      return false
    #endif
  }

  /// A one-time activation wait belongs to bootstrap, not an extra database or
  /// IPC watcher. Only two small receipts are read on each waiting iteration.
  func waitForAdmission() async {
    await start()
    while !Task.isCancelled, model == nil, failure == nil, !isFixture, !hasNoWorkspace {
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
