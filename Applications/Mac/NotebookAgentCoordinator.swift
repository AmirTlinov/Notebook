import Foundation
import Observation
import NotebookCore

/// The Mac schedules requests; the existing persistence queue owns every claim, chunk and final receipt.
@MainActor
@Observable
final class NotebookAgentCoordinator {
  private(set) var availability: NotebookAgentAvailability = .signInRequired
  private(set) var isCheckingAvailability = false
  private(set) var activeRequestID: UUID?
  private(set) var lastError: String?
  var isRunning: Bool { activeRequestID != nil }

  @ObservationIgnored private let executor: NotebookAgentExecutor
  @ObservationIgnored private let persistence: NotebookPersistenceQueue
  @ObservationIgnored private let actorID: UUID
  @ObservationIgnored private let render: @Sendable (AgentActionAuthority, UUID) async throws -> NotebookAgentToolResult
  @ObservationIgnored private var started = false
  @ObservationIgnored private var wantsWake = false
  @ObservationIgnored private var checksAvailability = false
  @ObservationIgnored private var wakeTask: Task<Void, Never>?
  @ObservationIgnored private var runTask: Task<Void, Never>?
  @ObservationIgnored private var flushTask: Task<Void, Never>?
  @ObservationIgnored private var active: Active?

  private struct Terminal {
    let status: AgentExecution.Status
    let error: String?
  }
  private final class Active {
    let authority: AgentActionAuthority
    let request: AgentRequest
    let question: String
    var response = NotebookAgentResponseBuffer()
    var flushing = false
    var finishingRun = false
    var cancelRequested = false
    var streamFailure: String?
    var terminal: Terminal?
    init(authority: AgentActionAuthority, request: AgentRequest, question: String) {
      self.authority = authority; self.request = request; self.question = question
    }
  }

  init(executor: NotebookAgentExecutor, persistence: NotebookPersistenceQueue, actorID: UUID,
       render: @escaping @Sendable (AgentActionAuthority, UUID) async throws -> NotebookAgentToolResult) {
    self.executor = executor; self.persistence = persistence; self.actorID = actorID; self.render = render
  }

  /// Called only after the model has opened its workspace and installed its one persistence owner.
  func start() async {
    guard !started else { return }
    started = true; checksAvailability = true
    storeDidCommit()
    await wakeTask?.value
  }

  /// The model calls this for committed request/stop/execution changes, not for every camera sample.
  func storeDidCommit() {
    guard started || active?.terminal != nil else { return }
    wantsWake = true
    guard wakeTask == nil else { return }
    wakeTask = Task { [weak self] in
      guard let self else { return }
      repeat {
        self.wantsWake = false
        let check = self.checksAvailability; self.checksAvailability = false
        await self.recoverOrStart(checkAvailability: check)
      } while self.wantsWake && !Task.isCancelled
      self.wakeTask = nil
    }
  }

  func refreshAvailability() async {
    isCheckingAvailability = true
    availability = await executor.availability()
    isCheckingAvailability = false
    if case .unavailable(let reason) = availability { lastError = Self.explanation(reason) }
    else { lastError = nil }
    if started { storeDidCommit() }
  }

  func signIn() async throws -> URL {
    try await executor.beginChatGPTLogin { [weak self] success in
      guard let self else { return }
      if success { await self.refreshAvailability() }
      else { await self.loginFailed() }
    }
  }

  private func loginFailed() {
    availability = .signInRequired
    lastError = "Вход в ChatGPT не завершён. Вопросы остаются в очереди и не исполняются без входа."
  }

  /// Quit waits for real cancellation and durable terminal state, not the interrupt RPC's empty response.
  func stop() async -> Bool {
    started = false; wantsWake = false
    await wakeTask?.value
    if let current = active, current.terminal == nil {
      current.cancelRequested = true
      _ = await executor.cancel(requestID: current.request.id)
    }
    await runTask?.value
    if active?.terminal != nil { await persistTerminal() }
    await executor.stop()
    return active == nil && persistence.failure == nil
  }

  private func recoverOrStart(checkAvailability: Bool) async {
    if let current = active {
      if current.terminal != nil { await persistTerminal(); return }
      do {
        let id = current.request.id
        let snapshot = try await persistence.submit { try $0.agentRequest(id, includesResponse: false) }
        guard active === current else { return }
        if snapshot?.stopRequested == true, !current.cancelRequested {
          current.cancelRequested = true
          Task { [executor] in _ = await executor.cancel(requestID: id) }
        }
      } catch { lastError = error.localizedDescription }
      return
    }
    guard started else { return }
    do {
      // At most sixteen immutable headers. Completed answers and unrelated contexts are never scanned.
      let pending = try await persistence.submit { try $0.pendingAgentRequests(limit: 16) }
      var queued: AgentRequest?
      for request in pending {
        guard started else { return }
        let id = request.id
        guard let snapshot = try await persistence.submit({ try $0.agentRequest(id, includesResponse: false) }) else { continue }
        if let execution = snapshot.execution {
          guard execution.status == .running else { continue }
          guard execution.stamp.actor == actorID else {
            lastError = "Этот вопрос принадлежит другому помощнику Mac. Повторный запуск запрещён."
            return
          }
          let authority = AgentActionAuthority(requestID: id, executionID: execution.executionID)
          _ = try await persistence.submit(publishesChanges: true) {
            try $0.finishAgentRequest(authority, status: .failed,
              error: "Предыдущее исполнение прервалось. Сохранённые изменения и части ответа сохранены; автоматического повтора нет.")
          }
          wantsWake = true
        } else if snapshot.stopRequested {
          // Claim records an already stopped question as stopped without starting any model turn.
          let actorID = actorID
          _ = try await persistence.submit(publishesChanges: true) { try $0.claimAgentRequest(id, actor: actorID) }
          wantsWake = true
        } else if queued == nil { queued = request }
      }
      if checkAvailability || queued != nil && availability != .ready {
        isCheckingAvailability = true
        availability = await executor.availability()
        isCheckingAvailability = false
        if case .unavailable(let reason) = availability { lastError = Self.explanation(reason) }
      }
      guard started, availability == .ready, let queued else { return }
      let actorID = actorID
      // The transactional CAS and addressed frozen question read share one accepted writer position.
      let prepared: (AgentActionAuthority, AgentRequest, String)? = try await persistence.submit(publishesChanges: true) { store in
        guard let snapshot = try store.agentRequest(queued.id, includesResponse: false), snapshot.execution == nil else { return nil }
        let authority = try store.claimAgentRequest(queued.id, actor: actorID)
        if snapshot.stopRequested { return nil }
        return try (authority, snapshot.request, store.agentQuestion(authority))
      }
      guard let (authority, request, question) = prepared else { wantsWake = true; return }
      let current = Active(authority: authority, request: request, question: question)
      active = current; activeRequestID = request.id; lastError = nil
      if !started { current.cancelRequested = true }
      runTask = Task { [weak self] in await self?.execute(authority) }
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func execute(_ authority: AgentActionAuthority) async {
    guard let current = active, current.authority == authority else { return }
    let result: NotebookAgentCompletion
    if !started || current.cancelRequested {
      result = .init(requestID: authority.requestID, status: .interrupted, answer: "", failure: .interrupted)
    } else {
      do {
        let context = try JSONValue.encode(current.request)
        result = await executor.run(requestID: authority.requestID, prompt: current.question, context: context,
          tools: Self.tools(for: current.request.grant.mode),
          onEvent: { [weak self] in await self?.event($0, authority: authority) },
          callTool: { [weak self] call in
            guard let self else { throw NotebookAgentFailure.interrupted }
            return try await self.tool(call, authority: authority)
          })
      } catch { result = .init(requestID: authority.requestID, status: .failed, answer: "", failure: .invalidRequest) }
    }
    guard active === current else { return }
    current.finishingRun = true
    if let pendingFlush = flushTask { pendingFlush.cancel(); await pendingFlush.value }
    flushTask = nil
    await flush(authority, all: true)
    guard active === current else { return }
    let status: AgentExecution.Status
    if current.streamFailure != nil { status = .failed }
    else {
      switch result.status {
      case .completed: status = .completed
      case .interrupted: status = .stopped
      case .failed, .unavailable: status = .failed
      }
    }
    current.terminal = Terminal(status: status, error: current.streamFailure ?? result.failure.map(Self.explanation))
    await persistTerminal()
    runTask = nil
    if started { storeDidCommit() }
  }

  private func event(_ event: NotebookAgentEvent, authority: AgentActionAuthority) async {
    guard let current = active, current.authority == authority, current.terminal == nil else { return }
    guard case .textDelta(let text) = event, !current.cancelRequested else { return }
    do { try current.response.append(text) }
    catch {
      current.streamFailure = "Ответ превысил ограниченный объём. Сохранённые части оставлены в вопросе."
      current.cancelRequested = true
      Task { [executor] in _ = await executor.cancel(requestID: authority.requestID) }
      return
    }
    if current.response.pendingBytes >= 8192 { await flush(authority, all: false) }
    else { scheduleFlush(authority) }
  }

  private func scheduleFlush(_ authority: AgentActionAuthority) {
    guard flushTask == nil, let current = active, current.authority == authority,
          !current.finishingRun, current.streamFailure == nil, current.response.pendingBytes > 0 else { return }
    flushTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self else { return }
      await self.flush(authority, all: false)
      self.flushTask = nil
      self.scheduleFlush(authority)
    }
  }

  private func flush(_ authority: AgentActionAuthority, all: Bool) async {
    guard let current = active, current.authority == authority else { return }
    // Completion joins the timer task before entering this method; an accepted chunk cannot be overtaken.
    guard !current.flushing, current.streamFailure == nil else { return }
    current.flushing = true
    defer { current.flushing = false }
    do {
      repeat {
        guard let chunk = current.response.next() else { break }
        try await persistence.submit(publishesChanges: true) {
          try $0.appendAgentResponse(authority, sequence: chunk.sequence, text: chunk.text)
        }
        try current.response.acknowledge(chunk)
      } while all || current.response.pendingBytes >= 8192
    } catch {
      current.streamFailure = "Не удалось сохранить очередную часть ответа: \(error.localizedDescription)"
      current.cancelRequested = true; lastError = current.streamFailure
      Task { [executor] in _ = await executor.cancel(requestID: authority.requestID) }
    }
  }

  private func tool(_ call: NotebookAgentToolCall, authority: AgentActionAuthority) async throws -> NotebookAgentToolResult {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while true {
      guard let current = active, current.authority == authority, !current.cancelRequested, current.terminal == nil, started else {
        throw NotebookAgentFailure.interrupted
      }
      do {
        // A stop intent is checked at the same queue fence immediately before admitting a new tool.
        let value: JSONValue = try await persistence.submit(publishesChanges: call.name == "apply") { store in
          guard try store.agentRequest(authority.requestID, includesResponse: false)?.stopRequested == false else {
            throw CollaborationError("request_stopping", "Человек остановил вопрос; новый ход не принят.")
          }
          if call.name == "render" {
            guard case .object(let arguments) = call.arguments, Set(arguments.keys) == ["referenceID"],
                  case .string(let text) = arguments["referenceID"], let id = UUID(uuidString: text) else {
              throw CollaborationError("grant_denied", "Изображение называет один закреплённый фрагмент.")
            }
            _ = try store.agentPinnedSource(authority, referenceID: id)
            return .string(id.uuidString)
          }
          return try NotebookCommandDispatcher(store: store).handleAgent(tool: call.name, arguments: call.arguments,
            callID: call.id, authority: authority)
        }
        if call.name == "render", case .string(let text) = value, let id = UUID(uuidString: text) {
          guard active === current, !current.cancelRequested else { throw NotebookAgentFailure.interrupted }
          return try await render(authority, id)
        }
        return .init(value: value)
      } catch let error as CollaborationError {
        if error.code == "input_active", ContinuousClock.now < deadline {
          // Wait outside the persistence worker, with the same stable callID and a cancellation fence.
          try await Task.sleep(for: .milliseconds(50))
          continue
        }
        return .init(value: .object(["status": .string("not_saved"), "error": try .encode(error), "callID": .string(call.id)]))
      }
    }
  }

  private func persistTerminal() async {
    guard let current = active, let terminal = current.terminal else { return }
    let authority = current.authority
    do {
      _ = try await persistence.submit(publishesChanges: true) {
        try $0.finishAgentRequest(authority, status: terminal.status, error: terminal.error)
      }
      if active === current { active = nil; activeRequestID = nil; lastError = terminal.error }
    } catch let error as CollaborationError where ["empty_response", "mutation_unconfirmed"].contains(error.code) {
      current.terminal = Terminal(status: .failed, error: error.message)
      await persistTerminal()
    } catch { lastError = "Завершение вопроса ещё не сохранено: \(error.localizedDescription)" }
  }

  static func tools(for mode: RequestGrant.Mode) -> [NotebookAgentTool] {
    let reference = JSONValue.object(["type": .string("string"), "format": .string("uuid")])
    var tools = [NotebookAgentTool(name: "read", description: "Read immutable request metadata with {} or one frozen, redacted selected source with referenceID. Does not read current selection or other owners.",
      inputSchema: .object(["type": .string("object"), "properties": .object(["referenceID": reference]), "additionalProperties": .bool(false)])),
      NotebookAgentTool(name: "render", description: "See the frozen PNG of exactly one selected reference. Use this image to read handwriting or a selected region. Never interprets a current view as the original image.",
      inputSchema: .object(["type": .string("object"), "properties": .object(["referenceID": reference]), "required": .array([.string("referenceID")]), "additionalProperties": .bool(false)]))]
    if mode == .change {
      let kinds = ["appendInkStroke", "insertElement", "updateElement", "setElementState", "removeElement", "reorderElements",
        "insertBlock", "updateBlock", "setBlockState", "removeBlock", "reorderBlocks", "setPreamble", "replaceDocument",
        "createNotebook", "createDocument", "createBoard", "renameItem", "moveItem", "stackItems"]
      let target = JSONValue.object(["type": .string("object"), "properties": .object([
        "kind": .object(["type": .string("string"), "enum": .array(["page", "document", "board", "cover", "workspace"].map(JSONValue.string))]),
        "id": reference, "boardID": reference]), "required": .array([.string("kind"), .string("id")]), "additionalProperties": .bool(false)])
      let operation = JSONValue.object(["type": .string("object"), "properties": .object([
        "kind": .object(["type": .string("string"), "enum": .array(kinds.map(JSONValue.string))]),
        "target": target, "id": .object(["type": .string("string")]),
        "values": .object(["type": .string("object"), "additionalProperties": .bool(true)])]),
        "required": .array([.string("kind"), .string("target"), .string("values")]), "additionalProperties": .bool(false)])
      tools.append(.init(name: "apply", description: "Save one complete reversible change within the selected grant. Supply summary and operations only; Notebook injects authority, stable action ID and causal expectations. Catalog/placement expansion is denied. Order for reorder operations belongs in values. A not_saved result is not a committed change.",
        inputSchema: .object(["type": .string("object"), "properties": .object([
          "summary": .object(["type": .string("string"), "minLength": .number(1), "maxLength": .number(4096)]),
          "operations": .object(["type": .string("array"), "items": operation, "minItems": .number(1), "maxItems": .number(64)])]),
          "required": .array([.string("summary"), .string("operations")]), "additionalProperties": .bool(false)])))
    }
    return tools
  }

  private static func explanation(_ failure: NotebookAgentFailure) -> String {
    switch failure {
    case .unsupportedRuntime, .unsupportedProfile: "Установленная версия помощника ещё не прошла проверку ограниченного доступа Notebook."
    case .signInRequired: "Для ответа войдите в ChatGPT через помощника Notebook на Mac."
    case .interrupted: "Вопрос остановлен. Уже сохранённые изменения остаются в истории."
    case .invalidImage: "Не удалось подтвердить PNG выбранного фрагмента; визуальное чтение не выполнено."
    case .responseLimit, .messageLimit, .toolLimit: "Ответ или инструмент превысил допустимый объём."
    case .transportTimeout: "Помощник не завершил ответ за отведённое время."
    default: "Помощник завершился без подтверждённого ответа. Сохранённые части и изменения не потеряны."
    }
  }
}

/// Unsaved text has one owner until the same bytes are acknowledged by the SQL writer.
struct NotebookAgentResponseBuffer {
  struct Chunk: Equatable, Sendable { let sequence: UInt64; let text: String }
  private var pending = ""
  private var offered: Chunk?
  private(set) var sequence: UInt64 = 0
  private var totalBytes = 0
  var pendingBytes: Int { pending.utf8.count }
  mutating func append(_ text: String) throws {
    guard totalBytes + text.utf8.count <= 1_048_576 else { throw NotebookAgentFailure.responseLimit }
    pending += text; totalBytes += text.utf8.count
  }
  mutating func next() -> Chunk? {
    if let offered { return offered }
    guard let text = NotebookAgentExecutor.textChunks(pending).first else { return nil }
    let chunk = Chunk(sequence: sequence + 1, text: text)
    offered = chunk
    return chunk
  }
  mutating func acknowledge(_ chunk: Chunk) throws {
    guard chunk.sequence == sequence + 1, chunk.sequence <= 2_048, let expected = offered,
      expected.text.utf8.elementsEqual(chunk.text.utf8), pending.utf8.starts(with: chunk.text.utf8) else {
      throw NotebookAgentFailure.protocolViolation
    }
    pending = String(decoding: pending.utf8.dropFirst(chunk.text.utf8.count), as: UTF8.self)
    sequence = chunk.sequence; offered = nil
  }
}
