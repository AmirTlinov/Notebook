import AVFoundation
import XCTest
@testable import Notebook

@MainActor final class NotebookDictationAudioTests: XCTestCase {
  func testPCMDownmixPreservesInterleavedAndPlanarChannelsAndRejectsOtherFormats() throws {
    for interleaved in [false, true] {
      let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
      buffer.frameLength = 8
      let channels = try XCTUnwrap(buffer.floatChannelData)
      for frame in 0..<8 {
        if interleaved { channels[0][frame * buffer.stride] = 0.2; channels[0][frame * buffer.stride + 1] = 0.6 }
        else { channels[0][frame * buffer.stride] = 0.2; channels[1][frame * buffer.stride] = 0.6 }
      }
      let pcm = try NotebookDictationPCM.copy(buffer, frame: 192)
      XCTAssertEqual(pcm.frame, 192); XCTAssertEqual(pcm.rate, 48_000); XCTAssertEqual(pcm.data.count, 32)
      pcm.data.withUnsafeBytes { bytes in
        for offset in stride(from: 0, to: 32, by: 4) { XCTAssertEqual(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self), 0.4, accuracy: 0.0001) }
      }
    }
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)); buffer.frameLength = 8
    XCTAssertThrowsError(try NotebookDictationPCM.copy(buffer, frame: 0))
  }
  func testSourceAudioEndsRequestsInNoiseAndKeepsQuietSpeechVisibleWithoutUISampling() async throws {
    for (noise, voice): (Float, Float) in [(0.0045, 0.04), (0.0001, 0.002)] {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID()).m4a")
      defer { try? FileManager.default.removeItem(at: url) }
      let storage = NotebookDictationAudioStorage(), id = UUID()
      var frame = 0
      for _ in 0..<12 { _ = try await storage.append(pcm(frame: frame, amplitude: noise)); frame += 6000 }
      _ = try await storage.append(pcm(frame: frame, amplitude: voice)); frame += 6000
      try await storage.begin(at: url, id: id, from: frame - 6000, hasRequest: true)
      // No UI samples or sleeps: the source clock alone owns the decision.
      for index in 0..<40 {
        let update = try await storage.append(pcm(frame: frame, amplitude: index % 8 == 0 ? noise : voice)); frame += 6000
        XCTAssertNil(update.end, "A long sentence cannot raise its own silence threshold")
        if index % 8 != 0 { XCTAssertGreaterThan(update.reading.audio.level, 0.1) }
        XCTAssertEqual(update.reading.id, id)
      }
      for index in 0..<6 {
        let update = try await storage.append(pcm(frame: frame, amplitude: noise)); frame += 6000
        if index < 5 { XCTAssertNil(update.end) } else { XCTAssertEqual(update.end, .pause) }
      }
      let result = await storage.close(); XCTAssertEqual(result.id, id); XCTAssertTrue(result.recorded)
    }
  }
  func testANameAloneExpiresWithoutSendingAndButtonRecordingDoesNotAutoSend() async throws {
    for addressed in [true, false] {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("name-\(UUID()).m4a")
      defer { try? FileManager.default.removeItem(at: url) }
      let storage = NotebookDictationAudioStorage()
      _ = try await storage.append(pcm(frame: 0, amplitude: 0.0045))
      try await storage.begin(at: url, id: UUID(), from: 0, hasRequest: addressed ? false : nil)
      for index in 1...48 {
        let update = try await storage.append(pcm(frame: index * 6000, amplitude: 0.0045))
        XCTAssertEqual(update.end, addressed && index == 48 ? .abandoned : nil)
      }
      _ = await storage.close()
    }
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
    try await storage.begin(at: url, id: UUID(), from: 6000, hasRequest: nil)
    let next = try await storage.append(pcm(frame: 12000))
    XCTAssertEqual(next.reading.elapsed, 0.5, accuracy: 0.001)
    let closed = await storage.close(); XCTAssertTrue(closed.recorded)
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
    do { try await storage.begin(at: url, id: UUID(), from: 0, hasRequest: nil); XCTFail("An expired address must not admit the current tail") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    do { _ = try await storage.append(pcm(frame: 300_000)); XCTFail("Missing PCM is an interruption, not a shorter recording") } catch {}
    let closed = await storage.close(); XCTAssertFalse(closed.recorded)
  }
  func testDirectButtonRecordingUsesTheSameAACWriterAndClosedInputCannotResume() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("direct-audio-\(UUID()).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    let storage = NotebookDictationAudioStorage()
    try await storage.begin(at: url, id: UUID(), from: nil, hasRequest: nil)
    _ = try await storage.append(pcm(frame: 0))
    let closed = await storage.close(); XCTAssertTrue(closed.recorded)
    let file = try AVAudioFile(forReading: url)
    XCTAssertGreaterThan(file.length, 0)
    do { _ = try await storage.append(pcm(frame: 6000)); XCTFail("Closed microphone input cannot resume") } catch {}
  }
}
