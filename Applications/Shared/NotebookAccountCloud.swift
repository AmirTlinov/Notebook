import CloudKit
import Foundation
import NotebookCore

enum NotebookAccountError: Error, Equatable, LocalizedError {
  case unavailable, changed, notConfigured, invalidDirectory
  var errorDescription: String? {
    switch self {
    case .unavailable: "Войдите в iCloud в системных настройках. Сохранение на этом устройстве работает."
    case .changed: "Это пространство связано с другим Apple Account. Его материалы остались на устройстве и не отправлены новому аккаунту."
    case .notConfigured: "В этой сборке автоматическое подключение через iCloud недоступно."
    case .invalidDirectory: "Не удалось проверить свои устройства в iCloud. Сохранённые материалы и ключи не изменены."
    }
  }
}

struct NotebookAccountSnapshot: Sendable {
  let account: String
  let directory: NotebookAccountDirectory
}

protocol NotebookAccountService: Sendable {
  func exchange(device: NotebookAccountDirectory.Device, boundAccount: String?,
    retained: [NotebookAccountDirectory.Pair], spaceName: String, publishName: Bool) async throws -> NotebookAccountSnapshot
  func initialWorkspace(proposed: UUID) async throws -> UUID
  func spaces(boundAccount: String?) async throws -> NotebookAccountSnapshot?
  func observe(changed: @escaping @Sendable (Bool) async -> Void) async throws
  func stop() async
}

/// Small account metadata has one CAS owner. Device keys live in an encrypted
/// field in a private zone, never a public record, Bonjour or content journal.
/// Account and content notifications share one private-database CKSyncEngine.
/// This owner only changes the bounded directory through its CAS transaction.
actor NotebookAccountCloud: NotebookAccountService {
  static let zoneName = "NotebookAccount"
  static let recordName = "devices"
  private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
  private let cloud: NotebookCloudSync?
  init(cloud: NotebookCloudSync? = nil) { self.cloud = cloud }
  private var generation = UUID()

  private func container() throws -> CKContainer {
    guard Bundle.main.object(forInfoDictionaryKey: "NotebookCloudContainer") as? String == NotebookCloudSync.containerIdentifier,
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      throw NotebookAccountError.notConfigured
    }
    return CKContainer(identifier: NotebookCloudSync.containerIdentifier)
  }

  private func requireCurrent(_ token: UUID) throws {
    try Task.checkCancellation()
    guard generation == token else { throw NotebookAccountError.changed }
  }

  private func account(_ container: CKContainer, token: UUID) async throws -> String {
    try requireCurrent(token)
    let status = try await container.accountStatus()
    try requireCurrent(token)
    switch status {
    case .available:
      let record = try await container.userRecordID()
      try requireCurrent(token)
      return record.recordName
    case .temporarilyUnavailable: throw CKError(.serviceUnavailable)
    default: throw NotebookAccountError.unavailable
    }
  }

  func initialWorkspace(proposed: UUID) async throws -> UUID {
    let token = generation, container = try container(), account = try await account(container, token: token)
    try requireCurrent(token)
    let value = try await update(container: container, expectedAccount: account, token: token, initialSpace: proposed) { _ in }
    try requireCurrent(token)
    return value.directory.defaultSpaceID ?? proposed
  }

  func exchange(device: NotebookAccountDirectory.Device, boundAccount: String?,
    retained: [NotebookAccountDirectory.Pair], spaceName: String, publishName: Bool) async throws -> NotebookAccountSnapshot {
    let token = generation, container = try container(), account = try await account(container, token: token)
    try requireCurrent(token)
    guard boundAccount == nil || boundAccount == account else { throw NotebookAccountError.changed }
    let snapshot = try await update(container: container, expectedAccount: account, token: token, initialSpace: device.identity.workspaceID, initialName: spaceName) {
      try $0.enroll(device, retained: retained, spaceName: spaceName)
      if publishName { try $0.renameSpace(device.identity.workspaceID, name: spaceName) }
    }
    try requireCurrent(token)
    return snapshot
  }

  private func update(container: CKContainer, expectedAccount: String, token: UUID, initialSpace: UUID, initialName: String = "Моё пространство",
    edit: (inout NotebookAccountDirectory) throws -> Void) async throws -> NotebookAccountSnapshot {
    try requireCurrent(token)
    let database = container.privateCloudDatabase
    let recordID = CKRecord.ID(recordName: Self.recordName, zoneID: zoneID)
    guard try await account(container, token: token) == expectedAccount else { throw NotebookAccountError.changed }
    try requireCurrent(token)
    _ = try await database.save(CKRecordZone(zoneID: zoneID))
    try requireCurrent(token)
    // Bounded CAS retries resolve simultaneous first launches. Never overwrite
    // the winner with a locally generated key or lose another device's entry.
    for _ in 0..<8 {
      try requireCurrent(token)
      guard try await account(container, token: token) == expectedAccount else { throw NotebookAccountError.changed }
      try requireCurrent(token)
      var record: CKRecord
      let original: NotebookAccountDirectory?
      do {
        record = try await database.record(for: recordID)
        try requireCurrent(token)
        original = try Self.decode(record)
      } catch let error as CKError where error.code == .unknownItem {
        try requireCurrent(token)
        record = CKRecord(recordType: "NotebookDevices", recordID: recordID)
        original = nil
      }
      var directory = original ?? .init(space: .init(id: initialSpace, name: initialName))
      try edit(&directory); try directory.validate()
      guard try await account(container, token: token) == expectedAccount else { throw NotebookAccountError.changed }
      try requireCurrent(token)
      if directory != original {
        let data = try JSONEncoder().encode(directory)
        guard data.count <= 262_144 else { throw NotebookTransportError.resourceLimit }
        record["format"] = 1 as NSNumber
        record.encryptedValues["directory"] = data as NSData
        do {
          let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
          try requireCurrent(token)
          guard let saved = result.saveResults[recordID] else { throw NotebookAccountError.invalidDirectory }
          _ = try saved.get()
        } catch let error as CKError where error.code == .serverRecordChanged {
          try requireCurrent(token)
          continue
        }
      }
      guard try await account(container, token: token) == expectedAccount else { throw NotebookAccountError.changed }
      try requireCurrent(token)
      return .init(account: expectedAccount, directory: directory)
    }
    throw CKError(.serverRecordChanged)
  }

  /// Catalog commands use the same account/CAS authority, not another engine.
  func spaces(boundAccount: String?) async throws -> NotebookAccountSnapshot? {
    let token = generation, container = try container(), current = try await account(container, token: token)
    try requireCurrent(token)
    guard boundAccount == nil || boundAccount == current else { throw NotebookAccountError.changed }
    do {
      let record = try await container.privateCloudDatabase.record(for: .init(recordName: Self.recordName, zoneID: zoneID))
      try requireCurrent(token)
      guard try await account(container, token: token) == current else { throw NotebookAccountError.changed }
      try requireCurrent(token)
      return try .init(account: current, directory: Self.decode(record))
    } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
      try requireCurrent(token)
      return nil
    }
  }

  func renameSpace(_ id: UUID, name: String, account expected: String) async throws {
    let token = generation, container = try container()
    try requireCurrent(token)
    _ = try await update(container: container, expectedAccount: expected, token: token, initialSpace: id) {
      try $0.renameSpace(id, name: name)
    }
    try requireCurrent(token)
  }

  func deleteSpace(_ id: UUID, account expected: String) async throws {
    let token = generation, container = try container()
    try requireCurrent(token)
    _ = try await update(container: container, expectedAccount: expected, token: token, initialSpace: id) { try $0.deleteSpace(id) }
    try requireCurrent(token)
    // Tombstone commits before erasure. Offline copies cannot recreate the zone
    // by enrolling; a failed zone removal is retryable with that same intent.
    guard try await account(container, token: token) == expected else { throw NotebookAccountError.changed }
    try requireCurrent(token)
    do {
      _ = try await container.privateCloudDatabase.deleteRecordZone(withID:
        .init(zoneName: "Notebook-" + id.uuidString.lowercased(), ownerName: CKCurrentUserDefaultName))
      try requireCurrent(token)
    } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
      try requireCurrent(token)
    }
  }

  static func decode(_ record: CKRecord) throws -> NotebookAccountDirectory {
    guard record.recordType == "NotebookDevices", record.recordID.recordName == recordName,
      record.recordID.zoneID.zoneName == zoneName, record["format"] as? Int == 1,
      let data = record.encryptedValues["directory"] as? Data, data.count <= 262_144 else {
      throw NotebookAccountError.invalidDirectory
    }
    let directory = try JSONDecoder().decode(NotebookAccountDirectory.self, from: data)
    try directory.validate()
    return directory
  }

  func observe(changed: @escaping @Sendable (Bool) async -> Void) async throws {
    let token = generation, container = try container()
    let expected = try await account(container, token: token)
    try requireCurrent(token)
    guard let cloud else { throw NotebookAccountError.notConfigured }
    try await cloud.observeAccount(expected, changed: changed)
    try requireCurrent(token)
  }
  func stop() async {
    generation = UUID()
    await cloud?.stop()
  }
}
