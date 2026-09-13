import AVFoundation
import UIKit
import NotebookCore

/// One microphone feeds either local address recognition or the admitted recording.
/// The same stream continues across activation, so the request after GPT is not cut.
@MainActor protocol NotebookDictationCapture: AnyObject {
  func listen(pcm: @escaping @MainActor (Data, Int, Double) -> Void,
    failed: @escaping @MainActor (String) -> Void) async throws
  func start(at url: URL, from frame: Int?, finished: @escaping @MainActor (Bool) -> Void) async throws
  func sample() -> (elapsed: TimeInterval, level: Double)
  func stop()
  func cancel()
}

struct NotebookDictationPCM: Sendable {
  let data: Data
  let frame: Int
  let rate: Double
}

/// End an addressed request on 1.4 seconds of microphone silence. A name alone
/// waits for a following utterance and expires without uploading idle audio.
struct NotebookDictationUtterance {
  enum Decision { case send, abandon }
  private var hasRequest: Bool
  private var previous: TimeInterval?
  private var start: TimeInterval?
  private var silence: TimeInterval = 0, speech: TimeInterval = 0
  init(hasRequest: Bool, silence: Double = 0) { self.hasRequest = hasRequest; self.silence = silence }
  mutating func sample(elapsed: TimeInterval, level: Double) -> Decision? {
    guard elapsed.isFinite, level.isFinite else { return nil }
    guard let previous else { self.previous = elapsed; start = elapsed; return nil }
    let delta = max(0, elapsed - previous); self.previous = elapsed
    // Sampling the same audio again must not manufacture a silence interval.
    if level >= 0.08 {
      silence = 0; speech += delta
      if speech >= 0.2 { hasRequest = true }
    } else { silence += delta; speech = 0 }
    if hasRequest && silence >= 1.4 { return .send }
    if !hasRequest, elapsed - (start ?? elapsed) >= 12 { return .abandon }
    return nil
  }
}

/// Audio-file work is serialized away from Pencil and the real-time audio callback.
/// Waiting retains at most ten seconds in RAM and creates no recording on disk.
actor NotebookDictationAudioStorage {
  private var tail: [NotebookDictationPCM] = []
  private var next = 0, first = 0
  private var rate = 0.0
  private var destination: URL?
  private var file: AVAudioFile?
  private var closed = false
  private var framesWritten = 0

  func append(_ chunk: NotebookDictationPCM) throws -> (TimeInterval, Double) {
    guard !closed else { throw CancellationError() }
    guard chunk.frame == next, (8000...96000).contains(chunk.rate), rate == 0 || rate == chunk.rate,
      chunk.data.count > 0, chunk.data.count <= 65_536, chunk.data.count % 4 == 0 else {
      throw NotebookPersistenceQueue.Failure(message: "Поток микрофона прервался. Ожидание выключено.")
    }
    let power = try chunk.data.withUnsafeBytes { bytes in
      var power = 0.0
      for offset in stride(from: 0, to: bytes.count, by: 4) {
        let sample = Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
        guard sample.isFinite else { throw NotebookPersistenceQueue.Failure(message: "Микрофон передал повреждённый звук.") }
        power += sample * sample
      }
      return power
    }
    rate = chunk.rate; next += chunk.data.count / 4
    if destination != nil { try write(chunk) }
    else {
      tail.append(chunk)
      while tail.count > 1, tail[1].frame < next - Int(rate * 10) { tail.removeFirst() }
    }
    let rms = sqrt(power / Double(chunk.data.count / 4))
    return (Double(framesWritten) / rate, min(1, max(0, (20 * log10(max(rms, 0.000001)) + 55) / 55)))
  }

  func begin(at url: URL, from frame: Int?) throws {
    guard !closed, destination == nil else { throw CancellationError() }
    if let frame {
      guard let oldest = tail.first?.frame, frame >= oldest, frame < next else {
        throw NotebookPersistenceQueue.Failure(message: "Начало обращения уже вне звукового буфера. Скажите GPT ещё раз.")
      }
      first = frame
    } else { first = next }
    destination = url
    for chunk in tail where chunk.frame + chunk.data.count / 4 > first { try write(chunk) }
    tail.removeAll()
  }

  private func write(_ chunk: NotebookDictationPCM) throws {
    guard let destination, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
    let skip = max(0, first - chunk.frame), count = chunk.data.count / 4 - skip
    guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
      let channel = buffer.floatChannelData?[0] else { return }
    if file == nil {
      file = try AVAudioFile(forWriting: destination, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
    }
    buffer.frameLength = AVAudioFrameCount(count)
    chunk.data.withUnsafeBytes { bytes in
      UnsafeMutableRawPointer(channel).copyMemory(from: bytes.baseAddress!.advanced(by: skip * 4), byteCount: count * 4)
    }
    try file?.write(from: buffer); framesWritten += count
  }
  func close() -> Bool {
    let recorded = file != nil && framesWritten > 0
    closed = true; file = nil; tail.removeAll(); return recorded
  }
}

@MainActor final class NotebookMicrophoneDictationCapture: NotebookDictationCapture {
  private var engine: AVAudioEngine?
  private var storage: NotebookDictationAudioStorage?
  private var continuation: AsyncThrowingStream<NotebookDictationPCM, Error>.Continuation?
  private var pump: Task<Void, Never>?
  private var completion: (@MainActor (Bool) -> Void)?
  private var received: (@MainActor (Data, Int, Double) -> Void)?
  private var failure: (@MainActor (String) -> Void)?
  private var generation = UUID()
  private var ownsSession = false
  private var reading = (elapsed: TimeInterval(0), level: 0.0)

  func listen(pcm: @escaping @MainActor (Data, Int, Double) -> Void,
    failed: @escaping @MainActor (String) -> Void) async throws {
    cancel(); received = pcm; failure = failed
    try await microphone()
  }
  func start(at url: URL, from frame: Int?, finished: @escaping @MainActor (Bool) -> Void) async throws {
    if frame == nil { cancel(); try await microphone() }
    let epoch = generation
    guard let storage, engine != nil else { throw CancellationError() }
    try await storage.begin(at: url, from: frame)
    guard generation == epoch else { throw CancellationError() }
    received = nil; failure = nil; completion = finished
  }
  private func microphone() async throws {
    let epoch = generation
    guard await AVAudioApplication.requestRecordPermission() else {
      throw NotebookPersistenceQueue.Failure(message: "Разрешите Notebook доступ к микрофону в настройках iPad.")
    }
    guard generation == epoch else { throw CancellationError() }
    guard UIApplication.shared.applicationState != .background else {
      throw NotebookPersistenceQueue.Failure(message: "Вернитесь в Notebook и включите микрофон.")
    }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
    try session.setActive(true); ownsSession = true
    let engine = AVAudioEngine(), storage = NotebookDictationAudioStorage()
    let input = engine.inputNode, format = input.outputFormat(forBus: 0)
    guard (8000...96000).contains(format.sampleRate), format.channelCount > 0 else {
      throw NotebookPersistenceQueue.Failure(message: "Микрофон не предоставил звуковой вход.")
    }
    let stream = AsyncThrowingStream<NotebookDictationPCM, Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
    let sink = stream.continuation, rate = format.sampleRate
    let cursor = NotebookDictationAudioCursor()
    // iOS 27's public tap API reports admission failure instead of raising an
    // Objective-C exception. This SDK exposes its refined Swift spelling.
    try input.__installTap(onBus: 0, bufferSize: AVAudioFrameCount(rate / 10), format: format, error: ()) { @Sendable buffer, _ in
      guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
      let count = Int(buffer.frameLength), frame = cursor.advance(count)
      let data = Data(bytes: channel, count: count * 4)
      if case .dropped = sink.yield(.init(data: data, frame: frame, rate: rate)) {
        sink.finish(throwing: NotebookPersistenceQueue.Failure(message: "iPad не успевает принимать звук. Микрофон выключен; повторите запись."))
      }
    }
    self.engine = engine; self.storage = storage; continuation = sink
    pump = Task { [weak self] in
      do {
        for try await chunk in stream.stream {
          let sample = try await storage.append(chunk)
          guard let self, generation == epoch, !Task.isCancelled else { break }
          reading = sample; received?(chunk.data, chunk.frame, chunk.rate)
          if completion != nil, sample.0 >= NotebookDictationRecording.maximumDuration { stop() }
        }
        let success = await storage.close()
        guard let self, generation == epoch, !Task.isCancelled else { return }
        let callback = completion; let failed = failure
        cancel()
        if let callback { callback(success) } else { failed?("Микрофон остановлен.") }
      } catch {
        _ = await storage.close()
        guard let self, generation == epoch, !Task.isCancelled else { return }
        let callback = completion; let failed = failure
        cancel(); if let callback { callback(false) } else { failed?(error.localizedDescription) }
      }
    }
    engine.prepare(); try engine.start()
  }
  func sample() -> (elapsed: TimeInterval, level: Double) { reading }
  func stop() { stopEngine(); continuation?.finish(); continuation = nil }
  func cancel() {
    generation = UUID(); completion = nil; received = nil; failure = nil
    stop(); pump?.cancel(); pump = nil
    if let storage { Task { _ = await storage.close() } }; storage = nil
    reading = (0, 0)
  }
  private func stopEngine() {
    if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }; engine = nil
    if ownsSession {
      ownsSession = false
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
}

/// The audio callback is serialized by AVAudioEngine; its cursor never crosses
/// the main actor. The lock also covers a device callback during engine teardown.
private final class NotebookDictationAudioCursor: @unchecked Sendable {
  private let lock = NSLock()
  private var frame = 0
  func advance(_ count: Int) -> Int { lock.withLock { defer { frame += count }; return frame } }
}
