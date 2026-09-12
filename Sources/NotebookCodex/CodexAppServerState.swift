import Foundation
import NotebookCore

/// A bounded view of native items, not a second stored transcript. Hidden reasoning is never retained.
struct CodexAppServerState: Sendable {
  let threadID: String
  var title = "Codex"
  var ready = false
  var activeTurnID: String?
  var revision = 0
  var messages: [CodexMessage] = []
  var requests: [CodexUserRequest] = []
  var turnStatuses: [String: String] = [:]
  var runtimeActive = false
  var access: CodexAccess?
  var cwd: String?
  private var accepted: [String: String] = [:]
  private var acceptedOrder: [String] = []

  var view: CodexConversation {
    CodexConversation(threadID: threadID, revision: revision, title: title, ready: ready,
      busy: runtimeActive || activeTurnID != nil, activeTurnID: activeTurnID, messages: messages, requests: requests,
      acceptedMessages: accepted,
      turnStatuses: turnStatuses, access: access)
  }

  mutating func hydrate(thread: JSONValue, history: [CodexMessage], turns: [JSONValue]) throws {
    guard thread["id"] == .string(threadID) else { throw CodexBridgeError.invalidResponse }
    title = String((thread["name"]?.string ?? thread["preview"]?.string ?? "Codex").prefix(256))
    for message in history { try acceptMessageID(message) }
    let known = Set(messages.map(\.id))
    messages = Array((history.filter { !known.contains($0.id) } + messages).suffix(64))
    if revision == 0 {
      runtimeActive = thread["status"]?["type"] == .string("active")
      for turn in turns { try acceptTurn(turn) }
    }
    ready = true; revision += 1
  }

  @discardableResult mutating func accept(_ frame: JSONValue) throws -> Bool {
    guard let method = frame["method"]?.string, let params = frame["params"],
      params["threadId"] == .string(threadID) else { return false }
    if let id = frame["id"] {
      guard id.string != nil || id.integer != nil, requests.count < 32,
        try JSONEncoder().encode(params).count <= 65_536,
        let turn = params["turnId"]?.string ?? activeTurnID else { throw CodexBridgeError.unsupportedRequest }
      let request = CodexUserRequest(nativeID: id, method: method, turnID: turn, parameters: params)
      if let prior = requests.first(where: { $0.nativeID == id }) {
        guard prior == request else { throw CodexBridgeError.invalidResponse }; return false
      }
      requests.append(request)
    } else {
      switch method {
      case "thread/settings/updated":
        guard let settings = params["threadSettings"], let policy = settings["approvalPolicy"] else { throw CodexBridgeError.invalidResponse }
        cwd = settings["cwd"]?.string ?? cwd
        access = CodexAccess(profileID: settings["activePermissionProfile"]?["id"]?.string,
          approvalPolicy: policy, available: access?.available ?? [])
      case "serverRequest/resolved":
        requests.removeAll { $0.nativeID == params["requestId"] }
      case "thread/status/changed":
        runtimeActive = params["status"]?["type"] == .string("active")
      case "thread/name/updated":
        title = String((params["threadName"]?.string ?? title).prefix(256))
      case "turn/started", "turn/completed":
        guard let turn = params["turn"] else { throw CodexBridgeError.invalidResponse }
        try acceptTurn(turn)
      case "item/started", "item/completed":
        guard let item = params["item"], let turn = params["turnId"]?.string else { throw CodexBridgeError.invalidResponse }
        if let message = Self.displayMessage(item, turnID: turn) { try acceptMessageID(message); upsert(message) }
      case "item/agentMessage/delta":
        guard let id = params["itemId"]?.string, let delta = params["delta"]?.string,
          let index = messages.firstIndex(where: { $0.id == id && $0.turnID == params["turnId"]?.string }) else { return false }
        let prior = messages[index], text = prior.text + delta
        messages[index] = CodexMessage(id: prior.id, turnID: prior.turnID, clientID: prior.clientID, role: prior.role,
          text: String(text.prefix(16_384)), isTruncated: prior.isTruncated || text.count > 16_384, activity: prior.activity)
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
  private mutating func upsert(_ message: CodexMessage) {
    if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
    else { messages.append(message); if messages.count > 64 { messages.removeFirst(messages.count - 64) } }
  }
}
