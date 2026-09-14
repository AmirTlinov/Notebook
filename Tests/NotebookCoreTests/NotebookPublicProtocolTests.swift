import Foundation
import Testing
@testable import NotebookCore

@Suite("Public protocol counterexamples use native owners")
struct NotebookPublicProtocolTests {
  private struct Fixture {
    let store: NotebookStore
    let actor = UUID()
    let index: WorkspaceIndex
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-public-protocol-\(UUID())"))
      index = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194)).0
      _ = try store.loadOrCreateSpatialInk(actor: actor)
    }
    func clean() { try? FileManager.default.removeItem(at: store.root) }
    var board: CollaborationTarget { .init(kind: .board, id: index.rootBoardID) }
    func expectation(_ target: CollaborationTarget) throws -> CollaborationExpectation {
      .init(target: target, revision: try store.targetContentRevision(target: target))
    }
    func insert() -> CollaborationOperation {
      .init(kind: .insertElement, target: board, id: "must-remain-absent", values: ["kind": .string("nativeText"),
        "source": .string("PRIVATE SUBMITTED SOURCE"), "worldOrigin": .object(["tileX": .number(0), "tileY": .number(0), "localX": .number(0), "localY": .number(0)]),
        "frame": .object(["x": .number(0), "y": .number(0), "width": .number(200), "height": .number(80)])])
    }
  }

  @Test func minimalPublicPlacementReachesTheNativePlannerWithoutOptionalLists() throws {
    let f = try Fixture(); defer { f.clean() }
    let target = CollaborationTarget(kind: .page, id: f.index.selectedPageID!)
    let placement: JSONValue = .object(["target": try .encode(target),
      "expectedRevision": .string(try f.store.targetContentRevision(target: target)),
      "items": .array([.object(["id": .string("next-note"), "size": .object(["width": .number(180), "height": .number(100)]), "direction": .string("free")])])])
    let command = try NotebookIPC.decodeCommand(JSONEncoder().encode(JSONValue.object(["command": .string("placement"), "placement": placement])))
    #expect(command.placement?.movable.isEmpty == true)
    #expect(command.placement?.additionalOwners.isEmpty == true)
    let result = try NotebookCommandDispatcher(store: f.store).handle(command).decode(CollaborationPlacement.self)
    #expect(result.status == .snapshotPending)
    #expect(result.renderRequest?.target == target)
    #expect(result.placements.isEmpty && result.moves.isEmpty)
    #expect(try f.store.loadPage(target.id).elements.isEmpty)
    guard case .object(var malformed) = placement else { return }
    malformed["movable"] = .string("invalid list")
    #expect(throws: CollaborationError.self) {
      try NotebookIPC.decodeCommand(JSONEncoder().encode(JSONValue.object(["command": .string("placement"), "placement": .object(malformed)])))
    }
  }

  @Test(arguments: [false, true])
  func failedOperationHasItsOwnAddressAndRollsBackEarlierOperations(projectionFailure: Bool) throws {
    let f = try Fixture(); defer { f.clean() }
    let run = UUID()
    _ = try f.store.admitScriptRun(.init(op: .start, runID: run, apiVersion: 1, code: "atomic protocol proof"))
    _ = try f.store.setScriptRunState(run, state: .running)
    var effect = try f.store.admitScriptEffect(run, key: "atomic", method: "transaction", arguments: .object([:]))
    effect.state = .committing; try f.store.saveScriptEffect(run, effect: effect)
    let failed = projectionFailure
      ? CollaborationOperation(kind: .reorderElements, target: f.board, values: ["ids": .array([.string("absent")])])
      : CollaborationOperation(kind: .removeElement, target: f.board, id: "absent")
    let action = CollaborationAction(id: effect.id, additionalOwners: [f.board], summary: "A later operation rejects the whole action",
      expected: [try f.expectation(f.board)], operations: [f.insert(), failed])
    let before = try f.store.readBoardNode(f.index.rootBoardID)
    let failure: CollaborationError
    do { _ = try f.store.applyCollaborationAction(action, actor: f.actor); Issue.record("A missing member must reject"); return }
    catch let error as CollaborationError { failure = error }
    #expect(failure.code == (projectionFailure ? "invalid_operation" : "target_missing"))
    #expect(failure.operation == .init(index: 1, operation: failed))
    #expect(try f.store.readBoardNode(f.index.rootBoardID) == before)
    #expect(try f.store.collaborationActionIfPresent(effect.id) == nil)
    let resolved = try f.store.reconcileScriptEffect(run, id: effect.id, failure: .encode(failure))
    #expect(resolved.state == .notSaved)
    #expect(try resolved.error?.decode(CollaborationError.self) == failure)
    let compact = try f.store.scriptRunPage(run)["effects"]?.array.first?["error"]
    #expect(try compact?["operation"]?.decode(CollaborationOperationDiagnostic.self) == failure.operation)
    #expect(compact?["code"]?.string == failure.code)
    #expect(!String(decoding: try JSONEncoder().encode(compact), as: UTF8.self).contains("PRIVATE SUBMITTED SOURCE"))
  }

  @Test func renameTargetsTheContainingBoardAndAlsoExpectsTheWorkspaceCatalogue() throws {
    let f = try Fixture(); defer { f.clean() }
    let workspace = CollaborationTarget(kind: .workspace, id: f.index.rootBoardID)
    let expected = [try f.expectation(f.board), try f.expectation(workspace)]
    let wrong = CollaborationOperation(kind: .renameItem, target: workspace, id: f.index.selectedItemID.uuidString, values: ["title": .string("New title")])
    do {
      _ = try f.store.applyCollaborationAction(.init(summary: "Wrong owner", expected: expected, operations: [wrong]), actor: f.actor)
      Issue.record("Workspace is not the rename operation target")
    } catch let error as CollaborationError {
      #expect(error.code == "target_missing")
      #expect(error.operation == .init(index: 0, operation: wrong))
    }
    let correct = CollaborationOperation(kind: .renameItem, target: f.board, id: f.index.selectedItemID.uuidString, values: wrong.values)
    _ = try f.store.applyCollaborationAction(.init(summary: "Containing board", expected: expected, operations: [correct]), actor: f.actor)
    #expect(try f.store.readItemHeader(f.index.selectedItemID)?.title == "New title")
  }
}
