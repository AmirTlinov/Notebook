import NotebookCore
import XCTest
@testable import Notebook

final class NotebookAgentQuestionTests: XCTestCase {
  @MainActor
  private func fixture(_ body: (NotebookAppModel) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-question-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    try await body(model)
  }

  @MainActor
  private func selection(_ model: NotebookAppModel, x: Double = 20) throws -> NotebookAttentionSelection {
    let page = try XCTUnwrap(model.activePage)
    return NotebookAttentionSelection(fragments: [.init(target: .init(kind: .page, id: page.id),
      elementID: nil, region: .init(x: x, y: 20, width: 100, height: 100),
      worldOrigin: nil, pageIndex: nil, label: "Фрагмент")],
      workspace: try XCTUnwrap(model.workspace), hierarchy: try XCTUnwrap(model.boardHierarchy),
      ink: try XCTUnwrap(model.spatialInk), pages: model.pages, documents: model.documents, states: model.documentStates)
  }

  @MainActor
  private func point(_ model: NotebookAppModel, x: Double = 20) async throws -> NotebookAgentQuestion {
    let old = model.agentQuestion?.id
    model.publishHumanContext(try selection(model, x: x))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let deadline = ContinuousClock.now + .seconds(2)
    while model.agentQuestion?.id == old, ContinuousClock.now < deadline { await Task.yield() }
    return try XCTUnwrap(model.agentQuestion)
  }

  @MainActor
  func testDismissRemovesIndicationAcrossReloadAndRestartWithoutDeletingQuestion() async throws {
    try await fixture { model in
      let question = try await point(model)
      let saved = await model.sendAgentQuestion("Что здесь?", mode: .question, question: question)
      XCTAssertTrue(saved, model.agentRequestError ?? "")
      let context = try XCTUnwrap(model.store.sharedContexts().contexts.first)
      let request = try XCTUnwrap(model.store.readAgentRequestHeaders(limit: 1).first)
      let presence = model.presence

      model.dismissAgentQuestion()
      XCTAssertNil(model.agentQuestion, "Closing removes the local indication synchronously")
      let dismissed = await model.finishPendingPersistence()
      XCTAssertTrue(dismissed)
      await model.reloadExternalChanges()?.value
      XCTAssertNil(model.activeSharedContext, "A closed indication is not the active shared selection")
      XCTAssertNil(try model.store.sharedContexts().selection?.contextID)
      XCTAssertEqual(try model.store.sharedContexts().contexts, [context])
      XCTAssertEqual(try model.store.agentRequest(request.id)?.status, .queued)
      XCTAssertEqual(try model.store.agentRequest(request.id)?.request.grant.references, question.references)
      XCTAssertEqual(model.presence, presence)

      let stopped = await model.shutdown()
      XCTAssertTrue(stopped)
      let resumed = NotebookAppModel(store: model.store, startsNearbySync: false)
      addTeardownBlock {
        let stopped = await resumed.shutdown()
        XCTAssertTrue(stopped)
      }
      await resumed.start(pageSize: NotebookAppModel.defaultPageSize)
      await resumed.finishPendingPersistence()
      XCTAssertNil(resumed.agentQuestion, "Restart must not reopen a dismissed fragment")
      XCTAssertNil(resumed.activeSharedContext)
      resumed.selectSharedContext(question.contextID)
      XCTAssertEqual(resumed.agentQuestion, question, "History explicitly resumes the original pinned references")
      await resumed.finishPendingPersistence()
      XCTAssertEqual(resumed.activeSharedContext?.id, question.contextID)
    }
  }

  @MainActor
  func testDismissBeforePointerCommitDoesNotRestoreItsSelection() async throws {
    try await fixture { model in
      // Both admissions happen without yielding the main actor: the accepted
      // pointer's asynchronous completion necessarily follows the dismissal.
      model.publishHumanContext(try selection(model))
      model.dismissAgentQuestion()
      let saved = await model.finishPendingPersistence()
      XCTAssertTrue(saved)
      await model.reloadExternalChanges()?.value
      XCTAssertNil(model.agentQuestion)
      XCTAssertNil(model.activeSharedContext)
      let snapshot = try model.store.sharedContexts()
      XCTAssertEqual(snapshot.contexts.count, 1, "Dismissal does not discard an accepted indication")
      XCTAssertNil(snapshot.selection?.contextID, "The close follows the pointer in the same durable queue")
    }
  }

  @MainActor
  func testOfflineQuestionKeepsItsOriginalContextAcrossSelectionAndRestart() async throws {
    try await fixture { model in
      let first = try await point(model)
      let second = try await point(model, x: 240)
      let presence = model.presence
      let saved = await model.sendAgentQuestion("Что здесь?", mode: .question, question: first)
      XCTAssertTrue(saved, model.agentRequestError ?? "")
      let request = try XCTUnwrap(model.store.readAgentRequestHeaders(limit: 1).first)
      XCTAssertEqual(request.contextID, first.contextID)
      XCTAssertEqual(request.grant.references, first.references)
      XCTAssertEqual(model.agentQuestion, second)
      XCTAssertEqual(model.presence, presence)
      XCTAssertEqual(try model.store.agentRequest(request.id)?.status, .queued)
      let stopped = await model.shutdown()
      XCTAssertTrue(stopped)
      let resumed = NotebookAppModel(store: model.store, startsNearbySync: false)
      addTeardownBlock {
        let stopped = await resumed.shutdown()
        XCTAssertTrue(stopped)
      }
      await resumed.start(pageSize: NotebookAppModel.defaultPageSize)
      _ = await resumed.finishPendingPersistence()
      await resumed.refreshAgentRequests()
      XCTAssertEqual(resumed.agentRequests.first?.id, request.id)
      XCTAssertEqual(resumed.agentRequests.first?.status, .queued)
      XCTAssertEqual(try resumed.store.readAgentRequestHeaders(limit: 32).count, 1)
    }
  }

  @MainActor
  func testResponseDoesNotChangeCameraSelectionOrActivePencil() async throws {
    try await fixture { model in
      let question = try await point(model)
      let saved = await model.sendAgentQuestion("Объясни", mode: .question, question: question)
      XCTAssertTrue(saved, model.agentRequestError ?? "")
      let request = try XCTUnwrap(model.store.readAgentRequestHeaders(limit: 1).first)
      let authority = try model.store.claimAgentRequest(request.id, actor: UUID())
      let pencil = UUID(), presence = model.presence
      model.inputGate.beginPencilAction(source: pencil)
      let generation = model.inputGate.pencilGeneration
      try model.store.appendAgentResponse(authority, sequence: 1, text: "Ответ относится только к указанному фрагменту.")
      _ = try model.store.finishAgentRequest(authority, status: .completed)
      await model.refreshAgentRequests()
      XCTAssertEqual(model.currentAgentRequest?.responseText, "Ответ относится только к указанному фрагменту.")
      XCTAssertEqual(model.presence, presence)
      XCTAssertEqual(model.agentQuestion, question)
      XCTAssertTrue(model.inputGate.hasActivePencil)
      XCTAssertEqual(model.inputGate.pencilGeneration, generation)
      model.inputGate.endPencilAction(source: pencil)
      _ = await model.finishPendingPersistence()
    }
  }
}
