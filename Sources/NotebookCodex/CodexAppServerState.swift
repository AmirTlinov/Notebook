import Foundation
import NotebookCore

/// A bounded view of native items, not a second stored transcript. Hidden reasoning is never retained.
struct CodexAppServerState: Sendable {
  let threadID: String
  let generation = UUID()
  var title = "Codex"
  var ready = false
  var activeTurnID: String?
  var revision = 0
  var messages: [CodexMessage] = []
  // Exact full-transfer bytes, not the smaller presentation excerpt. This
  // accounting belongs to the same bounded native item window as its bodies.
  private var messageBytes: [String: Int] = [:]
  var requests: [CodexUserRequest] = []
  var turnStatuses: [String: String] = [:]
  var runtimeActive = false
  private var receivedRuntimeState = false
  var access: CodexAccess?
  var model: CodexModelSelection?
  var contextUsage: CodexContextUsage?
  var cwd: String?
  private var accepted: [String: String] = [:]
  private var acceptedOrder: [String] = []

  var view: CodexConversation {
    CodexConversation(threadID: threadID, generation: generation, revision: revision, title: title, ready: ready,
      busy: runtimeActive || activeTurnID != nil, activeTurnID: activeTurnID, messages: messages, requests: requests,
      acceptedMessages: accepted,
      turnStatuses: turnStatuses, access: access, model: model, contextUsage: contextUsage)
  }

  mutating func hydrate(thread: JSONValue, history: [CodexMessage], turns: [JSONValue]) throws {
    guard thread["id"] == .string(threadID) else { throw CodexBridgeError.invalidResponse }
    title = String((thread["name"]?.string ?? thread["preview"]?.string ?? "Codex").prefix(256))
    for message in history { try acceptMessageID(message) }
    let known = Set(messages.map(\.id))
    var admitted: [CodexMessage] = []
    for message in history where !known.contains(message.id) { admitted.append(try admitMessage(message)) }
    messages = Array((admitted + messages).suffix(64))
    let retainedIDs = Set(messages.map(\.id))
    messageBytes = messageBytes.filter { retainedIDs.contains($0.key) }
    for turn in turns {
      guard let id = turn["id"]?.string, let status = turn["status"]?.string else { throw CodexBridgeError.invalidResponse }
      // Events received during the read own their newer status. A runtime
      // activity event must not discard unrelated historical terminal states.
      if turnStatuses[id] == nil { turnStatuses[id] = status }
    }
    if !receivedRuntimeState {
      runtimeActive = thread["status"]?["type"] == .string("active")
      // Descending history: only the newest turn can establish current work.
      if let newest = turns.first { try acceptTurn(newest) }
    }
    ready = true; revision += 1
  }

  @discardableResult mutating func accept(_ frame: JSONValue) throws -> Bool {
    guard let method = frame["method"]?.string, let params = frame["params"],
      params["threadId"] == .string(threadID) else { return false }
    if let id = frame["id"] {
      guard id.string != nil || id.integer != nil, requests.count < 32,
        try JSONEncoder().encode(id).count <= 512, method.utf8.count <= 256,
        try JSONEncoder().encode(params).count <= 65_536,
        let turn = params["turnId"]?.string ?? activeTurnID, turn.utf8.count <= 256 else { throw CodexBridgeError.unsupportedRequest }
      let request = CodexUserRequest(nativeID: id, generation: generation, method: method, turnID: turn, parameters: params)
      if let prior = requests.first(where: { $0.nativeID == id }) {
        guard prior == request else { throw CodexBridgeError.invalidResponse }; return false
      }
      requests.append(request)
    } else {
      switch method {
      case "thread/settings/updated":
        guard let settings = params["threadSettings"], let policy = settings["approvalPolicy"] else { throw CodexBridgeError.invalidResponse }
        if let name = settings["model"]?.string {
          if model?.model != name { contextUsage = nil }
          model = .init(model: name, effort: settings["effort"]?.string)
        }
        cwd = settings["cwd"]?.string ?? cwd
        access = CodexAccess(profileID: settings["activePermissionProfile"]?["id"]?.string,
          approvalPolicy: policy, available: access?.available ?? [])
      case "thread/tokenUsage/updated":
        guard let usage = params["tokenUsage"], let used = usage["last"]?["totalTokens"]?.integer, used >= 0 else { throw CodexBridgeError.invalidResponse }
        let window = usage["modelContextWindow"]?.integer
        guard window == nil || window! > 0 else { throw CodexBridgeError.invalidResponse }
        contextUsage = .init(used: used, window: window)
      case "serverRequest/resolved":
        requests.removeAll { $0.nativeID == params["requestId"] }
      case "thread/status/changed":
        receivedRuntimeState = true
        runtimeActive = params["status"]?["type"] == .string("active")
      case "thread/name/updated":
        title = String((params["threadName"]?.string ?? title).prefix(256))
      case "turn/started", "turn/completed":
        receivedRuntimeState = true
        guard let turn = params["turn"] else { throw CodexBridgeError.invalidResponse }
        try acceptTurn(turn)
      case "item/started", "item/completed":
        guard let item = params["item"], let turn = params["turnId"]?.string else { throw CodexBridgeError.invalidResponse }
        if let message = Self.displayMessage(item, turnID: turn) { try acceptMessageID(message); try upsert(message) }
      case "item/agentMessage/delta":
        guard let id = params["itemId"]?.string, let delta = params["delta"]?.string,
          let index = messages.firstIndex(where: { $0.id == id && $0.turnID == params["turnId"]?.string }) else { return false }
        let prior = messages[index]
        // Once this native item is unavailable, further deltas are neither
        // retained nor published. Only an authoritative item can restore it.
        guard let bytes = messageBytes[id] else { return false }
        if let addition = Self.encodedTextBytes(delta, within: CodexMessageTransfer.maximumBytes - bytes) {
          messageBytes[id] = bytes + addition
          messages[index] = CodexMessage(id: prior.id, turnID: prior.turnID, clientID: prior.clientID, role: prior.role,
            text: prior.text + delta, contentRevision: generation.uuidString + ":" + String(revision + 1),
            activity: prior.activity, attachments: prior.attachments, phase: prior.phase)
        } else {
          messageBytes.removeValue(forKey: id)
          messages[index] = unavailableMessage(prior)
        }
      default: return false
      }
    }
    revision += 1
    return true
  }

  private mutating func acceptTurn(_ turn: JSONValue) throws {
    guard let id = turn["id"]?.string, let status = turn["status"]?.string else { throw CodexBridgeError.invalidResponse }
    turnStatuses[id] = status
    if status == "inProgress" { activeTurnID = id; runtimeActive = true }
    else if activeTurnID == id { activeTurnID = nil; runtimeActive = false; requests.removeAll { $0.turnID == id } }
    let retained = Set(messages.map(\.turnID)).union([id])
    if turnStatuses.count > 64 { turnStatuses = turnStatuses.filter { retained.contains($0.key) } }
  }
  private mutating func acceptMessageID(_ message: CodexMessage) throws {
    guard let id = message.clientID else { return }
    if let previous = accepted[id] {
      guard previous == message.turnID else { throw CodexBridgeError.invalidResponse }; return
    }
    accepted[id] = message.turnID; acceptedOrder.append(id)
    if acceptedOrder.count > 128 { accepted.removeValue(forKey: acceptedOrder.removeFirst()) }
  }
  /// Matches JSONEncoder with `.withoutEscapingSlashes`: only ASCII controls,
  /// quote and backslash expand. Counting just the delta avoids re-encoding the
  /// growing body and rejects overload before allocating its concatenation.
  static func encodedTextBytes(_ text: String, within limit: Int) -> Int? {
    var count = 0
    for byte in text.utf8 {
      let cost: Int
      switch byte {
      case 8, 9, 10, 12, 13, 34, 92: cost = 2
      case 0..<32: cost = 6
      default: cost = 1
      }
      guard cost <= limit - count else { return nil }
      count += cost
    }
    return count
  }

  private func unavailableMessage(_ message: CodexMessage) -> CodexMessage {
    .init(id:message.id,turnID:message.turnID,clientID:message.clientID,role:message.role,
      text:"Полное сообщение недоступно в Notebook",isTruncated:true,
      contentRevision:generation.uuidString + ":unavailable:" + String(revision + 1),
      activity:.init(kind:.error,status:"failed",
        detail:"Сообщение превышает предел кадра Codex (8 МиБ). Оригинал не изменён; Notebook не может загрузить его этим протоколом."),
      phase:message.phase)
  }

  private mutating func admitMessage(_ message: CodexMessage) throws -> CodexMessage {
    let bytes = try CodexMessageTransfer.encode(message).count
    guard !message.isTruncated, bytes <= CodexMessageTransfer.maximumBytes else {
      messageBytes.removeValue(forKey:message.id)
      return unavailableMessage(message)
    }
    messageBytes[message.id] = bytes
    return message
  }

  private mutating func upsert(_ message: CodexMessage) throws {
    let admitted = try admitMessage(message)
    if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = admitted }
    else {
      messages.append(admitted)
      if messages.count > 64 {
        for retired in messages.prefix(messages.count - 64) { messageBytes.removeValue(forKey:retired.id) }
        messages.removeFirst(messages.count - 64)
      }
    }
  }
}
