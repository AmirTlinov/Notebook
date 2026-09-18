import Foundation
import Testing
@testable import NotebookCore

@Suite("Lifecycle results are compact immutable domain evidence", .serialized)
struct NotebookLifecycleResultTests {
  private typealias Fixture = NotebookItemLifecycleTests.Fixture

  private func receipt(_ f: Fixture, count: Int = 1, deleted: Bool = false) throws -> CollaborationReceipt {
    let extent = try #require(try f.store.readItemLifecycle(f.itemID)), pages = (0..<count).map { _ in UUID() }
    let after = NotebookItemHeader(id: f.itemID, kind: .notebook, title: extent.item.title,
      firstPageID: f.pageID, pageCount: extent.item.pageCount + count)
    let operations = pages.map { CollaborationOperation(kind: deleted ? .deleteItem : .appendPage,
      target: extent.target, id: deleted ? nil : $0.uuidString, values: [:]) }
    let action = CollaborationAction(summary: "Frozen lifecycle", expected: [], operations: operations)
    var receipt = CollaborationReceipt(id: action.id, action: action, createdAt: Date(), revisions: [], changes: [], undo: nil)
    receipt.lifecycleChanges = pages.map { .init(kind: deleted ? .deleteItem : .appendPage, target: extent.target,
      pageID: deleted ? nil : $0, beforeItem: extent.item, afterItem: deleted ? nil : after) }
    return receipt
  }

  private func freeze(_ receipt: CollaborationReceipt, in store: NotebookStore,
    fields: [CollaborationFieldChange] = []) throws -> JSONValue {
    try store.commandTransaction { try store.freezeActionResult(receipt, changed: fields) }
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
    let undone = try withUndo(receipt, events: [event]), result = try freeze(undone, in: f.store)
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
    let undo = try withUndo(original, events: [event]), result = try freeze(undo, in: f.store)
    #expect(result["changed"]?.array == [event.setting("kind", nil).setting("change", .string("removePage"))])
    #expect(result["publication"]?["shownOnIPad"] == .string("awaiting_display"))
  }

  @Test func fieldAndLifecyclePaginationShareTheExactFrozenVersionWithoutRawBodies() throws {
    let f = try Fixture(), receipt = try receipt(f, count: 40)
    let field = CollaborationFieldChange(file: "workspace.json", path: [.field("title")], before: .string("Before"), after: .string("Saved"))
    let first = try freeze(receipt, in: f.store, fields: [field])
    #expect(first["changeCount"] == .number(41))
    #expect(first["changed"]?.array.count == 32)
    #expect(first["changed"]?.array.first?["change"] == .string("updated"))
    let next = try #require(first["next"]?.string), version = try receipt.deliveryVersion()
    let rest = try f.store.actionResultPage(receipt.id, version: version, next: next)
    #expect(rest["changed"]?.array.count == 9 && rest["next"] == nil)
    #expect(rest["changed"]?.array.allSatisfy { $0["change"] == .string("appendPage") } == true)
    #expect(rest["actionVersion"] == first["actionVersion"])
    #expect(try JSONEncoder().encode(rest).count < 16_384)
    let undo = try withUndo(receipt, events: []); _ = try freeze(undo, in: f.store)
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
    let event: JSONValue = .object(["kind": .string("removePage"), "target": try .encode(lifecycle.target),
      "pageID": try .encode(lifecycle.pageID), "item": try .encode(lifecycle.beforeItem)])
    let undone = try withUndo(original, events: [event]); _ = try freeze(undone, in: f.store)
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
    #expect(afterUndo["page"]?["items"] == .array([event.setting("kind", nil).setting("change", .string("removePage"))]))
    #expect(afterUndo["page"]?["total"] == .number(1))
  }

  @Test func transactionCompletionAfterUndoStillReturnsTheOriginalFrozenVersion() throws {
    let f = try Fixture(), original = try receipt(f), lifecycle = try #require(original.lifecycleChanges?.first)
    let saved = try freeze(original, in: f.store)
    let event: JSONValue = .object(["kind": .string("removePage"), "target": try .encode(lifecycle.target),
      "pageID": try .encode(lifecycle.pageID), "item": try .encode(lifecycle.beforeItem)])
    let undone = try withUndo(original, events: [event]), undoResult = try freeze(undone, in: f.store)
    #expect(try f.store.completeScriptAction(nil, receipt: undone, method: "transaction") == saved)
    #expect(try f.store.completeScriptAction(nil, receipt: undone, method: "undo") == undoResult)
  }

  @Test func preservedLifecycleGroupIsExplicitAndNeverInventsAFieldChangeOrRestoration() throws {
    let f = try Fixture(), original = try receipt(f), lifecycle = try #require(original.lifecycleChanges?.first)
    let raw = try JSONValue.encode(withUndo(original, events: [], restored: 0))
    let targets = try JSONValue.encode([lifecycle.target])
    let undone = try raw.setting("undo", raw["undo"]?.setting("preservedLifecycle", targets)).decode(CollaborationReceipt.self)
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
