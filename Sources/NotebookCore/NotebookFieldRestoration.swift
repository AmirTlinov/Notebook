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
      try insertFieldRestoration(restoration, key: key, receiptAddress: address, database: database)
    }
    try indexLifecycleFieldRestorations(receipt, address: address, database: database)
  }

  private func insertFieldRestoration(_ restoration: CollaborationFieldRestoration, key: String,
    receiptAddress: String, database: NotebookSQLConnection) throws {
    let data = try Self.storageEncoder.encode(restoration)
    if let existing = try database.rows("SELECT value FROM action_field_restorations WHERE address=? AND field=?",
      [.text(receiptAddress), .text(key)]).first?[0].blob {
      guard try JSONDecoder().decode(CollaborationFieldRestoration.self, from: existing) == restoration else {
        throw NotebookStorageError.invalidTransaction("inconsistent field restoration")
      }
      return
    }
    try database.run("INSERT INTO action_field_restorations(address,field,version,value) VALUES(?,?,?,?)",
      [.text(receiptAddress), .text(key), .text(restoration.writtenVersion.restorationIdentity), .blob(data)])
  }

  /// Lifecycle fields are deliberately absent from the small ordinary patch
  /// array. Their existing inverse streams attest the same causal restoration
  /// without putting every page membership in a receipt or a second history.
  private func indexLifecycleFieldRestorations(_ receipt: CollaborationReceipt, address: String,
    database: NotebookSQLConnection) throws {
    let restored = (receipt.undo?.lifecycleChanges ?? []).filter { $0.kind == .restoreItem }
    guard !restored.isEmpty else { return }
    guard restored.count <= 512, let original = receipt.lifecycleInverse,
      let inverse = receipt.undo?.restorationInverse else {
      throw NotebookStorageError.invalidTransaction("lifecycle restoration evidence")
    }
    let targets = Set(restored.map(\.target))
    guard targets.count == restored.count, restored.allSatisfy({ event in
      event.target.kind == .cover && event.item?.id == event.target.id
        && receipt.lifecycleChanges?.contains(where: { $0.kind == .deleteItem && $0.target == event.target }) == true
        && receipt.undo?.preservedLifecycle?.contains(event.target) != true
    }) else { throw NotebookStorageError.invalidTransaction("lifecycle restoration scope") }

    // Scalar evidence only, streamed into TEMP. Even a large notebook has no
    // array of fields or page bodies in the provenance owner.
    try database.run("CREATE TEMP TABLE IF NOT EXISTS lifecycle_restoration_fields(address TEXT PRIMARY KEY,before_hash TEXT,after_hash TEXT) WITHOUT ROWID")
    try database.run("DELETE FROM lifecycle_restoration_fields")
    defer { try? database.run("DELETE FROM lifecycle_restoration_fields") }
    try visitLifecycleInverse(reference: original, actionID: receipt.id) { change in
      let row = try readLifecycleInverseFragment(hash: change.beforeHash ?? change.afterHash!, address: change.address)
      guard row.collection == "collaboration/fields" || row.collection == "board/collaboration/fields"
        || row.collection == "pageIDs" || row.collection == "board/elements" else { return }
      try database.run("INSERT INTO lifecycle_restoration_fields VALUES(?,?,?)", [.text(change.address),
        change.beforeHash.map(NotebookSQLValue.text) ?? .null, change.afterHash.map(NotebookSQLValue.text) ?? .null])
    }

    func oldSource(_ source: String) throws -> NotebookStoredFragment? {
      guard let hash = try database.rows("SELECT before_hash FROM lifecycle_restoration_fields WHERE address=?",
        [.text(source)]).first?[0].text else { return nil }
      return try readLifecycleInverseFragment(hash: hash, address: source)
    }

    func fieldPath(_ row: NotebookStoredFragment) throws -> [CollaborationPathComponent]? {
      let parts = row.member.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      if row.file == "workspace.json", row.parent == "workspace.json#", row.collection == "collaboration/fields" {
        if parts == ["items", "order"] { return [.field("collaboration"), .field("fields"), .field(row.member)] }
        guard parts.count >= 3, parts[0] == "items", let id = UUID(uuidString: parts[1]),
          targets.contains(where: { $0.id == id }), ["exists", "title", "kind", "pageIDs"].contains(parts[2]) else { return nil }
        if parts.count == 4, parts[2] == "pageIDs" {
          guard try oldSource("workspace.json#/items/@" + parts[1] + "/pageIDs/@" + parts[3]) != nil else { return nil }
        } else if parts.count != 3 { return nil }
        return [.field("collaboration"), .field("fields"), .field(row.member)]
      }
      if row.file == "board.json", row.collection == "board/collaboration/fields",
        let parent = row.parent, parent.hasPrefix("board.json#/boards/@"),
        let board = UUID(uuidString: String(parent.dropFirst("board.json#/boards/@".count))),
        targets.contains(where: { $0.boardID == board }), parts.count >= 2, parts[0] == "elements" {
        if parts != ["elements", "order"] {
          // A physical cover source, not its position or a similar ID on a
          // different surface, defines this lifecycle group's field ownership.
          guard parts.count >= 3,
            let source = try oldSource(parent + "/board/elements/@" + parts[1]),
            let surface = try source.value["surface"]?.decode(SurfaceID.self), surface.kind == .cover,
            targets.contains(where: { $0.id == surface.ownerID && $0.boardID == board }) else { return nil }
        }
        return [.field("boards"), .member(board.uuidString.lowercased()), .field("board"),
          .field("collaboration"), .field("fields"), .field(row.member)]
      }
      return nil
    }

    try visitLifecycleInverse(reference: inverse, actionID: receipt.id) { change in
      guard let after = change.afterHash else { return }
      let row = try readLifecycleInverseFragment(hash: after, address: change.address)
      guard let path = try fieldPath(row) else { return }
      let expectedAddress = row.parent! + "/" + row.collection + "/@" + fieldKey([row.member])
      guard row.address == expectedAddress, row.collections.isEmpty, row.position == 0 else {
        throw NotebookStorageError.invalidTransaction("lifecycle restoration field identity")
      }
      let prior = try database.rows("SELECT before_hash FROM lifecycle_restoration_fields WHERE address=?", [.text(row.address)]).first
      // An unchanged membership may have kept its old version through deletion.
      // A field changed inside the original action must instead use that
      // action's before-image, never its intermediate pre-delete value.
      let oldHash = prior.map { $0[0].text } ?? change.beforeHash
      guard let oldHash else { return } // A new field has no earlier owner.
      let old = try readLifecycleInverseFragment(hash: oldHash, address: row.address)
      guard old.file == row.file, old.parent == row.parent, old.collection == row.collection,
        old.member == row.member, old.position == 0, old.collections.isEmpty else {
        throw NotebookStorageError.invalidTransaction("lifecycle restored field identity")
      }
      let written = try row.value.decode(ContentFieldVersion.self), previous = try old.value.decode(ContentFieldVersion.self)
      guard written.isValid, previous.isValid, written.human,
        written.stamp != previous.stamp, written.includes(previous) else {
        throw NotebookStorageError.invalidTransaction("lifecycle restoration field version")
      }
      let restoration = CollaborationFieldRestoration(file: row.file, path: path,
        writtenVersion: written, restoredVersion: previous)
      try insertFieldRestoration(restoration, key: restorationKey(file: row.file, path: path),
        receiptAddress: address, database: database)
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
