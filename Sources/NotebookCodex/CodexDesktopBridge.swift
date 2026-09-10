import Foundation
import NotebookCore

public enum CodexBridgeEvent: Sendable {
  case conversation(CodexConversation)
  case unavailable(CodexBridgeError)
}

public enum CodexUserDecision: Sendable {
  case allowOnce, decline
  case answers([String: [String]])
  case elicitation(JSONValue)
}

/// All model execution goes to the discovered desktop owner, with its settings unchanged.
public actor CodexDesktopBridge {
  public nonisolated let events: AsyncStream<CodexBridgeEvent>
  private let output: AsyncStream<CodexBridgeEvent>.Continuation
  private let installation: CodexDesktopInstallation
  private var rpc: CodexRPC?
  private var connection: Task<CodexRPC, Error>?
  private var generation = UUID()
  private var states: [String: CodexStreamState] = [:]
  private var conversations: [String: CodexConversation] = [:]
  private var resynchronizing: Set<String> = []
  private var starting: Set<String> = []

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

  public func snapshot(threadID: String) -> CodexConversation? { conversations[threadID] }

  public func attach(threadID: String) async throws {
    guard UUID(uuidString: threadID) != nil else { throw CodexBridgeError.invalidInput }
    let rpc = try await connect()
    let epoch = generation
    if states[threadID] != nil { return }
    guard states.count < 8 else { throw CodexBridgeError.historyLimit }
    let owner: String
    do { owner = try await rpc.discover(threadID: threadID) }
    catch CodexBridgeError.unavailable {
      try await installation.open(threadID: threadID)
      let deadline = ContinuousClock.now.advanced(by: .seconds(15))
      var found: String?
      while found == nil, .now < deadline {
        try await Task.sleep(for: .milliseconds(250))
        do { found = try await rpc.discover(threadID: threadID) }
        catch CodexBridgeError.unavailable { continue }
      }
      guard let found else { throw CodexBridgeError.unavailable }
      owner = found
    }
    guard epoch == generation else { throw CodexBridgeError.disconnected }
    if states[threadID] != nil { return }
    guard states.count < 8 else { throw CodexBridgeError.historyLimit }
    states[threadID] = CodexStreamState(threadID: threadID, owner: owner)
    do { try await rpc.follow(threadID: threadID, owner: owner, enabled: true) }
    catch {
      if epoch == generation { states.removeValue(forKey: threadID) }
      throw error
    }
  }

  /// Stop observing only. Collapsing the panel or switching tasks never interrupts an agent.
  public func detach(threadID: String) async {
    guard let state = states.removeValue(forKey: threadID) else { return }
    conversations.removeValue(forKey: threadID); resynchronizing.remove(threadID)
    try? await rpc?.follow(threadID: threadID, owner: state.owner, enabled: false)
  }

  /// Caller durably records "attempting" BEFORE this call. Any ambiguous failure must be reconciled,
  /// not retried. clientMessageID identifies the original user message across reconnects.
  public func send(threadID: String, clientMessageID: UUID, text: String, context: String? = nil) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= CodexDesktopProtocol.messageLimit,
      (context?.utf8.count ?? 0) <= CodexDesktopProtocol.messageLimit else { throw CodexBridgeError.invalidInput }
    guard let rpc, let state = states[threadID], let current = conversations[threadID], current.ready,
      !resynchronizing.contains(threadID) else { throw CodexBridgeError.unavailable }
    let messageID = clientMessageID.uuidString.lowercased()
    if let turn = current.acceptedMessages[messageID] { return turn }
    guard !current.busy, current.requests.isEmpty, !starting.contains(threadID) else { throw CodexBridgeError.busy }
    starting.insert(threadID); defer { starting.remove(threadID) }
    var request: [String: JSONValue] = ["threadId": .string(threadID), "clientUserMessageId": .string(messageID),
      "input": .array([.textInput(text)])]
    // Context is appended as untrusted app input, not injected developer instructions on an existing task.
    if let context {
      request["additionalContext"] = .object(["notebook": .object([
        "kind": .string("untrusted"), "value": .string(context)])])
    }
    do {
      let result = try await rpc.request("thread-follower-start-turn", params: .object([
        "conversationId": .string(threadID), "turnStart": .object([
          "request": .object(request), "context": .object(["inheritThreadSettings": .bool(true)])])]), owner: state.owner)
      guard let turnID = result["result"]?["turn"]?["id"]?.string, UUID(uuidString: turnID) != nil else {
        throw CodexBridgeError.invalidResponse
      }
      return turnID
    } catch { throw CodexBridgeError.acceptanceUnknown }
  }

  public func interrupt(threadID: String, turnID: String) async throws {
    guard let rpc, let state = states[threadID], let current = conversations[threadID],
      !resynchronizing.contains(threadID), current.activeTurnID == turnID else { throw CodexBridgeError.staleTurn }
    let result = try await rpc.request("thread-follower-interrupt-turn", params: .object([
      "conversationId": .string(threadID), "mode": .string("user-stop"), "expectedTurnId": .string(turnID)]), owner: state.owner)
    guard result["ok"] == .bool(true), result["interruptedTurnId"] == .string(turnID) || result["interruptedTurnId"] == .null else {
      throw CodexBridgeError.invalidResponse
    }
    // RPC acknowledgement is not a terminal-turn receipt. The stream must observe completion.
  }

  public func respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision) async throws {
    guard let rpc, let state = states[threadID], let current = conversations[threadID],
      !resynchronizing.contains(threadID), current.requests.contains(request) else { throw CodexBridgeError.staleRequest }
    let (method, field, value) = try Self.response(request: request, decision: decision)
    let result = try await rpc.request(method, params: .object([
      "conversationId": .string(threadID), "requestId": request.nativeID, field: value]), owner: state.owner)
    guard result["ok"] == .bool(true) else { throw CodexBridgeError.invalidResponse }
  }

  static func response(request: CodexUserRequest, decision: CodexUserDecision) throws -> (String, String, JSONValue) {
    switch (request.method, decision) {
    case ("item/commandExecution/requestApproval", .allowOnce), ("item/commandExecution/requestApproval", .decline):
      return ("thread-follower-command-approval-decision", "decision", .string(isAllow(decision) ? "accept" : "decline"))
    case ("item/fileChange/requestApproval", .allowOnce), ("item/fileChange/requestApproval", .decline):
      return ("thread-follower-file-approval-decision", "decision", .string(isAllow(decision) ? "accept" : "decline"))
    case ("item/permissions/requestApproval", .allowOnce), ("item/permissions/requestApproval", .decline):
      guard let requested = request.parameters["permissions"], requested.object != nil else { throw CodexBridgeError.invalidResponse }
      return ("thread-follower-permissions-request-approval-response", "response",
        .object(["permissions": isAllow(decision) ? requested : .object([:]), "scope": .string("turn")]))
    case ("item/tool/requestUserInput", .answers(let answers)):
      guard let questions = request.parameters["questions"]?.array,
        answers.count <= 16, Set(answers.keys).isSubset(of: Set(questions.compactMap { $0["id"]?.string })),
        answers.values.allSatisfy({ $0.count <= 16 && $0.allSatisfy({ $0.utf8.count <= 8192 }) }) else { throw CodexBridgeError.invalidInput }
      return ("thread-follower-submit-user-input", "response", .object(["answers": .object(answers.mapValues {
        .object(["answers": .array($0.map(JSONValue.string))])
      })]))
    case ("mcpServer/elicitation/request", .elicitation(let response)):
      guard ["accept", "decline", "cancel"].contains(response["action"]?.string ?? ""),
        try JSONEncoder().encode(response).count <= 32_768 else { throw CodexBridgeError.invalidInput }
      return ("thread-follower-submit-mcp-server-elicitation-response", "response", response)
    default: throw CodexBridgeError.unsupportedRequest
    }
  }

  private static func isAllow(_ decision: CodexUserDecision) -> Bool { if case .allowOnce = decision { true } else { false } }

  public func close() async {
    generation = UUID()
    let rpc = self.rpc; self.rpc = nil
    connection?.cancel(); connection = nil
    states.removeAll(); conversations.removeAll(); resynchronizing.removeAll()
    await rpc?.stop()
  }

  private func connect() async throws -> CodexRPC {
    if let rpc { return rpc }
    if let connection { return try await connection.value }
    let installation = installation, epoch = generation
    let task = Task { [weak self] in
      try installation.validate()
      try await installation.launch()
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while !FileManager.default.fileExists(atPath: installation.endpoint.path), .now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      let channel = try CodexChannel.connect(installation.endpoint)
      let rpc = CodexRPC(channel: channel, surface: .desktop)
      do {
        try await rpc.start(onBroadcast: { [weak self] frame in try await self?.receive(frame, epoch: epoch) },
          onDisconnect: { [weak self] error in await self?.disconnected(error, epoch: epoch) })
        return rpc
      } catch { await rpc.stop(); throw error }
    }
    connection = task
    do {
      let result = try await task.value
      guard generation == epoch else { await result.stop(); throw CodexBridgeError.disconnected }
      rpc = result; connection = nil
      return result
    } catch { connection = nil; throw error }
  }

  private func receive(_ frame: JSONValue, epoch: UUID) async throws {
    guard epoch == generation, let id = frame["params"]?["conversationId"]?.string, var state = states[id] else { return }
    if resynchronizing.contains(id), frame["params"]?["change"]?["type"] == .string("patches") { return }
    do {
      guard let view = try state.accept(frame) else { return }
      states[id] = state; conversations[id] = view; resynchronizing.remove(id)
      output.yield(.conversation(view))
    } catch CodexBridgeError.revisionGap {
      resynchronizing.insert(id)
      states[id] = CodexStreamState(threadID: id, owner: state.owner)
      try await rpc?.follow(threadID: id, owner: state.owner, enabled: false)
      try await rpc?.follow(threadID: id, owner: state.owner, enabled: true)
    }
  }

  private func disconnected(_ error: CodexBridgeError, epoch: UUID) {
    guard generation == epoch else { return }
    generation = UUID(); rpc = nil; states.removeAll(); conversations.removeAll(); resynchronizing.removeAll()
    output.yield(.unavailable(error))
  }
}
