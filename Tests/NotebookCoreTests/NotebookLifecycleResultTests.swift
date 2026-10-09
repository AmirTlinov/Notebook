import Foundation
import Testing
@testable import NotebookCore

@Suite("Lifecycle results are compact immutable domain evidence", .serialized)
struct NotebookLifecycleResultTests {
  private typealias Fixture = NotebookItemLifecycleTests.Fixture

  private func receipt(_ f: Fixture, count: Int = 1, deleted: Bool = false, renamed: Bool = false) throws -> CollaborationReceipt {
    if deleted {
      let header = try f.store.workspaceHeader(), board = CollaborationTarget(kind: .board, id: header.rootBoardID)
      let basis = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
      _ = try f.store.applyCollaborationAction(.init(summary: "Retained neighbor", expected: basis.owners,
        operations: [.init(kind: .createNotebook, target: board, id: UUID().uuidString,
          values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])]), actor: f.actor)
    }
    let extent = try #require(try f.store.readItemLifecycle(f.itemID))
    var command = NotebookCommand(command: .read); command.readSnapshots = true
    command.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(f.itemID)]).decode(NotebookReadQuery.self)]
    let basis = try #require(try NotebookCommandDispatcher(store: f.store).handle(command).array.first?["basis"]?.decode(NotebookReadBasis.self))
    var operations = (0..<count).map { _ in CollaborationOperation(kind: deleted ? .deleteItem : .appendPage,
      target: extent.target, id: deleted ? nil : UUID().uuidString, values: [:]) }
    if renamed {
      operations.append(.init(kind: .renameItem, target: .init(kind: .board, id: try #require(extent.target.boardID)),
        id: f.itemID.uuidString, values: ["title": .string("Saved")]))
    }
    let expected = try f.store.expectations(base: basis, operations: operations)
    return try f.store.applyCollaborationAction(.init(additionalOwners: [extent.target], summary: "Frozen lifecycle",
      expected: expected, operations: operations), actor: f.actor)
  }

  private func freeze(_ receipt: CollaborationReceipt, in store: NotebookStore,
    fields: [CollaborationFieldChange] = []) throws -> JSONValue {
    try store.commandTransaction {
      // Explicit legacy phases below still use the current publication/index
      // owner. A synthetic positive read-model index is never installed.
      let file = "collaboration/actions/" + receipt.id.uuidString.lowercased() + ".json"
      try store.publishRecords(writes: [file: try .encode(receipt)])
      try store.freezeActionResult(receipt, changed: fields)
    }
    return try store.scriptActionOutcome(receipt)
  }

  private func withUndo(_ receipt: CollaborationReceipt, events: [JSONValue], restored: Int = 1) throws -> CollaborationReceipt {
    let undo: JSONValue = .object(["restored": .number(Double(restored)), "preserved": .array([]),
      "completedAt": try .encode(Date()), "lifecycleChanges": .array(events)])
    return try JSONValue.encode(receipt).setting("undo", undo).decode(CollaborationReceipt.self)
  }

  @Test func originalAppendCarriesTheSavedHeaderAndNeverSubstitutesLaterContent() throws {
    let f = try Fixture(), receipt = try receipt(f), lifecycle = try #require(receipt.lifecycleChanges?.first)
    let original = try freeze(receipt, in: f.store), changed = try #require(original["changed"]?.array.first)
    #expect(changed["change"] == .string("appendPage"))
    #expect(changed["target"] == (try .encode(lifecycle.target)))
    #expect(changed["pageID"] == (try .encode(lifecycle.pageID)))
    #expect(changed["item"] == (try .encode(lifecycle.afterItem)))
    #expect(changed["file"] == nil && changed["records"] == nil)
    #expect(original["changeCount"] == .number(1))
    #expect(original["publication"]?["shownOnIPad"] == .string("awaiting_display"))
    _ = try f.append(); _ = try f.append()
    #expect(try freeze(receipt, in: f.store) == original)
    #expect(try f.store.savedActionResult(receipt.id) == original)
    let model = try f.store.actionVersionModel(receipt.id, version: receipt.deliveryVersion())
    #expect(try JSONValue.encode(model)["lifecycleChanges"] == JSONValue.encode(receipt)["lifecycleChanges"])
  }

  @Test func deletionNamesOnlyTheBeforeHeaderAndUndoReportsOnlyItsActualRestoration() throws {
    let f = try Fixture(), receipt = try receipt(f, deleted: true), lifecycle = try #require(receipt.lifecycleChanges?.first)
    let original = try freeze(receipt, in: f.store)
    #expect(original["changed"]?.array == [.object(["change": .string("deletedItem"),
      "target": try .encode(lifecycle.target), "item": try .encode(lifecycle.beforeItem)])])
    let event: JSONValue = .object(["kind": .string("restoreItem"), "target": try .encode(lifecycle.target),
      "item": try .encode(lifecycle.beforeItem)])
    let undone = try f.store.undoCollaborationAction(receipt.id, actor: UUID()), result = try freeze(undone, in: f.store)
    #expect(result["changed"]?.array == [event.setting("kind", nil).setting("change", .string("restoreItem"))])
    #expect(result["actionVersion"] != original["actionVersion"])
    #expect(try f.store.savedActionResult(receipt.id) == original)
    #expect(try f.store.savedActionResult(receipt.id, version: undone.deliveryVersion()) == result)
    let model = try f.store.actionVersionModel(receipt.id, version: undone.deliveryVersion())
    #expect(try JSONValue.encode(model)["undo"]?["lifecycleChanges"] == .array([event]))
  }

  @Test func preservedAndLegacyUndoNeverEchoOriginalLifecycleOrInferItFromRestoredCount() throws {
    let f = try Fixture(), original = try receipt(f)
    for restored in [0, 7] {
      let undo = try withUndo(original, events: [], restored: restored), result = try freeze(undo, in: f.store)
      #expect(result["changed"] == .array([]))
      #expect(result["changeCount"] == .number(0))
    }
    let legacy = try JSONValue.encode(withUndo(original, events: [], restored: 3))
      .setting("undo", .object(["restored": .number(3), "preserved": .array([]), "completedAt": .number(1)]))
      .decode(CollaborationReceipt.self)
    #expect(try freeze(legacy, in: f.store)["changed"] == .array([]))
  }

  @Test func actualRemovePageIsDistinctFromAppendAndKeepsItsPostUndoHeader() throws {
    let f = try Fixture(), original = try receipt(f), lifecycle = try #require(original.lifecycleChanges?.first)
    let event: JSONValue = .object(["kind": .string("removePage"), "target": try .encode(lifecycle.target),
      "pageID": try .encode(lifecycle.pageID), "item": try .encode(lifecycle.beforeItem)])
    let undo = try f.store.undoCollaborationAction(original.id, actor: UUID()), result = try freeze(undo, in: f.store)
    #expect(result["changed"]?.array == [event.setting("kind", nil).setting("change", .string("removePage"))])
    #expect(result["publication"]?["shownOnIPad"] == .string("awaiting_display"))
  }

  @Test func fieldAndLifecyclePaginationShareTheExactFrozenVersionWithoutRawBodies() throws {
    let f = try Fixture(), receipt = try receipt(f, count: 40, renamed: true)
    let first = try freeze(receipt, in: f.store)
    #expect(first["changeCount"] == .number(41))
    #expect(first["changed"]?.array.count == 32)
    #expect(first["changed"]?.array.first?["change"] == .string("updated"))
    let next = try #require(first["next"]?.string), version = try receipt.deliveryVersion()
    let rest = try f.store.actionResultPage(receipt.id, version: version, next: next)
    #expect(rest["changed"]?.array.count == 9 && rest["next"] == nil)
    #expect(rest["changed"]?.array.allSatisfy { $0["change"] == .string("appendPage") } == true)
    #expect(rest["actionVersion"] == first["actionVersion"])
    #expect(try JSONEncoder().encode(rest).count < 16_384)
    let undo = try f.store.undoCollaborationAction(receipt.id, actor: UUID()); _ = try freeze(undo, in: f.store)
    #expect(try f.store.actionResultPage(receipt.id, version: version, next: next) == rest)
    #expect(throws: CollaborationError.self) {
      _ = try f.store.actionResultPage(receipt.id, version: undo.deliveryVersion(), next: next)
    }
  }

  @Test func historicalReadModelWithoutLifecycleFieldsStillDecodes() throws {
    let f = try Fixture(), original = try receipt(f)
    let undo = try withUndo(original, events: [])
    var raw = try JSONValue.encode(NotebookActionReadModel(undo)).setting("lifecycleChanges", nil)
    raw = raw.setting("undo", raw["undo"]?.setting("lifecycleChanges", nil))
    let historical = try raw.decode(NotebookActionReadModel.self)
    #expect(historical.id == original.id)
    #expect(historical.undo?.restored == 1)
    #expect(try JSONValue.encode(historical)["lifecycleChanges"] == nil)
    #expect(try JSONValue.encode(historical)["undo"]?["lifecycleChanges"] == nil)
  }

  @Test func detailSectionsPaginateOriginalLifecycleAndOnlyActualUndoEvents() throws {
    let f = try Fixture(), original = try receipt(f, count: 40), lifecycle = try #require(original.lifecycleChanges?.first)
    _ = try freeze(original, in: f.store)
    for change in original.lifecycleChanges!.dropFirst() {
      try f.write(try #require(change.pageID), text: "Human continuation retained by Undo")
    }
    let undone = try f.store.undoCollaborationAction(original.id, actor: UUID())
    let retained = try #require(try f.store.readItemHeader(f.itemID))
    #expect(retained.pageCount == 40)
    let event: JSONValue = .object(["kind": .string("removePage"), "target": try .encode(lifecycle.target),
      "pageID": try .encode(lifecycle.pageID), "item": try .encode(retained)])
    #expect(undone.undo?.lifecycleChanges?.count == 1)
    _ = try freeze(undone, in: f.store)
    let oldModel = try f.store.actionVersionModel(original.id, version: original.deliveryVersion())
    let newModel = try f.store.actionVersionModel(original.id, version: undone.deliveryVersion())
    let first = try f.store.actionDetails(oldModel, page: .init(section: .changes))
    #expect(first["page"]?["total"] == .number(40))
    #expect(first["page"]?["items"]?.array.count == 32)
    #expect(first["page"]?["items"]?.array.first?["change"] == .string("appendPage"))
    #expect(first["page"]?["nextOffset"] == .number(32))
    let last = try f.store.actionDetails(oldModel, page: .init(section: .changes, offset: 32))
    #expect(last["page"]?["items"]?.array.count == 8)
    let beforeUndo = try f.store.actionDetails(oldModel, page: .init(section: .undo))
    #expect(beforeUndo["page"]?["items"] == .array([]))
    let afterUndo = try f.store.actionDetails(newModel, page: .init(section: .undo))
    #expect(afterUndo["page"]?["items"] == .array([
      .object(["target": try .encode(lifecycle.target), "reason": .string("lifecycle_owner_continued")]),
      event.setting("kind", nil).setting("change", .string("removePage"))]))
    #expect(afterUndo["page"]?["total"] == .number(2))
  }

  @Test func transactionCompletionAfterUndoStillReturnsTheOriginalFrozenVersion() throws {
    let f = try Fixture(), original = try receipt(f)
    let saved = try freeze(original, in: f.store)
    let undone = try f.store.undoCollaborationAction(original.id, actor: UUID()), undoResult = try freeze(undone, in: f.store)
    #expect(try f.store.completeScriptAction(nil, receipt: undone, method: "transaction") == saved)
    #expect(try f.store.completeScriptAction(nil, receipt: undone, method: "undo") == undoResult)
  }

  @Test func preservedLifecycleGroupIsExplicitAndNeverInventsAFieldChangeOrRestoration() throws {
    let f = try Fixture(), original = try receipt(f), lifecycle = try #require(original.lifecycleChanges?.first)
    try f.write(try #require(lifecycle.pageID), text: "Human continuation keeps this page")
    let undone = try f.store.undoCollaborationAction(original.id, actor: UUID())
    let targets = try JSONValue.encode([lifecycle.target])
    let result = try freeze(undone, in: f.store)
    #expect(result["undo"]?["preservedCount"] == .number(1))
    #expect(result["changed"] == .array([]))
    let model = try f.store.actionVersionModel(original.id, version: undone.deliveryVersion())
    #expect(try JSONValue.encode(model)["undo"]?["preservedLifecycle"] == targets)
    let detail = try f.store.actionDetails(model, page: .init(section: .undo))
    #expect(detail["page"]?["items"] == .array([.object(["target": try .encode(lifecycle.target),
      "reason": .string("lifecycle_owner_continued")])]))
    #expect(detail["page"]?["total"] == .number(1))
  }
}
