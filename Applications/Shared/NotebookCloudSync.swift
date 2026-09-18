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
  private let source: NotebookReplicationSource
  private let zoneID: CKRecordZone.ID
  private let apply: @Sendable (NotebookReplicationDelivery, String) async throws -> Void
  private let report: @Sendable (NotebookCloudStatus) async -> Void
  private var engine: CKSyncEngine?
  private var account: String?
  private var contentEnabled = false
  private var accountObserver: (account: String, changed: @Sendable (Bool) async -> Void)?
  private let accountZoneID = CKRecordZone.ID(zoneName: NotebookAccountCloud.zoneName, ownerName: CKCurrentUserDefaultName)
  private var assets: [String: URL] = [:]
  private var pumping = false
  private var pumpAgain = false
  private var epoch = UUID()
  private var hasFailure = false
  private var resuming = false
  private var resumeRetry: Task<Void, Never>?

  init(store: NotebookStore, writer: NotebookPersistenceQueue, source: NotebookReplicationSource, workspaceID: UUID,
    apply: @escaping @Sendable (NotebookReplicationDelivery, String) async throws -> Void,
    report: @escaping @Sendable (NotebookCloudStatus) async -> Void) {
    self.store = store; self.writer = writer; self.source = source
    zoneID = .init(zoneName: "Notebook-" + workspaceID.uuidString.lowercased(), ownerName: CKCurrentUserDefaultName)
    self.apply = apply; self.report = report
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
    do {
      let configuration = try await writer.submit { try $0.cloudConfiguration() }
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
    let token = await stopEngine()
    guard epoch == token else { return }
    do {
      let container = try container(), current = try await currentAccount(container)
      guard epoch == token else { return }
      guard current == expected else { throw NotebookAccountError.changed }
      try await writer.submit { [source] store in
        let bound = try store.cloudConfiguration().account
        guard bound == nil || bound == expected else { throw NotebookAccountError.changed }
        try store.enableCloud(account: current, source: source)
      }
      try await start(container: container, account: current, token: token)
    } catch { if epoch == token { await reportFailure(error) } }
  }

  func resume() async {
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
        try await writer.submit { try $0.disableCloud(account: bound) }
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
    await pump()
  }

  func disable() async {
    let token = await stopEngine()
    guard epoch == token else { return }
    do {
      try await writer.submit { try $0.disableCloud() }
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
    epoch = UUID(); let previous = engine; engine = nil; account = nil; contentEnabled = false
    return previous
  }

  func stop() async { accountObserver = nil; _ = await stopEngine() }

  private func stopEngine() async -> UUID {
    let previous = invalidate(), files = Array(assets.values); assets.removeAll()
    let token = epoch
    await previous?.cancelOperations()
    for file in files { try? FileManager.default.removeItem(at: file) }
    return token
  }

  private func stopFromDelegate() {
    let previous = invalidate(), files = Array(assets.values); assets.removeAll()
    // A delegate must return before waiting for its own operation to cancel.
    Task {
      await previous?.cancelOperations()
      for file in files { try? FileManager.default.removeItem(at: file) }
    }
  }

  func notifyLocalChanges() async {
    if engine == nil { await resume() }
    await pump()
  }

  private func pump() async {
    pumpAgain = true
    guard !pumping else { return }; pumping = true
    defer { pumping = false }
    while pumpAgain {
      pumpAgain = false
      guard contentEnabled, let engine, let account else { return }
      let token = epoch
      do {
        // Asset reconstruction and reads never occupy the application's writer.
        while let blob = try await writer.submit({ try $0.nextCompleteCloudBlob(account: account) }) {
          let file = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-cloud-" + UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: file) }
          try await Task.detached(priority: .utility) { [store] in try store.assembleCloudBlob(blob, account: account, file: file) }.value
          guard epoch == token else { return }
          try await writer.submit { try $0.installCloudBlob(blob, account: account, file: file) }
        }
        var progressed = true
        while progressed {
          progressed = false
          let deliveries = try await writer.submit { try $0.cloudInbox(account: account) }
          for delivery in deliveries {
            guard epoch == token else { return }
            if try await writer.submit({ try $0.deliveryNeedsContent(delivery) }) {
              let missing = try await writer.submit { try $0.missingBlobHashes(for: delivery.change, limit: 1) }
              if !missing.isEmpty { continue }
            }
            try await apply(delivery, account); progressed = true
          }
        }
        guard epoch == token else { return }
        try await writer.submit { [source] in try $0.prepareCloudUpload(account: account, source: source) }
        let pending = try await writer.submit { try $0.cloudOutbox(account: account) }
        guard epoch == token else { return }
        let records = pending.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(.init(recordName: $0.id, zoneID: zoneID)) }
        if !records.isEmpty { engine.state.add(pendingRecordZoneChanges: records) }
        if !hasFailure {
          let uploaded = try await writer.submit { try $0.cloudHasUploadedCurrentContent(account: account) }
          guard epoch == token else { return }
          await report(.init(enabled: true, message: uploaded
            ? "Изменения отправлены в iCloud."
            : "Сохранено на устройстве. Ожидаем отправку в iCloud."))
        }
      } catch { await reportFailure(error); return }
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
    do {
      switch event {
      case .stateUpdate(let value):
        guard contentEnabled else { return }
        let data = try Self.encode(value.stateSerialization)
        try await writer.submit { try $0.saveCloudEngineState(data, account: account) }
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
          guard syncEngine === engine else { return }
          let (record, data) = try Self.decode(modification.record)
          if let delivery = record.delivery { try await writer.submit { [source] in try $0.stageCloudDelivery(delivery, account: account, localSource: source) } }
          else if let data { try await writer.submit { try $0.stageCloudChunk(record, data: data, account: account) } }
        }
        // Returning from this event is the fetch checkpoint boundary. Every
        // asset and envelope is durable before a later stateUpdate is saved.
        await pump()
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
          try await writer.submit { try $0.acknowledgeCloudRecords(ids, account: account) }
        }
        if value.failedRecordSaves.isEmpty, !accepted.isEmpty { hasFailure = false }
        for id in accepted { if let file = assets.removeValue(forKey: id) { try? FileManager.default.removeItem(at: file) } }
        await pump()
      case .sentDatabaseChanges(let value):
        for failure in value.failedZoneSaves { await reportFailure(failure.error) }
      case .didFetchRecordZoneChanges(let value):
        if let error = value.error { await reportFailure(error) }
      default: break
      }
    } catch {
      // Never advance a fetch checkpoint after a failed durable stage. Drop
      // this engine; resume replays from its last persisted serialization.
      if syncEngine === engine { stopFromDelegate(); await reportFailure(error) }
    }
  }

  private func accountChanged() async {
    notifyAccount(true)
    let bound = account
    stopFromDelegate()
    let token = epoch
    do { try await writer.submit { try $0.disableCloud(account: bound) } }
    catch { await reportFailure(error) }
    guard epoch == token else { return }
    await report(.init(enabled: false, message: "iCloud недоступен или аккаунт изменился. Материалы сохранены на устройстве."))
  }

  private func reportFailure(_ error: Error) async {
    hasFailure = true
    let enabled = (try? await writer.submit { try $0.cloudConfiguration().enabled }) ?? false
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
