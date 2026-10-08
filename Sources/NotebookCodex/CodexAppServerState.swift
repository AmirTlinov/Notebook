import Foundation
import NotebookCore

/// A bounded view of native items, not a second stored transcript. Hidden reasoning is never retained.
struct CodexAppServerState: Sendable {
  // A complete 64 KiB native question can use two-byte String storage plus
  // bounded container capacity; dense token arrays have their own retained cap.
  static let maximumRequestPayloadBytes = 256 * 1024
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
  private var bodyAllowance = 16 * 1_048_576
  var retainedBodyBytes: Int {
    messages.reduce(0) { $0 + ($1.isTruncated ? 0 : messageBytes[$1.id, default: 0]) }
  }
  var protectedBodyID: String? {
    messages.last { $0.turnID == activeTurnID && $0.activity == nil && !$0.isTruncated }?.id
  }
  var presentation: CodexConversation {
    let value = view
    return .init(threadID: value.threadID, generation: value.generation, revision: value.revision, title: value.title,
      ready: value.ready, busy: value.busy, activeTurnID: value.activeTurnID,
      messages: value.messages.map { $0.preview() }, requests: value.requests, acceptedMessages: value.acceptedMessages,
      turnStatuses: value.turnStatuses, access: value.access, model: value.model, contextUsage: value.contextUsage)
  }

  mutating func evictBodies(to bytes: Int, keeping id: String? = nil, protectingActive: Bool = false) {
    let active = protectingActive ? protectedBodyID : nil
    for index in messages.indices where retainedBodyBytes > max(0, bytes) {
      if messages[index].id != id, messages[index].id != active, !messages[index].isTruncated { messages[index] = messages[index].preview(evicted: true) }
    }
  }
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
    title = CodexMessageTransfer.textPrefix(thread["name"]?.string ?? thread["preview"]?.string ?? "Codex", maximumBytes: 256)
    for message in history { try acceptMessageID(message) }
    let known = Set(messages.map(\.id))
    let live = messages
    messages = []
    for message in history where !known.contains(message.id) { try upsert(message) }
    for message in live { try upsert(message) }
    let retainedIDs = Set(messages.map(\.id))
    messageBytes = messageBytes.filter { retainedIDs.contains($0.key) }
    for turn in turns {
      guard let id = turn["id"]?.string, let status = turn["status"]?.string,
      CodexMessageTransfer.encodedTextBytes(id, within: 256) != nil,
      CodexMessageTransfer.encodedTextBytes(status, within: 128) != nil else { throw CodexBridgeError.invalidResponse }
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

  @discardableResult mutating func accept(_ frame: JSONValue, bodyAllowance: Int = 16 * 1_048_576) throws -> Bool {
    self.bodyAllowance = max(0, bodyAllowance)
    guard let method = frame["method"]?.string, let params = frame["params"],
      params["threadId"] == .string(threadID) else { return false }
    if let id = frame["id"] {
      guard id.string != nil || id.integer != nil, requests.count < 32,
        CodexProjectionBytes.json(id, maximumBytes: 512) != nil, method.utf8.count <= 256,
        params.retainedPayloadBytes <= Self.maximumRequestPayloadBytes, CodexProjectionBytes.json(params, maximumBytes: 65_536) != nil,
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
          guard CodexModelSelection(model:name,effort:settings["effort"]?.string).isValid else { throw CodexBridgeError.invalidResponse }
          if model?.model != name { contextUsage = nil }
          model = .init(model: name, effort: settings["effort"]?.string)
        }
        guard (settings["cwd"]?.string?.utf8.count ?? 0) <= 4096 else { throw CodexBridgeError.invalidResponse }
        cwd = settings["cwd"]?.string ?? cwd
        access = try Self.boundedAccess(profileID: settings["activePermissionProfile"]?["id"]?.string,
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
        title = CodexMessageTransfer.textPrefix(params["threadName"]?.string ?? title, maximumBytes: 256)
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
        guard let bytes = messageBytes[id] else {
          if prior.activity?.kind == .error { return false }
          messages[index] = .init(id: prior.id, turnID: prior.turnID, clientID: prior.clientID, role: prior.role,
            text: prior.text, isTruncated: true, contentRevision: generation.uuidString + ":" + String(revision + 1),
            activity: prior.activity, attachments: prior.attachments, phase: prior.phase)
          revision += 1; return true
        }
        if let addition = Self.encodedTextBytes(delta, within: CodexMessageTransfer.maximumBytes - bytes) {
          evictBodies(to: self.bodyAllowance - addition, keeping: id, protectingActive: true)
          let fits = bytes + addition <= self.bodyAllowance - retainedBodyBytes + (prior.isTruncated ? 0 : bytes)
          messageBytes[id] = bytes + addition
          if !prior.isTruncated, fits {
            messages[index] = CodexMessage(id: prior.id, turnID: prior.turnID, clientID: prior.clientID, role: prior.role,
              text: prior.text + delta, contentRevision: generation.uuidString + ":" + String(revision + 1),
              activity: prior.activity, attachments: prior.attachments, phase: prior.phase)
          } else {
            let preview = prior.preview(evicted: true)
            messages[index] = .init(id: prior.id, turnID: prior.turnID, clientID: prior.clientID, role: prior.role,
              text: preview.text, isTruncated: true, contentRevision: generation.uuidString + ":" + String(revision + 1),
              activity: preview.activity, attachments: preview.attachments, phase: prior.phase)
          }
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

  func additionalBodyBytes(for frame: JSONValue) -> Int {
    let params = frame["params"]
    switch frame["method"]?.string {
    case "item/agentMessage/delta":
      guard let id = params?["itemId"]?.string, let delta = params?["delta"]?.string,
        let prior = messages.first(where: { $0.id == id }), !prior.isTruncated,
        let bytes = messageBytes[id],
        let addition = Self.encodedTextBytes(delta, within: CodexMessageTransfer.maximumBytes - bytes) else { return 0 }
      return addition
    case "item/started", "item/completed":
      let previous = params?["item"]?["id"]?.string.flatMap { id in
        messages.first { $0.id == id && !$0.isTruncated }.flatMap { messageBytes[$0.id] }
      } ?? 0
      return CodexMessageTransfer.maximumBytes - previous
    default: return 0
    }
  }

  private mutating func acceptTurn(_ turn: JSONValue) throws {
    guard let id = turn["id"]?.string, let status = turn["status"]?.string,
      CodexMessageTransfer.encodedTextBytes(id, within: 256) != nil,
      CodexMessageTransfer.encodedTextBytes(status, within: 128) != nil else { throw CodexBridgeError.invalidResponse }
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
    CodexMessageTransfer.encodedTextBytes(text, within: limit)
  }

  static func boundedAccess(profileID: String?, approvalPolicy: JSONValue, available: [CodexAccessMode]) throws -> CodexAccess {
    guard (profileID?.utf8.count ?? 0) <= 256, approvalPolicy.retainedPayloadBytes <= 4096,
      CodexProjectionBytes.json(approvalPolicy,maximumBytes:4096) != nil else { throw CodexBridgeError.invalidResponse }
    return .init(profileID:profileID,approvalPolicy:approvalPolicy,available:available)
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
    if message.isTruncated { messageBytes.removeValue(forKey: message.id); return message.preview() }
    guard let bytes = CodexMessageTransfer.encodedByteCount(message) else {
      messageBytes.removeValue(forKey:message.id)
      return unavailableMessage(message)
    }
    let previous = messages.first { $0.id == message.id }.flatMap { $0.isTruncated ? nil : messageBytes[$0.id] } ?? 0
    evictBodies(to: bodyAllowance - bytes + previous, keeping: message.id, protectingActive: true)
    let fits = bytes <= bodyAllowance - retainedBodyBytes + previous
    messageBytes[message.id] = bytes
    let identified = message.identifyingContent()
    return fits ? identified : identified.preview(evicted: true)
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
