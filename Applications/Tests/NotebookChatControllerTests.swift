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
    await controller.start()
    var expected: [UUID] = []
    for text in ["Первый", "Второй", "Третий"] {
      let saved = await controller.sendMessage(threadID: thread, text: text, context: "")
      XCTAssertTrue(saved)
      expected.append(try XCTUnwrap(controller.jobs.first).id)
    }
    controller.connect(peer)
    await fulfillment(of: [admitted], timeout: 10)
    await controller.stop()
    XCTAssertEqual(offers, expected)
    XCTAssertEqual(Set(offers).count, 3)
    let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }
}
