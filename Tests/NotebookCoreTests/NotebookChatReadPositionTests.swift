import Foundation
import Testing
@testable import NotebookCore

@Suite("Collapsed replies are presentation receipts, not a second conversation")
struct NotebookChatReadPositionTests {
  @Test func onlyUsefulCompletedRepliesCountAsUnread() throws {
    let messages: [CodexMessage] = [
      .init(id: "user", turnID: "1", clientID: nil, role: .user, text: "Question"),
      .init(id: "commentary", turnID: "1", clientID: nil, role: .assistant, text: "Working", phase: "commentary"),
      .init(id: "tool", turnID: "1", clientID: nil, role: .assistant, text: "Reading", activity: .init(kind: .tool, status: "completed")),
      .init(id: "first", turnID: "1", clientID: nil, role: .assistant, text: "Answer", phase: "final_answer"),
      .init(id: "second", turnID: "2", clientID: nil, role: .assistant, text: "Another answer", phase: "final_answer"),
      .init(id: "partial", turnID: "3", clientID: nil, role: .assistant, text: "Unfinished", phase: "final_answer")]
    let conversation = CodexConversation(threadID: UUID().uuidString, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Task", ready: true, busy: true, activeTurnID: "3",
      messages: messages, requests: [], acceptedMessages: [:], turnStatuses: ["1":"completed", "2":"completed", "3":"inProgress"])
    let replies = NotebookChatReadPosition.replies(in: messages, conversation: conversation)
    #expect(replies.map(\.id) == ["first", "second"])
    let receipt = NotebookChatReadPosition(threadID: conversation.threadID, readThrough: "first")
    #expect(receipt.unread(in: replies).map(\.id) == ["second"])
    #expect(CodexMessage.transportPage(messages).last?.phase == "final_answer")
    #expect(try JSONDecoder().decode(CodexMessage.self, from: JSONEncoder().encode(messages[3])).phase == "final_answer")
  }
  @Test func dismissingPreviewKeepsUnreadMessagesAndTheNextAnswerAppears() throws {
    let first = CodexMessage(id: "one", turnID: "1", clientID: nil, role: .assistant, text: "First answer", phase: "final_answer")
    let second = CodexMessage(id: "two", turnID: "2", clientID: nil, role: .assistant, text: "Next answer", phase: "final_answer")
    var receipt = NotebookChatReadPosition(threadID: UUID().uuidString)
    let now = Date(); receipt.present(in: [first], at: now)
    #expect(receipt.previews(in: [first], at: now).last == first)
    receipt.dismiss(first.id, at: now)
    receipt = try JSONDecoder().decode(NotebookChatReadPosition.self, from: JSONEncoder().encode(receipt))
    #expect(receipt.previews(in: [first], at: now).last == nil)
    #expect(receipt.unread(in: [first]) == [first])
    receipt.present(in: [first, second], at: now)
    #expect(receipt.previews(in: [first, second], at: now).last == second)
    #expect(receipt.unread(in: [first, second]) == [first, second])
    receipt.readThrough = second.id
    #expect(receipt.previews(in: [first, second], at: now).last == nil)
  }
  @Test func previewsExpireIndependentlyWithoutChangingUnreadOrRestartingOnRepeatedEvents() throws {
    let replies = (1...3).map { CodexMessage(id: "reply-\($0)", turnID: "\($0)", clientID: nil, role: .assistant, text: "Answer", phase: "final_answer") }
    var receipt = NotebookChatReadPosition(threadID: "task")
    let now = Date(timeIntervalSince1970: 1_000)
    receipt.present(in: replies, at: now)
    #expect(receipt.previews(in: replies, at: now).map(\.id) == ["reply-2", "reply-3"])
    receipt.dismiss("reply-2", at: now.addingTimeInterval(1))
    receipt.present(in: replies, at: now.addingTimeInterval(10))
    #expect(receipt.previews(in: replies, at: now.addingTimeInterval(11)).map(\.id) == ["reply-3"])
    receipt = try JSONDecoder().decode(NotebookChatReadPosition.self, from: JSONEncoder().encode(receipt))
    #expect(receipt.previews(in: replies, at: now.addingTimeInterval(13)).isEmpty)
    #expect(receipt.unread(in: replies) == replies)
    let old = Data(#"{"threadID":"task","dismissedThrough":"reply-3"}"#.utf8)
    var migrated = try JSONDecoder().decode(NotebookChatReadPosition.self, from: old)
    migrated.present(in: replies, at: now)
    #expect(!migrated.previews(in: replies, at: now).contains(replies[2]))
    #expect(!String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self).contains("dismissedThrough"))
  }
  @Test func receiptsAndTheDraftRestoreWithinTheirComputerWithoutContentMutation() throws {
    try NotebookChatStoreTests().fixture { store, author in
      let computer = UUID(), thread = UUID().uuidString
      let panel = NotebookChatPanelState(threadID: thread, draft: "Still editable", sidecarID: computer,
        readPosition: .init(threadID: thread, readThrough: "one", previewEndsAt: ["two": .distantPast]))
      try store.saveChatPanel(panel, author: author)
      #expect(try NotebookStore(root: store.root).chatPanel(author: author, computer: computer) == panel)
      #expect(try store.chatPanel(author: author, computer: UUID()).readPosition == nil)
      #expect(try store.recentChatJobs(author: author).isEmpty)
      var invalid = panel; invalid.readPosition = .init(threadID: UUID().uuidString)
      #expect(throws: (any Error).self) { try store.saveChatPanel(invalid, author: author) }
      invalid = panel; invalid.readPosition?.previewEndsAt[""] = .now
      #expect(throws: (any Error).self) { try store.saveChatPanel(invalid, author: author) }
    }
  }
}
