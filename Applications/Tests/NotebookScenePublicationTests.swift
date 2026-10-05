import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookScenePublicationTests: XCTestCase {
  func testNewerPreparedCutSurvivesOldWorkerAndWaitsForInputAdmission() async throws {
    let actor = UUID(), (workspace, original) = source(actor: UUID())
    let owner = NotebookScenePublication(actorID: actor)
    let previousObserver = NotebookNavigationObservation.onWebPreparation
    var dispatched = 0, delivered = false
    NotebookNavigationObservation.onWebPreparation = { event, id, _, _ in
      guard id == actor else { return }
      if event == "scene_index_dispatched" { dispatched += 1 }
      if event == "scene_index_delivered" { delivered = true }
    }
    defer { NotebookNavigationObservation.onWebPreparation = previousObserver }
    owner.onPrepared = { [weak owner] in owner?.publish { _ in false } }
    owner.prepare(workspace: workspace, hierarchy: original, paperSizes: [:], coverageOnly: false)
    XCTAssertEqual(dispatched, 1, "Cold dispatch must precede the next UI opportunity")
    var newer = original
    let id = try XCTUnwrap(workspace.selectedItemID), destination = WorldPoint(x: 120, y: 75)
    XCTAssertTrue(newer.moveItem(id, in: workspace.rootBoardID, to: destination, actor: actor))
    owner.accept(.init(workspace: workspace, hierarchy: newer, paperSizes: [:]), hierarchy: newer, coverageOnly: false)
    try await NotebookPersistenceFenceContract.until { delivered }
    XCTAssertNil(owner.index)
    XCTAssertTrue(owner.isPending)
    XCTAssertEqual(dispatched, 1, "An already prepared SQL cut must not be rebuilt after the old worker finishes")
    owner.publish { _ in true }
    XCTAssertEqual(owner.index?.board(id: workspace.rootBoardID)?.placement(of: id)?.center, destination)
    XCTAssertEqual(owner.indexGeneration, 1)
    XCTAssertEqual(owner.publicationGeneration, 1)
    XCTAssertFalse(owner.isPending)

    // An independently prepared catalog refresh of the same source keeps the
    // displayed geometry generation, even while input holds structural changes.
    let generation = owner.index?.generationID
    owner.accept(.init(workspace: workspace, hierarchy: newer, paperSizes: [:]), hierarchy: newer, coverageOnly: false)
    XCTAssertEqual(owner.index?.generationID, generation)
    XCTAssertEqual(owner.indexGeneration, 1)
    XCTAssertEqual(owner.publicationGeneration, 2)
    XCTAssertFalse(owner.isPending)
  }

  func testWarmRequestsCoalesceAndCancelBeforeDeliveryJoinsTheDispatchedWorker() async throws {
    let actor = UUID(), (workspace, original) = source(actor: UUID())
    let owner = NotebookScenePublication(actorID: actor)
    let previousObserver = NotebookNavigationObservation.onWebPreparation
    var cancelledWorkerEnded = false, dispatched = 0
    NotebookNavigationObservation.onWebPreparation = { event, id, request, _ in
      guard id == actor else { return }
      if event == "scene_index_ended", request == "1" { cancelledWorkerEnded = true }
      if event == "scene_index_dispatched" { dispatched += 1 }
    }
    defer { NotebookNavigationObservation.onWebPreparation = previousObserver }
    owner.onPrepared = { [weak owner] in owner?.publish { _ in true } }
    owner.prepare(workspace: workspace, hierarchy: original, paperSizes: [:], coverageOnly: false)
    let cancelled = try XCTUnwrap(owner.cancel())
    XCTAssertNil(owner.index)
    XCTAssertFalse(owner.isPending)
    XCTAssertEqual(owner.publicationGeneration, 0)
    // Start the replacement before joining the old delivery. Its late result
    // must neither publish nor clear the replacement's driver.
    owner.prepare(workspace: workspace, hierarchy: original, paperSizes: [:], coverageOnly: false)
    await cancelled.value
    XCTAssertTrue(cancelledWorkerEnded, "Draining the driver joins its actual dispatched worker")
    try await NotebookPersistenceFenceContract.until { owner.index != nil }
    XCTAssertEqual(owner.publicationGeneration, 1)
    dispatched = 0
    var latest = original
    let id = try XCTUnwrap(workspace.selectedItemID)
    for step in 1...8 {
      XCTAssertTrue(latest.moveItem(id, in: workspace.rootBoardID, to: .init(x: Double(step) * 25, y: 0), actor: actor))
      owner.prepare(workspace: workspace, hierarchy: latest, paperSizes: [:], coverageOnly: false)
    }
    XCTAssertEqual(dispatched, 0, "Warm synchronous changes share their next delivery opportunity")
    try await NotebookPersistenceFenceContract.until { !owner.isPending }
    XCTAssertEqual(dispatched, 1)
    XCTAssertEqual(owner.indexGeneration, 2)
    XCTAssertEqual(owner.publicationGeneration, 2)
    XCTAssertEqual(owner.index?.board(id: workspace.rootBoardID)?.placement(of: id)?.center, .init(x: 200, y: 0))
  }

  private func source(actor: UUID) -> (WorkspaceIndex, BoardHierarchy) {
    let stamp = VersionStamp(counter: 0, actor: actor)
    let item = WorkspaceItem.notebook(title: "Scene publication", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID, boards: [.init(id: workspace.rootBoardID,
      board: .init(freeItems: [.init(itemID: item.id, center: .zero, zIndex: 0, stamp: stamp)], elements: [], stamp: stamp))], stamp: stamp)
    return (workspace, hierarchy)
  }
}
