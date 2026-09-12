import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookLiveScenePublicationTests: XCTestCase {
  func testTwoMovesResizeAndDeleteUseAcceptedGeometryWhileTheCohortStaysOld() async throws {
    let fixture = try await fixture()
    let (model, cohort, presence, reference) = (fixture.model, fixture.cohort, fixture.presence, fixture.boardReference)
    let old = try XCTUnwrap(model.presentedElement(reference, cohort: cohort))
    model.selectElement(reference)
    for delta in [SpatialPoint(x: 40, y: 20), .init(x: 30, y: -10)] {
      let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
      XCTAssertTrue(model.finishElementManipulation(contact, translation: delta))
      XCTAssertNil(model.selectionSession.manipulation)
      XCTAssertTrue(model.compositionTiles.published === cohort)
      try assertPresentedElement(reference, model: model, cohort: cohort, presence: presence)
    }
    let resize = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.bottomTrailing)))
    XCTAssertTrue(model.finishElementManipulation(resize, translation: .init(x: 50, y: 35)))
    let accepted = try XCTUnwrap(model.presentedElement(reference, cohort: cohort))
    XCTAssertEqual(accepted.frame, .init(x: old.frame.x + 70, y: old.frame.y + 10,
      width: old.frame.width + 50, height: old.frame.height + 35))
    try assertPresentedElement(reference, model: model, cohort: cohort, presence: presence)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertEqual(try model.store.readSpatialElement(boardID: presence.boardID, elementID: accepted.id)?.frame, accepted.frame)
    XCTAssertNotEqual(cohort.frame.index.element(id: accepted.id, boardID: presence.boardID)?.frame, accepted.frame)
    model.deleteElement(reference)
    XCTAssertNil(model.presentedElement(reference, cohort: cohort))
    XCTAssertNil(NotebookAttentionProjection.editingFrame(reference, model: model, presence: presence))
    XCTAssertFalse(model.presentedWorkset(cohort: cohort, boardID: presence.boardID, presence: presence).elements.contains { $0.id == accepted.id })
    let drained = await model.finishPendingPersistence(); XCTAssertTrue(drained)
    await model.reloadExternalChanges()?.value
    XCTAssertNil(model.presentedElement(reference, cohort: cohort), "A bounded read cannot resurrect the deleted live host from its old cohort")
    XCTAssertNil(try model.store.readSpatialElement(boardID: presence.boardID, elementID: accepted.id))
    XCTAssertEqual(model.presence, presence)
  }

  func testCoverElementAndItsPaperShareTheAcceptedPlacementBeforeAnyNewCohort() async throws {
    let fixture = try await fixture()
    let (model, cohort) = (fixture.model, fixture.cohort)
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    let original = try XCTUnwrap(model.presentedItem(id: item, cohort: cohort, presence: fixture.presence))
    let presence = SessionPresence(boardID: fixture.presence.boardID, mode: .cover,
      camera: fixture.presence.camera, viewport: fixture.presence.viewport, focusedItemID: item,
      selectedItemID: item, notebookPageID: model.activePage?.id)
    model.updatePresence(presence, settled: true)
    let reference = fixture.coverReference
    let old = try XCTUnwrap(model.presentedElement(reference, cohort: cohort))
    model.selectElement(reference)
    let contact = try XCTUnwrap(model.beginElementManipulation(reference, kind: .move))
    XCTAssertTrue(model.finishElementManipulation(contact, translation: .init(x: 30, y: 40)))
    let moved = original.center.offsetBy(x: 120, y: -80)
    model.moveItem(item, to: moved)
    XCTAssertEqual(model.presentedItem(id: item, cohort: cohort, presence: presence)?.center, moved)
    XCTAssertEqual(model.presentedCoverElements(cohort: cohort, boardID: presence.boardID, itemID: item).first?.frame,
      .init(x: old.frame.x + 30, y: old.frame.y + 40, width: old.frame.width, height: old.frame.height))
    let element = try XCTUnwrap(model.presentedElement(reference, cohort: cohort))
    let box = original.geometry.screenFrame(center: moved, camera: presence.camera, viewport: presence.viewport)
    let outline = try XCTUnwrap(NotebookAttentionProjection.editingFrame(reference, model: model, presence: presence))
    XCTAssertEqual(outline.minX, box.x + element.frame.x * presence.camera.scale, accuracy: 0.000_001)
    XCTAssertEqual(outline.minY, box.y + element.frame.y * presence.camera.scale, accuracy: 0.000_001)
    XCTAssertTrue(model.compositionTiles.published === cohort)
    let drained = await model.finishPendingPersistence(); XCTAssertTrue(drained)
    XCTAssertEqual(try model.store.readBoardItem(item)?.board.placement(of: item)?.center, moved)
  }

  func testNewModelElementCannotBorrowAnotherCohortsAdmission() async throws {
    let fixture = try await fixture()
    let model = fixture.model, board = fixture.presence.boardID
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    let id = try XCTUnwrap(model.addNativeText(boardID: board, on: item, at: .init(x: 300, y: 300)))
    let reference = EditableElementReference.spatial(boardID: board, elementID: id)
    model.selectElement(reference)
    XCTAssertNil(model.presentedElement(reference, cohort: fixture.cohort))
    XCTAssertNil(NotebookAttentionProjection.editingFrame(reference, model: model, presence: fixture.presence))
    XCTAssertFalse(model.presentedWorkset(cohort: fixture.cohort, boardID: board, presence: fixture.presence).elements.contains { $0.id == id })
  }

  func testCurrentStackFanNeverWaitsForUnadmittedPeersOrWholeAreaProof() async throws {
    let fixture = try await fixture(), model = fixture.model, cohort = fixture.cohort
    let presence = fixture.presence, item = try XCTUnwrap(model.workspace?.selectedItemID)
    let peer = try XCTUnwrap(model.createNotebook(at: .init(x: -1_000, y: 120)))
    XCTAssertNotNil(model.stackItem(item, onto: peer))
    let stack = try XCTUnwrap(model.board?.stack(containing: item))
    let expected = try XCTUnwrap(WorkspaceItemStackPresentation.boardCenter(of: item, in: stack,
      cameraScale: presence.camera.scale, viewport: presence.viewport))
    let body = try XCTUnwrap(model.presentedItem(id: item, cohort: cohort, presence: presence))
    XCTAssertEqual(body.center, expected, "Accepted live position follows the current owner, not a retained capture layout")
    XCTAssertNil(model.presentedItem(id: peer, cohort: cohort, presence: presence), "A new peer still requires real composition admission")
    let frozen = try XCTUnwrap(model.presentedHierarchy(cohort: cohort).board(presence.boardID))
    XCTAssertEqual(frozen.placements.first { $0.id == item }?.pose?.stackID, stack.id,
      "A single retained member preserves latent membership; capture cannot invent a free intent")
    XCTAssertNotEqual(frozen.placement(of: item)?.center, body.center)
    let installed = Dictionary(uniqueKeysWithValues: cohort.nativeInk.owners.compactMap { surface, owner in
      owner.canvas.installedSpatialSource.map { (surface, $0) }
    })
    XCTAssertNil(NotebookAttentionProjection.capture(start: .init(x: 350, y: 560), end: .init(x: 620, y: 750),
      model: model, presence: presence, cohort: cohort, installedInk: installed),
      "Only the whole-area proof waits when the source layout cannot describe the actual mixed pixels")
    let box = body.geometry.screenFrame(center: body.center, camera: presence.camera, viewport: presence.viewport)
    let cover = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: box.x + 5, y: box.y + 5),
      end: .init(x: box.x + 60, y: box.y + 60), model: model, presence: presence, cohort: cohort,
      installedInk: installed, itemID: item))
    XCTAssertEqual(cover.fragments.first?.target, .init(kind: .cover, id: item, boardID: presence.boardID))
    let sealed = try await model.performStoreCommand { try cover.seal(in: $0) }
    XCTAssertFalse(sealed.references.isEmpty, "Cover-local material does not wait for a neighboring fan")
    XCTAssertTrue(model.compositionTiles.published === cohort)
    XCTAssertEqual(model.presence?.camera, presence.camera)
  }

  func testLateSQLSceneCannotReplaceTwoAcceptedMovesBeforeTheyAreSaved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("late-scene-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let initiallySaved = await model.finishPendingPersistence(); XCTAssertTrue(initiallySaved)
    let presence = try XCTUnwrap(model.presence), item = try XCTUnwrap(model.workspace?.selectedItemID)
    let observed = model.collaborationReadEpoch
    let pendingRead = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let first = WorldPoint(x: 130, y: 80), second = WorldPoint(x: 280, y: 120)
    model.moveItem(item, to: first)
    XCTAssertFalse(model.acceptExternalScene(pendingRead, observedEpoch: observed, observedPresence: presence, itemPins: [:]))
    XCTAssertEqual(model.board?.placement(of: item)?.center, first)
    model.moveItem(item, to: second)
    XCTAssertFalse(model.acceptExternalScene(pendingRead, observedEpoch: observed, observedPresence: presence, itemPins: [:]))
    XCTAssertEqual(model.board?.placement(of: item)?.center, second)
    XCTAssertEqual(model.presence, presence)
    try lock.release()
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.readBoardItem(item)?.board.placement(of: item)?.center, second)
    let currentEpoch = model.collaborationReadEpoch
    let current = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport)
    XCTAssertTrue(model.acceptExternalScene(current, observedEpoch: currentEpoch, observedPresence: presence, itemPins: [:]),
      "A current read must still publish; the negative case is the superseded frontier, not a permanently closed gate")
    XCTAssertEqual(model.board?.placement(of: item)?.center, second)
  }

  func testWholeBoardAndCoverCapturesSealImmediatelyAfterAcceptedGeometryWhileCohortStaysOld() async throws {
    let fixture = try await fixture(), model = fixture.model, cohort = fixture.cohort
    let presence = fixture.presence, item = try XCTUnwrap(model.workspace?.selectedItemID)
    let installed = Dictionary(uniqueKeysWithValues: cohort.nativeInk.owners.compactMap { surface, owner in
      owner.canvas.installedSpatialSource.map { (surface, $0) }
    })
    XCTAssertNotNil(installed[.board(presence.boardID)])
    XCTAssertNotNil(installed[.cover(item)])
    for (offset, delta) in [SpatialPoint(x: 40, y: 30), .init(x: 50, y: -10)].enumerated() {
      model.selectElement(fixture.boardReference)
      let move = try XCTUnwrap(model.beginElementManipulation(fixture.boardReference, kind: .move))
      XCTAssertTrue(model.finishElementManipulation(move, translation: delta))
      model.selectElement(fixture.coverReference)
      let resize = try XCTUnwrap(model.beginElementManipulation(fixture.coverReference, kind: .resize(.bottomTrailing)))
      XCTAssertTrue(model.finishElementManipulation(resize, translation: .init(x: 20, y: 15)))
      model.moveItem(item, to: .init(x: -1_200 + Double(offset * 120), y: 100))
      let boardSelection = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 350, y: 560),
        end: .init(x: 620, y: 750), model: model, presence: presence, cohort: cohort, installedInk: installed))
      XCTAssertEqual(boardSelection.fragments.first?.target, .init(kind: .board, id: presence.boardID))
      XCTAssertNil(boardSelection.fragments.first?.elementID)
      let cover = try XCTUnwrap(model.presentedItem(id: item, cohort: cohort, presence: presence))
      let box = cover.geometry.screenFrame(center: cover.center, camera: presence.camera, viewport: presence.viewport)
      let coverSelection = try XCTUnwrap(NotebookAttentionProjection.capture(
        start: .init(x: box.x + 5, y: box.y + 5), end: .init(x: box.x + 60, y: box.y + 60),
        model: model, presence: presence, cohort: cohort, installedInk: installed, itemID: item))
      XCTAssertEqual(coverSelection.fragments.first?.target, .init(kind: .cover, id: item, boardID: presence.boardID))
      for selection in [boardSelection, coverSelection] {
        let sealed = try await model.performStoreCommand { try selection.seal(in: $0) }
        XCTAssertFalse(sealed.references.isEmpty)
        for reference in sealed.references {
          XCTAssertEqual(reference.revision, try model.store.referenceRevision(target: reference.target, elementID: reference.elementID))
        }
      }
      XCTAssertTrue(model.compositionTiles.published === cohort)
      XCTAssertEqual(model.presence, presence)
    }
    model.deleteElement(fixture.boardReference)
    let selection = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 350, y: 560),
      end: .init(x: 620, y: 750), model: model, presence: presence, cohort: cohort, installedInk: installed))
    let sealed = try await model.performStoreCommand { try selection.seal(in: $0) }
    XCTAssertEqual(sealed.references.first?.revision,
      try model.store.referenceRevision(target: .init(kind: .board, id: presence.boardID)))
    XCTAssertTrue(model.compositionTiles.published === cohort)
  }

  private func assertPresentedElement(_ reference: EditableElementReference, model: NotebookAppModel,
    cohort: SceneCompositionCohort, presence: SessionPresence) throws {
    let element = try XCTUnwrap(model.presentedElement(reference, cohort: cohort))
    XCTAssertEqual(model.presentedWorkset(cohort: cohort, boardID: presence.boardID, presence: presence).elements.first { $0.id == element.id }, element)
    let origin = try XCTUnwrap(element.worldOrigin)
    let top = presence.camera.worldToScreen(origin.offsetBy(x: element.frame.x, y: element.frame.y), viewport: presence.viewport)
    let outline = try XCTUnwrap(NotebookAttentionProjection.editingFrame(reference, model: model, presence: presence))
    XCTAssertEqual(outline.minX, top.x, accuracy: 0.000_001)
    XCTAssertEqual(outline.minY, top.y, accuracy: 0.000_001)
    let point = CGPoint(x: outline.midX, y: outline.midY)
    let captured = try XCTUnwrap(NotebookAttentionProjection.capture(start: point, end: point, model: model,
      presence: presence, cohort: cohort, installedInk: [:]))
    XCTAssertEqual(captured.fragments.first?.elementID, element.id)
    XCTAssertEqual(captured.fragments.first?.region,
      .init(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height))
  }

  private struct Fixture {
    let model: NotebookAppModel
    let cohort: SceneCompositionCohort
    let presence: SessionPresence
    let boardReference: EditableElementReference
    let coverReference: EditableElementReference
  }

  private func fixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-scene-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var after = before
    XCTAssertTrue(after.moveItem(workspace.selectedItemID, in: workspace.rootBoardID, to: .init(x: -1_400, y: 0), actor: actor))
    let boardElement = SpatialElement(id: "live-chart", surface: .board(workspace.rootBoardID), kind: .nativeText,
      frame: .init(x: 20, y: 30, width: 200, height: 160), worldOrigin: .zero,
      source: "A movable chart", stamp: .init(counter: 0, actor: actor))
    let coverElement = SpatialElement(id: "cover-chart", surface: .cover(workspace.selectedItemID), kind: .nativeText,
      frame: .init(x: 100, y: 120, width: 200, height: 100), source: "A cover note", stamp: .init(counter: 0, actor: actor))
    XCTAssertTrue(after.upsertElement(boardElement, in: workspace.rootBoardID, expected: nil, actor: actor))
    XCTAssertTrue(after.upsertElement(coverElement, in: workspace.rootBoardID, expected: nil, actor: actor))
    _ = try store.saveBoardEdits(before: before, after: after)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .board, camera: .init(scale: 0.3),
      viewport: .init(x: 834, y: 1194), selectedItemID: workspace.selectedItemID,
      notebookPageID: workspace.selectedPageID), settled: true)
    let drained = await model.finishPendingPersistence(); XCTAssertTrue(drained)
    let presence = try XCTUnwrap(model.presence)
    let pins: Set<WorkspaceSpatialID> = [.item(workspace.selectedItemID), .element(boardElement.id), .element(coverElement.id)]
    // Like the mounted view's task, a new index/cursor retries preparation:
    // the initial bounded scene has not yet read these explicit cover pins.
    let deadline = ContinuousClock.now + .seconds(5)
    var requested: String?
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil, ContinuousClock.now < deadline {
      if !model.scenePreparationPending, let index = model.sceneIndex {
        let revision = "\(model.scenePublicationGeneration):\(model.workspaceHeader?.cursor ?? 0)"
        if requested != revision {
          requested = revision
          let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: model.scenePortalCamera, pinned: pins)
          model.prepareComposition(presence: presence, frame: frame, pinned: pins, displayScale: 1)
        }
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    let cohort = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "No admitted scene")
    XCTAssertTrue(cohort.plan.allowsLive(.element(boardElement.id), in: .board(workspace.rootBoardID)))
    XCTAssertTrue(cohort.plan.allowsLive(.element(coverElement.id), in: .cover(boardID: workspace.rootBoardID, itemID: workspace.selectedItemID)))
    return .init(model: model, cohort: cohort, presence: presence,
      boardReference: .spatial(boardID: workspace.rootBoardID, elementID: boardElement.id),
      coverReference: .spatial(boardID: workspace.rootBoardID, elementID: coverElement.id))
  }
}
