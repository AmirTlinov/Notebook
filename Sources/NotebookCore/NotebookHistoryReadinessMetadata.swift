import CryptoKit
import Foundation

/// Three transaction streams projected from accepted, source-local evidence.
/// A row commits metadata, never birth, authorship, restoration or activation.
public struct NotebookHistoryReadinessMetadata: Codable, Equatable, Sendable {
  public struct Row: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let transactionID: UUID
    public let manifestHash: String
    public let hash: String
    /// Each transaction contributes exactly one row, including zero receipts.
    public let count: Int
    /// Canonical framed metadata bytes hashed for this row. Raw fragment and
    /// dependency sizes are committed fields, not additional bytes in this sum.
    public let byteCount: Int64
  }

  public enum Component: String, Codable, Sendable { case physicalClosure, sourceOriginal }
  public struct Blocker: Codable, Equatable, Sendable {
    /// nil identifies the whole manifest's declared-record/dependency closure.
    public let receiptID: UUID?
    public let component: Component
    public let reason: NotebookHistoryPhysicalClosure.Reason
  }

  public let acceptedTransactions: Row
  public let physicalClosures: Row
  public let sourceOriginalRoots: Row
  public let receiptCount: Int
  public let physicalComplete: Bool
  /// Authenticated source-local roots; this does not identify an action's birth.
  public let sourceOriginalComplete: Bool
  public let incompletePhysicalCount: Int
  public let unknownSourceOriginalCount: Int
  public let missingSourceOriginalRootCount: Int
  public let blockers: [Blocker]
}

extension NotebookActionHistoryInventory.Occurrence {
  /// Local journal positions and first delivery routes differ across replicas.
  /// This accepted identity commits only workspace, transaction and manifest.
  public func historyReadinessAcceptedMetadata() throws -> NotebookHistoryReadinessMetadata.Row {
    guard localJournal != nil || firstReceived != nil else {
      throw NotebookStorageError.invalidTransaction("unaccepted history readiness metadata")
    }
    let digest = try NotebookHistoryMetadataDigest(domain: "notebook.history-readiness.accepted.v1",
      workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash)
    return digest.row()
  }
}

extension NotebookHistoryPhysicalClosure {
  /// Project the whole-transaction resolver result (receiptID: nil). This pure
  /// factory grants no new proof and cannot authenticate a decoded caller value.
  /// The native owner retains the actual read cut and its control fence.
  public func historyReadinessMetadata(accepted: NotebookActionHistoryInventory.Occurrence) throws
    -> NotebookHistoryReadinessMetadata {
    try historyReadinessMetadata(accepted: accepted, check: { try Task.checkCancellation() })
  }

  func historyReadinessMetadata(accepted: NotebookActionHistoryInventory.Occurrence,
    check: () throws -> Void) throws -> NotebookHistoryReadinessMetadata {
    try check()
    guard accepted.workspaceID == workspaceID, accepted.transactionID == transactionID,
      accepted.manifestHash == manifestHash, manifest.hash == manifestHash,
      (3...NotebookChangeManifest.currentFormat).contains(manifestFormat) else {
      throw NotebookStorageError.invalidTransaction("history readiness metadata scope")
    }
    guard manifestParts.count <= 512, receipts.count <= 64 else {
      throw NotebookStorageError.limitExceeded("history_readiness_metadata")
    }
    guard Set(manifestParts.map(\.hash)).count == manifestParts.count,
      Set(receipts.map(\.id)).count == receipts.count else {
      throw NotebookStorageError.invalidTransaction("duplicate history readiness metadata")
    }
    let acceptedRow = try accepted.historyReadinessAcceptedMetadata()
    var physical = try NotebookHistoryMetadataDigest(domain: "notebook.history-readiness.physical.v1",
      workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash)
    try physical.integer(Int64(manifestFormat))
    try physical.blob(manifest)
    try physical.integer(Int64(manifestParts.count))
    for part in manifestParts { try check(); try physical.blob(part) }
    let declared = declaredRecords
    guard (1...(512 * 16_384)).contains(declared.recordCount),
      (0...declared.recordCount).contains(declared.removalCount), declared.payloadBytes >= 0,
      (0...131_072).contains(declared.dependencyCount), declared.dependencyBytes >= 0 else {
      throw NotebookStorageError.invalidTransaction("history readiness declared fields")
    }
    var physicalUnknown = 0, originalUnknown = 0, missingRoots = 0
    var blockers: [NotebookHistoryReadinessMetadata.Blocker] = []
    switch declared.status {
    case .authenticatedDeclaredClosure:
      guard declared.recordSetHash != nil, declared.dependencySetHash != nil else {
        throw NotebookStorageError.invalidTransaction("history readiness authenticated declared fields")
      }
      try physical.tag(0)
    case .unproven(let reason):
      physicalUnknown += 1
      blockers.append(.init(receiptID: nil, component: .physicalClosure, reason: reason))
      try physical.tag(1); try physical.text(reason.rawValue)
    }
    try physical.integer(Int64(declared.recordCount)); try physical.integer(Int64(declared.removalCount))
    try physical.integer(declared.payloadBytes); try physical.optionalHash(declared.recordSetHash)
    try physical.integer(Int64(declared.dependencyCount)); try physical.integer(declared.dependencyBytes)
    try physical.optionalHash(declared.dependencySetHash)
    try physical.integer(Int64(receipts.count))
    var original = try NotebookHistoryMetadataDigest(domain: "notebook.history-readiness.source-original.v1",
      workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash)
    try original.integer(Int64(receipts.count))
    for receipt in receipts.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
      try check()
      guard (0...4_096).contains(receipt.fragmentCount), (0...131_072).contains(receipt.dependencyCount),
        receipt.fragmentBytes >= 0, receipt.dependencyBytes >= 0 else {
        throw NotebookStorageError.invalidTransaction("history readiness physical fields")
      }
      try physical.text(receipt.id.uuidString.lowercased())
      switch receipt.status {
      case .authenticatedDeclaredClosure:
        guard receipt.fragmentCount > 0, receipt.fragmentSetHash != nil, receipt.dependencySetHash != nil else {
          throw NotebookStorageError.invalidTransaction("history readiness authenticated fields")
        }
        try physical.tag(0)
      case .unproven(let reason):
        physicalUnknown += 1
        blockers.append(.init(receiptID: receipt.id, component: .physicalClosure, reason: reason))
        try physical.tag(1); try physical.text(reason.rawValue)
      }
      try physical.text(receipt.logicalBinding.rawValue)
      try physical.integer(Int64(receipt.fragmentCount)); try physical.integer(receipt.fragmentBytes)
      try physical.optionalHash(receipt.fragmentSetHash)
      try physical.integer(Int64(receipt.dependencyCount)); try physical.integer(receipt.dependencyBytes)
      try physical.optionalHash(receipt.dependencySetHash)

      let source = receipt.sourceOriginal
      try original.text(receipt.id.uuidString.lowercased())
      switch source.status {
      case .authenticatedSourceLocalRoots:
        guard let version = source.originalVersion, NotebookPageOrderRegister.validHash(version),
          source.original != nil, source.model != nil, source.result != nil else {
          throw NotebookStorageError.invalidTransaction("history readiness authenticated source roots")
        }
        try original.tag(0)
      case .unproven(let reason):
        originalUnknown += 1
        blockers.append(.init(receiptID: receipt.id, component: .sourceOriginal, reason: reason))
        try original.tag(1); try original.text(reason.rawValue)
      }
      // An unproven malformed version stays committed verbatim as bounded
      // metadata. Missing pointers/roots are distinct from present empty data.
      if let version = source.originalVersion { try original.tag(1); try original.text(version) }
      else { try original.tag(0) }
      for root in [source.original, source.model, source.result] {
        if let root { try original.tag(1); try original.blob(root) }
        else { missingRoots += 1; try original.tag(0) }
      }
    }
    try check()
    return .init(acceptedTransactions: acceptedRow, physicalClosures: physical.row(),
      sourceOriginalRoots: original.row(), receiptCount: receipts.count,
      physicalComplete: physicalUnknown == 0, sourceOriginalComplete: originalUnknown == 0,
      incompletePhysicalCount: physicalUnknown, unknownSourceOriginalCount: originalUnknown,
      missingSourceOriginalRootCount: missingRoots, blockers: blockers)
  }
}

/// v1 framing: UTF-8 strings have UInt64 big-endian byte lengths; nonnegative
/// integers are UInt64 big-endian; enums/optional presence use one-byte tags.
/// Scope precedes all fields. Parts retain manifest order, receipts use UUID
/// order, and original roots always use original/model/result order.
private struct NotebookHistoryMetadataDigest {
  private var digest = SHA256()
  private var byteCount: Int64 = 0
  private let workspaceID: UUID, transactionID: UUID
  private let manifestHash: String

  init(domain: String, workspaceID: UUID, transactionID: UUID, manifestHash: String) throws {
    guard NotebookPageOrderRegister.validHash(manifestHash) else {
      throw NotebookStorageError.invalidTransaction("history readiness manifest hash")
    }
    self.workspaceID = workspaceID; self.transactionID = transactionID; self.manifestHash = manifestHash
    try text(domain); try text(workspaceID.uuidString.lowercased())
    try text(transactionID.uuidString.lowercased()); try text(manifestHash)
  }

  mutating func text(_ value: String) throws {
    // Same finite capture bound as the frozen raw metadata reader.
    guard value.utf8.count <= 1_024 * 1_024 else {
      throw NotebookStorageError.limitExceeded("history_readiness_metadata_string")
    }
    try integer(Int64(value.utf8.count))
    try append(Data(value.utf8))
  }
  mutating func integer(_ value: Int64) throws {
    guard value >= 0 else { throw NotebookStorageError.invalidTransaction("history readiness metadata integer") }
    var bytes = UInt64(value).bigEndian
    try withUnsafeBytes(of: &bytes) { try append(Data($0)) }
  }
  mutating func tag(_ value: UInt8) throws { try append(Data([value])) }
  mutating func optionalHash(_ value: String?) throws {
    guard let value else { try tag(0); return }
    guard NotebookPageOrderRegister.validHash(value) else {
      throw NotebookStorageError.invalidTransaction("history readiness metadata hash")
    }
    try tag(1); try text(value)
  }
  mutating func blob(_ value: NotebookHistoryPhysicalClosure.Blob) throws {
    guard NotebookPageOrderRegister.validHash(value.hash), (0...268_435_456).contains(value.byteCount) else {
      throw NotebookStorageError.invalidTransaction("history readiness metadata blob")
    }
    try text(value.hash); try integer(value.byteCount)
  }
  private mutating func append(_ bytes: Data) throws {
    let next = byteCount.addingReportingOverflow(Int64(bytes.count))
    guard !next.overflow else { throw NotebookStorageError.limitExceeded("history_readiness_metadata_bytes") }
    digest.update(data: bytes); byteCount = next.partialValue
  }
  func row() -> NotebookHistoryReadinessMetadata.Row {
    .init(workspaceID: workspaceID, transactionID: transactionID, manifestHash: manifestHash,
      hash: NotebookHexEncoding.encode(digest.finalize()), count: 1, byteCount: byteCount)
  }
}
