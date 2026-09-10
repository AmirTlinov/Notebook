import CSQLite
import Foundation

/// Read-only evidence for *every* canonical owner in the current-format copy,
/// including requests, pinned sources, stops and owners unknown to the importer.
/// The importer never writes SQL: NotebookStore remains the only domain writer.
struct ArchiveRecordProof: Codable, Equatable {
  let address: String
  let file: String
  let sha256: String

  static func read(_ root: URL, forbiddenOwners: Set<UUID> = []) throws -> [Self] {
    var database: OpaquePointer?
    let path = root.appendingPathComponent("notebook.sqlite").path
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database else {
      if let database { sqlite3_close(database) }
      throw ArchiveTransferError.invalidSource("cannot read the current-format database")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database,
      "SELECT r.address,r.file,r.hash,b.data FROM records r LEFT JOIN blobs b ON b.hash=r.hash ORDER BY r.address",
      -1, &statement, nil) == SQLITE_OK, let statement else {
      throw ArchiveTransferError.invalidSource("cannot read canonical record evidence")
    }
    defer { sqlite3_finalize(statement) }
    var result: [Self] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return result }
      guard status == SQLITE_ROW,
        let address = sqlite3_column_text(statement, 0), let file = sqlite3_column_text(statement, 1),
        let hash = sqlite3_column_text(statement, 2), let bytes = sqlite3_column_blob(statement, 3) else {
        throw ArchiveTransferError.invalidSource("missing or unreadable canonical value")
      }
      let expected = String(cString: hash)
      let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
      guard digest(data) == expected else { throw ArchiveTransferError.invalidSource("canonical value hash mismatch") }
      try ArchiveReferenceScan.reject(data, owners: forbiddenOwners, address: String(cString: address))
      result.append(.init(address: String(cString: address), file: String(cString: file), sha256: expected))
    }
  }
}

enum ArchiveReferenceScan {
  private static let pattern = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

  /// Each source is scanned once, not once for every item in the other archive.
  static func reject(_ data: Data, owners: Set<UUID>, address: String) throws {
    guard !owners.isEmpty else { return }
    let source = String(decoding: data, as: UTF8.self), ns = source as NSString
    var collision: UUID?
    pattern.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
      guard let match, let id = UUID(uuidString: ns.substring(with: match.range)), owners.contains(id) else { return }
      collision = id; stop.pointee = true
    }
    if let collision {
      throw ArchiveTransferError.invalidSource("historical address collides with the other archive: \(address), \(collision)")
    }
  }
}
