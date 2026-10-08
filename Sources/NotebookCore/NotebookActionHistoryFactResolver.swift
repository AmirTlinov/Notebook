import CryptoKit
import Foundation

private enum NotebookActionHistoryClosureMismatch: Error { case unreferenced }

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
    case completeOriginalBody(JSONValue, OriginalAnchor)
    case unprovenClosure(Reason)
  }

  enum Reason: String, Sendable {
    case originalRootAbsent, rootRemoved, externalizedMembership, unreferencedFragments
    case originalAnchorUnavailable, originalAnchorMismatch
  }

  /// Source-local roots read in this observation's borrowed snapshot. These
  /// authenticate the complete logical body, not its birth transaction/actor.
  struct OriginalAnchor: Equatable, Sendable {
    let originalVersion: String
    let originalRootHash: String
    let modelRootHash: String
    let resultRootHash: String
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

/// Both logical reconstruction and raw physical authentication borrow this
/// same acceptance/manifest owner. These references contain no authored body.
struct NotebookActionHistoryReferences {
  let workspaceID: UUID
  let transactionID: UUID
  let manifestHash: String
  let borrowedSnapshotID: UUID
  let manifestFormat: Int
  let manifestByteCount: Int
  let manifestParts: [String]
  let receipts: [UUID: [NotebookActionHistoryObservation.Fragment]]
}

extension NotebookStore {
  /// Resolves one acceptance under the caller's existing readonly SQL snapshot.
  /// Current records, staging indexes and mutable delivery projections never
  /// fill gaps in the original manifest. All work tightens the enclosing lease.
  func actionHistoryFact(transactionID: UUID, manifestHash: String,
    receiptID: UUID? = nil) throws -> NotebookActionHistoryObservation {
    let declared = try actionHistoryReferences(transactionID: transactionID,
      manifestHash: manifestHash, receiptID: receiptID)
    let database = currentSQL!, workspaceID = declared.workspaceID, references = declared.receipts
    var receipts: [NotebookActionHistoryObservation.Receipt] = []
    // Only a source-local original witness admits split-body assembly. Ink
    // expansion borrows its existing owner and one aggregate transaction limit.
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
          disposition = try originalActionHistoryBody(id: id, workspaceID: workspaceID,
            file: file, fragments: fragments, database: database, remainingInkBytes: &remainingInkBytes)
        } else if fragments.count != 1 {
          disposition = .unprovenClosure(.unreferencedFragments)
        } else {
          let expanded = try database.decodedStoredFragment(from: rootPayload!,
            remainingBytes: &remainingInkBytes, budget: "action_history_fact_ink")
          try database.admitNativeFragmentCodec([expanded])
          disposition = .completeSelfContained(try NotebookRecordCodec.decode([expanded], root: rootAddress))
        }
      } else {
        disposition = .unprovenClosure(rootRemoved ? .rootRemoved : .originalRootAbsent)
      }
      receipts.append(.init(id: id, disposition: disposition, fragments: fragments))
    }
    try database.checkReadAllowance()
    return .init(workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash,
      borrowedSnapshotID: declared.borrowedSnapshotID, manifestFormat: declared.manifestFormat, receipts: receipts)
  }

  func actionHistoryReferences(transactionID: UUID, manifestHash: String,
    receiptID: UUID? = nil, workspaceID expectedWorkspaceID: UUID? = nil,
    visitDeclaredRecord: ((NotebookRecordMutation, String?) throws -> Void)? = nil,
    visitDeclaredOrderRoot: ((String) throws -> Void)? = nil) throws -> NotebookActionHistoryReferences {
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
    guard expectedWorkspaceID.map({ $0 == workspaceID }) ?? true else {
      throw NotebookStorageError.invalidTransaction("action history workspace changed")
    }
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
        // Raw physical authentication visits every immutable declaration in
        // manifest order. Only the logical receipt resolver narrows its files.
        if let visitDeclaredRecord {
          guard record.address.utf8.count <= 4_096 else {
            throw NotebookStorageError.limitExceeded("action_history_fact_fragments")
          }
          try visitDeclaredRecord(record, partHash)
        }
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
    for hash in manifest.pageOrderRoots { try visitDeclaredOrderRoot?(hash) }
    try database.checkReadAllowance()
    return .init(workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash,
      borrowedSnapshotID: snapshotID, manifestFormat: manifest.format, manifestByteCount: rootBytes,
      manifestParts: manifest.parts, receipts: references)
  }

  private func originalActionHistoryBody(id: UUID, workspaceID: UUID, file: String,
    fragments: [NotebookActionHistoryObservation.Fragment], database: NotebookSQLConnection,
    remainingInkBytes: inout Int64) throws -> NotebookActionHistoryObservation.Disposition {
    let anchor: NotebookActionHistoryObservation.OriginalAnchor
    do {
      let prefix = "local/action-results/" + id.uuidString.lowercased() + "/"
      guard let original = try actionHistorySourceRoot(prefix + "original.json", database: database) else {
        // No source witness: retain the existing DB29 membership ambiguity.
        return .unprovenClosure(.externalizedMembership)
      }
      guard original.fragment.collections.isEmpty,
        let version = original.fragment.value.string, NotebookPageOrderRegister.validHash(version) else {
        return .unprovenClosure(.originalAnchorMismatch)
      }
      guard let model = try actionHistorySourceRoot(prefix + version + "/model.json", database: database),
        let result = try actionHistorySourceRoot(prefix + version + "/result.json", database: database) else {
        return .unprovenClosure(.originalAnchorUnavailable)
      }
      func protects(_ fragment: NotebookStoredFragment, _ paths: [[String]]) -> Bool {
        !fragment.collections.contains { collection in
          paths.contains { path in collection.path.starts(with: path) || path.starts(with: collection.path) }
        }
      }
      guard protects(model.fragment, [["id"], ["actionVersion"], ["undo"]]),
        protects(result.fragment, [["actionID"], ["actionVersion"], ["basis", "workspaceID"], ["undo"]]),
        UUID(uuidString: model.fragment.value["id"]?.string ?? "") == id,
        model.fragment.value["actionVersion"] == .string(version),
        model.fragment.value["undo"] == nil || model.fragment.value["undo"] == .null,
        UUID(uuidString: result.fragment.value["actionID"]?.string ?? "") == id,
        result.fragment.value["actionVersion"] == .string(version),
        UUID(uuidString: result.fragment.value["basis"]?["workspaceID"]?.string ?? "") == workspaceID,
        result.fragment.value["undo"] == nil || result.fragment.value["undo"] == .null else {
        return .unprovenClosure(.originalAnchorMismatch)
      }
      anchor = .init(originalVersion: version, originalRootHash: original.hash,
        modelRootHash: model.hash, resultRootHash: result.hash)
    } catch NotebookStorageError.blobMissing {
      return .unprovenClosure(.originalAnchorUnavailable)
    } catch is DecodingError {
      return .unprovenClosure(.originalAnchorMismatch)
    }
    guard fragments.allSatisfy({ $0.rawPayload != nil }) else {
      return .unprovenClosure(.unreferencedFragments)
    }
    try database.admitJSONAllocation(bytes: fragments.count * MemoryLayout<NotebookStoredFragment>.stride)
    var expanded: [NotebookStoredFragment] = []
    expanded.reserveCapacity(fragments.count)
    for fragment in fragments {
      try database.checkReadAllowance()
      expanded.append(try database.decodedStoredFragment(from: fragment.rawPayload!,
        remainingBytes: &remainingInkBytes, budget: "action_history_fact_ink"))
    }
    // Admit assembly bookkeeping and output before Codec makes a second tree.
    try database.admitNativeFragmentCodec(expanded, copies: 2)
    let byAddress = Dictionary(uniqueKeysWithValues: expanded.map { ($0.address, $0) })
    guard try actionHistoryHasExactParents(expanded, root: file + "#", database: database) else {
      return .unprovenClosure(.unreferencedFragments)
    }
    let body = try NotebookRecordCodec.decode(expanded, root: file + "#")
    // Hash raw JSON, preserving every unknown field. This allocation charge
    // also pays the subsequent exact Codec closure check, without encoding to
    // measure a cost or renewing the enclosing SQL/JSON allowance.
    try database.admitNativeJSONPhase(body, copies: 3)
    guard body["undo"] == nil || body["undo"] == .null,
      try notebookActionDeliveryVersion(body) == anchor.originalVersion else {
      return .unprovenClosure(.originalAnchorMismatch)
    }
    var emitted = 0
    do {
      try NotebookRecordCodec.visitEncodedFragments(body, file: file) { row in
        try database.checkReadAllowance()
        guard byAddress[row.address] == row else { throw NotebookActionHistoryClosureMismatch.unreferenced }
        emitted += 1
      }
    } catch NotebookActionHistoryClosureMismatch.unreferenced {
      return .unprovenClosure(.unreferencedFragments)
    }
    guard emitted == expanded.count else { return .unprovenClosure(.unreferencedFragments) }
    return .completeOriginalBody(body, anchor)
  }

  func actionHistoryHasExactParents(_ rows: [NotebookStoredFragment], root: String,
    database: NotebookSQLConnection) throws -> Bool {
    let children = Dictionary(grouping: rows.filter { $0.parent != nil }, by: { $0.parent! })
    guard let header = rows.first(where: { $0.address == root }) else { return false }
    var pending: [(NotebookStoredFragment, Int)] = [(header, 0)], visited = 0
    while let (row, depth) = pending.popLast() {
      try database.checkReadAllowance()
      visited += 1
      var collections: [String: (key: String, value: NotebookStoredCollection)] = [:]
      for collection in row.collections {
        try database.checkReadAllowance()
        guard !collection.path.isEmpty else { return false }
        guard collection.path.count <= NotebookJSONAdmission.maximumDepth - depth else {
          throw NotebookStorageError.limitExceeded("json_decode_depth")
        }
        guard let key = try boundedActionHistoryFieldKey(collection.path,
          limit: 4_096 - row.address.utf8.count - 1, database: database) else { return false }
        guard collections.updateValue((key, collection), forKey: key) == nil else { return false }
      }
      for child in children[row.address] ?? [] {
        try database.checkReadAllowance()
        guard let entry = collections[child.collection],
          child.collection.utf8.elementsEqual(entry.key.utf8),
          child.parent?.utf8.elementsEqual(row.address.utf8) == true else { return false }
        let collection = entry.value
        let prefixBytes = row.address.utf8.count + 1 + child.collection.utf8.count
        let expected: String
        switch collection.kind {
        case .array, .dictionary:
          guard let member = try boundedActionHistoryFieldKey([child.member],
            limit: 4_096 - prefixBytes - 2, database: database) else { return false }
          expected = row.address + "/" + child.collection + "/@" + member
        case .value, .pageInk:
          guard prefixBytes <= 4_096 else { return false }
          expected = row.address + "/" + child.collection
        }
        // A short alias must never make Codec create larger canonical address
        // buffers than the admitted input. Check every component before joins.
        guard child.address.utf8.elementsEqual(expected.utf8) else { return false }
        let childDepth = depth + collection.path.count
          + (collection.kind == .array || collection.kind == .dictionary ? 1 : 0)
        guard childDepth <= NotebookJSONAdmission.maximumDepth else {
          throw NotebookStorageError.limitExceeded("json_decode_depth")
        }
        // Each authenticated child's address is strictly below its parent;
        // this traversal cannot cycle, and every input must be consumed once.
        pending.append((child, childDepth))
      }
    }
    return visited == rows.count
  }

  private func boundedActionHistoryFieldKey(_ parts: [String], limit: Int,
    database: NotebookSQLConnection) throws -> String? {
    guard limit >= 0 else { return nil }
    var remaining = limit
    for (partIndex, part) in parts.enumerated() {
      try database.checkReadAllowance()
      if partIndex > 0 {
        guard remaining > 0 else { return nil }
        remaining -= 1
      }
      for (byteIndex, byte) in part.utf8.enumerated() {
        if byteIndex.isMultiple(of: 256) { try database.checkReadAllowance() }
        let escapedBytes = byte == 47 || byte == 126 ? 2 : 1
        guard escapedBytes <= remaining else { return nil }
        remaining -= escapedBytes
      }
    }
    return fieldKey(parts)
  }

  private func actionHistorySourceRoot(_ file: String, database: NotebookSQLConnection) throws
    -> (hash: String, fragment: NotebookStoredFragment)? {
    // Local original/model/result roots are never taken from an incoming
    // manifest or the mutable action_read_models projection. Only this source
    // replica's exact addressed roots under the same readonly cut can witness.
    guard let row = try database.rows("""
      SELECT CASE WHEN typeof(hash)='text' AND length(CAST(hash AS BLOB))=64 THEN hash END
      FROM records WHERE address=?
      """, [.text(file + "#")]).first else { return nil }
    guard let hash = row[0].text, NotebookPageOrderRegister.validHash(hash) else {
      throw NotebookStorageError.corruptRecord(file + "#")
    }
    let data = try authenticatedActionHistoryBlob(hash, database: database)
    let fragment = try database.decodeFragmentEnvelope(data)
    try validateActionHistoryFragment(fragment, address: file + "#", file: file)
    _ = try fragment.inkBodyHashes
    return (hash, fragment)
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

  func validateActionHistoryFragment(_ fragment: NotebookStoredFragment, address: String, file: String) throws {
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
