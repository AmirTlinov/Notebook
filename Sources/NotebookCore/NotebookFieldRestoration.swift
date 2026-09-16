import Foundation

extension NotebookStore {
  /// A disposable index over the existing receipts. It contains no independent
  /// history and is rebuilt with the receipt read model during SQL admission.
  func indexFieldRestorations(_ receipt: CollaborationReceipt, address: String,
    database: NotebookSQLConnection) throws {
    try database.run("DELETE FROM action_field_restorations WHERE address=?", [.text(address)])
    var fields: [String: CollaborationFieldRestoration] = [:]
    for restoration in receipt.undo?.restorations ?? [] {
      guard restoration.writtenVersion.isValid, restoration.restoredVersion.isValid,
        restoration.writtenVersion.human,
        receipt.changes.contains(where: {
          $0.file == restoration.file && $0.path == restoration.path
            && $0.beforeVersion == restoration.restoredVersion
        }), receipt.undo?.preserved.contains(where: {
          $0.file == restoration.file && $0.path == restoration.path
        }) == false else { throw NotebookStorageError.invalidTransaction("invalid field restoration") }
      let key = try restorationKey(file: restoration.file, path: restoration.path)
      if try receipt.undo?.preserved.contains(where: {
        try restorationKey(file: $0.file, path: $0.path) == key
      }) == true { continue }
      if let prior = fields[key], prior.writtenVersion != restoration.writtenVersion || prior.restoredVersion != restoration.restoredVersion {
        throw NotebookStorageError.invalidTransaction("inconsistent field restoration")
      }
      fields[key] = restoration
    }
    for (key, restoration) in fields {
      try database.run("INSERT INTO action_field_restorations(address,field,version,value) VALUES(?,?,?,?)",
        [.text(address), .text(key),
          .text(restoration.writtenVersion.restorationIdentity), .blob(try Self.storageEncoder.encode(restoration))])
    }
  }

  /// Values alone never authorize undo (including an independent A → B → A).
  /// Follow only inverse writes attested by durable receipts at this exact path.
  func fieldIsOwned(_ current: ContentFieldVersion?, by change: CollaborationFieldChange) throws -> Bool {
    guard let expected = change.afterVersion else { return true }
    guard var version = current else { return false }
    let field = try restorationKey(file: change.file, path: change.path)
    var visited = Set<String>()
    while visited.insert(version.restorationIdentity).inserted {
      if version.stamp == expected.stamp && version.human == expected.human { return true }
      let rows = try currentSQL!.rows("SELECT value FROM action_field_restorations WHERE field=? AND version=? LIMIT 2",
        [.text(field), .text(version.restorationIdentity)])
      // Two claims about one inverse dot are not evidence of restored ownership.
      guard rows.count == 1, let data = rows[0][0].blob else { return false }
      version = try JSONDecoder().decode(CollaborationFieldRestoration.self, from: data).restoredVersion
    }
    return false
  }

  func graphicConversionIsAdopted(_ change: CollaborationFieldChange, receipt: CollaborationReceipt,
    files: [String: JSONValue]) throws -> Bool {
    guard change.path.suffix(2) == [.field("graphic"), .field("representation")],
      let version = change.afterVersion, change.before == .string("ink"),
      case .member(let id) = change.path.dropLast(2).last,
      receipt.action.operations.contains(where: { $0.kind == .convertInkToElement && $0.id.map(collaborationIdentity) == id }) else { return false }
    let prefix = Array(change.path.dropLast(2))
    for suffix: [CollaborationPathComponent] in [[.field("frame")], [.field("graphic"), .field("shape")],
      [.field("graphic"), .field("label")], [.field("graphic"), .field("style")]] {
      let path = prefix + suffix
      let field = CollaborationFieldChange(file: change.file, path: path, before: nil, after: nil, afterVersion: version)
      if try !fieldIsOwned(collaborationFieldVersion(file: files[change.file], path: path), by: field) { return true }
    }
    return false
  }

  private func restorationKey(file: String, path: [CollaborationPathComponent]) throws -> String {
    String(decoding: try Self.storageEncoder.encode(RestorationAddress(file: file,
      path: collaborationCausalFieldPath(path) ?? path)), as: UTF8.self)
  }
}

private struct RestorationAddress: Encodable {
  let file: String
  let path: [CollaborationPathComponent]
}

private extension ContentFieldVersion {
  var restorationIdentity: String { stamp.revision + (human ? ":human" : ":agent") }
}
