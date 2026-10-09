import Foundation
import NotebookCore
import NotebookCodex
import NotebookScriptHost
import Observation

/// IPC, script and Codex execution belong to the admitted workspace. This owner
/// borrows availability and native import effects, never a camera or scene.
@MainActor @Observable
final class NotebookAgentServices: NotebookPreviewWorkspace {
  struct Hooks {
    var permitsWork: @MainActor () -> Bool = { false }
    var isReady: @MainActor () -> Bool = { false }
    var workspaceID: @MainActor () -> UUID? = { nil }
    var header: @MainActor () -> NotebookWorkspaceHeader? = { nil }
    var contentChanged: @MainActor () -> Void = {}
    var importDocument: @MainActor (NotebookDocumentImportRequest) async throws -> JSONValue = { _ in throw CancellationError() }
    var permitsPreparation: @MainActor () -> Bool = { false }
    var localPresence: @MainActor () -> SessionPresence? = { nil }
    var localPresencePhase: @MainActor () -> PresencePhase = { .settled }
  }
  let workspaceRuntime: NotebookWorkspaceRuntime
  var store: NotebookStore { workspaceRuntime.store }
  var persistence: NotebookPersistenceQueue { workspaceRuntime.persistence }
  var actorID: UUID { workspaceRuntime.actorID }
  var commandReader: NotebookCommandReader { workspaceRuntime.commandReader }
  var connection: NotebookWorkspaceConnection { workspaceRuntime.connection }
  private var historyReadiness: NotebookHistoryReadiness { workspaceRuntime.historyReadiness }
  var hasPendingAuthoredPreparation: Bool {
    codexStartupTask != nil || scriptCoordinator?.hasPendingWorkspaceWork == true
      || programImporter?.hasPendingPreparation == true
  }
  let allowsCodexRegistration: Bool
  let acceptance: NotebookAcceptanceConfiguration?
  let commandSocketURL: URL?
  @ObservationIgnored var hooks = Hooks()
  @ObservationIgnored var codexHost: NotebookCodexHost?
  @ObservationIgnored private var codexSidecar: NotebookCodexSidecar?
  @ObservationIgnored private var codexStartupTask: Task<Void, Never>?
  private(set) var agentStartupError: String?
  @ObservationIgnored private var commandServer: NotebookIPCServer?
  @ObservationIgnored private var scriptCoordinator: NotebookScriptCoordinator?
  @ObservationIgnored private var programImporter: NotebookProgramImporter?
  @ObservationIgnored private var previewPublisher: MacPreviewPublisher?
  private(set) var observedPeerID: UUID?
  private(set) var peerPresenceEnvelope: PresenceEnvelope?
  private var presenceSequenceTracker = PresenceSequenceTracker()
  let presentationRelay = NotebookPresentationRelay()
  private var closed = false
  var isClosing: Bool { closed || !hooks.permitsWork() }
  var permitsExternalWork: Bool { !isClosing }
  var loadState: NotebookWorkspaceLoadState { hooks.isReady() ? .ready : .loading }
  var admittedWorkspaceID: UUID? { hooks.workspaceID() }
  var workspaceHeader: NotebookWorkspaceHeader? { hooks.header() }
  private var sync: NearbySync? { connection.sync }
  var observedPresence: SessionPresence? { observedPeerID == nil ? hooks.localPresence() : peerPresenceEnvelope?.presence }
  var observedPresencePhase: PresencePhase { observedPeerID == nil ? hooks.localPresencePhase() : peerPresenceEnvelope?.phase ?? .active }
  var isPeerConnected: Bool { connection.isPeerConnected }
  var permitsBackgroundPreparation: Bool { workspaceRuntime.permitsAuthoredWork && !isClosing && hooks.permitsPreparation() && !connection.peerPublication.isActive }
  var permitsOptionalPreparation: Bool { permitsBackgroundPreparation && SceneRenderResources.shared.allowsOptionalPreparation }
  var runtimeSocketKey: String? { commandServer == nil ? nil : commandSocketURL?.deletingPathExtension().lastPathComponent }

  init(runtime: NotebookWorkspaceRuntime, commandSocketURL: URL?,
    allowsCodexRegistration: Bool, acceptance: NotebookAcceptanceConfiguration?) {
    workspaceRuntime = runtime; self.commandSocketURL = commandSocketURL
    self.allowsCodexRegistration = allowsCodexRegistration; self.acceptance = acceptance
  }

  isolated deinit { commandServer?.stop() }

  func start() async {
    do { try await scripts().start() } catch { agentStartupError = error.localizedDescription }
    do { try startCommandServer() } catch { agentStartupError = error.localizedDescription }
    guard previewPublisher == nil, !isClosing else { return }
    let publisher = MacPreviewPublisher(model: self)
    previewPublisher = publisher; publisher.start()
  }

  func prepareCurrentView() async {
    // The request's accepted fence precedes source discovery. A header callback
    // may still be queued when IPC issues observe immediately after a write.
    if let header = try? await readCommandCut({ try $0.workspaceHeader() }) {
      await previewPublisher?.requestCurrentView(header: header)
    }
  }
  func suspendPreparation() { previewPublisher?.suspendForInput() }
  func drainHistoryPreparation() async { await previewPublisher?.drainHistoryPreparation() }
  func finishStartup() async { await codexStartupTask?.value }

  func stop() async {
    closed = true
    await codexStartupTask?.value
    await previewPublisher?.stop(); previewPublisher = nil
    await commandServer?.stopAndDrain(); commandServer = nil
    codexSidecar?.detachView(); codexSidecar = nil
    await scriptCoordinator?.shutdown(); scriptCoordinator = nil
    programImporter?.stop()
  }

  func performStoreCommand<T: Sendable>(publishesChanges: Bool = false,
    _ operation: @escaping @Sendable (NotebookStore) throws -> T) async throws -> T {
    guard !isClosing else { throw CancellationError() }
    return try await persistence.submit(publishesChanges: publishesChanges, writesStore: true, operation)
  }

  private func enqueue(owner: NotebookPersistenceQueue.Owner, _ operation: @escaping @Sendable (NotebookStore) throws -> Void) {
    persistence.enqueue(owner: owner) { try operation($0); return false }
  }

  func peerConnected(_ peer: NotebookTransportIdentity, generation: UUID) {
    observedPeerID = peer.deviceID; peerPresenceEnvelope = nil; presenceSequenceTracker = PresenceSequenceTracker()
    enqueue(owner: .peerSession(peer.deviceID)) { try $0.beginSelectionPublication(deviceID: peer.deviceID, connectionID: generation) }
    codexSidecar?.allowDevice(peer.deviceID)
  }
  func peerDisconnected(_ peer: UUID, generation: UUID) {
    presentationRelay.disconnect(peer)
    enqueue(owner: .peerSession(peer)) {
      try $0.resetInputActivity(deviceID: peer)
      try $0.endSelectionPublication(deviceID: peer, connectionID: generation)
    }
    if observedPeerID == peer { observedPeerID = nil; peerPresenceEnvelope = nil }
  }
  func revokeDevice(_ id: UUID) { codexSidecar?.revokeDevice(id) }
  func receive(_ message: NotebookTransportTransient, peerID: UUID, generation: UUID) {
    guard !isClosing, connection.peerGenerations[peerID] == generation else { return }
    switch message {
    case .relay: break
    case .selection(let value):
      guard value.deviceID == peerID, value.isValid else { return }
      enqueue(owner: .peerSession(peerID)) { _ = try $0.acceptSelectionPublication(value, connectionID: generation) }
    case .inputActivity(let value):
      guard value.deviceID == peerID, value.isValid, connection.peerPublication.receive(value) else { return }
      enqueue(owner: .inputActivity(peerID)) { try $0.saveInputActivity(value) }
    case .presence(let envelope):
      guard observedPeerID == peerID, envelope.presence.isValid, presenceSequenceTracker.accepts(envelope) else { return }
      presentationRelay.observe(envelope, from: peerID); peerPresenceEnvelope = envelope
      if envelope.phase == .settled {
        enqueue(owner: .peerPresence(peerID)) { _ = try $0.acceptPresencePublication(envelope, deviceID: peerID, connectionID: generation) }
      }
    case .presentation(let value):
      if case .receipt(let receipt) = value { presentationRelay.receive(receipt, from: peerID) }
    case .codex(let envelope):
      Task { [weak self] in
        guard let self, connection.peerGenerations[peerID] == generation, !isClosing else { return }
        await startCodexSidecar()
        guard connection.peerGenerations[peerID] == generation, !isClosing else { return }
        let reply: NotebookChatEnvelope
        if let codexSidecar {
          guard let value = await codexSidecar.receive(envelope, peerID: peerID) else { return }; reply = value
        } else { reply = .init(id: envelope.id, body: .reply(.failure(agentStartupError ?? "Codex недоступен"))) }
        guard connection.peerGenerations[peerID] == generation, !isClosing else { return }
        sync?.sendTransient(.codex(reply), to: peerID)
      }
    }
  }
    /// Native acceptance exercises the same journal and owner as paired input.
    func localCodexQuery(_ query: NotebookChatQuery, requestID: UUID = UUID()) async throws -> NotebookChatReply {
      if codexSidecar == nil { await startCodexSidecar() }
      guard let codexSidecar else { throw NotebookPersistenceQueue.Failure(message: agentStartupError ?? "Codex недоступен") }
      guard let envelope = await codexSidecar.receive(.init(id: requestID, body: .request(query)), peerID: actorID),
        case .reply(let reply) = envelope.body else { throw NotebookTransportError.disconnected }
      if case .failure(let message) = reply { throw NotebookPersistenceQueue.Failure(message: message) }
      return reply
    }
    func startCodexSidecar() async {
      guard !isClosing, loadState == .ready, codexSidecar == nil,
        let workspaceID = workspaceHeader?.workspaceID else { return }
      if let codexStartupTask { await codexStartupTask.value; return }
      let task = Task { [self] in
        defer { codexStartupTask = nil }
        do {
          guard allowsCodexRegistration || acceptance != nil else {
            agentStartupError = "Запуск Codex из этого архива закрыт до безопасной активации пары. Действующие инструменты Notebook не перенаправлены."
            return
          }
          guard let entry = Bundle.main.resourceURL?.appendingPathComponent("NotebookTools/dist/index.mjs"),
            let commandSocketURL else { throw CodexBridgeError.notInstalled }
          let directory: URL
          let scope: CodexRuntimeScope?
          if let acceptance, let path = acceptance.codexDirectory {
            directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
              attributes: [.posixPermissions: 0o700])
            scope = try CodexRuntimeScope(directory: directory, toolsEntry: entry, socket: commandSocketURL)
          } else {
            directory = FileManager.default.homeDirectoryForCurrentUser
              .appendingPathComponent("Library/Application Support/Notebook/Codex", isDirectory: true)
            scope = nil
          }
          let host = codexHost ?? NotebookCodexHost()
          codexHost = host
          let sidecar = try await host.workspace(persistence: persistence,
            workspaceID: workspaceID, computerID: actorID, directory: directory, scope: scope, entry: entry, socket: commandSocketURL,
            isWorkspaceOpen: { [weak self] in self?.isClosing == false },
            authorizePeer: { [weak self] peer in
              guard let self else { return false }
              return peer == self.actorID || self.sync?.pairedPeers.contains(where: { $0.deviceID == peer }) == true
            }) { [weak self] envelope, peer in
              guard let self, !isClosing, peer != actorID else { return }
              sync?.sendTransient(.codex(envelope), to: peer)
            }
          guard !isClosing else { sidecar.detachView(); return }
          codexSidecar = sidecar; agentStartupError = nil
        } catch { if !isClosing { agentStartupError = NotebookCodexSidecar.message(error) } }
      }
      codexStartupTask = task
      await task.value
    }


    private func startCommandServer() throws {
      guard commandServer == nil, let commandSocketURL else { return }
      let server = NotebookIPCServer(socketURL: commandSocketURL) { [weak self] command in
        guard let self else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
        return try await self.executeLocalCommand(command)
      }
      try server.start()
      commandServer = server
    }

    /// Wait outside the writer: a contact release must be able to commit while
    /// an agent is waiting. Core rechecks activity and causal versions inside SQL.
    func executeLocalCommand(_ command: NotebookCommand) async throws -> JSONValue {
      guard loadState == .ready, permitsExternalWork else {
        throw CollaborationError("owner_unavailable", "Хранилище Notebook ещё не открыто.")
      }
      if command.command == .historyReadiness {
        guard let request = command.historyReadiness else {
          throw CollaborationError("invalid_history_request", "Нужен запрос сверки истории.")
        }
        return try historyReadiness.handle(request, runtime: workspaceRuntime)
      }
      if command.command == .read, command.queries?.contains(where: { $0.kind == .replicaInventory }) == true {
        return try await historyReadiness.observeInventory(command, runtime: workspaceRuntime)
      }
      if [.script, .importProgram, .importDocument, .importDocumentResource].contains(command.command),
        let error = historyReadiness.authoredAdmissionError { throw error }
      if command.command == .script || command.command == .scriptContext {
        let coordinator = try scripts()
        if command.command == .script, let request = command.script {
          return try await coordinator.handle(request)
        }
        if command.command == .scriptContext, let request = command.scriptContext {
          return .object(["api_version": .number(2), "value": try await coordinator.context(request)])
        }
        throw CollaborationError("invalid_script_request", "Запрос исполнения или контекста отсутствует.")
      }
      if command.command == .importDocument {
        guard let request = command.documentImport else {
          throw CollaborationError("invalid_document_import", "Запрос импорта документа отсутствует.")
        }
        return try await hooks.importDocument(request)
      }
      if command.command == .importDocumentResource {
        guard let request = command.documentResourceImport, let workspaceID = workspaceHeader?.workspaceID else {
          throw CollaborationError("invalid_document_resource", "Запрос импорта ресурса отсутствует.")
        }
        if programImporter == nil { programImporter = NotebookProgramImporter(persistence: persistence, workspaceID: workspaceID) }
        return try await programImporter!.handle(request)
      }
      if command.command == .importProgram {
        guard let request = command.programImport, let workspaceID = workspaceHeader?.workspaceID else {
          throw CollaborationError("invalid_program_package", "Запрос импорта отсутствует.")
        }
        if programImporter == nil { programImporter = NotebookProgramImporter(persistence: persistence, workspaceID: workspaceID) }
        return try await programImporter!.handle(request)
      }
      if command.command == .presentation {
        presentationRelay.send = { [weak self] message, peer in
          self?.sync?.sendTransient(.presentation(message), to: peer)
        }
        return try presentationRelay.handle(command)
      }
      if NotebookReadCommand.accepts(command.command) {
        let request = try NotebookReadCommand(command)
        return try await readCommandCut { try $0.handle(request) }
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while true {
        // Core admits the actual affected carriers in the writer transaction.
        // An unrelated contact never delays the first attempt; only a rejected
        // affected surface waits outside the FIFO so its release can commit.
        do {
          guard permitsExternalWork else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
          let result = try await persistence.submit(owner: .command(command.command)) {
            try NotebookCommandDispatcher(store: $0).handle(command)
          }
          if command.changesStore { hooks.contentChanged() }
          if command.command == .render || command.command == .pageVision { previewPublisher?.requestsChanged() }
          return result
        } catch let error as CollaborationError where error.code == "input_active" && ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(20))
        }
      }
    }

    /// A fixed accepted prefix is captured before the first await. The reader
    /// then owns its own fresh WAL snapshot; later writes keep draining.
    func capturePreviewReadFence() -> NotebookPersistenceQueue.ReadFence {
      persistence.captureReadFence()
    }

    func readCommandCut<Value: Sendable>(
      _ operation: @escaping @Sendable (NotebookQueryCut) throws -> Value) async throws -> Value {
      try await workspaceRuntime.observeHistorySource(operation).value
    }

    private func scripts() throws -> NotebookScriptCoordinator {
      if let scriptCoordinator { return scriptCoordinator }
      guard let userService = Bundle.main.object(forInfoDictionaryKey: "NotebookScriptService") as? String,
        let markupService = Bundle.main.object(forInfoDictionaryKey: "NotebookMarkupService") as? String,
        !userService.isEmpty, !markupService.isEmpty else {
        throw CollaborationError("script_service_unavailable", "В сборке отсутствует изолированный исполнитель Notebook.")
      }
      let persistence = persistence
      let coordinator = NotebookScriptCoordinator(command: { [weak self] command in
        guard let self else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
        return try await self.executeLocalCommand(command)
      }, reader: { [weak self] operation in
        guard let self else { throw CollaborationError("owner_unavailable", "Notebook завершает работу.") }
        return try await self.readCommandCut(operation)
      }, persistence: { operation in
        try await persistence.submit(writesStore: true, operation)
      }, workingDirectory: store.root.appendingPathComponent("derived/script-runtime", isDirectory: true),
        canonicalExport: { [weak self] cut, options, id in
          guard let self else { throw CancellationError() }
          return try await DocumentCanonicalExport.publish(cut: cut, options: options, jobID: id, store: self.store, persistence: persistence)
        }, prepareCurrentView: { [weak self] in await self?.prepareCurrentView() },
        userServiceName: userService, markupServiceName: markupService)
      scriptCoordinator = coordinator
      return coordinator
    }
}
