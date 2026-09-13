import XCTest
import AVFoundation
import NotebookCore
@testable import Notebook

@MainActor final class TestDictationCapture: NotebookDictationCapture {
  var starts = 0, stops = 0
  var finished: (@MainActor (Bool) -> Void)?
  func start(at url: URL, finished: @escaping @MainActor (Bool) -> Void) async throws {
    starts += 1; self.finished = finished
    try Data(repeating: 0x41, count: 200_000).write(to: url)
  }
  func sample() -> (elapsed: TimeInterval, level: Double) { (1.2, 0.5) }
  func stop() { stops += 1; let callback = finished; finished = nil; callback?(true) }
  func cancel() { finished = nil }
}

@MainActor final class NotebookDictationControllerTests: XCTestCase {
  @MainActor final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-" + UUID().uuidString)
    let author = UUID(), peer = UUID(), id = UUID(), thread = UUID().uuidString
    var chat: NotebookChatController!
    var queue: NotebookPersistenceQueue!
    var store: NotebookStore!
    var queries: [NotebookDictationQuery] = []
    var hold = false
    var submitCount = 0
    var result = "Точный текст диктовки."
    var receivedBytes = 0
    var complete = false
    var recognitionFails = false
    var activeID: UUID
    let capture = TestDictationCapture()
    init(transcript: String? = nil, alreadyInserted: Bool = false, fresh: Bool = false) throws {
      activeID = id
      store = NotebookStore(root: root)
      _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
      try store.saveChatPanel(.init(threadID: thread, draft: alreadyInserted ? "Вопрос: " + result : "Вопрос:", sidecarID: peer,
        dictationReceipt: alreadyInserted ? id : nil), author: author)
      let directory = root.appendingPathComponent("runtime/dictation/" + author.uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if !fresh {
        let recording = NotebookDictationController.Pending(id: id, thread: thread, computer: peer, transcript: transcript)
        try JSONEncoder().encode(recording).write(to: directory.appendingPathComponent("pending.json"))
        // Synthetic transport input: this test never records a person's microphone.
        try Data(repeating: 0x41, count: 200_000).write(to: directory.appendingPathComponent(id.uuidString + ".m4a"))
      }
      queue = NotebookPersistenceQueue(store: store)
      chat = NotebookChatController(persistence: queue, author: author, dictationCapture: capture) { [weak self] packet, _ in
        guard let self, case .request(let query) = packet.body else { return }
        let reply: NotebookChatReply
        switch query {
        case .dictation(let action):
          queries.append(action)
          let state: NotebookDictationState
          switch action {
          case .prepare(let recording): activeID = recording.id; state = .init(id: activeID, receivedBytes: receivedBytes)
          case .append(_, let offset, let bytes): receivedBytes = offset + bytes.count; state = .init(id: activeID, receivedBytes: receivedBytes)
          case .finish, .retry: state = .init(id: activeID, phase: .transcribing, receivedBytes: receivedBytes)
          case .status:
            complete = !hold
            state = recognitionFails ? .init(id: activeID, phase: .failed, receivedBytes: receivedBytes, error: "Попробуйте снова.")
              : .init(id: activeID, phase: hold ? .transcribing : .completed, receivedBytes: receivedBytes, text: hold ? nil : result)
          case .cancel(let cancelled): state = .init(id: cancelled, phase: .cancelled)
          }
          reply = .dictation(state)
        case .job: submitCount += 1; reply = .failure("A transcription cannot submit a turn")
        case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
        case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
        case .history: reply = .history(.init(messages: [], nextCursor: nil))
        case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: .idle) })
        case .conversation: reply = .conversation(.init(threadID: thread, revision: 1, title: "Fixture", ready: true, busy: false,
          activeTurnID: nil, messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:]))
        default: reply = .failure("Unused fixture surface")
        }
        chat.receive(.init(id: packet.id, body: .reply(reply)), peerID: peer)
      }
    }
    func start() async { await chat.start(); await chat.connect(peer) }
    func close() async { await chat.stop(); _ = await queue.flush(); try? FileManager.default.removeItem(at: root) }
  }
  func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(8)
    while !condition(), .now < end { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition())
  }
  func testStopOpensTheChatThenRequestsEditingAfterTheDurableTranscript() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    await fixture.chat.dictation.begin()
    XCTAssertTrue(fixture.chat.dictation.recording)
    let compact = NotebookCompanion.preferredSize(chat: fixture.chat, available: .init(width: 834, height: 1194), showsTask: false)
    XCTAssertEqual(compact, .init(width: 352, height: 48))
    fixture.chat.dictation.finish()
    XCTAssertTrue(fixture.chat.expanded); XCTAssertNil(fixture.chat.dictation.reviewRequest)
    try await wait { !fixture.chat.dictation.busy }
    XCTAssertNotNil(fixture.chat.dictation.reviewRequest)
    XCTAssertEqual(fixture.chat.draft, "Вопрос: Точный текст диктовки.")
    XCTAssertEqual(fixture.capture.stops, 1); XCTAssertEqual(fixture.submitCount, 0)
    fixture.chat.draft += " Исправлено."
    _ = await fixture.queue.flush()
    XCTAssertEqual(try fixture.store.chatPanel(author: fixture.author, computer: fixture.peer).draft, fixture.chat.draft)
    await fixture.close()
  }
  func testSendDecisionRunsOnceOnlyAfterDurableInsertionAndDoubleTapCannotReplaceIt() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    await fixture.chat.dictation.begin()
    var sends = 0
    fixture.chat.dictation.finish {
      sends += 1
      XCTAssertFalse(fixture.chat.dictation.busy)
      XCTAssertEqual(fixture.chat.draft, "Вопрос: Точный текст диктовки.")
      XCTAssertEqual(try? fixture.store.chatPanel(author: fixture.author, computer: fixture.peer).dictationReceipt, fixture.activeID)
    }
    fixture.chat.dictation.finish { sends += 10 }
    try await wait { !fixture.chat.dictation.busy }
    XCTAssertEqual(sends, 1); XCTAssertEqual(fixture.capture.stops, 1)
    XCTAssertFalse(fixture.chat.expanded); XCTAssertNil(fixture.chat.dictation.reviewRequest)
    await fixture.close()
  }
  func testFailedSendDecisionIsDiscardedAndRetryOnlyOpensTheDraft() async throws {
    let fixture = try Fixture(fresh: true); fixture.recognitionFails = true; await fixture.start()
    await fixture.chat.dictation.begin()
    var sends = 0; fixture.chat.dictation.finish { sends += 1 }
    try await wait { fixture.chat.dictation.canRetry }
    XCTAssertTrue(fixture.chat.expanded); XCTAssertEqual(sends, 0)
    fixture.recognitionFails = false; fixture.chat.dictation.retry()
    try await wait { !fixture.chat.dictation.busy }
    XCTAssertEqual(sends, 0); XCTAssertNotNil(fixture.chat.dictation.reviewRequest)
    XCTAssertEqual(fixture.chat.draft, "Вопрос: Точный текст диктовки.")
    await fixture.close()
  }
  func testCancelWhileFinishingCannotSendLateSpeechAndTheNextCaptureStartsClean() async throws {
    let fixture = try Fixture(fresh: true); fixture.hold = true; await fixture.start()
    await fixture.chat.dictation.begin()
    var sends = 0; fixture.chat.dictation.finish { sends += 1 }
    try await wait { fixture.queries.contains(.status(fixture.activeID)) }
    fixture.chat.dictation.cancel(); fixture.hold = false
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(sends, 0); XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    fixture.receivedBytes = 0; await fixture.chat.dictation.begin(); fixture.chat.dictation.finish()
    try await wait { !fixture.chat.dictation.busy }
    XCTAssertEqual(sends, 0); XCTAssertNotNil(fixture.chat.dictation.reviewRequest)
    await fixture.close()
  }
  func testAutomaticCaptureLimitOpensReviewAndSubmissionPreparationDoesNotRecord() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    fixture.chat.dictation.submissionInProgress = { true }
    await fixture.chat.dictation.begin()
    XCTAssertEqual(fixture.capture.starts, 0); XCTAssertFalse(fixture.chat.dictation.busy)
    fixture.chat.dictation.submissionInProgress = { false }
    await fixture.chat.dictation.begin(); fixture.capture.stop()
    try await wait { !fixture.chat.dictation.busy }
    XCTAssertTrue(fixture.chat.expanded); XCTAssertNotNil(fixture.chat.dictation.reviewRequest)
    XCTAssertEqual(fixture.submitCount, 0)
    await fixture.close()
  }
  func testRestartDuringRecognitionRecoversOnlyAReviewableDraftWithoutTheSendDecision() async throws {
    let fixture = try Fixture(fresh: true); fixture.hold = true; await fixture.start()
    await fixture.chat.dictation.begin()
    var sends = 0; fixture.chat.dictation.finish { sends += 1 }
    try await wait { fixture.queries.contains(.status(fixture.activeID)) }
    fixture.chat.dictation.shutdown(); fixture.hold = false
    let recovered = NotebookDictationController()
    recovered.chat = fixture.chat
    try recovered.restore(directory: fixture.root.appendingPathComponent("runtime/dictation/" + fixture.author.uuidString), inserted: nil)
    XCTAssertTrue(recovered.canRetry); recovered.retry()
    try await wait { !recovered.busy }
    XCTAssertEqual(sends, 0); XCTAssertNotNil(recovered.reviewRequest)
    XCTAssertEqual(fixture.chat.draft, "Вопрос: Точный текст диктовки.")
    recovered.shutdown(); await fixture.close()
  }
  func testRecoveredRecordingUploadsBoundedChunksAndInsertsExactlyOnceWithoutSending() async throws {
    let fixture = try Fixture(), microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    await fixture.start()
    XCTAssertTrue(fixture.chat.dictation.canRetry)
    fixture.chat.dictation.retry()
    try await wait { !fixture.chat.dictation.busy }
    XCTAssertEqual(fixture.chat.draft, "Вопрос: Точный текст диктовки.")
    XCTAssertEqual(fixture.chat.dictationReceipt, fixture.id); XCTAssertEqual(fixture.submitCount, 0)
    XCTAssertEqual(fixture.receivedBytes, 200_000)
    let chunks = fixture.queries.compactMap { if case .append(_, _, let bytes) = $0 { bytes.count } else { nil } }
    XCTAssertEqual(chunks, [98_304, 98_304, 3_392])
    XCTAssertEqual(AVCaptureDevice.authorizationStatus(for: .audio), microphone)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("runtime/dictation/" + fixture.author.uuidString + "/pending.json").path))
    await fixture.close()
  }
  func testCrashAfterInsertionOnlyRemovesRecordingAndNeverReinsertsOrUploads() async throws {
    let fixture = try Fixture(transcript: "Точный текст диктовки.", alreadyInserted: true)
    await fixture.start()
    XCTAssertFalse(fixture.chat.dictation.busy); XCTAssertEqual(fixture.chat.draft, "Вопрос: Точный текст диктовки.")
    XCTAssertTrue(fixture.queries.isEmpty); XCTAssertEqual(fixture.submitCount, 0)
    await fixture.close()
  }
  func testCancelDuringRecognitionKeepsDraftAndRejectsLateText() async throws {
    let fixture = try Fixture(); fixture.hold = true; await fixture.start()
    fixture.chat.dictation.retry()
    try await wait { fixture.queries.contains(.status(fixture.id)) }
    fixture.chat.dictation.cancel(); fixture.hold = false
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(fixture.chat.draft, "Вопрос:"); XCTAssertNil(fixture.chat.dictationReceipt)
    XCTAssertFalse(fixture.chat.dictation.busy); XCTAssertEqual(fixture.submitCount, 0)
    await fixture.close()
  }
  func testRecoveredResultCanUseEditedDraftAndCannotSwitchTaskOrStartVoice() async throws {
    let fixture = try Fixture(transcript: "Точный текст диктовки."); await fixture.start()
    fixture.chat.draft = "Исправленный вопрос:\n"
    fixture.chat.select(.init(id: UUID().uuidString, title: "Another", cwd: "/tmp"))
    XCTAssertEqual(fixture.chat.threadID, fixture.thread)
    let host = UIView(); fixture.chat.voice.host = host
    await fixture.chat.voice.begin(); XCTAssertFalse(fixture.chat.voice.capturing)
    XCTAssertTrue(fixture.chat.voice.error?.contains("диктовку") == true)
    fixture.chat.dictation.retry(); try await wait { !fixture.chat.dictation.busy }
    XCTAssertEqual(fixture.chat.draft, "Исправленный вопрос:\nТочный текст диктовки.")
    XCTAssertTrue(fixture.queries.isEmpty); XCTAssertEqual(fixture.submitCount, 0)
    await fixture.close()
  }
  func testPanelPersistenceDuringDurableInsertionCannotOverwriteRecognizedWords() async throws {
    let fixture = try Fixture(transcript: "Точный текст диктовки."); await fixture.start()
    _ = await fixture.queue.flush()
    let gate = DispatchSemaphore(value: 0)
    fixture.queue.enqueue(publishesChanges: false) { _ in gate.wait(); return false }
    let insertion = Task { try await fixture.chat.insertDictation(fixture.result, id: fixture.id,
      thread: fixture.thread, computer: fixture.peer) }
    try await wait { fixture.queue.pendingCount >= 2 }
    // Attachment/read-state updates use the same panel writer even while its
    // draft editor is disabled. A stale snapshot must not follow the insertion.
    fixture.chat.removeAttachment("already-removed")
    gate.signal()
    try await insertion.value
    _ = await fixture.queue.flush()
    let author = fixture.author, peer = fixture.peer
    let stored = try await fixture.queue.submit { try $0.chatPanel(author: author, computer: peer) }
    XCTAssertEqual(stored.draft, "Вопрос: Точный текст диктовки.")
    XCTAssertEqual(stored.dictationReceipt, fixture.id)
    await fixture.close()
  }
  func testPendingSubmissionCannotStartRecordingOverTheDraftBeingSent() async throws {
    let fixture = try Fixture(alreadyInserted: true); await fixture.start()
    _ = await fixture.queue.flush()
    let permission = AVCaptureDevice.authorizationStatus(for: .audio), gate = DispatchSemaphore(value: 0)
    fixture.queue.enqueue(publishesChanges: false) { _ in gate.wait(); return false }
    let sending = Task { await fixture.chat.sendMessage(threadID: fixture.thread, text: fixture.chat.draft, context: "") }
    try await wait { fixture.chat.saving }
    await fixture.chat.dictation.begin()
    XCTAssertFalse(fixture.chat.dictation.busy)
    XCTAssertTrue(fixture.chat.dictation.error?.contains("сохранения") == true)
    XCTAssertEqual(AVCaptureDevice.authorizationStatus(for: .audio), permission)
    gate.signal(); _ = await sending.value
    await fixture.close()
  }
  func testOfflineCancelSurvivesRestartAndReleasesTheMacBeforeAnotherRecording() async throws {
    let fixture = try Fixture(); fixture.hold = true; await fixture.start()
    fixture.chat.dictation.retry(); try await wait { fixture.queries.contains(.status(fixture.id)) }
    fixture.chat.disconnect(fixture.peer); fixture.chat.dictation.cancel()
    let directory = fixture.root.appendingPathComponent("runtime/dictation/" + fixture.author.uuidString)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fixture.id.uuidString + ".m4a").path))
    let recovered = NotebookDictationController(); recovered.chat = fixture.chat
    try recovered.restore(directory: directory, inserted: nil)
    XCTAssertFalse(recovered.busy)
    await fixture.chat.connect(fixture.peer)
    try await recovered.finishCancellation(on: fixture.peer)
    XCTAssertEqual(fixture.queries.filter { $0 == .cancel(fixture.id) }.count, 1)
    let cancellations = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: directory.appendingPathComponent("cancelled.json")))
    XCTAssertTrue(cancellations.isEmpty); XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    XCTAssertEqual(fixture.submitCount, 0); recovered.shutdown(); await fixture.close()
  }
  func testRestartBetweenSavedCancelAndAudioDeletionCannotRecoverOrRecognizeTheCancelledRecording() async throws {
    let fixture = try Fixture()
    let directory = fixture.root.appendingPathComponent("runtime/dictation/" + fixture.author.uuidString)
    try JSONEncoder().encode([fixture.peer.uuidString: fixture.id]).write(to: directory.appendingPathComponent("cancelled.json"))
    await fixture.start()
    XCTAssertFalse(fixture.chat.dictation.busy)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fixture.id.uuidString + ".m4a").path))
    XCTAssertTrue(fixture.queries.isEmpty); XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    await fixture.close()
  }
}
