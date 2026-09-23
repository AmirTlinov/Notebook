import Foundation

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
        let address=domain.kind == .page
          ? pageFile(domain.id)+"#/drawingData/actions/@"+id.uuidString.lowercased()
          : "spatial-ink.json#/actions/@"+id.uuidString.lowercased()
        guard let row=try storedFragments(address:address,descendants:false).first,
          row.value["isActive"] == .bool(active) else { return false }
        if case .inkRedo(_,let stamp)=entry,
          row.value["stateStamp"].flatMap({ try? $0.decode(VersionStamp.self) }) != stamp { return false }
        if domain.kind == .page { return true }
        return try !currentSQL!.rows("SELECT 1 FROM ink_surfaces WHERE address=? AND kind=? AND owner_id=?",
          [.text(address),.text(domain.kind.rawValue),.text(domain.id.uuidString.lowercased())]).isEmpty
      }
    }
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

  func nativeRedoRestoresSource(_ change: CollaborationFieldChange, version: ContentFieldVersion,
    predecessors: [(repeated: CollaborationReceipt, original: CollaborationReceipt)]) throws -> Bool {
    guard let expected = change.beforeVersion else { return false }
    let owner = collaborationCausalFieldPath(change.path) ?? change.path
    func ownsField(_ field: CollaborationFieldChange) -> Bool {
      field.file == change.file && (collaborationCausalFieldPath(field.path) ?? field.path) == owner
    }
    for (repeated, original) in predecessors where repeated.changes.contains(where: {
      ownsField($0) && $0.afterVersion == version
    }) {
      // Undo/Redo of the first repeated step may itself be repeated before
      // continuing the pending sequence. Follow that action's own addressed
      // lineage, not unrelated history or a same-valued material snapshot.
      var source = original, visited: Set<UUID> = [repeated.id]
      while visited.insert(source.id).inserted {
        guard source.author == .human, source.undo != nil else { break }
        if source.changes.contains(where: { ownsField($0) && $0.afterVersion == expected }) { return true }
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
