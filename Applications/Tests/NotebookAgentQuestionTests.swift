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
      let context = try XCTUnwrap(model.store.sharedContexts().contexts.first)
      let presence = model.presence

      model.dismissAgentQuestion()
      XCTAssertNil(model.agentQuestion, "Closing removes the local indication synchronously")
      let dismissed = await model.finishPendingPersistence()
      XCTAssertTrue(dismissed)
      await model.reloadExternalChanges()?.value
      XCTAssertNil(model.activeSharedContext, "A closed indication is not the active shared selection")
      XCTAssertNil(try model.store.sharedContexts().selection?.contextID)
      XCTAssertEqual(try model.store.sharedContexts().contexts, [context])
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
  func testOfflineChatKeepsContextDraftAndTaskAcrossSelectionAndRestart() async throws {
    try await fixture { model in
      let first = try await point(model)
      let chat = try XCTUnwrap(model.chat)
      let thread = CodexTask(id: UUID().uuidString, title: "Математика", cwd: "/tmp")
      chat.select(thread); chat.draft = "Что здесь?"
      let presence = model.presence
      await model.sendChatMessage()
      let job = try XCTUnwrap(chat.jobs.first)
      guard case .send(let id, let text, let context) = job.input.action else { return XCTFail("Expected native Codex message") }
      XCTAssertEqual(id, thread.id); XCTAssertEqual(text, "Что здесь?")
      XCTAssertTrue(context.contains(first.contextID.uuidString))
      _ = try await point(model, x: 240)
      XCTAssertEqual(try model.store.chatJob(job.id), job)
      XCTAssertEqual(model.presence, presence)
      chat.draft = "Следующий вопрос"
      let stopped = await model.shutdown(); XCTAssertTrue(stopped)
      let resumed = NotebookAppModel(store: model.store, startsNearbySync: false)
      await resumed.start(pageSize: NotebookAppModel.defaultPageSize)
      XCTAssertEqual(resumed.chat?.threadID, thread.id)
      XCTAssertEqual(resumed.chat?.draft, "Следующий вопрос")
      XCTAssertEqual(resumed.chat?.jobs.first, job)
      let finished = await resumed.shutdown(); XCTAssertTrue(finished)
    }
  }
}
