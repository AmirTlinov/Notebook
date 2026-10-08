import CloudKit
import CryptoKit
import Foundation
import NotebookCore
import OSLog

struct NotebookCloudStatus: Sendable {
  let enabled: Bool
  let message: String
  static let off = Self(enabled: false, message: "Выключено. Тетрадь сохраняется на этом устройстве.")
}

/// CKSyncEngine owns scheduling and CloudKit tokens, never document merging.
/// All durable mutations enter the application's ordinary persistence queue.
actor NotebookCloudSync: CKSyncEngineDelegate {
  static let containerIdentifier = "iCloud.com.amirtlinov.notebook"
  private let store: NotebookStore
  private let writer: NotebookPersistenceQueue
  private let uploadReader: NotebookCloudUploadReader
  private let source: NotebookReplicationSource
  private let zoneID: CKRecordZone.ID
  private let apply: @Sendable (NotebookReplicationDelivery, String) async throws -> Void
  private let waitForInputIdle: @Sendable () async -> UInt64?
  private let report: @Sendable (NotebookCloudStatus) async -> Void
  private var engine: CKSyncEngine?
  private var account: String?
  private var contentEnabled = false
  private var stopped = false
  private var accountObserver: (account: String, changed: @Sendable (Bool) async -> Void)?
  private let accountZoneID = CKRecordZone.ID(zoneName: NotebookAccountCloud.zoneName, ownerName: CKCurrentUserDefaultName)
  private var assets: [String: URL] = [:]
  private struct Flight {
    let id: UUID
    let task: Task<Void, Never>
  }
  private enum Deferred {
    case input, dependencies, semantic(String)
    var wake: DeferredWake {
      switch self { case .input: .input; case .dependencies: .dependencies; case .semantic: .semantic }
    }
  }
  private struct DeferredWake: OptionSet, Sendable {
    let rawValue: UInt8
    static let input = Self(rawValue: 1)
    static let dependencies = Self(rawValue: 2)
    static let semantic = Self(rawValue: 4)
  }
  private var inbound: Flight?
  private var outbound: Flight?
  private var inputWait: Flight?
  private var inboundRequested = false
  private var outboundRequested = false
  private var inboundPaused = false
  private var outboundPaused = false
  private var deferred: [NotebookReplicationSource: Deferred] = [:]
  private var overflowWake: DeferredWake = []
  private var overflowReported = false
  private var afterSource: NotebookReplicationSource?
  private var sweepAgain = false
  private var sweepProgressed = false
  private var materialWake: UInt64 = 0
  private var lastInputWake: (generation: UInt64, material: UInt64)?
  private var epoch = UUID()
  private var hasFailure = false
  private var resuming = false
  private var resumeRetry: Task<Void, Never>?
  private var uploadPreparation: Task<NotebookCloudUploadPlan?, Error>?
  private var historyPause: UUID?
  private var engineStop: Flight?
  private var delegateCallbacks = 0
  private var delegateJoins: [CheckedContinuation<Void, Never>] = []

  init(store: NotebookStore, writer: NotebookPersistenceQueue, source: NotebookReplicationSource, workspaceID: UUID,
    apply: @escaping @Sendable (NotebookReplicationDelivery, String) async throws -> Void,
    waitForInputIdle: @escaping @Sendable () async -> UInt64?,
    report: @escaping @Sendable (NotebookCloudStatus) async -> Void) {
    self.store = store; self.writer = writer; self.source = source
    uploadReader = NotebookCloudUploadReader(store: store)
    zoneID = .init(zoneName: "Notebook-" + workspaceID.uuidString.lowercased(), ownerName: CKCurrentUserDefaultName)
    self.apply = apply; self.waitForInputIdle = waitForInputIdle; self.report = report
  }

  private func container() throws -> CKContainer {
    // Unsigned/Simulator acceptance builds must never touch the user's cloud.
    guard Bundle.main.object(forInfoDictionaryKey: "NotebookCloudContainer") as? String == Self.containerIdentifier else {
      throw CloudFailure("В этой сборке синхронизация iCloud не настроена. Нужна подписанная сборка с общим iCloud-контейнером.")
    }
    return CKContainer(identifier: Self.containerIdentifier)
  }

  private func currentAccount(_ container: CKContainer) async throws -> String {
    guard try await container.accountStatus() == .available else {
      throw CloudFailure("iCloud недоступен. Локальная тетрадь и прямой обмен продолжают работать.")
    }
    return try await container.userRecordID().recordName
  }

  /// The sole engine also observes device metadata when content sync is off.
  /// No second engine or competing AppDelegate subscription owns this database.
  func observeAccount(_ expected: String, changed: @escaping @Sendable (Bool) async -> Void) async throws {
    guard historyPause == nil else { throw NotebookTransportError.historyReadinessPending }
    let token = epoch, container = try container()
    guard try await currentAccount(container) == expected else { throw NotebookAccountError.changed }
    guard epoch == token else { throw CancellationError() }
    let first = accountObserver == nil || engine == nil
    accountObserver = (expected, changed)
    if engine == nil { try await start(container: container, account: expected, token: token) }
    guard epoch == token, let engine, account == expected else { throw CancellationError() }
    if first {
      try await engine.fetchChanges(.init(scope: .zoneIDs([accountZoneID])))
      // A fetched event never waits for this account task to finish observing.
      Task { await changed(false) }
    }
  }

  private func notifyAccount(_ changed: Bool) {
    guard let callback = accountObserver?.changed else { return }
    Task { await callback(changed) }
  }

  static func fetchZoneIDs(workspaceID: CKRecordZone.ID, contentEnabled: Bool, requested: CKSyncEngine.FetchChangesOptions.Scope = .all) -> [CKRecordZone.ID] {
    let account = CKRecordZone.ID(zoneName: NotebookAccountCloud.zoneName, ownerName: CKCurrentUserDefaultName)
    return (contentEnabled ? [account, workspaceID] : [account]).filter { requested.contains($0) }
  }

  /// First account enrollment enables normal sync. A saved user opt-out stays
  /// off, and a different account never receives this workspace implicitly.
  func connect(account verifiedAccount: String) async {
    guard historyPause == nil else { return }
    let token = epoch
    do {
      let configuration = try await writer.submit { try $0.cloudConfiguration() }
      guard historyPause == nil, epoch == token else { return }
      guard configuration.account == nil || configuration.account == verifiedAccount else {
        await stop()
        await report(.init(enabled: false, message: NotebookAccountError.changed.localizedDescription))
        return
      }
      if configuration.account == nil { await enable(account: verifiedAccount) }
      else if configuration.enabled { await resume() }
      else { await report(.off) }
    } catch { await reportFailure(error) }
  }

  func enable(account expected: String) async {
    guard historyPause == nil else { return }
    let token = await stopEngine()
    guard epoch == token else { return }
    stopped = false
    do {
      let container = try container(), current = try await currentAccount(container)
      guard epoch == token else { return }
      guard current == expected else { throw NotebookAccountError.changed }
      try await writer.submit(writesStore: true) { [source] store in
        let bound = try store.cloudConfiguration().account
        guard bound == nil || bound == expected else { throw NotebookAccountError.changed }
        try store.enableCloud(account: current, source: source)
      }
      try await start(container: container, account: current, token: token)
    } catch { if epoch == token { await reportFailure(error) } }
  }

  func resume() async {
    guard historyPause == nil else { return }
    stopped = false
    guard engine == nil, !resuming else { return }
    resuming = true
    defer { resuming = false }
    let token = epoch
    do {
      let configuration = try await writer.submit { try $0.cloudConfiguration() }
      guard epoch == token else { return }
      guard configuration.enabled, let bound = configuration.account else { await report(.off); return }
      let container = try container(), current = try await currentAccount(container)
      guard epoch == token else { return }
      guard current == bound else {
        try await writer.submit(writesStore: true) { try $0.disableCloud(account: bound) }
        guard epoch == token else { return }
        await stop()
        await report(.init(enabled: false, message: "Apple Account изменился. Для отправки этой тетради новому аккаунту откройте пространство этого аккаунта.")); return
      }
      try await start(container: container, account: bound, token: token)
    } catch {
      guard epoch == token else { return }
      await reportFailure(error)
      // CKSyncEngine cannot retry before it exists. Retry only this initial
      // account gate after an offline launch; data scheduling remains Apple's.
      guard epoch == token, resumeRetry == nil else { return }
      resumeRetry = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        await self?.retryResume(token: token)
      }
    }
  }

  private func retryResume(token: UUID) async {
    guard epoch == token else { return }
    resumeRetry = nil
    await resume()
  }

  private func start(container: CKContainer, account: String, token: UUID) async throws {
    guard engine == nil else { return }
    let stored = try await writer.submit { try $0.cloudConfiguration() }
    guard stored.account == nil || stored.account == account else { throw NotebookAccountError.changed }
    let enabled = stored.enabled && stored.account == account
    let data = enabled ? try await writer.submit { try $0.cloudEngineState(account: account) } : nil
    guard epoch == token, engine == nil else { return }
    contentEnabled = enabled
    let state = try data.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    resumeRetry?.cancel(); resumeRetry = nil
    self.account = account; hasFailure = false
    var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: self)
    configuration.automaticallySync = true
    let engine = CKSyncEngine(configuration); self.engine = engine
    // SQLite outbox is authoritative if a process died between an ACK and
    // CKSyncEngine's following serialization event.
    engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
    if enabled && state == nil { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
    await report(enabled ? .init(enabled: true, message: "Синхронизация iCloud включена.") : .off)
    if enabled { try await activateContent(account: account) }
  }

  func disable() async {
    guard historyPause == nil else { return }
    let token = await stopEngine()
    guard epoch == token else { return }
    do {
      try await writer.submit(writesStore: true) { try $0.disableCloud() }
      guard epoch == token else { return }
      await report(.off)
      if let observer = accountObserver {
        let container = try container()
        guard try await currentAccount(container) == observer.account else { throw NotebookAccountError.changed }
        try await start(container: container, account: observer.account, token: token)
      }
    } catch { if epoch == token { await reportFailure(error) } }
  }

  private func invalidate() -> CKSyncEngine? {
    resumeRetry?.cancel(); resumeRetry = nil
    uploadPreparation?.cancel()
    inbound?.task.cancel(); outbound?.task.cancel(); inputWait?.task.cancel()
    inboundRequested = false; outboundRequested = false
    deferred.removeAll(); overflowWake = []; overflowReported = false
    afterSource = nil; sweepAgain = false; sweepProgressed = false; lastInputWake = nil
    epoch = UUID(); let previous = engine; engine = nil; account = nil; contentEnabled = false
    return previous
  }

  func stop() async { stopped = true; accountObserver = nil; _ = await stopEngine() }

  /// This is a suspension of the existing engine, never a second sync owner.
  /// Its request stays closed until the application's exact writer seal ends.
  func pauseForHistory(_ requestID: UUID) async throws {
    guard historyPause == nil || historyPause == requestID else {
      throw NotebookTransportError.historyReadinessPending
    }
    historyPause = requestID
    await stop()
  }

  func finishHistoryPause(_ requestID: UUID) throws {
    guard historyPause == requestID else { throw NotebookTransportError.historyCutStale }
    historyPause = nil
  }

  private func stopEngine() async -> UUID {
    let (token, task) = beginEngineStop()
    await task.value
    return token
  }

  private func stopFromDelegate() {
    _ = beginEngineStop()
  }

  private func beginEngineStop() -> (UUID, Task<Void, Never>) {
    let retry = resumeRetry, preparation = uploadPreparation, preceding = engineStop?.task
    let previous = invalidate(), files = Array(assets.values); assets.removeAll()
    let joining = [inbound?.task, outbound?.task, inputWait?.task].compactMap { $0 }
    // A delegate must return before waiting for its own operation to cancel.
    let id = UUID(), token = epoch
    let task = Task { [self] in
      await preceding?.value
      await previous?.cancelOperations()
      for task in joining { await task.value }
      _ = await preparation?.result
      await retry?.value
      await joinDelegateCallbacks()
      for file in files { try? FileManager.default.removeItem(at: file) }
      if engineStop?.id == id { engineStop = nil }
    }
    engineStop = .init(id: id, task: task)
    return (token, task)
  }

  private func joinDelegateCallbacks() async {
    guard delegateCallbacks != 0 else { return }
    await withCheckedContinuation { delegateJoins.append($0) }
  }

  private func finishedDelegateCallback() {
    delegateCallbacks -= 1
    guard delegateCallbacks == 0 else { return }
    let joining = delegateJoins; delegateJoins.removeAll()
    for continuation in joining { continuation.resume() }
  }

  func notifyLocalChanges() async {
    guard !stopped else { return }
    if engine == nil, !contentEnabled { await resume() }
    guard !stopped, contentEnabled else { return }
    materialWake &+= 1
    deferred = deferred.filter { if case .input = $0.value { return true }; return false }
    overflowWake.formIntersection(.input)
    if overflowWake.isEmpty { overflowReported = false }
    inboundPaused = false; outboundPaused = false
    requestInbound(sweep: true); requestOutbound(); watchInput()
  }

  func inputChanged() { watchInput() }

  /// Durable content scheduling is bound to the locally enabled account. The
  /// CloudKit adapter uses this same seam after authenticating its account;
  /// preparing a local outbox needs neither an engine nor a network session.
  func activateContent(account expected: String) async throws {
    guard historyPause == nil else { throw NotebookTransportError.historyReadinessPending }
    let token = epoch
    let configuration = try await writer.submit { try $0.cloudConfiguration() }
    guard epoch == token else { throw CancellationError() }
    guard configuration.enabled, configuration.account == expected,
      account == nil || account == expected else { throw NotebookTransportError.disconnected }
    account = expected; stopped = false; contentEnabled = true; hasFailure = false
    resumeRetry?.cancel(); resumeRetry = nil
    inboundPaused = false; outboundPaused = false
    requestInbound(sweep: true); requestOutbound()
  }

  /// Retry belongs to the existing FIFO. A retained apply/batch task keeps its
  /// original accepted result; waking the other run never creates its retry.
  func writerRecovered() {
    guard !stopped, contentEnabled else { return }
    inboundPaused = false; outboundPaused = false
    requestInbound(sweep: true); requestOutbound(); watchInput()
  }

  /// Join the work already owned by this actor, leaving a rejected contact's
  /// idle subscription in place. No delivery or retry is admitted by this join.
  func waitForContentRuns() async {
    while inbound != nil || outbound != nil {
      let joining = [inbound?.task, outbound?.task].compactMap { $0 }
      for task in joining { await task.value }
    }
  }

  var deferredSourceCount: Int { deferred.count }

  private func matches(_ token: UUID, account expected: String) -> Bool {
    !stopped && epoch == token && contentEnabled && account == expected
  }

  @MainActor private static func admitWrite<Value: Sendable>(_ writer: NotebookPersistenceQueue,
    _ operation: @escaping @Sendable (NotebookStore) throws -> Value) async throws -> Value {
    // Stop can run while this task crosses to MainActor. Cancellation is
    // checked at FIFO admission; an already accepted slot retains its result.
    try Task.checkCancellation()
    return try await writer.submit(writesStore: true, operation)
  }

  private func requestInbound(sweep: Bool = false) {
    inboundRequested = true
    if sweep { sweepAgain = true }
    guard !stopped, inbound == nil, !inboundPaused, contentEnabled, let account else { return }
    let id = UUID(), token = epoch
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runInbound(id: id, token: token, account: account)
    }
    inbound = .init(id: id, task: task)
  }

  private func requestOutbound() {
    outboundRequested = true
    guard !stopped, outbound == nil, !outboundPaused, contentEnabled, let account else { return }
    let id = UUID(), token = epoch
    let task = Task { [weak self] in
      guard let self else { return }
      await self.runOutbound(id: id, token: token, account: account)
    }
    outbound = .init(id: id, task: task)
  }

  private func finishInbound(_ id: UUID) {
    guard inbound?.id == id else { return }
    inbound = nil
    if inboundRequested { requestInbound() }
  }

  private func finishOutbound(_ id: UUID) {
    guard outbound?.id == id else { return }
    outbound = nil
    if outboundRequested { requestOutbound() }
  }

  private func watchInput() {
    guard !stopped, contentEnabled, inputWait == nil,
      overflowWake.contains(.input) || deferred.values.contains(where: { if case .input = $0 { return true }; return false }) else { return }
    let id = UUID(), token = epoch, material = materialWake
    let task = Task { [weak self, waitForInputIdle] in
      let generation = await waitForInputIdle()
      await self?.inputDidBecomeIdle(id: id, token: token, material: material, generation: generation)
    }
    inputWait = .init(id: id, task: task)
  }

  private func inputDidBecomeIdle(id: UUID, token: UUID, material: UInt64, generation: UInt64?) {
    guard inputWait?.id == id else { return }
    inputWait = nil
    guard epoch == token else { watchInput(); return }
    guard !stopped, contentEnabled, let generation else { return }
    // A rejected packet may outlive the contact captured before its FIFO wait.
    // Retry that cut once, then require another actual input/material epoch.
    guard lastInputWake?.generation != generation || lastInputWake?.material != material else { return }
    lastInputWake = (generation, material)
    deferred = deferred.filter { if case .input = $0.value { return false }; return true }
    overflowWake.remove(.input)
    if overflowWake.isEmpty { overflowReported = false }
    requestInbound(sweep: true)
  }

  func contentWasFetched() {
    deferred = deferred.filter { if case .dependencies = $0.value { return false }; return true }
    overflowWake.remove(.dependencies)
    if overflowWake.isEmpty { overflowReported = false }
    requestInbound(sweep: true); requestOutbound()
  }

  private static func deferredReason(_ error: Error) -> Deferred? {
    if let accepted = error as? NotebookAcceptedWriteError {
      guard case .rejected = accepted.outcome else { return nil }
      return deferredReason(accepted.underlying)
    }
    if let failure = error as? CollaborationError {
      if failure.code == "input_active" { return .input }
      guard !["storage_error", "operation_failed", "conversion_required", "publication_pending",
        "edit_receipt_unavailable", "action_version_unavailable", "request_identity_unavailable"].contains(failure.code) else { return nil }
      return .semantic(String(failure.localizedDescription.prefix(1024)))
    }
    if let failure = error as? NotebookStorageError {
      switch failure {
      case .transactionConflict, .invalidTransaction, .limitExceeded, .unsupportedFormat:
        return .semantic(String(failure.localizedDescription.prefix(1024)))
      default: return nil
      }
    }
    if let failure = error as? NotebookTransportError {
      switch failure {
      case .invalidFrame, .frameTooLarge, .unsupportedVersion, .identityMismatch,
        .invalidSequence, .invalidBlob, .blobTooLarge, .unexpectedBlob, .invalidAcknowledgement, .resourceLimit:
        return .semantic(String(describing: failure))
      default: return nil
      }
    }
    return nil
  }

  private func deferSource(_ source: NotebookReplicationSource, reason: Deferred) async {
    if deferred[source] != nil || deferred.count < 128 { deferred[source] = reason }
    else {
      // The cursor still visits every journal once in this finite sweep. The
      // existing inbox retains uncached heads; only their wake kinds stay here.
      overflowWake.insert(reason.wake)
      if !overflowReported {
        overflowReported = true
        await report(.init(enabled: true, message: "Входящие материалы iCloud ожидают применения. Сохранённые источники продолжают обмен."))
      }
    }
    switch reason {
    case .input: watchInput()
    case .dependencies: break
    case .semantic(let message):
      Logger(subsystem: "com.amirtlinov.notebook", category: "CloudSync")
        .error("Cloud source deferred: \(source.deviceID, privacy: .public)/\(source.generation, privacy: .public), \(message, privacy: .public)")
      await report(.init(enabled: true, message: message))
    }
  }

  private func runInbound(id: UUID, token: UUID, account: String) async {
    defer { finishInbound(id) }
    while inboundRequested {
      inboundRequested = false
      guard matches(token, account: account), !Task.isCancelled, !inboundPaused else { return }
      if afterSource == nil { sweepAgain = false; sweepProgressed = false }
      do {
        // One complete immutable blob per round. Its actual assembly is joined
        // before the temporary file is released, even when this epoch stops.
        if let blob = try await writer.submit({ try $0.nextCompleteCloudBlob(account: account) }) {
          guard matches(token, account: account), !Task.isCancelled else { return }
          let file = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-cloud-" + UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: file) }
          try await Task.detached(priority: .utility) { [store] in try store.assembleCloudBlob(blob, account: account, file: file) }.value
          guard matches(token, account: account), !Task.isCancelled else { return }
          try await Self.admitWrite(writer) { try $0.installCloudBlob(blob, account: account, file: file) }
          guard matches(token, account: account), !Task.isCancelled else { return }
          deferred = deferred.filter { if case .dependencies = $0.value { return false }; return true }
          overflowWake.remove(.dependencies)
          sweepAgain = true
          inboundRequested = true
        }
        let exclusions = Set(deferred.keys), cursor = afterSource
        let heads = try await writer.submit { try $0.cloudInbox(account: account, excluding: exclusions, afterSource: cursor) }
        guard matches(token, account: account), !Task.isCancelled else { return }
        if heads.isEmpty {
          if cursor != nil, sweepProgressed || sweepAgain {
            afterSource = nil; inboundRequested = true; continue
          }
          if inboundRequested || sweepAgain { continue }
          return
        }
        // Every nonempty batch advances the exact-source cursor. One final
        // empty read closes the sweep, including a partial rejected batch.
        inboundRequested = true
        for delivery in heads {
          guard matches(token, account: account), !Task.isCancelled else { return }
          afterSource = delivery.source
          do {
            if try await writer.submit({ try $0.deliveryNeedsContent(delivery) }) {
              guard matches(token, account: account), !Task.isCancelled else { return }
              let missing = try await Self.admitWrite(writer) { try $0.missingBlobHashes(for: delivery.change, limit: 1) }
              guard matches(token, account: account), !Task.isCancelled else { return }
              if !missing.isEmpty { await deferSource(delivery.source, reason: .dependencies); continue }
            }
            // One attempt. A revoked input observation cannot occupy this
            // actor or the independent outbound plan while its source waits.
            guard matches(token, account: account), !Task.isCancelled else { return }
            try await apply(delivery, account)
            guard matches(token, account: account), !Task.isCancelled else { return }
            deferred[delivery.source] = nil
            sweepProgressed = true
            inboundRequested = true; requestOutbound()
          } catch {
            guard matches(token, account: account), !Task.isCancelled else { return }
            guard let reason = Self.deferredReason(error) else { throw error }
            await deferSource(delivery.source, reason: reason)
          }
        }
        await Task.yield()
      } catch {
        guard matches(token, account: account), !Task.isCancelled else { return }
        inboundPaused = true
        await reportFailure(error)
        return
      }
    }
  }

  private func runOutbound(id: UUID, token: UUID, account: String) async {
    defer { finishOutbound(id) }
    while outboundRequested {
      outboundRequested = false
      guard matches(token, account: account), !Task.isCancelled, !outboundPaused else { return }
      do {
        var preparation = try await Self.admitWrite(writer) { try $0.pendingCloudUploadPlan(account: account) }
        guard matches(token, account: account), !Task.isCancelled else { return }
        if preparation == nil {
          let preparationTask = Task { [uploadReader, source] in
            try await uploadReader.prepare(account: account, source: source)
          }
          uploadPreparation = preparationTask
          let plan: NotebookCloudUploadPlan?
          do { plan = try await preparationTask.value }
          catch { uploadPreparation = nil; throw error }
          uploadPreparation = nil
          guard matches(token, account: account), !Task.isCancelled else {
            if let plan { try? await uploadReader.discard(plan.id) }
            return
          }
          if let plan {
            do {
              if try await Self.admitWrite(writer, { try $0.beginCloudUpload(plan, account: account) }) { preparation = plan.id }
              else { try? await uploadReader.discard(plan.id) }
            } catch {
              try? await uploadReader.discard(plan.id)
              throw error
            }
          }
        }
        if let preparation {
          while true {
            guard matches(token, account: account), !Task.isCancelled else { return }
            guard let batch = try await uploadReader.batch(preparation, account: account) else {
              try await uploadReader.discard(preparation); break
            }
            guard matches(token, account: account), !Task.isCancelled else { return }
            let complete = try await Self.admitWrite(writer) { try $0.installCloudUploadBatch(batch, account: account) }
            if complete { try await uploadReader.discard(preparation); break }
            await Task.yield()
          }
        }
        guard matches(token, account: account), !Task.isCancelled else { return }
        let pending = try await writer.submit { try $0.cloudOutbox(account: account) }
        guard matches(token, account: account), !Task.isCancelled else { return }
        let records = pending.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(.init(recordName: $0.id, zoneID: zoneID)) }
        if !records.isEmpty { engine?.state.add(pendingRecordZoneChanges: records) }
        if !hasFailure, !overflowWake.contains(.semantic), !deferred.values.contains(where: { if case .semantic = $0 { return true }; return false }) {
          let uploaded = try await writer.submit { try $0.cloudHasUploadedCurrentContent(account: account) }
          guard matches(token, account: account), !Task.isCancelled else { return }
          await report(.init(enabled: true, message: uploaded
            ? "Изменения отправлены в iCloud."
            : "Сохранено на устройстве. Ожидаем отправку в iCloud."))
        }
      } catch {
        guard matches(token, account: account), !Task.isCancelled else { return }
        outboundPaused = true
        await reportFailure(error)
        return
      }
    }
  }

  func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
    var options = context.options
    options.scope = .zoneIDs(Self.fetchZoneIDs(workspaceID: zoneID, contentEnabled: contentEnabled, requested: context.options.scope))
    options.prioritizedZoneIDs = [accountZoneID]
    return options
  }

  func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
    guard contentEnabled, syncEngine === engine, let account else { return nil }
    delegateCallbacks += 1
    defer { finishedDelegateCallback() }
    let token = epoch
    do {
      // A changed account may never receive the previously bound outbox, even
      // if an account event and a scheduled send arrive close together.
      let current = try await currentAccount(container())
      guard epoch == token else { return nil }
      guard current == account else { await accountChanged(); return nil }
      let pending = try await writer.submit { try $0.cloudOutbox(account: account) }
      var records: [CKRecord] = []
      for value in pending {
        let id = CKRecord.ID(recordName: value.id, zoneID: zoneID)
        guard context.options.scope.contains(id) else { continue }
        let record = CKRecord(recordType: value.delivery == nil ? "NotebookBlob" : "NotebookDelivery", recordID: id)
        record["format"] = 1 as NSNumber
        if let delivery = value.delivery {
          let data = try Self.encode(delivery)
          record["body"] = data as NSData
        } else if let hash = value.hash {
          let data = try await Task.detached(priority: .utility) { [store] in
            try store.readBlobChunk(hash: hash, offset: value.offset, maxBytes: max(1, value.byteCount))
          }.value
          guard epoch == token else { return nil }
          guard data.count == value.byteCount else { throw NotebookTransportError.invalidBlob }
          let file = assets[value.id] ?? FileManager.default.temporaryDirectory.appendingPathComponent("notebook-cloud-send-" + UUID().uuidString)
          if assets[value.id] == nil { try data.write(to: file, options: [.atomic]); assets[value.id] = file }
          record["hash"] = hash as NSString; record["offset"] = value.offset as NSNumber; record["total"] = value.totalBytes as NSNumber
          record["digest"] = Self.digest(data) as NSString
          record["asset"] = CKAsset(fileURL: file)
        }
        records.append(record)
      }
      guard epoch == token, !records.isEmpty else { return nil }
      return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: [], atomicByZone: false)
    } catch { if epoch == token { await reportFailure(error) }; return nil }
  }

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    guard syncEngine === engine, let account else { return }
    delegateCallbacks += 1
    defer { finishedDelegateCallback() }
    let token = epoch
    do {
      switch event {
      case .stateUpdate(let value):
        guard contentEnabled else { return }
        let data = try Self.encode(value.stateSerialization)
        try await writer.submit(writesStore: true) { try $0.saveCloudEngineState(data, account: account) }
      case .accountChange(let value):
        switch value.changeType {
        case .signIn(let user) where user.recordName == account: break
        default: await accountChanged()
        }
      case .fetchedDatabaseChanges(let value):
        if value.deletions.contains(where: { $0.zoneID == accountZoneID }) { notifyAccount(false) }
        guard contentEnabled else { return }
        if value.deletions.contains(where: { $0.zoneID == zoneID }) {
          throw CloudFailure("Облачная зона удалена. Обмен остановлен; локальные данные сохранены.")
        }
      case .fetchedRecordZoneChanges(let value):
        if value.modifications.contains(where: { $0.record.recordID.zoneID == accountZoneID })
          || value.deletions.contains(where: { $0.recordID.zoneID == accountZoneID }) { notifyAccount(false) }
        guard contentEnabled else { return }
        guard value.deletions.filter({ $0.recordID.zoneID == zoneID }).isEmpty else {
          throw CloudFailure("Удалены неизменяемые облачные записи. Обмен остановлен; локальные данные сохранены.")
        }
        for modification in value.modifications where modification.record.recordID.zoneID == zoneID {
          guard epoch == token, syncEngine === engine else { return }
          let (record, data) = try Self.decode(modification.record)
          if let delivery = record.delivery { try await writer.submit(writesStore: true) { [source] in try $0.stageCloudDelivery(delivery, account: account, localSource: source) } }
          else if let data { try await writer.submit(writesStore: true) { try $0.stageCloudChunk(record, data: data, account: account) } }
        }
        // Returning from this event is the fetch checkpoint boundary. Every
        // asset and envelope is durable before a later stateUpdate is saved.
        guard epoch == token, syncEngine === engine else { return }
        contentWasFetched()
      case .sentRecordZoneChanges(let value):
        guard contentEnabled else { return }
        var accepted = value.savedRecords.map { $0.recordID.recordName }
        for failed in value.failedRecordSaves {
          if failed.error.code == .serverRecordChanged, let server = failed.error.serverRecord {
            let a = try Self.descriptor(failed.record), b = try Self.descriptor(server)
            guard a == b, failed.record["digest"] as? String == server["digest"] as? String else { throw NotebookStorageError.transactionConflict }
            accepted.append(server.recordID.recordName)
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
          } else if failed.error.code == .zoneNotFound {
            throw CloudFailure("Синхронизация iCloud временно недоступна. Материалы сохранены на устройстве.")
          } else {
            // Scheduling/retries belong to CKSyncEngine. The durable outbox
            // remains intact for quota, offline, or interrupted requests.
            await reportFailure(failed.error)
          }
        }
        for ids in stride(from: 0, to: accepted.count, by: 16).map({ Array(accepted[$0..<min($0 + 16, accepted.count)]) }) {
          guard epoch == token, syncEngine === engine else { return }
          try await writer.submit(writesStore: true) { try $0.acknowledgeCloudRecords(ids, account: account) }
        }
        guard epoch == token, syncEngine === engine else { return }
        if value.failedRecordSaves.isEmpty, !accepted.isEmpty { hasFailure = false }
        for id in accepted { if let file = assets.removeValue(forKey: id) { try? FileManager.default.removeItem(at: file) } }
        requestOutbound()
      case .sentDatabaseChanges(let value):
        for failure in value.failedZoneSaves { await reportFailure(failure.error) }
      case .didFetchRecordZoneChanges(let value):
        if let error = value.error { await reportFailure(error) }
      default: break
      }
    } catch {
      // Never advance a fetch checkpoint after a failed durable stage. Drop
      // this engine; resume replays from its last persisted serialization.
      if epoch == token, syncEngine === engine { stopFromDelegate(); await reportFailure(error) }
    }
  }

  private func accountChanged() async {
    notifyAccount(true)
    let bound = account
    stopFromDelegate()
    let token = epoch
    do { try await writer.submit(writesStore: true) { try $0.disableCloud(account: bound) } }
    catch { await reportFailure(error) }
    guard epoch == token else { return }
    await report(.init(enabled: false, message: "iCloud недоступен или аккаунт изменился. Материалы сохранены на устройстве."))
  }

  private func reportFailure(_ error: Error) async {
    let token = epoch
    hasFailure = true
    let enabled = (try? await writer.submit { try $0.cloudConfiguration().enabled }) ?? false
    guard epoch == token else { return }
    let code = (error as? CKError)?.code
    Logger(subsystem: "com.amirtlinov.notebook", category: "CloudSync")
      .error("Cloud delivery failed: code \(code?.rawValue ?? -1), type \(String(reflecting: type(of: error)), privacy: .public)")
    let message: String
    if let failure = error as? CloudFailure { message = failure.message }
    else if let failure = error as? NotebookAccountError { message = failure.localizedDescription }
    else if code == .quotaExceeded { message = "В iCloud закончилось свободное место. Материалы сохранены на устройстве." }
    else if code == .notAuthenticated { message = "Войдите в iCloud в системных настройках. Материалы сохранены на устройстве." }
    else { message = "Синхронизация iCloud приостановлена. Материалы сохранены на устройстве." }
    await report(.init(enabled: enabled, message: message))
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
  }
  private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  static func descriptor(_ record: CKRecord) throws -> NotebookCloudRecord {
    guard record["format"] as? Int == 1 else { throw NotebookTransportError.unsupportedVersion }
    if record.recordType == "NotebookDelivery", let data = record["body"] as? Data, data.count <= 4096 {
      let delivery = try JSONDecoder().decode(NotebookReplicationDelivery.self, from: data)
      let value = try NotebookCloudRecord(delivery: delivery)
      guard value.id == record.recordID.recordName else { throw NotebookTransportError.invalidBlob }
      return value
    }
    guard record.recordType == "NotebookBlob", let hash = record["hash"] as? String,
      let offset = record["offset"] as? Int64, let total = record["total"] as? Int64,
      let digest = record["digest"] as? String, NotebookTransportFraming.isSHA256(digest) else { throw NotebookTransportError.invalidBlob }
    let value = try NotebookCloudRecord.chunk(hash: hash, offset: offset, totalBytes: total)
    guard value.id == record.recordID.recordName else { throw NotebookTransportError.invalidBlob }
    return value
  }

  static func decode(_ record: CKRecord) throws -> (NotebookCloudRecord, Data?) {
    let value = try descriptor(record)
    if value.delivery != nil { return (value, nil) }
    guard let asset = record["asset"] as? CKAsset, let file = asset.fileURL else { throw NotebookTransportError.invalidBlob }
    let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
    let data = try input.read(upToCount: NotebookCloudRecord.chunkBytes + 1) ?? Data()
    guard value.id == record.recordID.recordName, data.count == value.byteCount,
      record["digest"] as? String == digest(data) else { throw NotebookTransportError.invalidBlob }
    return (value, data)
  }

  private struct CloudFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

/// A cloud plan is an immutable read operation. It never owns the live writer,
/// and its temporary files have exactly the pending export's lifetime.
private actor NotebookCloudUploadReader {
  let store: NotebookStore
  init(store: NotebookStore) { self.store = store }
  func prepare(account: String, source: NotebookReplicationSource) throws -> NotebookCloudUploadPlan? {
    try store.prepareCloudUploadPlan(account: account, source: source)
  }
  func batch(_ id: UUID, account: String) throws -> NotebookCloudUploadBatch? {
    try store.prepareCloudUploadBatch(id, account: account)
  }
  func discard(_ id: UUID) throws { try store.discardCloudUploadSpool(id) }
}
