import Foundation

extension NotebookStore {
  func noteDocumentSourceDelivery(address: String, file: String, collection: String,
    member: String, database: NotebookSQLConnection) throws {
    guard file.hasPrefix("documents/") else { return }
    let prefix = file + "#/blocks/@"
    if address.hasPrefix(prefix), let id = address.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).first, !id.isEmpty {
      try database.noteOwner(.documentProgram, prefix + id)
    }
    if collection == "collaboration/fields", member == "blocks/order" {
      try database.noteOwner(.documentOrder, file)
    }
  }

  /// A program's initial state is an atomic authored value, even when its JSON
  /// contains arrays named blocks or records. Delivery declares the complete
  /// program subtree, not a patch to an unrelated peer's current nested value.
  /// An order edit likewise carries every authored slot, not a hybrid of two
  /// devices' ordinals. Only hashes are enumerated, in the existing SQL window.
  func completeDocumentSourceDelivery(database: NotebookSQLConnection) throws {
    try database.visitOwners(.documentOrder) { file in
      var after = ""
      while true {
        let members = try database.rows("SELECT address FROM records WHERE parent=? AND collection='blocks' AND address>? ORDER BY address LIMIT 64",
          [.text(file + "#"), .text(after)])
        if members.isEmpty { break }
        for member in members {
          after = member[0].text!
          try database.noteOwner(.documentProgram, after)
        }
      }
    }
    try database.visitOwners(.documentProgram) { address in
      let file = String(address.split(separator: "#", maxSplits: 1)[0]), root = file + "#"
      let prefix = file + "#/blocks/@", escapedID = String(address.dropFirst(prefix.count))
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
      for key in DocumentBlock.causalFieldKeys(id: member) {
        let field = root + "/collaboration/fields/@" + fieldKey([key])
        for row in try database.rows("SELECT address,hash FROM records WHERE address=?", [.text(field)]) {
          try database.recordChange(.init(address: row[0].text!, blobHash: row[1].text!))
        }
      }
    }
  }
}
