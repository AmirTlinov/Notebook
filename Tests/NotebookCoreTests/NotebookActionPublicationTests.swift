import Foundation
import Testing
@testable import NotebookCore

@Suite("Action publication separates no-change undo from installed pixels")
struct NotebookActionPublicationTests {
  private struct Fixture {
    let store: NotebookStore
    let human = UUID(), agent = UUID(), device = UUID()
    let target: CollaborationTarget
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-action-publication-\(UUID())"))
      let index = try store.loadOrCreate(actor: human, pageSize: .init(width: 400, height: 600)).0
      target = .init(kind: .board, id: index.rootBoardID)
      _ = try store.loadOrCreateSpatialInk(actor: human)
      _ = try apply(.init(kind: .insertElement, target: target, id: "control", values: [
        "kind": .string("web"), "source": .string("<button>Value</button>"),
        "frame": try .encode(PageRect(x: 0, y: 0, width: 200, height: 80)),
        "worldOrigin": try .encode(WorldPoint.zero), "state": .number(0)]))
    }
    func clean() { try? FileManager.default.removeItem(at: store.root) }
    func apply(_ operation: CollaborationOperation) throws -> CollaborationReceipt {
      try store.applyCollaborationAction(.init(summary: "A state contribution", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [operation]), actor: agent)
    }
    func set(_ value: Int) throws -> CollaborationReceipt {
      try apply(.init(kind: .setElementState, target: target, id: "control", values: ["state": .number(Double(value))]))
    }
    func humanSet(_ value: Int) throws {
      let rendered = try #require(try store.readSpatialElement(boardID: target.id, elementID: "control"))
      let basis = try #require(store.loadBoard(items: store.loadIndex().items).board(target.id)?.programStateBasis(rendered.id))
      let result = try store.commitSpatialElementState(boardID: target.id, rendered: rendered,
        state: .number(Double(value)), actor: human, expectedProgramBasis: basis)
      #expect(result != nil)
    }
    func details(_ receipt: CollaborationReceipt) throws -> JSONValue {
      var command = NotebookCommand(command: .actionDetails); command.actionID = receipt.id
      return try #require(NotebookCommandDispatcher(store: store).handle(command).array.first)
    }
    func delivery(_ receipt: CollaborationReceipt) throws {
      try store.saveDeviceActionReceipt(.init(id: receipt.id, deviceID: device,
        revisions: receipt.revisions, actionVersion: receipt.deliveryVersion()))
    }
  }

  @Test(arguments: [false, true])
  func preservedHumanUndoNeedsNoPixelsAndStatusReadsDoNotWrite(received: Bool) throws {
    let f = try Fixture(); defer { f.clean() }
    let action = try f.set(1)
    #expect(!action.revisions.isEmpty)
    try f.humanSet(2)
    let human = try #require(try f.store.readSpatialElement(boardID: f.target.id, elementID: "control"))
    let version = try f.store.targetContentRevision(target: f.target)
    let undone = try f.store.undoCollaborationAction(action.id, actor: f.agent)
    #expect(undone.undo?.restored == 0 && undone.undo?.preserved.count == 1)
    #expect(undone.revisions.isEmpty)
    if received { try f.delivery(undone) }
    let receiptFile = "collaboration/actions/" + action.id.uuidString.lowercased() + ".json"
    let receiptRecords = try f.store.sqlRead {
      try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(receiptFile)])
        .map { [$0[0].text!, $0[1].text!] }
    }
    let receipts = try f.store.deviceActionReceipts(actionIDs: [action.id])
    let cursor = try f.store.currentChangeCursor()
    let requests = try f.store.targetRenderRequests()
    for _ in 0..<3 {
      let details = try f.details(undone)
      #expect(details["publication"]?["saved"] == .string("confirmed"))
      #expect(details["publication"]?["receivedByIPad"] == .string(received ? "confirmed" : "awaiting_device"))
      #expect(details["publication"]?["shownOnIPad"] == .string("not_required"))
      #expect(details["publication"]?["shownOnIPadReason"] == .string("undo_without_visual_changes"))
    }
    #expect(try f.store.sqlRead {
      try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(receiptFile)])
        .map { [$0[0].text!, $0[1].text!] }
    } == receiptRecords)
    #expect(try f.store.deviceActionReceipts(actionIDs: [action.id]) == receipts)
    #expect(receipts.allSatisfy { !$0.displayComplete && $0.shown.isEmpty && $0.visibleRegions.isEmpty })
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.targetRenderRequests() == requests)
    #expect(try f.store.readSpatialElement(boardID: f.target.id, elementID: "control") == human)
    #expect(try f.store.targetContentRevision(target: f.target) == version)
    let direct = try f.store.scriptActionOutcome(undone)
    #expect(direct["publication"]?["saved"] == .string("confirmed"))
    #expect(direct["publication"]?["receivedByIPad"] == .string("awaiting_device"),
      "The immutable completion does not add current device delivery claims")
  }

  @Test func mutatingUndoStillRequiresActualDisplayBeyondReceiptArrival() throws {
    let f = try Fixture(); defer { f.clean() }
    let action = try f.set(1)
    let undone = try f.store.undoCollaborationAction(action.id, actor: f.agent)
    #expect(undone.undo?.restored == 1 && !undone.revisions.isEmpty)
    #expect(try f.store.readSpatialElement(boardID: f.target.id, elementID: "control")?.state == .number(0))
    let before = try f.details(undone)
    #expect(before["publication"]?["receivedByIPad"] == .string("awaiting_device"))
    #expect(before["publication"]?["shownOnIPad"] == .string("awaiting_display"))
    try f.delivery(undone)
    let after = try f.details(undone)
    #expect(after["publication"]?["receivedByIPad"] == .string("confirmed"))
    #expect(after["publication"]?["shownOnIPad"] == .string("awaiting_display"))
    #expect(after["publication"]?["shownOnIPadReason"] == nil)
    #expect(try f.store.deviceActionReceipts(actionIDs: [action.id]).allSatisfy { !$0.displayComplete })
  }

  @Test func originalNoChangeEffectHasItsOwnNoPixelsReason() throws {
    let f = try Fixture(); defer { f.clean() }
    let noChange = try f.set(0)
    #expect(noChange.undo == nil && noChange.revisions.isEmpty && noChange.changes.isEmpty)
    let result = try f.details(noChange)
    #expect(result["publication"]?["shownOnIPad"] == .string("not_required"))
    #expect(result["publication"]?["shownOnIPadReason"] == .string("action_without_visual_changes"))
    #expect(result["publication"]?["receivedByIPad"] == .string("awaiting_device"))
    #expect(try f.store.deviceActionReceipts(actionIDs: [noChange.id]).isEmpty)
  }

  @Test func anInkEffectWithoutFieldChangesStillRequiresItsNewPixels() throws {
    let f = try Fixture(); defer { f.clean() }
    let operation = CollaborationOperation(kind: .appendInkStroke, target: f.target, id: UUID().uuidString,
      values: ["points": .array([.object(["x": .number(10), "y": .number(10)]),
        .object(["x": .number(30), "y": .number(20)])]), "worldOrigin": try .encode(WorldPoint.zero)])
    let stroke = try f.store.applyCollaborationAction(.init(summary: "A real ink contribution", expected: [
      .init(target: f.target, revision: f.store.targetContentRevision(target: f.target),
        inkRevision: f.store.loadSpatialInk().stamp.revision)], operations: [operation]), actor: f.agent)
    #expect(stroke.changes.isEmpty && !stroke.revisions.isEmpty)
    #expect(stroke.revisions.first?.inkRevision != nil)
    let result = try f.details(stroke)
    #expect(result["publication"]?["shownOnIPad"] == .string("awaiting_display"))
    #expect(result["publication"]?["shownOnIPadReason"] == nil)
  }

  @Test(arguments: [false, true])
  func incompleteUndoEvidenceCannotQualifyAsNoVisualChange(emptyRevisions: Bool) throws {
    let f = try Fixture(); defer { f.clean() }
    var projection = try f.set(1)
    // Projection-only malformed/legacy boundaries; no device or source write.
    projection.undo = .init(restored: emptyRevisions ? 1 : 0, preserved: [], completedAt: Date())
    if emptyRevisions { projection.revisions = [] }
    let result = try f.store.readTransaction { try $0.actionDetails(NotebookActionReadModel(projection), page: nil) }
    #expect(result["publication"]?["shownOnIPad"] == .string("awaiting_display"))
    #expect(result["publication"]?["shownOnIPadReason"] == nil)
  }
}
