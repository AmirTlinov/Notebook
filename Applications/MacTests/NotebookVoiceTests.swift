import XCTest
import NotebookCore
import NotebookCodex
@testable import Notebook

private actor VoiceOwner: NotebookCodexVoiceOwner {
  var current: NotebookVoiceState?
  var starts = 0, stops = 0
  func startVoice(id: UUID, request: NotebookVoiceStart) { starts += 1; current = .init(id: id, threadID: request.threadID, phase: .active, sdp: "v=0\r\nanswer") }
  func stopVoice(id: UUID) { stops += 1; if current?.id == id { current?.phase = .ended; current?.sdp = nil } }
  func voiceState(id: UUID) -> NotebookVoiceState? { current?.id == id ? current : nil }
  func counts() -> (Int, Int) { (starts, stops) }
}
@MainActor final class NotebookVoiceTests: XCTestCase {
  private func receive(_ service: MacNotebookVoice, _ queue: NotebookPersistenceQueue, _ input: NotebookChatInput) async throws -> NotebookChatJob {
    let job = try await queue.submit { try $0.saveChatInput(input) }
    return try await service.receive(job) {
      try await queue.submit { try $0.advanceChatJob(input.id, from: .saved, to: .attempting) }
    }
  }

  func testVoiceHasOneJournalIdentityAndCannotBeReadOrStoppedByAnotherPeer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory), author = UUID(), queue = NotebookPersistenceQueue(store: store)
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let owner = VoiceOwner(), service = MacNotebookVoice(persistence: queue, executor: VoiceOwner())
    let actual = MacNotebookVoice(persistence: queue, executor: owner)
    let start = NotebookChatInput(author: author, action: .startVoice(.init(threadID: UUID().uuidString, sdp: "v=0\r\noffer")))
    _ = try await receive(actual, queue, start); _ = try await receive(actual, queue, start)
    do { _ = try await actual.state(start.id, peer: UUID()); XCTFail("Another peer may not see SDP") } catch { }
    let wrong = try await receive(actual, queue, .init(author: UUID(), action: .stopVoice(start.id)))
    XCTAssertEqual(wrong.state, .rejected)
    let stop = NotebookChatInput(author: author, action: .stopVoice(start.id))
    _ = try await receive(actual, queue, stop); _ = try await receive(actual, queue, stop)
    let counts = await owner.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    let ended = try await actual.state(start.id, peer: author); XCTAssertEqual(ended.phase, .ended); XCTAssertNil(ended.sdp)
    let cold = try await service.state(start.id, peer: author); XCTAssertEqual(cold.phase, .ended)
    _ = try await receive(service, queue, start)
    let final = await owner.counts(); XCTAssertEqual(final.0, 1)
  }
}
