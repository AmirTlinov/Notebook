import AVFoundation
import CryptoKit
import Observation
import UIKit
import NotebookCore

/// The chat owns this controller, independent of either presentation. A private
/// recording survives network errors and app restarts until insertion or cancel.
@MainActor @Observable final class NotebookDictationController {
  enum Phase { case idle, authorizing, recording, finishing, transcribing, inserting, failed }
  struct Pending: Codable, Equatable {
    let id: UUID
    let thread: String
    let computer: UUID
    var transcript: String?
  }
  private(set) var phase = Phase.idle
  private(set) var error: String?
  private(set) var elapsed: TimeInterval = 0
  private(set) var level: Double = 0
  private(set) var levels: [Double] = []
  private(set) var reviewRequest: UUID?
  private(set) var progress: Double = 0
  private(set) var pending: Pending?
  var busy: Bool { phase != .idle || pending != nil }
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
    case .recording: "Диктовка · \(Int(elapsed) / 60):\(String(format: "%02d", Int(elapsed) % 60))"
    case .finishing: "Сохраняю запись…"
    case .transcribing: progress < 1 ? "Передаю запись в Codex…" : "Codex распознаёт речь…"
    case .inserting: "Сохраняю текст в черновике…"
    case .failed: error ?? "Запись сохранена. Повторите распознавание."
    }
  }
  @ObservationIgnored weak var chat: NotebookChatController?
  @ObservationIgnored var submissionInProgress: @MainActor () -> Bool = { false }
  @ObservationIgnored private var directory: URL?
  @ObservationIgnored private let capture: any NotebookDictationCapture
  @ObservationIgnored private var sendAfterInsertion: (@MainActor () -> Void)?
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var meter: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var cancellations: [String: UUID] = [:]

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
        Task { @MainActor [weak self] in if self?.recording == true { self?.finish() } }
      }
    }
  }

  func begin() async {
    guard !busy else { return }
    error = nil
    guard let chat, let thread = chat.threadID, !chat.browsesChats else { error = "Выберите чат для диктовки."; return }
    guard chat.connected, let computer = chat.computerID, !chat.switchingComputer else { error = "Подключите Mac, чтобы начать диктовку."; return }
    guard !chat.saving, !submissionInProgress() else { error = "Дождитесь сохранения текущего сообщения и начните диктовку."; return }
    guard !chat.voice.capturing else { error = "Завершите голосовой разговор перед диктовкой."; return }
    guard directory != nil else { error = "Хранилище записи ещё не готово."; return }
    generation = UUID(); let epoch = generation; sendAfterInsertion = nil; reviewRequest = nil; levels = []
    phase = .authorizing
    do { try await finishCancellation(on: computer) }
    catch {
      guard generation == epoch else { return }
      phase = .idle; self.error = "Не удалось завершить отмену прежней диктовки на Mac. Повторите после восстановления связи."; return
    }
    guard generation == epoch else { return }
    do {
      let recording = Pending(id: UUID(), thread: thread, computer: computer)
      pending = recording; try savePending()
      try await capture.start(at: audioURL(recording.id)) { [weak self] success in
        self?.captureFinished(epoch: epoch, success: success)
      }
      guard generation == epoch else { return }
      phase = .recording; elapsed = 0; level = 0; progress = 0
      meter = Task { [weak self] in
        while !Task.isCancelled {
          guard let self, phase == .recording else { return }
          let sample = capture.sample(); elapsed = sample.elapsed; level = sample.level
          levels.append(level); if levels.count > 240 { levels.removeFirst(levels.count - 240) }
          do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
      }
    } catch {
      guard generation == epoch else { return }
      releaseMicrophone()
      if let pending, !FileManager.default.fileExists(atPath: audioURL(pending.id).path) { clearRecording() }
      phase = pending == nil ? .idle : .failed; self.error = error.localizedDescription
    }
  }
  func recoveryFailed() { phase = .idle; error = "Не удалось восстановить прежнюю запись диктовки. Сохранённые файлы оставлены на iPad." }
  func finish(sending: (@MainActor () -> Void)? = nil) {
    guard phase == .recording else { return }
    sendAfterInsertion = sending
    if sending == nil { revealDraft(focus: false) }
    elapsed = capture.sample().elapsed; phase = .finishing; meter?.cancel(); level = 0
    let epoch = generation
    operation = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let self, generation == epoch, phase == .finishing else { return }
      releaseMicrophone(); sendAfterInsertion = nil; phase = .failed
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
    sendAfterInsertion = nil; revealDraft(focus: false)
    operation?.cancel(); let epoch = generation
    operation = Task { [weak self] in await self?.recognize(epoch: epoch, retryFailed: true) }
  }
  func cancel() {
    guard phase != .inserting else { return }
    generation = UUID(); operation?.cancel(); operation = nil; sendAfterInsertion = nil
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
    generation = UUID(); operation?.cancel(); operation = nil; sendAfterInsertion = nil; releaseMicrophone()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
    if pending != nil { phase = .failed }
  }
  private func releaseMicrophone() {
    meter?.cancel(); meter = nil; capture.cancel(); level = 0
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
        pending?.transcript = text; try savePending()
      }
      guard generation == epoch, let text = pending?.transcript else { return }
      phase = .inserting
      try await chat.insertDictation(text, id: capture.id, thread: capture.thread, computer: capture.computer)
      guard generation == epoch else { return }
      let send = sendAfterInsertion; sendAfterInsertion = nil
      clearRecording(); phase = .idle; error = nil; progress = 0
      if let send { send() } else { revealDraft() }
    } catch {
      guard generation == epoch, !Task.isCancelled else { return }
      sendAfterInsertion = nil; phase = .failed; self.error = error.localizedDescription; revealDraft()
    }
  }
  private func captureFinished(epoch: UUID, success: Bool) {
    guard generation == epoch, phase == .recording || phase == .finishing else { return }
    operation?.cancel(); releaseMicrophone()
    guard success else {
      sendAfterInsertion = nil; phase = .failed
      error = "Запись прервалась. Сохранённое аудио можно попробовать распознать повторно."; revealDraft(); return
    }
    operation = Task { [weak self] in await self?.recognize(epoch: epoch, retryFailed: false) }
  }
}
