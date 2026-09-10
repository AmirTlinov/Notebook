import CryptoKit
import Foundation

extension NotebookStore {
  /// Reads one physical page with an explicit ceiling before loading point blobs.
  /// Imported raster-only ink is not silently presented as editable Pencil UUIDs.
  public func readComputationInk(notebookID: UUID, pageID: UUID, region: PageRect) throws -> NotebookComputationInk {
    try readTransaction { _ in
      let cut = try computationInkCut(notebookID: notebookID, pageID: pageID, region: region)
      let address = pageFile(pageID) + "#/drawingData"
      let drawing = try NotebookRecordCodec.decode(storedFragments(address: address), root: address).decode(PageInkDrawing.self)
      guard drawing.isValid, drawing.actions.allSatisfy({ $0.sequence > 0 }) else { throw PageInkDrawing.InkError.invalidDrawing }
      guard drawing.baselinePNG == nil, drawing.baselineActionCount == 0 else {
        throw CollaborationError("ink_source_unavailable", "Для вычисления нужны настоящие штрихи, а не импортированное изображение.")
      }
      guard drawing.actions.reduce(0, { $0 + $1.samples.count }) <= 65_536 else {
        throw NotebookStorageError.limitExceeded("computation_ink_samples")
      }
      let actions = drawing.activeActions.filter { Self.computationIntersects($0, region: region) }
      guard actions.contains(where: { $0.tool == .pen }) else {
        throw CollaborationError("ink_source_empty", "В указанной области нет штрихов ручки.")
      }
      return .init(source: cut.source, pageSize: cut.size, drawing: .init(actions: actions))
    }
  }

  /// The caller captures ink after the input fence. A retry of an activation ID
  /// reads its existing state, rather than reviving a stopped or removed record.
  public func activateComputation(id: UUID, ink: NotebookComputationInk, actor: UUID) throws -> NotebookComputationRead {
    try commandTransaction {
      if let existing = try computationRecord(pageID: ink.source.pageID, id: id) {
        guard existing.origin == ink.source else { throw NotebookStorageError.transactionConflict }
        return try computationRead(existing)
      }
      try requireComputationSource(ink.source)
      let records = try computationRecords(pageID: ink.source.pageID)
      guard records.count < 256 else { throw NotebookStorageError.limitExceeded("page_computations") }
      let frontier = records.map(\.order.counter).max() ?? 0
      guard let order = VersionStamp(counter: frontier, actor: actor).advanced(by: actor) else {
        throw NotebookStorageError.limitExceeded("computation_order")
      }
      let record = NotebookComputation(id: id, origin: ink.source, order: order, source: ink.source,
        stamp: order, predecessor: nil, phase: .awaitingRecognition, attemptID: nil, recognition: nil)
      try writeComputation(record)
      return .init(computation: record, sourceIsCurrent: true)
    }
  }

  public func readComputation(pageID: UUID, id: UUID) throws -> NotebookComputationRead {
    try readTransaction { _ in
      guard let record = try computationRecord(pageID: pageID, id: id) else { throw CocoaError(.fileNoSuchFile) }
      return try computationRead(record)
    }
  }

  /// Intra-page order is independent of click history. Cross-page execution must
  /// use NotebookPagePosition/visibleRoot, not concatenate recently loaded pages.
  public func readPageComputations(pageID: UUID) throws -> [NotebookComputationRead] {
    try readTransaction { _ in
      let records = try computationRecords(pageID: pageID)
      guard let first = records.first else { return [] }
      guard records.allSatisfy({ $0.source.notebookID == first.source.notebookID }),
        try ownerItemID(ofPage: pageID) == first.source.notebookID else { throw NotebookStorageError.corruptRecord("computation owner") }
      do {
        let current = try computationInkCut(notebookID: first.source.notebookID, pageID: pageID, region: first.source.region)
        return records.map { .init(computation: $0,
          sourceIsCurrent: $0.source.inkHash == current.source.inkHash && $0.source.drawingStamp == current.source.drawingStamp) }
      } catch NotebookStorageError.limitExceeded {
        return records.map { .init(computation: $0, sourceIsCurrent: false) }
      }
    }
  }

  public func beginComputationRecognition(pageID: UUID, id: UUID, expectedRevision: String,
    attemptID: UUID, ink: NotebookComputationInk, actor: UUID) throws -> NotebookRecognitionInput {
    try commandTransaction {
      guard var record = try computationRecord(pageID: pageID, id: id), record.phase != .removed,
        record.origin.pageID == ink.source.pageID, record.origin.notebookID == ink.source.notebookID,
        record.origin.region == ink.source.region else { throw CocoaError(.fileNoSuchFile) }
      try requireComputationSource(ink.source)
      if record.attemptID == attemptID {
        guard record.phase == .recognizing, record.source == ink.source else { throw NotebookStorageError.transactionConflict }
        return .init(computationID: id, revision: try record.revision, attemptID: attemptID, ink: ink)
      }
      guard try record.revision == expectedRevision else { throw NotebookStorageError.transactionConflict }
      try advanceComputation(&record, actor: actor)
      record.source = ink.source; record.attemptID = attemptID; record.phase = .recognizing; record.recognition = nil
      try writeComputation(record)
      return .init(computationID: id, revision: try record.revision, attemptID: attemptID, ink: ink)
    }
  }

  /// A candidate is always marked for review. Syntax validity is never evidence
  /// that handwriting was read correctly, even when only one candidate exists.
  public func publishComputationRecognition(_ prepared: PreparedNotebookRecognition, actor: UUID) throws -> NotebookComputationRead {
    try commandTransaction {
      guard var record = try computationRecord(pageID: prepared.source.pageID, id: prepared.computationID),
        record.attemptID == prepared.attemptID, record.source == prepared.source else { throw NotebookStorageError.transactionConflict }
      if record.phase == .needsReview, record.predecessor == prepared.revision,
        record.recognition == prepared.output { return try computationRead(record) }
      guard record.phase == .recognizing, try record.revision == prepared.revision else { throw NotebookStorageError.transactionConflict }
      try requireComputationSource(prepared.source)
      try advanceComputation(&record, actor: actor)
      record.phase = .needsReview; record.recognition = prepared.output
      try writeComputation(record)
      return .init(computation: record, sourceIsCurrent: true)
    }
  }

  public func stopComputation(pageID: UUID, id: UUID, expectedRevision: String, actor: UUID) throws -> NotebookComputationRead {
    try endComputation(pageID: pageID, id: id, expectedRevision: expectedRevision, actor: actor, phase: .stopped)
  }

  public func removeComputation(pageID: UUID, id: UUID, expectedRevision: String, actor: UUID) throws -> NotebookComputationRead {
    try endComputation(pageID: pageID, id: id, expectedRevision: expectedRevision, actor: actor, phase: .removed)
  }

  private func endComputation(pageID: UUID, id: UUID, expectedRevision: String, actor: UUID,
    phase: NotebookComputation.Phase) throws -> NotebookComputationRead {
    try commandTransaction {
      guard var record = try computationRecord(pageID: pageID, id: id) else { throw CocoaError(.fileNoSuchFile) }
      if record.phase == phase, record.predecessor == expectedRevision { return try computationRead(record) }
      guard try record.revision == expectedRevision, record.phase != .removed else { throw NotebookStorageError.transactionConflict }
      try advanceComputation(&record, actor: actor)
      record.phase = phase; record.recognition = nil
      try writeComputation(record)
      return try computationRead(record)
    }
  }

  private func advanceComputation(_ record: inout NotebookComputation, actor: UUID) throws {
    guard let next = record.stamp.advanced(by: actor) else { throw NotebookStorageError.limitExceeded("computation_revision") }
    record.predecessor = try record.revision
    record.stamp = next
  }

  private func computationRead(_ record: NotebookComputation) throws -> NotebookComputationRead {
    guard try ownerItemID(ofPage: record.source.pageID) == record.source.notebookID else { throw CocoaError(.fileNoSuchFile) }
    do {
      let current = try computationInkCut(notebookID: record.source.notebookID, pageID: record.source.pageID, region: record.source.region)
      return .init(computation: record, sourceIsCurrent: current.source == record.source)
    } catch NotebookStorageError.limitExceeded {
      // Growing ink beyond the recognition window cannot block Stop or Removal.
      return .init(computation: record, sourceIsCurrent: false)
    }
  }

  private func requireComputationSource(_ source: NotebookComputationSource) throws {
    let current = try computationInkCut(notebookID: source.notebookID, pageID: source.pageID, region: source.region)
    guard current.source == source else { throw CollaborationError("source_conflict", "Штрихи изменились после начала обработки.") }
  }

  private func computationRecord(pageID: UUID, id: UUID) throws -> NotebookComputation? {
    let address = pageFile(pageID) + "#/computations/@" + id.uuidString.lowercased()
    let bytes = try currentSQL!.rows("SELECT length(b.data) FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?", [.text(address)]).first?[0].integer ?? 0
    guard bytes <= 262_144 else { throw NotebookStorageError.limitExceeded("computation_record_bytes") }
    guard let row = try storedFragments(address: address, descendants: false).first else { return nil }
    let record = try row.value.decode(NotebookComputation.self)
    guard record.isValid, record.id == id, record.source.pageID == pageID, row.collections.isEmpty else {
      throw NotebookStorageError.corruptRecord(address)
    }
    return record
  }

  func computationRecords(pageID: UUID) throws -> [NotebookComputation] {
    guard try ownerItemID(ofPage: pageID) != nil else { throw CocoaError(.fileNoSuchFile) }
    let rows = try currentSQL!.rows("SELECT member FROM records WHERE parent=? AND collection='computations' ORDER BY position,member LIMIT 257",
      [.text(pageFile(pageID) + "#")])
    guard rows.count <= 256 else { throw NotebookStorageError.limitExceeded("page_computations") }
    return try rows.map {
      guard let id = $0[0].text.flatMap(UUID.init(uuidString:)), let record = try computationRecord(pageID: pageID, id: id) else {
        throw NotebookStorageError.corruptRecord("computation identity")
      }
      return record
    }.sorted(by: NotebookComputation.ordered)
  }

  private func writeComputation(_ record: NotebookComputation) throws {
    let file = pageFile(record.source.pageID), address = file + "#", database = currentSQL!
    guard record.isValid, try ownerItemID(ofPage: record.source.pageID) == record.source.notebookID,
      let page = try storedFragments(address: address, descendants: false).first,
      let size = try page.value["size"]?.decode(PageSize.self), record.source.region.isContained(in: size) else {
      throw NotebookStorageError.invalidTransaction("computation owner")
    }
    let collection = NotebookStoredCollection(path: ["computations"], kind: .array)
    if !page.collections.contains(collection) {
      try writeFragment(page.replacing(value: page.value, collections: page.collections + [collection]), database: database)
    }
    let member = record.id.uuidString.lowercased()
    try writeFragment(.init(address: address + "/computations/@" + member, file: file, parent: address,
      collection: "computations", member: member, position: 0, value: try .encode(record), collections: []), database: database)
  }

  private func computationInkCut(notebookID: UUID, pageID: UUID, region: PageRect)
    throws -> (source: NotebookComputationSource, size: PageSize) {
    guard try ownerItemID(ofPage: pageID) == notebookID,
      let page = try storedFragments(address: pageFile(pageID) + "#", descendants: false).first,
      page.value["format"] == .number(Double(PageDocument.formatVersion)),
      let size = try page.value["size"]?.decode(PageSize.self), size.isValid,
      let stamp = try page.value["drawingStamp"]?.decode(VersionStamp.self), stamp.counter <= VersionStamp.maximumCounter else {
      throw CocoaError(.fileNoSuchFile)
    }
    guard region.isContained(in: size) else { throw CollaborationError("invalid_region", "Область должна находиться внутри листа.") }
    let prefix = pageFile(pageID) + "#/drawingData"
    let rows = try currentSQL!.rows("SELECT r.address,r.hash,length(b.data) FROM records r CROSS JOIN blobs b ON b.hash=r.hash WHERE r.address>=? AND r.address<? ORDER BY r.address LIMIT 4099",
      [.text(prefix), .text(prefix + "\u{10ffff}")])
    guard !rows.isEmpty, rows.first?[0].text == prefix else { throw NotebookStorageError.corruptRecord(prefix) }
    guard rows.count <= 4098, rows.reduce(Int64(0), { $0 + ($1[2].integer ?? 8_388_609) }) <= 8_388_608 else {
      throw NotebookStorageError.limitExceeded("computation_ink_bytes")
    }
    var digest = SHA256()
    for row in rows {
      digest.update(data: Data((row[0].text! + "\n" + row[1].text! + "\n").utf8))
    }
    let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return (.init(notebookID: notebookID, pageID: pageID, region: region, drawingStamp: stamp, inkHash: hash), size)
  }

  private static func computationIntersects(_ action: PageInkAction, region: PageRect) -> Bool {
    // A conservative whole-stroke bound retains joins and caps. Clipping samples
    // would manufacture endpoints and change the native pen/eraser raster.
    let radius = action.samples.map(\.width).max()! / 2
    let x = action.samples.map { $0.point.x }, y = action.samples.map { $0.point.y }
    return x.min()! - radius <= region.x + region.width && x.max()! + radius >= region.x
      && y.min()! - radius <= region.y + region.height && y.max()! + radius >= region.y
  }
}
