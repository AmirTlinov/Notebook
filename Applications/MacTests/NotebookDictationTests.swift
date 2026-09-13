import XCTest
import CryptoKit
import NotebookCore
import NotebookCodex
@testable import Notebook

@MainActor final class NotebookDictationTests: XCTestCase {
  actor Transcriber: NotebookCodexDictationOwner {
    var calls = 0
    var shouldFail = false
    var hold = false
    func fail(_ value: Bool) { shouldFail = value }
    func suspend(_ value: Bool) { hold = value }
    func transcribeDictation(_ audio: Data) async throws -> String {
      calls += 1
      while hold { try await Task.sleep(for: .milliseconds(20)) }
      if shouldFail { throw NSError(domain: "Synthetic transcription failure", code: 1) }
      return "Точный текст диктовки."
    }
  }
  func metadata(_ audio: Data, computer: UUID) -> NotebookDictationRecording {
    .init(id: UUID(), threadID: UUID().uuidString, computerID: computer, byteCount: audio.count,
      sha256: SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined())
  }
  func settled(_ owner: MacNotebookDictation, id: UUID, peer: UUID) async throws -> NotebookDictationState {
    let end = ContinuousClock.now + .seconds(3)
    while .now < end {
      let value = try owner.receive(.status(id), peer: peer)
      if value.phase != .transcribing { return value }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw CodexBridgeError.timeout
  }
  func testChunkReplayLostFinishReceiptAndForeignDeviceCannotDuplicateOrStealTranscription() async throws {
    let computer = UUID(), peer = UUID(), transcriber = Transcriber(), bytes = Data("recorded audio".utf8)
    let owner = MacNotebookDictation(executor: transcriber, computer: computer), meta = metadata(bytes, computer: computer)
    _ = try owner.receive(.prepare(meta), peer: peer)
    XCTAssertThrowsError(try owner.receive(.finish(meta.id), peer: peer))
    let chunk = NotebookDictationQuery.append(id: meta.id, offset: 0, bytes: bytes)
    XCTAssertEqual(try owner.receive(chunk, peer: peer).receivedBytes, bytes.count)
    XCTAssertEqual(try owner.receive(chunk, peer: peer).receivedBytes, bytes.count)
    XCTAssertThrowsError(try owner.receive(.append(id: meta.id, offset: 0, bytes: Data([0])), peer: peer))
    for query: NotebookDictationQuery in [.status(meta.id), .finish(meta.id), .cancel(meta.id), .prepare(meta)] {
      XCTAssertThrowsError(try owner.receive(query, peer: UUID()))
    }
    _ = try owner.receive(.finish(meta.id), peer: peer)
    _ = try owner.receive(.finish(meta.id), peer: peer)
    let result = try await settled(owner, id: meta.id, peer: peer)
    XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.text, "Точный текст диктовки.")
    XCTAssertEqual(try owner.receive(.prepare(meta), peer: peer), result)
    let calls = await transcriber.calls; XCTAssertEqual(calls, 1)
    owner.stop()
  }
  func testFailedAudioIsRetainedAndOnlyExplicitRetryStartsAnotherRecognition() async throws {
    let computer = UUID(), peer = UUID(), transcriber = Transcriber(), bytes = Data([1, 2, 3])
    let owner = MacNotebookDictation(executor: transcriber, computer: computer), meta = metadata(bytes, computer: computer)
    await transcriber.fail(true)
    _ = try owner.receive(.prepare(meta), peer: peer)
    _ = try owner.receive(.append(id: meta.id, offset: 0, bytes: bytes), peer: peer)
    _ = try owner.receive(.finish(meta.id), peer: peer)
    let failed = try await settled(owner, id: meta.id, peer: peer); XCTAssertEqual(failed.phase, .failed)
    _ = try owner.receive(.finish(meta.id), peer: peer)
    var calls = await transcriber.calls; XCTAssertEqual(calls, 1)
    await transcriber.fail(false); _ = try owner.receive(.retry(meta.id), peer: peer)
    let result = try await settled(owner, id: meta.id, peer: peer); XCTAssertEqual(result.phase, .completed)
    calls = await transcriber.calls; XCTAssertEqual(calls, 2); owner.stop()
  }
  func testCancelCannotPublishLateTextAndNewCaptureCannotReplaceRunningAudio() async throws {
    let computer = UUID(), peer = UUID(), transcriber = Transcriber(), bytes = Data([1])
    let owner = MacNotebookDictation(executor: transcriber, computer: computer), meta = metadata(bytes, computer: computer)
    await transcriber.suspend(true)
    _ = try owner.receive(.prepare(meta), peer: peer)
    _ = try owner.receive(.append(id: meta.id, offset: 0, bytes: bytes), peer: peer)
    _ = try owner.receive(.finish(meta.id), peer: peer)
    XCTAssertThrowsError(try owner.receive(.prepare(metadata(bytes, computer: computer)), peer: peer))
    _ = try owner.receive(.cancel(meta.id), peer: peer)
    await transcriber.suspend(false); try await Task.sleep(for: .milliseconds(40))
    let value = try owner.receive(.status(meta.id), peer: peer)
    XCTAssertEqual(value.phase, .cancelled); XCTAssertNil(value.text)
    let next = metadata(bytes, computer: computer)
    XCTAssertEqual(try owner.receive(.prepare(next), peer: peer).phase, .uploading)
    owner.stop()
  }
}
