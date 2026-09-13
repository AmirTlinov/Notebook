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
    let conversation = CodexConversation(threadID: UUID().uuidString, revision: 1, title: "Task", ready: true, busy: true, activeTurnID: "3",
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
    #expect(receipt.preview(in: [first]) == first)
    receipt.dismissedThrough = first.id
    receipt = try JSONDecoder().decode(NotebookChatReadPosition.self, from: JSONEncoder().encode(receipt))
    #expect(receipt.preview(in: [first]) == nil)
    #expect(receipt.unread(in: [first]) == [first])
    #expect(receipt.preview(in: [first, second]) == second)
    #expect(receipt.unread(in: [first, second]) == [first, second])
    receipt.readThrough = second.id
    #expect(receipt.preview(in: [first, second]) == nil)
  }
  @Test func receiptsAndTheDraftRestoreWithinTheirComputerWithoutContentMutation() throws {
    try NotebookChatStoreTests().fixture { store, author in
      let computer = UUID(), thread = UUID().uuidString
      let panel = NotebookChatPanelState(threadID: thread, draft: "Still editable", sidecarID: computer,
        readPosition: .init(threadID: thread, readThrough: "one", dismissedThrough: "two"))
      try store.saveChatPanel(panel, author: author)
      #expect(try NotebookStore(root: store.root).chatPanel(author: author, computer: computer) == panel)
      #expect(try store.chatPanel(author: author, computer: UUID()).readPosition == nil)
      #expect(try store.recentChatJobs(author: author).isEmpty)
      var invalid = panel; invalid.readPosition = .init(threadID: UUID().uuidString)
      #expect(throws: (any Error).self) { try store.saveChatPanel(invalid, author: author) }
      invalid = panel; invalid.readPosition?.dismissedThrough = ""
      #expect(throws: (any Error).self) { try store.saveChatPanel(invalid, author: author) }
    }
  }
}
