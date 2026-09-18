import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookSelectionPublicationTests: XCTestCase {
  func testActualOwnerPublishesClearSurfaceAndReselectWithoutCameraFrameChurn() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    await model.finishPendingPersistence()
    model.setSelectionSurfaceActive(true)
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements((0..<40).map { .init(id: "element-\($0)", kind: .markdown,
      frame: .init(x: 20, y: 20, width: 100, height: 100), source: "Source \($0)", html: "<p>\($0)</p>") }, actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let reference = EditableElementReference.page(pageID: page.id, elementID: "element-39")
    model.selectElement(reference)
    let first = try XCTUnwrap(model.lastSelectionEnvelope)
    XCTAssertEqual(first.selection?.id, model.selectionSession.id)
    XCTAssertEqual(first.selection?.target, .init(kind: .page, id: page.id))
    XCTAssertEqual(first.selection?.elementID, "element-39")
    let original = try XCTUnwrap(model.presence)
    let camera = SessionPresence(boardID: original.boardID, mode: original.mode,
      camera: .init(center: original.camera.center, scale: original.camera.scale * 1.1),
      viewport: original.viewport, focusedItemID: original.focusedItemID,
      openProgress: original.openProgress, documentPageIndex: original.documentPageIndex,
      selectedItemID: original.selectedItemID, notebookPageID: original.notebookPageID)
    model.updatePresence(camera, settled: false)
    XCTAssertEqual(model.lastSelectionEnvelope, first, "A camera frame is not a different selection")
    model.selectElement(reference)
    XCTAssertEqual(model.lastSelectionEnvelope, first, "Reselecting the same owner does not synthesize a new choice")
    model.clearSelection()
    let cleared = try XCTUnwrap(model.lastSelectionEnvelope)
    XCTAssertEqual(cleared.selection?.kind, .empty)
    XCTAssertGreaterThan(cleared.sequence, first.sequence)
    XCTAssertNotEqual(cleared.selection?.id, first.selection?.id)
    model.updatePresence(.init(boardID: camera.boardID, mode: .cover, camera: camera.camera,
      viewport: camera.viewport, focusedItemID: model.workspace?.selectedItemID,
      selectedItemID: camera.selectedItemID, notebookPageID: camera.notebookPageID), settled: false)
    let cover = try XCTUnwrap(model.lastSelectionEnvelope)
    XCTAssertEqual(cover.selection?.kind, .empty)
    XCTAssertEqual(cover.selection?.surface.kind, .cover)
    XCTAssertGreaterThan(cover.sequence, cleared.sequence)
    model.selectElement(reference)
    let reselected = try XCTUnwrap(model.lastSelectionEnvelope)
    XCTAssertEqual(reselected.selection?.target, first.selection?.target,
      "Even a different camera surface cannot redirect an exact selected physical owner")
    XCTAssertNotEqual(reselected.selection?.id, first.selection?.id)
    XCTAssertGreaterThan(reselected.sequence, cover.sequence)
  }

  func testUnavailableScenePublishesUnknownWithoutClearingSelectionCameraOrPencil() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.setSelectionSurfaceActive(true)
    let initial = try XCTUnwrap(model.presence), item = try XCTUnwrap(model.workspace?.selectedItemID)
    model.updatePresence(.init(boardID: initial.boardID, mode: .board, camera: initial.camera, viewport: initial.viewport), settled: false)
    let presence = try XCTUnwrap(model.presence)
    model.selectWorkspaceItem(item, boardID: presence.boardID)
    let first = try XCTUnwrap(model.lastSelectionEnvelope)
    XCTAssertEqual(first.selection?.kind, .item)
    let pencil = UUID()
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    let accepted = model.selectionSession
    model.setSelectionSurfaceActive(false)
    let unknown = try XCTUnwrap(model.lastSelectionEnvelope)
    XCTAssertNil(unknown.selection)
    XCTAssertGreaterThan(unknown.sequence, first.sequence)
    XCTAssertEqual(model.selectionSession, accepted)
    XCTAssertEqual(model.presence, presence)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    model.setSelectionSurfaceActive(false)
    XCTAssertEqual(model.lastSelectionEnvelope, unknown)
    model.setSelectionSurfaceActive(true)
    let restored = try XCTUnwrap(model.lastSelectionEnvelope)
    XCTAssertEqual(restored.selection, first.selection)
    XCTAssertGreaterThan(restored.sequence, unknown.sequence)
    model.inputGate.endPencilAction(source: pencil)
  }
}
