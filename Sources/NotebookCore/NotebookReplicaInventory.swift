import CSQLite
import CryptoKit
import Foundation

/// A metadata observation of one borrowed read snapshot, never format-transition
/// authority or evidence that another replica accepted this replica's prefix.
public struct NotebookReplicaInventoryCut: Codable, Equatable, Sendable {
  public enum GenerationStatus: String, Codable, Sendable { case stored, missing, invalid }
  public struct DeliveryFloors: Codable, Equatable, Sendable {
    public let placement: UInt64?
    public let ink: UInt64?
    public let document: UInt64?
  }
  public struct ControlObservation: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable { case reusedReaderConnection }
    /// SQLite data_version is comparable only on the SAME reused connection.
    /// A native anchor must separately bind that connection's lifetime.
    public let scope: Scope
    public let sqliteDataVersion: Int64
    /// Complete fixed scalar fields, excluding the ephemeral snapshot UUID.
    /// Historical endpoint/cloud rows have their own bounded page witnesses.
    public let fixedScalarHash: String
  }
  public let workspaceID: UUID
  public let borrowedSnapshotID: UUID
  public let readRevision: UInt64
  public let databaseVersion: Int
  public let wireVersion: Int
  public let manifestVersion: Int
  public let journalGenerationStatus: GenerationStatus
  public let journalGeneration: UUID?
  /// Last accepted local journal position, including relayed transactions.
  /// nil means an empty journal; first-received-only occurrences are separate.
  public let acceptedLocalPrefix: NotebookDurableChange?
  public let deliveryFloors: DeliveryFloors
  public let cloud: NotebookReplicaCloudBinding
  public let controlObservation: ControlObservation
}

/// Every historical reason for an endpoint is retained. A received route names
/// the first retained delivery, not the original action's author or peer head.
public enum NotebookReplicaEndpointObservation: Codable, Equatable, Sendable {
  case incoming(source: NotebookReplicationSource, acceptedThrough: UInt64)
  case outgoing(deviceID: UUID, acknowledgedThrough: UInt64)
  case firstReceived(transactionID: UUID, source: NotebookReplicationSource, senderSequence: UInt64, manifestHash: String)
  case admittedGeneration(deviceID: UUID, generation: UUID)
  case snapshotCoverage(source: NotebookReplicationSource, coveredThrough: UInt64)
  case retirement(NotebookPeerRetirement)
}

public struct NotebookReplicaInventoryCursor: Codable, Equatable, Sendable {
  public enum Section: String, Codable, Sendable { case endpoints, cloudAccounts, cloudPending, cloudReceipts }
  public let workspaceID: UUID
  public let borrowedSnapshotID: UUID
  public let section: Section
  // Internal positions cannot revive a cursor in another SQL snapshot.
  let kind: Int
  let key: String
  let subkey: String
  let offset: Int64
  public var position: NotebookReplicaInventoryPosition {
    .init(workspaceID: workspaceID, section: section, kind: kind, key: key, subkey: subkey, offset: offset)
  }
}

/// A semantic key seek, without a SQL snapshot or transition authority. Native
/// resumption additionally binds the reused reader lifetime and sealed phase.
public struct NotebookReplicaInventoryPosition: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let section: NotebookReplicaInventoryCursor.Section
  let kind: Int
  let key: String
  let subkey: String
  let offset: Int64
}

public struct NotebookReplicaEndpointPage: Codable, Equatable, Sendable {
  public let cut: NotebookReplicaInventoryCut
  public let entries: [NotebookReplicaEndpointObservation]
  public let next: NotebookReplicaInventoryCursor?
  /// Completeness requires preceding pages in this cut or a native anchor whose
  /// reader lifetime, sealed phase and unchanged control fence were verified.
  public let complete: Bool
  public let scalarWitnessHash: String
}

enum NotebookReplicaInventory {
  private struct FixedScalars: Codable {
    let workspaceID: UUID
    let readRevision: UInt64
    let databaseVersion: Int
    let wireVersion: Int
    let manifestVersion: Int
    let journalGenerationStatus: NotebookReplicaInventoryCut.GenerationStatus
    let journalGeneration: UUID?
    let acceptedLocalPrefix: NotebookDurableChange?
    let deliveryFloors: NotebookReplicaInventoryCut.DeliveryFloors
    let cloud: NotebookReplicaCloudBinding
  }

  static func cut(in database: NotebookSQLConnection) throws -> NotebookReplicaInventoryCut {
    let snapshotID = try borrowedSnapshot(in: database)
    guard try database.rows("PRAGMA application_id").first?[0].integer == 1_313_999_665,
      let version = try database.rows("PRAGMA user_version").first?[0].integer,
      version == Int64(NotebookStore.currentDatabaseVersion) else {
      throw NotebookStorageError.unsupportedFormat
    }
    let rows = try database.rows("""
      SELECT key, CASE WHEN typeof(value)='text' AND length(CAST(value AS BLOB))<=36
        THEN value END FROM metadata WHERE key IN
        ('workspace_id','read_revision','journal_generation','placement_outgoing_floor',
         'ink_outgoing_floor','document_outgoing_floor') ORDER BY key
      """)
    var metadata: [String: String] = [:], present = Set<String>()
    for row in rows {
      guard let key = row[0].text, present.insert(key).inserted else { throw corrupt("metadata key") }
      if let value = row[1].text { metadata[key] = value }
    }
    let workspaceID = try uuid(metadata["workspace_id"], field: "workspace_id")
    let revision = try decimal(metadata["read_revision"], field: "read_revision")
    let generation: UUID?
    let generationStatus: NotebookReplicaInventoryCut.GenerationStatus
    if !present.contains("journal_generation") { generation = nil; generationStatus = .missing }
    else if let value = metadata["journal_generation"], let parsed = UUID(uuidString: value),
      value == parsed.uuidString.lowercased() { generation = parsed; generationStatus = .stored }
    else { generation = nil; generationStatus = .invalid }

    let head = try database.rows("""
      SELECT CASE WHEN typeof(sequence)='integer' AND sequence>0 THEN sequence END,
        CASE WHEN typeof(transaction_id)='text' AND length(CAST(transaction_id AS BLOB))=36
          THEN transaction_id END,
        CASE WHEN typeof(manifest_hash)='text' AND length(CAST(manifest_hash AS BLOB))=64
          THEN manifest_hash END,
        CASE WHEN typeof(byte_count)='integer' AND byte_count BETWEEN 1 AND 67108864
          THEN byte_count END
      FROM change_log ORDER BY sequence DESC LIMIT 1
      """).first
    let prefix: NotebookDurableChange?
    if let head {
      prefix = try .init(sequence: unsigned(head[0], positive: true, field: "journal sequence"),
        transactionID: uuid(head[1].text, field: "journal transaction"),
        manifestHash: hash(head[2].text, field: "journal manifest"),
        byteCount: Int(unsigned(head[3], positive: true, field: "journal bytes")))
    } else { prefix = nil }
    func floor(_ key: String) throws -> UInt64? {
      guard present.contains(key) else { return nil }
      let value = try decimal(metadata[key], field: key)
      guard value <= (prefix?.sequence ?? 0) else { throw corrupt(key) }
      return value
    }
    let floors = try NotebookReplicaInventoryCut.DeliveryFloors(placement: floor("placement_outgoing_floor"),
      ink: floor("ink_outgoing_floor"), document: floor("document_outgoing_floor"))
    let cloud = try NotebookReplicaCloudInventory.binding(in: database)
    let scalars = FixedScalars(workspaceID: workspaceID, readRevision: revision,
      databaseVersion: Int(version), wireVersion: NotebookTransportLimits.protocolVersion,
      manifestVersion: NotebookChangeManifest.currentFormat, journalGenerationStatus: generationStatus,
      journalGeneration: generation, acceptedLocalPrefix: prefix, deliveryFloors: floors, cloud: cloud)
    guard let dataVersion = try database.rows("PRAGMA data_version").first?[0].integer,
      dataVersion >= 0 else { throw corrupt("data_version") }
    return try .init(workspaceID: workspaceID, borrowedSnapshotID: snapshotID, readRevision: revision,
      databaseVersion: scalars.databaseVersion, wireVersion: scalars.wireVersion,
      manifestVersion: scalars.manifestVersion, journalGenerationStatus: generationStatus,
      journalGeneration: generation, acceptedLocalPrefix: prefix, deliveryFloors: floors, cloud: cloud,
      controlObservation: .init(scope: .reusedReaderConnection, sqliteDataVersion: dataVersion,
        fixedScalarHash: witness(scalars, domain: "notebook.replica.fixed-control.v1")))
  }

  static func endpoints(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    after cursor: NotebookReplicaInventoryCursor?, limit: Int) throws -> NotebookReplicaEndpointPage {
    try validate(in: database, cut: cut, cursor: cursor, section: .endpoints, limit: limit)
    return try endpointPage(in: database, cut: cut, after: cursor?.position, limit: limit)
  }

  static func endpoints(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    resuming position: NotebookReplicaInventoryPosition,
    expectedControlObservation: NotebookReplicaInventoryCut.ControlObservation, limit: Int) throws -> NotebookReplicaEndpointPage {
    try validateResume(in: database, cut: cut, position: position,
      expected: expectedControlObservation, section: .endpoints, limit: limit)
    return try endpointPage(in: database, cut: cut, after: position, limit: limit)
  }

  private static func endpointPage(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    after cursor: NotebookReplicaInventoryPosition?, limit: Int) throws -> NotebookReplicaEndpointPage {
    if let cursor {
      guard cursor.subkey.isEmpty, cursor.offset == 0 else { throw corrupt("endpoint cursor") }
      switch cursor.kind {
      case 1, 5:
        guard cursor.key.utf8.count <= 73, NotebookReplicationSource(cursorKey: cursor.key) != nil else {
          throw corrupt("endpoint cursor")
        }
      case 2, 3, 4, 6: _ = try uuid(cursor.key, field: "endpoint cursor")
      default: throw corrupt("endpoint cursor")
      }
    }
    // Unknown directions cannot disappear behind the two known sections.
    guard try database.rows("SELECT 1 FROM peer_cursors WHERE direction NOT IN ('incoming','outgoing') OR direction IS NULL LIMIT 1").isEmpty else {
      throw corrupt("peer cursor direction")
    }
    var entries: [NotebookReplicaEndpointObservation] = []
    var lastKind = cursor?.kind ?? 0, lastKey = cursor?.key ?? ""
    var kindToRead = cursor?.kind ?? 1, afterKey = cursor?.key
    while entries.count < limit && kindToRead <= 6 {
      let rows = try endpointRows(in: database, kind: kindToRead, after: afterKey, limit: limit - entries.count)
      for row in rows {
        guard let rawKind = row[0].integer, let key = row[1].text,
          rawKind > Int64(lastKind) || (rawKind == Int64(lastKind) && key > lastKey) else {
          throw corrupt("endpoint key")
        }
        let kind = Int(rawKind), source = NotebookReplicationSource(cursorKey: key)
        let entry: NotebookReplicaEndpointObservation
        switch kind {
        case 1:
          guard let source else { throw corrupt("incoming source") }
          entry = try .incoming(source: source, acceptedThrough: unsigned(row[2], field: "incoming cursor"))
        case 2:
          let deviceID = try uuid(key, field: "outgoing device")
          let acknowledged = try unsigned(row[2], field: "outgoing cursor")
          guard acknowledged <= (cut.acceptedLocalPrefix?.sequence ?? 0) else { throw corrupt("outgoing cursor") }
          entry = .outgoing(deviceID: deviceID, acknowledgedThrough: acknowledged)
        case 3:
          guard let sourceKey = row[3].text, let receivedSource = NotebookReplicationSource(cursorKey: sourceKey) else {
            throw corrupt("received source")
          }
          entry = try .firstReceived(transactionID: uuid(key, field: "received transaction"), source: receivedSource,
            senderSequence: unsigned(row[2], positive: true, field: "received sequence"),
            manifestHash: hash(row[4].text, field: "received manifest"))
        case 4:
          entry = try .admittedGeneration(deviceID: uuid(key, field: "admitted device"),
            generation: uuid(row[3].text, field: "admitted generation"))
        case 5:
          guard let source else { throw corrupt("snapshot source") }
          entry = try .snapshotCoverage(source: source, coveredThrough: decimal(row[3].text, field: "snapshot cursor"))
        case 6:
          guard let value = row[3].text else { throw corrupt("retirement receipt") }
          let data = Data(value.utf8)
          try database.admitJSONDecode(data, maximumAllocationBytes: 65_536)
          let receipt = try JSONDecoder().decode(NotebookPeerRetirement.self, from: data)
          let deviceID = try uuid(key, field: "retired device")
          guard receipt.peerID == deviceID, receipt.workspaceID == cut.workspaceID,
            receipt.sourceCursor <= (cut.acceptedLocalPrefix?.sequence ?? 0),
            receipt.acknowledgedCursor <= receipt.sourceCursor, receipt.date.timeIntervalSinceReferenceDate.isFinite else {
            throw corrupt("retirement receipt")
          }
          entry = .retirement(receipt)
        default: throw corrupt("endpoint kind")
        }
        entries.append(entry); lastKind = kind; lastKey = key
      }
      kindToRead += 1; afterKey = nil
    }
    let next = entries.count == limit ? NotebookReplicaInventoryCursor(workspaceID: cut.workspaceID,
      borrowedSnapshotID: cut.borrowedSnapshotID, section: .endpoints, kind: lastKind,
      key: lastKey, subkey: "", offset: 0) : nil
    return try .init(cut: cut, entries: entries, next: next, complete: next == nil,
      scalarWitnessHash: witness(entries, domain: "notebook.replica.endpoints.v1"))
  }

  private static func endpointRows(in database: NotebookSQLConnection, kind: Int,
    after: String?, limit: Int) throws -> [[NotebookSQLValue]] {
    // Current relations already have key indexes. First-received routes seek
    // their transaction PK instead of GROUP BY/scanning history for every page.
    let arguments: [NotebookSQLValue] = (after.map { [.text($0)] } ?? []) + [.integer(Int64(limit))]
    if kind == 1 || kind == 2 {
      let direction = kind == 1 ? "incoming" : "outgoing"
      let seek = after == nil ? "" : " AND peer_id>?"
      return try database.rows("""
        SELECT \(kind),CASE WHEN typeof(peer_id)='text' AND length(CAST(peer_id AS BLOB)) IN (36,73)
            THEN peer_id END,
          CASE WHEN typeof(sequence)='integer' AND sequence>=0 THEN sequence END,NULL,NULL
        FROM peer_cursors WHERE direction='\(direction)'\(seek) ORDER BY peer_id LIMIT ?
        """, arguments)
    }
    if kind == 3 {
      let seek = after == nil ? "" : "WHERE transaction_id>?"
      return try database.rows("""
        SELECT 3,CASE WHEN typeof(transaction_id)='text' AND length(CAST(transaction_id AS BLOB))=36
            THEN transaction_id END,
          CASE WHEN typeof(sequence)='integer' AND sequence>0 THEN sequence END,
          CASE WHEN typeof(peer_id)='text' AND length(CAST(peer_id AS BLOB)) IN (36,73) THEN peer_id END,
          CASE WHEN typeof(manifest_hash)='text' AND length(CAST(manifest_hash AS BLOB))=64 THEN manifest_hash END
        FROM received_transactions \(seek) ORDER BY transaction_id LIMIT ?
        """, arguments)
    }
    let prefix: String
    switch kind {
    case 4: prefix = "peer_generation:"
    case 5: prefix = "replication_snapshot:"
    case 6: prefix = "retired_peer:"
    default: throw corrupt("endpoint kind")
    }
    let seek = after == nil ? "" : " AND key>?"
    let metadataArguments: [NotebookSQLValue] = (after.map { [.text(prefix + $0)] } ?? []) + [.integer(Int64(limit))]
    return try database.rows("""
      SELECT \(kind),CASE WHEN typeof(key)='text' AND length(CAST(key AS BLOB)) IN
          (\(prefix.utf8.count + 36),\(prefix.utf8.count + 73)) THEN substr(key,\(prefix.utf8.count + 1)) END,NULL,
        CASE WHEN typeof(value)='text' AND length(CAST(value AS BLOB))<=\(kind == 6 ? 4096 : 36) THEN value END,NULL
      FROM metadata WHERE key GLOB '\(prefix)*'\(seek) ORDER BY key LIMIT ?
      """, metadataArguments)
  }

  static func validate(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    cursor: NotebookReplicaInventoryCursor?, section: NotebookReplicaInventoryCursor.Section, limit: Int) throws {
    guard (1...64).contains(limit) else { throw NotebookStorageError.limitExceeded("replica_inventory_page") }
    guard try borrowedSnapshot(in: database) == cut.borrowedSnapshotID else {
      throw NotebookStorageError.invalidTransaction("replica inventory read cut changed")
    }
    let workspace = try database.rows("""
      SELECT CASE WHEN typeof(value)='text' AND length(CAST(value AS BLOB))=36
        THEN value END FROM metadata WHERE key='workspace_id'
      """).first?[0].text
    guard try uuid(workspace, field: "workspace_id") == cut.workspaceID else { throw corrupt("workspace_id") }
    if let cursor, cursor.workspaceID != cut.workspaceID || cursor.borrowedSnapshotID != cut.borrowedSnapshotID
      || cursor.section != section {
      throw NotebookStorageError.invalidTransaction("replica inventory cursor changed")
    }
  }

  static func validateResume(in database: NotebookSQLConnection, cut: NotebookReplicaInventoryCut,
    position: NotebookReplicaInventoryPosition, expected: NotebookReplicaInventoryCut.ControlObservation,
    section: NotebookReplicaInventoryCursor.Section, limit: Int) throws {
    try validate(in: database, cut: cut, cursor: nil, section: section, limit: limit)
    guard position.workspaceID == cut.workspaceID, position.section == section else {
      throw NotebookStorageError.invalidTransaction("replica inventory position changed")
    }
    // Re-read only fixed bounded scalars. The caller cannot replace the current
    // observation with a decoded old cut while keeping a new snapshot UUID.
    let actual = try self.cut(in: database)
    guard actual == cut, actual.controlObservation == expected else {
      throw NotebookStorageError.invalidTransaction("replica inventory control changed")
    }
  }

  private static func borrowedSnapshot(in database: NotebookSQLConnection) throws -> UUID {
    guard !database.writable, let identity = database.readSnapshotIdentity,
      sqlite3_get_autocommit(database.handle) == 0 else { throw NotebookStorageError.readOnlyTransaction }
    try database.checkReadAllowance()
    return identity
  }

  static func uuid(_ value: String?, field: String) throws -> UUID {
    guard let value, value.utf8.count == 36, let result = UUID(uuidString: value),
      value == result.uuidString.lowercased() else {
      throw corrupt(field)
    }
    return result
  }
  static func hash(_ value: String?, field: String) throws -> String {
    guard let value, NotebookTransportFraming.isSHA256(value) else { throw corrupt(field) }
    return value
  }
  static func unsigned(_ value: NotebookSQLValue, positive: Bool = false, field: String) throws -> UInt64 {
    guard let integer = value.integer, integer >= (positive ? 1 : 0) else { throw corrupt(field) }
    return UInt64(integer)
  }
  static func decimal(_ value: String?, field: String) throws -> UInt64 {
    guard let value, value.utf8.count <= 19, let result = UInt64(value),
      result <= UInt64(Int64.max), String(result) == value else { throw corrupt(field) }
    return result
  }
  static func witness<T: Encodable>(_ value: T, domain: String) throws -> String {
    var bytes = Data(domain.utf8); bytes.append(0)
    bytes.append(try NotebookStore.storageEncoder.encode(value))
    return NotebookHexEncoding.encode(SHA256.hash(data: bytes))
  }
  static func corrupt(_ field: String) -> NotebookStorageError { .corruptRecord("replica inventory " + field) }
}
