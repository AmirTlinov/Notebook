import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookChatControllerTests: XCTestCase {
  func testOfflineQueueAdmitsInOrderWhileEarlierReceiptsDisappearAndNeverChangesIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-chat-delivery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    var controller: NotebookChatController!
    var offers: [UUID] = [], envelopeIDs: [UUID: UUID] = [:]
    let admitted = expectation(description: "All saved messages reached the same Mac in order")
    controller = .init(persistence: queue, author: author) { envelope, destination in
      XCTAssertEqual(destination, peer)
      guard case .request(let query) = envelope.body else { return XCTFail("Expected a query") }
      let reply: NotebookChatReply
      switch query {
      case .job(let input):
        if let previous = envelopeIDs[input.id] {
          XCTAssertEqual(previous, envelope.id, "An unacknowledged transport retry retains its request ID")
        } else {
          envelopeIDs[input.id] = envelope.id
          offers.append(input.id)
          if offers.count == 1 { return } // Lost reply: do not invent a second message.
        }
        let job = NotebookChatJob(input: input, state: .accepted, result: .turn(UUID().uuidString), revision: 2)
        reply = .job(job)
        if offers.count == 3 { admitted.fulfill() }
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      default: return XCTFail("Collapsed panel must not poll a conversation")
      }
      controller.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    let inputs = [300, 100, 200].map { time in
      NotebookChatInput(author: author, action: .send(threadID: thread, text: "Часы \(time)", context: ""),
        createdAt: Date(timeIntervalSince1970: Double(time)))
    }
    for input in inputs { _ = try store.saveChatSubmission(input) }
    let expected = inputs.map(\.id)
    await controller.start()
    controller.connect(peer)
    await fulfillment(of: [admitted], timeout: 10)
    await controller.stop()
    XCTAssertEqual(offers, expected)
    XCTAssertEqual(Set(offers).count, 3)
    let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }

  func testPermissionAndStopKeepTheirNativeAddressAcrossTapsTaskChangesAndRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-chat-controls-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let request = CodexUserRequest(nativeID: .number(7), method: "item/commandExecution/requestApproval",
      turnID: UUID().uuidString, parameters: .object(["command": .string("read this file")]))
    let first = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("An offline approval cannot send itself") }
    await first.start(); first.select(.init(id: thread, title: "Урок", cwd: "/tmp"))
    await first.respond(request, decision: .allowOnce, threadID: thread)
    let job = try XCTUnwrap(first.decisionJob(request, threadID: thread))
    first.expanded = false; first.expanded = true
    await first.respond(request, decision: .allowOnce, threadID: thread)
    XCTAssertEqual(first.jobs, [job])
    await first.stop()
    let second = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("An offline approval cannot send itself") }
    await second.start()
    XCTAssertEqual(second.threadID, thread)
    second.select(.init(id: UUID().uuidString, title: "Другая задача", cwd: "/tmp"))
    await second.respond(request, decision: .allowOnce, threadID: thread)
    XCTAssertEqual(second.jobs, [job])
    await second.respond(request, decision: .decline, threadID: thread)
    XCTAssertNotNil(second.error)
    XCTAssertEqual(second.jobs, [job], "A second button cannot rewrite the accepted human decision")
    await second.stopTurn(threadID: thread, turnID: request.turnID)
    await second.stopTurn(threadID: thread, turnID: request.turnID)
    XCTAssertEqual(second.jobs.count, 2)
    XCTAssertTrue(second.jobs.allSatisfy { $0.input.action.threadID == thread }, "A delayed tap addresses the shown task, not the later selection")
    await second.stop()
    let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }
}
