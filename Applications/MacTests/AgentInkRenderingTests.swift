import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class AgentInkRenderingTests: XCTestCase {
  @MainActor
  func testAgentPenReachesNativeCompositeAndUndoWithoutMovingCamera() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-ink-render-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let target = CollaborationTarget(kind: .page, id: page.id)
    let before = model.presence
    let action = CollaborationAction(summary: "Линия агента общей ручкой", expected: [
      .init(target: target, revision: page.agentStamp.revision, inkRevision: page.drawingStamp.revision)
    ], operations: [.init(kind: .appendInkStroke, target: target, id: UUID().uuidString, values: [
      "width": .number(8), "color": .object(["red": .number(0.1), "green": .number(0.25), "blue": .number(0.7)]),
      "points": .array([.object(["x": .number(80), "y": .number(100)]),
        .object(["x": .number(180), "y": .number(180), "width": .number(5), "opacity": .number(0.5)]),
        .object(["x": .number(300), "y": .number(100)])])
    ])])
    _ = try model.store.applyCollaborationAction(action, actor: UUID())
    await model.reloadExternalChanges()?.value
    let drawn = try XCTUnwrap(model.activePage)
    XCTAssertTrue(drawn.elements.isEmpty)
    XCTAssertGreaterThan(drawn.drawingStamp, page.drawingStamp)
    let vision = try PageVisionRenderer.render(drawn)
    XCTAssertFalse(vision.regions.isEmpty)
    let request = try model.store.requestTargetRender(target: target, expectedRevision: drawn.agentStamp.revision)
    try await CurrentViewPreviewWriter.writeTarget(request, model: model)
    let receipt = try JSONDecoder().decode(TargetRenderReceipt.self, from: Data(contentsOf: model.store.targetReceiptURL(request.id)))
    XCTAssertEqual(receipt.status, "ready")
    XCTAssertTrue(receipt.diagnostics.isEmpty)
    XCTAssertFalse(receipt.inkRegions.isEmpty)
    XCTAssertEqual(model.presence, before)
    if let path = ProcessInfo.processInfo.environment["NOTEBOOK_AGENT_INK_PROOF"] {
      let crop = try model.store.requestTargetRender(target: target, expectedRevision: drawn.agentStamp.revision,
        region: .init(x: 55, y: 75, width: 270, height: 135))
      try await CurrentViewPreviewWriter.writeTarget(crop, model: model)
      try Data(contentsOf: model.store.targetPNGURL(crop.id)).write(to: URL(fileURLWithPath: path))
    }
    _ = try model.store.undoCollaborationAction(action.id, actor: UUID())
    await model.reloadExternalChanges()?.value
    let undone = try XCTUnwrap(model.activePage)
    XCTAssertTrue(try PageVisionRenderer.render(undone).regions.isEmpty)
    XCTAssertEqual(model.presence, before)
  }
}
