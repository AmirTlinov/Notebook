import AVFoundation
import UIKit
import NotebookCore

/// Audio acquisition is the replaceable device boundary. Dictation, recovery
/// and the user's stop/send decision remain with NotebookDictationController.
@MainActor protocol NotebookDictationCapture: AnyObject {
  func start(at url: URL, finished: @escaping @MainActor (Bool) -> Void) async throws
  func sample() -> (elapsed: TimeInterval, level: Double)
  func stop()
  func cancel()
}

@MainActor final class NotebookMicrophoneDictationCapture: NSObject, NotebookDictationCapture {
  private var recorder: AVAudioRecorder?
  private var completion: (@MainActor (Bool) -> Void)?
  private var generation = UUID()
  private var ownsSession = false

  func start(at url: URL, finished: @escaping @MainActor (Bool) -> Void) async throws {
    cancel(); let epoch = generation
    let allowed = await AVAudioApplication.requestRecordPermission()
    guard generation == epoch else { throw CancellationError() }
    guard allowed else { throw NotebookPersistenceQueue.Failure(message: "Разрешите Notebook доступ к микрофону в настройках iPad.") }
    guard UIApplication.shared.applicationState != .background else {
      throw NotebookPersistenceQueue.Failure(message: "Вернитесь в Notebook и начните диктовку.")
    }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
    try session.setActive(true); ownsSession = true
    let audio = try AVAudioRecorder(url: url, settings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
      AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
    audio.delegate = self; audio.isMeteringEnabled = true; recorder = audio; completion = finished
    guard audio.record(forDuration: NotebookDictationRecording.maximumDuration) else {
      throw NotebookPersistenceQueue.Failure(message: "Микрофон не начал запись.")
    }
  }
  func sample() -> (elapsed: TimeInterval, level: Double) {
    guard let recorder else { return (0, 0) }
    recorder.updateMeters()
    return (recorder.currentTime, min(1, max(0, (Double(recorder.averagePower(forChannel: 0)) + 55) / 55)))
  }
  func stop() { recorder?.stop() }
  func cancel() {
    generation = UUID(); completion = nil
    recorder?.delegate = nil; recorder?.stop(); recorder = nil
    if ownsSession {
      ownsSession = false
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }
  private func finished(_ id: ObjectIdentifier, success: Bool) {
    guard let recorder, ObjectIdentifier(recorder) == id else { return }
    let callback = completion; cancel(); callback?(success)
  }
}

extension NotebookMicrophoneDictationCapture: AVAudioRecorderDelegate {
  nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    let id = ObjectIdentifier(recorder)
    Task { @MainActor [weak self] in self?.finished(id, success: flag) }
  }
  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    let id = ObjectIdentifier(recorder)
    Task { @MainActor [weak self] in self?.finished(id, success: false) }
  }
}
