import Foundation
import NotebookCore

public enum CodexBridgeEvent: Sendable {
  case conversation(CodexConversation)
  case unavailable(CodexBridgeError)
}

/// The Mac's persistent client of Codex's executor. The server arbitrates the cross-process writer lease.
public actor CodexAppServer {
  public nonisolated let events: AsyncStream<CodexBridgeEvent>
  private let output: AsyncStream<CodexBridgeEvent>.Continuation
  private let installation: CodexDesktopInstallation
  private var rpc: CodexRPC?
  private var connection: Task<CodexRPC, Error>?
  private var generation = UUID()
  private var states: [String: CodexAppServerState] = [:]
  private var attaching: [String: Task<Void, Error>] = [:]
  private var starting: Set<String> = []
  private struct RunningProcess {
    let publish: @Sendable (NotebookProcessEvent) async throws -> Void
    var task: Task<Void, Never>?
    var probe: Task<Void, Never>?
    var running = false
  }
  private var voice: NotebookVoiceState?
  private var processes: [UUID: RunningProcess] = [:]
  private var selections: Set<String> = []

  public init(installation: CodexDesktopInstallation) {
    self.installation = installation
    let stream = AsyncStream<CodexBridgeEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
    events = stream.stream; output = stream.continuation
  }
  deinit {
    connection?.cancel(); output.finish()
    let rpc = rpc
    Task { await rpc?.stop() }
  }

  func session<T: Sendable>(_ body: @Sendable (CodexRPC) async throws -> T) async throws -> T {
    try await body(connect())
  }
  public func snapshot(threadID: String) -> CodexConversation? { states[threadID]?.view }

  public func attach(threadID: String) async throws {
    guard UUID(uuidString: threadID) != nil else { throw CodexBridgeError.invalidInput }
    if states[threadID]?.ready == true { selections.insert(threadID); return }
    if let task = attaching[threadID] { try await task.value; selections.insert(threadID); return }
    let epoch = generation
    let task = Task { try await self.load(threadID: threadID, epoch: epoch) }
    attaching[threadID] = task
    do {
      try await task.value
      guard epoch == generation else { throw CodexBridgeError.disconnected }
      attaching.removeValue(forKey: threadID); selections.insert(threadID)
    } catch {
      if epoch == generation { attaching.removeValue(forKey: threadID); states.removeValue(forKey: threadID) }
      throw error
    }
  }

  private func load(threadID: String, epoch: UUID) async throws {
    let rpc = try await connect()
    if states.count >= 9 {
      guard let idle = states.keys.sorted().first(where: { !selections.contains($0) && !(voice?.threadID == $0 && voice?.phase != .ended) && states[$0]?.view.busy == false && states[$0]?.requests.isEmpty == true }) else { throw CodexBridgeError.busy }
      _ = try await rpc.request("thread/unsubscribe", params: .object(["threadId": .string(idle)]))
      states.removeValue(forKey: idle)
    }
    // No settings overrides, stale-turn inference or force takeover. A foreign active writer is a refusal.
    states[threadID] = CodexAppServerState(threadID: threadID)
    let result = try await rpc.request("thread/resume", params: .object(["threadId": .string(threadID), "excludeTurns": .bool(true)]))
    guard epoch == generation, let thread = result["thread"], thread["id"] == .string(threadID),
      thread["canAcceptDirectInput"] == .bool(true) else { throw CodexBridgeError.externalOwnerUnavailable }
    if states[threadID]?.model == nil, let model = result["model"]?.string {
      states[threadID]?.model = .init(model: model, effort: result["reasoningEffort"]?.string)
    }
    states[threadID]?.cwd = result["cwd"]?.string
    states[threadID]?.access = CodexAccess(profileID: result["activePermissionProfile"]?["id"]?.string,
      approvalPolicy: result["approvalPolicy"] ?? .null, available: [])
    let modes = (try? await Self.availableAccess(rpc, cwd: result["cwd"]?.string)) ?? []
    guard epoch == generation, let currentAccess = states[threadID]?.access else { throw CodexBridgeError.disconnected }
    // A settings event received during the catalogue read is newer than resume.
    states[threadID]?.access = CodexAccess(profileID: currentAccess.profileID,
      approvalPolicy: currentAccess.approvalPolicy, available: modes)
    let history = try await history(threadID: threadID)
    let turns = try await rpc.request("thread/turns/list", params: .object([
      "threadId": .string(threadID), "limit": .number(1), "sortDirection": .string("desc"), "itemsView": .string("notLoaded")]))
    guard epoch == generation, var state = states[threadID], let rows = turns["data"]?.array, rows.count <= 1 else { throw CodexBridgeError.disconnected }
    try state.hydrate(thread: thread, history: history.messages, turns: rows)
    states[threadID] = state; output.yield(.conversation(state.view))
  }

  /// Removing a view neither unsubscribes an active task nor interrupts its turn.
  public func detach(threadID: String) { selections.remove(threadID) }

  public func activities(threadIDs: [String]) async throws -> [CodexTaskActivity] {
    guard threadIDs.count <= 8, Set(threadIDs).count == threadIDs.count,
      threadIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw CodexBridgeError.invalidInput }
    let rpc = try await connect()
    var rows: [CodexTaskActivity] = []
    for id in threadIDs {
      if let state = states[id] {
        rows.append(.init(id: id, status: !state.requests.isEmpty ? .waitingForInput : state.view.busy ? .running : state.ready ? .idle : .unavailable,
          summary: state.messages.last.map { String($0.text.prefix(240)) }))
      } else {
        // A catalogue read does not acquire a writer or load full history.
        let result = try await rpc.request("thread/read", params: .object(["threadId": .string(id), "includeTurns": .bool(false)]))
        let thread = result["thread"]
        rows.append(.init(id: id, status: thread?["status"]?["type"] == .string("active") ? .running : .unavailable,
          summary: thread?["preview"]?.string.map { String($0.prefix(240)) }))
      }
    }
    return rows
  }

  /// SQLite has already recorded the attempt. An unknown response never authorizes resending this input.
  public func send(threadID: String, clientMessageID: UUID, text: String, context: String? = nil, attachments: [CodexInputAttachment] = []) async throws -> String {
    try await submit(threadID: threadID, clientMessageID: clientMessageID, text: text, context: context, expectedTurnID: nil, attachments: attachments)
  }
  public func steer(threadID: String, turnID: String, clientMessageID: UUID, text: String, context: String? = nil, attachments: [CodexInputAttachment] = []) async throws -> String {
    try await submit(threadID: threadID, clientMessageID: clientMessageID, text: text, context: context, expectedTurnID: turnID, attachments: attachments)
  }
  private func submit(threadID: String, clientMessageID: UUID, text: String, context: String?, expectedTurnID: String?, attachments: [CodexInputAttachment]) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= CodexProtocol.messageLimit, (context?.utf8.count ?? 0) <= CodexProtocol.messageLimit else { throw CodexBridgeError.invalidInput }
    guard let rpc, let current = states[threadID]?.view, current.ready else { throw CodexBridgeError.unavailable }
    let messageID = clientMessageID.uuidString.lowercased()
    if let turn = current.acceptedMessages[messageID] { return turn }
    if let expectedTurnID {
      guard current.activeTurnID == expectedTurnID else { throw CodexBridgeError.staleTurn }
    } else if current.busy { throw CodexBridgeError.busy }
    guard current.requests.isEmpty, starting.insert(threadID).inserted else { throw CodexBridgeError.busy }
    defer { starting.remove(threadID) }
    var params: [String: JSONValue] = ["threadId": .string(threadID), "clientUserMessageId": .string(messageID), "input": .array(try Self.composerInput(text: text, attachments: attachments))]
    if let expectedTurnID { params["expectedTurnId"] = .string(expectedTurnID) }
    if let context { params["additionalContext"] = .object(["notebook": .object(["kind": .string("untrusted"), "value": .string(context)])]) }
    do {
      let result = try await rpc.request(expectedTurnID == nil ? "turn/start" : "turn/steer", params: .object(params))
      guard let turn = expectedTurnID == nil ? result["turn"]?["id"]?.string : result["turnId"]?.string,
        UUID(uuidString: turn) != nil else { throw CodexBridgeError.invalidResponse }
      return turn
    } catch { throw CodexBridgeError.acceptanceUnknown }
  }

  public func interrupt(threadID: String, turnID: String) async throws {
    guard let rpc, states[threadID]?.activeTurnID == turnID else { throw CodexBridgeError.staleTurn }
    _ = try await rpc.request("turn/interrupt", params: .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
  }

  public func respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision) async throws {
    guard let rpc, states[threadID]?.requests.contains(request) == true else { throw CodexBridgeError.staleRequest }
    let value = try Self.response(request: request, decision: decision), epoch = generation
    try await rpc.respond(id: request.nativeID, result: value)
    let deadline = ContinuousClock.now.advanced(by: .seconds(12))
    while states[threadID]?.requests.contains(request) == true {
      guard epoch == generation, .now < deadline else { throw CodexBridgeError.acceptanceUnknown }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard epoch == generation else { throw CodexBridgeError.acceptanceUnknown }
  }

  public func setAccess(threadID: String, mode: CodexAccessMode) async throws {
    guard let rpc, let current = states[threadID], current.ready else { throw CodexBridgeError.unavailable }
    guard try await Self.availableAccess(rpc, cwd: current.cwd).contains(mode) else { throw CodexBridgeError.invalidInput }
    let epoch = generation
    _ = try await rpc.request("thread/settings/update", params: .object([
      "threadId": .string(threadID), "permissions": .string(mode.rawValue), "approvalPolicy": .string(mode.approvalPolicy)]))
    let deadline = ContinuousClock.now + .seconds(12)
    while states[threadID]?.access?.mode != mode {
      guard generation == epoch, .now < deadline else { throw CodexBridgeError.acceptanceUnknown }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard generation == epoch else { throw CodexBridgeError.acceptanceUnknown }
  }

  public func setModel(threadID: String, selection: CodexModelSelection) async throws {
    guard let rpc, states[threadID]?.ready == true else { throw CodexBridgeError.unavailable }
    guard selection.isValid, let option = try await Self.models(rpc).first(where: { $0.id == selection.model }),
      let effort = selection.effort, option.efforts.contains(effort) else { throw CodexBridgeError.invalidInput }
    let epoch = generation
    _ = try await rpc.request("thread/settings/update", params: .object([
      "threadId": .string(threadID), "model": .string(selection.model), "effort": .string(effort)]))
    let deadline = ContinuousClock.now + .seconds(12)
    while states[threadID]?.model != selection {
      guard generation == epoch, .now < deadline else { throw CodexBridgeError.acceptanceUnknown }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard generation == epoch else { throw CodexBridgeError.acceptanceUnknown }
  }

  public func compact(threadID: String) async throws {
    guard let rpc, let state = states[threadID], state.ready else { throw CodexBridgeError.unavailable }
    guard !state.view.busy, state.requests.isEmpty else { throw CodexBridgeError.busy }
    _ = try await rpc.request("thread/compact/start", params: .object(["threadId": .string(threadID)]))
  }

  static func response(request: CodexUserRequest, decision: CodexUserDecision) throws -> JSONValue {
    if [.allowOnce, .allowSession, .allowAlways, .decline].contains(decision), !request.approvalDecisions.contains(decision) {
      throw CodexBridgeError.unsupportedRequest
    }
    switch (request.method, decision) {
    case ("item/commandExecution/requestApproval", .allowOnce), ("item/commandExecution/requestApproval", .decline),
      ("item/commandExecution/requestApproval", .allowSession), ("item/fileChange/requestApproval", .allowSession),
      ("item/fileChange/requestApproval", .allowOnce), ("item/fileChange/requestApproval", .decline):
      return .object(["decision": .string(decision == .allowSession ? "acceptForSession" : decision == .allowOnce ? "accept" : "decline")])
    case ("item/permissions/requestApproval", .allowOnce), ("item/permissions/requestApproval", .allowSession), ("item/permissions/requestApproval", .decline):
      guard let requested = request.parameters["permissions"], requested.object != nil else { throw CodexBridgeError.invalidResponse }
      return .object(["permissions": decision == .decline ? .object([:]) : requested, "scope": .string(decision == .allowSession ? "session" : "turn")])
    case ("mcpServer/elicitation/request", .allowOnce), ("mcpServer/elicitation/request", .allowSession),
      ("mcpServer/elicitation/request", .allowAlways), ("mcpServer/elicitation/request", .decline):
      var reply: [String: JSONValue] = ["action": .string(decision == .decline ? "decline" : "accept"),
        "content": decision == .decline ? .null : .object([:])]
      if decision == .allowSession || decision == .allowAlways { reply["_meta"] = .object(["persist": .string(decision == .allowAlways ? "always" : "session")]) }
      return .object(reply)
    case ("item/tool/requestUserInput", .answers(let answers)):
      guard let questions = request.parameters["questions"]?.array,
        answers.count <= 16, Set(answers.keys).isSubset(of: Set(questions.compactMap { $0["id"]?.string })),
        answers.values.allSatisfy({ $0.count <= 16 && $0.allSatisfy({ $0.utf8.count <= 8192 }) }) else { throw CodexBridgeError.invalidInput }
      return .object(["answers": .object(answers.mapValues { .object(["answers": .array($0.map(JSONValue.string))]) })])
    case ("mcpServer/elicitation/request", .elicitation(let response)):
      guard ["accept", "decline", "cancel"].contains(response["action"]?.string ?? ""), try JSONEncoder().encode(response).count <= 32_768 else { throw CodexBridgeError.invalidInput }
      return response
    default: throw CodexBridgeError.unsupportedRequest
    }
  }

  public func close() async {
    if let current = voice, current.phase != .ended { try? await stopVoice(id: current.id) }
    generation = UUID()
    if voice?.isActive == true { voice?.phase = .failed; voice?.sdp = nil; voice?.error = "Mac отключён. Голос не возобновляется автоматически." }
    let rpc = self.rpc; self.rpc = nil
    connection?.cancel(); connection = nil
    for task in attaching.values { task.cancel() }; attaching.removeAll()
    states.removeAll(); selections.removeAll()
    await rpc?.stop()
    await interruptProcesses()
  }

  public func voiceState(id: UUID) -> NotebookVoiceState? { voice?.id == id ? voice : nil }

  public func startVoice(id: UUID, request: NotebookVoiceStart) async throws {
    guard request.isValid, voice == nil || voice?.phase == .ended else { throw CodexBridgeError.busy }
    voice = .init(id: id, threadID: request.threadID)
    var dispatched = false
    do {
      try await attach(threadID: request.threadID)
      guard let rpc else { throw CodexBridgeError.disconnected }
      let account = try await rpc.request("account/read", params: .object(["refreshToken": .bool(false)]))
      guard account["account"]?["type"] == .string("chatgpt") else { throw CodexBridgeError.signInRequired }
      guard voice?.id == id, voice?.phase == .starting else { throw CodexBridgeError.disconnected }
      dispatched = true
      _ = try await rpc.request("thread/realtime/start", params: .object([
        "threadId": .string(request.threadID), "realtimeSessionId": .string(id.uuidString.lowercased()),
        "transport": .object(["type": .string("webrtc"), "sdp": .string(request.sdp)]),
        "outputModality": .string("audio"), "version": .string("v3"),
        "clientManagedHandoffs": .bool(false), "flushTranscriptTailOnSessionEnd": .bool(false)]))
    } catch {
      if voice?.id == id { voice?.phase = dispatched ? .failed : .ended; voice?.error = "Начало разговора не подтверждено. Повторного вызова нет." }
      throw dispatched ? CodexBridgeError.acceptanceUnknown : error
    }
  }
  public func stopVoice(id: UUID) async throws {
    guard let current = voice, current.id == id, current.phase != .ended else { return }
    guard let rpc else { throw CodexBridgeError.disconnected }
    voice?.phase = .ending
    _ = try await rpc.request("thread/realtime/stop", params: .object(["threadId": .string(current.threadID)]))
    let deadline = ContinuousClock.now + .seconds(5)
    while voice?.id == id, voice?.phase == .ending, .now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    guard voice?.id == id, voice?.isActive == false else { throw CodexBridgeError.acceptanceUnknown }
  }
  private func receiveVoice(_ frame: JSONValue) throws -> Bool {
    guard let method = frame["method"]?.string, method.hasPrefix("thread/realtime/") else { return false }
    guard let params = frame["params"], params["threadId"] == voice.map({ .string($0.threadID) }), voice?.phase != .ended else { return true }
    switch method {
    case "thread/realtime/started":
      guard params["realtimeSessionId"] == voice.map({ .string($0.id.uuidString.lowercased()) }) else { throw CodexBridgeError.invalidResponse }
    case "thread/realtime/sdp":
      guard let sdp = params["sdp"]?.string, sdp.hasPrefix("v=0"), sdp.utf8.count <= 65_536 else { throw CodexBridgeError.invalidResponse }
      voice?.sdp = sdp; voice?.phase = .active
    case "thread/realtime/transcript/done":
      guard let text = params["text"]?.string else { throw CodexBridgeError.invalidResponse }
      if params["role"] == .string("user") { voice?.userText = String(text.prefix(4096)) }
      else if params["role"] == .string("assistant") { voice?.assistantText = String(text.prefix(4096)) }
    case "thread/realtime/closed": voice?.phase = .ended; voice?.sdp = nil
    case "thread/realtime/error":
      voice?.phase = .failed; voice?.sdp = nil; voice?.error = String((params["message"]?.string ?? "Голосовое соединение прервано").prefix(2048))
    default: break // Audio stays on WebRTC; only typed complete transcripts enter the panel.
    }
    return true
  }

  /// The durable Mac run record is admitted before this adapter is called.
  /// A request remains pending until the actual PTY exits, not for 12 seconds.
  public func startProcess(id: UUID, request: NotebookRunRequest,
    publish: @escaping @Sendable (NotebookProcessEvent) async throws -> Void) async throws {
    guard request.isValid, processes[id] == nil, processes.count < 4 else { throw CodexBridgeError.invalidInput }
    let rpc = try await connect()
    processes[id] = .init(publish: publish)
    processes[id]?.task = Task { [weak self] in
      do {
        let result = try await rpc.request("command/exec", params: .object([
          "processId": .string(id.uuidString.lowercased()),
          "command": .array((request.command.map { ["/bin/zsh", "-lc", $0] } ?? ["/bin/zsh", "-il"]).map(JSONValue.string)),
          "env": .object(["TERM": .string("xterm-256color"), "TERM_PROGRAM": .string("Notebook")]),
          "cwd": .string(request.root.root), "tty": .bool(true), "disableTimeout": .bool(true), "disableOutputCap": .bool(true),
          "size": .object(["cols": .number(Double(request.columns)), "rows": .number(Double(request.rows))])]), timeout: nil)
        guard case .number(let code)? = result["exitCode"], code.isFinite, code.rounded() == code,
          code >= Double(Int32.min), code <= Double(Int32.max) else { throw CodexBridgeError.invalidResponse }
        await self?.finishProcess(id, event: .exited(Int(code)))
      } catch { await self?.finishProcess(id, event: .interrupted("Исполнитель прервал запуск: \(error.localizedDescription)")) }
    }
    processes[id]?.probe = Task { [weak self] in
      while !Task.isCancelled, await self?.processNeedsProbe(id) == true {
        do {
          try await Task.sleep(for: .milliseconds(100))
          try await self?.resizeProcess(id: id, columns: request.columns, rows: request.rows)
          await self?.markProcessRunning(id)
        } catch { if Task.isCancelled { return } }
      }
    }
  }
  private func processNeedsProbe(_ id: UUID) -> Bool { processes[id]?.running == false }
  private func markProcessRunning(_ id: UUID) async {
    guard processes[id]?.running == false, let publish = processes[id]?.publish else { return }
    processes[id]?.running = true
    do { try await publish(.running) } catch { Task { await self.stopFailedProcess(id) } }
  }
  private func finishProcess(_ id: UUID, event: NotebookProcessEvent) async {
    guard let process = processes.removeValue(forKey: id) else { return }
    process.probe?.cancel()
    try? await process.publish(event)
  }
  private func stopFailedProcess(_ id: UUID) async { try? await stopProcess(id: id) }
  public func writeProcess(id: UUID, data: Data) async throws {
    guard !data.isEmpty, data.count <= 8192, processes[id] != nil, let rpc else { throw CodexBridgeError.invalidInput }
    _ = try await rpc.request("command/exec/write", params: .object(["processId": .string(id.uuidString.lowercased()), "deltaBase64": .string(data.base64EncodedString())]))
  }
  public func resizeProcess(id: UUID, columns: Int, rows: Int) async throws {
    guard (20...500).contains(columns), (4...200).contains(rows), processes[id] != nil, let rpc else { throw CodexBridgeError.invalidInput }
    _ = try await rpc.request("command/exec/resize", params: .object(["processId": .string(id.uuidString.lowercased()), "size": .object(["cols": .number(Double(columns)), "rows": .number(Double(rows))])]))
    await markProcessRunning(id)
  }
  public func stopProcess(id: UUID) async throws {
    guard let task = processes[id]?.task else { return }
    guard let rpc else { throw CodexBridgeError.disconnected }
    _ = try await rpc.request("command/exec/terminate", params: .object(["processId": .string(id.uuidString.lowercased())]))
    await task.value
  }
  private func interruptProcesses() async {
    let previous = processes; processes.removeAll()
    for process in previous.values {
      process.probe?.cancel(); process.task?.cancel()
      try? await process.publish(.interrupted("Соединение с исполнителем прервано. Запуск не повторён."))
    }
  }

  private func connect() async throws -> CodexRPC {
    if let rpc { return rpc }
    if let connection { return try await connection.value }
    let installation = installation, epoch = generation
    let task = Task { [weak self] in
      try installation.validate()
      let channel = try CodexChannel.appServer(binary: installation.binary, directory: FileManager.default.homeDirectoryForCurrentUser)
      let rpc = CodexRPC(channel: channel)
      do {
        try await rpc.start(onEvent: { [weak self] frame in try await self?.receive(frame, epoch: epoch) },
          onDisconnect: { [weak self] error in await self?.disconnected(error, epoch: epoch) })
        return rpc
      } catch { await rpc.stop(); throw error }
    }
    connection = task
    do {
      let result = try await task.value
      guard generation == epoch else { await result.stop(); throw CodexBridgeError.disconnected }
      rpc = result; connection = nil; return result
    } catch { connection = nil; throw error }
  }

  private func receive(_ frame: JSONValue, epoch: UUID) async throws {
    guard epoch == generation else { return }
    if try receiveVoice(frame) { return }
    if frame["method"]?.string == "command/exec/outputDelta" {
      guard let id = frame["params"]?["processId"]?.string.flatMap(UUID.init(uuidString:)),
        let encoded = frame["params"]?["deltaBase64"]?.string, let bytes = Data(base64Encoded: encoded), bytes.count <= 131_072 else { throw CodexBridgeError.invalidFrame }
      if let publish = processes[id]?.publish {
        processes[id]?.running = true
        // Await durable consumption: a noisy child backpressures its own pipe,
        // never an unbounded stream of Swift output values or the iPad camera.
        do { try await publish(.output(bytes)) }
        catch { Task { await self.stopFailedProcess(id) } }
      }
      return
    }
    guard let id = frame["params"]?["threadId"]?.string, var state = states[id] else {
      if frame["id"] != nil { throw CodexBridgeError.unsupportedRequest }; return
    }
    if try state.accept(frame) { states[id] = state; output.yield(.conversation(state.view)) }
  }
  private func disconnected(_ error: CodexBridgeError, epoch: UUID) async {
    guard generation == epoch else { return }
    if voice?.isActive == true { voice?.phase = .failed; voice?.sdp = nil; voice?.error = "Соединение с Codex прервано. Голос не возобновляется автоматически." }
    generation = UUID(); rpc = nil; states.removeAll(); selections.removeAll()
    output.yield(.unavailable(error))
    await interruptProcesses()
  }
}
