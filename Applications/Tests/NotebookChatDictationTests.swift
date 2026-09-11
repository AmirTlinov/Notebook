import NotebookCore
import XCTest
@testable import Notebook

private actor DictationFixture: NotebookDictationInput {
  private var update: (@Sendable (NotebookDictationUpdate) async -> Void)?
  private var waiting: CheckedContinuation<Void, Never>?
  var running: Bool { waiting != nil }
  func run(locale: String, update: @escaping @Sendable (NotebookDictationUpdate) async -> Void) async throws {
    self.update = update
    await update(.listening)
    await withCheckedContinuation { waiting = $0 }
  }
  func emit(_ text: String) async { await update?(.text(text)) }
  func finish() async {
    await update?(.text("итог"))
    waiting?.resume(); waiting = nil
  }
}

@MainActor final class NotebookChatDictationTests: XCTestCase {
  private func wait(_ predicate: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(3)
    while !(await predicate()), .now < end { try await Task.sleep(for: .milliseconds(10)) }
    let value = await predicate(); XCTAssertTrue(value)
  }
  func testVoiceRefinesTheSameDraftAndFinishesWithoutSending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let author = UUID(), store = NotebookStore(root: root), voice = DictationFixture()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let chat = NotebookChatController(persistence: queue, author: author, dictationInput: voice) { _, _ in XCTFail("Dictation never sends a message") }
    await chat.start(); chat.draft = "Вопрос:"; chat.startDictation()
    try await wait { await voice.running }
    await voice.emit("один"); XCTAssertEqual(chat.draft, "Вопрос: один")
    await voice.emit("два"); XCTAssertEqual(chat.draft, "Вопрос: два", "A volatile result replaces its own voice span")
    chat.stopDictation()
    try await wait { chat.dictationStatus == nil }
    XCTAssertEqual(chat.draft, "Вопрос: итог", "Final words survive stopping the microphone")
    XCTAssertTrue(chat.jobs.isEmpty)
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
    XCTAssertEqual(try store.chatPanel(author: author).draft, "Вопрос: итог")
  }
  func testLaterTypingAndAnotherTaskCannotReceiveLateVoiceWords() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-switch-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let author = UUID(), store = NotebookStore(root: root), voice = DictationFixture()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let chat = NotebookChatController(persistence: queue, author: author, dictationInput: voice) { _, _ in XCTFail("Offline draft") }
    await chat.start(); chat.startDictation(); try await wait { await voice.running }
    await voice.emit("из голоса")
    chat.draft = "Я исправил вручную"
    try await wait { chat.dictationStatus == nil }
    XCTAssertEqual(chat.draft, "Я исправил вручную")
    chat.startDictation(); try await wait { await voice.running }
    chat.select(.init(id: UUID().uuidString, title: "Другой чат", cwd: "/tmp"))
    try await wait { chat.dictationStatus == nil }
    XCTAssertEqual(chat.draft, "Я исправил вручную", "Task selection rejects the old microphone's final callback")
    XCTAssertTrue(chat.jobs.isEmpty)
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }
}
