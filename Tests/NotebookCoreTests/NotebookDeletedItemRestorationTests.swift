import Foundation
import CSQLite
import Testing
@testable import NotebookCore

@Suite("Addressed notebook deletion restoration", .serialized)
struct NotebookDeletedItemRestorationTests {
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    var store: NotebookStore { content.store }
    var itemID: UUID { content.itemID }
    var pageID: UUID { content.pageID }
    var actor: UUID { content.actor }
    let target: CollaborationTarget

    init() throws {
      content = try NotebookItemLifecycleTests.Fixture()
      let header = try content.store.workspaceHeader()
      let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
      target = .init(kind: .cover, id: content.itemID, boardID: header.rootBoardID)
      let base = try content.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
      _ = try content.store.applyCollaborationAction(.init(summary: "Neighbor retained by deletion", expected: base.owners, operations: [
        .init(kind: .createNotebook, target: board, id: UUID().uuidString,
          values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])
      ]), actor: content.actor)
    }

    func deletion(after operations: [CollaborationOperation] = []) throws -> CollaborationReceipt {
      let query = try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(itemID)]).decode(NotebookReadQuery.self)
      var command = NotebookCommand(command: .read); command.queries = [query]; command.readSnapshots = true
      let result = try #require(try NotebookCommandDispatcher(store: store).handle(command).array.first)
      var basis = try #require(try result["basis"]?.decode(NotebookReadBasis.self))
      let pageTargets = operations.map(\.target).filter { $0.kind == .page }
      if !pageTargets.isEmpty { basis = try .merging([basis, store.readBasis(targets: pageTargets)]) }
      let all = operations + [.init(kind: .deleteItem, target: target)]
      let expected = try store.expectations(base: basis, operations: all)
      return try store.applyCollaborationAction(.init(additionalOwners: [target], summary: "Delete admitted notebook", expected: expected, operations: all), actor: actor)
    }

    func restore(_ receipt: CollaborationReceipt) throws -> NotebookLifecycleUndoResult {
      try store.commandTransaction {
        let prepared = try store.prepareDeletedItemUndo(receipt: receipt, actor: UUID())
        defer { try? prepared?.clear() }
        let captureID = NotebookStore.submissionID(receipt.id, suffix: "lifecycle-undo")
        var result = try store.currentSQL!.withActionRecordCapture(actionID: captureID) {
          try store.publishDeletedItemUndo(prepared)
        }
        result.restorationInverse = try store.saveLifecycleInverse(actionID: receipt.id, captureID: captureID)
        return result
      }
    }

    // Simulate a well-hashed, workspace/action-bound incoming inverse whose
    // placement source violates its native owner identity. Hash validity alone
    // must never authorize a different item as this restored cover.
    func changingBefore(_ receipt: CollaborationReceipt, address: String,
      value: (JSONValue) throws -> JSONValue) throws -> CollaborationReceipt {
      try store.commandTransaction {
        let reference = try #require(receipt.lifecycleInverse)
        let root = try store.readLifecycleInverseRoot(reference: reference, actionID: receipt.id)
        var parts: [String] = [], changed = false
        for (ordinal, hash) in root.parts.enumerated() {
          let part = try store.readLifecycleInversePart(hash: hash, actionID: receipt.id, ordinal: ordinal)
          let records = try part.records.map { record -> NotebookActionRecordChange in
            guard record.address == address, let previous = record.beforeHash else { return record }
            let row = try store.readLifecycleInverseFragment(hash: previous, address: address)
            let next = try row.replacing(value: value(row.value))
            let nextHash = try store.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(next))
            changed = true
            return .init(address: address, beforeHash: nextHash, afterHash: record.afterHash)
          }
          let next = NotebookLifecycleInversePart(format: part.format, workspaceID: part.workspaceID,
            actionID: part.actionID, ordinal: ordinal, records: records)
          parts.append(try store.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(next)))
        }
        #expect(changed)
        let next = NotebookLifecycleInverseRoot(format: root.format, workspaceID: root.workspaceID,
          actionID: receipt.id, recordCount: root.recordCount, parts: parts)
        let hash = try store.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(next))
        var modified = receipt
        modified.lifecycleInverse = .init(rootHash: hash, recordCount: root.recordCount)
        return modified
      }
    }


  }

  @Test func lifecycleRestorationLeavesPageEditsToTheExistingConditionalUndoOwner() throws {
    let f = try Fixture()
    try f.content.write(f.pageID, text: "Before all operations")
    let item = try #require(try f.store.readItemHeader(f.itemID))
    let board = CollaborationTarget(kind: .board, id: f.target.boardID!)
    let receipt = try f.deletion(after: [
      .init(kind: .renameItem, target: board, id: f.itemID.uuidString, values: ["title": .string("Transient title")]),
      .init(kind: .updateElement, target: .init(kind: .page, id: f.pageID), id: "label",
        values: ["source": .string("Transient source"), "html": .string("<p>Transient source</p>")])
    ])
    let retained = try #require(try f.store.storedValue(pageFile(f.pageID))?.decode(PageDocument.self))
    let result = try f.restore(receipt)
    #expect(result.changes.count == 1 && result.preserved.isEmpty)
    #expect(result.changes.first?.kind == .restoreItem)
    #expect(result.changes.first?.item == item)
    #expect(try f.store.loadPage(f.pageID) == retained,
      "Lifecycle only restores owners; ordinary conditional undo owns prior source edits")
    #expect(try f.store.ownerBoardID(of: f.itemID) == f.target.boardID)
    let reference = try #require(result.restorationInverse)
    var fields = 0
    try f.store.visitLifecycleInverse(reference: reference, actionID: receipt.id) { record in
      if record.address.hasPrefix("workspace.json#/collaboration/fields/@"), record.beforeHash != nil, record.afterHash != nil {
        fields += 1
      }
    }
    #expect(fields >= 3, "Fresh lifecycle ownership must have bounded, durable before/after provenance")
  }

  @Test func appendThenDeleteRestoresOnlyThePreActionPageOrder() throws {
    let f = try Fixture(), previousLast = try f.content.append(), transient = UUID()
    let order = try f.store.readTransaction { try $0.readPageOrder(f.itemID) }
    let receipt = try f.deletion(after: [.init(kind: .appendPage, target: f.target, id: transient.uuidString)])
    let result = try f.restore(receipt)
    #expect(result.changes.count == 1)
    #expect(try f.store.pageCount(in: f.itemID) == 2)
    #expect(try f.store.pageID(at: 0, in: f.itemID) == f.pageID)
    #expect(try f.store.pageID(at: 1, in: f.itemID) == previousLast)
    #expect(try !f.store.hasStoredValue(pageFile(transient)))
    let restored = try f.store.readTransaction { try $0.readPageOrder(f.itemID) }
    #expect(restored.visibleRoot == order.visibleRoot)
    #expect(restored.heads.count == 1 && restored.heads[0].version.human)
    #expect(restored.heads[0].version != order.heads[0].version)
  }

  @Test func anotherHumanTombstoneWithTheSamePosePreservesTheWholeDeletion() throws {
    let f = try Fixture(), receipt = try f.deletion()
    let before = try f.store.loadBoard(items: f.store.loadIndex().items)
    var after = before
    let authored = after.restorePlacement(itemID: f.itemID, on: f.target.boardID!, pose: nil, actor: UUID())
    #expect(authored)
    _ = try f.store.saveBoardEdits(before: before, after: after)
    let cursor = try f.store.currentChangeCursor()
    let result = try f.restore(receipt)
    #expect(result.changes.isEmpty && result.preserved == [f.target])
    #expect(result.restorationInverse == nil)
    #expect(try f.store.readItemHeader(f.itemID) == nil)
    #expect(throws: (any Error).self) { _ = try f.store.loadPage(f.pageID) }
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func allPagesBeyondOneStreamingBatchRestoreWithTheirOriginalIdentities() throws {
    let f = try Fixture()
    var pages = [f.pageID]
    for _ in 0..<65 { pages.append(try f.content.append()) }
    try f.content.write(pages.last!, text: "Last page, outside the first batch")
    let last = try f.store.loadPage(pages.last!), receipt = try f.deletion()
    let result = try f.restore(receipt)
    #expect(result.changes.count == 1 && result.changes.first?.item?.pageCount == pages.count)
    for (position, page) in pages.enumerated() {
      #expect(try f.store.pageID(at: position, in: f.itemID) == page)
      #expect(try f.store.hasStoredValue(pageFile(page)))
    }
    #expect(try f.store.loadPage(pages.last!) == last)
  }

  @Test func restoringMembershipDoesNotDecodeAnAlreadyAdmittedPageBodyAgain() throws {
    let f = try Fixture()
    try f.content.write(f.pageID, text: String(repeating: "Retained source ", count: 1024))
    let receipt = try f.deletion()
    final class Trace {
      let file: String
      var bodyAddresses = Set<String>()
      init(_ file: String) { self.file = file }
    }
    let trace = Trace(pageFile(f.pageID))
    let result = try f.store.commandTransaction {
      let database = f.store.currentSQL!
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_ROW), { _, context, statement, _ in
        let trace = Unmanaged<Trace>.fromOpaque(context!).takeUnretainedValue()
        let statement = OpaquePointer(statement!)
        for column in 0..<sqlite3_column_count(statement) where sqlite3_column_type(statement, column) == SQLITE_BLOB {
          guard let bytes = sqlite3_column_blob(statement, column) else { continue }
          let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
          guard let row = try? JSONDecoder().decode(NotebookStoredFragment.self, from: data), row.file == trace.file,
            ![trace.file + "#", trace.file + "#/drawingData"].contains(row.address) else { continue }
          trace.bodyAddresses.insert(row.address)
        }
        return 0
      }, Unmanaged.passUnretained(trace).toOpaque())
      defer { sqlite3_trace_v2(database.handle, 0, nil, nil) }
      return try f.restore(receipt)
    }
    #expect(result.changes.count == 1)
    #expect(trace.bodyAddresses.isEmpty,
      "Restoring live membership must reuse the typed retained baseline, not decode its source again")
  }

  @Test func anUnownedLosingExistenceHeadPreservesDeletionDespiteTheSameWinner() throws {
    let f = try Fixture(), receipt = try f.deletion()
    try f.store.commandTransaction {
      let key = fieldKey(["items", f.itemID.uuidString.lowercased(), "exists"])
      let address = "workspace.json#/collaboration/fields/@" + fieldKey([key])
      let row = try #require(try f.store.storedFragments(address: address, descendants: false).first)
      let original = try row.value.decode(ContentFieldVersion.self)
      let loser = ContentFieldVersion(stamp: .init(counter: 0, actor: UUID()), human: false)
      let joined = try original.joining(loser)
      #expect(joined.stamp == original.stamp && joined.human == original.human)
      #expect(joined != original)
      try f.store.writeFragment(row.replacing(value: .encode(joined)), database: f.store.currentSQL!)
    }
    let cursor = try f.store.currentChangeCursor()
    let result = try f.restore(receipt)
    #expect(result.changes.isEmpty && result.preserved == [f.target])
    #expect(try f.store.readItemHeader(f.itemID) == nil)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func deletedCoverProgramsAndOriginalInkReturnWithoutInventingNewSourceDots() throws {
    let f = try Fixture(), stroke = UUID(), pageTarget = CollaborationTarget(kind: .page, id: f.pageID)
    let coverBasis = try f.store.readBasis(targets: [f.target])
    _ = try f.store.applyCollaborationAction(.init(additionalOwners: [f.target], summary: "Original cover source", expected: coverBasis.owners, operations: [
      .init(kind: .insertElement, target: f.target, id: "cover-source", values: ["kind": .string("markdown"),
        "frame": try .encode(PageRect(x: 10, y: 10, width: 100, height: 60)),
        "source": .string("Original cover program"), "html": .string("<p>Original cover program</p>")])
    ]), actor: f.actor)
    let inkBasis = try f.store.readBasis(targets: [pageTarget])
    _ = try f.store.applyCollaborationAction(.init(summary: "Original stroke", expected: inkBasis.owners, operations: [
      .init(kind: .appendInkStroke, target: pageTarget, id: stroke.uuidString,
        values: ["points": .array([.object(["x": .number(20), "y": .number(20)])])])
    ]), actor: f.actor)
    let source = try #require(try f.store.readSpatialElement(boardID: f.target.boardID!, elementID: "cover-source"))
    let drawing = try PageInkDrawing.decode(f.store.loadPage(f.pageID).drawingData)
    let receipt = try f.deletion()
    #expect(try f.store.readSpatialElement(boardID: f.target.boardID!, elementID: "cover-source") == nil)
    _ = try f.restore(receipt)
    #expect(try f.store.readSpatialElement(boardID: f.target.boardID!, elementID: "cover-source") == source)
    #expect(try PageInkDrawing.decode(f.store.loadPage(f.pageID).drawingData) == drawing)
  }

  @Test func forgedDeletedKindRefusesBeforeAnyContentEffect() throws {
    let f = try Fixture(), receipt = try f.deletion()
    var unsupported = receipt
    let document = NotebookItemHeader(id: f.itemID, kind: .document, title: "Forged document", firstPageID: nil, pageCount: 0)
    unsupported.lifecycleChanges = [.init(kind: .deleteItem, target: f.target, pageID: nil, beforeItem: document, afterItem: nil)]
    let cursor = try f.store.currentChangeCursor()
    do { _ = try f.restore(unsupported); Issue.record("A forged lifecycle kind must refuse before restoration") }
    catch let error as NotebookStorageError { #expect(error == .invalidTransaction("pre-action item header")) }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.readItemHeader(f.itemID) == nil)
    #expect(throws: (any Error).self) { _ = try f.store.loadPage(f.pageID) }
  }

  @Test func restoringTwoDeletedItemsKeepsTheirOriginalCatalogueOrder() throws {
    let f = try Fixture(), board = CollaborationTarget(kind: .board, id: f.target.boardID!)
    let second = try #require(try f.store.loadIndex().items.first { $0.id != f.itemID })
    let createBasis = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: board.id)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Third item remains live", expected: createBasis.owners, operations: [
      .init(kind: .createNotebook, target: board, id: UUID().uuidString,
        values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])
    ]), actor: f.actor)
    let before = try f.store.loadIndex().items.map(\.id)
    let targets = [f.target, CollaborationTarget(kind: .cover, id: second.id, boardID: board.id)]
    var command = NotebookCommand(command: .read); command.readSnapshots = true
    command.queries = try targets.map { target in
      try JSONValue.object(["kind": .string("itemLifecycle"), "id": .encode(target.id)]).decode(NotebookReadQuery.self)
    }
    let bases = try NotebookCommandDispatcher(store: f.store).handle(command).array.map {
      try #require(try $0["basis"]?.decode(NotebookReadBasis.self))
    }
    let operations = targets.map { CollaborationOperation(kind: .deleteItem, target: $0) }
    let expected = try f.store.expectations(base: .merging(bases), operations: operations)
    let receipt = try f.store.applyCollaborationAction(.init(additionalOwners: targets, summary: "Delete two original items",
      expected: expected, operations: operations), actor: f.actor)
    let result = try f.restore(receipt)
    #expect(result.changes.count == 2 && result.preserved.isEmpty)
    #expect(try f.store.loadIndex().items.map(\.id) == before,
      "The first restoration's own order dot must not look like a foreign continuation to the second")
  }

  @Test func aWellHashedPlacementOfAnotherItemIsRefusedAtomically() throws {
    let f = try Fixture(), original = try f.deletion()
    let address = "board.json#/boards/@" + f.target.boardID!.uuidString.lowercased()
      + "/board/placements/@" + f.itemID.uuidString.lowercased()
    let receipt = try f.changingBefore(original, address: address) { value in
      try value.setting("itemID", .encode(UUID()))
    }
    let cursor = try f.store.currentChangeCursor()
    #expect(throws: (any Error).self) { _ = try f.restore(receipt) }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.readItemHeader(f.itemID) == nil)
    #expect(throws: (any Error).self) { _ = try f.store.loadPage(f.pageID) }
  }
}
