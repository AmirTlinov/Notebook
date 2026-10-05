import Foundation

extension NotebookStore {
  /// Disposable header index. Canonical action.sequence owns painter order;
  /// appending needs only its frontier, without opening any prior measurements.
  static func createPageInkOrderIndex(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE TABLE IF NOT EXISTS page_ink_order(address TEXT PRIMARY KEY REFERENCES records(address) ON DELETE CASCADE,page_id TEXT NOT NULL,sequence INTEGER NOT NULL)")
    try database.run("CREATE INDEX IF NOT EXISTS page_ink_frontier ON page_ink_order(page_id,sequence DESC,address)")
  }

  func indexPageInkOrder(_ fragment: NotebookStoredFragment, database: NotebookSQLConnection) throws {
    guard let page = UUID(uuidString: URL(fileURLWithPath: fragment.file).deletingPathExtension().lastPathComponent),
      let id = UUID(uuidString: fragment.member),
      fragment.address == pageFile(page) + "#/drawingData/actions/@" + id.uuidString.lowercased(),
      let sequence = try fragment.value["sequence"]?.decode(UInt64.self),
      sequence > 0, sequence <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.corruptRecord(fragment.address)
    }
    try database.run("INSERT INTO page_ink_order(address,page_id,sequence) VALUES(?,?,?) ON CONFLICT(address) DO UPDATE SET page_id=excluded.page_id,sequence=excluded.sequence",
      [.text(fragment.address), .text(page.uuidString.lowercased()), .integer(Int64(sequence))])
  }

  func pageInkSequenceFrontier(_ pageID: UUID) throws -> UInt64 {
    let value = try currentSQL!.rows("SELECT sequence FROM page_ink_order WHERE page_id=? ORDER BY sequence DESC LIMIT 1",
      [.text(pageID.uuidString.lowercased())]).first?[0].integer ?? 0
    guard value >= 0, UInt64(value) <= VersionStamp.maximumCounter else {
      throw NotebookStorageError.corruptRecord("page ink sequence")
    }
    return UInt64(value)
  }
}
