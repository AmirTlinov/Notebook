import Foundation
import NotebookCore
import Observation

/// The admitted workspace's durable owners. Native UI and headless agent
/// services borrow these exact instances for their whole accepted lifetime.
@MainActor @Observable
final class NotebookWorkspaceRuntime {
  struct InitialStorage: Sendable {
    let header: NotebookWorkspaceHeader
    let began: ContinuousClock.Instant?
    let ended: ContinuousClock.Instant?
  }

  /// Presentation contributes only its accepted boundary. Storage, fleet and
  /// admission stay with this runtime on both platforms.
  struct HistoryHooks {
    var isReady: @MainActor () -> Bool = { false }
    var permitsWork: @MainActor () -> Bool = { false }
    var prepare: @MainActor () async throws -> Void = { throw CancellationError() }
    var drain: @MainActor (NotebookHistoryReadiness.Request) async -> Bool = { _ in false }
    var resume: @MainActor () async -> Void = {}
  }

  let historyReadiness = NotebookHistoryReadiness()
  @ObservationIgnored var historyHooks = HistoryHooks()
  @ObservationIgnored var historyReadinessLifecycleIsBusy: (@MainActor () -> Bool)?
  var permitsExternalWork: Bool { shutdownPhase == .running && historyHooks.permitsWork() }
  var permitsAuthoredWork: Bool { permitsExternalWork && historyReadiness.permitsAuthorship }
  var permitsTransportWork: Bool { shutdownPhase == .closing || permitsExternalWork }

  let store: NotebookStore
  let persistence: NotebookPersistenceQueue
  let commandReader: NotebookCommandReader
  let connection: NotebookWorkspaceConnection
  let actorID: UUID
  private(set) var admittedWorkspaceID: UUID?
  private(set) var awaitingAccountContent = false
  private(set) var shutdownPhase = NotebookWorkspaceShutdownPhase.running
  private(set) var persistenceFailure: String?
  @ObservationIgnored var onFailureChange: (@MainActor (String?) -> Void)?
  @ObservationIgnored var onContentMerged: (@MainActor () -> Void)?
  @ObservationIgnored var onCommit: (@MainActor (NotebookPersistenceQueue.Owner?) -> Void)?
  @ObservationIgnored private var initialStorage: InitialStorage?
  private let requiresExistingAccountContent: Bool

  init(configuration: NotebookWorkspaceOpenConfiguration) {
    store = configuration.store
    persistence = configuration.persistence
    actorID = NotebookWorkspaceIdentity.actor(defaults: configuration.preferences)
    admittedWorkspaceID = configuration.expectedWorkspaceID
    requiresExistingAccountContent = configuration.requiresExistingAccountContent
    commandReader = NotebookCommandReader(store: configuration.store)
    connection = NotebookWorkspaceConnection(store: store, persistence: persistence, actorID: actorID,
      pairingActivationID: configuration.pairingActivationID, pairingService: configuration.pairingService,
      acceptance: configuration.acceptance)
    persistence.authoredAdmission = { [historyReadiness] in historyReadiness.authoredAdmissionError }
    connection.transportAdmission = { [weak self] in self?.permitsTransportWork == true }
    connection.onHistoryControl = { [weak self] control, peer, generation in
      guard let self else { return }
      historyReadiness.receive(control, peerID: peer, connectionID: generation, runtime: self)
    }
    connection.onHistoryProgress = { [weak self] peer, generation in
      self?.historyReadiness.deliveryProgress(peerID: peer, connectionID: generation)
    }
    connection.onHistoryDisconnect = { [weak self] peer, generation in
      self?.historyReadiness.deliveryDisconnected(peerID: peer, connectionID: generation)
    }
    persistence.onFailureChange = { [weak self] message in
      guard let self else { return }
      persistenceFailure = message
      onFailureChange?(message)
      if message == nil, let cloud = connection.cloudSync { Task { await cloud.writerRecovered() } }
    }
    persistence.onContentMerged = { [weak self] in self?.onContentMerged?() }
    persistence.onCommit = { [weak self] owner in
      guard let self else { return }
      connection.notifyDurableChanges()
      onCommit?(owner)
    }
  }

  func admitWorkspaceIdentity(_ id: UUID) throws {
    guard admittedWorkspaceID == nil || admittedWorkspaceID == id else {
      throw NotebookStorageError.invalidTransaction("workspace identity changed")
    }
    admittedWorkspaceID = id
  }

  /// An account replica may already own an identity while it awaits content.
  /// It must not create a competing initial notebook on that empty replica.
  func prepareInitialStorage(pageSize: PageSize, observing: Bool = false) async throws -> InitialStorage? {
    if let initialStorage { return initialStorage }
    if requiresExistingAccountContent {
      let source = try await persistence.submit { try ($0.hasWorkspaceContent(), $0.storedWorkspaceID()) }
      try admitWorkspaceIdentity(source.1)
      guard source.0 else { awaitingAccountContent = true; return nil }
    }
    let actor = actorID
    let prepared = try await persistence.submit(writesStore: true) { store in
      let began: ContinuousClock.Instant? = observing ? .now : nil
      _ = try store.initializeWorkspace(actor: actor, pageSize: pageSize,
        initialNotebookID: NotebookWorkspaceIdentity.initialNotebookID,
        initialPageID: NotebookWorkspaceIdentity.initialPageID)
      try store.resetInputActivities()
      try store.resetSelectionPublication()
      return InitialStorage(header: try store.workspaceHeader(), began: began,
        ended: observing ? .now : nil)
    }
    try admitWorkspaceIdentity(prepared.header.workspaceID)
    initialStorage = prepared
    awaitingAccountContent = false
    return prepared
  }

  func startConnection() async throws {
    await connection.prepareCloudSync()
    try await connection.start()
  }

  func retryPendingPersistence() { persistence.retry() }

  func beginClosing() {
    guard shutdownPhase == .running else { return }
    shutdownPhase = .closing
  }

  /// Callers first close authored admission and finish accepted native/agent
  /// work. Trust drain keeps the original connection available on failure.
  func stopConnection() async -> Bool {
    guard await persistence.flush(), await connection.stop() else { return false }
    // stop joins accepted transport callbacks; disconnect publication may add
    // a final local tail. Offline delivery remains in the existing journal.
    return await persistence.flush()
  }

  func beginDraining() {
    precondition(shutdownPhase == .closing || shutdownPhase == .draining)
    shutdownPhase = .draining
  }

  /// Native preparation readers and agent services have joined before this
  /// boundary. A failed save retains the same writer and both read lanes.
  func finishShutdown() async -> Bool {
    guard shutdownPhase != .running else { return false }
    if shutdownPhase == .stopped { return true }
    guard await persistence.flush() else { return false }
    await commandReader.close()
    await connection.close()
    shutdownPhase = .stopped
    return true
  }
}
