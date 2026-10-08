import CryptoKit
import Foundation

/// RAW evidence in one borrowed source cut. Complete means authenticated
/// declared physical membership; no logical JSON, original birth, actor,
/// execution, cleanup or joint-seal authority follows from these hashes.
public struct NotebookHistoryPhysicalClosure: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let transactionID: UUID
  public let manifestHash: String
  public let borrowedSnapshotID: UUID
  public let manifestFormat: Int
  public let manifest: Blob
  public let manifestParts: [Blob]
  public let declaredRecords: DeclaredRecords
  public let receipts: [Receipt]

  public struct Blob: Codable, Equatable, Sendable {
    public let hash: String
    public let byteCount: Int64
  }
  public enum Reason: String, Codable, Sendable {
    case rootAbsent, rootRemoved, removedFragment, missingBlob, unreferencedFragments
    case unsupportedDependency, originalAnchorUnavailable, originalAnchorMismatch, orphanAnchor
  }
  public enum Status: Codable, Equatable, Sendable {
    case authenticatedDeclaredClosure
    case unproven(Reason)
  }
  /// Every manifest record, including removals and files without receipts.
  /// Receipt payloads borrow their already authenticated receipt proof; all
  /// other payloads and their owned dependencies are scrubbed in this cut.
  public struct DeclaredRecords: Codable, Equatable, Sendable {
    public let status: Status
    public let recordCount: Int
    public let removalCount: Int
    public let payloadBytes: Int64
    public let recordSetHash: String?
    /// Manifest order roots and non-receipt owned dependencies. Receipts
    /// independently commit their own dependency sets below.
    public let dependencyCount: Int
    public let dependencyBytes: Int64
    public let dependencySetHash: String?
  }
  public enum LogicalBinding: String, Codable, Sendable {
    case notEvaluated, externalizedMembership
  }
  public struct Receipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let status: Status
    public let logicalBinding: LogicalBinding
    public let fragmentCount: Int
    public let fragmentBytes: Int64
    /// Framed addresses, removal declarations and authenticated raw hashes.
    public let fragmentSetHash: String?
    public let dependencyCount: Int
    public let dependencyBytes: Int64
    public let dependencySetHash: String?
    public let sourceOriginal: SourceOriginal
  }
  public enum SourceOriginalStatus: Codable, Equatable, Sendable {
    case authenticatedSourceLocalRoots
    case unproven(Reason)
  }
  public struct SourceOriginal: Codable, Equatable, Sendable {
    public let status: SourceOriginalStatus
    public let originalVersion: String?
    public let original: Blob?
    public let model: Blob?
    public let result: Blob?
  }
}

extension NotebookStore {
  /// No connection, BEGIN, cache or budget renewal. The caller supplies its
  /// validated workspace and already owns a readonly transaction.
  func actionHistoryPhysicalClosure(workspaceID: UUID, transactionID: UUID,
    manifestHash: String, receiptID: UUID? = nil) throws -> NotebookHistoryPhysicalClosure {
    guard let database = currentSQL, !database.writable else { throw NotebookStorageError.readOnlyTransaction }
    let declaredReader = NotebookHistoryPhysicalReader(store: self, database: database)
    var beganDeclared = false
    func beginDeclared() throws {
      if !beganDeclared {
        try declaredReader.beginDeclared(workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash)
        beganDeclared = true
      }
    }
    let refs = try actionHistoryReferences(transactionID: transactionID, manifestHash: manifestHash,
      receiptID: receiptID, workspaceID: workspaceID,
      visitDeclaredRecord: { record, part in
        try beginDeclared()
        let file = String(record.address.split(separator: "#", maxSplits: 1)[0])
        let delegated = file.hasPrefix("collaboration/actions/")
          && (receiptID == nil || file == "collaboration/actions/" + receiptID!.uuidString.lowercased() + ".json")
        try declaredReader.declaredRecord(record, partHash: part, delegatesReceipt: delegated)
      }, visitDeclaredOrderRoot: { try beginDeclared(); try declaredReader.declaredOrderRoot($0) })
    try beginDeclared()
    try database.admitJSONAllocation(bytes: 4_096 + refs.manifestParts.count * 192 + refs.receipts.count * 512)
    var parts: [NotebookHistoryPhysicalClosure.Blob] = []
    // The shared manifest owner has already authenticated and validated these
    // parts, including scope, format, uniqueness and their original order.
    for hash in refs.manifestParts { parts.append(.init(hash: hash, byteCount: try historyPhysicalBlobSize(hash))) }
    var receipts: [NotebookHistoryPhysicalClosure.Receipt] = []
    for id in refs.receipts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      try database.checkReadAllowance()
      let reader = NotebookHistoryPhysicalReader(store: self, database: database)
      receipts.append(try reader.receipt(id, references: refs.receipts[id]!, workspaceID: workspaceID,
        transactionID: transactionID, manifestHash: manifestHash))
    }
    try database.checkReadAllowance()
    return .init(workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash,
      borrowedSnapshotID: refs.borrowedSnapshotID, manifestFormat: refs.manifestFormat,
      manifest: .init(hash: manifestHash, byteCount: Int64(refs.manifestByteCount)),
      manifestParts: parts, declaredRecords: try declaredReader.declaredProof(receipts: receipts), receipts: receipts)
  }

  fileprivate func historyPhysicalBlobSize(_ hash: String) throws -> Int64 {
    guard NotebookPageOrderRegister.validHash(hash) else { throw NotebookStorageError.invalidTransaction("history physical hash") }
    guard let row = try currentSQL!.rows("SELECT typeof(data),length(data) FROM blobs WHERE hash=?", [.text(hash)]).first else {
      throw NotebookStorageError.blobMissing(hash)
    }
    guard row[0].text == "blob", let size = row[1].integer else { throw NotebookStorageError.corruptRecord(hash) }
    guard (0...Int64(256 * 1_024 * 1_024)).contains(size) else { throw NotebookStorageError.limitExceeded("history_physical_blob") }
    return size
  }
}

private final class NotebookHistoryPhysicalReader {
  typealias Proof = NotebookHistoryPhysicalClosure
  typealias Fields = [[String]: Data]
  private let store: NotebookStore
  private let database: NotebookSQLConnection
  private var dependencyHashes: Set<String> = [], visiting: Set<String> = []
  private var inkKinds: [String: Bool] = [:], programHashes: Set<String> = []
  private var orderNodes: [String: (height: Int, count: Int)] = [:]
  private var dependencyDigest = SHA256(), dependencyBytes: Int64 = 0
  private var unsupportedDependency = false
  private var declaredDigest = SHA256()
  private var declaredAddresses = Set<Data>()
  private var declaredCount = 0, declaredRemovals = 0, delegatedCount = 0
  private var declaredBytes: Int64 = 0
  private var declaredReason: Proof.Reason?
  private let headerPaths = [["address"], ["file"], ["parent"], ["collection"], ["member"],
    ["position"], ["collections"], ["inkBodies"]]

  init(store: NotebookStore, database: NotebookSQLConnection) { self.store = store; self.database = database }

  func beginDeclared(workspaceID: UUID, transactionID: UUID, manifestHash: String) throws {
    try frame(["notebook.history-raw.declared.v1", workspaceID.uuidString.lowercased(),
      transactionID.uuidString.lowercased(), manifestHash], into: &declaredDigest)
    try frame(["notebook.history-raw.declared-dependencies.v1", workspaceID.uuidString.lowercased(),
      transactionID.uuidString.lowercased(), manifestHash], into: &dependencyDigest)
  }

  func declaredRecord(_ record: NotebookRecordMutation, partHash: String?, delegatesReceipt: Bool) throws {
    try database.checkReadAllowance()
    guard declaredCount < 512 * 16_384 else { throw NotebookStorageError.limitExceeded("history_physical_records") }
    // Exact UTF-8 addresses, not Swift's canonically equivalent String keys.
    // Only fixed-size fingerprints survive the current manifest-part window.
    try database.admitJSONAllocation(bytes: record.address.utf8.count + 512)
    let addressHash = Data(SHA256.hash(data: Data(record.address.utf8)))
    guard declaredAddresses.insert(addressHash).inserted else { throw NotebookStorageError.transactionConflict }
    declaredCount += 1
    try frame([partHash ?? "", record.address, record.blobHash == nil ? "removed" : "blob",
      record.blobHash ?? ""], into: &declaredDigest)
    guard let hash = record.blobHash else {
      declaredRemovals += 1; try frame(["0"], into: &declaredDigest); return
    }
    if delegatesReceipt { delegatedCount += 1 }
    do {
      let size = try store.historyPhysicalBlobSize(hash)
      declaredBytes = try add(declaredBytes, size)
      try frame([String(size)], into: &declaredDigest)
      if delegatesReceipt { return } // receipt() authenticates these exact references once
      let file = String(record.address.split(separator: "#", maxSplits: 1)[0])
      let (blob, fields, shape) = try selectedBlob(hash, paths: headerPaths + dependencyPaths(file: file, address: record.address),
        projectCausal: causalContentAddress(file: file, address: record.address))
      let header = try decodeHeader(fields, address: record.address, file: file)
      try fragmentDependencies(header, hash: hash, size: blob.byteCount, fields: fields, headShape: shape)
      if file.hasPrefix("collaboration/actions/"), header.parent == nil {
        let key = String(file.dropFirst("collaboration/actions/".count).dropLast(".json".count))
        guard let id = UUID(uuidString: key), key == id.uuidString.lowercased(),
          try decode(UUID.self, ["value", "id"], in: fields) == id,
          try decode(UUID.self, ["value", "action", "id"], in: fields) == id else {
          throw NotebookStorageError.invalidTransaction("history physical receipt identity")
        }
        for path in [["value", "lifecycleInverse"], ["value", "undo", "restorationInverse"]] {
          if let data = fields[path], !isNull(data) { try inverseClosure(try decode(data), actionID: id) }
        }
      }
    } catch NotebookStorageError.blobMissing {
      declaredReason = declaredReason ?? .missingBlob
    }
  }

  func declaredOrderRoot(_ hash: String) throws {
    do { _ = try orderClosure(hash) }
    catch NotebookStorageError.blobMissing { declaredReason = declaredReason ?? .missingBlob }
  }

  func declaredProof(receipts: [Proof.Receipt]) throws -> Proof.DeclaredRecords {
    try database.checkReadAllowance()
    var authenticatedReceiptPayloads = 0
    for receipt in receipts {
      // An explicitly requested ID absent from this manifest contributes no
      // declaration. Its receipt remains rootAbsent, without altering the
      // independently authenticated records of the actual transaction.
      if receipt.fragmentCount == 0 { continue }
      switch receipt.status {
      case .authenticatedDeclaredClosure: authenticatedReceiptPayloads += receipt.fragmentCount
      case .unproven(let reason): declaredReason = declaredReason ?? reason
      }
    }
    if declaredReason == nil, authenticatedReceiptPayloads != delegatedCount {
      throw NotebookStorageError.invalidTransaction("history physical delegated receipt membership")
    }
    if unsupportedDependency { declaredReason = declaredReason ?? .unsupportedDependency }
    return .init(status: declaredReason.map(Proof.Status.unproven) ?? .authenticatedDeclaredClosure,
      recordCount: declaredCount, removalCount: declaredRemovals, payloadBytes: declaredBytes,
      recordSetHash: declaredReason == nil ? NotebookHexEncoding.encode(declaredDigest.finalize()) : nil,
      dependencyCount: dependencyHashes.count, dependencyBytes: dependencyBytes,
      dependencySetHash: declaredReason == nil ? NotebookHexEncoding.encode(dependencyDigest.finalize()) : nil)
  }

  private struct Header {
    let address: String, file: String, parent: String?, collection: String, member: String
    let position: Int
    let collections: [NotebookStoredCollection]
    let inkBodies: [[String]]
    func fragment(_ value: JSONValue = .null) -> NotebookStoredFragment {
      .init(address: address, file: file, parent: parent, collection: collection,
        member: member, position: position, value: value, collections: collections)
    }
  }

  func receipt(_ id: UUID, references: [NotebookActionHistoryObservation.Fragment], workspaceID: UUID,
    transactionID: UUID, manifestHash: String) throws -> Proof.Receipt {
    let file = "collaboration/actions/" + id.uuidString.lowercased() + ".json", root = file + "#"
    try database.admitJSONAllocation(bytes: 4_096 + references.count * MemoryLayout<NotebookStoredFragment>.stride * 8)
    var headers: [NotebookStoredFragment] = [], digest = SHA256(), bytes: Int64 = 0
    var reason: Proof.Reason?, rootFound = false, split = false
    let scope = [workspaceID.uuidString.lowercased(), transactionID.uuidString.lowercased(), manifestHash, id.uuidString.lowercased()]
    try frame(["notebook.history-physical-fragments.v1"] + scope, into: &digest)
    try frame(["notebook.history-physical-dependencies.v1"] + scope, into: &dependencyDigest)
    for reference in references.sorted(by: { $0.address.utf8.lexicographicallyPrecedes($1.address.utf8) }) {
      try database.checkReadAllowance()
      try frame([reference.address, reference.manifestPartHash ?? "", reference.blobHash ?? ""], into: &digest)
      guard let hash = reference.blobHash else {
        reason = reference.address == root ? .rootRemoved : (reason ?? .removedFragment); continue
      }
      do {
        let paths = headerPaths + [["value", "id"], ["value", "action", "id"],
          ["value", "lifecycleInverse"], ["value", "undo", "restorationInverse"]]
        let (blob, fields, _) = try selectedBlob(hash, paths: paths)
        bytes = try add(bytes, blob.byteCount)
        let header = try decodeHeader(fields, address: reference.address, file: file)
        headers.append(header.fragment())
        if reference.address == root {
          rootFound = true; split = !header.collections.isEmpty
          guard try decode(UUID.self, ["value", "id"], in: fields) == id,
            try decode(UUID.self, ["value", "action", "id"], in: fields) == id else {
            throw NotebookStorageError.invalidTransaction("history physical receipt identity")
          }
          for path in [["value", "lifecycleInverse"], ["value", "undo", "restorationInverse"]] {
            if let data = fields[path], !isNull(data) {
              let inverse: NotebookLifecycleInverseReference = try decode(data)
              try inverseClosure(inverse, actionID: id)
            }
          }
        }
        try inkReferences(header, hash: hash, size: blob.byteCount)
      } catch NotebookStorageError.blobMissing { reason = reason ?? .missingBlob }
    }
    if !rootFound, reason == nil { reason = .rootAbsent }
    if reason == nil, try !store.actionHistoryHasExactParents(headers, root: root, database: database) {
      reason = .unreferencedFragments
    }
    if reason == nil, unsupportedDependency { reason = .unsupportedDependency }
    let source = try sourceOriginal(id, workspaceID: workspaceID)
    try database.checkReadAllowance()
    return .init(id: id, status: reason.map(Proof.Status.unproven) ?? .authenticatedDeclaredClosure,
      logicalBinding: split ? .externalizedMembership : .notEvaluated,
      fragmentCount: references.count, fragmentBytes: bytes,
      fragmentSetHash: reason == nil ? NotebookHexEncoding.encode(digest.finalize()) : nil,
      dependencyCount: dependencyHashes.count, dependencyBytes: dependencyBytes,
      dependencySetHash: reason == nil ? NotebookHexEncoding.encode(dependencyDigest.finalize()) : nil,
      sourceOriginal: source)
  }

  private func selectedBlob(_ hash: String, paths: [[String]], projectCausal: Bool = false)
    throws -> (Proof.Blob, Fields, NotebookJSONBlobWindow.ArrayShape?) {
    let size = try store.historyPhysicalBlobSize(hash)
    var hasher = SHA256(), fields: Fields = [:]
    try database.admitJSONAllocation(bytes: 1_024)
    let heads = projectCausal ? NotebookJSONBlobWindow.ArrayMetadata(path: ["value", "heads"],
      elementPaths: [["stamp", "counter"], ["stamp", "actor"], ["human"], ["hasValue"],
        ["value", "programPackage"], ["value", "resource"]],
      maximumElements: 256, unsignedIntegerPaths: [["stamp", "counter"]]) : nil
    let selectedPaths = projectCausal ? paths + [["value", "stamp", "counter"], ["value", "stamp", "actor"],
      ["value", "human"], ["value", "observed"]] : paths
    let integerPaths = projectCausal ? [["value", "stamp", "counter"], ["value", "observed"]] : []
    let reader = NotebookJSONBlobWindow(count: size, check: database.checkReadAllowance,
      admitCapture: database.admitJSONAllocation) { [store] offset, length in
      let chunk = try store.readBlobChunk(hash: hash, offset: offset, maxBytes: Int(length))
      hasher.update(data: chunk); return chunk
    }
    try reader.selectMetadata(paths: selectedPaths, maximumCaptureBytes: 1_024 * 1_024,
      array: heads, unsignedIntegerPaths: integerPaths) { path, data in
      try self.database.admitJSONAllocation(bytes: 128 + path.count * MemoryLayout<String>.stride)
      guard fields.updateValue(data, forKey: path) == nil else { throw NotebookStorageError.corruptRecord("duplicate history metadata") }
    }
    guard NotebookHexEncoding.encode(hasher.finalize()) == hash else { throw NotebookStorageError.blobHashMismatch }
    return (.init(hash: hash, byteCount: size), fields, heads?.shape)
  }

  private func decode<T: Decodable>(_ type: T.Type, _ path: [String], in fields: Fields) throws -> T {
    guard let data = fields[path] else { throw NotebookStorageError.corruptRecord("history physical metadata") }
    return try decode(data)
  }
  private func decode<T: Decodable>(_ data: Data) throws -> T {
    try database.admitJSONDecode(data)
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch is DecodingError { throw NotebookStorageError.corruptRecord("history physical metadata") }
  }
  private func isNull(_ data: Data) -> Bool { data == Data("null".utf8) }

  private func decodeHeader(_ fields: Fields, address: String, file: String) throws -> Header {
    let header = Header(address: try decode(String.self, ["address"], in: fields),
      file: try decode(String.self, ["file"], in: fields),
      parent: try fields[["parent"]].map { try decode($0) as String? } ?? nil,
      collection: try decode(String.self, ["collection"], in: fields),
      member: try decode(String.self, ["member"], in: fields),
      position: try decode(Int.self, ["position"], in: fields),
      collections: try decode([NotebookStoredCollection].self, ["collections"], in: fields),
      inkBodies: try fields[["inkBodies"]].map { try decode($0) as [[String]] } ?? [])
    guard header.address.utf8.elementsEqual(address.utf8), header.file.utf8.elementsEqual(file.utf8), header.position >= 0,
      [header.address, header.file, header.collection, header.member].allSatisfy({ $0.utf8.count <= 4_096 }),
      header.parent.map({ $0.utf8.count <= 4_096 }) ?? true else {
      throw NotebookStorageError.invalidTransaction("history physical fragment identity")
    }
    try store.validateActionHistoryFragment(header.fragment(), address: address, file: file)
    return header
  }

  private func inkReferences(_ header: Header, hash: String, size: Int64) throws {
    guard !header.inkBodies.isEmpty else { return }
    try database.admitJSONAllocation(bytes: header.inkBodies.count * 256)
    guard header.inkBodies.count <= 4_096, Set(header.inkBodies).count == header.inkBodies.count,
      header.inkBodies.allSatisfy({ $0.count <= 512 && $0.allSatisfy { $0.utf8.count <= 4_096 } }) else {
      throw NotebookStorageError.invalidTransaction("history physical ink paths")
    }
    // The immutable envelope was already authenticated. Only declared exact
    // paths are selected in this second sparse pass; arbitrary inkBody keys
    // elsewhere are authored content, not references.
    let paths = header.inkBodies.map { ["value"] + $0 }
    var found = Set<[String]>()
    let reader = NotebookJSONBlobWindow(count: size, check: database.checkReadAllowance,
      admitCapture: database.admitJSONAllocation) { [store] offset, length in
      try store.readBlobChunk(hash: hash, offset: offset, maxBytes: Int(length))
    }
    try reader.selectMetadata(paths: paths, maximumCaptureBytes: 256) { path, data in
      let value: JSONValue = try self.decode(data)
      guard let body = value["inkBody"]?.string, NotebookPageOrderRegister.validHash(body),
        let revision = value["revision"]?.string, UUID(uuidString: revision) != nil,
        case .object(let fields) = value, fields.count == 2 else {
        throw NotebookStorageError.invalidTransaction("history physical ink reference")
      }
      try self.database.admitJSONAllocation(bytes: 192 + path.count * MemoryLayout<String>.stride)
      found.insert(path)
      try self.inkClosure(body)
    }
    guard found.count == paths.count else { throw NotebookStorageError.invalidTransaction("history physical ink membership") }
  }

  private func dependencyPaths(file: String, address: String) -> [[String]] {
    if file.hasPrefix("collaboration/actions/") {
      return [["value", "lifecycleInverse"], ["value", "undo", "restorationInverse"],
        ["value", "id"], ["value", "action", "id"]]
    }
    if file == "workspace.json", address.hasPrefix("workspace.json#/pageOrders/@")
      || address.hasPrefix("workspace.json#/pageOrderNodes/@") { return [["value"]] }
    if file.hasPrefix("pages/") || file == "board.json" { return [["value", "programPackage"]] }
    if file.hasPrefix("documents/") { return [["value", "resource"]] }
    return []
  }

  private func causalContentAddress(file: String, address: String) -> Bool {
    // This selects metadata only. The authenticated envelope below must still
    // name the actual owned causal collection/member before it can use it.
    if file.hasPrefix("pages/") || file.hasPrefix("documents/") {
      let prefix = file + "#/collaboration/fields/@"
      return address.hasPrefix(prefix + "elements~1") && address.hasSuffix("~1content")
        || (file.hasPrefix("documents/") && address.hasPrefix(prefix + "files~1") && address.hasSuffix("~1content"))
    }
    return file == "board.json" && address.contains("/board/collaboration/fields/@elements~1")
      && address.hasSuffix("~1content")
  }

  private func causalVersion(_ fields: Fields, shape: NotebookJSONBlobWindow.ArrayShape) throws -> ContentFieldVersion {
    let count: Int
    if case .elements(let length) = shape {
      guard (1...256).contains(length) else { throw NotebookStorageError.invalidTransaction("history physical causal heads") }
      count = length
    } else { count = 0 }
    try database.admitJSONAllocation(bytes: 1_024 + count * 512)
    // The clock bytes must reach UInt64 decoding unchanged. A JSONValue
    // intermediate would round invalid or adjacent high integer literals.
    func write(_ literal: (String) throws -> Void, _ field: ([String]) throws -> Void) throws {
      func stamp(_ prefix: [String]) throws {
        try literal("{\"counter\":"); try field(prefix + ["stamp", "counter"])
        try literal(",\"actor\":"); try field(prefix + ["stamp", "actor"]); try literal("}")
      }
      try literal("{\"stamp\":"); try stamp(["value"])
      try literal(",\"human\":"); try field(["value", "human"])
      try literal(",\"observed\":"); try field(["value", "observed"])
      switch shape {
      case .absent: break
      case .null: try literal(",\"heads\":null")
      case .elements:
        try literal(",\"heads\":[")
        for index in 0..<count {
          try database.checkReadAllowance()
          let prefix = ["value", "heads", String(index)]
          if index > 0 { try literal(",") }
          try literal("{\"stamp\":"); try stamp(prefix)
          try literal(",\"human\":"); try field(prefix + ["human"])
          try literal(",\"hasValue\":"); try field(prefix + ["hasValue"])
          try literal(",\"value\":{")
          var emitted = false
          for key in ["programPackage", "resource"] where fields[prefix + ["value", key]] != nil {
            if emitted { try literal(",") }
            try literal("\"" + key + "\":"); try field(prefix + ["value", key]); emitted = true
          }
          try literal("}}")
        }
        try literal("]")
      }
      try literal("}")
    }
    var bytes = 0
    func measure(_ size: Int) throws {
      let sum = bytes.addingReportingOverflow(size)
      guard !sum.overflow else { throw NotebookStorageError.limitExceeded("history_physical_metadata") }
      bytes = sum.partialValue
    }
    try write({ try measure($0.utf8.count) }, { path in
      guard let data = fields[path] else { throw NotebookStorageError.corruptRecord("history physical metadata") }
      try measure(data.count)
    })
    guard bytes <= (Int.max - 1_024) / 2 else { throw NotebookStorageError.limitExceeded("history_physical_metadata") }
    try database.admitJSONAllocation(bytes: bytes * 2 + 1_024)
    var data = Data(); data.reserveCapacity(bytes)
    try write({ data.append(contentsOf: $0.utf8) }, { data.append(fields[$0]!) })
    // Authored text/state stays in the authenticated raw payload. Only the
    // exact clock and owned program/resource references are materialized here.
    return try decode(data)
  }

  /// The same owned references as lifecycle inverse discovery. Sparse raw
  /// reads never treat arbitrary hash-looking authored strings as a graph.
  private func fragmentDependencies(_ header: Header, hash: String, size: Int64, fields: Fields,
    headShape: NotebookJSONBlobWindow.ArrayShape?) throws {
    try inkReferences(header, hash: hash, size: size)
    let causal = header.member.split(separator: "/")
    let isCausal = ((header.file.hasPrefix("pages/") || header.file.hasPrefix("documents/"))
      && header.collection == "collaboration/fields")
      || (header.file == "board.json" && header.collection == "board/collaboration/fields")
    if isCausal, causal.count == 3, causal[2] == "content",
      causal[0] == "elements" || (header.file.hasPrefix("documents/") && causal[0] == "files") {
      guard let headShape else { unsupportedDependency = true; return }
      let version = try causalVersion(fields, shape: headShape)
      guard version.isValid else { throw NotebookStorageError.invalidTransaction("history physical causal source") }
      // These existing owners enumerate every losing retained authored value.
      // Their retained-reference arrays and typed resource decoding consume
      // the same aggregate allowance before that processing allocates.
      try database.admitJSONAllocation(bytes: version.writeFootprint().decodingBytes)
      if causal[0] == "elements" {
        for program in try store.programPackageHashes(in: version).sorted() { try programClosure(program) }
      } else {
        for part in try store.documentResourceParts(in: version) {
          try opaqueDependency(part.sha256, expectedBytes: Int64(part.byteCount), role: "resource-part")
        }
      }
      return
    }
    if header.file == "workspace.json", header.collection == "pageOrders" || header.collection == "pageOrderNodes" {
      let value: JSONValue
      if let data = fields[["value"]] { value = try decode(data) }
      else {
        let (_, orderFields, _) = try selectedBlob(hash, paths: [["value"]])
        value = try decode(JSONValue.self, ["value"], in: orderFields)
      }
      for order in try store.lifecycleInverseOrderRoots(header.fragment(value)) { _ = try orderClosure(order) }
    } else {
      try database.admitJSONAllocation(bytes: 512)
      var value: [String: JSONValue] = [:]
      for key in ["programPackage", "resource"] {
        if let data = fields[["value", key]] { value[key] = try decode(data) }
      }
      let fragment = header.fragment(.object(value))
      for program in try store.programPackageHashes(in: fragment).sorted() { try programClosure(program) }
      for part in try store.documentResourceParts(in: fragment) {
        try opaqueDependency(part.sha256, expectedBytes: Int64(part.byteCount), role: "resource-part")
      }
    }
  }

  private func inverseClosure(_ reference: NotebookLifecycleInverseReference, actionID: UUID) throws {
    let root = try store.readLifecycleInverseRoot(reference: reference, actionID: actionID)
    try noteDependency(.init(hash: reference.rootHash, byteCount: store.historyPhysicalBlobSize(reference.rootHash)), role: "inverse-root")
    var count = 0, previous = ""
    for (ordinal, hash) in root.parts.enumerated() {
      try database.checkReadAllowance()
      let part = try store.readLifecycleInversePart(hash: hash, actionID: actionID, ordinal: ordinal)
      try noteDependency(.init(hash: hash, byteCount: store.historyPhysicalBlobSize(hash)), role: "inverse-part-" + String(ordinal))
      for record in part.records {
        try database.checkReadAllowance()
        guard previous.utf8.lexicographicallyPrecedes(record.address.utf8), count < root.recordCount else {
          throw NotebookStorageError.invalidTransaction("history physical inverse order")
        }
        for hash in [record.beforeHash, record.afterHash].compactMap({ $0 }) {
          let file = String(record.address.split(separator: "#", maxSplits: 1)[0])
          let (blob, fields, shape) = try selectedBlob(hash, paths: headerPaths + dependencyPaths(file: file, address: record.address),
            projectCausal: causalContentAddress(file: file, address: record.address))
          let header = try decodeHeader(fields, address: record.address, file: file)
          try noteDependency(blob, role: "inverse-fragment")
          try fragmentDependencies(header, hash: hash, size: blob.byteCount, fields: fields, headShape: shape)
        }
        previous = record.address; count += 1
      }
    }
    guard count == root.recordCount else { throw NotebookStorageError.invalidTransaction("history physical inverse count") }
  }

  private func inkClosure(_ hash: String, depth: Int = 0, isNode: Bool = false) throws {
    if let kind = inkKinds[hash] {
      guard kind == isNode else { throw NotebookStorageError.corruptRecord(hash) }; return
    }
    try database.checkReadAllowance()
    guard inkKinds.count < InkStoredBody.maximumNodes + 1 else { throw NotebookStorageError.limitExceeded("history_physical_ink_nodes") }
    try database.admitJSONAllocation(bytes: 768)
    guard depth <= 128, visiting.insert(hash).inserted else { throw NotebookStorageError.invalidTransaction("history physical ink cycle") }
    defer { visiting.remove(hash) }
    let size = try store.historyPhysicalBlobSize(hash)
    var prefix = Data(), data = Data(), hasher = SHA256(), offset: Int64 = 0
    // NIN1 is <=32KiB and NIB2 exactly74 bytes. A large NIB1 is hashed
    // window-by-window and only its fixed prefix survives.
    if size <= 32_768 { try database.admitJSONAllocation(bytes: Int(size) * 2 + 256); data.reserveCapacity(Int(size)) }
    try database.admitJSONAllocation(bytes: 256)
    while offset < size {
      try database.checkReadAllowance()
      let chunk = try store.readBlobChunk(hash: hash, offset: offset, maxBytes: Int(min(1_024 * 1_024, size - offset)))
      hasher.update(data: chunk)
      if prefix.count < 74 { prefix.append(chunk.prefix(74 - prefix.count)) }
      if size <= 32_768 { data.append(chunk) }
      offset += Int64(chunk.count)
    }
    guard NotebookHexEncoding.encode(hasher.finalize()) == hash else { throw NotebookStorageError.blobHashMismatch }
    let children: [String]
    if isNode {
      guard prefix.starts(with: Data("NIN1".utf8)), !data.isEmpty else { throw NotebookStorageError.corruptRecord(hash) }
      try database.admitJSONAllocation(bytes: 1_024)
      children = try InkStoredBody.dependencies(data)
    } else {
      _ = try InkStoredBody.readFootprint(prefix, storedBytes: Int(size))
      children = prefix.starts(with: Data("NIB1".utf8)) ? [] : try InkStoredBody.dependencies(data)
    }
    for child in children { try inkClosure(child, depth: depth + 1, isNode: true) }
    inkKinds[hash] = isNode
    try noteDependency(.init(hash: hash, byteCount: size), role: "ink")
  }

  private func orderClosure(_ hash: String, height: Int? = nil) throws -> Int {
    if let existing = orderNodes[hash] {
      guard height.map({ $0 == existing.height }) ?? true else { throw NotebookStorageError.invalidTransaction("history physical order height") }
      return existing.count
    }
    let data = try smallAuthenticatedBlob(hash, maximumBytes: NotebookPageOrderVector.maximumNodeBytes)
    try database.admitJSONDecode(data); try database.admitJSONAllocation(bytes: data.count * 4 + 4_096)
    let node = try store.readPageOrderNode(hash)
    guard height.map({ $0 == node.height }) ?? true else { throw NotebookStorageError.invalidTransaction("history physical order height") }
    var total = 0
    for child in node.children { total += try orderClosure(child, height: node.height - 1) }
    guard node.height == 0 || total == node.count else { throw NotebookStorageError.invalidTransaction("history physical order count") }
    try database.admitJSONAllocation(bytes: 512)
    orderNodes[hash] = (node.height, node.count)
    try noteDependency(.init(hash: hash, byteCount: Int64(data.count)), role: "order")
    return node.count
  }

  private func programClosure(_ hash: String) throws {
    if programHashes.contains(hash) { return }
    let data = try smallAuthenticatedBlob(hash, maximumBytes: NotebookProgramPackage.maximumManifestBytes)
    try database.admitJSONDecode(data); try database.admitJSONAllocation(bytes: data.count * 4)
    let package = try store.readProgramPackage(hash)
    for file in package.files { for part in file.parts {
      try opaqueDependency(part.sha256, expectedBytes: Int64(part.byteCount), role: "program-part")
    } }
    try database.admitJSONAllocation(bytes: 384)
    programHashes.insert(hash)
    try noteDependency(.init(hash: hash, byteCount: Int64(data.count)), role: "program-root")
  }

  private func opaqueDependency(_ hash: String, expectedBytes: Int64, role: String) throws {
    if dependencyHashes.contains(hash) {
      guard try store.historyPhysicalBlobSize(hash) == expectedBytes else { throw NotebookStorageError.blobHashMismatch }; return
    }
    let size = try store.historyPhysicalBlobSize(hash)
    guard size == expectedBytes else { throw NotebookStorageError.blobHashMismatch }
    var hasher = SHA256(), offset: Int64 = 0
    while offset < size {
      try database.checkReadAllowance()
      let chunk = try store.readBlobChunk(hash: hash, offset: offset, maxBytes: Int(min(1_024 * 1_024, size - offset)))
      hasher.update(data: chunk); offset += Int64(chunk.count)
    }
    guard NotebookHexEncoding.encode(hasher.finalize()) == hash else { throw NotebookStorageError.blobHashMismatch }
    try noteDependency(.init(hash: hash, byteCount: size), role: role)
  }

  private func smallAuthenticatedBlob(_ hash: String, maximumBytes: Int) throws -> Data {
    let size = try store.historyPhysicalBlobSize(hash)
    guard size > 0, size <= maximumBytes else { throw NotebookStorageError.limitExceeded("history_physical_metadata") }
    try database.admitJSONAllocation(bytes: Int(size) * 2 + 256)
    let data = try store.readBlobChunk(hash: hash, offset: 0, maxBytes: Int(size))
    guard NotebookHexEncoding.encode(SHA256.hash(data: data)) == hash else { throw NotebookStorageError.blobHashMismatch }
    return data
  }

  private func noteDependency(_ blob: Proof.Blob, role: String) throws {
    if dependencyHashes.contains(blob.hash) { return }
    guard dependencyHashes.count < 131_072 else { throw NotebookStorageError.limitExceeded("history_physical_dependencies") }
    try database.admitJSONAllocation(bytes: 384)
    dependencyHashes.insert(blob.hash); dependencyBytes = try add(dependencyBytes, blob.byteCount)
    try frame([role, blob.hash, String(blob.byteCount)], into: &dependencyDigest)
  }

  private func sourceOriginal(_ id: UUID, workspaceID: UUID) throws -> Proof.SourceOriginal {
    let prefix = "local/action-results/" + id.uuidString.lowercased() + "/"
    var original: Proof.Blob?, model: Proof.Blob?, result: Proof.Blob?, version: String?
    func outcome(_ reason: Proof.Reason?) -> Proof.SourceOriginal {
      .init(status: reason.map(Proof.SourceOriginalStatus.unproven) ?? .authenticatedSourceLocalRoots,
        originalVersion: version, original: original, model: model, result: result)
    }
    do {
      guard let pointer = try sourceRoot(prefix + "original.json", paths: [["value"]]) else { return outcome(.originalAnchorUnavailable) }
      original = pointer.0
      guard pointer.1.collections.isEmpty, pointer.1.inkBodies.isEmpty else { return outcome(.originalAnchorMismatch) }
      version = try decode(String.self, ["value"], in: pointer.2)
      guard NotebookPageOrderRegister.validHash(version!) else { return outcome(.originalAnchorMismatch) }
      guard let storedModel = try sourceRoot(prefix + version! + "/model.json",
        paths: [["value", "id"], ["value", "actionVersion"], ["value", "undo"]]),
        let storedResult = try sourceRoot(prefix + version! + "/result.json",
        paths: [["value", "actionID"], ["value", "actionVersion"], ["value", "basis", "workspaceID"], ["value", "undo"]]) else {
        return outcome(.originalAnchorUnavailable)
      }
      model = storedModel.0; result = storedResult.0
      guard storedModel.1.collections.isEmpty, storedResult.1.collections.isEmpty,
        storedModel.1.inkBodies.isEmpty, storedResult.1.inkBodies.isEmpty,
        try decode(UUID.self, ["value", "id"], in: storedModel.2) == id,
        try decode(String.self, ["value", "actionVersion"], in: storedModel.2) == version,
        try decode(UUID.self, ["value", "actionID"], in: storedResult.2) == id,
        try decode(String.self, ["value", "actionVersion"], in: storedResult.2) == version,
        try decode(UUID.self, ["value", "basis", "workspaceID"], in: storedResult.2) == workspaceID,
        storedModel.2[["value", "undo"]].map(isNull) ?? true,
        storedResult.2[["value", "undo"]].map(isNull) ?? true else { return outcome(.originalAnchorMismatch) }
      return outcome(nil)
    } catch NotebookHistoryPhysicalAnchorOrphan.found { return outcome(.orphanAnchor) }
    catch NotebookStorageError.blobMissing { return outcome(.originalAnchorUnavailable) }
    catch NotebookStorageError.corruptRecord { return outcome(.originalAnchorMismatch) }
    catch NotebookStorageError.invalidTransaction { return outcome(.originalAnchorMismatch) }
  }

  private func sourceRoot(_ file: String, paths: [[String]]) throws -> (Proof.Blob, Header, Fields)? {
    let address = file + "#"
    guard let row = try database.rows("""
      SELECT CASE WHEN typeof(hash)='text' AND length(CAST(hash AS BLOB))=64 THEN hash END
      FROM records WHERE address=?
      """, [.text(address)]).first else { return nil }
    guard let hash = row[0].text else { throw NotebookStorageError.corruptRecord(address) }
    guard try database.rows("SELECT 1 FROM records WHERE file=? AND address<>? LIMIT 1", [.text(file), .text(address)]).isEmpty else {
      throw NotebookHistoryPhysicalAnchorOrphan.found
    }
    let (blob, fields, _) = try selectedBlob(hash, paths: headerPaths + paths)
    return (blob, try decodeHeader(fields, address: address, file: file), fields)
  }

  private func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow, value >= 0 else { throw NotebookStorageError.limitExceeded("history_physical_bytes") }
    return value
  }
  private func frame(_ values: [String], into hasher: inout SHA256) throws {
    for value in values {
      try database.checkReadAllowance()
      let count = value.utf8.count
      try database.admitJSONAllocation(bytes: count + 8)
      var length = UInt64(count).bigEndian
      withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
      hasher.update(data: Data(value.utf8))
    }
  }
}

private enum NotebookHistoryPhysicalAnchorOrphan: Error { case found }
