import Foundation
import NotebookCore
import NotebookCodex

protocol NotebookCodexVoiceOwner: Sendable {
  func startVoice(id: UUID, request: NotebookVoiceStart) async throws
  func stopVoice(id: UUID) async throws
  func voiceState(id: UUID) async -> NotebookVoiceState?
}
extension CodexAppServer: NotebookCodexVoiceOwner { }

/// The existing chat journal records attempts. A call without its original
/// App Server connection is ended, never recreated from its old SDP.
@MainActor final class MacNotebookVoice {
  let persistence: NotebookPersistenceQueue
  let executor: any NotebookCodexVoiceOwner
  private var executing = Set<UUID>()
  init(persistence: NotebookPersistenceQueue, executor: any NotebookCodexVoiceOwner) { self.persistence = persistence; self.executor = executor }
  func state(_ id: UUID, peer: UUID) async throws -> NotebookVoiceState {
    guard let job = try await persistence.submit({ try $0.chatJob(id) }), job.input.author == peer,
      case .startVoice(let request) = job.input.action else { throw CodexBridgeError.invalidInput }
    return await executor.voiceState(id: id) ?? .init(id: id, threadID: request.threadID, phase: .ended,
      error: job.error ?? "Прежнее голосовое соединение завершено. Автоматического звонка нет.")
  }
  func receive(_ input: NotebookChatInput) async throws -> NotebookChatJob {
    let job = try await persistence.submit { try $0.saveChatInput(input) }
    guard input.action.isVoiceCommand, !job.isTerminal, executing.insert(input.id).inserted else { return job }
    defer { executing.remove(input.id) }
    if job.state != .saved {
      let result: NotebookChatResult?
      switch input.action {
      case .startVoice:
        result = await executor.voiceState(id: input.id) != nil ? .voice(input.id) : nil
      case .stopVoice(let id):
        let value = try await state(id, peer: input.author)
        result = value.phase == .ended ? .acknowledged : nil
      default: result = nil
      }
      if let result { return try await persistence.submit { try $0.advanceChatJob(input.id, from: job.state, to: .accepted, result: result) } }
      if job.state == .attempting { return try await persistence.submit { try $0.advanceChatJob(input.id, from: .attempting, to: .uncertain, error: "Голосовая команда не повторена: её принятие неизвестно.") } }
      return job
    }
    _ = try await persistence.submit { try $0.advanceChatJob(input.id, from: .saved, to: .attempting) }
    do {
      let result: NotebookChatResult
      switch input.action {
      case .startVoice(let request): try await executor.startVoice(id: input.id, request: request); result = .voice(input.id)
      case .stopVoice(let id):
        _ = try await state(id, peer: input.author)
        try await executor.stopVoice(id: id); result = .acknowledged
      default: throw CodexBridgeError.invalidInput
      }
      return try await persistence.submit { try $0.advanceChatJob(input.id, from: .attempting, to: .accepted, result: result) }
    } catch {
      // An offer or stop is never resent after an ambiguous RPC outcome.
      let phase: NotebookChatJob.State = (error as? CodexBridgeError) == .acceptanceUnknown ? .uncertain : .rejected
      return try await persistence.submit { try $0.advanceChatJob(input.id, from: .attempting, to: phase, error: String(error.localizedDescription.prefix(2048))) }
    }
  }
}
