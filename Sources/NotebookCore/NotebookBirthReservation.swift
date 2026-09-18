import Foundation

extension NotebookStore {
  // Item UUIDs remain reserved by their canonical causal identity after
  // catalogue retirement. An ordinary birth must not adopt retained source.
  func requireUnreservedItemID(_ itemID: UUID) throws {
    let key = fieldKey(["items", itemID.uuidString.lowercased(), "exists"])
    let address = "workspace.json#/collaboration/fields/@" + fieldKey([key])
    let reserved = try sqlRead { database in
      try !database.rows("SELECT 1 FROM records WHERE address=? LIMIT 1", [.text(address)]).isEmpty
    }
    guard !reserved else { throw NotebookStorageError.invalidTransaction("item birth UUID is already reserved") }
  }

  // This is a UUID reservation, not permission to allocate/read an orphan PAGE.
  // The authoritative key stays in the existing retained causal field record;
  // SQLite maintains only a disposable expression index over its page UUID.
  private static let pageBirthPredicate = """
    file='workspace.json' AND parent='workspace.json#' AND collection='collaboration/fields'
    AND length(member)=87 AND substr(member,1,6)='items/' AND substr(member,43,9)='/pageIDs/'
    """

  static var pageBirthReservationQuery: String {
    "SELECT 1 FROM records INDEXED BY record_page_births WHERE " + pageBirthPredicate
      + " AND substr(member,52,36)=? LIMIT 1"
  }

  static func createPageBirthReservationIndex(_ database: NotebookSQLConnection) throws {
    try database.run("CREATE INDEX IF NOT EXISTS record_page_births ON records(substr(member,52,36)) WHERE " + pageBirthPredicate)
  }

  func requireUnreservedPageID(_ pageID: UUID) throws {
    let reserved = try sqlRead { database in
      try !database.rows(Self.pageBirthReservationQuery, [.text(pageID.uuidString.lowercased())]).isEmpty
    }
    guard !reserved else { throw NotebookStorageError.invalidTransaction("page birth UUID is already reserved") }
  }
}
