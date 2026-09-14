import NotebookCore
import XCTest
@testable import Notebook

final class CollaborationReadTests: XCTestCase {
  @MainActor
  func testLargeReceivedActionOpensTheBoardWithoutLoadingTheClosedDocumentBody() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID(), id = UUID()
    let actionID = try await Task.detached {
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
      let blocks = (0..<140).map { DocumentBlock.markdown(id: "part-\($0)",
        source: "# Chapter \($0)\n\n" + String(repeating: "Large source. ", count: 3_800)) }
      let receipt = try store.applyCollaborationAction(.init(summary: "Large received document", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target)),
        .init(target: .init(kind: .workspace, id: header.rootBoardID), revision: store.workspaceHeader().stamp.revision)
      ], operations: [.init(kind: .createDocument, target: target, id: id.uuidString, values: [
        "paperSize": .string("a4"), "blocks": try .encode(blocks), "center": try .encode(WorldPoint.zero)])]), actor: actor)
      try store.savePresence(.init(boardID: header.rootBoardID, mode: .board, camera: .init(),
        viewport: .init(x: 834, y: 1194), openProgress: 0, selectedItemID: id))
      return receipt.id
    }.value
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    await model.reloadExternalChanges()?.value
    XCTAssertNil(model.persistenceFailure)
    XCTAssertEqual(model.presence?.mode, .board)
    XCTAssertEqual(model.presence?.openProgress, 0)
    XCTAssertNil(model.documents[id], "A closed document contributes geometry and metadata, not its body")
    let action = try XCTUnwrap(model.collaborationActions.first { $0.id == actionID })
    XCTAssertLessThan(try JSONEncoder().encode(action).count, 128 * 1_024)
    let delivery = try XCTUnwrap(store.deviceActionReceipts(actionIDs: [actionID]).first)
    XCTAssertTrue(delivery.matches(action))
    XCTAssertFalse(delivery.displayComplete, "Arrival alone is not installation")
  }

  @MainActor
  func testHistoryReadsDoNotPrepareContentAndInvalidateAfterHumanChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let target = CollaborationTarget(kind: .page, id: page.id)
    let action = try model.store.applyCollaborationAction(.init(summary: "Пояснение",
      expected: [.init(target: target, revision: page.agentStamp.revision)], operations: [
        .init(kind: .insertElement, target: target, id: "idea", values: ["kind": .string("markdown"),
          "source": .string("Idea"), "html": .string("Idea"), "frame": .object([
            "x": .number(30), "y": .number(30), "width": .number(200), "height": .number(80)])])]), actor: UUID())
    await model.reloadExternalChanges()?.value
    let readModel = try XCTUnwrap(model.collaborationActions.first { $0.id == action.id })
    let reference = try XCTUnwrap(action.resultReferences(in: XCTUnwrap(model.collaborationContent)).first)
    let finger = UUID()
    model.inputGate.beginContact(source: finger)
    await model.refreshCollaborationDetails()
    XCTAssertFalse(model.collaborationDetailsAreCurrent)
    let clock = ContinuousClock(), began = clock.now
    for _ in 0..<100 {
      XCTAssertTrue(model.results(for: readModel).isEmpty)
      XCTAssertTrue(model.continuations(for: readModel).isEmpty)
      XCTAssertEqual(model.referenceStatusLabel(reference), "Проверяется исходник")
    }
    XCTAssertLessThan(began.duration(to: clock.now), .milliseconds(100), "Строки не ждут сериализации, файлов или замка")
    model.inputGate.endContact(source: finger)
    for _ in 0..<100 where model.inputGate.isActive { await Task.yield() }
    await model.refreshCollaborationDetails()
    XCTAssertTrue(model.collaborationDetailsAreCurrent)
    XCTAssertEqual(model.results(for: readModel).first?.region?.x, 30)

    var changed = try model.store.loadPage(page.id)
    _ = changed.replaceElements([.init(id: "idea", kind: .markdown,
      frame: .init(x: 130, y: 30, width: 200, height: 80), source: "Human", html: "Human")], actor: model.actorID)
    _ = try model.store.savePage(changed)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    XCTAssertFalse(model.collaborationDetailsAreCurrent)
    XCTAssertTrue(model.results(for: readModel).isEmpty, "Старое положение не выдаётся за текущий результат")
    await model.refreshCollaborationDetails()
    XCTAssertEqual(model.results(for: readModel).first?.region?.x, 130)
    XCTAssertTrue(model.continuations(for: readModel).contains { $0.author == .human })
  }
}
