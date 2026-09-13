import AVFoundation
import Speech
import NotebookCore

/// Local classification of the address only. This object owns neither a microphone
/// nor a transcript: PCM comes from the call's one media graph and is never saved.
@MainActor final class NotebookWakeRecognizer {
  let language: String
  let address: String
  let activated: (Int) -> Void
  let failed: (String) -> Void
  private let recognizer: SFSpeechRecognizer
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognition: SFSpeechRecognitionTask?
  private var settle: Task<Void, Never>?
  private var generation = UUID()
  private var stopped = true
  private var base = 0, rate = 0.0, nextFrame: Int?
  private var tail: [(frame: Int, samples: [Float])] = []

  static var languages: [String] { SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted() }
  static var preferredLanguage: String {
    let preferred = Locale.preferredLanguages.first ?? "en-US"
    return languages.first { $0.replacingOccurrences(of: "_", with: "-") == preferred }
      ?? languages.first { $0.prefix(2) == preferred.prefix(2) } ?? "en-US"
  }
  init(language: String, address: String, activated: @escaping (Int) -> Void, failed: @escaping (String) -> Void) throws {
    let requested = language.replacingOccurrences(of: "_", with: "-").lowercased()
    guard Self.languages.contains(where: { $0.replacingOccurrences(of: "_", with: "-").lowercased() == requested }),
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.supportsOnDeviceRecognition else {
      let name = Locale.current.localizedString(forIdentifier: language) ?? language
      throw NotebookPersistenceQueue.Failure(message: "На этом iPad недоступно локальное распознавание: \(name). Выберите другой язык в настройках голоса или начните разговор кнопкой. Микрофон выключен.")
    }
    self.recognizer = recognizer; self.language = language; self.address = address
    self.activated = activated; self.failed = failed
  }
  func authorize() async -> Bool {
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    return status == .authorized
  }
  func start() { stopped = false }
  func stop() {
    stopped = true; generation = UUID(); settle?.cancel(); settle = nil
    request?.endAudio(); recognition?.cancel(); request = nil; recognition = nil; tail = []; nextFrame = nil
  }
  func append(data: Data, frame: Int, sampleRate: Double) {
    guard !stopped else { return }
    guard (8000...96000).contains(sampleRate), frame >= 0, data.count > 0, data.count <= 65536, data.count % 4 == 0,
      nextFrame == nil || nextFrame == frame, rate == 0 || rate == sampleRate else { abort("Локальный звук прервался. Микрофон выключен."); return }
    var samples = [Float](repeating: 0, count: data.count / 4)
    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    guard samples.allSatisfy(\.isFinite) else { abort("Локальный звук повреждён. Микрофон выключен."); return }
    rate = sampleRate; nextFrame = frame + samples.count
    tail.append((frame, samples)); while tail.count > 1, tail[1].frame < frame - Int(rate * 1.5) { tail.removeFirst() }
    if request == nil || frame - base > Int(rate * 45) { restart() }
    else { feed(samples) }
  }
  private func restart() {
    generation = UUID(); settle?.cancel(); request?.endAudio(); recognition?.cancel()
    base = tail.first?.frame ?? 0
    let generation = generation
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
    request.contextualStrings = NotebookWakeAddress.phrases(language: language, address: address)
    self.request = request
    recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let segments = result?.bestTranscription.segments.map { NotebookWakeAddress.Segment($0.substring, start: $0.timestamp, duration: $0.duration) }
      let final = result?.isFinal == true
      let failure = error?.localizedDescription
      Task { @MainActor [weak self] in self?.receive(segments, final: final, error: failure, generation: generation) }
    }
    for chunk in tail { feed(chunk.samples) }
  }
  private func feed(_ samples: [Float]) {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData?[0] else { abort("Не удалось подготовить локальный звук."); return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
    request?.append(buffer)
  }
  private func receive(_ segments: [NotebookWakeAddress.Segment]?, final: Bool, error: String?, generation: UUID) {
    guard !stopped, generation == self.generation else { return }
    if let segments, !segments.isEmpty {
      settle?.cancel()
      if detect(segments, settled: final) { return }
      settle = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
        guard let self, !stopped, generation == self.generation else { return }
        _ = detect(segments, settled: true)
      }
    }
    if final { self.request?.endAudio(); self.request = nil; recognition = nil }
    else if let error { abort("Локальное ожидание обращения остановлено: \(error)") }
  }
  @discardableResult private func detect(_ segments: [NotebookWakeAddress.Segment], settled: Bool) -> Bool {
    guard let time = NotebookWakeAddress.start(in: segments, language: language, address: address, settled: settled) else { return false }
    let frame = base + Int(time * rate)
    stop(); activated(frame); return true
  }
  private func abort(_ message: String) { stop(); failed(message) }
}
