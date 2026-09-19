import Foundation
import NotebookCore

/// One bounded mailbox per native process. The JSONL reader only deposits bytes;
/// it never waits for SQLite. At most four process owners retain these mailboxes.
actor CodexProcessOutput {
  static let byteLimit = 512 * 1024
  private let publish: @Sendable (NotebookProcessEvent) async throws -> Void
  private let stop: @Sendable () async -> Void
  private let completed: @Sendable () async -> Void
  private var chunks: [Data] = []
  private(set) var queuedBytes = 0
  private var runningPending = false
  private var runningSent = false
  private var terminal: NotebookProcessEvent?
  private var ending = false
  private var failure: String?
  private var drain: Task<Void, Never>?

  init(publish: @escaping @Sendable (NotebookProcessEvent) async throws -> Void,
    stop: @escaping @Sendable () async -> Void, completed: @escaping @Sendable () async -> Void) {
    self.publish = publish; self.stop = stop; self.completed = completed
  }
  func running() {
    guard !ending, !runningSent else { return }
    runningPending = true; schedule()
  }
  func append(_ bytes: Data) {
    guard !bytes.isEmpty, !ending, failure == nil else { return }
    guard queuedBytes + bytes.count <= Self.byteLimit else {
      fail("Вывод неполный: сохранение не успевает за процессом. Запрошена остановка процесса; повторного запуска нет.")
      return
    }
    // Include the currently publishing chunk in the byte budget.
    chunks.append(bytes); queuedBytes += bytes.count
    if !runningSent { runningPending = true }; schedule()
  }
  func finish(_ event: NotebookProcessEvent) {
    guard !ending else { return }
    ending = true; terminal = failure.map(NotebookProcessEvent.interrupted) ?? event; schedule()
  }
  func waitForDrain() async { await drain?.value }
  private func fail(_ message: String) {
    guard failure == nil else { return }
    failure = message
    if ending { terminal = .interrupted(message) }
    Task { await stop() }
  }
  private func schedule() {
    guard drain == nil else { return }
    drain = Task { await consume() }
  }
  private func consume() async {
    while true {
      if runningPending {
        runningPending = false; runningSent = true
        do { try await publish(.running) }
        catch { fail("Вывод неполный: не удалось сохранить состояние процесса. Запуск не повторён.") }
      } else if let bytes = chunks.first {
        do {
          try await publish(.output(bytes))
          chunks.removeFirst(); queuedBytes -= bytes.count
        } catch {
          // A failed commit is not replayed. Report the incomplete tail explicitly.
          chunks.removeAll(); queuedBytes = 0
          fail("Вывод неполный: ошибка сохранения. Запрошена остановка процесса; повторного запуска нет.")
        }
      } else if let event = terminal {
        terminal = nil
        try? await publish(event)
        drain = nil; await completed(); return
      } else { drain = nil; return }
    }
  }
}
