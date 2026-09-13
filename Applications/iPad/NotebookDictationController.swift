import AVFoundation
import CryptoKit
import Observation
import OSLog
import UIKit
import NotebookCore

/// The chat owns this controller, independent of either presentation. A private
/// recording survives network errors and app restarts until insertion, durable
/// submission or cancel.
@MainActor @Observable final class NotebookDictationController {
  enum Phase { case idle, authorizing, waiting, recording, finishing, transcribing, inserting, failed }
  struct Activation: Codable, Equatable { let language: String; let address: String }
  struct Pending: Codable, Equatable {
    let id: UUID
    let thread: String
    let computer: UUID
    var transcript: String?
    var activation: Activation? = nil
  }
  private static let log = Logger(subsystem: "com.amirtlinov.notebook", category: "dictation")
  private(set) var phase = Phase.idle { didSet {
    if phase != oldValue { Self.log.info("phase=\(String(describing: self.phase), privacy: .public)") }
  } }
  private(set) var error: String?
  private(set) var elapsed: TimeInterval = 0
  private(set) var level: Double = 0
  private(set) var levels: [Double] = []
  private(set) var reviewRequest: UUID?
  private(set) var progress: Double = 0
  private(set) var pending: Pending?
  private(set) var activationEnabled = false
  var waiting: Bool { phase == .waiting }
  var busy: Bool { (phase != .idle && phase != .waiting) || pending != nil }
  var recording: Bool { phase == .recording }
  var showsInput: Bool { busy && !canRetry && phase != .failed }
  var canRetry: Bool { phase == .failed && pending.map { cancellations[$0.computer.uuidString] != $0.id } == true }
  func allowsComputer(_ id: UUID) -> Bool { !busy || (phase == .failed && pending?.computer == id) }
  func allowsThread(_ id: String) -> Bool {
    !busy || (phase == .failed && pending?.thread == id && pending?.computer == chat?.computerID)
  }
  var status: String {
    switch phase {
    case .idle: error ?? ""
    case .authorizing: "Подготовка микрофона…"
    case .waiting: "Ожидаю GPT · отправка после паузы"
    case .recording: "Диктовка · \(Int(elapsed) / 60):\(String(format: "%02d", Int(elapsed) % 60))"
    case .finishing: "Сохраняю запись…"
    case .transcribing: progress < 1 ? "Передаю запись в Codex…" : "Codex распознаёт речь…"
    case .inserting: submitAddressed == nil ? "Сохраняю текст в черновике…" : "Отправляю просьбу…"
    case .failed: error ?? "Запись сохранена. Повторите распознавание."
    }
  }
  @ObservationIgnored weak var chat: NotebookChatController?
  @ObservationIgnored var submissionInProgress: @MainActor () -> Bool = { false }
  typealias Submission = @MainActor (Pending, String) async -> Bool
  @ObservationIgnored var captureSubmission: @MainActor () -> Submission? = { nil }
  @ObservationIgnored private var submitAddressed: Submission?
  @ObservationIgnored private var utterance: NotebookDictationUtterance?
  @ObservationIgnored private var directory: URL?
  @ObservationIgnored private let capture: any NotebookDictationCapture
  @ObservationIgnored private var sendAfterInsertion: (@MainActor () -> Void)?
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var meter: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var cancellations: [String: UUID] = [:]
  @ObservationIgnored private var wake: (any NotebookAddressRecognition)?
  @ObservationIgnored private var activationTarget: (thread: String, computer: UUID)?
  @ObservationIgnored var authorizeAddress: @MainActor () async -> Bool = { await NotebookWakeRecognizer.authorize() }
  @ObservationIgnored var makeAddressRecognizer: @MainActor (String, String, @escaping (NotebookWakeActivation) -> Void, @escaping (String) -> Void) throws -> any NotebookAddressRecognition = {
    try NotebookWakeRecognizer(language: $0, address: $1, activated: $2, failed: $3)
  }

  init(capture: any NotebookDictationCapture = NotebookMicrophoneDictationCapture()) { self.capture = capture }

  func restore(directory: URL, inserted: UUID?) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cancelled = directory.appendingPathComponent("cancelled.json")
    if FileManager.default.fileExists(atPath: cancelled.path) {
      cancellations = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: cancelled))
    }
    let manifest = directory.appendingPathComponent("pending.json")
    if FileManager.default.fileExists(atPath: manifest.path) {
      let saved = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: manifest))
      pending = saved
      if saved.id == inserted || cancellations[saved.computer.uuidString] == saved.id { clearRecording(); phase = .idle }
      else { phase = .failed; error = "Сохранена незавершённая диктовка. Можно повторить распознавание или удалить запись." }
    }
    observers = [UIApplication.didEnterBackgroundNotification, AVAudioSession.interruptionNotification,
      AVAudioSession.mediaServicesWereResetNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          activationEnabled = false; activationTarget = nil
          if recording { finish() } else if waiting || phase == .authorizing { cancel() }
        }
      }
    }
  }

  private func target() -> (thread: String, computer: UUID)? {
    guard let chat, let thread = chat.threadID, !chat.browsesChats else { error = "Выберите чат для диктовки."; return nil }
    guard chat.connected, let computer = chat.computerID, !chat.switchingComputer else { error = "Подключите Mac, чтобы начать диктовку."; return nil }
    guard !chat.saving, !submissionInProgress() else { error = "Дождитесь сохранения текущего сообщения и начните диктовку."; return nil }
    guard !chat.voice.capturing else { error = "Завершите голосовой разговор перед диктовкой."; return nil }
    guard directory != nil else { error = "Хранилище записи ещё не готово."; return nil }
    return (thread, computer)
  }
  func arm() async {
    guard !busy, !waiting, let target = target(), let chat else { return }
    generation = UUID(); let epoch = generation
    activationEnabled = true; activationTarget = target; phase = .authorizing; error = nil
    do {
      try await finishCancellation(on: target.computer)
      guard generation == epoch else { return }
      let recognizer = try makeAddressRecognizer(chat.voice.language, chat.voice.address, { [weak self] activation in
        guard let self, generation == epoch, waiting else { return }
        operation = Task { [weak self] in await self?.begin(from: activation, wakeEpoch: epoch) }
      }, { [weak self] message in
        guard let self, generation == epoch else { return }
        cancel(); error = message
      })
      wake = recognizer
      guard await authorizeAddress() else {
        throw NotebookPersistenceQueue.Failure(message: "Для обращения GPT разрешите локальное распознавание в настройках iPad. Окружающая речь не отправляется.")
      }
      guard generation == epoch else { return }
      recognizer.start()
      try await capture.listen(pcm: { [weak self] data, frame, rate in
        guard let self, generation == epoch else { return }
        wake?.append(data: data, frame: frame, sampleRate: rate)
      }, failed: { [weak self] message in
        guard let self, generation == epoch else { return }
        cancel(); error = message
      })
      guard generation == epoch else { return }
      phase = .waiting; levels = []; startMeter()
    } catch {
      guard generation == epoch else { return }
      cancel(); self.error = error.localizedDescription
    }
  }
  func disableActivation() {
    activationEnabled = false; activationTarget = nil
    if waiting || (phase == .authorizing && pending == nil) { cancel() }
  }
  func begin() async { await begin(from: nil, wakeEpoch: nil) }
  private func begin(from activation: NotebookWakeActivation?, wakeEpoch: UUID?) async {
    guard !busy else { return }
    if let wakeEpoch { guard generation == wakeEpoch, waiting, activationEnabled else { return } }
    else { disableActivation() }
    error = nil
    let frame = activation?.frame
    guard let target = target() else { disableActivation(); return }
    let thread = target.thread, computer = target.computer
    if frame != nil {
      guard activationTarget?.thread == thread, activationTarget?.computer == computer else { disableActivation(); return }
    }
    if frame == nil { generation = UUID() }
    let epoch = generation; sendAfterInsertion = nil; reviewRequest = nil; levels = []
    submitAddressed = activation == nil ? nil : captureSubmission()
    if activation != nil, submitAddressed == nil {
      disableActivation(); error = "Дождитесь подготовки выбранного материала и повторите обращение."; return
    }
    utterance = activation.map { .init(hasRequest: $0.hasRequest, silence: $0.silence) }
    phase = .authorizing
    wake?.stop(); wake = nil
    do { if frame == nil { try await finishCancellation(on: computer) } }
    catch {
      guard generation == epoch else { return }
      phase = .idle; self.error = "Не удалось завершить отмену прежней диктовки на Mac. Повторите после восстановления связи."; return
    }
    guard generation == epoch else { return }
    do {
      var recording = Pending(id: UUID(), thread: thread, computer: computer)
      if frame != nil, let chat { recording.activation = .init(language: chat.voice.language, address: chat.voice.address) }
      pending = recording; try savePending()
      try await capture.start(at: audioURL(recording.id), from: frame) { [weak self] success in
        self?.captureFinished(epoch: epoch, success: success)
      }
      guard generation == epoch else { return }
      phase = .recording; elapsed = 0; level = 0; progress = 0
      startMeter()
    } catch {
      guard generation == epoch else { return }
      releaseMicrophone()
      if let pending, !FileManager.default.fileExists(atPath: audioURL(pending.id).path) { clearRecording() }
      activationEnabled = false; activationTarget = nil
      phase = pending == nil ? .idle : .failed; self.error = error.localizedDescription
    }
  }
  private func startMeter() {
    meter?.cancel()
    meter = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, phase == .recording || phase == .waiting else { return }
        let sample = capture.sample(); elapsed = sample.elapsed; level = sample.level
        levels.append(level); if levels.count > 240 { levels.removeFirst(levels.count - 240) }
        switch utterance?.sample(elapsed: elapsed, level: level) {
        case .send: completeRecording(); return
        case .abandon:
          submitAddressed = nil; releaseMicrophone(); clearRecording(); phase = .idle
          resumeActivation(); return
        default: break
        }
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      }
    }
  }
  func recoveryFailed() { phase = .idle; error = "Не удалось восстановить прежнюю запись диктовки. Сохранённые файлы оставлены на iPad." }
  func finish(sending: (@MainActor () -> Void)? = nil) {
    guard phase == .recording else { return }
    // A deliberate stop switches this recording to review. Only the automatic
    // end of an addressed utterance may bypass the editable draft.
    if submitAddressed != nil { disableActivation(); submitAddressed = nil }
    sendAfterInsertion = sending
    if sending == nil { revealDraft(focus: false) }
    completeRecording()
  }
  private func completeRecording() {
    guard phase == .recording else { return }
    elapsed = capture.sample().elapsed; phase = .finishing; meter?.cancel(); level = 0
    let epoch = generation
    operation = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let self, generation == epoch, phase == .finishing else { return }
      releaseMicrophone(); disableActivation(); submitAddressed = nil; sendAfterInsertion = nil; phase = .failed
      error = "Запись не завершилась вовремя. Аудио сохранено; повторите распознавание."; revealDraft(focus: true)
    }
    capture.stop()
  }
  func revealDraft(focus: Bool = true) {
    guard let chat, pending == nil || (chat.threadID == pending?.thread && chat.computerID == pending?.computer) else { return }
    chat.browsesChats = false; chat.expanded = true
    if focus { reviewRequest = UUID() }
  }
  func retry() {
    guard canRetry else { return }
    sendAfterInsertion = nil; submitAddressed = nil; revealDraft(focus: false)
    operation?.cancel(); let epoch = generation
    operation = Task { [weak self] in await self?.recognize(epoch: epoch, retryFailed: true) }
  }
  func cancel() {
    guard phase != .inserting else { return }
    activationEnabled = false; activationTarget = nil
    generation = UUID(); operation?.cancel(); operation = nil; sendAfterInsertion = nil; submitAddressed = nil
    releaseMicrophone()
    let previous = pending
    if let previous {
      cancellations[previous.computer.uuidString] = previous.id
      do { try saveCancellations() }
      catch { phase = .failed; self.error = "Не удалось сохранить отмену. Запись оставлена на iPad; повторите отмену."; return }
    }
    clearRecording(); phase = .idle; error = nil; elapsed = 0; progress = 0
    if let previous, let chat, chat.computerID == previous.computer, chat.connected {
      Task { [weak self] in try? await self?.finishCancellation(on: previous.computer) }
    }
  }
  /// A cancelled recording must not occupy the Mac's single upload slot after
  /// an offline cancel or restart. Its small receipt outlives the deleted audio.
  func finishCancellation(on computer: UUID) async throws {
    let key = computer.uuidString
    guard let id = cancellations[key] else { return }
    guard let chat, chat.computerID == computer, chat.connected,
      case .dictation(let state) = try await chat.directQuery(.dictation(.cancel(id))),
      state.id == id, state.phase == .cancelled, state.isValid else { throw NotebookTransportError.disconnected }
    guard cancellations[key] == id else { return }
    cancellations.removeValue(forKey: key)
    do { try saveCancellations() }
    catch { cancellations[key] = id; throw error }
  }
  func shutdown() {
    activationEnabled = false; activationTarget = nil
    generation = UUID(); operation?.cancel(); operation = nil; sendAfterInsertion = nil; submitAddressed = nil; releaseMicrophone()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
    if pending != nil { phase = .failed }
  }
  private func releaseMicrophone() {
    wake?.stop(); wake = nil; meter?.cancel(); meter = nil; utterance = nil; capture.cancel(); level = 0
  }
  private func audioURL(_ id: UUID) -> URL { directory!.appendingPathComponent(id.uuidString + ".m4a") }
  private func savePending() throws {
    guard let pending, let directory else { return }
    try JSONEncoder().encode(pending).write(to: directory.appendingPathComponent("pending.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  private func saveCancellations() throws {
    guard let directory else { throw NotebookTransportError.disconnected }
    try JSONEncoder().encode(cancellations).write(to: directory.appendingPathComponent("cancelled.json"),
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  private func clearRecording() {
    if let pending, directory != nil { try? FileManager.default.removeItem(at: audioURL(pending.id)) }
    if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("pending.json")) }
    pending = nil
  }
  private func query(_ query: NotebookDictationQuery, capture: Pending) async throws -> NotebookDictationState {
    try Task.checkCancellation()
    guard let chat, chat.computerID == capture.computer, chat.threadID == capture.thread else {
      throw NotebookPersistenceQueue.Failure(message: "Запись относится к другому чату. Вернитесь в исходный чат для распознавания.")
    }
    guard case .dictation(let state) = try await chat.directQuery(.dictation(query)), state.id == capture.id, state.isValid else {
      throw NotebookTransportError.invalidAcknowledgement
    }
    try Task.checkCancellation(); return state
  }
  private func recognize(epoch: UUID, retryFailed: Bool) async {
    guard let capture = pending, let chat else { return }
    phase = .transcribing; error = nil; progress = 0
    do {
      if capture.transcript == nil {
        let url = audioURL(capture.id)
        let bytes = try await Task.detached(priority: .utility) {
          let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
          guard let size = attributes[.size] as? NSNumber, (1...NotebookDictationRecording.maximumBytes).contains(size.intValue) else {
            throw NotebookPersistenceQueue.Failure(message: "Сохранённая запись пуста или превышает допустимый размер.")
          }
          return try Data(contentsOf: url)
        }.value
        try Task.checkCancellation()
        let metadata = NotebookDictationRecording(id: capture.id, threadID: capture.thread, computerID: capture.computer,
          byteCount: bytes.count, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        guard metadata.isValid else { throw NotebookPersistenceQueue.Failure(message: "Не удалось прочитать сохранённую запись.") }
        var state = try await query(.prepare(metadata), capture: capture)
        if state.phase == .uploading {
          guard state.receivedBytes <= bytes.count else { throw NotebookTransportError.invalidAcknowledgement }
          var offset = state.receivedBytes
          while offset < bytes.count {
            let end = min(bytes.count, offset + NotebookDictationRecording.chunkBytes)
            state = try await query(.append(id: capture.id, offset: offset, bytes: bytes.subdata(in: offset..<end)), capture: capture)
            guard state.phase == .uploading, state.receivedBytes == end else { throw NotebookTransportError.invalidAcknowledgement }
            offset = end; progress = Double(offset) / Double(bytes.count)
          }
          state = try await query(.finish(capture.id), capture: capture)
        } else if state.phase == .failed, retryFailed { state = try await query(.retry(capture.id), capture: capture) }
        progress = 1
        let deadline = ContinuousClock.now + .seconds(150)
        while state.phase == .transcribing {
          guard .now < deadline else { throw NotebookPersistenceQueue.Failure(message: "Распознавание задерживается. Запись сохранена; можно проверить результат повторно.") }
          try await Task.sleep(for: .milliseconds(350))
          state = try await query(.status(capture.id), capture: capture)
        }
        guard state.phase == .completed, let text = state.text else {
          throw NotebookPersistenceQueue.Failure(message: state.error ?? "Распознавание не завершено. Запись сохранена.")
        }
        guard generation == epoch, pending?.id == capture.id else { return }
        pending?.transcript = capture.activation.map {
          NotebookWakeAddress.removingPrefix(from: text, language: $0.language, address: $0.address)
        } ?? text
        try savePending()
      }
      guard generation == epoch, let text = pending?.transcript else { return }
      phase = .inserting
      if capture.activation != nil,
        try await chat.hasSavedDictation(capture.id, thread: capture.thread, computer: capture.computer, text: text) {
        // The outbox is authoritative after a crash between saving the job and
        // retiring its audio. Never insert or enqueue that request a second time.
        clearRecording(); phase = .idle; submitAddressed = nil; resumeActivation(); return
      }
      if let submitAddressed {
        if !text.isEmpty, !(await submitAddressed(capture, text)) {
          throw NotebookPersistenceQueue.Failure(message: "Просьба не сохранена в чате. Запись оставлена; повтор откроет текст для проверки.")
        }
        guard generation == epoch else { return }
        self.submitAddressed = nil; clearRecording(); phase = .idle; error = nil; progress = 0
        resumeActivation(); return
      }
      if !text.isEmpty { try await chat.insertDictation(text, id: capture.id, thread: capture.thread, computer: capture.computer) }
      guard generation == epoch else { return }
      let send = sendAfterInsertion; sendAfterInsertion = nil
      clearRecording(); phase = .idle; error = nil; progress = 0
      if let send { send() } else { revealDraft(); resumeActivation() }
    } catch {
      guard generation == epoch, !Task.isCancelled else { return }
      disableActivation(); submitAddressed = nil; sendAfterInsertion = nil; phase = .failed; self.error = error.localizedDescription; revealDraft()
    }
  }
  private func captureFinished(epoch: UUID, success: Bool) {
    guard generation == epoch, phase == .recording || phase == .finishing else { return }
    operation?.cancel(); releaseMicrophone()
    guard success else {
      disableActivation(); submitAddressed = nil; sendAfterInsertion = nil; phase = .failed
      error = "Запись прервалась. Сохранённое аудио можно попробовать распознать повторно."; revealDraft(); return
    }
    operation = Task { [weak self] in await self?.recognize(epoch: epoch, retryFailed: false) }
  }
  /// Resume only after the existing outbox durably admits the addressed request.
  /// Neither a pending submission nor a task switch may open another microphone.
  func resumeActivation() {
    guard phase == .idle, activationEnabled, let chat,
      activationTarget?.thread == chat.threadID, activationTarget?.computer == chat.computerID else { return }
    operation = Task { [weak self] in await self?.arm() }
  }
}
