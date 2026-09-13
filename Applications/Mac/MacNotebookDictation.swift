import Foundation
import CryptoKit
import NotebookCore
import NotebookCodex

protocol NotebookCodexDictationOwner: Sendable {
  func transcribeDictation(_ audio: Data) async throws -> String
}
extension CodexAppServer: NotebookCodexDictationOwner { }

/// One bounded upload and transcription per peer. Repeated transport packets
/// acknowledge the same bytes; only an explicit retry repeats a failed request.
@MainActor final class MacNotebookDictation {
  private final class Recording {
    let peer: UUID
    let metadata: NotebookDictationRecording
    var audio = Data()
    var state: NotebookDictationState
    var task: Task<Void, Never>?
    var touched = Date()
    init(peer: UUID, metadata: NotebookDictationRecording) {
      self.peer = peer; self.metadata = metadata; state = .init(id: metadata.id)
    }
  }
  private let executor: any NotebookCodexDictationOwner
  private let computer: UUID
  private var recordings: [UUID: Recording] = [:]
  init(executor: any NotebookCodexDictationOwner, computer: UUID) { self.executor = executor; self.computer = computer }
  func stop() { for recording in recordings.values { recording.task?.cancel() }; recordings.removeAll() }

  func receive(_ query: NotebookDictationQuery, peer: UUID) throws -> NotebookDictationState {
    guard query.isValid else { throw CodexBridgeError.invalidInput }
    for (id, recording) in recordings where Date().timeIntervalSince(recording.touched) > 900 {
      recording.task?.cancel(); recordings.removeValue(forKey: id)
    }
    if case .prepare(let metadata) = query {
      guard metadata.computerID == computer else { throw CodexBridgeError.invalidInput }
      if let recording = recordings[metadata.id] {
        guard recording.peer == peer, recording.metadata == metadata else { throw CodexBridgeError.invalidInput }
        recording.touched = Date(); return recording.state
      }
      // A new capture replaces only this peer's terminal result, never another
      // device's recording or an in-progress transcription.
      for (id, old) in recordings where old.peer == peer {
        guard old.state.phase == .completed || old.state.phase == .cancelled else { throw CodexBridgeError.busy }
        recordings.removeValue(forKey: id)
      }
      guard recordings.count < 4 else { throw CodexBridgeError.busy }
      let recording = Recording(peer: peer, metadata: metadata); recordings[metadata.id] = recording
      return recording.state
    }
    guard let recording = recordings[query.id] else {
      if case .cancel = query { return .init(id: query.id, phase: .cancelled) }
      throw CodexBridgeError.invalidInput
    }
    guard recording.peer == peer else { throw CodexBridgeError.invalidInput }
    recording.touched = Date()
    switch query {
    case .append(_, let offset, let bytes):
      guard recording.state.phase == .uploading, offset <= recording.audio.count,
        offset + bytes.count <= recording.metadata.byteCount else { throw CodexBridgeError.invalidInput }
      if offset < recording.audio.count {
        guard offset + bytes.count <= recording.audio.count,
          recording.audio.subdata(in: offset..<offset + bytes.count) == bytes else { throw CodexBridgeError.invalidInput }
      } else { recording.audio.append(bytes); recording.state.receivedBytes = recording.audio.count }
    case .finish:
      if recording.state.phase == .uploading {
        guard recording.audio.count == recording.metadata.byteCount,
          SHA256.hash(data: recording.audio).map({ String(format: "%02x", $0) }).joined() == recording.metadata.sha256 else { throw CodexBridgeError.invalidInput }
        transcribe(recording)
      }
    case .retry:
      if recording.state.phase == .failed { transcribe(recording) }
    case .cancel:
      recording.task?.cancel(); recording.task = nil; recording.audio.removeAll()
      recording.state = .init(id: query.id, phase: .cancelled)
    case .status: break
    case .prepare: throw CodexBridgeError.invalidInput
    }
    return recording.state
  }
  private func transcribe(_ recording: Recording) {
    recording.state.phase = .transcribing; recording.state.error = nil
    let executor = executor, audio = recording.audio
    recording.task = Task { [weak recording] in
      do {
        let text = try await executor.transcribeDictation(audio)
        try Task.checkCancellation()
        guard let recording else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768 else { throw CodexBridgeError.invalidResponse }
        recording.state.text = text; recording.state.phase = .completed
        recording.audio.removeAll(); recording.task = nil; recording.touched = Date()
      } catch {
        guard !Task.isCancelled, let recording else { return }
        recording.state.phase = .failed
        recording.state.error = String(error.localizedDescription.prefix(1800)); recording.task = nil
      }
    }
  }
}
