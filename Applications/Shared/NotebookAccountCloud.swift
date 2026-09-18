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
    retained: [NotebookAccountDirectory.Pair]) async throws -> NotebookAccountSnapshot
  func initialWorkspace(proposed: UUID) async throws -> UUID
  func observe(changed: @escaping @Sendable (Bool) async -> Void) async throws
  func stop() async
}

/// Small account metadata has one CAS owner. Device keys live in an encrypted
/// field in a private zone, never a public record, Bonjour or content journal.
/// A zone subscription wakes this owner; the content pipeline is the only
/// CKSyncEngine for the private database. No perpetual cloud polling.
actor NotebookAccountCloud: NotebookAccountService {
  static let zoneName = "NotebookAccount"
  static let recordName = "devices"
  private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
  private var observing = false
  private let observationID = UUID()
  private var generation = UUID()

  private func container() throws -> CKContainer {
    guard Bundle.main.object(forInfoDictionaryKey: "NotebookCloudContainer") as? String == NotebookCloudSync.containerIdentifier,
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      throw NotebookAccountError.notConfigured
    }
    return CKContainer(identifier: NotebookCloudSync.containerIdentifier)
  }

  private func account(_ container: CKContainer) async throws -> String {
    let status = try await container.accountStatus()
    switch status {
    case .available: return try await container.userRecordID().recordName
    case .temporarilyUnavailable: throw CKError(.serviceUnavailable)
    default: throw NotebookAccountError.unavailable
    }
  }

  func initialWorkspace(proposed: UUID) async throws -> UUID {
    let container = try container(), account = try await account(container)
    let value = try await update(container: container, expectedAccount: account, initialSpace: proposed) { _ in }
    return value.directory.defaultSpaceID
  }

  func exchange(device: NotebookAccountDirectory.Device, boundAccount: String?,
    retained: [NotebookAccountDirectory.Pair]) async throws -> NotebookAccountSnapshot {
    let container = try container(), account = try await account(container)
    guard boundAccount == nil || boundAccount == account else { throw NotebookAccountError.changed }
    return try await update(container: container, expectedAccount: account, initialSpace: device.identity.workspaceID) {
      try $0.enroll(device, retained: retained, spaceName: "Пространство · " + device.identity.displayName)
    }
  }

  private func update(container: CKContainer, expectedAccount: String, initialSpace: UUID,
    edit: (inout NotebookAccountDirectory) throws -> Void) async throws -> NotebookAccountSnapshot {
    let token = generation, database = container.privateCloudDatabase
    let recordID = CKRecord.ID(recordName: Self.recordName, zoneID: zoneID)
    _ = try await database.save(CKRecordZone(zoneID: zoneID))
    // Bounded CAS retries resolve simultaneous first launches. Never overwrite
    // the winner with a locally generated key or lose another device's entry.
    for _ in 0..<8 {
      try Task.checkCancellation()
      guard generation == token, try await account(container) == expectedAccount else { throw NotebookAccountError.changed }
      var record: CKRecord
      let original: NotebookAccountDirectory?
      do {
        record = try await database.record(for: recordID)
        original = try Self.decode(record)
      } catch let error as CKError where error.code == .unknownItem {
        record = CKRecord(recordType: "NotebookDevices", recordID: recordID)
        original = nil
      }
      var directory = original ?? .init(space: .init(id: initialSpace, name: "Моё пространство"))
      try edit(&directory); try directory.validate()
      guard generation == token, try await account(container) == expectedAccount else { throw NotebookAccountError.changed }
      if directory != original {
        let data = try JSONEncoder().encode(directory)
        guard data.count <= 262_144 else { throw NotebookTransportError.resourceLimit }
        record["format"] = 1 as NSNumber
        record.encryptedValues["directory"] = data as NSData
        do {
          let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
          guard let saved = result.saveResults[recordID] else { throw NotebookAccountError.invalidDirectory }
          _ = try saved.get()
        } catch let error as CKError where error.code == .serverRecordChanged { continue }
      }
      guard generation == token, try await account(container) == expectedAccount else { throw NotebookAccountError.changed }
      return .init(account: expectedAccount, directory: directory)
    }
    throw CKError(.serverRecordChanged)
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
    guard !observing else { return }
    let token = generation, container = try container()
    let expectedAccount = try await account(container)
    let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: NotebookAccountPush.subscriptionID)
    let info = CKSubscription.NotificationInfo()
    info.shouldSendContentAvailable = true
    subscription.notificationInfo = info
    _ = try await container.privateCloudDatabase.save(subscription)
    guard generation == token, try await account(container) == expectedAccount else { throw NotebookAccountError.changed }
    await NotebookAccountPush.install(id: observationID, changed: changed)
    guard generation == token else {
      await NotebookAccountPush.remove(id: observationID)
      throw NotebookAccountError.changed
    }
    observing = true
    // Close the enrollment-to-subscription gap, without waiting on the account
    // work that is currently installing this observer.
    Task { await changed(false) }
  }

  func stop() async {
    generation = UUID(); observing = false
    await NotebookAccountPush.remove(id: observationID)
  }
}

/// App delegates deliver a wake-up, never credentials or content. A single
/// handler belongs to the currently admitted account owner. Background fetch
/// waits for that owner's work instead of completing before the cloud read.
@MainActor
enum NotebookAccountPush {
  nonisolated static let subscriptionID = "Notebook.AccountDevices"
  private static var observer: (id: UUID, changed: @Sendable (Bool) async -> Void)?

  static func install(id: UUID, changed: @escaping @Sendable (Bool) async -> Void) {
    observer = (id, changed)
  }
  static func remove(id: UUID) {
    if observer?.id == id { observer = nil }
  }
  static func matches(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard let value = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKRecordZoneNotification else { return false }
    return accepts(container: value.containerIdentifier, subscription: value.subscriptionID,
      zone: value.recordZoneID?.zoneName, database: value.databaseScope)
  }
  static func accepts(container: String?, subscription: String?, zone: String?, database: CKDatabase.Scope) -> Bool {
    // CloudKit can prune optional payload fields. This only requests a fresh
    // authenticated read, and cannot enroll a device from push payload data.
    subscription == subscriptionID && database == .private
      && (container == nil || container == NotebookCloudSync.containerIdentifier)
      && (zone == nil || zone == NotebookAccountCloud.zoneName)
  }
  static func refresh() async { await observer?.changed(false) }
}
