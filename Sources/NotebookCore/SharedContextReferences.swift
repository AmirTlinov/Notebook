import Foundation

extension NotebookStore {
  func firstHumanContextEntry(_ id: UUID) throws -> SharedContextEntry? {
    try requireContextOrderIndex()
    let address = try currentSQL!.rows("SELECT address FROM context_entry_order WHERE context=? AND author='human' ORDER BY counter,actor,address LIMIT 1", [.text(contextFile(id) + "#")]).first?[0].text
    return try address.flatMap { try storedEntry(at: $0) }
  }

  func contextContainsHumanReference(_ reference: CollaborationReference, contextID: UUID) throws -> Bool {
    try requireContextOrderIndex()
    let hash = try collaborationHash(reference)
    guard let row = try currentSQL!.rows("SELECT address,reference_id FROM context_references WHERE context=? AND hash=? AND author='human' LIMIT 1", [.text(contextFile(contextID) + "#"), .text(hash)]).first,
      let entry = try storedEntry(at: row[0].text!), entry.author == .human else { return false }
    guard let indexed = entry.references.first(where: { $0.id.uuidString.lowercased() == row[1].text }),
      indexed == reference else { throw NotebookStorageError.corruptRecord("human context reference") }
    return true
  }

  /// A scope is the same union of historical references, not a newly selected
  /// context or an expanded grant. Repeated identical references cost one seek.
  /// A large union refuses the entire action before any mutation is published.
  func contextReferences(_ id: UUID) throws -> [CollaborationReference] {
    try requireContextOrderIndex()
    guard try hasStoredValue(contextFile(id)) else { throw CollaborationError("context_missing", "Общий фрагмент не найден.") }
    var result: [CollaborationReference] = [], entries: [String: SharedContextEntry] = [:]
    var after = "", bytes: Int64 = 0
    while let row = try currentSQL!.rows("SELECT i.hash,i.address,i.reference_id,length(b.data) FROM context_references i JOIN records r ON r.address=i.address JOIN blobs b ON b.hash=r.hash WHERE i.context=? AND i.hash>? ORDER BY i.hash LIMIT 1", [.text(contextFile(id) + "#"), .text(after)]).first {
      guard result.count < 512 else { throw Self.contextReferenceBudget() }
      after = row[0].text!
      let address = row[1].text!, entry: SharedContextEntry
      if let previous = entries[address] { entry = previous }
      else {
        let size = row[3].integer!
        guard size <= 2_097_152, bytes + size <= 4_194_304 else { throw Self.contextReferenceBudget() }
        guard let stored = try storedEntry(at: address) else { throw NotebookStorageError.corruptRecord(address) }
        entry = stored; entries[address] = stored; bytes += size
      }
      guard let reference = entry.references.first(where: { $0.id.uuidString.lowercased() == row[2].text }),
        try collaborationHash(reference) == after else { throw NotebookStorageError.corruptRecord("context reference: " + address) }
      result.append(reference)
    }
    return result
  }

  private static func contextReferenceBudget() -> CollaborationError {
    .init("context_reference_budget", "Область действия содержит больше 512 разных указаний или 4 МиБ источников. Начните отдельное указание; частичное действие не сохранено.")
  }
}
