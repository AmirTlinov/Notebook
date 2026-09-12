import Foundation
import NotebookCore
import NotebookCodex

protocol NotebookCodexProcessOwner: Sendable {
  func startProcess(id: UUID, request: NotebookRunRequest, publish: @escaping @Sendable (NotebookProcessEvent) async throws -> Void) async throws
  func writeProcess(id: UUID, data: Data) async throws
  func resizeProcess(id: UUID, columns: Int, rows: Int) async throws
  func stopProcess(id: UUID) async throws
}
extension CodexAppServer: NotebookCodexProcessOwner { }

/// Mac run admission and output belong to the existing SQLite queue. The
/// actual PTY remains owned by the same persistent Codex App Server connection.
@MainActor final class MacNotebookProjectRuns {
  private let persistence: NotebookPersistenceQueue
  private let executor: any NotebookCodexProcessOwner
  private let metadata: any NotebookCodexCatalogueOwner
  private let computer: UUID
  private let recovery: Task<Void, Error>
  private var executing = Set<UUID>()
  private var failedEvents: [UUID: String] = [:]
  init(persistence: NotebookPersistenceQueue, executor: any NotebookCodexProcessOwner, metadata: any NotebookCodexCatalogueOwner, computer: UUID) {
    self.persistence = persistence; self.executor = executor; self.metadata = metadata; self.computer = computer
    recovery = Task {
      try await persistence.submit { store in
        for run in try store.activeRuns() { try store.receiveRunEvent(run.id, .interrupted("Mac-помощник перезапущен. Прежний процесс не запускается повторно.")) }
      }
    }
  }
  func read(_ query: NotebookRunRead) async throws -> NotebookRunOutput {
    try await recovery.value; try await validate(query.root)
    for (id, message) in failedEvents {
      try await persistence.submit { try $0.receiveRunEvent(id, .interrupted(message)) }
      failedEvents.removeValue(forKey: id)
    }
    return try await persistence.submit { try $0.readRun(query) }
  }
  func resize(_ id: UUID, columns: Int, rows: Int) async throws {
    try await recovery.value
    guard let run = try await persistence.submit({ try $0.runRecord(id) }), run.isActive else { throw CodexBridgeError.invalidInput }
    try await validate(run.request.root)
    try await executor.resizeProcess(id: id, columns: columns, rows: rows)
  }
  private func consume(_ id: UUID, event: NotebookProcessEvent) async throws {
    let accepted = failedEvents[id].map(NotebookProcessEvent.interrupted) ?? event
    do {
      try await persistence.submit { try $0.receiveRunEvent(id, accepted) }
      failedEvents.removeValue(forKey: id)
    } catch {
      failedEvents[id] = "Не удалось сохранить вывод. Процесс остановлен без повторного запуска: \(error.localizedDescription)"
      throw error
    }
  }
  private func validate(_ root: NotebookFileAddress) async throws {
    guard root.isValid, root.path.isEmpty, root.computer == computer else { throw CodexBridgeError.invalidInput }
    let project = try await metadata.readProject(id: root.project)
    guard project.roots.contains(root.root) else { throw CodexBridgeError.invalidInput }
  }
  /// Small terminal inputs need not wait behind an unrelated model turn.
  /// They still use the same durable job states and never repeat an attempt.
  func receive(_ input: NotebookChatInput) async throws -> NotebookChatJob {
    try await recovery.value
    let job = try await persistence.submit { try $0.saveChatInput(input) }
    guard input.action.isRunCommand, !job.isTerminal, executing.insert(input.id).inserted else { return job }
    defer { executing.remove(input.id) }
    if job.state == .attempting || job.state == .uncertain {
      if case .startRun = input.action, try await persistence.submit({ try $0.runRecord(input.id) }) != nil {
        return try await persistence.submit { try $0.advanceChatJob(input.id, from: job.state, to: .accepted, result: .run(input.id)) }
      }
      if job.state == .attempting {
        return try await persistence.submit { try $0.advanceChatJob(input.id, from: .attempting, to: .uncertain, error: "Принятие терминального ввода неизвестно. Ввод не повторён.") }
      }
      return job
    }
    _ = try await persistence.submit { try $0.advanceChatJob(input.id, from: .saved, to: .attempting) }
    var dispatched = false
    do {
      let result: NotebookChatResult
      switch input.action {
      case .startRun(let request):
        try await validate(request.root)
        if let previousID = request.replacing {
          guard let previous = try await persistence.submit({ try $0.latestRun(root: request.root) }), previous.id == previousID else { throw CodexBridgeError.invalidInput }
          if previous.isActive { try await executor.stopProcess(id: previousID) }
        }
        let record = NotebookRunRecord(id: input.id, author: input.author, request: request)
        try await persistence.submit { try $0.admitRun(record) }
        dispatched = true
        let id = input.id
        do {
          try await executor.startProcess(id: id, request: request) { [weak self] event in
            guard let self else { throw CodexBridgeError.disconnected }
            try await self.consume(id, event: event)
          }
        } catch {
          try await persistence.submit { try $0.receiveRunEvent(id, .interrupted("Запуск не подтверждён: \(error.localizedDescription)")) }
        }
        result = .run(input.id)
      case .writeRun(let id, let data):
        guard let run = try await persistence.submit({ try $0.runRecord(id) }), run.isActive else { throw CodexBridgeError.invalidInput }
        try await validate(run.request.root); dispatched = true
        try await executor.writeProcess(id: id, data: data); result = .acknowledged
      case .stopRun(let id):
        guard let run = try await persistence.submit({ try $0.runRecord(id) }), run.request.root.computer == computer else { throw CodexBridgeError.invalidInput }
        // Revoking a project does not prevent stopping its already-owned child.
        if run.isActive { dispatched = true; try await executor.stopProcess(id: id) }
        result = .acknowledged
      default: throw CodexBridgeError.invalidInput
      }
      return try await persistence.submit { try $0.advanceChatJob(input.id, from: .attempting, to: .accepted, result: result) }
    } catch {
      let state: NotebookChatJob.State = dispatched ? .uncertain : .rejected
      let message = dispatched ? "Принятие команды неизвестно; она не повторена." : error.localizedDescription
      return try await persistence.submit { try $0.advanceChatJob(input.id, from: .attempting, to: state, error: message) }
    }
  }
}
