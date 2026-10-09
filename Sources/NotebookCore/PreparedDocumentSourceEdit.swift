import Foundation

/// An ephemeral native Save plan. It owns the exact editor cut and the sole
/// search recipe's output; no prepared bytes are persisted outside the normal
/// action/source/index transaction.
public struct PreparedDocumentSourceEdit: Sendable {
  public struct Cost: Sendable, Equatable {
    public let payloadBytes: Int
    public let completionBytes: Int
    public var bytes: Int { payloadBytes + completionBytes }

    fileprivate init(payloadBytes: Int, completionBytes: Int) throws {
      guard payloadBytes >= 0, completionBytes >= 0,
        payloadBytes <= 256 * 1_024 * 1_024 - completionBytes else { throw Self.refusal() }
      self.payloadBytes = payloadBytes; self.completionBytes = completionBytes
    }

    private static func refusal() -> NotebookStorageError { .limitExceeded("document_source_preparation") }
  }

  public static let maximumPreparationBytes = 64 * 1_024 * 1_024
  public let edit: DocumentSourceEdit
  public let workspaceID: UUID
  /// Held after the utility worker has actually joined, while input becomes
  /// idle. The later writer finish is acquired only after that boundary.
  public let retainedCost: Cost
  public let cost: Cost
  let search: NotebookPreparedSearchEntry
  struct FinishRead: Sendable {
    let projectionBytes: Int64
    let draftBytes: Int64
    let receiptBytes: Int64
    let projectionAllocationBytes: Int
    let draftAllocationBytes: Int
    let receiptAllocationBytes: Int
  }
  let finishRead: FinishRead

  /// Pre-worker admission uses scalar extents only. In particular, it does
  /// not encode escaped source on the MainActor. A file CAS uses the compact
  /// causal vector returned by fileBasis, never a register's retained bodies.
  public static func cost(for edit: DocumentSourceEdit) throws -> Cost {
    guard (edit.baseSource.isContiguousUTF8 || edit.baseSource.utf16.count <= DocumentFile.maximumSourceLength),
      (edit.source.isContiguousUTF8 || edit.source.utf16.count <= DocumentFile.maximumSourceLength) else {
      throw refusal()
    }
    // Reading a foreign NSString's UTF8 view can materialize its whole body.
    // Reserve its admitted maximum here; the utility worker resolves the real
    // extent. Native contiguous String counts already live in its scalar header.
    let before = edit.baseSource.isContiguousUTF8 ? edit.baseSource.utf8.count : DocumentFile.maximumSourceLength
    let after = edit.source.isContiguousUTF8 ? edit.source.utf8.count : DocumentFile.maximumSourceLength
    guard before <= DocumentFile.maximumSourceLength, after <= DocumentFile.maximumSourceLength,
      !edit.fileID.isEmpty, boundedUTF16(edit.fileID, maximum: 120),
      !edit.baseVersion.hasRetainedAlternatives, edit.baseVersion.observed.count <= 256,
      edit.baseVersion.observed.keys.allSatisfy({
        $0.isContiguousUTF8 ? $0.utf8.count <= 36 : $0.utf16.count <= 36
      }) else { throw refusal() }
    let version = 1_024 + edit.baseVersion.observed.count * 192
    let beforeFactor = edit.baseSource.isContiguousUTF8 ? 2 : 3
    let afterFactor = edit.source.isContiguousUTF8 ? 2 : 3
    let payload = 65_536 + before * beforeFactor + after * afterFactor + version
    let working = min(maximumPreparationBytes - payload, 8_192 + after * 224)
    guard working >= 8_192 else { throw refusal() }
    return try .init(payloadBytes: payload, completionBytes: working)
  }

  public init(edit: DocumentSourceEdit, workspaceID: UUID) throws {
    let initial = try Self.cost(for: edit)
    let beforeFactor = edit.baseSource.isContiguousUTF8 ? 2 : 3
    let afterFactor = edit.source.isContiguousUTF8 ? 2 : 3
    try Task.checkCancellation()
    try DocumentEditingSession(edit: edit).validate()
    guard edit.baseVersion.isValid else {
      throw Self.refusal()
    }
    let input = NotebookSearchInput(documentID: edit.documentID, fileID: edit.fileID, source: edit.source)
    let search = try NotebookPreparedSearchEntry(input: input, workspaceID: workspaceID,
      maximumWorkingBytes: initial.completionBytes)
    let retained = 65_536 + edit.baseSource.utf8.count * beforeFactor + edit.source.utf8.count * afterFactor
      + edit.baseVersion.retainedPayloadBytes + search.retainedBytes
    let retainedCost = try Cost(payloadBytes: retained, completionBytes: 0)
    guard retainedCost.bytes <= initial.bytes else { throw Self.refusal() }
    let finish = try Self.finish(edit)
    try Task.checkCancellation()
    self.edit = edit; self.workspaceID = workspaceID; self.search = search
    self.retainedCost = retainedCost
    self.cost = try .init(payloadBytes: retained, completionBytes: finish.bytes)
    self.finishRead = finish.read
  }

  private static func finish(_ edit: DocumentSourceEdit) throws -> (bytes: Int, read: FinishRead) {
    typealias Footprint = ContentFieldVersion.WriteFootprint
    let before = try Footprint.string(edit.baseSource), after = try Footprint.string(edit.source)
    let version = try edit.baseVersion.writeFootprint()
    // Source CAS and the addressed projections retain source scalars by value.
    // The receipt carries operation(base,new) plus diff(before,after). A saved
    // terminal draft carries edit(base,new) plus the accepted new publication.
    // Each codec phase allows the decoded representation (8*wire+512/token)
    // and two concurrent canonical/transient buffers. Recovery and the initial
    // publication are sequential; their peaks are not added together.
    let framing = 32_768 + version.wireBytes * 4
    let receiptWire = (before.wireBytes + after.wireBytes) * 2 + framing
    let draftWire = before.wireBytes + after.wireBytes * 2 + framing
    let projectionWire = before.wireBytes + after.wireBytes + framing
    let tokens = 256 + version.tokens * 4
    let bytes = 524_288 + max(receiptWire * 10, draftWire * 10, projectionWire * 12) + tokens * 2_048
    // An unfinished old draft is released before the projection is read. The
    // original and accepted file projections can coexist; each therefore owns
    // at most half of this already reserved finish phase. Cached terminal
    // recovery returns directly and may use the whole draft phase instead.
    return (bytes, .init(projectionBytes: Int64(projectionWire), draftBytes: Int64(draftWire), receiptBytes: Int64(receiptWire),
      projectionAllocationBytes: bytes / 2, draftAllocationBytes: bytes, receiptAllocationBytes: bytes / 2))
  }

  private static func boundedUTF16(_ value: String, maximum: Int) -> Bool {
    if value.isContiguousUTF8, value.utf8.count > maximum * 4 { return false }
    return value.utf16.count <= maximum
  }

  private static func refusal() -> NotebookStorageError { .limitExceeded("document_source_preparation") }
}
