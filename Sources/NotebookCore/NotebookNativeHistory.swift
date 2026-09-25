import Foundation

extension CollaborationAction {
  /// An item disappears from its cover domain; its inverse remains reachable
  /// on the surviving parent board. Material edits keep their surface owner.
  public var nativeHistoryDomains: Set<PencilUndoHistory.Domain> {
    Set(operations.map { operation in
      if operation.kind == .deleteItem, let parent = operation.target.boardID { return .board(parent) }
      return .init(operation.target)
    })
  }
}

public struct NotebookCodeInkState: Sendable {
  public let fragmentID: UUID
  public let result: NotebookSpatialInkResult
  public init(fragmentID: UUID, result: NotebookSpatialInkResult) { self.fragmentID = fragmentID; self.result = result }
}

public struct NotebookCodeInkHistory: Sendable {
  public let stamp: VersionStamp
  public let undo: [PencilUndoHistory.Entry]
  public let redo: [PencilUndoHistory.Entry]
  public let states: [UUID: NotebookCodeInkState]
}

/// Device-local history is an ordered directory of native action identities.
/// The same transaction writes material and its history; replicas never invent
/// local Undo entries from a peer's receipt or a wall-clock timestamp.
extension NotebookStore {
  public func nativeHistory(domain: PencilUndoHistory.Domain, actor: UUID) throws -> [PencilUndoHistory.Entry] {
    try readTransaction { _ in
      try rawNativeHistory(domain:domain,actor:actor,redo:false).filter { try nativeHistoryEntry($0,domain:domain,active:true) }
    }
  }

  public func nativeRedoHistory(domain: PencilUndoHistory.Domain, actor: UUID) throws -> [PencilUndoHistory.Entry] {
    try readTransaction { _ in
      var available:[PencilUndoHistory.Entry]=[]
      for entry in try rawNativeHistory(domain:domain,actor:actor,redo:true).reversed() {
        guard try nativeHistoryEntry(entry,domain:domain,active:false) else { break }
        available.append(entry)
      }
      return available.reversed()
    }
  }

  private func rawNativeHistory(domain:PencilUndoHistory.Domain,actor:UUID,redo:Bool) throws -> [PencilUndoHistory.Entry] {
    let key=Self.nativeHistoryKey(domain:domain,actor:actor,redo:redo)
    guard let value=try currentSQL!.rows("SELECT value FROM metadata WHERE key=?",[.text(key)]).first?[0].text else { return [] }
    guard value.utf8.count <= 65_536 else { throw NotebookStorageError.corruptRecord("native history") }
    let entries=try JSONDecoder().decode([PencilUndoHistory.Entry].self,from:Data(value.utf8))
    guard entries.count <= 32,entries.allSatisfy({ entry in
      switch entry {
      case .ink(let ids): return !ids.isEmpty && ids.count <= 32
      case .inkRedo(let ids,_): return ids.count == 1
      case .command: return true
      }
    }) else { throw NotebookStorageError.corruptRecord("native history") }
    return entries
  }

  private func nativeHistoryEntry(_ entry:PencilUndoHistory.Entry,domain:PencilUndoHistory.Domain,
    active:Bool) throws -> Bool {
      // The local directory does not overrule material or a peer's inverse.
      // Check bounded headers only; never decode ink measurements to find Undo.
    switch entry {
    case .command(let id):
      let address="collaboration/actions/"+id.uuidString.lowercased()+".json#"
      guard let row=try currentSQL!.rows("SELECT status FROM metadata_index WHERE address=? AND kind='action'",[.text(address)]).first else { return false }
      guard let status=row[0].text,["active","undone"].contains(status) else {
        throw NotebookStorageError.corruptRecord("native history phase: "+address)
      }
      return (status == "active") == active
    case .ink(let ids), .inkRedo(let ids,_):
      return try ids.contains { id in
        let address: String
        if case .target(.page, let pageID) = domain {
          address = pageFile(pageID) + "#/drawingData/actions/@" + id.uuidString.lowercased()
        } else { address = "spatial-ink.json#/actions/@" + id.uuidString.lowercased() }
        guard let row=try storedFragments(address:address,descendants:false).first,
          row.value["isActive"] == .bool(active) else { return false }
        if case .inkRedo(_,let stamp)=entry,
          row.value["stateStamp"].flatMap({ try? $0.decode(VersionStamp.self) }) != stamp { return false }
        switch domain {
        case .target(.page, _): return true
        case .target(let kind, let owner):
          return try !currentSQL!.rows("SELECT 1 FROM ink_surfaces WHERE address=? AND kind=? AND owner_id=?",
            [.text(address), .text(kind.rawValue), .text(owner.uuidString.lowercased())]).isEmpty
        case .codeFile(let file): return try codeInkOwner(address: address, file: file) != nil
        }
      }
    }
  }

  /// The same saved order, with only the bounded action headers needed to
  /// accept an inverse synchronously. No scan of file fragments or ink samples.
  public func codeInkHistory(file: NotebookFileAddress, actor: UUID) throws -> NotebookCodeInkHistory {
    guard file.isValid else { throw NotebookStorageError.invalidTransaction("code history file") }
    return try readTransaction { _ in
      let domain = PencilUndoHistory.Domain.codeFile(file)
      let stamp = try readSpatialInk(surfaces: []).stamp
      let undo = try nativeHistory(domain: domain, actor: actor)
      let redo = try nativeRedoHistory(domain: domain, actor: actor)
      var ids = Set<UUID>(), states: [UUID: NotebookCodeInkState] = [:]
      for entry in undo + redo {
        switch entry {
        case .ink(let actions), .inkRedo(let actions, _): ids.formUnion(actions)
        case .command: break
        }
      }
      for id in ids {
        let address = "spatial-ink.json#/actions/@" + id.uuidString.lowercased()
        guard let owner = try codeInkOwner(address: address, file: file),
          let record = try storedFragments(address: address, descendants: false).first else { continue }
        let header = try record.value.decode(SpatialInkActionHeader.self)
        guard header.isValid, header.id == id else { throw NotebookStorageError.corruptRecord(address) }
        states[id] = .init(fragmentID: owner, result: .init(actionID: id, creationStamp: header.stamp,
          isActive: header.isActive, stateStamp: header.stateStamp, journalStamp: stamp))
      }
      return .init(stamp: stamp, undo: undo, redo: redo, states: states)
    }
  }

  private func codeInkOwner(address: String, file: NotebookFileAddress) throws -> UUID? {
    try currentSQL!.rows("""
      SELECT s.owner_id FROM ink_surfaces s
      WHERE s.address=? AND s.kind='codeFragment' AND EXISTS (
        SELECT 1 FROM code_fragment_files f WHERE f.file_id=? AND f.fragment_id=s.owner_id
      ) LIMIT 1
      """, [.text(address), .text(file.id)]).first?[0].text.flatMap(UUID.init(uuidString:))
  }

  func recordNativeHistory(_ entry: PencilUndoHistory.Entry, domain: PencilUndoHistory.Domain,
    actor: UUID, removing: Bool = false, stateStamp: VersionStamp? = nil) throws {
    var history=try nativeHistoryDirectory(domain:domain,actor:actor)
    switch entry {
    case .command(let id):
      if removing { history.didUndoCommand(domain: domain, actionID: id) }
      else { history.recordCommand(domain: domain, actionID: id) }
    case .ink(let ids):
      if removing {
        guard let stateStamp else { throw NotebookStorageError.invalidTransaction("native redo gate") }
        history.didRemoveContribution(ids, for: domain, stateStamp: stateStamp)
      }
      else {
        guard ids.count == 1, let id = ids.first else { throw NotebookStorageError.invalidTransaction("native contact history") }
        history.recordAction(domain: domain, actionID: id)
      }
    case .inkRedo: throw NotebookStorageError.invalidTransaction("native redo entry")
    }
    try writeNativeHistoryDirectory(history,domain:domain,actor:actor)
  }

  func repeatNativeHistoryCommand(originalID:UUID,actionID:UUID,domain:PencilUndoHistory.Domain,actor:UUID) throws {
    var history=try nativeHistoryDirectory(domain:domain,actor:actor)
    guard history.recordRepeatedCommand(domain:domain,originalID:originalID,actionID:actionID) else {
      throw CollaborationError("revision_conflict","Повтор недоступен: порядок истории изменился.")
    }
    try writeNativeHistoryDirectory(history,domain:domain,actor:actor)
  }

  func nativeRedoHead(domain:PencilUndoHistory.Domain,actor:UUID) throws -> PencilUndoHistory.Entry? {
    guard let head=try rawNativeHistory(domain:domain,actor:actor,redo:true).last,
      try nativeHistoryEntry(head,domain:domain,active:false) else { return nil }
    return head
  }

  /// Only the bounded device-local order can authorize the next Redo. The
  /// receipts remain the evidence; this read creates no replacement clocks,
  /// mutable acceptance gates or second history. It is needed only when an
  /// earlier Redo has advanced the original inverse's exact field version.
  func nativeRepeatedPredecessors(domains: Set<PencilUndoHistory.Domain>, actor: UUID) throws
    -> [(repeated: CollaborationReceipt, original: CollaborationReceipt)] {
    var ids = Set<UUID>(), result: [(CollaborationReceipt, CollaborationReceipt)] = []
    for domain in domains {
      for case .command(let id) in try nativeHistory(domain: domain, actor: actor) where ids.insert(id).inserted {
        let repeated = try collaborationAction(id)
        guard repeated.author == .human, repeated.undo == nil, let source = repeated.redoOf,
          source != repeated.id else { continue }
        let original = try collaborationAction(source)
        guard original.author == .human, original.undo != nil else { continue }
        result.append((repeated, original))
      }
    }
    return result
  }

  func nativeRedoRestoresSource(_ change: CollaborationFieldChange, receipt: CollaborationReceipt, version: ContentFieldVersion,
    predecessors: [(repeated: CollaborationReceipt, original: CollaborationReceipt)]) throws -> Bool {
    let owner = collaborationCausalFieldPath(change.path) ?? change.path
    func ownsField(_ field: CollaborationFieldChange) -> Bool {
      field.file == change.file && (collaborationCausalFieldPath(field.path) ?? field.path) == owner
    }
    // The pending step may itself be a repeated command. Its immediate before
    // version then names its own older inverse, not the predecessor's original
    // result. Follow that exact saved lineage as well; equal geometry is not proof.
    var expected: [ContentFieldVersion] = [], target = receipt, targets = Set<UUID>()
    while targets.insert(target.id).inserted {
      guard target.author == .human, target.undo != nil else { break }
      expected += target.changes.filter(ownsField).compactMap(\.beforeVersion)
      if let owner = placementAddress(change.file, change.path),
        target.action.operations.contains(where: { $0.kind == .deleteItem && $0.target.id == owner.itemID }),
        let basis = try nativeDeletedPlacementBasis(receipt: target, boardID: owner.boardID, itemID: owner.itemID) {
        expected.append(basis.before.winner.version)
      }
      guard let previous = target.redoOf else { break }
      target = try collaborationAction(previous)
    }
    guard !expected.isEmpty else { return false }
    for (repeated, original) in predecessors where repeated.changes.contains(where: {
      ownsField($0) && $0.afterVersion == version
    }) {
      // Undo/Redo of the first repeated step may itself be repeated before
      // continuing the pending sequence. Follow that action's own addressed
      // lineage, not unrelated history or a same-valued material snapshot.
      var source = original, visited: Set<UUID> = [repeated.id]
      while visited.insert(source.id).inserted {
        guard source.author == .human, source.undo != nil else { break }
        if source.changes.contains(where: { field in
          ownsField(field) && field.afterVersion.map(expected.contains) == true
        }) { return true }
        guard let previous = source.redoOf else { break }
        source = try collaborationAction(previous)
      }
    }
    return false
  }

  func requireNativeInkRedoGate(_ id:UUID,domain:PencilUndoHistory.Domain,
    actor:UUID,expected:VersionStamp) throws {
    let redo=try rawNativeHistory(domain:domain,actor:actor,redo:true)
    guard redo.last == .inkRedo([id],expected) else {
      throw CollaborationError("revision_conflict","Штрих изменился после отмены; повтор недоступен.")
    }
  }

  private func nativeHistoryDirectory(domain:PencilUndoHistory.Domain,actor:UUID) throws -> PencilUndoHistory {
    var history=PencilUndoHistory()
    history.restore(try rawNativeHistory(domain:domain,actor:actor,redo:false),for:domain)
    history.restoreRedo(try rawNativeHistory(domain:domain,actor:actor,redo:true),for:domain)
    return history
  }

  private func writeNativeHistoryDirectory(_ history:PencilUndoHistory,domain:PencilUndoHistory.Domain,actor:UUID) throws {
    let value = String(decoding: try Self.storageEncoder.encode(history.entries(for: domain)), as: UTF8.self)
    let redo=String(decoding:try Self.storageEncoder.encode(history.redoEntries(for:domain)),as:UTF8.self)
    for (key,stored) in [(Self.nativeHistoryKey(domain:domain,actor:actor,redo:false),value),
      (Self.nativeHistoryKey(domain:domain,actor:actor,redo:true),redo)] {
      try currentSQL!.run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value!=excluded.value",
        [.text(key),.text(stored)])
    }
  }

  private static func nativeHistoryKey(domain: PencilUndoHistory.Domain, actor: UUID,redo:Bool) -> String {
    (redo ? "native_redo:" : "native_history:") + actor.uuidString.lowercased() + ":" + domain.key
  }
}

public struct NotebookSpatialInkHistoryState: Sendable {
  public let result: NotebookSpatialInkResult
  public let surfaces: Set<SurfaceID>
  public init(result: NotebookSpatialInkResult, surfaces: Set<SurfaceID>) { self.result = result; self.surfaces = surfaces }
}

extension NotebookStore {
  /// Cold Undo/Redo retains exact gates and physical owners, never old samples.
  public func spatialInkHistoryStates(ids: Set<UUID>) throws -> [UUID: NotebookSpatialInkHistoryState] {
    guard ids.count <= 32_768 else { throw NotebookStorageError.limitExceeded("ink_history_headers") }
    return try readTransaction { _ in
      let stamp = try readSpatialInk(surfaces: []).stamp
      var states: [UUID: NotebookSpatialInkHistoryState] = [:]
      for id in ids {
        let address = "spatial-ink.json#/actions/@" + id.uuidString.lowercased()
        guard let record = try storedFragments(address: address, descendants: false).first else { continue }
        let header = try record.value.decode(SpatialInkActionHeader.self)
        guard header.isValid, header.id == id else { throw NotebookStorageError.corruptRecord(address) }
        let surfaces = try currentSQL!.rows("SELECT kind,owner_id FROM ink_surfaces WHERE address=?", [.text(address)]).map { row -> SurfaceID in
          guard let kind = row[0].text.flatMap(SurfaceKind.init(rawValue:)), let owner = row[1].text.flatMap(UUID.init(uuidString:)) else { throw NotebookStorageError.corruptRecord(address) }
          return .init(kind: kind, ownerID: owner)
        }
        states[id] = .init(result: .init(actionID: id, creationStamp: header.stamp, isActive: header.isActive, stateStamp: header.stateStamp, journalStamp: stamp), surfaces: Set(surfaces))
      }
      return states
    }
  }
}
