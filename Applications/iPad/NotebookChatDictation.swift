import AVFoundation
import Foundation
import Speech

/// The native capture pipeline owns audio and transcription, never the chat draft
/// or a model turn. Only the controller decides where a result may be written.
enum NotebookDictationUpdate: Sendable { case preparing, listening, text(String) }
protocol NotebookDictationInput: Sendable {
  func run(locale: String, update: @escaping @Sendable (NotebookDictationUpdate) async -> Void) async throws
  func finish() async
}

actor NotebookMicrophoneDictation: NotebookDictationInput {
  private var captureTask: Task<Void, Error>?
  private var finishing = false
  private var sessionID: UUID?

  func finish() { finishing = true; captureTask?.cancel() }

  func run(locale identifier: String, update: @escaping @Sendable (NotebookDictationUpdate) async -> Void) async throws {
    try Task.checkCancellation()
    guard sessionID == nil else { throw DictationError.alreadyRunning }
    let identity = UUID(); sessionID = identity
    defer { sessionID = nil }
    finishing = false
    await update(.preparing)
    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw DictationError.microphoneDenied }
    try checkActive()
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
      throw DictationError.unsupportedLanguage
    }
    let transcriber = DictationTranscriber(locale: locale, contentHints: [.shortForm],
      transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await installation.downloadAndInstall()
    }
    try checkActive()
    guard let microphone = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified) else { throw DictationError.noMicrophone }
    let provider = try await CaptureInputSequenceProvider.providerWithSession(from: microphone, compatibleWith: [transcriber])
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try checkActive()
    // This separately owned reader is deliberately not cancelled with capture:
    // finalization must deliver its last words before the draft is released.
    let results = Task {
      do {
        var transcript = AttributedString()
        for try await result in transcriber.results {
          if let range = transcript.rangeOfAudioTimeRangeAttributes(intersecting: result.range) {
            transcript.replaceSubrange(range, with: result.text)
          } else { transcript.append(result.text) }
          await update(.text(String(transcript.characters)))
        }
      } catch { finish(); throw error }
    }
    let analysis = Task {
      try checkActive()
      startCapture(provider.captureSession)
      await update(.listening)
      do {
        let end = try await analyzer.analyzeSequence(provider.analyzerInputs)
        stopCapture(provider.captureSession)
        if let end {
          // A fresh, awaited task shields finalization from capture cancellation.
          try await Task { try await analyzer.finalizeAndFinish(through: end) }.value
        } else { await analyzer.cancelAndFinishNow() }
      } catch {
        stopCapture(provider.captureSession); await analyzer.cancelAndFinishNow(); throw error
      }
    }
    captureTask = analysis
    let interruption = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
      object: provider.captureSession, queue: nil) { [weak self] _ in
        Task { await self?.finishIfCurrent(identity) }
      }
    defer { NotificationCenter.default.removeObserver(interruption) }
    do {
      try await analysis.value
      try await results.value
      captureTask = nil
    } catch {
      stopCapture(provider.captureSession); await analyzer.cancelAndFinishNow()
      results.cancel(); _ = await results.result; captureTask = nil
      throw error
    }
  }
  private func finishIfCurrent(_ identity: UUID) {
    guard sessionID == identity else { return }; finish()
  }
  // The provider and capture session remain in this actor's isolation region.
  // Synchronous capture lifecycle never runs on the main actor.
  private func startCapture(_ session: AVCaptureSession) { session.startRunning() }
  private func stopCapture(_ session: AVCaptureSession) { session.stopRunning() }
  private func checkActive() throws {
    try Task.checkCancellation()
    if finishing { throw CancellationError() }
  }
}

private enum DictationError: LocalizedError {
  case microphoneDenied, unsupportedLanguage, noMicrophone, alreadyRunning
  var errorDescription: String? {
    switch self {
    case .microphoneDenied: "Разрешите Notebook доступ к микрофону в настройках iPad."
    case .unsupportedLanguage: "Этот язык диктовки пока недоступен на устройстве. Выберите другой язык у микрофона."
    case .noMicrophone: "Микрофон недоступен."
    case .alreadyRunning: "Предыдущая диктовка ещё завершается."
    }
  }
}
