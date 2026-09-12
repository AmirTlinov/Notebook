#if os(iOS)
import Foundation
import Observation
import NotebookCore

/// A terminal is a view of a Mac-owned run. Mount/reconnect only reads its
/// existing ID; neither losing the view nor restoring it is a start command.
@MainActor @Observable final class NotebookRunController {
  private(set) var root: NotebookFileAddress?
  private(set) var record: NotebookRunRecord?
  var command = "" { didSet { persistCommand() } }
  private(set) var error: String?
  private(set) var busy = false
  private(set) var inputBlocked = false
  private(set) var columns = 80
  private(set) var rows = 24
  @ObservationIgnored weak var chat: NotebookChatController?
  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  @ObservationIgnored private var reading: Task<Void, Never>?
  @ObservationIgnored private var readerID: UUID?
  @ObservationIgnored private var inputTask: Task<Void, Never>?
  @ObservationIgnored private var pendingInput: [(UUID, Data)] = []
  private(set) var loadingCommand = false
  @ObservationIgnored private var resizing: Task<Void, Never>?
  init(persistence: NotebookPersistenceQueue) { self.persistence = persistence }

  var selectedRoot: NotebookFileAddress? {
    guard let chat, let computer = chat.computerID, let project = chat.selectedProject else { return nil }
    let document = chat.files.document?.address
    let preferred = chat.files.window.runRoot ?? (document?.project == project.id && document?.computer == computer ? document?.root : nil)
    guard let path = preferred.flatMap({ project.roots.contains($0) ? $0 : nil }) ?? project.roots.first else { return nil }
    return .init(computer: computer, project: project.id, root: path, path: "")
  }
  func attach(_ root: NotebookFileAddress, consume: @escaping @MainActor (NotebookRunOutput, Bool) async throws -> Void) -> UUID {
    detach()
    let id = UUID(); readerID = id; self.root = root; record = nil; inputBlocked = false; loadingCommand = true
    reading = Task { [weak self] in
      guard let self else { return }
      do {
        let saved = try await persistence.submit { try $0.runCommand(root: root) }
        guard readerID == id else { return }
        loadingCommand = true; command = saved; loadingCommand = false
      } catch { self.error = error.localizedDescription; loadingCommand = false }
      var runID: UUID?, cursor = "0", initial = true
      while readerID == id, !Task.isCancelled {
        var more = false
        if chat?.connected == true {
          do {
            guard case .run(let output) = try await chat?.directQuery(.run(.init(root: root, runID: runID, after: cursor))),
              readerID == id, !Task.isCancelled else { return }
            let reset = initial || runID != output.record?.id || output.lostPrefix
            try await consume(output, reset)
            guard readerID == id else { return }
            if runID != output.record?.id { inputBlocked = false }
            initial = false; runID = output.record?.id; cursor = output.after; record = output.record; more = output.more
          } catch { if readerID == id, !Task.isCancelled { self.error = error.localizedDescription } }
        }
        if !more { do { try await Task.sleep(for: .milliseconds(350)) } catch { break } }
      }
    }
    return id
  }
  func detach(_ id: UUID? = nil) {
    guard id == nil || readerID == id else { return }
    readerID = nil; reading?.cancel(); reading = nil; resizing?.cancel(); resizing = nil
    // Measured keyboard input already belongs to its run and still drains.
  }
  func stop() async { detach(); await inputTask?.value }
  private func persistCommand() {
    guard !loadingCommand, let root, command.utf8.count <= 8192 else { return }
    let value = command
    persistence.enqueue(owner: .runCommand(root.id), publishesChanges: false) { try $0.saveRunCommand(value, root: root); return false }
  }
  func start(restart: Bool = false) async {
    guard !busy, !loadingCommand, let root, let chat, root == selectedRoot else { return }
    let request = NotebookRunRequest(root: root, command: command, replacing: restart ? record?.id : nil, columns: columns, rows: rows)
    guard request.isValid else { error = "Введите команду длиной до 8 КиБ."; return }
    busy = true; defer { busy = false }
    do { try check(try await chat.sessionCommand(.startRun(request))); error = nil }
    catch { self.error = error.localizedDescription }
  }
  func stopRun() async {
    guard !busy, let id = record?.id, let chat else { return }
    busy = true; defer { busy = false }
    do { try check(try await chat.sessionCommand(.stopRun(id))); error = nil }
    catch { self.error = error.localizedDescription }
  }
  func input(_ bytes: Data) {
    guard chat?.connected == true, let record, record.isActive, !inputBlocked, !bytes.isEmpty else { return }
    guard bytes.count + pendingInput.reduce(0, { $0 + $1.1.count }) <= 8192 else { error = "Ввод превышает 8 КиБ. Вставьте текст меньшими частями."; return }
    if pendingInput.last?.0 == record.id { pendingInput[pendingInput.count - 1].1.append(bytes) }
    else { pendingInput.append((record.id, bytes)) }
    drainInput()
  }
  func continueInput() { inputBlocked = false; drainInput() }
  func unavailable(_ message: String) { error = message }
  private func drainInput() {
    guard inputTask == nil, !inputBlocked, !pendingInput.isEmpty else { return }
    inputTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(60))
      guard let self else { return }
      while !pendingInput.isEmpty {
        let (id, bytes) = pendingInput.removeFirst()
        do {
          guard let chat else { throw NotebookTransportError.disconnected }
          try check(try await chat.sessionCommand(.writeRun(id, bytes)))
        } catch {
          self.error = "Ввод не подтверждён; автоматически не повторяется. \(error.localizedDescription)"
          inputBlocked = true; break
        }
      }
      inputTask = nil
    }
  }
  func size(columns: Int, rows: Int) {
    guard (20...500).contains(columns), (4...200).contains(rows) else { return }
    self.columns = columns; self.rows = rows
    resizing?.cancel()
    guard let record, record.isActive else { return }
    let id = record.id
    resizing = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(100))
        guard let self, chat?.connected == true else { return }
        _ = try await chat?.directQuery(.resizeRun(id, columns: columns, rows: rows))
      } catch { }
    }
  }
  private func check(_ job: NotebookChatJob) throws {
    guard job.state == .accepted else { throw NotebookPersistenceQueue.Failure(message: job.error ?? "Команда сохранена; подтверждение Mac ещё не получено.") }
  }
}
#endif
