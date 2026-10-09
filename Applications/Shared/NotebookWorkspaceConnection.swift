import Foundation
import NotebookCore
import Observation

/// One admitted workspace owns its reader, delivery routes and account binding.
/// Native input is borrowed through hooks; a headless owner has no input device.
@MainActor @Observable
final class NotebookWorkspaceConnection {
  struct Hooks {
    var permitsWork: @MainActor () -> Bool = { false }
    var workspaceID: @MainActor () -> UUID? = { nil }
    var workspaceName: @MainActor () -> String = { "Моё пространство" }
    var publishesName: @MainActor () -> Bool = { false }
    var inputTargets: @MainActor () -> [CollaborationTarget] = { [] }
    var waitForInput: @MainActor () async -> UInt64? = { 0 }
    var contentAvailable: @MainActor (Bool) -> Void = { _ in }
    var stateChanged: @MainActor () -> Void = {}
    var connected: @MainActor (NotebookTransportIdentity, UUID) -> Void = { _, _ in }
    var disconnected: @MainActor (UUID, UUID) -> Void = { _, _ in }
    var revoked: @MainActor (UUID) -> Void = { _ in }
    var transient: @MainActor (NotebookTransportTransient, UUID, UUID) -> Void = { _, _, _ in }
    var shouldOpenDefault: @MainActor () async -> Bool = { false }
    var openWorkspace: @MainActor (UUID) -> Void = { _ in }
    var nameSaved: @MainActor (String, Set<UUID>) async -> Void = { _, _ in }
    var workspaceDeleted: @MainActor () -> Void = {}
    var cloudConnected: @MainActor (String) -> Void = { _ in }
  }

  let store: NotebookStore
  let persistence: NotebookPersistenceQueue
  let actorID: UUID
  let peerPublication: NotebookPeerPublication
  @ObservationIgnored var hooks = Hooks()
  @ObservationIgnored var transportAdmission: @MainActor () -> Bool = { false }
  @ObservationIgnored var onHistoryControl: (@MainActor (NotebookHistoryControl, UUID, UUID) -> Void)?
  @ObservationIgnored var onHistoryProgress: (@MainActor (UUID, UUID) -> Void)?
  @ObservationIgnored var onHistoryDisconnect: (@MainActor (UUID, UUID) -> Void)?
  @ObservationIgnored var sync: NearbySync?
  @ObservationIgnored private(set) var transportReader: NotebookTransportReader?
  @ObservationIgnored private(set) var cloudSync: NotebookCloudSync?
  private(set) var accountConnection: NotebookAccountConnection?
  var cloudStatus = NotebookCloudStatus.off
  var connectionState = NotebookConnectionState.waiting
  var pairedPeers: [NotebookTransportIdentity] = []
  var knownDevices: [NotebookTransportIdentity] = []
  var blockedDeviceIDs: Set<UUID> = []
  @ObservationIgnored var peerGenerations: [UUID: UUID] = [:]
  private let pairingActivationID: UUID?
  private let pairingService: String?
  private let acceptance: NotebookAcceptanceConfiguration?
  private var stopped = false

  init(store: NotebookStore, persistence: NotebookPersistenceQueue, actorID: UUID,
    pairingActivationID: UUID?, pairingService: String?, acceptance: NotebookAcceptanceConfiguration?) {
    self.store = store; self.persistence = persistence; self.actorID = actorID
    self.pairingActivationID = pairingActivationID; self.pairingService = pairingService
    self.acceptance = acceptance
    peerPublication = NotebookPeerPublication(persistence: persistence, actorID: actorID)
  }

  var permitsWork: Bool { !stopped && hooks.permitsWork() }
  var permitsTransportWork: Bool { !stopped && transportAdmission() }
  var isPeerConnected: Bool { !peerGenerations.isEmpty }

  func notifyDurableChanges() {
    guard !stopped else { return }
    sync?.notifyDurableChanges()
    if let cloudSync { Task { await cloudSync.notifyLocalChanges() } }
  }

  func makeTransportStorage() async throws -> NotebookTransportStorage {
    guard permitsWork else { throw NotebookTransportError.disconnected }
    let source = try await persistence.submit(writesStore: true) { [actorID] in
      try $0.replicationSource(deviceID: actorID)
    }
    guard permitsWork else { throw NotebookTransportError.disconnected }
    let reader = transportReader ?? NotebookTransportReader(store: store)
    transportReader = reader
    return NotebookTransportStorage(journalGeneration: source.generation,
      changes: { try await reader.changes(after: $0, limit: $1) },
      incomingCursor: { @MainActor [weak self] peer in
        guard let self, permitsTransportWork else { throw NotebookTransportError.disconnected }
        return try await persistence.submit(writesStore: true) { try $0.admitReplicationSource(peer) }
      }, acknowledgePeer: { @MainActor [weak self] peer, cursor in
        guard let self, permitsTransportWork else { throw NotebookTransportError.disconnected }
        try await persistence.submit(writesStore: true) { try $0.acknowledgePeer(peerID: peer, through: cursor) }
      }, readBlobWindow: { try await reader.blobs($0) },
      stageBlobs: { @MainActor [weak self] blobs in
        guard let self, permitsTransportWork else { throw NotebookTransportError.disconnected }
        try await persistence.submit(writesStore: true) { try $0.stageBlobs(blobs) }
      }, prepareIncoming: { @MainActor [weak self] delivery, blobs in
        guard let self, permitsTransportWork else { throw NotebookTransportError.disconnected }
        return try await persistence.submit(writesStore: true) { try $0.prepareIncomingBlobs(delivery, staging: blobs) }
      }, applyRemoteChange: { [weak self] delivery in
        guard let self else { throw NotebookTransportError.disconnected }
        return try await applyDurableDelivery(delivery)
      })
  }

  func start() async throws {
    guard sync == nil, permitsWork else { return }
    let workspaceID = try await persistence.submit { try $0.storedWorkspaceID() }
    let storage = try await makeTransportStorage()
    #if os(iOS)
      let role = NearbySync.Role.iPadConnector
      let name = "iPad"
    #else
      let role = NearbySync.Role.macListener
      let name = Host.current().localizedName ?? "Mac"
    #endif
    let identity = NotebookTransportIdentity(deviceID: actorID, workspaceID: workspaceID, displayName: name)
    let trust = NotebookKeychainDeviceStore(activationID: pairingActivationID, service: pairingService)
    let retiredPeers = try await persistence.submit { try $0.retiredReplicationPeers() }
    let connection = NearbySync(role: role, identity: identity, storage: storage,
      stagingRoot: store.root.appendingPathComponent("transfer-staging", isDirectory: true),
      trustStore: trust, retiredPeers: retiredPeers)
    bind(connection)
    await connection.start()
    guard permitsWork, sync === connection else { connection.stop(); return }
    updatePeers()
    await startAccountConnection(connection)
    hooks.stateChanged()
  }

  private func bind(_ connection: NearbySync) {
    precondition(sync == nil || sync === connection)
    sync = connection
    connection.onStateChange = { [weak self] state in
      guard let self else { return }
      connectionState = state; updatePeers(); hooks.stateChanged()
    }
    connection.onDeviceRevoked = { [weak self] in self?.hooks.revoked($0) }
    connection.onConnect = { [weak self] peer, generation in
      guard let self else { return }
      peerGenerations[peer.deviceID] = generation; updatePeers(); hooks.connected(peer, generation)
    }
    connection.onDisconnect = { [weak self] peer, generation in
      guard let self, peerGenerations[peer] == generation else { return }
      onHistoryDisconnect?(peer, generation)
      hooks.disconnected(peer, generation)
      peerGenerations[peer] = nil; peerPublication.disconnect(peer)
    }
    connection.onTransient = { [weak self] value, peer, generation in
      guard let self, permitsWork, peerGenerations[peer] == generation else { return }
      hooks.transient(value, peer, generation)
    }
    connection.onHistoryControl = { [weak self] control, peer, generation in
      self?.onHistoryControl?(control, peer, generation)
    }
    connection.onHistoryProgress = { [weak self] _, peer, generation in
      self?.onHistoryProgress?(peer, generation)
    }
  }

  func captureHistoryFleet() async throws -> NotebookHistoryFleetWitness {
    guard permitsWork, let connection = sync,
      hooks.workspaceID() == connection.identity.workspaceID else {
      throw CollaborationError("owner_unavailable", "Владелец подключений пространства ещё не готов.")
    }
    let trust = connection.savedTrust, owner = accountConnection, epoch = owner?.catalogGeneration
    let directory: NotebookAccountSnapshot?
    let status: NotebookHistoryFleetObservation.DirectoryStatus
    do {
      directory = try await owner?.historyDirectory()
      status = directory == nil ? .missing : .verified
    } catch NotebookAccountError.changed { throw NotebookAccountError.changed }
    catch is CancellationError { throw CancellationError() }
    catch { directory = nil; status = .unavailable }
    guard permitsWork, sync === connection, accountConnection === owner,
      owner?.catalogGeneration == epoch, connection.savedTrust == trust else {
      throw CollaborationError("stale_history_readiness", "Граница устройств или аккаунта изменилась.")
    }
    let observation = try connection.historyFleetObservation(directory: directory, directoryStatus: status)
    return .init(observation: observation) { [weak self] in
      guard let self, self.permitsWork, self.sync === connection,
        self.accountConnection === owner, owner?.catalogGeneration == epoch,
        connection.savedTrust == trust,
        try connection.historyFleetObservation(directory: directory, directoryStatus: status) == observation else {
        throw CollaborationError("stale_history_readiness", "Граница устройств, аккаунта или подключения изменилась.")
      }
    }
  }

  private func updatePeers() {
    pairedPeers = sync?.pairedPeers ?? []; knownDevices = sync?.knownPeers ?? []
    blockedDeviceIDs = sync?.savedTrust.blocked ?? []
  }

  func applyDurableDelivery(_ delivery: NotebookReplicationDelivery, cloudAccount: String? = nil,
    waitsForInput: Bool = true) async throws -> UInt64 {
    let applied: (cursor: UInt64, changed: Bool)
    while true {
      guard permitsTransportWork else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
      try Task.checkCancellation()
      let targets = hooks.inputTargets()
      do {
        applied = try await persistence.submit(writesStore: true) { store in
          let cursor: UInt64
          if let cloudAccount { cursor = try store.applyCloudDelivery(delivery, account: cloudAccount, protectingInputOn: targets) }
          else { cursor = try store.applyDelivery(delivery, protectingInputOn: targets) }
          return (cursor, try store.transactionHasContentChanges())
        }
        break
      } catch let error as CollaborationError where error.code == "input_active" {
        guard waitsForInput else { throw error }
        guard await hooks.waitForInput() != nil else { throw CancellationError() }
      }
    }
    if applied.changed { notifyDurableChanges() }
    hooks.contentAvailable(applied.changed)
    if delivery.isSnapshot { sync?.receivedCheckpoint(from: delivery.source.deviceID) }
    return applied.cursor
  }

  func prepareCloudSync() async {
    guard cloudSync == nil, permitsWork else { return }
    do {
      let identity = try await persistence.submit(writesStore: true) { [actorID] store in
        try store.prepareCloudStorage()
        return try (store.replicationSource(deviceID: actorID), store.storedWorkspaceID())
      }
      guard cloudSync == nil, permitsWork else { return }
      cloudSync = NotebookCloudSync(store: store, writer: persistence, source: identity.0, workspaceID: identity.1,
        apply: { [weak self] delivery, account in
          guard let self else { throw NotebookTransportError.disconnected }
          _ = try await applyDurableDelivery(delivery, cloudAccount: account, waitsForInput: false)
        }, waitForInputIdle: { [weak self] in await self?.inputIdleGeneration() },
        report: { [weak self] status in await self?.acceptCloudStatus(status) })
    } catch { cloudStatus = .init(enabled: false, message: error.localizedDescription) }
  }

  private func acceptCloudStatus(_ status: NotebookCloudStatus) { cloudStatus = status }
  private func inputIdleGeneration() async -> UInt64? {
    guard permitsWork else { return nil }
    return await hooks.waitForInput()
  }
  func enableCloud() async {
    if cloudSync == nil { await prepareCloudSync() }
    guard let account = accountConnection?.account else { return }
    await cloudSync?.enable(account: account)
  }
  func disableCloud() async { await cloudSync?.disable() }
  func refresh() { accountConnection?.refresh(); sync?.resumeDiscovery() }

  private func startAccountConnection(_ connection: NearbySync) async {
    let service: any NotebookAccountService
    if let acceptance {
      guard let pair = acceptance.pair else { return }
      service = NotebookAcceptanceAccountService(configuration: acceptance, pair: pair)
    } else {
      guard let cloudSync else { return }
      service = NotebookAccountCloud(cloud: cloudSync)
    }
    let bound: String?
    do { bound = try await persistence.submit { try $0.cloudConfiguration().account } }
    catch { connectionState = .failed("Не удалось проверить настройки устройств. Локальное сохранение доступно."); return }
    bindAccountConnection(connection, service: service, boundAccount: bound)
  }

  private func bindAccountConnection(_ connection: NearbySync, service: any NotebookAccountService, boundAccount: String?) {
    guard permitsWork, sync === connection, hooks.workspaceID() == connection.identity.workspaceID else { return }
    #if os(iOS)
      let platform = NotebookAccountDirectory.Device.Platform.iPad
    #else
      let platform = NotebookAccountDirectory.Device.Platform.mac
    #endif
    let account = NotebookAccountConnection(device: .init(identity: connection.identity, platform: platform,
      activation: pairingActivationID), sync: connection, service: service, initialBoundAccount: boundAccount,
      spaceName: hooks.workspaceName(), publishName: hooks.publishesName(),
      workspaceDeleted: { [weak self] in self?.hooks.workspaceDeleted() },
      shouldOpenDefault: { [weak self] in await self?.hooks.shouldOpenDefault() ?? false },
      openWorkspace: { [weak self] in self?.hooks.openWorkspace($0) },
      accountReady: { [weak self] account in
        guard let self, permitsWork, sync === connection, let accountOwner = accountConnection else { return }
        let generation = accountOwner.catalogGeneration, sourceAccount = accountOwner.account
        let workspaceID = hooks.workspaceID()
        guard sourceAccount == account else { return }
        if let name = accountOwner.spaces.first(where: { $0.id == connection.identity.workspaceID })?.name {
          await hooks.nameSaved(name, accountOwner.deletedSpaces)
        }
        guard permitsWork, sync === connection, accountConnection === accountOwner,
          hooks.workspaceID() == workspaceID, workspaceID == connection.identity.workspaceID,
          accountOwner.catalogGeneration == generation, accountOwner.account == sourceAccount else { return }
        hooks.cloudConnected(account)
        await cloudSync?.connect(account: account)
      }, accountUnavailable: { [weak self] in await self?.cloudSync?.stop() })
    accountConnection = account; account.start()
  }

  #if DEBUG
  func startFixture(_ connection: NearbySync, service: any NotebookAccountService) {
    precondition(sync == nil && accountConnection == nil && hooks.workspaceID() == connection.identity.workspaceID)
    bind(connection); bindAccountConnection(connection, service: service, boundAccount: nil)
  }
  #endif

  /// Closing routes retains their trust and accepted writer identities through
  /// host drain. The final reader close belongs to the workspace's saved boundary.
  func stop() async -> Bool {
    stopped = true
    await accountConnection?.stop(); await cloudSync?.stop()
    if let sync, !(await sync.stopAndDrain()) { return false }
    return true
  }

  func close() async {
    peerPublication.stop()
    await transportReader?.close(); transportReader = nil
  }

  isolated deinit {
    peerPublication.stop(); sync?.stop()
    if let accountConnection { Task { await accountConnection.stop() } }
    if let cloudSync { Task { await cloudSync.stop() } }
  }
}
