import Foundation

extension NotebookStore {
  /// Elements, ink and computations have separate causal owners. Receiving a
  /// frame edit must not decode either the drawing or another element.
  func applyReplicatedPage(file: String, manifestHash: String, isSnapshot: Bool = false) throws {
    let records = NotebookIncomingRecords(store: self, manifestHash: manifestHash)
    let database = currentSQL!, root = file + "#"
    guard let id = UUID(uuidString: String(file.dropFirst(6).dropLast(5))), pageFile(id) == file else {
      throw NotebookStorageError.invalidTransaction("page owner")
    }
    let old = try records.previous(root)
    let liveOwner = try ownerItemID(ofPage: id)
    let retired = liveOwner == nil ? try retiredNotebookMembership(ofPage: id) : nil
    if liveOwner == nil {
      guard retired != nil else { try removeFragment(root, database: database); return }
      // A split field-name claim cannot allocate a source. A snapshot or an
      // atomic native birth has typed order + birth + full PAGE closure, and
      // receives complete semantic validation before this transaction commits.
      if old == nil, !isSnapshot {
        guard try hasRetiredPageBirthClosure(pageID: id, membership: retired!, records: records) else { return }
      }
      if let mutation = try records.mutation(root), mutation[0].text == nil { return }
    }
    guard let next = try records.candidate(root) else { throw NotebookStorageError.invalidTransaction("live page retains content") }
    let candidate = try pageSourceHeader(next, id: id), previous = try old.map { try pageSourceHeader($0, id: id) }
    guard previous == nil || previous?.size == candidate.size else { throw NotebookStorageError.transactionConflict }
    if old == nil, retired != nil {
      // The already validated root admits this in-flight baseline's typed
      // computation owner. Any missing/malformed descendant rolls back it all.
      try writeFragment(next, database: database)
    }
    var result = next.value
    let frontier = max(candidate.agentStamp, previous?.agentStamp ?? candidate.agentStamp)
    let drawingRoot = root + "/drawingData"
    var hasInkChanges = false
    var hasComputationChanges = false
    try records.visit(from: root + "/", to: file + "$") { address in
      if address == drawingRoot || address.hasPrefix(drawingRoot + "/") { hasInkChanges = true }
      else if address.hasPrefix(root + "/computations/@") { hasComputationChanges = true }
      else if !address.hasPrefix(root + "/elements/@") && !address.hasPrefix(root + "/collaboration/fields/@") {
        throw NotebookStorageError.invalidTransaction("page address")
      }
    }
    var drawingStamp = max(candidate.drawingStamp, previous?.drawingStamp ?? candidate.drawingStamp)
    if hasInkChanges {
      // The drawing owner alone is reconstructed when its baseline/strokes
      // change. Element-only delivery never enters this path.
      let beforeRows = try storedFragments(address: drawingRoot)
      let candidateRows = try records.overlay(drawingRoot, previous: beforeRows)
      let incomingDrawing = try NotebookRecordCodec.decode(candidateRows, root: drawingRoot).decode(PageInkDrawing.self)
      let incomingData = try incomingDrawing.dataRepresentation()
      let incomingPage = try JSONValue.encode(candidate).setting("drawingData", .encode(incomingData)).decode(PageDocument.self)
      var merged = incomingPage
      if let previous {
        let beforeDrawing = try NotebookRecordCodec.decode(beforeRows, root: drawingRoot).decode(PageInkDrawing.self)
        let beforePage = try JSONValue.encode(previous).setting("drawingData", .encode(beforeDrawing.dataRepresentation())).decode(PageDocument.self)
        merged = try incomingPage.merging(beforePage)
      }
      drawingStamp = merged.drawingStamp
      let drawing = try PageInkDrawing.decode(merged.drawingData)
      try records.publishSubtree(.encode(drawing), old: beforeRows, file: file, address: drawingRoot,
        parent: root, collection: "drawingData", member: "", position: 0)
    } else if old == nil { throw NotebookStorageError.corruptRecord(drawingRoot) }
    result = try result.setting("drawingStamp", .encode(drawingStamp))
    let elementsDiffer = try records.mergeElements(file: file, parent: root, collection: "elements", fields: "collaboration/fields",
      localStamp: previous?.agentStamp, incomingStamp: candidate.agentStamp) { value in
        let element = try value.decode(AgentElement.self)
        guard PageDocument.elementsAreValid([element], in: candidate.size), try JSONValue.encode(element) == value else {
          throw NotebookStorageError.corruptRecord("page element")
        }
      }
    result = try result.setting("agentStamp", .encode(elementsDiffer ? frontier.advanced(by: frontier.actor) ?? frontier : frontier))
    if hasComputationChanges {
      try records.visit(from: root + "/computations/@", to: root + "/computations0") { address in
        guard let row = try records.fragment(address) else { return } // The typed journal retains accepted computations.
        let incoming = try row.value.decode(NotebookComputation.self)
        let prior = try records.previous(address)?.value.decode(NotebookComputation.self)
        let joined = try prior.map { try $0.joining(incoming) } ?? incoming
        guard joined.source.pageID == id, joined.source.region.isContained(in: candidate.size) else { throw NotebookStorageError.transactionConflict }
        try writeFragment(row.replacing(value: .encode(joined)), database: database)
      }
      let count = try database.rows("SELECT count(*) FROM records WHERE parent=? AND collection='computations'", [.text(root)]).first![0].integer!
      guard count <= 256 else { throw NotebookStorageError.limitExceeded("page_computations") }
    }
    // A delayed root cannot hide a concurrently published typed collection.
    var collections = Set((old?.collections ?? []).map { fieldKey($0.path) })
    collections.formUnion(next.collections.map { fieldKey($0.path) })
    let descriptors = Dictionary((old?.collections ?? []) .map { (fieldKey($0.path), $0) } + next.collections.map { (fieldKey($0.path), $0) }, uniquingKeysWith: { _, next in next })
    try writeFragment(next.replacing(value: result, collections: collections.sorted().compactMap { descriptors[$0] }), database: database)
    if old == nil, retired != nil { try validateStoredPageSource(file: file) }
  }
}
