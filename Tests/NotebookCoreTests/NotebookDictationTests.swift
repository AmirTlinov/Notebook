import Foundation
import Testing
@testable import NotebookCore

@Suite("Dictation preserves drafts and never submits a conversation turn")
struct NotebookDictationTests {
  @Test func insertionAndReceiptSurviveRestartWithoutDuplicateWords() throws {
    try NotebookChatStoreTests().fixture { store, author in
      let computer = UUID(), thread = UUID().uuidString, id = UUID()
      let file = CodexInputAttachment(kind: .file, name: "formula.swift", path: "/tmp/formula.swift")
      try store.saveChatPanel(.init(threadID: thread, draft: "Мой вопрос:", sidecarID: computer, attachments: [file]), author: author)
      let first = try store.insertChatDictation(" Объясни формулу. ", id: id, thread: thread, computer: computer, author: author)
      #expect(first.draft == "Мой вопрос: Объясни формулу."); #expect(first.attachments == [file])
      let reopened = NotebookStore(root: store.root)
      let second = try reopened.insertChatDictation("Объясни формулу.", id: id, thread: thread, computer: computer, author: author)
      #expect(first == second); #expect(second.dictationReceipt == id)
      #expect(try reopened.chatJob(id) == nil)
      #expect(throws: NotebookStorageError.self) {
        try reopened.insertChatDictation("Wrong destination", id: UUID(), thread: UUID().uuidString, computer: computer, author: author)
      }
      #expect(try reopened.chatPanel(author: author, computer: computer) == second)
    }
  }
  @Test func emptyAndOversizedTranscriptsCannotTruncateOrConsumeTheDraft() throws {
    try NotebookChatStoreTests().fixture { store, author in
      let computer = UUID(), thread = UUID().uuidString
      let draft = String(repeating: "я", count: 16_384)
      try store.saveChatPanel(.init(threadID: thread, draft: draft, sidecarID: computer), author: author)
      for text in [" ", "ещё"] {
        #expect(throws: NotebookStorageError.self) {
          try store.insertChatDictation(text, id: UUID(), thread: thread, computer: computer, author: author)
        }
      }
      let panel = try store.chatPanel(author: author, computer: computer)
      #expect(panel.draft == draft); #expect(panel.dictationReceipt == nil)
    }
  }
  @Test func existingNewlineAndEditedDraftArePreserved() throws {
    try NotebookChatStoreTests().fixture { store, author in
      let computer = UUID(), thread = UUID().uuidString
      try store.saveChatPanel(.init(threadID: thread, draft: "Исправленный вопрос:\n", sidecarID: computer), author: author)
      let panel = try store.insertChatDictation("Текст диктовки", id: UUID(), thread: thread, computer: computer, author: author)
      #expect(panel.draft == "Исправленный вопрос:\nТекст диктовки")
    }
  }
  @Test func transportRejectsOversizedChunksOffsetsAndInvalidResults() {
    let id = UUID(), peer = UUID()
    for query: NotebookDictationQuery in [
      .append(id: id, offset: -1, bytes: Data([1])),
      .append(id: id, offset: 0, bytes: Data()),
      .append(id: id, offset: 0, bytes: Data(repeating: 1, count: NotebookDictationRecording.chunkBytes + 1)),
      .append(id: id, offset: .max, bytes: Data([1]))] {
      #expect(!NotebookChatEnvelope(body: .request(.dictation(query))).isValid(from: peer))
    }
    #expect(NotebookChatEnvelope(body: .request(.dictation(.append(id: id, offset: 0, bytes: Data([1]))))).isValid(from: peer))
    #expect(!NotebookChatEnvelope(body: .reply(.dictation(.init(id: id, phase: .completed, text: "")))).isValid(from: peer))
  }
}
