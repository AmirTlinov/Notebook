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
  struct Workspace: Identifiable, Equatable {
    let id: UUID
    let name: String
    let local: Bool
    let remote: Bool
    let deleting: Bool
  }
  private var library: NotebookWorkspaceLibrary { .init(originalRoot: root) }
  var selectedWorkspaceID: UUID? { try? model?.store.storedWorkspaceID() }

  #if os(macOS)
    let codexHost = NotebookCodexHost()
    private var retainedModels: [UUID: NotebookAppModel] = [:]
    private var defaultCommandServer: NotebookIPCServer?

  #endif

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
    installWorkspaceSelection()
  }

  init(failure: String) {
    self.failure = failure; root = URL(fileURLWithPath: "/unused-notebook-rejected-launch")
    target = nil; makeModel = nil; isFixture = true
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
    guard !isFixture, model == nil, !isChecking, !hasNoWorkspace else { return }
    isChecking = true; failure = nil
    defer { finishOperation() }
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
          opensDefaultAccountWorkspace: fresh, requiresExistingAccountContent: selectedRoot != root)
        installWorkspaceSelection()
      case .waitingForPair: break
      }
    } catch is CancellationError {
      // A committed activation remains on disk; cancellation cannot restore old
      // bytes or publish a model after the calling scene has disappeared.
    } catch { failure = error.localizedDescription }
  }

  private func makeWorkspaceModel(store: NotebookStore, opensDefaultAccountWorkspace: Bool = false,
    requiresExistingAccountContent: Bool = false) throws -> NotebookAppModel {
    if let makeModel { return try makeModel(store, pairingActivationID) }
    #if os(macOS)
      let writer: NotebookPersistenceQueue? = codexHost.persistence(for: store)
      let socketID = SHA256.hash(data: Data(store.root.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
      let socket = NotebookIPC.defaultSocketURL.deletingLastPathComponent().appendingPathComponent(socketID + ".sock")
      if allowsCodexRegistration, defaultCommandServer == nil {
        let server = NotebookIPCServer { [weak self] command in
          guard let model = await self?.model else { throw NotebookTransportError.disconnected }
          return try await model.executeLocalCommand(command)
        }
        try server.start(); defaultCommandServer = server
      }
    #else
      let writer: NotebookPersistenceQueue? = nil
    #endif
    #if os(macOS)
      let model = NotebookAppModel(store: store, commandSocketURL: socket, allowsCodexRegistration: allowsCodexRegistration,
        pairingActivationID: pairingActivationID, opensDefaultAccountWorkspace: opensDefaultAccountWorkspace,
        requiresExistingAccountContent: requiresExistingAccountContent, persistenceQueue: writer)
    #else
    let model = NotebookAppModel(store: store, allowsCodexRegistration: allowsCodexRegistration,
      pairingActivationID: pairingActivationID, opensDefaultAccountWorkspace: opensDefaultAccountWorkspace,
      requiresExistingAccountContent: requiresExistingAccountContent, persistenceQueue: writer)
    #endif
    #if os(macOS)
      model.codexHost = codexHost
    #endif
    return model
  }

  func shutdown() async -> Bool {
    guard await model?.shutdown() ?? true else { return false }
    #if os(macOS)
      if let owner = model?.codexHost, owner !== codexHost { await owner.shutdown() }
      for retained in retainedModels.values { guard await retained.shutdown() else { return false } }
      retainedModels.removeAll()
      await codexHost.shutdown()
      await defaultCommandServer?.stopAndDrain(); defaultCommandServer = nil
    #endif
    return true
  }

  private func installWorkspaceSelection() {
    guard let model else { return }
    model.openWorkspaceLibrary = { [weak self] tab in self?.workspaceTab = tab; self?.showsWorkspaces = true }
    guard !isFixture else { return }
    if let id = try? model.store.storedWorkspaceID(), let entry = try? library.catalog().entries.first(where: { $0.id == id }) {
      model.workspaceName = entry.name
      model.publishesWorkspaceName = entry.needsNamePublication
    }
    model.accountWorkspaceNameSaved = { [weak self, weak model] name, deleted in
      guard let self, let model, let id = try? model.store.storedWorkspaceID() else { return }
      do {
        for entry in try self.library.catalog().entries where deleted.contains(entry.id) { self.retireWorkspace(entry.id) }
        try self.library.acknowledgeName(id, name: name)
        let pending = try self.library.catalog().entries.first(where: { $0.id == id })?.needsNamePublication ?? false
        if !pending { model.workspaceName = name; model.publishesWorkspaceName = false; model.accountConnection?.publishName = false }
      } catch { self.workspaceError = error.localizedDescription }
    }
    model.workspaceDeleted = { [weak self, weak model] in
      guard let self, let model, let id = try? model.store.storedWorkspaceID() else { return }
      self.retireWorkspace(id)
    }
    model.openDefaultAccountWorkspace = { [weak self] id in
      Task { await self?.openWorkspace(id, automatically: true) }
    }

  }

  func openWorkspace(_ id: UUID, automatically: Bool = false, creatingName: String? = nil) async {
    guard !isChecking else { return }
    let previous = model
    isChecking = true; catalogGeneration = UUID()
    var retired = false
    var replacement: NotebookAppModel?
    defer { finishOperation() }
    do {
      guard try library.catalog().pendingCloudDeletion[id] == nil else {
        throw NotebookStorageError.invalidTransaction("Удаление этого пространства ещё не завершено.")
      }
      let currentID = try previous?.store.storedWorkspaceID()
      guard currentID != id else { showsWorkspaces = false; return }
      if let previous, automatically {
        guard await previous.prepareAutomaticWorkspaceSwitch() else { previous.refreshDeviceConnection(); return }
      } else if let previous {
        guard await previous.finishPendingInteraction() else { throw NotebookTransportError.storageUnavailable }
      }
      #if os(macOS)
      if let previous, let currentID {
        // Closing a workspace removes its view, not the accepted Mac owner.
        // Keep a bounded set; never evict an owner that is still working.
        if retainedModels.count >= 7, retainedModels[id] == nil {
          var evicted = false
          for (candidate, retained) in retainedModels where !(await codexHost.hasActiveWork(workspace: candidate)) {
            guard await retained.shutdown() else { throw NotebookTransportError.storageUnavailable }
            try await codexHost.removeWorkspace(candidate)
            retainedModels.removeValue(forKey: candidate); evicted = true; break
          }
          guard evicted else { throw NotebookTransportError.resourceLimit }
        }
        retainedModels[currentID] = previous
      }
      #else
      guard await previous?.shutdown() ?? true else { throw NotebookTransportError.storageUnavailable }
      #endif
      retired = true
      if let previous, automatically, !(try previous.automaticWorkspaceCutIsUnchanged()) { throw SwitchCancellation.acceptedLocalWork }
      let library = NotebookWorkspaceLibrary(originalRoot: root)
      let destination = try await Task.detached { try library.prepare(id) }.value
      #if os(macOS)
      let next = try retainedModels.removeValue(forKey: id) ?? makeWorkspaceModel(store: NotebookStore(root: destination),
        requiresExistingAccountContent: creatingName == nil && destination != root)
      #else
      let next = try makeWorkspaceModel(store: NotebookStore(root: destination),
        requiresExistingAccountContent: creatingName == nil && destination != root)
      #endif
      next.workspaceName = creatingName ?? workspaceList.first(where: { $0.id == id })?.name
        ?? (try? library.catalog().entries.first(where: { $0.id == id })?.name) ?? "Моё пространство"
      next.publishesWorkspaceName = creatingName != nil || ((try? library.catalog().entries.first(where: { $0.id == id })?.needsNamePublication) ?? false)
      replacement = next
      await next.start(pageSize: NotebookAppModel.defaultPageSize)
      guard next.loadState == .ready || next.awaitingAccountContent else { throw NotebookTransportError.storageUnavailable }
      _ = try library.select(id, name: next.workspaceName, publishName: next.publishesWorkspaceName)
      // A first enrollment can finish during start, before the catalog entry
      // existed. Acknowledge its exact name only after the selection is durable.
      if next.accountConnection?.spaces.first(where: { $0.id == id })?.name == next.workspaceName {
        try library.acknowledgeName(id, name: next.workspaceName)
      }
      model = next; failure = nil; hasNoWorkspace = false; showsWorkspaces = false; installWorkspaceSelection()
      let row = Workspace(id: id, name: next.workspaceName, local: true,
        remote: workspaceList.contains(where: { $0.id == id && $0.remote }) || next.accountConnection?.spaces.contains(where: { $0.id == id }) == true,
        deleting: false)
      if let index = workspaceList.firstIndex(where: { $0.id == id }) { workspaceList[index] = row }
      else { workspaceList.append(row) }
    } catch {
      Logger(subsystem: "com.amirtlinov.notebook", category: "WorkspaceLifecycle").error("Space switch failed: \(String(reflecting: error), privacy: .public)")
      let cancelledForInput = error is SwitchCancellation
      failure = cancelledForInput ? nil : error.localizedDescription
      workspaceError = failure
      guard retired else { return }
      if let replacement, !(await replacement.shutdown()) {
        model = replacement
        workspaceError = "Не удалось завершить открытие пространства. Изменения остаются на этом устройстве."
        installWorkspaceSelection()
        return
      }
      if creatingName != nil { try? library.remove(id) }
      guard let previous else { model = nil; hasNoWorkspace = true; return }
      // The source was not changed or merged. Reopen its same owner after an
      // unsuccessful switch instead of leaving a stopped model on screen.
      #if os(macOS)
      if let previousID = try? previous.store.storedWorkspaceID() { retainedModels.removeValue(forKey: previousID) }
      model = previous
      #else
      model = try? makeWorkspaceModel(store: previous.store, requiresExistingAccountContent: previous.store.root != root)
      #endif
      installWorkspaceSelection()
      await model?.start(pageSize: NotebookAppModel.defaultPageSize)
    }
  }

  /// A confirmed offline deletion resumes on connectivity, not a timer or a
  /// ritual "sync now" button. No catalog monitor exists without pending work.
  private func observePendingDeletions() {
    guard !isFixture else { return }
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
  }

  private func retireWorkspace(_ id: UUID) {
    retiredWorkspaces.insert(id)
    if !isChecking { finishOperation() }
  }

  func refreshWorkspaces() async {
    guard !isFixture, !readingCatalog else { return }
    readingCatalog = true
    defer { readingCatalog = false; observePendingDeletions() }
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
    guard !isChecking else { return false }
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
        root.standardizedFileURL.resolvingSymlinksInPath() == NotebookStore.defaultRoot.standardizedFileURL.resolvingSymlinksInPath() else { return false }
      switch activation {
      case .admitted(let receipt): guard receipt.target.role == .mac, receipt.target.bundleID == Bundle.main.bundleIdentifier else { return false }
      case .unchanged: guard !FileManager.default.fileExists(atPath: NotebookArchiveActivation.controlURL(for: root).path) else { return false }
      case .waitingForPair: return false
      }
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
