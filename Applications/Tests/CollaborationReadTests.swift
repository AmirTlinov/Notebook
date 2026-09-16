import NotebookCore
import XCTest
@testable import Notebook

final class CollaborationReadTests: XCTestCase {
  @MainActor
  func testRegionalProofBatchKeepsIndependentStatesAndRefreshesArrivingReceipts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage)
    let target = CollaborationTarget(kind: .page, id: page.id)
    let revision = try model.store.referenceRevision(target: target)
    let current = CollaborationReference(target: target,
      region: .init(x: 10, y: 10, width: 30, height: 30), revision: revision)
    let pending = CollaborationReference(target: target,
      region: .init(x: 50, y: 10, width: 30, height: 30), revision: revision)
    let unexamined = CollaborationReference(target: target,
      region: .init(x: 90, y: 10, width: 30, height: 30), revision: "unexamined-version")
    let missing = CollaborationReference(target: .init(kind: .page, id: UUID()),
      region: .init(x: 10, y: 10, width: 30, height: 30), revision: revision)
    try model.store.appendContext(references: [current, pending, unexamined, missing],
      author: .human, actor: model.actorID)
    let readyRequest = try model.store.requestTargetRender(target: target,
      expectedRevision: model.store.targetContentRevision(target: target), region: current.region)
    let pendingRequest = try model.store.requestTargetRender(target: target,
      expectedRevision: model.store.targetContentRevision(target: target), region: pending.region)
    try model.store.saveTargetRender(.init(request: readyRequest, status: "ready", referenceFingerprint: "first-region"))
    await model.reloadExternalChanges()?.value
    await model.refreshCollaborationDetails()
    XCTAssertTrue(model.collaborationDetailsAreCurrent)
    XCTAssertNil(model.referenceStatusLabel(current))
    XCTAssertEqual(model.referenceStatusLabel(pending), "Проверяется область")
    XCTAssertEqual(model.referenceStatusLabel(unexamined), "Нужно рассмотреть заново")
    XCTAssertEqual(model.referenceStatusLabel(missing), "Исходник удалён")

    let historyKey = model.collaborationPreparationKey
    try model.store.saveTargetRender(.init(request: pendingRequest, status: "ready", referenceFingerprint: "second-region"))
    let finger = UUID()
    model.inputGate.beginContact(source: finger)
    await model.refreshReferenceStatuses()
    XCTAssertEqual(model.referenceStatusLabel(pending), "Проверяется область",
      "A new proof must not start background preparation during the contact")
    model.inputGate.endContact(source: finger)
    for _ in 0..<100 where model.inputGate.isActive { await Task.yield() }
    await model.refreshReferenceStatuses()
    XCTAssertEqual(model.collaborationPreparationKey, historyKey,
      "A new proof needs a fresh read, not a new content snapshot or a persistent proof cache")
    XCTAssertNil(model.referenceStatusLabel(current))
    XCTAssertNil(model.referenceStatusLabel(pending))
    XCTAssertEqual(model.referenceStatusLabel(unexamined), "Нужно рассмотреть заново")
    XCTAssertEqual(model.referenceStatusLabel(missing), "Исходник удалён")
  }

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
    await model.refreshCollaborationDetails()
    XCTAssertTrue(model.collaborationDetailsAreCurrent)
    XCTAssertEqual(model.results(for: action).first?.target, .init(kind: .document, id: id),
      "History resolves the durable owner even when its body is outside the scene")
    XCTAssertTrue(model.continuations(for: action).isEmpty,
      "An unloaded document is not a removed document")
    XCTAssertNil(model.documents[id], "Reading history must not mount a closed document")
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

    let preparedKey = model.collaborationPreparationKey
    let preparedContent = model.collaborationContent
    for _ in 0..<3 {
      let readEpoch = model.collaborationReadEpoch
      await model.reloadExternalChanges()?.value
      XCTAssertEqual(model.collaborationContent, preparedContent)
      XCTAssertGreaterThan(model.collaborationReadEpoch, readEpoch,
        "Accepting a SQL cut must still invalidate older asynchronous scene reads")
      XCTAssertEqual(model.collaborationPreparationKey, preparedKey,
        "Reading identical source values is not a new history input")
      XCTAssertTrue(model.collaborationDetailsAreCurrent,
        "A repeated read must retain prepared results without serializing the same sources again")
      XCTAssertEqual(model.results(for: readModel).first?.region?.x, 30)
    }

    model.selectElement(.page(pageID: page.id, elementID: "idea"))
    model.clearSelection()
    XCTAssertEqual(model.collaborationPreparationKey, preparedKey,
      "Ordinary selection does not add a reference or change source content")
    XCTAssertTrue(model.collaborationDetailsAreCurrent)

    model.requestShow(reference)
    let highlighted = try XCTUnwrap(model.requestedReference)
    model.completeShow(highlighted)
    XCTAssertFalse(model.collaborationDetailsAreCurrent, "A new highlighted reference must be prepared")
    await model.refreshCollaborationDetails()
    XCTAssertNil(model.referenceStatusLabel(highlighted))
    model.clearSelection()
    XCTAssertFalse(model.collaborationDetailsAreCurrent)
    await model.refreshCollaborationDetails()
    XCTAssertTrue(model.collaborationDetailsAreCurrent)

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
