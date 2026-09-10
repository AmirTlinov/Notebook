import Foundation

/// A cursor names a completed SQL commit, not a file modification time.
public struct NotebookDurableChange: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let transactionID: UUID
  public let manifestHash: String
  public let byteCount: Int
  public init(sequence: UInt64, transactionID: UUID, manifestHash: String, byteCount: Int) {
    self.sequence = sequence; self.transactionID = transactionID
    self.manifestHash = manifestHash; self.byteCount = byteCount
  }
}

public struct NotebookRecordMutation: Codable, Equatable, Sendable {
  public let address: String
  public let blobHash: String?
  public init(address: String, blobHash: String?) { self.address = address; self.blobHash = blobHash }
}

public struct NotebookChangeManifest: Codable, Equatable, Sendable {
  public let format: Int
  public let transactionID: UUID
  public let workspaceID: UUID
  public let records: [NotebookRecordMutation]
  public let parts: [String]
  public let pageOrderRoots: [String]
  public init(transactionID: UUID, workspaceID: UUID, records: [NotebookRecordMutation], parts: [String] = [], pageOrderRoots: [String] = []) {
    format = 2; self.transactionID = transactionID; self.workspaceID = workspaceID
    self.records = records; self.parts = parts; self.pageOrderRoots = pageOrderRoots
  }
}

public enum NotebookPeerCursorDirection: String, Codable, Sendable { case incoming, outgoing }

public struct NotebookWorkspaceHeader: Codable, Sendable, Equatable {
  public let workspaceID: UUID
  public let rootBoardID: UUID
  public let stamp: VersionStamp
  public let itemCount: Int
  public let selectedItemID: UUID?
  public let selectedPageID: UUID?
  public let boardRevision: String?
  public let boardStamp: VersionStamp?
  public let spatialInkStamp: VersionStamp?
  public let cursor: UInt64
}

/// The disk returns only the requested physical owners. Missing members are
/// absence from this projection, never implicit deletion commands.
public struct NotebookWorkingSet: Codable, Sendable {
  public let header: NotebookWorkspaceHeader
  public let items: [NotebookItemHeader]
  public let boards: [BoardNode]
  public let pages: [UUID: PageDocument]
  public let documents: [UUID: DocumentDocument]
  public let states: [UUID: DocumentStateJournal]
  public let ink: SpatialInkJournal
}

public struct NotebookSceneWindow: Codable, Sendable {
  public let header: NotebookWorkspaceHeader
  public let boardID: UUID
  public let items: [WorkspaceItem]
  public let boards: [BoardNode]
  public let documentPaper: [UUID: DocumentPaperSize]
  public let pageCounts: [UUID: Int]
  public let referenceIdentities: [NotebookReferenceIdentity]
  public let totalMatches: Int
  public let truncated: Bool
}

public struct NotebookScenePaintCursor: Codable, Equatable, Sendable {
  public let revision: UInt64
  public let boardID: UUID
  public let boundsHash: String
  public let layer: Int
  public let zIndex: Double
  public let address: String
}

public struct NotebookScenePaintPosition: Codable, Equatable, Sendable, Comparable {
  public let layer: Int
  public let zIndex: Double
  public let key: String
  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
    if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
    return lhs.key < rhs.key
  }
}

public struct NotebookScenePaintPage: Codable, Sendable {
  public let revision: UInt64
  public let entries: [WorkspaceSpatialEntry]
  public let positions: [NotebookScenePaintPosition]
  public let next: NotebookScenePaintCursor?
}

public enum NotebookStorageError: Error, LocalizedError, Equatable, Sendable {
  case legacyStoreRequiresConversion
  case unsupportedFormat
  case corruptRecord(String)
  case invalidTransaction(String)
  case transactionConflict
  case readOnlyTransaction
  case limitExceeded(String)
  case blobMissing(String)
  case blobHashMismatch

  public var errorDescription: String? {
    switch self {
    case .legacyStoreRequiresConversion:
      "Хранилище использует прежний формат. Требуется внешний перенос данных (legacy_store)."
    case .unsupportedFormat:
      "Формат хранилища не поддерживается этой версией Notebook (unsupported_format)."
    case .corruptRecord(let address):
      "Запись хранилища повреждена или не содержит обязательных данных (corrupt_record): \(address.prefix(200))."
    case .invalidTransaction(let reason):
      "Изменение не соответствует правилам хранилища (invalid_transaction): \(reason.prefix(200))."
    case .transactionConflict:
      "Исходная версия изменилась. Команда требует согласования перед сохранением (transaction_conflict)."
    case .readOnlyTransaction:
      "Изменение нельзя сохранить внутри операции чтения (read_only_transaction)."
    case .limitExceeded(let limit):
      "Операция превышает ограничение хранилища (limit_exceeded): \(limit.prefix(200))."
    case .blobMissing(let hash):
      "Не получена необходимая часть содержания (blob_missing): \(hash.prefix(64))."
    case .blobHashMismatch:
      "Полученное содержание не совпадает с его контрольной суммой (blob_hash_mismatch)."
    }
  }
}

/// Faults are injected only by isolated Core tests; production has no hook.
enum NotebookStorageFault: Sendable { case afterRecordWrites, beforeCommit, afterCommit }

extension WorkspaceSpatialEntry: Codable {
  private enum CodingKeys: String, CodingKey { case kind, id, origin, maximum, zIndex }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch id {
    case .item(let id): try values.encode("item", forKey: .kind); try values.encode(id.uuidString.lowercased(), forKey: .id)
    case .element(let id): try values.encode("element", forKey: .kind); try values.encode(id, forKey: .id)
    }
    try values.encode(bounds.origin, forKey: .origin); try values.encode(bounds.maximum, forKey: .maximum)
    try values.encode(zIndex, forKey: .zIndex)
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try values.decode(String.self, forKey: .kind), id = try values.decode(String.self, forKey: .id)
    let identity: WorkspaceSpatialID
    if kind == "item", let uuid = UUID(uuidString: id) { identity = .item(uuid) }
    else if kind == "element" { identity = .element(id) }
    else { throw NotebookStorageError.invalidTransaction("spatial identity") }
    let origin = try values.decode(WorldPoint.self, forKey: .origin), maximum = try values.decode(WorldPoint.self, forKey: .maximum)
    guard origin.isValid, maximum.isValid,
      (origin.tileX < maximum.tileX || (origin.tileX == maximum.tileX && origin.localX <= maximum.localX)),
      (origin.tileY < maximum.tileY || (origin.tileY == maximum.tileY && origin.localY <= maximum.localY)) else {
      throw NotebookStorageError.invalidTransaction("spatial bounds")
    }
    self.init(id: identity, bounds: .init(origin: origin, maximum: maximum), zIndex: try values.decode(Double.self, forKey: .zIndex))
  }
}

public struct NotebookItemHeader: Codable, Sendable, Equatable {
  public let id: UUID
  public let kind: WorkspaceItemKind
  public let title: String
  public let firstPageID: UUID?
  public let pageCount: Int
}

extension NotebookItemHeader {
  public var item: WorkspaceItem {
    .init(id: id, kind: kind, title: title, pageIDs: firstPageID.map { [$0] } ?? [])
  }
}

public struct NotebookChangedRecord: Codable, Equatable, Sendable {
  public let address: String
  public let beforeHash: String?
  public let afterHash: String?
}

public struct NotebookChangedAddresses: Codable, Sendable {
  public let records: [NotebookChangedRecord]
  public var addresses: [String] { records.map(\.address) }
  public let hasMore: Bool
}
