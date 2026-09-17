import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookGraphicModelTests: XCTestCase {
  func testPageShapeUsesNativeCommandsAgentEditsAndSequentialUndo() async throws { try await scenario(onBoard: false) }
  func testBoardShapeUsesNativeCommandsAgentEditsAndSequentialUndo() async throws { try await scenario(onBoard: true) }
  func testPageShapeSequentialUndoSurvivesColdModelReopening() async throws { try await scenario(onBoard: false, reopens: true) }
  func testBoardShapeSequentialUndoSurvivesColdModelReopening() async throws { try await scenario(onBoard: true, reopens: true) }

  private func scenario(onBoard: Bool, reopens: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-model-\(UUID())")
    var model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace, "Startup: \(model.loadState)"), pageID = try XCTUnwrap(workspace.selectedPageID)
    let target = CollaborationTarget(kind: onBoard ? .board : .page, id: onBoard ? workspace.rootBoardID : pageID)
    if onBoard { model.updatePresence(.init(boardID: target.id, mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)), settled: true) }
    let initialSave = await model.finishPendingPersistence(); XCTAssertTrue(initialSave)
    let store = model.store, strokeID = UUID()
    var values: [String: JSONValue] = ["points": .array((0...48).map { index in
      let a = Double(index) / 48 * 2 * Double.pi
      return .object(["x": .number(150 + 60 * cos(a)), "y": .number(150 + 60 * sin(a))])
    })]
    if onBoard { values["worldOrigin"] = try .encode(WorldPoint.zero) }
    _ = try store.applyCollaborationAction(.init(summary: "Measured samples",
      expected: [.init(target: target, revision: store.targetContentRevision(target: target), inkRevision: store.inkRevision(on: target))],
      operations: [.init(kind: .appendInkStroke, target: target, id: strokeID.uuidString, values: values)]), actor: model.actorID)
    await model.reloadExternalChanges()?.value
    let fit = NotebookQuickShapeFit(frame: .init(x: 90, y: 90, width: 120, height: 120), sampleCount: 49)
    if onBoard {
      model.acceptQuickShape(fit, boardID: target.id, origin: .zero, stroke: try XCTUnwrap(store.loadSpatialInk().actions.first { $0.id == strokeID }))
    } else {
      let page = try store.loadPage(pageID), ink = try PageInkDrawing.decode(page.drawingData)
      model.acceptQuickShape(fit, pageID: pageID, stroke: try XCTUnwrap(ink.actions.first { $0.id == strokeID }))
    }
    try await wait { !model.graphicCommandPending }
    await model.reloadExternalChanges()?.value
    let id: String
    if onBoard { id = try XCTUnwrap(model.boardHierarchy?.board(target.id)?.elements.first { $0.graphic != nil }?.id) }
    else { id = try XCTUnwrap(model.pages[pageID]?.elements.first { $0.graphic != nil }?.id) }
    let reference: EditableElementReference = onBoard ? .spatial(boardID: target.id, elementID: id) : .page(pageID: pageID, elementID: id)
    func graphic() throws -> NotebookGraphic? {
      if onBoard { return try store.readSpatialElement(boardID: target.id, elementID: id)?.graphic }
      return try store.readPageElement(pageID: pageID, elementID: id)?.graphic
    }
    let conversion = try XCTUnwrap(store.collaborationActions(afterID: nil).first { $0.action.operations.contains { $0.kind == .convertInkToElement } })
    XCTAssertEqual(conversion.author, .human)
    model.moveElementAccessibly(reference, by: .init(x: 24, y: 18))
    try await wait { !model.graphicCommandPending }
    await model.reloadExternalChanges()?.value
    let moved = try XCTUnwrap(store.collaborationActions(afterID: nil).first { $0.action.operations.contains { $0.kind == .updateElement } })
    XCTAssertEqual(moved.author, .human)
    let edit = try store.applyCollaborationAction(.init(summary: "Agent label",
      references: [.init(target: target, elementID: id, revision: store.targetContentRevision(target: target))],
      expected: [.init(target: target, revision: store.targetContentRevision(target: target))],
      operations: [.init(kind: .updateElement, target: target, id: id, values: ["graphic": .object(["label": .string("+")])])]), actor: UUID())
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.graphicElement(reference)?.label, "+")
    model.selectElement(reference); model.deleteElement(reference)
    try await wait { !model.graphicCommandPending }
    XCTAssertEqual(try graphic()?.visible, false)
    let deletion = try XCTUnwrap(store.collaborationActions(afterID: nil).first { $0.action.operations.contains { $0.kind == .removeElement } })
    for receipt in [deletion, edit, moved, conversion] {
      if reopens {
        let saved = await model.shutdown(); XCTAssertTrue(saved)
        model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
        retainNotebookUntilTeardown(model, removing: root)
        await model.start(pageSize: NotebookAppModel.defaultPageSize)
      }
      model.undoCollaboration(receipt.id)
      // Quiescent save joins the accepted command, including its idle wait;
      // returning early here would lose the inverse on immediate process exit.
      let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
      XCTAssertNotNil(try store.collaborationActions(afterID: nil).first { $0.id == receipt.id }?.undo)
      await model.reloadExternalChanges()?.value
    }
    XCTAssertEqual(try graphic()?.representation, .ink)
    XCTAssertEqual(try graphic()?.visible, true)
    XCTAssertEqual(try graphic()?.label, "")
  }

  private func wait(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(try predicate())
  }
}
