import Foundation
import NotebookCore
import Observation

/// The Mac owns durable work and execution routes. Its lifetime contains no
/// native camera, input gate, page cache, scene frame or mounted presentation.
@MainActor @Observable
final class NotebookHeadlessWorkspace: NotebookWorkspaceLifecycle {
  static let defaultPageSize = NotebookWorkspaceIdentity.defaultPageSize
  let workspaceRuntime: NotebookWorkspaceRuntime
  var store: NotebookStore { workspaceRuntime.store }
  var persistence: NotebookPersistenceQueue { workspaceRuntime.persistence }
  var commandReader: NotebookCommandReader { workspaceRuntime.commandReader }
  var connection: NotebookWorkspaceConnection { workspaceRuntime.connection }
  var actorID: UUID { workspaceRuntime.actorID }
  let agentServices: NotebookAgentServices
  let allowsCodexRegistration: Bool
  let acceptance: NotebookAcceptanceConfiguration?
  private let startsNearbySync: Bool
  private let opensDefaultAccountWorkspace: Bool
  var admittedWorkspaceID: UUID? { workspaceRuntime.admittedWorkspaceID }
  private(set) var workspaceHeader: NotebookWorkspaceHeader?
  private(set) var loadState = NotebookWorkspaceLoadState.loading
  var shutdownPhase: NotebookWorkspaceShutdownPhase { workspaceRuntime.shutdownPhase }
  var awaitingAccountContent: Bool { workspaceRuntime.awaitingAccountContent }
  private(set) var persistenceFailure: String?
  var workspaceName = "Моё пространство"
  var publishesWorkspaceName = false
  @ObservationIgnored var accountWorkspaceNameSaved: (@MainActor (String, Set<UUID>) async -> Void)?
  @ObservationIgnored var workspaceDeleted: (@MainActor () -> Void)?
  @ObservationIgnored var openDefaultAccountWorkspace: (@MainActor (UUID) -> Void)?
  @ObservationIgnored private var startupTask: Task<Void, Never>?
  @ObservationIgnored private var headerTask: Task<Void, Never>?
  @ObservationIgnored private var shutdownTask: Task<Bool, Never>?
  @ObservationIgnored private var documentImporter: NotebookDocumentImportOwner?
  private var headerNeedsRefresh = false
  private var started = false
  private var pageSize = defaultPageSize
  private var initialAccountWorkspaceCursor: UInt64?
  private var automaticTransition: NotebookWorkspaceTransition?
  private var selectionSeal: UUID?
  private var manualSeal: UUID?
  private var workspaceTransitionIsFrozen = false
  var permitsExternalWork: Bool { workspaceRuntime.permitsExternalWork }
  var permitsAuthoredWork: Bool { workspaceRuntime.permitsAuthoredWork }
  var accountConnection: NotebookAccountConnection? { connection.accountConnection }
  var runtimeStartupPending: Bool { startupTask != nil }
  var runtimeSocketKey: String? { agentServices.runtimeSocketKey }
  var agentStartupError: String? { agentServices.agentStartupError }
  var codexHost: NotebookCodexHost? {
    get { agentServices.codexHost }
    set { agentServices.codexHost = newValue }
  }

  static func open(_ configuration: NotebookWorkspaceOpenConfiguration) -> NotebookHeadlessWorkspace {
    .init(configuration: configuration)
  }

  init(configuration: NotebookWorkspaceOpenConfiguration, startsNearbySync: Bool = true) {
    let runtime = NotebookWorkspaceRuntime(configuration: configuration)
    workspaceRuntime = runtime
    allowsCodexRegistration = configuration.allowsCodexRegistration
    acceptance = configuration.acceptance
    self.startsNearbySync = startsNearbySync
    opensDefaultAccountWorkspace = configuration.opensDefaultAccountWorkspace
    agentServices = NotebookAgentServices(runtime: runtime,
      commandSocketURL: configuration.commandSocketURL,
      allowsCodexRegistration: allowsCodexRegistration, acceptance: acceptance)
    runtime.historyHooks = .init(isReady: { [weak self] in self?.loadState == .ready },
      permitsWork: { [weak self] in self?.workspaceTransitionIsFrozen == false },
      prepare: { [weak self] in
        guard let self else { throw CancellationError() }
        @MainActor func isCurrent() -> Bool {
          permitsAuthoredWork && startupTask == nil && automaticTransition == nil
            && documentImporter?.hasPendingAuthoredPreparation != true && !agentServices.hasPendingAuthoredPreparation
        }
        guard isCurrent(), await finishPendingInteraction(boundary: .acceptedInput, continuing: { isCurrent() }),
          isCurrent() else {
          throw CollaborationError("input_active", "Дождитесь завершения принятой команды перед сверкой истории.")
        }
      }, drain: { [weak self] request in
        guard let self else { return false }
        await agentServices.drainHistoryPreparation()
        return await finishPendingInteraction(boundary: .quiescent,
          continuing: { self.permitsExternalWork && self.workspaceRuntime.historyReadiness.phase == .draining(request) })
      })
    agentServices.hooks = .init(permitsWork: { [weak self] in self?.permitsExternalWork == true },
      isReady: { [weak self] in self?.loadState == .ready }, workspaceID: { [weak self] in self?.admittedWorkspaceID },
      header: { [weak self] in self?.workspaceHeader }, contentChanged: { [weak self] in self?.refreshHeader() },
      importDocument: { [weak self] request in
        guard let self else { throw CancellationError() }
        if documentImporter == nil { documentImporter = NotebookDocumentImportOwner(persistence: persistence, actor: actorID) }
        let result = try await documentImporter!.run(request); refreshHeader(); return result.response
      }, permitsPreparation: { [weak self] in
        self?.loadState == .ready && self?.permitsAuthoredWork == true && self?.automaticTransition == nil
      })
    connection.hooks = .init(permitsWork: { [weak self] in self?.permitsExternalWork == true },
      workspaceID: { [weak self] in self?.admittedWorkspaceID },
      workspaceName: { [weak self] in self?.workspaceName ?? "Моё пространство" },
      publishesName: { [weak self] in self?.publishesWorkspaceName == true },
      contentAvailable: { [weak self] changed in
        guard let self else { return }
        if awaitingAccountContent { resumeAccountContent() } else if changed { refreshHeader() }
      }, connected: { [weak self] peer, generation in self?.agentServices.peerConnected(peer, generation: generation) },
      disconnected: { [weak self] peer, generation in self?.agentServices.peerDisconnected(peer, generation: generation) },
      revoked: { [weak self] peer in self?.agentServices.revokeDevice(peer) },
      transient: { [weak self] value, peer, generation in self?.agentServices.receive(value, peerID: peer, generation: generation) },
      shouldOpenDefault: { [weak self] in
        guard let self, let transition = await prepareAutomaticWorkspaceSwitch() else { return false }
        rollbackAutomaticWorkspaceSwitch(transition); return true
      }, openWorkspace: { [weak self] id in self?.openDefaultAccountWorkspace?(id) },
      nameSaved: { [weak self] name, deleted in await self?.accountWorkspaceNameSaved?(name, deleted) },
      workspaceDeleted: { [weak self] in self?.workspaceDeleted?() })
    connection.peerPublication.onChange = { [weak self] in
      if self?.connection.peerPublication.isActive == true { self?.agentServices.suspendPreparation() }
    }
    connection.peerPublication.onFailure = { [weak self] in self?.persistenceFailure = $0.localizedDescription }
    workspaceRuntime.onFailureChange = { [weak self] in self?.persistenceFailure = $0 }
    workspaceRuntime.onContentMerged = { [weak self] in self?.refreshHeader() }
    workspaceRuntime.onCommit = { [weak self] _ in self?.refreshHeader() }
  }

  func admitWorkspaceIdentity(_ id: UUID) throws { try workspaceRuntime.admitWorkspaceIdentity(id) }

  func start(pageSize: PageSize) async {
    guard shutdownPhase == .running else { return }
    if let startupTask { _ = await persistence.waitForLifecycle(startupTask); return }
    guard !started else { return }
    started = true; self.pageSize = pageSize
    beginStartup()
    if let startupTask { _ = await persistence.waitForLifecycle(startupTask) }
  }

  private func beginStartup() {
    guard startupTask == nil, permitsExternalWork else { return }
    startupTask = Task { [self] in
      defer { startupTask = nil }
      do {
        guard let storage = try await workspaceRuntime.prepareInitialStorage(pageSize: pageSize) else {
          if startsNearbySync { try await workspaceRuntime.startConnection() }
          return
        }
        // Bootstrap's prepared header precedes its accepted COMMIT and journal
        // publication. The admitted reader captures that completed durable cut
        // before IPC can accept work or automatic selection compares its cursor.
        let header = try await commandReader.read(workspaceID: storage.header.workspaceID) {
          try $0.workspaceHeader()
        }
        workspaceHeader = header
        if opensDefaultAccountWorkspace { initialAccountWorkspaceCursor = header.cursor }
        loadState = .ready
        await agentServices.start()
        if startsNearbySync {
          do { try await workspaceRuntime.startConnection() } catch { connection.connectionState = .failed(error.localizedDescription) }
          await agentServices.startCodexSidecar()
        }
      } catch { loadState = .failed(error.localizedDescription) }
    }
  }

  private func resumeAccountContent() {
    guard awaitingAccountContent, permitsExternalWork else { return }
    if startupTask != nil {
      Task { [weak self] in
        await self?.startupTask?.value
        guard let self, awaitingAccountContent, permitsExternalWork else { return }; beginStartup()
      }
    } else { beginStartup() }
  }
  func finishStartup() async { await startupTask?.value }
  func refreshDeviceConnection() { connection.refresh() }
  func retryPendingPersistence() { workspaceRuntime.retryPendingPersistence() }
  func startCodexSidecar() async { await agentServices.startCodexSidecar() }
  func executeLocalCommand(_ command: NotebookCommand) async throws -> JSONValue { try await agentServices.executeLocalCommand(command) }

  /// Header refresh is bounded metadata; no page/document/scene material is read.
  private func refreshHeader() {
    guard loadState == .ready, shutdownPhase == .running, let workspaceID = admittedWorkspaceID else { return }
    headerNeedsRefresh = true
    guard headerTask == nil else { return }
    headerTask = Task { [self] in
      defer { headerTask = nil }
      while headerNeedsRefresh, shutdownPhase == .running, !Task.isCancelled {
        headerNeedsRefresh = false
        do {
          let fence = persistence.captureReadFence(); try await fence.wait()
          workspaceHeader = try await commandReader.read(workspaceID: workspaceID) { try $0.workspaceHeader() }
        } catch { if !Task.isCancelled { persistenceFailure = error.localizedDescription }; return }
      }
    }
  }

  func waitForPersistenceLifecycle<Value: Sendable>(_ task: Task<Value, Never>) async -> NotebookPersistenceQueue.LifecycleResult<Value> {
    await persistence.waitForLifecycle(task)
  }
  func finishPendingInteraction(boundary: NotebookPersistenceBoundary, continuing: @MainActor () -> Bool) async -> Bool {
    guard continuing(), !Task.isCancelled, await persistence.flush(), continuing(), !Task.isCancelled else { return false }
    if boundary == .quiescent { await headerTask?.value }
    return persistenceFailure == nil && continuing()
  }

  func prepareAutomaticWorkspaceSwitch() async -> NotebookWorkspaceTransition? {
    guard let cursor = initialAccountWorkspaceCursor, let workspaceID = admittedWorkspaceID,
      loadState == .ready, permitsAuthoredWork, automaticTransition == nil else { return nil }
    let transition = NotebookWorkspaceTransition(id: UUID(), workspaceID: workspaceID, cursor: cursor,
      inputGeneration: 0, mutationGeneration: persistence.acceptedMutationGeneration)
    automaticTransition = transition; agentServices.suspendPreparation()
    var prepared = false
    defer { if !prepared { rollbackAutomaticWorkspaceSwitch(transition) } }
    guard await finishPendingInteraction(boundary: .acceptedInput, continuing: { self.unchanged(transition) }),
      let current = try? await commandReader.read(workspaceID: workspaceID, { try $0.currentChangeCursor() }),
      unchanged(transition), current == cursor else { return nil }
    prepared = true; return transition
  }
  private func unchanged(_ transition: NotebookWorkspaceTransition, writerSeal: UUID? = nil) -> Bool {
    if let writerSeal {
      guard workspaceTransitionIsFrozen, selectionSeal == writerSeal,
        persistence.ownsWorkspaceSelectionSeal(writerSeal), workspaceRuntime.historyReadiness.permitsAuthorship else { return false }
    } else {
      guard permitsAuthoredWork else { return false }
    }
    return shutdownPhase == .running && loadState == .ready && automaticTransition == transition
      && admittedWorkspaceID == transition.workspaceID && persistence.acceptedMutationGeneration == transition.mutationGeneration
  }
  func freezeAutomaticWorkspaceSwitch(_ transition: NotebookWorkspaceTransition) async throws -> Bool {
    guard !workspaceTransitionIsFrozen, unchanged(transition), documentImporter?.hasPendingAuthoredPreparation != true,
      let seal = persistence.sealWorkspaceSelection(expectedGeneration: transition.mutationGeneration) else { return false }
    selectionSeal = seal; workspaceTransitionIsFrozen = true
    do {
      let cursor = try await commandReader.read(workspaceID: transition.workspaceID) { try $0.currentChangeCursor() }
      guard unchanged(transition, writerSeal: seal), cursor == transition.cursor else {
        rollbackAutomaticWorkspaceSwitch(transition); return false
      }
      return true
    } catch { rollbackAutomaticWorkspaceSwitch(transition); throw error }
  }
  func commitAutomaticWorkspaceSwitch(_ transition: NotebookWorkspaceTransition) {
    guard automaticTransition == transition, workspaceTransitionIsFrozen else { return }
    rollbackAutomaticWorkspaceSwitch(transition)
  }
  func rollbackAutomaticWorkspaceSwitch(_ transition: NotebookWorkspaceTransition) {
    guard automaticTransition == transition else { return }
    if let selectionSeal { persistence.finishWorkspaceSelection(selectionSeal) }
    selectionSeal = nil; automaticTransition = nil; workspaceTransitionIsFrozen = false
  }
  func freezeManualWorkspaceSelection() -> UUID? {
    guard permitsAuthoredWork, !workspaceTransitionIsFrozen else { return nil }
    let id = UUID(); manualSeal = id; workspaceTransitionIsFrozen = true; return id
  }
  func finishManualWorkspaceSelection(_ id: UUID) {
    guard manualSeal == id else { return }; manualSeal = nil; workspaceTransitionIsFrozen = false
  }

  /// Accepted work retains the exact FIFO and reader until its saved boundary.
  /// A failed drain leaves these identities available for explicit repair/retry.
  func shutdown() async -> Bool {
    while let shutdownTask {
      guard case .completed(let saved) = await persistence.waitForLifecycle(shutdownTask) else { return false }
      if saved { return true }
      // A storage fault releases the previous caller before its attempt joins.
      // Explicit Retry must finish that attempt, then close the repaired FIFO.
      guard persistence.failure == nil else { return false }
    }
    if shutdownPhase == .stopped { return true }
    workspaceRuntime.beginClosing()
    let task = Task { [self] in
      defer { shutdownTask = nil }
      await workspaceRuntime.historyReadiness.stopAndJoin()
      documentImporter?.stop()
      await startupTask?.value; await agentServices.finishStartup()
      await agentServices.stop()
      await documentImporter?.close()
      guard await workspaceRuntime.stopConnection() else { return false }
      documentImporter = nil
      workspaceRuntime.beginDraining()
      headerTask?.cancel(); await headerTask?.value
      return await workspaceRuntime.finishShutdown()
    }
    shutdownTask = task
    guard case .completed(let saved) = await persistence.waitForLifecycle(task) else { return false }; return saved
  }
}
