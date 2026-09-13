import AVFoundation
import Speech
import OSLog
import NotebookCore

@MainActor protocol NotebookAddressRecognition: AnyObject {
  func start()
  func stop()
  func append(data: Data, frame: Int, sampleRate: Double)
}
struct NotebookWakeActivation { let frame: Int; let hasRequest: Bool; var silence: Double = 0 }

/// Local classification of the address only. This object owns neither a microphone
/// nor a transcript: PCM comes from the active audio owner, not a second microphone.
@MainActor final class NotebookWakeRecognizer: NotebookAddressRecognition {
  let language: String
  let address: String
  let activated: (NotebookWakeActivation) -> Void
  let failed: (String) -> Void
  private let recognizer: SFSpeechRecognizer
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognition: SFSpeechRecognitionTask?
  private var settle: Task<Void, Never>?
  private var generation = UUID()
  private var stopped = true
  private var base = 0, rate = 0.0, nextFrame: Int?
  private var acoustic = NotebookAcousticUtterance()
  private var phraseOpen = false
  private static let log = Logger(subsystem: "com.amirtlinov.notebook", category: "wake")
  private var tail: [(frame: Int, samples: [Float])] = []

  static var languages: [String] { SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted() }
  static var preferredLanguage: String {
    let preferred = Locale.preferredLanguages.first ?? "en-US"
    return languages.first { $0.replacingOccurrences(of: "_", with: "-") == preferred }
      ?? languages.first { $0.prefix(2) == preferred.prefix(2) } ?? "en-US"
  }
  init(language: String, address: String, activated: @escaping (NotebookWakeActivation) -> Void, failed: @escaping (String) -> Void) throws {
    let requested = language.replacingOccurrences(of: "_", with: "-").lowercased()
    guard Self.languages.contains(where: { $0.replacingOccurrences(of: "_", with: "-").lowercased() == requested }),
      let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.supportsOnDeviceRecognition else {
      let name = Locale.current.localizedString(forIdentifier: language) ?? language
      throw NotebookPersistenceQueue.Failure(message: "На этом iPad недоступно локальное распознавание: \(name). Выберите другой язык в настройках голоса или начните разговор кнопкой. Микрофон выключен.")
    }
    self.recognizer = recognizer; self.language = language; self.address = address
    self.activated = activated; self.failed = failed
  }
  static func authorize() async -> Bool {
    let status = await withCheckedContinuation { continuation in
      // Speech may reply on a background queue. Only the awaiting owner resumes
      // on MainActor; the system callback must not inherit its isolation.
      SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
    }
    return status == .authorized
  }
  func start() { acoustic = .init(); rate = 0; stopped = false }
  func stop() {
    stopped = true; generation = UUID(); settle?.cancel(); settle = nil
    request?.endAudio(); recognition?.cancel(); request = nil; recognition = nil; tail = []; nextFrame = nil; phraseOpen = false
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
    let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    let boundary = acoustic.append(rms: sqrt(power / Double(samples.count)), frame: frame, count: samples.count, rate: rate)
    if case .began(let start) = boundary { beginPhrase(at: start) }
    else if phraseOpen { feed(samples) }
    if boundary == .ended {
      phraseOpen = false; request?.endAudio()
    }
    // A long non-addressed monologue is not restarted in its middle, where a
    // mention of GPT would falsely become an opening address.
    if phraseOpen, frame - base > Int(rate * 30) {
      phraseOpen = false; request?.endAudio()
    }
  }
  private func beginPhrase(at frame: Int) {
    generation = UUID(); settle?.cancel(); request?.endAudio(); recognition?.cancel()
    base = frame; phraseOpen = true
    let generation = generation
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
    request.contextualStrings = NotebookWakeAddress.phrases(language: language, address: address)
    self.request = request
    recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let final = result?.isFinal == true
      let failure = error?.localizedDescription
      let noSpeech = (error as NSError?).map { $0.domain == "kAFAssistantErrorDomain" && $0.code == 1110 || $0.domain == "kLSRErrorDomain" && $0.code == 203 } == true
      Task { @MainActor [weak self] in self?.receive(text, final: final, error: noSpeech ? nil : failure, generation: generation) }
    }
    for chunk in tail where chunk.frame + chunk.samples.count > base {
      feed(Array(chunk.samples.dropFirst(max(0, base - chunk.frame))))
    }
  }
  private func feed(_ samples: [Float]) {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData?[0] else { abort("Не удалось подготовить локальный звук."); return }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
    request?.append(buffer)
  }
  private func receive(_ text: String?, final: Bool, error: String?, generation: UUID) {
    guard !stopped, generation == self.generation else { return }
    if let text, !text.isEmpty {
      settle?.cancel()
      if detect(text, settled: final) { return }
      settle = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        guard let self, !stopped, generation == self.generation, acoustic.silence >= 0.4 else { return }
        _ = detect(text, settled: true)
      }
    }
    if final { request = nil; recognition = nil }
    // "No speech" at the end of an acoustic event (a knock, for example) is a
    // rejected candidate, not a failed microphone. Unexpected live failures stop.
    else if let error { abort("Локальное ожидание обращения остановлено: \(error)") }
  }
  @discardableResult private func detect(_ text: String, settled: Bool) -> Bool {
    guard let hasRequest = NotebookWakeAddress.match(text, language: language, address: address, settled: settled) else { return false }
    let activation = NotebookWakeActivation(frame: base, hasRequest: hasRequest, silence: acoustic.silence)
    let age = Double((nextFrame ?? base) - base) / rate
    Self.log.info("address admitted; audio age=\(age, privacy: .public)s; request=\(hasRequest, privacy: .public)")
    stop(); activated(activation); return true
  }
  private func abort(_ message: String) { stop(); failed(message) }
}
