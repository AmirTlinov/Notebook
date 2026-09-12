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
  func testItemElementRegionAndContextCannotRetainCompetingSelections() async throws {
    try await fixture { model in
      let question = try await point(model)
      let presence = try XCTUnwrap(model.presence)
      let item = try XCTUnwrap(model.workspace?.selectedItemID)
      let element = EditableElementReference.page(pageID: try XCTUnwrap(model.activePage).id, elementID: "artifact")
      model.selectElement(element)
      XCTAssertEqual(model.selectionSession.target, .element(element))
      XCTAssertNil(model.agentQuestion)
      XCTAssertNil(model.selectionSession.itemID(on: presence.boardID))
      model.interactiveElementFocus = .page(pageID: try XCTUnwrap(model.activePage).id, elementID: "artifact")
      model.selectWorkspaceItem(item, boardID: presence.boardID)
      XCTAssertEqual(model.selectionSession.target, .item(boardID: presence.boardID, itemID: item))
      XCTAssertNil(model.selectionSession.element); XCTAssertNil(model.interactiveElementFocus)
      model.updateSelectionPreview(.init(x: 30, y: 40, width: 100, height: 80))
      XCTAssertEqual(model.selectionSession.target, .context)
      XCTAssertNil(model.selectionSession.element); XCTAssertNil(model.selectionSession.itemID(on: presence.boardID))
      XCTAssertNotNil(model.selectionSession.preview)
      model.clearSelection()
      XCTAssertNil(model.selectionSession.target); XCTAssertNil(model.selectionSession.preview)
      XCTAssertNil(model.agentQuestion)
      model.selectSharedContext(question.id)
      XCTAssertEqual(model.selectionSession.target, .context)
      XCTAssertEqual(model.agentQuestion, question)
      XCTAssertNil(model.selectionSession.element); XCTAssertNil(model.selectionSession.preview)
      await model.finishPendingPersistence()
      XCTAssertEqual(model.presence, presence)
    }
  }

  @MainActor
  func testLatePointAndHistoryCompletionCannotReopenAReplacedChoice() async throws {
    try await fixture { model in
      let capture = try selection(model)
      let presence = try XCTUnwrap(model.presence)
      let element = EditableElementReference.page(pageID: try XCTUnwrap(model.activePage).id, elementID: "next-artifact")
      model.publishHumanContext(capture)
      model.selectElement(element)
      let admission = model.selectionSession.id
      await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
      XCTAssertEqual(model.selectionSession.id, admission)
      XCTAssertEqual(model.selectionSession.element, element); XCTAssertNil(model.agentQuestion)
      let history = try XCTUnwrap(model.store.sharedContexts().contexts.first)
      XCTAssertNil(try model.store.sharedContexts().selection?.contextID)
      model.selectSharedContext(history.id)
      let item = try XCTUnwrap(model.workspace?.selectedItemID)
      model.selectWorkspaceItem(item, boardID: presence.boardID)
      await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
      XCTAssertEqual(model.selectionSession.target, .item(boardID: presence.boardID, itemID: item))
      XCTAssertNil(model.agentQuestion); XCTAssertNil(try model.store.sharedContexts().selection?.contextID)
      XCTAssertEqual(try model.store.sharedContexts().contexts.count, 1, "Superseding a choice retains accepted history")
    }
  }

  @MainActor
  func testSameElementIDOnAnotherBoardAndReferenceHighlightDoNotShareSelection() async throws {
    try await fixture { model in
      let first = EditableElementReference.spatial(boardID: UUID(), elementID: "chart")
      let second = EditableElementReference.spatial(boardID: UUID(), elementID: "chart")
      model.selectElement(first)
      model.selectElement(second)
      XCTAssertEqual(model.selectionSession.element, second); XCTAssertNil(model.selectionSession.manipulation)
      let question = try await point(model)
      model.completeShow(try XCTUnwrap(question.references.first))
      XCTAssertNil(model.agentQuestion); XCTAssertNil(model.selectionSession.element)
      XCTAssertNotNil(model.highlightedReference)
      model.selectElement(first)
      XCTAssertNil(model.highlightedReference)
      await model.finishPendingPersistence()
      XCTAssertEqual(model.selectionSession.element, first)
    }
  }

  @MainActor
  func testPendingSelectionCannotSendThePreviousMaterialOrAnEmptyContext() async throws {
    try await fixture { model in
      let chat = try XCTUnwrap(model.chat)
      chat.select(.init(id: UUID().uuidString, title: "Обсуждение", cwd: "/tmp"))
      chat.draft = "Объясни выбранное"
      model.publishHumanContext(try selection(model))
      XCTAssertNil(model.sendChatMessage())
      XCTAssertTrue(chat.jobs.isEmpty); XCTAssertEqual(chat.draft, "Объясни выбранное")
      await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
      let context = try XCTUnwrap(model.agentQuestion)
      await model.sendChatMessage()?.value
      XCTAssertEqual(chat.jobs.count, 1)
      XCTAssertEqual(chat.jobs.first?.input.attentionContextID, context.contextID)
    }
  }

  @MainActor
  func testRejectedSourceCannotRestorePreviousSelectionAfterReload() async throws {
    try await fixture { model in
      _ = try await point(model)
      let capture = try selection(model)
      var page = try XCTUnwrap(model.activePage)
      page.replaceElements([.init(id: "changed", kind: .web, frame: .init(x: 20, y: 20, width: 80, height: 80), source: "", html: "<div>New</div>")], actor: model.actorID)
      try model.store.savePage(page)
      model.publishHumanContext(capture)
      await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
      XCTAssertNil(model.agentQuestion); XCTAssertFalse(model.selectionSession.isResolvingContext)
      XCTAssertNotNil(model.agentRequestError)
      XCTAssertNil(try model.store.sharedContexts().selection?.contextID)
      XCTAssertEqual(try model.store.sharedContexts().contexts.count, 1)
      XCTAssertEqual(try model.store.loadPage(page.id).elements, page.elements)
    }
  }

  @MainActor
  func testNavigationWhileContextIsSavingRetainsOnlyThatContext() async throws {
    try await fixture { model in
      let element = EditableElementReference.page(pageID: try XCTUnwrap(model.activePage).id, elementID: "artifact")
      model.publishHumanContext(try selection(model), target: .element(element))
      let admission = model.selectionSession.id
      model.endSurfaceEditing()
      await model.finishPendingPersistence(); await model.reloadExternalChanges()?.value
      XCTAssertEqual(model.selectionSession.id, admission)
      XCTAssertNil(model.selectionSession.element)
      XCTAssertEqual(model.selectionSession.target, .context)
      XCTAssertNotNil(model.agentQuestion)
      XCTAssertEqual(model.agentQuestion?.id, try model.store.sharedContexts().selection?.contextID)
    }
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
      await model.sendChatMessage()?.value
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

  @MainActor
  func testSendAdmissionPinsTheShownTaskAndShutdownWaitsForItsDurableMessage() async throws {
    try await fixture { model in
      let chat = try XCTUnwrap(model.chat)
      let first = CodexTask(id: UUID().uuidString, title: "Первый урок", cwd: "/tmp")
      let second = CodexTask(id: UUID().uuidString, title: "Другой урок", cwd: "/tmp")
      chat.select(first); chat.draft = "Исходный вопрос"
      let accepted = try XCTUnwrap(model.sendChatMessage())
      XCTAssertNil(model.sendChatMessage(), "A second tap cannot enter before the first save")
      chat.select(second); chat.draft = "Следующий черновик"
      let stopped = await model.shutdown(); XCTAssertTrue(stopped)
      await accepted.value
      let job = try XCTUnwrap(model.store.recentChatJobs(author: model.actorID).first)
      guard case .send(let thread, let text, _) = job.input.action else { return XCTFail("Expected the admitted message") }
      XCTAssertEqual(thread, first.id); XCTAssertEqual(text, "Исходный вопрос")
      let panel = try model.store.chatPanel(author: model.actorID)
      XCTAssertEqual(panel.threadID, second.id); XCTAssertEqual(panel.draft, "Следующий черновик")
      XCTAssertNil(model.sendChatMessage(), "Shutdown closes new submission admission")
    }
  }
}
