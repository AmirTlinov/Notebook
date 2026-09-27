import Foundation

extension NotebookStore {
  func noteDocumentSourceDelivery(address: String, file: String, collection: String,
    member: String, database: NotebookSQLConnection) throws {
    guard file.hasPrefix("documents/") else { return }
    let prefix = file + "#/files/@"
    if address.hasPrefix(prefix), let id = address.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).first, !id.isEmpty {
      try database.noteOwner(.documentFile, prefix + id)
    }
  }

  /// One addressed file and its four causal registers travel together.
  /// Only hashes are enumerated; sibling source is not reconstructed.
  func completeDocumentSourceDelivery(database: NotebookSQLConnection) throws {
    try database.visitOwners(.documentFile) { address in
      let file = String(address.split(separator: "#", maxSplits: 1)[0]), root = file + "#"
      let prefix = file + "#/files/@", escapedID = String(address.dropFirst(prefix.count))
      let member = escapedID.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
      guard fieldKey([member]) == escapedID else { throw NotebookStorageError.invalidTransaction("document delivery address") }
      let point = try database.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text
      try database.recordChange(.init(address: address, blobHash: point))
      for row in try database.rows("SELECT address,hash FROM records WHERE address=?", [.text(root)]) {
        try database.recordChange(.init(address: row[0].text!, blobHash: row[1].text!))
      }
      var after = address
      while true {
        let rows = try database.rows("SELECT address,hash FROM records WHERE address>? AND address>=? AND address<? ORDER BY address LIMIT 64",
          [.text(after), .text(address + "/"), .text(address + "0")])
        if rows.isEmpty { break }
        for row in rows { after = row[0].text!; try database.recordChange(.init(address: after, blobHash: row[1].text!)) }
      }
      for key in DocumentFile.causalFieldKeys(id: member) {
        let field = root + "/collaboration/fields/@" + fieldKey([key])
        for row in try database.rows("SELECT address,hash FROM records WHERE address=?", [.text(field)]) {
          try database.recordChange(.init(address: row[0].text!, blobHash: row[1].text!))
        }
      }
    }
  }
}
