import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookAgentCoordinatorTests: XCTestCase {
  func testCrashRecoveryRetainsChunksAndCommittedActionButNeverReplaysOrClaimsWithoutLogin() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-agent-coordinator-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), human = UUID(), mac = UUID()
    _ = try store.initializeWorkspace(actor: human, pageSize: .init(width: 834, height: 1194))
    let pageID = try XCTUnwrap(store.readItemHeaders(limit: 1).first?.firstPageID)
    let target = CollaborationTarget(kind: .page, id: pageID)
    let files = try store.referenceSourceFiles(target: target)
    let reference = CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 200, height: 150),
      revision: try NotebookStore.referenceRevision(target: target, files: files))
    let context = try store.appendContext(references: [reference], author: .human, actor: human, select: false)
    func request() throws -> AgentRequest {
      let id = UUID(), grant = try RequestGrant(mode: .change, references: [reference])
      let source = try AgentPinnedSource.capture(requestID: id, reference: reference, files: files)
      return try store.createAgentRequest(id: id, contextID: context.id, replyTo: context.entries[0].id,
        question: "Помоги с выбранной областью", grant: grant, sources: [source], actor: human)
    }
    let interrupted = try request(), queued = try request(), stoppedBeforeStart = try request()
    let authority = try store.claimAgentRequest(interrupted.id, actor: mac)
    try store.appendAgentResponse(authority, sequence: 1, text: "Уже сохранённая часть ответа.")
    let receipt = try store.applyCollaborationAction(.init(contextID: context.id, requestID: interrupted.id,
      summary: "Уже сохранённое изменение", references: [reference], expected: [.init(target: target, revision: store.loadPage(pageID).agentStamp.revision)],
      operations: [.init(kind: .insertElement, target: target, id: "preserved-action", values: ["kind": .string("markdown"),
        "source": .string("Сохранённый смысл"), "frame": try .encode(PageRect(x: 20, y: 20, width: 80, height: 40))])]),
      actor: mac, agentAuthority: authority)
    try store.requestAgentStop(stoppedBeforeStart.id, actor: human)
    let queue = NotebookPersistenceQueue(store: store)
    let missing = URL(fileURLWithPath: "/notebook-no-unverified-runtime")
    let executor = NotebookAgentExecutor(binary: missing, runtimeDirectory: root.appendingPathComponent("runtime"), configuration: missing)
    let coordinator = NotebookAgentCoordinator(executor: executor, persistence: queue, actorID: mac, render: { _, _ in
      XCTFail("Recovery must not render or reinterpret current content")
      throw NotebookAgentFailure.toolDenied
    })
    await coordinator.start()
    let previous = try XCTUnwrap(store.agentRequest(interrupted.id))
    XCTAssertEqual(previous.status, .failed)
    XCTAssertEqual(previous.execution?.executionID, authority.executionID)
    XCTAssertEqual(previous.responseText, "Уже сохранённая часть ответа.")
    XCTAssertEqual(previous.execution?.receiptIDs, [receipt.id])
    XCTAssertTrue(try store.loadPage(pageID).elements.contains { $0.id == "preserved-action" })
    XCTAssertNil(try store.agentRequest(queued.id)?.execution, "Unavailable runtime must not consume the one execution claim")
    XCTAssertEqual(try store.agentRequest(stoppedBeforeStart.id)?.status, .stopped)
    XCTAssertFalse(coordinator.isRunning)
    XCTAssertEqual(coordinator.availability, .unavailable(.unsupportedRuntime))
    let cursor = try store.currentReadCursor()
    for _ in 0..<20 { coordinator.storeDidCommit() }
    let finished = await coordinator.stop()
    XCTAssertTrue(finished)
    XCTAssertEqual(try store.currentReadCursor(), cursor, "Duplicate commit notifications do not create another execution or history")
  }

  func testEmptyWorkspaceAndBlockedWriterNeverProduceAnExecutionOrQuitAcknowledgement() async throws {
    enum Fault: Error { case storageUnavailable }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-empty-agent-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let missing = URL(fileURLWithPath: "/notebook-no-unverified-runtime")
    let executor = NotebookAgentExecutor(binary: missing, runtimeDirectory: root.appendingPathComponent("runtime"), configuration: missing)
    let coordinator = NotebookAgentCoordinator(executor: executor, persistence: queue, actorID: actor, render: { _, _ in
      XCTFail("An empty queue cannot render"); throw NotebookAgentFailure.toolDenied
    })
    let before = try store.currentReadCursor()
    for _ in 0..<20 { coordinator.storeDidCommit() }
    XCTAssertFalse(coordinator.isRunning, "Commit notifications cannot start work before model readiness")
    await coordinator.start()
    XCTAssertTrue(try store.pendingAgentRequests(limit: 16).isEmpty)
    XCTAssertEqual(try store.currentReadCursor(), before)
    queue.enqueue { _ in throw Fault.storageUnavailable }
    let drained = await queue.flush()
    XCTAssertFalse(drained)
    let clean = await coordinator.stop()
    XCTAssertFalse(clean, "Quit must not acknowledge durability while an accepted native write remains blocked")
    XCTAssertEqual(try store.currentReadCursor(), before)
  }

  func testResponseBufferDoesNotRemoveBytesUntilTheSameChunkIsDurable() throws {
    var buffer = NotebookAgentResponseBuffer()
    let text = String(repeating: "Смысл 👨‍👩‍👧‍👦 é ", count: 1000)
    try buffer.append(text)
    let first = try XCTUnwrap(buffer.next())
    XCTAssertLessThanOrEqual(first.text.utf8.count, 8192)
    XCTAssertTrue(text.utf8.starts(with: first.text.utf8))
    XCTAssertFalse(text.hasPrefix(first.text), "The real protocol chunk deliberately ends inside a grapheme, not inside a UTF-8 scalar")
    XCTAssertThrowsError(try buffer.acknowledge(.init(sequence: first.sequence, text: String(first.text.dropLast()))),
      "An arbitrary shorter prefix is not the chunk submitted to the writer")
    XCTAssertEqual(buffer.next(), first, "A failed write retries identical bytes and sequence")
    try buffer.append("Следующий фрагмент.")
    try buffer.acknowledge(first)
    XCTAssertThrowsError(try buffer.acknowledge(first))
    var answer = first.text
    while let chunk = buffer.next() { answer += chunk.text; try buffer.acknowledge(chunk) }
    XCTAssertEqual(answer, text + "Следующий фрагмент.")
    XCTAssertEqual(buffer.pendingBytes, 0)
    XCTAssertThrowsError(try buffer.append(String(repeating: "a", count: 1_048_576)))
    var partial = NotebookAgentResponseBuffer()
    try partial.append("Короткая порция.")
    let accepted = try XCTUnwrap(partial.next())
    try partial.append("Новые байты во время записи.")
    XCTAssertEqual(partial.next(), accepted, "An in-flight short chunk is not enlarged by newly arriving text")
    try partial.acknowledge(accepted)
    XCTAssertEqual(partial.next()?.text, "Новые байты во время записи.")
  }

  func testQuestionCatalogHasNoMutationAndChangeArgumentsCannotSupplyAuthority() throws {
    let question = NotebookAgentCoordinator.tools(for: .question)
    XCTAssertEqual(question.map(\.name), ["read", "render"])
    let change = NotebookAgentCoordinator.tools(for: .change)
    XCTAssertEqual(change.map(\.name), ["read", "render", "apply"])
    let apply = try XCTUnwrap(change.last)
    XCTAssertEqual(apply.inputSchema["additionalProperties"], .bool(false))
    guard case .object(let fields) = apply.inputSchema["properties"] else { return XCTFail("An explicit input object is required") }
    XCTAssertEqual(Set(fields.keys), Set(["summary", "operations"]))
    XCTAssertNil(fields["authority"]); XCTAssertNil(fields["requestID"]); XCTAssertNil(fields["root"])
  }
}
