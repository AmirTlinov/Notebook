import Foundation
import NotebookCore

public enum CodexBridgeError: String, Error, Sendable {
  case notInstalled, incompatibleVersion, unsupportedHome, unsafeEndpoint, unavailable, disconnected, timeout
  case invalidFrame, invalidResponse, wrongOwner, revisionGap, historyLimit, busy, staleTurn
  case staleRequest, unsupportedRequest, invalidInput, acceptanceUnknown, signInRequired, externalOwnerUnavailable
}

/// Only this reviewed desktop protocol is admitted. This is not an App Server version promise.
public enum CodexDesktopProtocol {
  public static let appVersion = "26.903.61454"
  public static let appBuild = "8378"
  static let streamVersion = 11
  static let frameLimit = 8 * 1_048_576
  static let messageLimit = 32_768
  static let versions: [String: Int] = [
    "initialize": 0, "thread-owner-discovery": 1,
    "thread-follower-start-turn": 2, "thread-follower-interrupt-turn": 4,
    "thread-follower-command-approval-decision": 1, "thread-follower-file-approval-decision": 1,
    "thread-follower-permissions-request-approval-response": 1,
    "thread-follower-submit-user-input": 1, "thread-follower-submit-mcp-server-elicitation-response": 1
  ]
}

extension JSONValue {
  var string: String? { if case .string(let v) = self { v } else { nil } }
  var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
  var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
  var integer: Int? {
    guard case .number(let v) = self, v.isFinite, v >= 0, v <= 9_007_199_254_740_991, v.rounded() == v else { return nil }
    return Int(v)
  }
  static func textInput(_ text: String) -> JSONValue {
    .object(["type": .string("text"), "text": .string(text), "text_elements": .array([])])
  }
}

/// Implements the desktop's revisioned Immer patch contract. A failed batch publishes nothing.
struct CodexStreamState: Sendable {
  let threadID: String
  let owner: String
  private(set) var revision: Int?
  private(set) var value: JSONValue?

  mutating func accept(_ message: JSONValue) throws -> CodexConversation? {
    guard message["method"] == .string("thread-stream-state-changed") else { return nil }
    guard message["sourceClientId"] == .string(owner) else { throw CodexBridgeError.wrongOwner }
    guard message["version"]?.integer == CodexDesktopProtocol.streamVersion else { throw CodexBridgeError.incompatibleVersion }
    guard let params = message["params"], params["hostId"] == .string("local"),
      params["conversationId"] == .string(threadID), let change = params["change"],
      let nextRevision = change["revision"]?.integer else { throw CodexBridgeError.invalidResponse }
    let candidate: JSONValue
    switch change["type"] {
    case .string("snapshot"):
      guard let state = change["conversationState"], state["id"] == .string(threadID),
        state["hostId"] == .string("local") else { throw CodexBridgeError.invalidResponse }
      if let revision, nextRevision < revision { return nil }
      if revision == nextRevision, let value, value != state { throw CodexBridgeError.invalidResponse }
      candidate = state
    case .string("patches"):
      guard let revision, let value, change["baseRevision"]?.integer == revision,
        nextRevision > revision else { throw CodexBridgeError.revisionGap }
      guard let patches = change["patches"]?.array, patches.count <= 4096 else { throw CodexBridgeError.historyLimit }
      var changed = value
      for patch in patches {
        guard let path = patch["path"]?.array, path.count <= 64, let operation = patch["op"]?.string,
          ["add", "replace", "remove"].contains(operation) else { throw CodexBridgeError.invalidResponse }
        if message[CodexWireProjection.marker] == .bool(true), CodexWireProjection.omits(path, in: changed) { continue }
        let replacement = message[CodexWireProjection.marker] == .bool(true)
          ? CodexWireProjection.replacement(patch["value"], operation: operation, path: path, in: changed) : patch["value"]
        changed = try Self.apply(operation, path: path[...], replacement: replacement, to: changed)
        if message[CodexWireProjection.marker] == .bool(true) { changed = CodexWireProjection.pruneAfterPatch(changed) }
      }
      candidate = changed
    default: throw CodexBridgeError.invalidResponse
    }
    guard try JSONEncoder().encode(candidate).count <= CodexDesktopProtocol.frameLimit else { throw CodexBridgeError.historyLimit }
    let projection = try Self.project(candidate, threadID: threadID, revision: nextRevision)
    revision = nextRevision; value = candidate
    return projection
  }

  private static func apply(_ op: String, path: ArraySlice<JSONValue>, replacement: JSONValue?, to value: JSONValue) throws -> JSONValue {
    guard let head = path.first else {
      guard op != "remove", let replacement else { throw CodexBridgeError.invalidResponse }
      return replacement
    }
    let tail = path.dropFirst()
    if case .object(var fields) = value, let key = head.string {
      if tail.isEmpty {
        if op != "add", fields[key] == nil { throw CodexBridgeError.invalidResponse }
        if op == "remove" { fields.removeValue(forKey: key) }
        else { guard let replacement else { throw CodexBridgeError.invalidResponse }; fields[key] = replacement }
      } else {
        guard let child = fields[key] else { throw CodexBridgeError.invalidResponse }
        fields[key] = try apply(op, path: tail, replacement: replacement, to: child)
      }
      return .object(fields)
    }
    if case .array(var items) = value, let index = head.integer {
      if tail.isEmpty, op == "add" {
        guard index <= items.count, let replacement else { throw CodexBridgeError.invalidResponse }
        items.insert(replacement, at: index)
      } else {
        guard index < items.count else { throw CodexBridgeError.invalidResponse }
        if tail.isEmpty, op == "remove" { items.remove(at: index) }
        else { items[index] = try apply(op, path: tail, replacement: replacement, to: items[index]) }
      }
      return .array(items)
    }
    throw CodexBridgeError.invalidResponse
  }

  private static func project(_ state: JSONValue, threadID: String, revision: Int) throws -> CodexConversation {
    let turns: [JSONValue]
    if state["turnHistory"]?["kind"] == .string("canonical"),
      let history = state["turnHistory"]?["history"], let entities = history["entitiesByKey"]?.object,
      let islands = history["islands"]?.array {
      let keys = islands.flatMap { $0["entries"]?.array ?? [] }.compactMap { $0["value"]?.string }
      guard keys.count <= 4096, keys.allSatisfy({ entities[$0] != nil }) else { throw CodexBridgeError.invalidResponse }
      turns = keys.compactMap { entities[$0] }
    } else if let legacy = state["turns"]?.array { turns = legacy }
    else { throw CodexBridgeError.invalidResponse }
    let active = turns.filter { $0["status"] == .string("inProgress") }
    guard active.count <= 1, let rawRequests = state["requests"]?.array, rawRequests.count <= 32 else {
      throw CodexBridgeError.invalidResponse
    }
    let requests = try rawRequests.map { raw -> CodexUserRequest in
      guard let nativeID = raw["id"], nativeID.string != nil || nativeID.integer != nil,
        let method = raw["method"]?.string, let params = raw["params"],
        params["threadId"] == .string(threadID), let turnID = params["turnId"]?.string else { throw CodexBridgeError.invalidResponse }
      return CodexUserRequest(nativeID: nativeID, method: method, turnID: turnID, parameters: params)
    }
    var accepted: [String: String] = [:]
    var messages: [CodexMessage] = []
    for turn in turns {
      let turnID = turn["turnId"]?.string ?? turn["id"]?.string ?? ""
      guard !turnID.isEmpty else { continue }
      for item in turn["items"]?.array ?? [] {
        if item["type"] == .string("userMessage"), let clientID = item["clientId"]?.string {
          if let previous = accepted[clientID], previous != turnID { throw CodexBridgeError.invalidResponse }
          accepted[clientID] = turnID
        }
        if let message = displayMessage(item, turnID: turnID) { messages.append(message) }
      }
    }
    return CodexConversation(threadID: threadID, revision: revision, title: state["title"]?.string ?? "Codex",
      ready: state["resumeState"] == .string("resumed"),
      busy: !active.isEmpty || state["threadRuntimeStatus"]?["type"] == .string("active"),
      activeTurnID: active.first?["turnId"]?.string ?? active.first?["id"]?.string, messages: Array(messages.suffix(64)), requests: requests,
      acceptedMessages: accepted, turnStatuses: Dictionary(turns.suffix(64).compactMap { turn in
        guard let id = turn["turnId"]?.string ?? turn["id"]?.string, let status = turn["status"]?.string else { return nil }
        return (id, status)
      }, uniquingKeysWith: { _, new in new }))
  }

  static func displayMessage(_ item: JSONValue, turnID: String) -> CodexMessage? {
    guard let id = item["id"]?.string, let type = item["type"]?.string else { return nil }
    let role: CodexMessage.Role, text: String
    var activity: CodexMessage.Activity?
    var detailTruncated = false
    let status = item["status"]?.string
    func action(_ kind: CodexMessage.Activity.Kind, _ detail: String? = nil) -> CodexMessage.Activity {
      detailTruncated = detailTruncated || (detail?.count ?? 0) > 8192
      return .init(kind: kind, status: status, detail: detail.map { String($0.prefix(8192)) })
    }
    switch type {
    case "userMessage":
      guard item["content"] != nil else { return nil }
      role = .user; text = (item["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
    case "agentMessage":
      role = .assistant; text = item["text"]?.string ?? ""
    case "commandExecution":
      role = .assistant
      let command = item["command"]?.string ?? ""
      text = (status == "inProgress" ? "Выполняется команда" : status == "failed" ? "Команда завершилась ошибкой" : "Выполнена команда") + (command.isEmpty ? "" : " · " + String(command.prefix(160)))
      let output = item["aggregatedOutput"]?.string
      activity = action(.command, command + (output.map { "\n\n" + $0 } ?? ""))
    case "fileChange":
      role = .assistant
      let changes = item["changes"]?.array ?? []
      text = (status == "inProgress" ? "Изменяются файлы" : "Изменены файлы") + " · \(changes.count)"
      activity = action(.files, changes.compactMap { $0["path"]?.string }.joined(separator: "\n"))
    case "mcpToolCall", "dynamicToolCall", "functionCallOutput":
      role = .assistant
      let name = [item["server"]?.string ?? item["namespace"]?.string, item["tool"]?.string ?? item["name"]?.string].compactMap { $0 }.joined(separator: ".")
      text = (status == "inProgress" ? "Вызывается инструмент" : "Вызван инструмент") + (name.isEmpty ? "" : " · " + name)
      activity = action(.tool)
    case "webSearch":
      role = .assistant; text = "Поиск · " + (item["query"]?.string ?? ""); activity = action(.search)
    case "imageView":
      role = .assistant; text = "Просмотрено изображение"; activity = action(.image, item["path"]?.string)
    case "plan", "planImplementation":
      role = .assistant; text = "План работы"; activity = action(.plan, item["text"]?.string)
    case "contextCompaction":
      role = .assistant; text = item["completed"] == .bool(false) ? "Контекст сжимается" : "Контекст сжат"; activity = action(.compaction)
    case "error":
      role = .assistant; text = "Ошибка Codex"; activity = action(.error, item["message"]?.string)
    // Reasoning content, hidden context and optimistic/steering input are not a
    // second transcript. Canonical user items and public commentary own those rows.
    default: return nil
    }
    return CodexMessage(id: id, turnID: turnID, clientID: item["clientId"]?.string, role: role,
      text: String(text.prefix(16_384)), isTruncated: text.count > 16_384 || detailTruncated, activity: activity)
  }
}
