import Foundation

/// Identifies a journal, not authorship. Relays retain transaction IDs and all
/// causal versions. A new journal on the same device gets another generation.
public struct NotebookReplicationSource: Codable, Equatable, Hashable, Sendable {
  public let deviceID: UUID
  public let generation: UUID
  public init(deviceID: UUID, generation: UUID) {
    self.deviceID = deviceID; self.generation = generation
  }
  init?(cursorKey: String) {
    let parts=cursorKey.split(separator:"/",omittingEmptySubsequences:false)
    guard (1...2).contains(parts.count),let device=UUID(uuidString:String(parts[0])),
      let generation=parts.count == 1 ? device : UUID(uuidString:String(parts[1])) else { return nil }
    self.init(deviceID:device,generation:generation)
    guard self.cursorKey == cursorKey else { return nil }
  }
  var cursorKey: String {
    let peer = deviceID.uuidString.lowercased()
    // Existing installed journals are generation deviceID. This admission
    // preserves their acknowledged position, including the retired wire floor.
    return generation == deviceID ? peer : peer + "/" + generation.uuidString.lowercased()
  }
}

/// Snapshot is a coherent cut followed by the same journal. It authorizes only
/// skipping the covered prefix, never replacing local content or its clocks.
public struct NotebookReplicationDelivery: Codable, Equatable, Sendable {
  public let source: NotebookReplicationSource
  public let change: NotebookDurableChange
  public let isSnapshot: Bool
  public init(source: NotebookReplicationSource, change: NotebookDurableChange, isSnapshot: Bool = false) {
    self.source = source; self.change = change; self.isSnapshot = isSnapshot
  }
}

extension NotebookStore {
  /// Incoming cursors name journals; outgoing acknowledgements name devices.
  /// A new incoming generation is not another recipient of our shared writes.
  /// Preserve every cursor and still require acknowledgement from every device,
  /// including a historical peer whose continued membership is unknown.
  func hasPendingPeerDelivery(through cursor: UInt64,database: NotebookSQLConnection) throws -> Bool {
    let retired = try Self.retiredReplicationPeers(database: database)
    let devices=try Set(database.rows("SELECT peer_id,direction FROM peer_cursors").map { row -> UUID in
      guard let key=row[0].text,let source=NotebookReplicationSource(cursorKey:key),
        row[1].text == "incoming" || (row[1].text == "outgoing" && key == source.deviceID.uuidString.lowercased()) else {
        throw NotebookStorageError.corruptRecord("peer_cursors")
      }
      return source.deviceID
    })
    return try devices.contains { peer in
      if retired.contains(peer) { return false }
      let acknowledged=try database.rows("SELECT sequence FROM peer_cursors WHERE peer_id=? AND direction='outgoing'",
        [.text(peer.uuidString.lowercased())]).first?[0].integer ?? 0
      return try !database.rows("SELECT 1 FROM change_log WHERE sequence>? AND sequence<=? LIMIT 1",
        [.integer(acknowledged),.integer(Int64(cursor))]).isEmpty
    }
  }

  public func replicationSource(deviceID: UUID) throws -> NotebookReplicationSource {
    try commandTransaction(advancesReadRevision: false) {
      let database = currentSQL!
      let generation = try database.rows("SELECT value FROM metadata WHERE key='journal_generation'").first?[0].text.flatMap(UUID.init(uuidString:)) ?? deviceID
      try database.run("INSERT OR IGNORE INTO metadata(key,value) VALUES('journal_generation',?)", [.text(generation.uuidString.lowercased())])
      return .init(deviceID: deviceID, generation: generation)
    }
  }

  /// Only the authenticated direct session selects the current source for
  /// device-addressed receipts. Delayed cloud history cannot switch it back.
  public func admitReplicationSource(_ source: NotebookReplicationSource) throws -> UInt64 {
    try commandTransaction(advancesReadRevision: false) {
      try requireActiveReplicationPeer(source.deviceID, database: currentSQL!)
      try currentSQL!.run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [.text("peer_generation:" + source.deviceID.uuidString.lowercased()), .text(source.generation.uuidString.lowercased())])
      return try incomingCursor(source: source)
    }
  }

  public func incomingCursor(source: NotebookReplicationSource) throws -> UInt64 {
    try sqlRead { UInt64(try $0.rows("SELECT sequence FROM peer_cursors WHERE peer_id=? AND direction='incoming'", [.text(source.cursorKey)]).first?[0].integer ?? 0) }
  }

  /// A coherent checkpoint covers a source prefix even when the individual
  /// historical transaction receipts were not copied into this replica.
  public func deliveryNeedsContent(_ delivery: NotebookReplicationDelivery) throws -> Bool {
    try sqlRead { db in
      try requireActiveReplicationPeer(delivery.source.deviceID, database: db)
      let change = delivery.change
      guard change.sequence > 0, change.sequence <= UInt64(Int64.max) else { throw NotebookStorageError.invalidTransaction("incoming sequence") }
      let transaction = change.transactionID.uuidString.lowercased()
      let known = try db.rows("SELECT manifest_hash FROM received_transactions WHERE transaction_id=? UNION SELECT manifest_hash FROM change_log WHERE transaction_id=?", [.text(transaction), .text(transaction)])
      if !known.isEmpty {
        guard known.allSatisfy({ $0[0].text == change.manifestHash }) else { throw NotebookStorageError.transactionConflict }
        return false
      }
      let floor = UInt64(try db.rows("SELECT value FROM metadata WHERE key=?", [.text("replication_snapshot:" + delivery.source.cursorKey)]).first?[0].text ?? "0") ?? 0
      return delivery.isSnapshot || change.sequence > floor
    }
  }

  func coverReplicationPrefix(_ delivery: NotebookReplicationDelivery) throws {
    guard delivery.isSnapshot else { return }
    let key = "replication_snapshot:" + delivery.source.cursorKey
    let old = UInt64(try currentSQL!.rows("SELECT value FROM metadata WHERE key=?", [.text(key)]).first?[0].text ?? "0") ?? 0
    try currentSQL!.run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      [.text(key), .text(String(max(old, delivery.change.sequence)))])
  }

}
