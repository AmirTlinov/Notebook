import CryptoKit
import Foundation

extension NotebookStore {
  /// A disposable index over the existing receipts. It contains no independent
  /// history and is rebuilt with the receipt read model during SQL admission.
  func indexFieldRestorations(_ receipt: CollaborationReceipt, address: String,
    database: NotebookSQLConnection) throws {
    try database.run("DELETE FROM action_field_restorations WHERE address=?", [.text(address)])
    var fields: [String: CollaborationFieldRestoration] = [:]
    for restoration in receipt.undo?.restorations ?? [] {
      guard restoration.writtenVersion.isValid, restoration.restoredVersion?.isValid ?? true,
        restoration.writtenVersion.human,
        receipt.changes.contains(where: {
          $0.file == restoration.file && $0.path == restoration.path
            && $0.beforeVersion == restoration.restoredVersion
            && (restoration.restoredVersion != nil || $0.before == nil)
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
    try indexCapturedFieldRestorations(receipt, address: address, database: database)
  }

  private func insertFieldRestoration(_ restoration: CollaborationFieldRestoration, key: String,
    receiptAddress: String, database: NotebookSQLConnection,
    condition: CapturedFieldRestorationCondition? = nil) throws {
    let value = try JSONValue.encode(restoration).setting("condition", condition.map { try .encode($0) })
    let data = try Self.storageEncoder.encode(value)
    if let existing = try database.rows("SELECT value FROM action_field_restorations WHERE address=? AND field=?",
      [.text(receiptAddress), .text(key)]).first?[0].blob {
      let previous = try JSONDecoder().decode(JSONValue.self, from: existing)
      guard try previous.decode(CollaborationFieldRestoration.self) == restoration,
        try previous["condition"]?.decode(CapturedFieldRestorationCondition.self) == condition else {
        throw NotebookStorageError.invalidTransaction("inconsistent field restoration")
      }
      return
    }
    try database.run("INSERT INTO action_field_restorations(address,field,version,value) VALUES(?,?,?,?)",
      [.text(receiptAddress), .text(key), .text(restoration.writtenVersion.restorationIdentity), .blob(data)])
  }

  /// Implicit existence, complete placement registers and lifecycle membership
  /// use the same authenticated changed-record streams, never a second history.
  private func indexCapturedFieldRestorations(_ receipt: CollaborationReceipt, address: String,
    database: NotebookSQLConnection) throws {
    let restored = (receipt.undo?.lifecycleChanges ?? []).filter { $0.kind == .restoreItem }
    let removed = (receipt.undo?.lifecycleChanges ?? []).filter { $0.kind == .removePage }
    guard receipt.undo != nil else { return }
    guard restored.count <= 512, let original = receipt.lifecycleInverse,
      let inverse = receipt.undo?.restorationInverse else {
      if !restored.isEmpty || !removed.isEmpty { throw NotebookStorageError.invalidTransaction("lifecycle restoration evidence") }
      return // Historical ordinary receipts cannot invent missing provenance.
    }
    let targets = Set(restored.map(\.target))
    guard targets.count == restored.count, restored.allSatisfy({ event in
      event.target.kind == .cover && event.item?.id == event.target.id
        && receipt.lifecycleChanges?.contains(where: { $0.kind == .deleteItem && $0.target == event.target }) == true
        && receipt.undo?.preservedLifecycle?.contains(event.target) != true
    }) else { throw NotebookStorageError.invalidTransaction("lifecycle restoration scope") }
    guard removed.count <= 512, removed.allSatisfy({ event in
      event.target.kind == .cover && event.pageID != nil
        && receipt.lifecycleChanges?.contains(where: { $0.kind == .appendPage && $0.target == event.target && $0.pageID == event.pageID }) == true
        && receipt.undo?.preservedLifecycle?.contains(event.target) != true
    }) else { throw NotebookStorageError.invalidTransaction("append restoration scope") }

    // Scalar evidence only, streamed into TEMP. Even a large notebook has no
    // array of fields or page bodies in the provenance owner.
    try database.run("CREATE TEMP TABLE IF NOT EXISTS lifecycle_restoration_fields(address TEXT PRIMARY KEY,before_hash TEXT,after_hash TEXT) WITHOUT ROWID")
    try database.run("CREATE TEMP TABLE IF NOT EXISTS captured_restoration_undo(address TEXT PRIMARY KEY,before_hash TEXT,after_hash TEXT) WITHOUT ROWID")
    try database.run("DELETE FROM lifecycle_restoration_fields")
    try database.run("DELETE FROM captured_restoration_undo")
    defer {
      try? database.run("DELETE FROM lifecycle_restoration_fields")
      try? database.run("DELETE FROM captured_restoration_undo")
    }
    try visitLifecycleInverse(reference: original, actionID: receipt.id) { change in
      try database.run("INSERT INTO lifecycle_restoration_fields VALUES(?,?,?)", [.text(change.address),
        change.beforeHash.map(NotebookSQLValue.text) ?? .null, change.afterHash.map(NotebookSQLValue.text) ?? .null])
    }
    try visitLifecycleInverse(reference: inverse, actionID: receipt.id) { change in
      try database.run("INSERT INTO captured_restoration_undo VALUES(?,?,?)", [.text(change.address),
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
        if parts == ["items", "order"], !targets.isEmpty { return [.field("collaboration"), .field("fields"), .field(row.member)] }
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

    func implicitExistencePath(_ row: NotebookStoredFragment) throws -> [CollaborationPathComponent]? {
      let parts = row.member.split(separator: "/", omittingEmptySubsequences: false).map {
        $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
      }
      guard parts.count == 3, parts[2] == "exists", row.member == fieldKey(parts), let parent = row.parent else { return nil }
      let prefix: [CollaborationPathComponent], sourceAddress: String
      if row.file == "workspace.json", parent == "workspace.json#", row.collection == "collaboration/fields", parts[0] == "items",
        let id = UUID(uuidString: parts[1]), parts[1] == id.uuidString.lowercased() {
        prefix = []; sourceAddress = parent + "/items/@" + parts[1]
      } else if row.file == "board.json", row.collection == "board/collaboration/fields", parts[0] == "elements",
        parent.hasPrefix("board.json#/boards/@"), let board = UUID(uuidString: String(parent.dropFirst("board.json#/boards/@".count))) {
        prefix = [.field("boards"), .member(board.uuidString.lowercased()), .field("board")]
        sourceAddress = parent + "/board/elements/@" + fieldKey([parts[1]])
      } else if row.collection == "collaboration/fields", parent == row.file + "#",
        (row.file.hasPrefix("pages/") && parts[0] == "elements") || (row.file.hasPrefix("documents/") && parts[0] == "blocks") {
        prefix = []; sourceAddress = parent + "/" + parts[0] + "/@" + fieldKey([parts[1]])
      } else { return nil }
      let source = prefix + [.field(parts[0]), .member(parts[1])]
      guard receipt.undo?.preserved.contains(where: {
        $0.file == row.file && ($0.path.starts(with: source) || source.starts(with: $0.path))
      }) != true else { return nil }
      let removedAppend = row.file == "workspace.json" && removed.contains { $0.target.id.uuidString.lowercased() == parts[1] }
      guard removedAppend || receipt.changes.contains(where: {
        $0.file == row.file && $0.path.count > source.count && $0.path.starts(with: source)
      }) else { return nil }
      if !removedAppend {
        guard let priorHash = try database.rows("SELECT before_hash FROM lifecycle_restoration_fields WHERE address=?", [.text(sourceAddress)]).first?[0].text,
          let hash = try database.rows("SELECT after_hash FROM captured_restoration_undo WHERE address=?", [.text(sourceAddress)]).first?[0].text else { return nil }
        // Both streams were fully admitted above. Equal physical references
        // name the very same immutable source, not two hash-equal measurements.
        // Compare that shared form before reconstructing any source again.
        func stored(_ hash: String) throws -> NotebookStoredFragment {
          let data = try lifecycleInverseBlob(hash, maximumBytes: 256 * 1_024 * 1_024)
          let value = try JSONDecoder().decode(NotebookStoredFragment.self, from: data)
          guard value.address == sourceAddress else { throw NotebookStorageError.invalidTransaction("restoration source address") }
          return value
        }
        let oldStored = try stored(priorHash), writtenStored = try stored(hash)
        if oldStored.inkBodies != writtenStored.inkBodies
          || collaborationComparable(oldStored.value, file: row.file, path: source)
            != collaborationComparable(writtenStored.value, file: row.file, path: source) {
          let old = try readLifecycleInverseFragment(hash: priorHash, address: sourceAddress)
          let written = try readLifecycleInverseFragment(hash: hash, address: sourceAddress)
          guard collaborationComparable(old.value, file: row.file, path: source)
            == collaborationComparable(written.value, file: row.file, path: source) else { return nil }
        }
      }
      return prefix + [.field("collaboration"), .field("fields"), .field(row.member)]
    }

    func indexChange(_ change: NotebookActionRecordChange) throws {
      // The complete streams have already been validated. Only field and
      // placement records contribute ownership; geometry cannot add an edge.
      guard let after = change.afterHash else { return }
      let data = try lifecycleInverseBlob(after, maximumBytes: 256 * 1_024 * 1_024)
      let stored = try JSONDecoder().decode(NotebookStoredFragment.self, from: data)
      guard ["collaboration/fields", "board/collaboration/fields", "board/placements"].contains(stored.collection) else { return }
      let row = try readLifecycleInverseFragment(hash: after, address: change.address)
      if row.collection == "board/placements" {
        let target = targets.first(where: { target in
          target.boardID.map { placementRecordAddress(boardID: $0, itemID: target.id) == row.address } == true
        })
        let ordinary = receipt.changes.first { field in
          guard let owner = placementAddress(field.file, field.path) else { return false }
          return placementRecordAddress(boardID: owner.boardID, itemID: owner.itemID) == row.address
        }
        guard let owner = target.flatMap({ value in value.boardID.map { (boardID: $0, itemID: value.id) } })
          ?? ordinary.flatMap({ placementAddress($0.file, $0.path) }) else { return }
        let boardID = owner.boardID, itemID = owner.itemID
        if target == nil, receipt.undo?.preserved.contains(where: { $0.file == ordinary!.file && $0.path == ordinary!.path }) == true { return }
        guard let hashes = try database.rows("SELECT before_hash,after_hash FROM lifecycle_restoration_fields WHERE address=?",
          [.text(row.address)]).first, let priorHash = hashes[0].text, let deletedHash = hashes[1].text,
          let undoBeforeHash = change.beforeHash else {
          if target != nil { throw NotebookStorageError.invalidTransaction("lifecycle placement restoration evidence") }
          return // Undoing a new placement does not restore an older owner.
        }
        let prior = try restoredPlacement(hash: priorHash, boardID: boardID, itemID: itemID)
        let deleted = try restoredPlacement(hash: deletedHash, boardID: boardID, itemID: itemID)
        let undoBefore = try restoredPlacement(hash: undoBeforeHash, boardID: boardID, itemID: itemID)
        let written = try restoredPlacement(hash: after, boardID: boardID, itemID: itemID)
        let owned: Bool
        if target != nil { owned = deleted.pose == nil && undoBefore == deleted }
        else { owned = true } // Its exact dependency is checked when followed, independent of receipt indexing order.
        // Observation alone cannot establish identity: one authored dot may
        // not carry two poses. The native merge validates that shared frontier
        // before proving dominance, including intermediate writes in an action.
        guard prior.pose != nil, owned,
          try deleted.merging(prior) == deleted, try written.merging(undoBefore) == written, written != prior,
          written.heads.count == 1, written.heads[0].version.human,
          written.pose == prior.pose else {
          throw NotebookStorageError.invalidTransaction("lifecycle placement restoration register")
        }
        // Rebuildable pointers into the two already authenticated inverse
        // streams, not another copy of the placement's causal history.
        let proof = LifecyclePlacementRestoration(writtenHash: after, restoredHash: priorHash,
          requiredBeforeHash: target == nil ? undoBeforeHash : nil, originalAfterHash: target == nil ? deletedHash : nil)
        try database.run("INSERT INTO action_field_restorations(address,field,version,value) VALUES(?,?,?,?)",
          [.text(address), .text("placement:" + row.address), .text(try placementIdentity(written)),
            .blob(try Self.storageEncoder.encode(proof))])
        return
      }
      let lifecyclePath = try fieldPath(row)
      guard let path = try lifecyclePath ?? implicitExistencePath(row) else { return }
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
      var condition: CapturedFieldRestorationCondition?
      if lifecyclePath == nil {
        guard let authoredHash = try database.rows("SELECT after_hash FROM lifecycle_restoration_fields WHERE address=?", [.text(row.address)]).first?[0].text,
          let undoBeforeHash = change.beforeHash else { return }
        let authored = try readLifecycleInverseFragment(hash: authoredHash, address: row.address).value.decode(ContentFieldVersion.self)
        let current = try readLifecycleInverseFragment(hash: undoBeforeHash, address: row.address).value.decode(ContentFieldVersion.self)
        guard authored.isValid, current.isValid else { throw NotebookStorageError.invalidTransaction("implicit restoration field version") }
        // This is a conditional edge, not an authority grant. Rebuild/snapshot
        // order need not have admitted its ancestor's derived index yet.
        condition = .init(current: current, expected: authored)
        let written = try row.value.decode(ContentFieldVersion.self)
        guard try written.joining(current) == written else { throw NotebookStorageError.invalidTransaction("implicit restoration causal frontier") }
      }
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
        receiptAddress: address, database: database, condition: condition)
    }
    var cursor = ""
    while true {
      let rows = try database.rows("SELECT address,before_hash,after_hash FROM captured_restoration_undo WHERE address>? ORDER BY address LIMIT 64", [.text(cursor)])
      guard let last = rows.last?[0].text else { break }
      for row in rows { try indexChange(.init(address: row[0].text!, beforeHash: row[1].text, afterHash: row[2].text)) }
      cursor = last
    }
  }

  /// Values alone never authorize undo (including an independent A → B → A).
  /// Follow only inverse writes attested by durable receipts at this exact path.
  /// Destructive lifecycle callers also require the complete version at every
  /// hop: an unrelated observation or losing head cannot borrow an inverse dot.
  func fieldIsOwned(_ current: ContentFieldVersion?, by change: CollaborationFieldChange,
    requiringExactVersion: Bool = false) throws -> Bool {
    guard let expected = change.afterVersion else { return true }
    guard let current else { return false }
    let field = try restorationKey(file: change.file, path: change.path)
    return try fieldVersionIsOwned(current, expected: expected, field: field,
      requiringExactVersion: requiringExactVersion, ancestors: [])
  }

  private func fieldVersionIsOwned(_ current: ContentFieldVersion, expected: ContentFieldVersion?,
    field: String, requiringExactVersion: Bool, ancestors: Set<String>) throws -> Bool {
    var version = current, visited = ancestors
    while visited.insert(version.restorationIdentity).inserted {
      if let expected,requiringExactVersion ? version == expected : (version.stamp == expected.stamp && version.human == expected.human) { return true }
      let rows = try currentSQL!.rows("SELECT value FROM action_field_restorations WHERE field=? AND version=? LIMIT 2",
        [.text(field), .text(version.restorationIdentity)])
      // Two claims about one inverse dot are not evidence of restored ownership.
      guard rows.count == 1, let data = rows[0][0].blob else { return false }
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      let restoration = try value.decode(CollaborationFieldRestoration.self)
      let condition = try value["condition"]?.decode(CapturedFieldRestorationCondition.self)
      // Delivery may bind an implicit single head to its nil payload. This is
      // the same absence, not an extra observation or concurrent authored head.
      let exact = expected == nil
        ? version.retainingValue(nil) == restoration.writtenVersion.retainingValue(nil)
        : version == restoration.writtenVersion
      guard !(requiringExactVersion || condition != nil) || exact else { return false }
      if let condition {
        guard try fieldVersionIsOwned(condition.current, expected: condition.expected, field: field,
          requiringExactVersion: true, ancestors: visited) else { return false }
      }
      guard let prior=restoration.restoredVersion else { return expected == nil }
      version = prior
    }
    return false
  }

  /// The entire register is the placement owner, including losing concurrent
  /// heads. Only an attested inverse can bridge a freshly authored undo dot.
  func placementIsOwned(_ current: JSONValue?, after: JSONValue?,
    file: String, path: [CollaborationPathComponent]) throws -> Bool {
    guard let address = placementAddress(file, path),
      let value = try current?.decode(WorkspacePlacement.self),
      let expected = try after?.decode(WorkspacePlacement.self),
      value.itemID == address.itemID, expected.itemID == address.itemID else { return false }
    return try placementVersionIsOwned(value, expected: expected, boardID: address.boardID,
      itemID: address.itemID, ancestors: [])
  }

  private func placementVersionIsOwned(_ current: WorkspacePlacement, expected: WorkspacePlacement,
    boardID: UUID, itemID: UUID, ancestors: Set<String>) throws -> Bool {
    let field = "placement:" + placementRecordAddress(boardID: boardID, itemID: itemID)
    var value = current, visited = ancestors
    while true {
      if value == expected { return true }
      let identity = try placementIdentity(value)
      guard visited.insert(identity).inserted else { return false }
      let rows = try currentSQL!.rows("SELECT value FROM action_field_restorations WHERE field=? AND version=? LIMIT 2",
        [.text(field), .text(identity)])
      guard rows.count == 1, let bytes = rows[0][0].blob else { return false }
      let proof = try JSONDecoder().decode(LifecyclePlacementRestoration.self, from: bytes)
      let written = try restoredPlacement(hash: proof.writtenHash, boardID: boardID, itemID: itemID)
      guard written == value else { return false }
      if let beforeHash = proof.requiredBeforeHash, let afterHash = proof.originalAfterHash {
        let before = try restoredPlacement(hash: beforeHash, boardID: boardID, itemID: itemID)
        let after = try restoredPlacement(hash: afterHash, boardID: boardID, itemID: itemID)
        guard try placementVersionIsOwned(before, expected: after, boardID: boardID, itemID: itemID, ancestors: visited) else { return false }
      } else if proof.requiredBeforeHash != nil || proof.originalAfterHash != nil { return false }
      value = try restoredPlacement(hash: proof.restoredHash, boardID: boardID, itemID: itemID)
    }
  }

  private func placementIdentity(_ placement: WorkspacePlacement) throws -> String {
    SHA256.hash(data: try Self.storageEncoder.encode(placement)).map { String(format: "%02x", $0) }.joined()
  }

  private func placementRecordAddress(boardID: UUID, itemID: UUID) -> String {
    "board.json#/boards/@" + boardID.uuidString.lowercased() + "/board/placements/@" + itemID.uuidString.lowercased()
  }

  private func restoredPlacement(hash: String, boardID: UUID, itemID: UUID) throws -> WorkspacePlacement {
    let address = placementRecordAddress(boardID: boardID, itemID: itemID)
    let row = try readLifecycleInverseFragment(hash: hash, address: address)
    guard row.file == "board.json", row.parent == "board.json#/boards/@" + boardID.uuidString.lowercased(),
      row.collection == "board/placements", row.member == itemID.uuidString.lowercased(),
      row.collections.isEmpty, row.position == 0 else {
      throw NotebookStorageError.invalidTransaction("lifecycle placement restoration address")
    }
    let value = try row.value.decode(WorkspacePlacement.self)
    guard value.itemID == itemID, try row.value == .encode(value) else {
      throw NotebookStorageError.invalidTransaction("lifecycle placement restoration identity")
    }
    return value
  }

  func graphicConversionIsAdopted(_ change: CollaborationFieldChange, receipt: CollaborationReceipt,
    files: [String: JSONValue], preserving dependencies: inout [CollaborationPreservedDependency],
    ownershipVersion: ContentFieldVersion? = nil) throws -> Bool {
    let conversion = change.path.suffix(2) == [.field("graphic"), .field("representation")] && change.before == .string("ink")
    let creation = change.before == nil && change.after?["graphic"] != nil
    guard conversion || creation, let version = ownershipVersion ?? change.afterVersion else { return false }
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
        // An initial absence is not adoption; a later independent clearing is.
        // An inverse keeps its own authored dot and proves what it restored.
        let current=collaborationFieldVersion(file:files[change.file],path:path)
        if files[change.file]?.value(at:path[...]) == nil {
          if current == nil { continue }
          // Equality with nil is not ownership: only the exact inverse chain
          // may prove return to the absence present at this conversion.
          let original=JSONValue.object(operation.values).value(at:suffix.map(CollaborationPathComponent.field)[...])
          if original == nil,let current,try fieldVersionIsOwned(current,expected:nil,
            field:restorationKey(file:change.file,path:path),requiringExactVersion:true,ancestors:[]) { continue }
        }
        let field = CollaborationFieldChange(file: change.file, path: path, before: nil, after: nil, afterVersion: version)
        if try !fieldIsOwned(current, by: field) { adopted = true; break }
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

private struct LifecyclePlacementRestoration: Codable {
  let writtenHash: String
  let restoredHash: String
  let requiredBeforeHash: String?
  let originalAfterHash: String?
}

/// Disposable receipt-index data only. Both versions come from the existing
/// authenticated inverse streams; no new durable receipt or history format.
private struct CapturedFieldRestorationCondition: Codable, Equatable {
  let current: ContentFieldVersion
  let expected: ContentFieldVersion
}

private extension ContentFieldVersion {
  var restorationIdentity: String { stamp.revision + (human ? ":human" : ":agent") }
}
