import Foundation

extension NotebookStore {
  /// Elements, ink and computations have separate causal owners. Receiving a
  /// frame edit must not decode either the drawing or another element.
  func applyReplicatedPage(file: String, manifestHash: String) throws {
    let records = NotebookIncomingRecords(store: self, manifestHash: manifestHash)
    let database = currentSQL!, root = file + "#"
    guard let id = UUID(uuidString: String(file.dropFirst(6).dropLast(5))), pageFile(id) == file else {
      throw NotebookStorageError.invalidTransaction("page owner")
    }
    guard try ownerItemID(ofPage: id) != nil else { try removeFragment(root, database: database); return }
    let old = try records.previous(root)
    guard let next = try records.candidate(root) else { throw NotebookStorageError.invalidTransaction("live page retains content") }
    func header(_ row: NotebookStoredFragment) throws -> PageDocument {
      let value = row.value.setting("elements", .array([])).setting("drawingData", try .encode(Data()))
        .setting("collaboration", .object(["fields": .object([:])]))
      let page = try value.decode(PageDocument.self)
      guard page.id == id, page.isValid, row.parent == nil, row.collection.isEmpty, row.member.isEmpty,
        row.position == 0, row.collections.contains(.init(path: ["drawingData"], kind: .pageInk)),
        row.collections.contains(.init(path: ["elements"], kind: .array)),
        row.collections.allSatisfy({ [.init(path: ["drawingData"], kind: .pageInk), .init(path: ["elements"], kind: .array),
          .init(path: ["collaboration", "fields"], kind: .dictionary), .init(path: ["computations"], kind: .array)].contains($0) }) else {
        throw NotebookStorageError.corruptRecord(root)
      }
      let canonical = try NotebookRecordCodec.encode(.encode(page), file: file).first { $0.address == root }
      guard canonical == row.replacing(value: row.value, collections: row.collections.filter { $0.path != ["computations"] }) else {
        throw NotebookStorageError.corruptRecord(root)
      }
      return page
    }
    let candidate = try header(next), previous = try old.map(header)
    guard previous == nil || previous?.size == candidate.size else { throw NotebookStorageError.transactionConflict }
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
  }
}
