import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookActionDeliveryTests: XCTestCase {
  func testNativeRefreshAcknowledgesANewEmptyUndoPhaseWithoutClaimingDisplay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let target = CollaborationTarget(kind: .board, id: boardID), actor = model.actorID
    let action = try await model.performStoreCommand { store in
      _ = try store.applyCollaborationAction(.init(summary: "A real control", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .insertElement, target: target, id: "delivery", values: ["kind": .string("web"),
          "source": .string("<button>Value</button>"), "state": .number(0),
          "frame": try .encode(PageRect(x: 0, y: 0, width: 200, height: 80)),
          "worldOrigin": try .encode(WorldPoint.zero)])]), actor: actor)
      return try store.applyCollaborationAction(.init(summary: "No changed value", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .setElementState, target: target, id: "delivery", values: ["state": .number(0)])]), actor: actor)
    }
    await model.reloadExternalChanges()?.value
    let initial = try XCTUnwrap(model.store.deviceActionReceipts(actionIDs: [action.id]).first)
    XCTAssertEqual(initial.actionVersion, try action.deliveryVersion())
    let undo = try await model.performStoreCommand { try $0.undoCollaborationAction(action.id, actor: actor) }
    XCTAssertTrue(undo.revisions.isEmpty)
    XCTAssertNotEqual(try undo.deliveryVersion(), initial.actionVersion)
    await model.reloadExternalChanges()?.value
    await model.refreshCollaborationDetails()
    let latest = try XCTUnwrap(model.store.deviceActionReceipts(actionIDs: [action.id]).first)
    XCTAssertEqual(latest.actionVersion, try undo.deliveryVersion())
    XCTAssertGreaterThanOrEqual(latest.receivedAt, try XCTUnwrap(undo.undo).completedAt)
    model.confirmVisibleActions(presence: try XCTUnwrap(model.presence))
    let flushed = await model.finishPendingPersistence(); XCTAssertTrue(flushed)
    let afterOpportunity = try XCTUnwrap(model.store.deviceActionReceipts(actionIDs: [action.id]).first)
    XCTAssertEqual(afterOpportunity, latest)
    XCTAssertFalse(afterOpportunity.displayComplete)
    XCTAssertTrue(afterOpportunity.shown.isEmpty && afterOpportunity.visibleRegions.isEmpty)
    let rejected = try await model.performStoreCommand { try $0.saveDeviceActionReceipt(initial) }
    XCTAssertFalse(rejected)
    XCTAssertEqual(try model.store.deviceActionReceipts(actionIDs: [action.id]).first, latest)
  }
}
