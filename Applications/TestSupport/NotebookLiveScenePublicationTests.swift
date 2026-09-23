import NotebookCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import XCTest
@testable import Notebook

@MainActor
final class NotebookLiveScenePublicationTests: XCTestCase {
  func testBooleanResultDoesNotRevertWhileItsInsertionCohortIsRetained() async throws {
    let fixture = try await fixture(), model = fixture.model
    let board = fixture.presence.boardID
    let address = NotebookToolAddress(surface:.board(board),boardID:board,worldOrigin:.zero,bounds:nil)
    model.selectDrawingTool(.shape)
    model.drawingToolSettings.shape = .rectangle
    model.drawingToolSettings.shapeOperation = .normal
    XCTAssertTrue(model.drawingTools.begin(at:.init(x:300,y:100),address:address,screenScale:1))
    model.drawingTools.move(to:.init(x:600,y:400)); model.drawingTools.finish()
    let id = try XCTUnwrap(model.workingGraphics.last?.id)
    model.drawingToolSettings.shapeOperation = .subtract
    XCTAssertTrue(model.drawingTools.begin(at:.init(x:400,y:200),address:address,screenScale:1))
    model.drawingTools.move(to:.init(x:500,y:300)); model.drawingTools.finish()
    let expected = try XCTUnwrap(model.graphicElement(address.reference(id)))
    XCTAssertEqual(expected.shape,.path)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    XCTAssertTrue(model.compositionTiles.published === fixture.cohort)
    XCTAssertNotNil(model.workingGraphics.first { $0.id == id },"Original insertion is still retained for the old raster")
    XCTAssertNil(model.elementCommandDrafts[address.reference(id)],"The logical model has admitted the edits")
    XCTAssertEqual(model.presentedGraphicGraph(boardID:board,cohort:fixture.cohort).nodes[id]?.graphic,expected,
      "The retained live host must paint the accepted hole, not resurrect the original rectangle")
    let interaction=model.interactionGraphicGraph(boardID:board,cohort:fixture.cohort)
    XCTAssertEqual(interaction.node(id)?.graphic,expected,
      "The next eraser, lasso and point selection must use the same hole, not the insertion preview")
    XCTAssertEqual(interaction.node(id)?.placement,
      model.presentedGraphicGraph(boardID:board,cohort:fixture.cohort).node(id)?.placement)
  }

  func testUnadmittedGraphicCannotCommitAnInvisibleMoveOrResize() async throws {
    let fixture = try await fixture(), model = fixture.model
    let target = CollaborationTarget(kind: .board, id: fixture.presence.boardID)
    _ = try model.store.applyCollaborationAction(.init(summary: "New native object", expected: [
      .init(target: target, revision: model.store.targetContentRevision(target: target))
    ], operations: [.init(kind: .insertElement, target: target, id: "new-graphic", values: [
      "kind": .string("graphic"), "source": .string(""), "graphic": try .encode(NotebookGraphic()),
      "frame": try .encode(PageRect(x: 100, y: 100, width: 80, height: 80)), "worldOrigin": try .encode(WorldPoint.zero)
    ])]), actor: UUID())
    await model.reloadExternalChanges()?.value
    let reference = EditableElementReference.spatial(boardID: target.id, elementID: "new-graphic")
    XCTAssertNotNil(model.graphicElement(reference))
    XCTAssertNil(model.presentedElement(reference, cohort: fixture.cohort))
    let before = try model.store.targetContentRevision(target: target)
    model.selectElement(reference)
    XCTAssertNil(model.beginElementManipulation(reference, kind: .move))
    XCTAssertNil(model.beginElementManipulation(reference, kind: .resize(.bottomTrailing)))
    model.moveElementAccessibly(reference, by: .init(x: 80, y: 40))
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertNil(model.selectionSession.manipulation)
    XCTAssertEqual(try model.store.targetContentRevision(target: target), before)
    XCTAssertTrue(model.compositionTiles.published === fixture.cohort)
  }

  func testAcceptedProgramStateInvalidatesAReadBeforeItsWriterCompletes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("input-frontier-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var after = before
    let rendered = SpatialElement(id: "text-control", surface: .board(workspace.rootBoardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 200, height: 120), worldOrigin: .zero,
      source: "Input frontier", html: "<input>", stamp: .init(counter: 0, actor: actor))
    XCTAssertTrue(after.upsertElement(rendered, in: workspace.rootBoardID, expected: nil, actor: actor))
    _ = try store.saveBoardEdits(before: before, after: after)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let presence = try XCTUnwrap(model.presence)
    let savedBefore = await model.finishPendingPersistence(); XCTAssertTrue(savedBefore)
    let epoch = model.collaborationReadEpoch
    let read = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport)
    let preparedIndex = WorkspaceSceneIndex(workspace: read.workspace, hierarchy: read.hierarchy, paperSizes: read.paperSizes)
    await model.refreshCollaborationDetails()
    XCTAssertTrue(model.collaborationDetailsAreCurrent)
    let historyKey = model.collaborationPreparationKey
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    XCTAssertTrue(model.commitSpatialElementState(boardID: presence.boardID, rendered: rendered, state: .string("first")))
    XCTAssertFalse(model.acceptExternalScene(read, observedEpoch: epoch, observedPresence: presence, itemPins: [:],
      preparedIndex: preparedIndex), "Prepared geometry cannot bypass the accepted-contact frontier")
    XCTAssertFalse(model.collaborationDetailsAreCurrent, "Accepted input cannot leave old history results current while its write waits")
    XCTAssertNotEqual(model.collaborationPreparationKey, historyKey)
    let firstEpoch = model.collaborationReadEpoch
    XCTAssertTrue(model.commitSpatialElementState(boardID: presence.boardID, rendered: rendered, state: .string("complete input")))
    XCTAssertGreaterThan(model.collaborationReadEpoch, firstEpoch)
    XCTAssertFalse(model.acceptExternalScene(read, observedEpoch: firstEpoch, observedPresence: presence, itemPins: [:]))
    let preparing = Task { await model.refreshCollaborationDetails() }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(model.collaborationDetailsAreCurrent,
      "A history retry cannot certify the old SQL content while accepted input is still queued")
    preparing.cancel()
    await preparing.value
    XCTAssertFalse(model.collaborationDetailsAreCurrent)
    try lock.release()
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.readSpatialElement(boardID: presence.boardID, elementID: rendered.id)?.state,
      .string("complete input"))
    await model.reloadExternalChanges()?.value
    XCTAssertFalse(model.scenePreparationPending, "The accepted read already carries its derived geometry")
    XCTAssertEqual(model.sceneIndex?.element(id: rendered.id, boardID: presence.boardID)?.state, .string("complete input"))
    await model.refreshCollaborationDetails()
    XCTAssertTrue(model.collaborationDetailsAreCurrent)
  }

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
    let beforeResize=try XCTUnwrap(model.presentedElement(reference,cohort:cohort))
    XCTAssertEqual(beforeResize.frame.width,old.frame.width,"Moving text does not change its layout width")
    XCTAssertEqual(beforeResize.frame.height,old.frame.height)
    let resize = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.trailingCenter)))
    XCTAssertTrue(model.finishElementManipulation(resize, translation: .init(x: 50, y: 35)))
    let accepted = try XCTUnwrap(model.presentedElement(reference, cohort: cohort))
    let fitted=NotebookTextTypography.fittingFrame(old.source,style:old.textStyle,
      in:.init(x:0,y:0,width:old.frame.width+50,height:old.frame.height))
    XCTAssertEqual(accepted.frame, .init(x: old.frame.x + 70, y: old.frame.y + 10,
      width: old.frame.width + 50, height:fitted.height))
    XCTAssertEqual(accepted.textStyle,old.textStyle,"A text width grip reflows instead of scaling the font")
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
    let address = NotebookToolAddress(surface: .cover(item), boardID: board, worldOrigin: nil,
      bounds: .init(x: 0, y: 0, width: WorkspaceItemGeometry.notebook.width, height: WorkspaceItemGeometry.notebook.height))
    model.clearSelection()
    let id = try XCTUnwrap(model.beginToolText(at: .init(x: 300, y: 300), address: address, screenScale: 1))
    model.commitNativeText(reference: address.reference(id), text: "Новый текст", finish: true)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.board?.elements.first { $0.id == id }?.source, "Новый текст")
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
    XCTAssertNotNil(model.moveItem(item, to: .init(x: -1_000, y: 120), onto: peer))
    let stack = try XCTUnwrap(model.board?.stack(containing: item))
    let expected = try XCTUnwrap(WorkspaceItemStackPresentation.focusedCenter(of:item,in:stack))
    let body = try XCTUnwrap(model.presentedItem(id: item, cohort: cohort, presence: presence))
    XCTAssertEqual(body.center, expected, "Accepted live position follows the current owner, not a retained capture layout")
    XCTAssertNil(model.presentedItem(id: peer, cohort: cohort, presence: presence), "A new peer still requires real composition admission")
    let frozen = try XCTUnwrap(model.presentedHierarchy(cohort: cohort).board(presence.boardID))
    XCTAssertEqual(frozen.placements.first { $0.id == item }?.pose?.stackID, stack.id,
      "A single retained member preserves latent membership; capture cannot invent a free intent")
    XCTAssertNotEqual(frozen.placement(of:item)?.center,body.center)
    let installed=fixture.installed
    XCTAssertNil(NotebookAttentionProjection.capture(start: .init(x: 350, y: 560), end: .init(x: 620, y: 750),
      model: model, presence: presence, cohort: cohort, installedInk: installed),
      "Only the whole-area proof waits when the source layout cannot describe the actual mixed pixels")
    let box = body.geometry.screenFrame(center: body.center, camera: presence.camera, viewport: presence.viewport)
    let cover = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: box.x + 5, y: box.y + 5),
      end: .init(x: box.x + 60, y: box.y + 60), model: model, presence: presence, cohort: cohort,
      installedInk: installed, itemID: item))
    XCTAssertEqual(cover.fragments.first?.target, .init(kind: .cover, id: item, boardID: presence.boardID))
    let sealed = try await seal(cover,model:model)
    XCTAssertFalse(sealed.references.isEmpty, "Cover-local material does not wait for a neighboring fan")
    XCTAssertTrue(model.compositionTiles.published === cohort)
    XCTAssertEqual(model.presence?.camera, presence.camera)
  }

  func testLateSQLSceneCannotReplaceTwoAcceptedMovesBeforeTheyAreSaved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("late-scene-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let board = try XCTUnwrap(model.presence?.boardID)
    model.updatePresence(.init(boardID: board, mode: .board, camera: .init(),
      viewport: .init(x: 1194, y: 834)), settled: true)
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
    let installed=fixture.installed
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
        let sealed = try await seal(selection,model:model)
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
    let sealed = try await seal(selection,model:model)
    XCTAssertEqual(sealed.references.first?.revision,
      try model.store.referenceRevision(target: .init(kind: .board, id: presence.boardID)))
    XCTAssertTrue(model.compositionTiles.published === cohort)
  }

  func testAcceptedTextContentAndQueuedMovesPublishTheExactHumanContext() async throws {
    let fixture=try await fixture(),model=fixture.model,ref=fixture.boardReference
    let lock=try NotebookSQLWriteBlocker(store:model.store)
    defer { try? lock.release() }
    model.commitNativeText(reference:ref,text:"Принятое содержание",finish:true)
    XCTAssertEqual(model.presentedElement(ref,cohort:fixture.cohort)?.source,"Принятое содержание")
    XCTAssertEqual(model.presentedElement(ref,cohort:fixture.cohort)?.html,"Принятое содержание")
    model.selectElement(ref)
    for delta in [SpatialPoint(x:25,y:10),.init(x:30,y:20)] {
      let contact=try XCTUnwrap(model.beginElementManipulation(ref,kind:.move))
      XCTAssertTrue(model.finishElementManipulation(contact,translation:delta))
    }
    let selection=try captureBoard(fixture)
    XCTAssertTrue(selection.hasAcceptedCommands)
    model.publishHumanContext(selection)
    XCTAssertTrue(model.selectionSession.isResolvingContext)
    try lock.release()
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    XCTAssertNil(model.agentRequestError)
    let question=try XCTUnwrap(model.agentQuestion)
    let reference=try XCTUnwrap(question.references.first)
    XCTAssertEqual(reference.revision,try model.store.referenceRevision(target:reference.target,elementID:reference.elementID))
    XCTAssertEqual(try model.store.readSpatialElement(boardID:fixture.presence.boardID,elementID:ref.elementID)?.source,"Принятое содержание")
    XCTAssertTrue(model.compositionTiles.published === fixture.cohort)
    try await Task.sleep(for:.milliseconds(50))
    let image=try XCTUnwrap(fixture.snapshot())
    let proof=XCTAttachment(data:image,uniformTypeIdentifier:"public.png")
    proof.name="accepted-native-text-on-retained-scene";proof.lifetime = .keepAlways;add(proof)
  }

  func testFrozenAcceptedCaptureCannotSilentlyAdvanceToALaterTextEdit() async throws {
    let fixture=try await fixture(),model=fixture.model,ref=fixture.boardReference
    model.selectElement(ref)
    let first=try XCTUnwrap(model.beginElementManipulation(ref,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(first,translation:.init(x:30,y:20)))
    let selection=try captureBoard(fixture)
    let second=try XCTUnwrap(model.beginElementManipulation(ref,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(second,translation:.init(x:50,y:40)))
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    do {
      _ = try await seal(selection,model:model)
      XCTFail("A frozen capture must not borrow a later command's stamp or geometry")
    } catch let error as CollaborationError { XCTAssertEqual(error.code,"capture_source_changed") }
    XCTAssertNil(model.persistenceFailure)
  }

  func testReadyCaptureRegistersItsFenceBeforeTheNextAcceptedContact() async throws {
    let fixture=try await fixture(),model=fixture.model
    let selection=try captureBoard(fixture)
    XCTAssertFalse(selection.hasAcceptedCommands)
    let expected=try model.store.referenceRevision(target:.init(kind:.board,id:fixture.presence.boardID))
    model.publishHumanContext(selection)
    let item=try XCTUnwrap(model.workspace?.selectedItemID)
    model.moveItem(item,to:.init(x:-1_200,y:100))
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    XCTAssertNil(model.agentRequestError)
    let reference=try XCTUnwrap(model.agentQuestion?.references.first)
    XCTAssertEqual(reference.revision,expected)
    XCTAssertNotEqual(reference.revision,try model.store.referenceRevision(target:reference.target))
  }

  func testDismissedPendingTextCaptureSavesHistoryWithoutReopeningSelection() async throws {
    let fixture=try await fixture(),model=fixture.model,ref=fixture.boardReference
    let lock=try NotebookSQLWriteBlocker(store:model.store)
    defer { try? lock.release() }
    model.selectElement(ref)
    let contact=try XCTUnwrap(model.beginElementManipulation(ref,kind:.move))
    XCTAssertTrue(model.finishElementManipulation(contact,translation:.init(x:20,y:10)))
    let selection=try captureBoard(fixture)
    model.publishHumanContext(selection)
    model.dismissAgentQuestion()
    try lock.release()
    let saved=await model.finishPendingPersistence();XCTAssertTrue(saved)
    await model.reloadExternalChanges()?.value
    XCTAssertNil(model.agentQuestion)
    XCTAssertNil(model.agentRequestError)
    let contexts=try model.store.sharedContexts()
    XCTAssertEqual(contexts.contexts.filter { $0.entries.first?.references.first?.id == selection.fragments.first?.id }.count,1)
    XCTAssertNil(contexts.selection?.contextID)
  }

  private func captureBoard(_ fixture:Fixture) throws -> NotebookAttentionSelection {
    try XCTUnwrap(NotebookAttentionProjection.capture(start:.init(x:350,y:560),end:.init(x:620,y:750),
      model:fixture.model,presence:fixture.presence,cohort:fixture.cohort,installedInk:fixture.installed))
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
    XCTAssertEqual(captured.fragments.first?.region,NotebookTextTypography.frame(element))
  }

  private func seal(_ selection:NotebookAttentionSelection,model:NotebookAppModel) async throws -> NotebookAttentionSelection.Sealed {
    let ready=try await selection.resolvingAcceptedCommands()
    return try await model.performStoreCommand { try ready.seal(in:$0) }
  }

  private struct Fixture {
    let model: NotebookAppModel
    let cohort: SceneCompositionCohort
    let presence: SessionPresence
    let boardReference: EditableElementReference
    let coverReference: EditableElementReference
    let installed: [SurfaceID:SpatialInkInstalledSource]
    let snapshot: @MainActor () -> Data?
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
    // Retain this actual native publication while exercising newer accepted
    // geometry. A prepared cohort alone is deliberately not a paint receipt.
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: presence.viewport.x, height: presence.viewport.y)
    window.rootViewController = UIHostingController(rootView:
      RetainedLiveScene(cohort: cohort, presence: presence).environment(model).ignoresSafeArea())
    window.makeKeyAndVisible()
    addTeardownBlock { @MainActor in
      window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
    func snapshot() -> Data? {
      window.layoutIfNeeded()
      return UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
        window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)
      }.pngData()
    }
    func installedSources() -> [SurfaceID:SpatialInkInstalledSource] {
      Dictionary(uniqueKeysWithValues:cohort.nativeInk.owners.compactMap { surface,owner in
        owner.canvas.installedSpatialSource.map { (surface,$0) }
      })
    }
    #else
    let window=NSWindow(contentRect:.init(x:0,y:0,width:presence.viewport.x,height:presence.viewport.y),
      styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    window.contentView=NSHostingView(rootView:RetainedLiveScene(cohort:cohort,presence:presence).environment(model))
    window.orderFront(nil)
    addTeardownBlock { @MainActor in window.orderOut(nil);window.contentView=nil;window.close() }
    func snapshot() -> Data? {
      guard let view=window.contentView else { return nil }
      view.layoutSubtreeIfNeeded();view.displayIfNeeded()
      guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return nil }
      view.cacheDisplay(in:view.bounds,to:bitmap)
      return bitmap.representation(using:.png,properties:[:])
    }
    func installedSources() -> [SurfaceID:SpatialInkInstalledSource] {
      var result:[SurfaceID:SpatialInkInstalledSource]=[:]
      func visit(_ view:NSView) {
        if let source=(view as? InkCanvasView)?.installedSpatialSource { result[source.surface]=source }
        for child in view.subviews { visit(child) }
      }
      if let view=window.contentView { visit(view) };return result
    }
    #endif
    let paintDeadline = ContinuousClock.now + .seconds(5)
    while (!cohort.isPaintInstalled || installedSources().count<2), .now < paintDeadline {
      #if os(iOS)
      window.layoutIfNeeded()
      #else
      window.contentView?.layoutSubtreeIfNeeded()
      #endif
      try await Task.sleep(for:.milliseconds(10))
    }
    XCTAssertTrue(cohort.isPaintInstalled)
    return .init(model: model, cohort: cohort, presence: presence,
      boardReference: .spatial(boardID: workspace.rootBoardID, elementID: boardElement.id),
      coverReference: .spatial(boardID: workspace.rootBoardID, elementID: coverElement.id),installed:installedSources(),snapshot:snapshot)
  }
}

/// The normal content/native-plane owners with one deliberately retained cohort;
/// no automatic preparation task can replace the old generation under this case.
private struct RetainedLiveScene: View {
  @Environment(NotebookAppModel.self) private var model
  let cohort: SceneCompositionCohort
  let presence: SessionPresence
  private let ink = SpatialInkSurfaceRegistry()

  var body: some View {
    ZStack {
      plane(.elements)
      #if os(iOS)
      SpatialInkSurfaceView(surface:.board(presence.boardID),cohort:cohort,boardID:presence.boardID,isActive:false)
        .allowsHitTesting(false)
      #else
      SpatialInkSurfaceView(surface:.board(presence.boardID),journal:cohort.liveData.ink,camera:presence.camera,viewport:presence.viewport)
        .allowsHitTesting(false)
      #endif
      plane(.covers)
    }
      .environment(\.sceneComposition, .init(cohort))
      .environment(\.workspaceSceneFrame, cohort.frame)
  }

  private func plane(_ layer: ScenePaintPosition.Layer) -> some View {
    let workset = model.presentedWorkset(cohort: cohort, boardID: presence.boardID, presence: presence)
    let graph=model.presentedGraphicGraph(boardID:presence.boardID,cohort:cohort)
    return SceneCameraPlane(presence: presence, revision: model.scenePublicationGeneration,
      installation: cohort.installation(for: layer)) { anchor in
      ZStack {
        ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(presence.boardID), layer: layer, presence: anchor)) { band in
          band.zIndex(Double(band.rank))
        }
        if layer == .elements {
          ForEach(workset.elements) { element in
            if let placement=graph.placement(element.id) {
              let presentation=NotebookElementPresentation(element,placement:placement),frame=presentation.frame
              let point = anchor.camera.worldToScreen(placement.origin, viewport: anchor.viewport)
              NotebookPlacedElement(presentation:presentation) {
                SpatialElementContent(element: element, commitsState: false, boardID: presence.boardID)
              }.frame(width:frame.width,height:frame.height)
                .scaleEffect(anchor.camera.scale)
                .position(x: point.x + (frame.x + frame.width / 2) * anchor.camera.scale,
                  y: point.y + (frame.y + frame.height / 2) * anchor.camera.scale)
            }
          }
        } else {
          ForEach(workset.items) { item in
            let point = anchor.camera.worldToScreen(item.center, viewport: anchor.viewport)
            WorkspaceItemCoverView(item: item.item, boardID: presence.boardID, geometry: item.geometry,
              spatialInkSurfaces: ink,
              elements: model.presentedCoverElements(cohort: cohort, boardID: presence.boardID, itemID: item.id),
              editingTextID: nil, portalOpenProgress: 0, portalViewport: anchor.viewport,
              onTap: { _, _ in }, onTextEditingEnded: { _ in })
              .frame(width: item.geometry.width, height: item.geometry.height)
              .scaleEffect(anchor.camera.scale).position(x: point.x, y: point.y)
          }
        }
      }
    }
  }
}
