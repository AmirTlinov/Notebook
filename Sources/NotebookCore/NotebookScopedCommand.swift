import CryptoKit
import Foundation

extension NotebookStoredFragment {
  func replacing(value: JSONValue, collections: [NotebookStoredCollection]? = nil, position: Int? = nil) -> Self {
    .init(address: address, file: file, parent: parent, collection: collection, member: member,
      position: position ?? self.position, value: value, collections: collections ?? self.collections)
  }
}

extension NotebookStore {
  /// The only physical row writer. Whole-owner commands and bounded native
  /// edits both reach it inside the same SQL command/receipt transaction.
  @discardableResult
  func writeFragment(_ fragment: NotebookStoredFragment, data suppliedData: Data? = nil, hash suppliedHash: String? = nil,
    database: NotebookSQLConnection) throws -> Bool {
    let data = try suppliedData ?? Self.storageEncoder.encode(fragment)
    let hash = try suppliedHash ?? database.putBlob(data)
    if suppliedHash != nil { _ = try database.putBlob(data) }
    let previousHash = try database.rows("SELECT hash FROM records WHERE address=?", [.text(fragment.address)]).first?[0].text
    if previousHash == hash { return false }
    if fragment.file == "workspace.json", fragment.collection == "pageOrderNodes" {
      guard previousHash == nil, fragment.parent == "workspace.json#", fragment.position == 0,
        fragment.address == "workspace.json#/pageOrderNodes/@" + fragment.member, fragment.collections.isEmpty else {
        throw NotebookStorageError.invalidTransaction("immutable page order node")
      }
      let node = try fragment.value.decode(NotebookPageOrderNode.self)
      try node.validate()
      guard try node.hash == fragment.member else { throw NotebookStorageError.blobHashMismatch }
      _ = try database.putBlob(node.canonicalData())
    }
    if fragment.file == "workspace.json", fragment.collection == "pageOrders" {
      guard fragment.parent == "workspace.json#", fragment.position == 0,
        UUID(uuidString: fragment.member)?.uuidString.lowercased() == fragment.member,
        fragment.address == "workspace.json#/pageOrders/@" + fragment.member, fragment.collections.isEmpty else {
        throw NotebookStorageError.invalidTransaction("page order address")
      }
      let order = try fragment.value.decode(NotebookPageOrderRegister.self)
      try order.validate()
      if try !database.hasOwner(.capturedPageOrder, fragment.member) {
        let previousRoot: String?
        if let previousHash {
          let old = try JSONDecoder().decode(NotebookStoredFragment.self, from: database.blob(previousHash))
          previousRoot = try old.value.decode(NotebookPageOrderRegister.self).visibleRoot
        } else { previousRoot = nil }
        try database.noteOwner(.capturedPageOrder, fragment.member, value: previousRoot)
      }
      try database.noteOwner(.orderRoot, order.visibleRoot)
      for head in order.heads { try database.noteOwner(.orderRoot, head.valueRoot) }
      try database.noteOwner(.pageOrder, fragment.member)
    }
    if previousHash != nil,
      (fragment.file.hasPrefix("pages/") && fragment.address.contains("#/drawingData/actions/@") && fragment.collection == "samples")
        || (fragment.file == "spatial-ink.json" && fragment.collection == "spans") {
      throw NotebookStorageError.invalidTransaction("stroke samples are immutable")
    }
    if fragment.file == "workspace.json", fragment.collection == "items", let id = UUID(uuidString: fragment.member) { try database.noteOwner(.item, id.uuidString.lowercased()) }
    if fragment.file == "workspace.json", fragment.collection == "pageIDs", let parent = fragment.parent,
      let id = parent.components(separatedBy: "@").last.flatMap(UUID.init(uuidString:)) {
      guard fragment.parent == "workspace.json#/items/@" + id.uuidString.lowercased(),
        UUID(uuidString: fragment.member)?.uuidString.lowercased() == fragment.member,
        fragment.value.string.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() == fragment.member else {
        throw NotebookStorageError.invalidTransaction("page membership identity")
      }
      try database.noteOwner(.item, id.uuidString.lowercased())
      try database.noteOwner(.pageOrder, id.uuidString.lowercased())
      try database.noteOwner(.pageMembership, fragment.address)
      if previousHash == nil { try database.run("INSERT INTO item_page_counts(address,count) VALUES(?,1) ON CONFLICT(address) DO UPDATE SET count=count+1", [.text(parent)]) }
    }
    if previousHash == nil, fragment.file == "workspace.json", fragment.collection == "items" {
      try database.run("UPDATE metadata SET value=CAST(value AS INTEGER)+1 WHERE key='item_count'")
    }
    try database.run("INSERT INTO records(address,file,parent,collection,member,position,hash) VALUES(?,?,?,?,?,?,?) ON CONFLICT(address) DO UPDATE SET parent=excluded.parent,collection=excluded.collection,member=excluded.member,position=excluded.position,hash=excluded.hash", [
      .text(fragment.address), .text(fragment.file), fragment.parent.map(NotebookSQLValue.text) ?? .null,
      .text(fragment.collection), .text(fragment.member), .integer(Int64(fragment.position)), .text(hash)])
    try updateBoardContribution(address: fragment.address, previous: previousHash, next: hash, database: database)
    try updateAddressIndexes(fragment, database: database)
    try updateSearchIndex(fragment, database: database)
    try noteReferenceChange(fragment.address, file: fragment.file, database: database)
    if !Self.localRecord(fragment.file) { try database.recordChange(.init(address: fragment.address, blobHash: hash)) }
    return true
  }

  func removeFragment(_ address: String, database: NotebookSQLConnection) throws {
    guard !address.hasPrefix("workspace.json#/pageOrderNodes/@") else { throw NotebookStorageError.invalidTransaction("immutable page order node") }
    let prefix = address + "/"
    while true {
      let descendants = try database.rows("SELECT address,file,collection,member,hash FROM records WHERE address>=? AND address<? ORDER BY address DESC LIMIT 64",
        [.text(prefix), .text(prefix + "\u{10ffff}")])
      let rows = try descendants.isEmpty
        ? database.rows("SELECT address,file,collection,member,hash FROM records WHERE address=?", [.text(address)]) : descendants
      for row in rows {
        let address = row[0].text!, file = row[1].text!, collection = row[2].text!, member = row[3].text!
        if file == "workspace.json", collection == "pageOrders" { try database.noteOwner(.pageOrder, member) }
        if file == "workspace.json", collection == "items", let id = UUID(uuidString: member) {
          try database.noteOwner(.item, id.uuidString.lowercased())
          try database.run("UPDATE metadata SET value=CAST(value AS INTEGER)-1 WHERE key='item_count'")
        }
        if file == "workspace.json", collection == "pageIDs", let id = address.components(separatedBy: "@").dropLast().last?.split(separator: "/").first {
          try database.noteOwner(.pageOrder, String(id))
          try database.noteOwner(.pageMembership, address)
          try database.run("UPDATE item_page_counts SET count=count-1 WHERE address=? AND count>0", [.text("workspace.json#/items/@" + id)])
        }
        if file == "board.json" {
          let owned = try database.rows("SELECT item_id FROM item_owners WHERE address=?", [.text(address)]).compactMap { $0[0].text.flatMap(UUID.init(uuidString:)) }
          for id in owned { try database.noteOwner(.item, id.uuidString.lowercased()) }
        }
        try updateBoardContribution(address: address, previous: row[4].text, next: nil, database: database)
        try noteReferenceChange(address, file: file, database: database)
        try database.run("DELETE FROM records WHERE address=?", [.text(address)])
        if !Self.localRecord(file) { try database.recordChange(.init(address: address, blobHash: nil)) }
      }
      if descendants.isEmpty { return }
    }
  }

  private func projectionDelta(before: JSONValue?, after: JSONValue?, current: JSONValue?) throws -> JSONValue? {
    if before == after { return current }
    if current == before || current == after { return after }
    if let current, let after, let oldVersion = try? current.decode(ContentFieldVersion.self),
      let nextVersion = try? after.decode(ContentFieldVersion.self) { return try .encode(oldVersion.joining(nextVersion)) }
    if let current, let after, let oldStamp = try? current.decode(VersionStamp.self),
      let nextStamp = try? after.decode(VersionStamp.self) { return try .encode(max(oldStamp, nextStamp)) }
    if case .object(let old) = before, case .object(let next) = after, case .object(let stored) = current {
      var result = stored
      for key in Set(old.keys).union(next.keys) where old[key] != next[key] {
        result[key] = try projectionDelta(before: old[key], after: next[key], current: stored[key])
      }
      return .object(result)
    }
    throw NotebookStorageError.transactionConflict
  }

  /// Baseline identity defines the command's scope. Missing unseen members of
  /// either projection are not sent to the writer and cannot become tombstones.
  func publishProjectionEdits(file: String, before: JSONValue, after: JSONValue) throws {
    let old = Dictionary(uniqueKeysWithValues: try NotebookRecordCodec.encode(before, file: file).map { ($0.address, $0) })
    let next = Dictionary(uniqueKeysWithValues: try NotebookRecordCodec.encode(after, file: file).map { ($0.address, $0) })
    guard let database = currentSQL, database.writable else { throw NotebookStorageError.readOnlyTransaction }
    // A projection's ordinals are local to its selected members. Only an
    // actual sequence edit permutes their durable slots; unseen rows retain
    // theirs, and simultaneously inserted members retain authored order.
    func sequenceGroups(_ fragments: [String: NotebookStoredFragment]) -> [String: [NotebookStoredFragment]] {
      Dictionary(grouping: fragments.values.filter { $0.parent != nil && !$0.collection.hasSuffix("collaboration/fields") && !["pageOrders", "pageOrderNodes"].contains($0.collection) },
        by: { $0.parent! + "|" + $0.collection })
    }
    let oldGroups = sequenceGroups(old), nextGroups = sequenceGroups(next)
    var positions: [String: Int] = [:]
    for (group, members) in nextGroups {
      let ordered = members.sorted { $0.position == $1.position ? $0.address < $1.address : $0.position < $1.position }
      let prior = (oldGroups[group] ?? []).sorted { $0.position == $1.position ? $0.address < $1.address : $0.position < $1.position }
      guard ordered.map(\.address) != prior.map(\.address), let first = ordered.first else { continue }
      var slots: [Int] = []
      let current = try ordered.compactMap { row -> (String, Int)? in
        guard let position = try database.rows("SELECT position FROM records WHERE address=?", [.text(row.address)]).first?[0].integer else { return nil }
        slots.append(Int(position)); return (row.address, Int(position))
      }
      let priorIDs = Set(prior.map(\.address)), nextIDs = Set(ordered.map(\.address)), currentIDs = Set(current.map(\.0))
      let retainedBefore = prior.map(\.address).filter { nextIDs.contains($0) }
      let retainedAfter = ordered.map(\.address).filter { priorIDs.contains($0) }
      let added = ordered.filter { !priorIDs.contains($0.address) }
      // Reading a bounded projection may sort its members differently from
      // their durable slots. Appending/removing without moving retained members
      // does not author that presentation order back into the shared sequence.
      if retainedBefore == retainedAfter,
        ordered.map(\.address) == retainedAfter + added.map(\.address) {
        let missing = added.filter { !currentIDs.contains($0.address) }
        if !missing.isEmpty {
          let maximum = Int(try database.rows("SELECT COALESCE(MAX(position),-1) FROM records WHERE parent=? AND collection=?", [.text(first.parent!), .text(first.collection)]).first![0].integer!)
          guard maximum <= Int.max - missing.count else { throw NotebookStorageError.limitExceeded("member_sequence") }
          for (offset, member) in missing.enumerated() { positions[member.address] = maximum + offset + 1 }
        }
        continue
      }
      let expectedOrder = prior.map(\.address).filter { currentIDs.contains($0) }
      let actualOrder = current.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.0)
      let completedOrder = ordered.map(\.address).filter { currentIDs.contains($0) }
      // An exact retry may already have committed the desired permutation.
      // Otherwise an explicit insertion/reorder still compares its baseline.
      guard expectedOrder == actualOrder.filter({ priorIDs.contains($0) }) || completedOrder == actualOrder else {
        throw NotebookStorageError.transactionConflict
      }
      if slots.count < ordered.count {
        let maximum = Int(try database.rows("SELECT COALESCE(MAX(position),-1) FROM records WHERE parent=? AND collection=?", [.text(first.parent!), .text(first.collection)]).first![0].integer!)
        guard maximum <= Int.max - (ordered.count - slots.count) else { throw NotebookStorageError.limitExceeded("member_sequence") }
        slots += (1...(ordered.count - slots.count)).map { maximum + $0 }
      }
      for (member, slot) in zip(ordered, slots.sorted()) { positions[member.address] = slot }
    }
    let addresses = Set(old.keys).union(next.keys)
    let depths = Dictionary(uniqueKeysWithValues: addresses.map { ($0, $0.filter { $0 == "/" }.count) })
    for address in addresses.sorted(by: { depths[$0] == depths[$1] ? $0 < $1 : depths[$0]! > depths[$1]! }) {
      let previous = old[address], edited = next[address]
      guard previous?.value != edited?.value || previous?.collections != edited?.collections || positions[address] != nil else { continue }
      let stored = try storedFragments(address: address, descendants: false).first
      if let edited {
        if stored == nil, previous != nil { throw NotebookStorageError.transactionConflict }
        let value = try projectionDelta(before: previous?.value, after: edited.value, current: stored?.value)
        guard let value else { throw NotebookStorageError.invalidTransaction("projection value") }
        let position = (edited.collection.hasSuffix("collaboration/fields") || ["pageOrders", "pageOrderNodes"].contains(edited.collection)) ? 0 : try positions[address] ?? stored?.position ?? Int(database.rows("SELECT COALESCE(MAX(position),-1)+1 FROM records WHERE parent=? AND collection=?", [edited.parent.map(NotebookSQLValue.text) ?? .null, .text(edited.collection)]).first![0].integer!)
        let changed = try writeFragment(edited.replacing(value: value, position: position), database: database)
        if changed, !edited.member.isEmpty, !edited.collection.hasSuffix("collaboration/fields"), let parent = edited.parent {
          let prefix = edited.collection.components(separatedBy: "/").last! + "/" + edited.member + "/"
          let collection = edited.collection.hasPrefix("board/") ? "board/collaboration/fields" : "collaboration/fields"
          for row in try database.rows("SELECT address,hash FROM records WHERE parent=? AND collection=? AND member>=? AND member<?", [.text(parent), .text(collection), .text(prefix), .text(prefix + "\u{10ffff}")]) {
            try database.recordChange(.init(address: row[0].text!, blobHash: row[1].text!))
          }
        }
      } else if let stored {
        guard stored.value == previous?.value else { throw NotebookStorageError.transactionConflict }
        try removeFragment(address, database: database)
      }
    }
  }

  @discardableResult
  public func saveBoardEdits(before: BoardHierarchy, after: BoardHierarchy) throws -> BoardHierarchy {
    guard before.rootBoardID == after.rootBoardID,
      Set(before.boards.map(\.id)).count == before.boards.count, Set(after.boards.map(\.id)).count == after.boards.count else {
      throw NotebookStorageError.invalidTransaction("board projection")
    }
    return try commandTransaction {
      try publishProjectionEdits(file: "board.json", before: .encode(before), after: .encode(after))
      return after
    }
  }

  @discardableResult
  public func saveWorkspaceEdits(before: WorkspaceIndex, after: WorkspaceIndex,
    boardBefore: BoardHierarchy, boardAfter: BoardHierarchy,
    pages: [PageDocument] = [], documents: [DocumentDocument] = [], states: [DocumentStateJournal] = []) throws -> NotebookWorkspaceHeader {
    guard before.rootBoardID == after.rootBoardID, after.rootBoardID == boardAfter.rootBoardID,
      Set(pages.map(\.id)).count == pages.count, Set(documents.map(\.id)).count == documents.count,
      Set(states.map(\.id)).count == states.count else { throw NotebookStorageError.invalidTransaction("workspace projection") }
    try commandTransaction {
      for page in pages { try savePage(page) }
      for document in documents { try saveDocument(document) }
      for state in states { try saveDocumentState(state) }
      try publishProjectionEdits(file: "workspace.json", before: .encode(before), after: .encode(after))
      _ = try saveBoardEdits(before: boardBefore, after: boardAfter)
      for item in after.items {
        for id in item.pageIDs where try !hasStoredValue(pageFile(id)) { throw NotebookStorageError.corruptRecord(pageFile(id)) }
        if item.kind == .document {
          guard try hasStoredValue(documentFile(item.id)), try hasStoredValue(stateFile(item.id)) else { throw NotebookStorageError.corruptRecord(documentFile(item.id)) }
        }
      }
      if let presence = try? loadPresence() { try savePresence(presence.selecting(itemID: after.selectedItemID, pageID: after.selectedPageID)) }
    }
    return try workspaceHeader()
  }

  @discardableResult
  public func deleteWorkspaceItem(itemID: UUID, expected: VersionStamp? = nil, actor: UUID) throws -> NotebookWorkspaceHeader {
    try commandTransaction {
      let header = try workspaceHeader()
      guard header.itemCount > 1 else { throw NotebookStorageError.invalidTransaction("workspace retains one item") }
      guard let item = try readItemHeader(itemID), let parent = try readBoardItem(itemID) else { throw CocoaError(.fileNoSuchFile) }
      if let expected, parent.board.stamp != expected { throw NotebookStorageError.transactionConflict }
      if item.kind == .board {
        let address = "board.json#/boards/@" + itemID.uuidString.lowercased()
        let members = try currentSQL!.rows("SELECT 1 FROM records WHERE parent=? AND collection IN ('board/freeItems','board/stacks','board/elements') LIMIT 1", [.text(address)])
        let ink = try readSpatialInk(surfaces: [.board(itemID)])
        guard members.isEmpty, !ink.containsEditableInk(on: .board(itemID)) else { throw NotebookStoreError.boardContainsContent(itemID) }
        try removeFragment(address, database: currentSQL!)
      }
      var board = parent.board
      guard board.deleteItem(itemID, actor: actor) else { throw NotebookStorageError.transactionConflict }
      let old = BoardHierarchy(rootBoardID: header.rootBoardID, boards: [parent], stamp: parent.board.stamp)
      let next = BoardHierarchy(rootBoardID: header.rootBoardID, boards: [.init(id: parent.id, board: board, portalCamera: parent.portalCamera, portalStamp: parent.portalStamp)], stamp: board.stamp)
      _ = try saveBoardEdits(before: old, after: next)
      let nodeAddress = "board.json#/boards/@" + parent.id.uuidString.lowercased()
      // The UI projection deliberately contains no cover programs. Deletion
      // still removes every addressed cover source and leaves causal tombstones.
      while let element = try currentSQL!.rows("SELECT r.address,r.member FROM spatial_entries s JOIN records r ON r.address=s.address WHERE s.kind='coverElement' AND s.board_id=? AND s.owner_id=? ORDER BY s.entry_id LIMIT 1", [.text(parent.id.uuidString.lowercased()), .text(itemID.uuidString.lowercased())]).first {
        let key = fieldKey(["elements", element[1].text!, "exists"])
        let address = nodeAddress + "/board/collaboration/fields/@" + fieldKey([key])
        let previous = try storedFragments(address: address, descendants: false).first?.value.decode(ContentFieldVersion.self)
        let version = ContentFieldVersion(stamp: board.stamp, human: true, previous: previous)
        try writeFragment(.init(address: address, file: "board.json", parent: nodeAddress, collection: "board/collaboration/fields", member: key, position: 0, value: try .encode(version), collections: []), database: currentSQL!)
        try removeFragment(element[0].text!, database: currentSQL!)
      }
      let itemAddress = "workspace.json#/items/@" + itemID.uuidString.lowercased()
      // Enumerate the durable memberships, not the UI's finite projection.
      // Each body and membership is removed before requesting the next 64.
      while true {
        let pages = try currentSQL!.rows("SELECT member,address FROM records WHERE parent=? AND collection='pageIDs' ORDER BY member LIMIT 64", [.text(itemAddress)])
        if pages.isEmpty { break }
        for row in pages {
          guard let id = row[0].text.flatMap(UUID.init(uuidString:)), let address = row[1].text else {
            throw NotebookStorageError.corruptRecord(itemAddress)
          }
          try removeFragment(pageFile(id) + "#", database: currentSQL!)
          try removeFragment(address, database: currentSQL!)
        }
      }
      try removeFragment(itemAddress, database: currentSQL!)
      guard let root = try storedFragments(address: "workspace.json#", descendants: false).first,
        let stamp = header.stamp.advanced(by: actor) else { throw NotebookStorageError.invalidTransaction("workspace clock") }
      try writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(stamp))), database: currentSQL!)
      let key = fieldKey(["items", itemID.uuidString.lowercased(), "exists"])
      let address = "workspace.json#/collaboration/fields/@" + fieldKey([key])
      let oldVersion = try storedFragments(address: address, descendants: false).first?.value.decode(ContentFieldVersion.self)
      let version = ContentFieldVersion(stamp: stamp, human: true, previous: oldVersion)
      try writeFragment(.init(address: address, file: "workspace.json", parent: "workspace.json#", collection: "collaboration/fields", member: key, position: 0, value: try .encode(version), collections: []), database: currentSQL!)
      try publishRecords(writes: [:], removals: item.kind == .document ? [documentFile(itemID), stateFile(itemID)] : [])
      if let presence = try? loadPresence(), presence.selectedItemID == itemID,
        let replacement = try readItemHeaders(limit: 1).first {
        try savePresence(presence.selecting(itemID: replacement.id, pageID: replacement.firstPageID))
      }
    }
    return try workspaceHeader()
  }
}
