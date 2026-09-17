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
    files: [String: JSONValue], preserving dependencies: inout [CollaborationPreservedDependency]) throws -> Bool {
    let conversion = change.path.suffix(2) == [.field("graphic"), .field("representation")] && change.before == .string("ink")
    let creation = change.before == nil && change.after?["graphic"] != nil
    guard conversion || creation, let version = change.afterVersion else { return false }
    let prefix = conversion ? Array(change.path.dropLast(2)) : change.path
    guard case .member(let id) = prefix.last,
      let operation = receipt.action.operations.first(where: {
        [.insertElement, .convertInkToElement].contains($0.kind) && $0.id.map(collaborationIdentity) == id
      }) else { return false }
    var adopted = false
    if conversion {
      let graphic = try files[change.file]?.value(at: prefix[...])?["graphic"]?.decode(NotebookGraphic.self)
      let paths = [["frame"]] + (graphic == nil ? [] : NotebookGraphic.allCausalPaths).filter { !["representation", "visible", "sourceInkIDs"].contains($0[0]) }.map { ["graphic"] + $0 }
      for suffix in paths {
        let path = prefix + suffix.map(CollaborationPathComponent.field)
        // Optional geometry can be absent initially, or deliberately cleared
        // later. Only the latter has an authored register and can adopt a shape.
        if files[change.file]?.value(at:path[...]) == nil && collaborationFieldVersion(file:files[change.file],path:path) == nil { continue }
        let field = CollaborationFieldChange(file: change.file, path: path, before: nil, after: nil, afterVersion: version)
        if try !fieldIsOwned(collaborationFieldVersion(file: files[change.file], path: path), by: field) { adopted = true; break }
      }
    }
    let owner = operation.target.kind.rawValue + ":" + operation.target.id.uuidString.lowercased()
    for address in try dependentGraphicAddresses(owner: owner, id: id) {
      guard let dependent = try storedFragments(address: address, descendants: false).first,
        let graphic = try dependent.value["graphic"]?.decode(NotebookGraphic.self), graphic.showsGeometry,
        let dependentID = dependent.value["id"]?.string else { continue }
      // An atomic construction can undo its own still-owned link and nodes.
      // A later independent edit of that link protects the entire dependency.
      let created = receipt.changes.first { $0.file == dependent.file && $0.before == nil && $0.after?["id"]?.string == dependentID }
      if let created, let authored = created.afterVersion {
        let paths = [["frame"], ["worldOrigin"]] + graphic.causalPaths.map { ["graphic"] + $0 }
        var owned = true
        for suffix in paths where dependent.value.value(at:suffix.map(CollaborationPathComponent.field)[...]) != nil {
          let path = created.path + suffix.map(CollaborationPathComponent.field)
          let current = try collaborationFieldVersion(path: path, read: { try readCollaborationValue(file: dependent.file, path: $0) })
          if try !fieldIsOwned(current, by: .init(file: dependent.file, path: path, before: nil, after: nil, afterVersion: authored)) {
            owned = false; break
          }
        }
        if owned { continue }
      }
      let dependency = CollaborationPreservedDependency(file:dependent.file,
        path:Array(prefix.dropLast())+[.member(collaborationIdentity(dependentID))],dependsOn:prefix)
      if !dependencies.contains(dependency) { dependencies.append(dependency) }
      adopted = true
    }
    return adopted
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
