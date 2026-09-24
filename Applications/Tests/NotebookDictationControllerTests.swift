import XCTest
import AVFoundation
import UIKit
import NotebookCore
@testable import Notebook

@MainActor final class TestDictationCapture: NotebookDictationCapture {
  var starts = 0, stops = 0, listens = 0
  var listening = false
  var startFrame: Int?
  var events: (@MainActor (NotebookDictationAudioEvent) -> Void)?
  var id: UUID?
  func listen(pcm: @escaping @Sendable (Data, NotebookAcousticUtterance.Sample) async -> Void,
    events: @escaping @MainActor (NotebookDictationAudioEvent) -> Void) async throws {
    listens += 1; listening = true; self.events = events; id = nil
  }
  func start(at url: URL, id: UUID, from frame: Int?, hasRequest: Bool?,
    events: @escaping @MainActor (NotebookDictationAudioEvent) -> Void) async throws {
    startFrame = frame; listening = false; self.id = id
    starts += 1; self.events = events
    try Data(repeating: 0x41, count: 200_000).write(to: url)
  }
  func emit() {
    var acoustic = NotebookAcousticUtterance()
    _ = acoustic.append(rms: 0.0001, frame: 0, count: 2400, rate: 24000)
    let sample = acoustic.append(rms: 0.004, frame: 2400, count: 2400, rate: 24000)
    events?(.reading(.init(id: id, elapsed: 1.2, audio: sample, levels: [sample.level])))
  }
  func end(_ reason: NotebookDictationEnd) { guard let id else { return }; events?(.finished(.init(id: id, frame: 4800, rate: 24000, reason: reason, recorded: true, error: nil))) }
  func stop() { stops += 1; end(.stopped) }
  func cancel() { events = nil; listening = false; id = nil }
}

@MainActor final class NotebookDictationControllerTests: XCTestCase {
  @MainActor final class Address: NotebookAddressRecognition {
    var started = false
    func start() { started = true }
    func stop() { started = false }
    func append(data: Data, audio: NotebookAcousticUtterance.Sample) {}
  }
  @MainActor final class SuspendedAddress: NotebookAddressRecognition {
    var continuation: CheckedContinuation<Void, Never>?
    var started = false
    func start() async {
      await withCheckedContinuation { continuation = $0 }
      started = true
    }
    func stop() { started = false }
    func append(data: Data, audio: NotebookAcousticUtterance.Sample) {}
  }
  func testAddressSendsAfterSilenceThroughTheSameOutboxWithoutTouchingTheDraftOrCalling() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    let dictation = fixture.chat.dictation, recognizer = Address()
    var activate: ((NotebookWakeActivation) -> Void)?
    dictation.authorizeAddress = { true }
    dictation.makeAddressRecognizer = { _, _, action, _ in activate = action; return recognizer }
    dictation.captureSubmission = { [weak fixture] in
      { recording, text in
        guard let fixture else { return false }
        return await fixture.chat.sendMessage(to: .thread(recording.thread), text: text, context: "frozen material", dictationID: recording.id)
      }
    }
    dictation.setForeground(true); try await wait { dictation.waiting }
    XCTAssertTrue(dictation.waiting); XCTAssertFalse(dictation.busy)
    XCTAssertTrue(fixture.capture.listening); XCTAssertTrue(recognizer.started)
    fixture.capture.emit(); XCTAssertGreaterThan(dictation.level, 0); XCTAssertFalse(dictation.levels.isEmpty)
    XCTAssertNil(dictation.pending); XCTAssertEqual(fixture.capture.starts, 0)
    XCTAssertTrue(fixture.queries.isEmpty); XCTAssertFalse(fixture.chat.voice.capturing)
    let late = try XCTUnwrap(activate); late(.init(frame: 1200, hasRequest: true))
    try await wait { dictation.recording }
    XCTAssertEqual(fixture.capture.startFrame, 1200); XCTAssertEqual(fixture.capture.starts, 1)
    fixture.result = "Hey GPT, объясни формулу?"
    let id = try XCTUnwrap(dictation.pending?.id)
    fixture.capture.emit(); XCTAssertEqual(dictation.elapsed, 1.2)
    fixture.capture.end(.pause)
    try await wait { dictation.waiting }
    XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    let job = try XCTUnwrap(fixture.store.chatJob(id))
    XCTAssertEqual(job.input.action, .send(threadID: fixture.thread, text: "объясни формулу?", context: "frozen material"))
    XCTAssertEqual(job.id, id); XCTAssertFalse(fixture.chat.voice.capturing)
    XCTAssertFalse(fixture.chat.expanded); XCTAssertNil(dictation.reviewRequest)
    late(.init(frame: 1200, hasRequest: true))
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(fixture.capture.starts, 1, "A late address cannot become a second recording")
    activate?(.init(frame: 2400, hasRequest: true))
    try await wait { dictation.recording }
    let secondID = try XCTUnwrap(dictation.pending?.id); XCTAssertNotEqual(secondID, id)
    fixture.capture.end(.pause)
    try await wait { dictation.waiting }
    XCTAssertNotNil(try fixture.store.chatJob(secondID))
    XCTAssertEqual(fixture.capture.starts, 2)
    XCTAssertEqual(try fixture.store.routedChatJobs(author: fixture.author, computer: fixture.peer).count, 2)
    dictation.setMicrophoneMuted(true)
    XCTAssertFalse(fixture.capture.listening); XCTAssertTrue(dictation.microphoneMuted)
    XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    await fixture.close()
  }
  func testRecoveredAddressAlreadyInTheOutboxDoesNotReinsertOrResubmitTheMessage() async throws {
    let fixture = try Fixture(transcript: "Объясни формулу", activated: true)
    let input = NotebookChatInput(id: fixture.id, author: fixture.author,
      action: .send(threadID: fixture.thread, text: "Объясни формулу", context: "original selection"))
    _ = try fixture.store.saveChatSubmission(input, to: fixture.peer)
    await fixture.start()
    fixture.chat.dictation.retry()
    try await wait { !fixture.chat.dictation.busy }
    XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    XCTAssertEqual(try fixture.store.routedChatJobs(author: fixture.author, computer: fixture.peer).count, 1)
    XCTAssertEqual(try fixture.store.chatJob(fixture.id)?.input, input)
    XCTAssertTrue(fixture.queries.isEmpty, "An already committed transcript needs no second upload")
    await fixture.close()
  }
  func testSwitchingTaskStopsWaitingAndCannotRedirectAPendingAddress() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    var activate: ((NotebookWakeActivation) -> Void)?
    fixture.chat.dictation.authorizeAddress = { true }
    fixture.chat.dictation.makeAddressRecognizer = { _, _, action, _ in activate = action; return Address() }
    fixture.chat.dictation.setForeground(true); try await wait { fixture.chat.dictation.waiting }
    let task = CodexTask(id: UUID().uuidString, title: "Другая задача", cwd: "/tmp")
    fixture.chat.select(task)
    activate?(.init(frame: 0, hasRequest: true))
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertTrue(fixture.capture.listening); XCTAssertEqual(fixture.capture.starts, 0)
    XCTAssertFalse(fixture.chat.dictation.microphoneMuted); XCTAssertEqual(fixture.submitCount, 0)
    await fixture.close()
  }
  func testDeniedRecognitionAndBackgroundLeaveNoMicrophoneOrRecording() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    fixture.chat.dictation.makeAddressRecognizer = { _, _, _, _ in Address() }
    fixture.chat.dictation.authorizeAddress = { false }
    fixture.chat.dictation.addressAuthorized = { false }
    fixture.chat.dictation.setForeground(true)
    fixture.chat.dictation.setMicrophoneMuted(false)
    try await wait { fixture.chat.dictation.error != nil }
    XCTAssertFalse(fixture.capture.listening)
    fixture.chat.dictation.authorizeAddress = { true }
    fixture.chat.dictation.addressAuthorized = { true }
    fixture.chat.dictation.setForeground(false); fixture.chat.dictation.setForeground(true)
    try await wait { fixture.chat.dictation.waiting }
    fixture.chat.dictation.setForeground(false)
    XCTAssertFalse(fixture.capture.listening); XCTAssertNil(fixture.chat.dictation.pending)
    XCTAssertEqual(fixture.submitCount, 0); XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    fixture.chat.dictation.setForeground(true); try await wait { fixture.chat.dictation.waiting }
    fixture.chat.dictation.setMicrophoneMuted(true)
    fixture.chat.dictation.setForeground(false); fixture.chat.dictation.setForeground(true)
    fixture.chat.disconnect(fixture.peer); await fixture.chat.connect(fixture.peer)
    XCTAssertTrue(fixture.chat.dictation.microphoneMuted); XCTAssertFalse(fixture.capture.listening)
    await fixture.close()
  }
  func testManualReviewAndCancellationReturnToWaitingWithoutChangingMicrophoneIntent() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    fixture.chat.dictation.makeAddressRecognizer = { _, _, _, _ in Address() }
    fixture.chat.dictation.authorizeAddress = { true }
    fixture.chat.dictation.setForeground(true); try await wait { fixture.chat.dictation.waiting }
    await fixture.chat.dictation.begin(); fixture.chat.dictation.cancel()
    try await wait { fixture.chat.dictation.waiting }
    await fixture.chat.dictation.begin(); fixture.chat.dictation.finish()
    try await wait { fixture.chat.dictation.waiting }
    XCTAssertEqual(fixture.chat.draft, "Вопрос: Точный текст диктовки.")
    XCTAssertEqual(fixture.submitCount, 0); XCTAssertFalse(fixture.chat.dictation.microphoneMuted)
    await fixture.close()
  }
  func testWaitingPreparationDoesNotOwnTheDraftAndLatePermissionCannotStartInBackground() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    let dictation = fixture.chat.dictation
    var permission: CheckedContinuation<Bool, Never>?
    dictation.makeAddressRecognizer = { _, _, _, _ in Address() }
    dictation.authorizeAddress = { await withCheckedContinuation { permission = $0 } }
    dictation.addressAuthorized = { false }
    dictation.setForeground(true); dictation.setMicrophoneMuted(false)
    try await wait { permission != nil }
    XCTAssertEqual(dictation.phase, .preparing); XCTAssertFalse(dictation.busy); XCTAssertFalse(dictation.showsInput)
    dictation.setForeground(false); permission?.resume(returning: true)
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertFalse(fixture.capture.listening); XCTAssertNil(dictation.pending)
    XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    dictation.authorizeAddress = { true }; dictation.addressAuthorized = { true }; dictation.setForeground(true)
    try await wait { dictation.waiting }
    await fixture.close()
  }
  func testOpeningAndReconnectingTextChatNeverRequestsMissingAudioPermissions() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    let dictation = fixture.chat.dictation
    var prompts = 0, recognizers = 0
    dictation.addressAuthorized = { false }
    dictation.authorizeAddress = { prompts += 1; return true }
    dictation.makeAddressRecognizer = { _, _, _, _ in recognizers += 1; return Address() }
    dictation.setForeground(true)
    fixture.chat.expanded = true
    fixture.chat.select(.init(id: UUID().uuidString, title: "Текстовый чат", cwd: "/tmp"))
    fixture.chat.disconnect(fixture.peer); await fixture.chat.connect(fixture.peer)
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(prompts, 0); XCTAssertEqual(recognizers, 0)
    XCTAssertFalse(fixture.capture.listening); XCTAssertEqual(fixture.capture.starts, 0)
    XCTAssertFalse(dictation.busy); XCTAssertFalse(dictation.showsInput); XCTAssertNil(dictation.notice)
    XCTAssertTrue(dictation.needsAddressAuthorization); XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    dictation.setMicrophoneMuted(false)
    try await wait { dictation.waiting }
    XCTAssertEqual(prompts, 1); XCTAssertEqual(recognizers, 1)
    XCTAssertTrue(fixture.capture.listening)
    await fixture.close()
  }
  func testFailedBackgroundRecognitionLeavesTextSubmissionAvailableWithoutRetrying() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    let dictation = fixture.chat.dictation
    var fail: ((String) -> Void)?, recognizers = 0
    dictation.makeAddressRecognizer = { _, _, _, failed in
      recognizers += 1; fail = failed; return Address()
    }
    dictation.setForeground(true); try await wait { dictation.waiting }
    fail?("Локальное распознавание недоступно")
    try await wait { dictation.notice != nil }
    XCTAssertFalse(dictation.busy); XCTAssertFalse(dictation.showsInput)
    XCTAssertFalse(fixture.capture.listening); XCTAssertNil(dictation.pending)
    XCTAssertEqual(dictation.notice, "Локальное распознавание недоступно")
    XCTAssertEqual(fixture.chat.draft, "Вопрос:")
    let submitted = await fixture.chat.sendMessage(to: .thread(fixture.thread), text: "Текст работает", context: "")
    XCTAssertTrue(submitted)
    XCTAssertEqual(try fixture.store.routedChatJobs(author: fixture.author, computer: fixture.peer).count, 1)
    // Admission is durable before the asynchronous outbox delivers to Mac.
    try await wait { fixture.submitCount == 1 }
    XCTAssertEqual(fixture.submitCount, 1)
    dictation.dismissNotice(); dictation.resumeActivation()
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertNil(dictation.notice); XCTAssertEqual(recognizers, 1)
    XCTAssertFalse(fixture.capture.listening); XCTAssertEqual(fixture.capture.starts, 0)
    await fixture.close()
  }
  func testManualDictationDoesNotRequireLocalAddressRecognitionOrRaceItsPreparation() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    let dictation = fixture.chat.dictation
    var prompts = 0, recognizers = 0
    dictation.addressAuthorized = { false }
    dictation.authorizeAddress = { prompts += 1; return false }
    dictation.makeAddressRecognizer = { _, _, _, _ in recognizers += 1; return Address() }
    dictation.setForeground(true)
    await dictation.begin()
    XCTAssertTrue(dictation.recording); XCTAssertEqual(fixture.capture.starts, 1)
    XCTAssertEqual(prompts, 0); XCTAssertEqual(recognizers, 0)
    dictation.cancel()
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertFalse(dictation.busy); XCTAssertFalse(fixture.capture.listening)
    XCTAssertEqual(prompts, 0); XCTAssertEqual(recognizers, 0)
    await fixture.close()
  }
  func testLateAddressStartCannotCancelANewerManualRecording() async throws {
    let fixture = try Fixture(fresh: true); await fixture.start()
    let dictation = fixture.chat.dictation, recognizer = SuspendedAddress()
    dictation.makeAddressRecognizer = { _, _, _, _ in recognizer }
    dictation.setForeground(true)
    try await wait { recognizer.continuation != nil }
    XCTAssertEqual(dictation.phase, .preparing)
    await dictation.begin()
    let recordingID = try XCTUnwrap(dictation.pending?.id)
    XCTAssertTrue(dictation.recording); XCTAssertEqual(fixture.capture.starts, 1)
    recognizer.continuation?.resume(); recognizer.continuation = nil
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(fixture.capture.listens, 0)
    XCTAssertEqual(fixture.capture.id, recordingID); XCTAssertTrue(dictation.recording)
    XCTAssertEqual(dictation.pending?.id, recordingID); XCTAssertFalse(recognizer.started)
    await fixture.close()
  }
  func testExplicitMicrophoneMuteSurvivesControllerRecreation() {
    let suite = "dictation-mute-" + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let first = NotebookDictationController(capture: TestDictationCapture(), preferences: preferences)
    first.setMicrophoneMuted(true); first.shutdown()
    let restored = NotebookDictationController(capture: TestDictationCapture(), preferences: preferences)
    XCTAssertTrue(restored.microphoneMuted)
    restored.setForeground(true); restored.resumeActivation()
    XCTAssertTrue(restored.microphoneMuted); XCTAssertFalse(restored.waiting)
    restored.setMicrophoneMuted(false); restored.shutdown()
    XCTAssertFalse(NotebookDictationController(capture: TestDictationCapture(), preferences: preferences).microphoneMuted)
  }
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
    init(transcript: String? = nil, alreadyInserted: Bool = false, fresh: Bool = false, activated: Bool = false) throws {
      activeID = id
      store = NotebookStore(root: root)
      _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
      try store.saveChatPanel(.init(threadID: thread, draft: alreadyInserted ? "Вопрос: " + result : "Вопрос:", sidecarID: peer,
        dictationReceipt: alreadyInserted ? id : nil), author: author)
      let directory = root.appendingPathComponent("runtime/dictation/" + author.uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if !fresh {
        let recording = NotebookDictationController.Pending(id: id, thread: thread, computer: peer, transcript: transcript, activation: activated ? .init(language: "ru-RU", address: "Слушай") : nil)
        try JSONEncoder().encode(recording).write(to: directory.appendingPathComponent("pending.json"))
        // Synthetic transport input: this test never records a person's microphone.
        try Data(repeating: 0x41, count: 200_000).write(to: directory.appendingPathComponent(id.uuidString + ".m4a"))
      }
      queue = NotebookPersistenceQueue(store: store)
      chat = NotebookChatController(persistence: queue, author: author, dictationCapture: capture, preferences: UserDefaults(suiteName: "dictation-tests-" + author.uuidString)!) { [weak self] packet, _ in
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
        case .job(let input): submitCount += 1; reply = .job(.init(input: input, state: .accepted, result: .turn(input.id.uuidString), revision: 2))
        case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
        case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
        case .history: reply = .history(.init(messages: [], nextCursor: nil))
        case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: .idle) })
        case .conversation: reply = .conversation(.init(threadID: thread, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Fixture", ready: true, busy: false,
          activeTurnID: nil, messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:]))
        default: reply = .failure("Unused fixture surface")
        }
        chat.receive(.init(id: packet.id, body: .reply(reply)), peerID: peer)
      }
      // Existing-grant state is explicit in controller contracts; tests never
      // inherit the host Simulator's microphone or Speech privacy decisions.
      chat.dictation.addressAuthorized = { true }
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
    let compact = NotebookCompanion.preferredSize(chat: fixture.chat, available: .init(width: 834, height: 1194))
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
    let sending = Task { await fixture.chat.sendMessage(to: .thread(fixture.thread), text: fixture.chat.draft, context: "") }
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
