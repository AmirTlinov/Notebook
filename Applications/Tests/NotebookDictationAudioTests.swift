import AVFoundation
import XCTest
@testable import Notebook

@MainActor final class NotebookDictationAudioTests: XCTestCase {
  func testAddressedRequestEndsOnAudioSilenceButANameAloneWaitsForTheNextPhrase() {
    var request = NotebookDictationUtterance(hasRequest: true)
    XCTAssertNil(request.sample(elapsed: 3, level: 0))
    XCTAssertNil(request.sample(elapsed: 3.9, level: 0))
    XCTAssertNil(request.sample(elapsed: 3.9, level: 0), "No new audio is not silence")
    XCTAssertNil(request.sample(elapsed: 4, level: 0.5), "A short pause within speech does not send")
    XCTAssertNil(request.sample(elapsed: 5, level: 0))
    XCTAssertEqual(request.sample(elapsed: 5.5, level: 0), .send)
    var name = NotebookDictationUtterance(hasRequest: false)
    XCTAssertNil(name.sample(elapsed: 2, level: 0))
    XCTAssertNil(name.sample(elapsed: 5, level: 0), "GPT alone is not a request")
    XCTAssertNil(name.sample(elapsed: 5.3, level: 0.6))
    XCTAssertNil(name.sample(elapsed: 6.3, level: 0))
    XCTAssertEqual(name.sample(elapsed: 6.9, level: 0), .send)
    var abandoned = NotebookDictationUtterance(hasRequest: false)
    XCTAssertNil(abandoned.sample(elapsed: 1, level: 0))
    XCTAssertEqual(abandoned.sample(elapsed: 13, level: 0), .abandon)
    var delayed = NotebookDictationUtterance(hasRequest: true, silence: 0.9)
    XCTAssertNil(delayed.sample(elapsed: 4, level: 0))
    XCTAssertEqual(delayed.sample(elapsed: 4.6, level: 0), .send, "The pause observed before ASR admission is not waited a second time")
    var quiet = NotebookDictationUtterance(hasRequest: false)
    XCTAssertNil(quiet.sample(elapsed: 0, level: 0))
    XCTAssertNil(quiet.sample(elapsed: 0.3, level: 0.12))
    XCTAssertEqual(quiet.sample(elapsed: 1.8, level: 0), .send, "Quiet iPad speech following a name is still a request")
  }
  private func pcm(frame: Int, amplitude: Float = 0.1) -> NotebookDictationPCM {
    let values = (0..<6000).map { amplitude * sin(Float($0) * 2 * .pi / 60) }
    return .init(data: values.withUnsafeBytes { Data($0) }, frame: frame, rate: 24_000)
  }
  func testWaitingWritesNothingAndActivationCutsAllEarlierAudioWithoutRestartingTheStream() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wake-audio-\(UUID()).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    let storage = NotebookDictationAudioStorage()
    _ = try await storage.append(pcm(frame: 0, amplitude: 0.9))
    _ = try await storage.append(pcm(frame: 6000))
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    try await storage.begin(at: url, from: 6000)
    let next = try await storage.append(pcm(frame: 12000))
    XCTAssertEqual(next.0, 0.5, accuracy: 0.001)
    let closed = await storage.close(); XCTAssertTrue(closed)
    let file = try AVAudioFile(forReading: url)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
    XCTAssertLessThan(rms, 0.15, "The loud surrounding conversation before the address must not reach the AAC file")
    XCTAssertGreaterThan(rms, 0.04, "The utterance following GPT must remain audible")
  }
  func testExpiredAddressAndDiscontinuousMicrophoneCannotWriteAnUnrelatedRecording() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wake-expired-\(UUID()).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    let storage = NotebookDictationAudioStorage()
    for index in 0..<48 { _ = try await storage.append(pcm(frame: index * 6000)) }
    do { try await storage.begin(at: url, from: 0); XCTFail("An expired address must not admit the current tail") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    do { _ = try await storage.append(pcm(frame: 300_000)); XCTFail("Missing PCM is an interruption, not a shorter recording") } catch {}
    let closed = await storage.close(); XCTAssertFalse(closed)
  }
  func testDirectButtonRecordingUsesTheSameAACWriterAndClosedInputCannotResume() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-audio-\(UUID()).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    let storage = NotebookDictationAudioStorage()
    try await storage.begin(at: url, from: nil)
    _ = try await storage.append(pcm(frame: 0))
    let closed = await storage.close(); XCTAssertTrue(closed)
    let file = try AVAudioFile(forReading: url)
    XCTAssertGreaterThan(file.length, 0)
    do { _ = try await storage.append(pcm(frame: 6000)); XCTFail("Closed microphone input cannot resume") } catch {}
  }
}
