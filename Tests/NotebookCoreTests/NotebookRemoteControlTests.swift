import Foundation
import Testing
@testable import NotebookCore

@Suite struct NotebookRemoteControlTests {
  @Test func accountChangeRejectsOnlyUnattemptedCommandsAndNeverReplaysShell() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let identity = String(repeating: "a", count: 64)
    #expect(try store.admitCodexAccount(identity))
    let first = NotebookChatInput(author: author, action: .send(threadID: thread, text: "queued", context: ""))
    let second = NotebookChatInput(author: author, action: .send(threadID: thread, text: "attempted", context: ""))
    try store.saveChatInput(first); try store.saveChatInput(second)
    _ = try store.advanceChatJob(second.id, from: .saved, to: .attempting)
    #expect(try !store.admitCodexAccount(identity))
    #expect(try store.chatJob(first.id)?.state == .saved)
    #expect(try store.admitCodexAccount(String(repeating: "b", count: 64)))
    #expect(try store.chatJob(first.id)?.state == .rejected)
    #expect(try store.chatJob(second.id)?.state == .attempting)
    #expect(try store.saveChatInput(first).state == .rejected, "Retransmission is the same rejected command, not new consent")
  }
  @Test func revokedDeviceCannotLeaveAnUnattemptedCommandBehind() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), other = UUID()
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let first = NotebookChatInput(author: author, action: .create(title: "A", project: nil))
    let second = NotebookChatInput(author: other, action: .create(title: "B", project: nil))
    try store.saveChatInput(first); try store.saveChatInput(second)
    try store.rejectSavedChatInputs(from: author)
    #expect(try store.chatJob(first.id)?.state == .rejected)
    #expect(try store.chatJob(second.id)?.state == .saved)
  }
  @Test func bulkBytesCannotTakeReservedControlCapacity() throws {
    var outgoing = NotebookTransportOutgoing()
    let chunk = NotebookTransportMessage.blobs([.init(hash: String(repeating: "a", count: 64), offset: 0,
      totalBytes: 1_048_576, data: Data(repeating: 9, count: NotebookTransportLimits.maximumChunkBytes))])
    var sent: [UInt64] = []
    for _ in 0..<10 {
      if outgoing.pendingCount < 2 { try outgoing.enqueue(chunk) }
      if let packet = try outgoing.takeNext() { sent.append(packet.sequence) }
    }
    #expect(outgoing.window.unacknowledgedBytes <= NotebookTransportLimits.maximumUnacknowledgedBytes - NotebookTransportLimits.reservedControlBytes)
    #expect(outgoing.pendingBytes < NotebookTransportLimits.maximumQueuedBytes)
    let control = NotebookChatEnvelope(body: .request(.account(.read)))
    try outgoing.enqueue(.transient(.codex(control)))
    #expect(try outgoing.takeNext()?.message == .transient(.codex(control)))
    try outgoing.acknowledge(sent)
    #expect(outgoing.window.unacknowledgedBytes < 1024)
  }
  @Test func routingCapabilityCannotTurnRelayIntoAnArbitraryHTTPProxy() {
    let token = String(repeating: "a", count: 43)
    #expect(NotebookRelayRoute(endpoint: URL(string: "https://catocut.com")!, route: UUID(), capability: token).isValid)
    for endpoint in ["http://catocut.com", "https://user:pass@catocut.com", "https://catocut.com:22", "https://catocut.com/path", "https://catocut.com?secret=x"] {
      #expect(!NotebookRelayRoute(endpoint: URL(string: endpoint)!, route: UUID(), capability: token).isValid)
    }
  }
}
