import NotebookCore
import XCTest
@testable import Notebook

final class SceneCompositionSQLTests: XCTestCase {
  @MainActor
  func testLivePayloadIsOneSQLRevisionAndExcludedHumanChangesCarryStaticPixels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let actor = UUID(), store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var workspace = try store.loadIndex()
    let notebookID = workspace.selectedItemID
    var hierarchy = try store.loadBoard(items: workspace.items)
    XCTAssertTrue(hierarchy.moveItem(notebookID, in: header.rootBoardID, to: .init(x: 1_000_000, y: 1_000_000), actor: actor))
    let documentID = try XCTUnwrap(workspace.createDocument(title: "Live document", actor: actor)?.id)
    XCTAssertTrue(hierarchy.addItem(documentID, to: header.rootBoardID, near: .zero, actor: actor))
    var document = DocumentDocument(id: documentID, actor: actor, blocks: [.markdown(id: "body", source: "Old body")])
    var state = DocumentStateJournal(id: documentID, actor: actor)
    try store.saveDocumentWorkspaceBundle(index: workspace, document: document, state: state, board: hierarchy)
    document = try store.loadDocument(documentID)
    state = try store.loadDocumentState(documentID)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [documentID: .a4])
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: .init(scale: 0.3),
      viewport: .init(x: 512, y: 512), focusedItemID: documentID, selectedItemID: documentID)
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil }, pinned: [.item(documentID)])
    func source() throws -> SceneCompositionSource {
      let current = try store.workspaceHeader()
      return .init(store: store, revision: current.cursor, workspaceID: current.workspaceID)
    }
    func plan(_ source: SceneCompositionSource) async throws -> SceneCompositionPlan {
      try await .prepare(source: source, presence: presence, frame: frame, pinned: [.item(documentID)], displayScale: 2, previous: nil)
    }
    let before = try source(), oldPlan = try await plan(before)
    let oldData = try await before.liveData(plan: oldPlan, presence: presence, frame: frame)
    XCTAssertEqual(oldData.documents[documentID], document)
    XCTAssertEqual(oldData.states[documentID], state)
    XCTAssertTrue(oldData.pages.isEmpty)
    let resources = SceneRenderResources(byteLimit: 128 * 1024 * 1024)
    let coordinator = SceneCompositionTiles(resources: resources)
    defer { coordinator.removePublishedCoverage() }
    coordinator.prepare(source: before, presence: presence, frame: frame, pinned: [.item(documentID)])
    try await waitForPublication(coordinator, revision: before.revision)
    let oldCohort = try XCTUnwrap(coordinator.published)
    let rasterGeneration = resources.rasterGeneration

    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "New body", actor: actor))
    XCTAssertTrue(state.commit(blockID: "body", value: .number(7), actor: actor))
    try store.saveDocument(document); try store.saveDocumentState(state)
    var journal = try store.readSpatialInk(surfaces: [.board(header.rootBoardID)])
    let sample = SpatialInkSample(point: .zero, worldPoint: .zero, timeOffset: 0,
      width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    _ = journal.append(tool: .pen, spans: [.init(surface: .board(header.rootBoardID), samples: [sample])], actor: actor)
    try store.saveSpatialInk(journal)
    let after = try source(), newPlan = try await plan(after)
    let newData = try await after.liveData(plan: newPlan, presence: presence, frame: frame)
    let carry = try await after.canCarryStaticPixels(from: oldPlan, liveData: oldData, to: newPlan, liveData: newData)
    XCTAssertTrue(carry, "A new Pencil action and live document state do not invalidate excluded background paint")
    XCTAssertEqual(oldData.documents[documentID]?.blocks.first?.source, "Old body", "Shown passive payload is immutable while another revision prepares")
    XCTAssertEqual(newData.documents[documentID]?.blocks.first?.source, "New body")
    XCTAssertEqual(newData.states[documentID]?.value(for: "body"), .number(7))
    XCTAssertEqual(newData.ink.actions.count, 1)
    coordinator.prepare(source: after, presence: presence, frame: frame, pinned: [.item(documentID)])
    try await waitForPublication(coordinator, revision: after.revision)
    let newCohort = try XCTUnwrap(coordinator.published)
    XCTAssertFalse(oldCohort === newCohort, "New live values publish in a new coherent cohort")
    XCTAssertEqual(resources.rasterGeneration, rasterGeneration, "An excluded edit allocates no replacement tile")
    for (key, raster) in newCohort.rasters {
      XCTAssertTrue(oldCohort.rasters[key.atRevision(oldCohort.plan.revision)]?.image === raster.image,
        "The renderer carries the actual retained pixels, not just a cache counter")
    }
    do { try await before.validate(); XCTFail("An old SQL reader cannot publish a new mixed revision") }
    catch NotebookStorageError.transactionConflict { }

    _ = journal.append(tool: .eraser, spans: [
      .init(surface: .board(header.rootBoardID), samples: [sample]),
      .init(surface: .cover(notebookID), samples: [.init(point: .zero, timeOffset: 0,
        width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    ], actor: actor)
    try store.saveSpatialInk(journal)
    let crossSurface = try source(), crossPlan = try await plan(crossSurface)
    let crossData = try await crossSurface.liveData(plan: crossPlan, presence: presence, frame: frame)
    let crossesStatic = try await crossSurface.canCarryStaticPixels(from: newPlan, liveData: newData, to: crossPlan, liveData: crossData)
    XCTAssertFalse(crossesStatic, "A contact spanning a non-excluded physical owner invalidates its static pixels")
  }

  @MainActor
  private func waitForPublication(_ coordinator: SceneCompositionTiles, revision: UInt64) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while coordinator.published?.plan.revision != revision, coordinator.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(coordinator.published?.plan.revision, revision, coordinator.failure ?? "Whole cohort was not published")
  }
}
