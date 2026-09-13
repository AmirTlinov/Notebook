import AVFoundation
import UIKit
import OSLog
import NotebookCore

struct NotebookDictationReading: Sendable {
  let id: UUID?
  let elapsed: TimeInterval
  let audio: NotebookAcousticUtterance.Sample
  let levels: [Double]
  var capturedAt = ProcessInfo.processInfo.systemUptime
}
enum NotebookDictationEnd: Sendable { case pause, abandoned, limit, stopped }
struct NotebookDictationCompletion: Sendable {
  let id: UUID?
  let frame: Int
  let rate: Double
  let reason: NotebookDictationEnd
  let recorded: Bool
  let error: String?
  let completedAt = ProcessInfo.processInfo.systemUptime
}
enum NotebookDictationAudioEvent: Sendable {
  case reading(NotebookDictationReading)
  case finished(NotebookDictationCompletion)
}

/// One source stream continues from local waiting into an admitted recording.
/// Meter snapshots may coalesce; recording completion is delivered separately.
@MainActor protocol NotebookDictationCapture: AnyObject {
  func listen(pcm: @escaping @Sendable (Data, NotebookAcousticUtterance.Sample) async -> Void,
    events: @escaping @MainActor (NotebookDictationAudioEvent) -> Void) async throws
  func start(at url: URL, id: UUID, from frame: Int?, hasRequest: Bool?,
    events: @escaping @MainActor (NotebookDictationAudioEvent) -> Void) async throws
  func stop()
  func cancel()
}
struct NotebookDictationPCM: Sendable {
  let data: Data
  let frame: Int
  let rate: Double
  let capturedAt = ProcessInfo.processInfo.systemUptime
  static func copy(_ buffer: AVAudioPCMBuffer, frame: Int) throws -> Self {
    guard buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData,
      buffer.frameLength > 0, buffer.format.channelCount > 0 else {
      throw NotebookPersistenceQueue.Failure(message: "Микрофон перестал передавать поддерживаемый звук.")
    }
    let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount), stride = buffer.stride
    var values = [Float](repeating: 0, count: count)
    for channel in 0..<channelCount {
      for index in 0..<count {
        let value = buffer.format.isInterleaved ? channels[0][index * stride + channel] : channels[channel][index * stride]
        values[index] += value / Float(channelCount)
      }
    }
    return .init(data: values.withUnsafeBytes { Data($0) }, frame: frame, rate: buffer.format.sampleRate)
  }
}

/// This actor owns the source-audio clock, analysis, bounded pre-roll and AAC.
/// Neither a delayed UI frame nor a slow main actor can manufacture a pause.
actor NotebookDictationAudioStorage {
  struct Update: Sendable {
    let reading: NotebookDictationReading
    let waiting: Bool
    let end: NotebookDictationEnd?
  }
  private var tail: [NotebookDictationPCM] = []
  private var next = 0, first = 0, admitted = 0, speechFrames = 0
  private var rate = 0.0
  private var destination: URL?
  private var id: UUID?
  private var hasRequest: Bool?
  private var file: AVAudioFile?
  private var closed = false
  private var framesWritten = 0
  private var diagnostic: [[String: Double]] = []
  private var acoustic = NotebookAcousticUtterance()
  private var levels: [Double] = []

  func append(_ chunk: NotebookDictationPCM) throws -> Update {
    guard !closed else { throw CancellationError() }
    guard chunk.frame == next, (8000...96000).contains(chunk.rate), rate == 0 || rate == chunk.rate,
      chunk.data.count > 0, chunk.data.count <= 65_536, chunk.data.count % 4 == 0 else {
      throw NotebookPersistenceQueue.Failure(message: "Поток микрофона прервался. Запись сохранена на iPad.")
    }
    let measurement = try chunk.data.withUnsafeBytes { bytes in
      var power = 0.0, peak = 0.0
      for offset in stride(from: 0, to: bytes.count, by: 4) {
        let sample = Double(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
        guard sample.isFinite else { throw NotebookPersistenceQueue.Failure(message: "Микрофон передал повреждённый звук.") }
        power += sample * sample; peak = max(peak, abs(sample))
      }
      return (sqrt(power / Double(bytes.count / 4)), peak)
    }
    rate = chunk.rate; next += chunk.data.count / 4
    let audio = acoustic.append(rms: measurement.0, peak: measurement.1, frame: chunk.frame, count: chunk.data.count / 4, rate: rate)
    levels.append(audio.level); if levels.count > 240 { levels.removeFirst(levels.count - 240) }
    if destination != nil {
      try write(chunk)
      diagnostic.append(["frame": Double(audio.end), "rms": audio.rms, "peak": audio.peak,
        "noiseDB": audio.noiseDB, "level": audio.level, "silence": audio.silence, "speaking": audio.speaking ? 1 : 0,
        "analysisDelayMs": (ProcessInfo.processInfo.systemUptime - chunk.capturedAt) * 1000])
      if diagnostic.count > 240 { diagnostic.removeFirst() }
    }
    else {
      tail.append(chunk)
      while tail.count > 1, tail[1].frame < next - Int(rate * 10) { tail.removeFirst() }
    }
    var end: NotebookDictationEnd?
    if let hasRequest {
      if audio.speaking { speechFrames += audio.count } else { speechFrames = 0 }
      if !hasRequest, Double(speechFrames) / rate >= 0.2 { self.hasRequest = true }
      if self.hasRequest == true, audio.silence >= 1.4 { end = .pause }
      else if self.hasRequest == false, Double(next - admitted) / rate >= 12 { end = .abandoned }
    }
    if Double(framesWritten) / rate >= NotebookDictationRecording.maximumDuration { end = .limit }
    return .init(reading: .init(id: id, elapsed: Double(framesWritten) / rate, audio: audio, levels: levels, capturedAt: chunk.capturedAt),
      waiting: destination == nil, end: end)
  }
  func begin(at url: URL, id: UUID, from frame: Int?, hasRequest: Bool?) throws {
    guard !closed, destination == nil else { throw CancellationError() }
    if let frame {
      guard let oldest = tail.first?.frame, frame >= oldest, frame < next else {
        throw NotebookPersistenceQueue.Failure(message: "Начало обращения уже вне звукового буфера. Скажите GPT ещё раз.")
      }
      first = frame
    } else { first = next }
    self.id = id; self.hasRequest = hasRequest; admitted = next; levels = []
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
  func close(reason: NotebookDictationEnd = .stopped, error: String? = nil) -> NotebookDictationCompletion {
    let recorded = file != nil && framesWritten > 0
    if !closed, let destination, let id {
      let report: [String: Any] = ["recording": id.uuidString, "rate": rate, "framesWritten": framesWritten,
        "framesReceived": next, "samples": diagnostic, "closedAt": Date().timeIntervalSince1970, "reason": String(describing: reason)]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
        try? data.write(to: destination.deletingLastPathComponent().appendingPathComponent("audio-diagnostics.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
      Logger(subsystem: "com.amirtlinov.notebook", category: "dictation-audio").info("closed frames=\(self.framesWritten) rate=\(self.rate)")
    }
    closed = true; file = nil; tail.removeAll()
    return .init(id: id, frame: next, rate: rate, reason: reason, recorded: recorded, error: error)
  }
}

@MainActor final class NotebookMicrophoneDictationCapture: NotebookDictationCapture {
  private var engine: AVAudioEngine?
  private var storage: NotebookDictationAudioStorage?
  private var continuation: AsyncThrowingStream<NotebookDictationPCM, Error>.Continuation?
  private var pump: Task<Void, Never>?
  private var meter: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var events: (@MainActor (NotebookDictationAudioEvent) -> Void)?
  private var generation = UUID()
  private var ownsSession = false

  func listen(pcm: @escaping @Sendable (Data, NotebookAcousticUtterance.Sample) async -> Void,
    events: @escaping @MainActor (NotebookDictationAudioEvent) -> Void) async throws {
    cancel(); self.events = events
    try await microphone(pcm: pcm)
  }
  func start(at url: URL, id: UUID, from frame: Int?, hasRequest: Bool?,
    events: @escaping @MainActor (NotebookDictationAudioEvent) -> Void) async throws {
    self.events = events
    if engine == nil {
      guard frame == nil else { throw CancellationError() }
      try await microphone(pcm: { _, _ in })
    }
    let epoch = generation
    guard let storage, engine != nil else { throw CancellationError() }
    try await storage.begin(at: url, id: id, from: frame, hasRequest: hasRequest)
    guard generation == epoch else { throw CancellationError() }
  }
  private func microphone(pcm: @escaping @Sendable (Data, NotebookAcousticUtterance.Sample) async -> Void) async throws {
    let epoch = generation
    guard await AVAudioApplication.requestRecordPermission() else {
      throw NotebookPersistenceQueue.Failure(message: "Разрешите Notebook доступ к микрофону в настройках iPad.")
    }
    guard generation == epoch else { throw CancellationError() }
    guard UIApplication.shared.applicationState != .background else {
      throw NotebookPersistenceQueue.Failure(message: "Вернитесь в Notebook, чтобы включить микрофон.")
    }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
    try session.setActive(true); ownsSession = true
    let engine = AVAudioEngine(), storage = NotebookDictationAudioStorage()
    let input = engine.inputNode, format = input.outputFormat(forBus: 0)
    guard (8000...96000).contains(format.sampleRate), format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
      throw NotebookPersistenceQueue.Failure(message: "Микрофон не предоставил поддерживаемый звуковой вход.")
    }
    let stream = AsyncThrowingStream<NotebookDictationPCM, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
    let snapshots = AsyncStream<NotebookDictationReading>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let sink = stream.continuation, rate = format.sampleRate
    let cursor = NotebookDictationAudioCursor()
    // iOS 27's throwing tap API reports admission failure rather than raising
    // an Objective-C exception. Normalize channel layout at this boundary.
    try input.__installTap(onBus: 0, bufferSize: AVAudioFrameCount(rate / 20), format: format, error: ()) { @Sendable buffer, _ in
      do {
        let frame = cursor.advance(Int(buffer.frameLength))
        let chunk = try NotebookDictationPCM.copy(buffer, frame: frame)
        if case .dropped = sink.yield(chunk) {
          sink.finish(throwing: NotebookPersistenceQueue.Failure(message: "Приём звука прервался. Запись сохранена на iPad."))
        }
      } catch { sink.finish(throwing: error) }
    }
    self.engine = engine; self.storage = storage; continuation = sink
    meter = Task { [weak self] in
      for await reading in snapshots.stream {
        guard let self, generation == epoch, !Task.isCancelled else { return }
        events?(.reading(reading))
      }
    }
    // No per-block main-actor hop: file I/O, speech boundaries and local ASR
    // continue while the user drags the chat or draws with Pencil.
    pump = Task.detached(priority: .userInitiated) { [weak self] in
      var reason = NotebookDictationEnd.stopped, failure: String?
      do {
        for try await chunk in stream.stream {
          try Task.checkCancellation()
          let update = try await storage.append(chunk)
          snapshots.continuation.yield(update.reading)
          if update.waiting { await pcm(chunk.data, update.reading.audio) }
          if let end = update.end { reason = end; break }
        }
      } catch { failure = error.localizedDescription }
      sink.finish(); snapshots.continuation.finish()
      let completion = await storage.close(reason: reason, error: failure)
      guard !Task.isCancelled else { return }
      await self?.finished(epoch: epoch, completion: completion)
    }
    engine.prepare(); try engine.start()
    watchdog = Task.detached {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        if cursor.stalled {
          sink.finish(throwing: NotebookPersistenceQueue.Failure(message: "Микрофон не передаёт звук. Запись сохранена; проверьте микрофон.")); return
        }
      }
    }
  }
  private func finished(epoch: UUID, completion: NotebookDictationCompletion) {
    guard generation == epoch else { return }
    let callback = events
    cancel()
    callback?(.finished(completion))
  }
  func stop() { stopEngine(); continuation?.finish(); continuation = nil }
  func cancel() {
    generation = UUID(); events = nil
    stop(); pump?.cancel(); pump = nil; meter?.cancel(); meter = nil
    if let storage { Task { _ = await storage.close() } }; storage = nil
  }
  private func stopEngine() {
    watchdog?.cancel(); watchdog = nil
    if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }; engine = nil
    if ownsSession {
      ownsSession = false
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
}
private final class NotebookDictationAudioCursor: @unchecked Sendable {
  private let lock = NSLock()
  private var frame = 0
  private var last = ContinuousClock.now
  var stalled: Bool { lock.withLock { last.duration(to: .now) > .seconds(2) } }
  func advance(_ count: Int) -> Int { lock.withLock { defer { frame += count; last = .now }; return frame } }
}
