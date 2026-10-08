import CryptoKit
import Foundation

/// The exact legacy receipt fragments declared by one accepted occurrence.
/// Completeness describes the JSON body only; this is neither a birth proof
/// nor a seal, causal cut, inverse or restoration authority.
struct NotebookActionHistoryObservation: Equatable, Sendable {
  let workspaceID: UUID
  let transactionID: UUID
  let manifestHash: String
  let borrowedSnapshotID: UUID
  let manifestFormat: Int
  let receipts: [Receipt]

  struct Receipt: Equatable, Sendable {
    let id: UUID
    let disposition: Disposition
    let fragments: [Fragment]
  }

  enum Disposition: Equatable, Sendable {
    case completeSelfContained(JSONValue)
    case unprovenClosure(Reason)
  }

  enum Reason: String, Sendable {
    case originalRootAbsent, rootRemoved, externalizedMembership, unreferencedFragments
  }

  struct Fragment: Equatable, Sendable {
    let address: String
    /// nil denotes a declaration directly in the accepted root manifest.
    let manifestPartHash: String?
    /// A nil hash and payload preserve an original removal declaration.
    let blobHash: String?
    let rawPayload: Data?
  }
}

extension NotebookStore {
  /// Resolves one acceptance under the caller's existing readonly SQL snapshot.
  /// Current records, staging indexes and mutable delivery projections never
  /// fill gaps in the original manifest. All work tightens the enclosing lease.
  func actionHistoryFact(transactionID: UUID, manifestHash: String,
    receiptID: UUID? = nil) throws -> NotebookActionHistoryObservation {
    guard let database = currentSQL, !database.writable,
      let snapshotID = database.readSnapshotIdentity else { throw NotebookStorageError.readOnlyTransaction }
    guard NotebookPageOrderRegister.validHash(manifestHash) else {
      throw NotebookStorageError.invalidTransaction("action history manifest hash")
    }
    try database.limitReads(.agentCommand)
    let workspace = try database.rows("""
      SELECT CASE WHEN typeof(value)='text' AND length(CAST(value AS BLOB))=36
        THEN value END FROM metadata WHERE key='workspace_id'
      """).first?[0].text.flatMap(UUID.init(uuidString:))
    guard let workspaceID = workspace else { throw NotebookStorageError.corruptRecord("action history inventory workspace") }
    guard let accepted = try NotebookActionHistoryInventory.occurrence(in: database,
      workspaceID: workspaceID, transactionID: transactionID) else {
      throw NotebookStorageError.invalidTransaction("unaccepted action history occurrence")
    }
    guard accepted.manifestHash == manifestHash else { throw NotebookStorageError.transactionConflict }
    let rootBytes = try admitActionHistoryManifest(hash: manifestHash,
      byteCount: accepted.localJournal?.manifestByteCount, database: database)
    let sequence = accepted.localJournal?.sequence ?? accepted.firstReceived!.senderSequence
    let change = NotebookDurableChange(sequence: sequence, transactionID: transactionID,
      manifestHash: manifestHash, byteCount: rootBytes)
    let manifest = try actionHistoryManifest(change)
    var references: [UUID: [NotebookActionHistoryObservation.Fragment]] = [:]
    if let receiptID { references[receiptID] = [] }
    var addresses = Set<String>()
    func collect(_ records: [NotebookRecordMutation], partHash: String?) throws {
      for (index, record) in records.enumerated() {
        if index.isMultiple(of: 64) { try database.checkReadAllowance() }
        guard record.address.hasPrefix("collaboration/actions/") else { continue }
        guard record.address.utf8.count <= 4_096 else {
          throw NotebookStorageError.limitExceeded("action_history_fact_fragments")
        }
        let file = String(record.address.split(separator: "#", maxSplits: 1)[0])
        let key = String(file.dropFirst("collaboration/actions/".count).dropLast(".json".count))
        guard let id = UUID(uuidString: key), key == id.uuidString.lowercased() else {
          throw NotebookStorageError.invalidTransaction("action history receipt address")
        }
        if let receiptID, receiptID != id { continue }
        guard addresses.count < 4_096 else {
          throw NotebookStorageError.limitExceeded("action_history_fact_fragments")
        }
        guard addresses.insert(record.address).inserted else { throw NotebookStorageError.transactionConflict }
        if references[id] == nil {
          guard references.count < 64 else { throw NotebookStorageError.limitExceeded("action_history_fact_receipts") }
          references[id] = []
        }
        references[id]!.append(.init(address: record.address, manifestPartHash: partHash,
          blobHash: record.blobHash, rawPayload: nil))
      }
    }
    try collect(manifest.records, partHash: nil)
    for hash in manifest.parts {
      _ = try admitActionHistoryManifest(hash: hash, byteCount: nil, database: database)
      let part = try actionHistoryManifest(change, partHash: hash)
      guard part.format == manifest.format else { throw NotebookStorageError.invalidTransaction("action history manifest part format") }
      try collect(part.records, partHash: hash)
    }
    var receipts: [NotebookActionHistoryObservation.Receipt] = []
    // Ink expansion uses its existing typed owner and the same aggregate read
    // budget. Unproven split fragments retain references, without guessing a body.
    var remainingInkBytes: Int64 = 32 * 1_024 * 1_024
    for id in references.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      let file = "collaboration/actions/" + id.uuidString.lowercased() + ".json"
      let rootAddress = file + "#"
      var fragments: [NotebookActionHistoryObservation.Fragment] = []
      var root: NotebookStoredFragment?, rootPayload: Data?, rootRemoved = false
      for reference in references[id]!.sorted(by: { $0.address < $1.address }) {
        try database.checkReadAllowance()
        let data: Data?
        if let hash = reference.blobHash {
          data = try authenticatedActionHistoryBlob(hash, database: database)
          let fragment: NotebookStoredFragment
          do { fragment = try database.decodeFragmentEnvelope(data!) }
          catch is DecodingError { throw NotebookStorageError.corruptRecord(reference.address) }
          try validateActionHistoryFragment(fragment, address: reference.address, file: file)
          _ = try fragment.inkBodyHashes
          if reference.address == rootAddress { root = fragment; rootPayload = data }
        } else {
          data = nil
          if reference.address == rootAddress { rootRemoved = true }
        }
        fragments.append(.init(address: reference.address, manifestPartHash: reference.manifestPartHash,
          blobHash: reference.blobHash, rawPayload: data))
      }
      let disposition: NotebookActionHistoryObservation.Disposition
      if let root {
        guard UUID(uuidString: root.value["id"]?.string ?? "") == id,
          UUID(uuidString: root.value["action"]?["id"]?.string ?? "") == id else {
          throw NotebookStorageError.invalidTransaction("action history receipt identity")
        }
        if !root.collections.isEmpty {
          // DB29 headers commit path/kind, never member count or hashes. Even
          // an empty collection and a missing last child have identical headers.
          disposition = .unprovenClosure(.externalizedMembership)
        } else if fragments.count != 1 {
          disposition = .unprovenClosure(.unreferencedFragments)
        } else {
          let expanded = try database.decodedStoredFragment(from: rootPayload!,
            remainingBytes: &remainingInkBytes, budget: "action_history_fact_ink")
          disposition = .completeSelfContained(try NotebookRecordCodec.decode([expanded], root: rootAddress))
        }
      } else {
        disposition = .unprovenClosure(rootRemoved ? .rootRemoved : .originalRootAbsent)
      }
      receipts.append(.init(id: id, disposition: disposition, fragments: fragments))
    }
    try database.checkReadAllowance()
    return .init(workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash,
      borrowedSnapshotID: snapshotID, manifestFormat: manifest.format, receipts: receipts)
  }

  private func actionHistoryManifest(_ change: NotebookDurableChange, partHash: String? = nil) throws -> NotebookChangeManifest {
    do { return try validatedManifest(change, partHash: partHash, historical: true) }
    catch is DecodingError { throw NotebookStorageError.corruptRecord(partHash ?? change.manifestHash) }
  }

  private func admitActionHistoryManifest(hash: String, byteCount: Int?, database: NotebookSQLConnection) throws -> Int {
    // Authenticate/admit before the shared manifest validator allocates typed
    // records. Its reread observes these same immutable bytes in this SQL cut;
    // both physical copies consume the enclosing connection's finite allowance.
    let data = try authenticatedActionHistoryBlob(hash, database: database)
    guard byteCount.map({ $0 == data.count }) ?? true else { throw NotebookStorageError.blobHashMismatch }
    try database.admitJSONDecode(data)
    return data.count
  }

  private func authenticatedActionHistoryBlob(_ hash: String, database: NotebookSQLConnection) throws -> Data {
    guard let row = try database.rows("SELECT typeof(data),length(data) FROM blobs WHERE hash=?", [.text(hash)]).first else {
      throw NotebookStorageError.blobMissing(hash)
    }
    guard row[0].text == "blob", let bytes = row[1].integer else { throw NotebookStorageError.corruptRecord(hash) }
    guard (0...Int64(8 * 1_024 * 1_024)).contains(bytes) else { throw NotebookStorageError.limitExceeded("action_history_fact_blob") }
    let data = try database.blob(hash)
    guard NotebookHexEncoding.encode(SHA256.hash(data: data)) == hash else { throw NotebookStorageError.blobHashMismatch }
    try database.checkReadAllowance()
    return data
  }

  private func validateActionHistoryFragment(_ fragment: NotebookStoredFragment, address: String, file: String) throws {
    let root = file + "#"
    guard fragment.address == address, fragment.file == file,
      fragment.position >= 0, fragment.value.isValid else { throw NotebookStorageError.invalidTransaction("action history fragment identity") }
    if let parent = fragment.parent {
      guard parent == root || parent.hasPrefix(root + "/"), fragment.address.hasPrefix(parent + "/"),
        !fragment.collection.isEmpty else { throw NotebookStorageError.invalidTransaction("action history fragment parent") }
    } else {
      guard fragment.address == root, fragment.collection.isEmpty, fragment.member.isEmpty,
        fragment.position == 0 else { throw NotebookStorageError.invalidTransaction("action history fragment root") }
    }
  }
}
