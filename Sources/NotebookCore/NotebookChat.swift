import Foundation
import CryptoKit

public struct CodexTask: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let title: String
  public let cwd: String
  public init(id: String, title: String, cwd: String) { self.id = id; self.title = title; self.cwd = cwd }

}

public struct CodexTaskPage: Codable, Equatable, Sendable {
  public let tasks: [CodexTask]
  public let nextCursor: String?
  public init(tasks: [CodexTask], nextCursor: String?) { self.tasks = tasks; self.nextCursor = nextCursor }

}

public struct CodexMessage: Codable, Equatable, Sendable, Identifiable {
  public enum Role: String, Codable, Sendable { case user, assistant }
  public let id: String
  public let turnID: String
  public let clientID: String?
  public let role: Role
  public let text: String
  public let isTruncated: Bool
  public init(id: String, turnID: String, clientID: String?, role: Role, text: String, isTruncated: Bool = false) { self.isTruncated = isTruncated; self.id = id; self.turnID = turnID; self.clientID = clientID; self.role = role; self.text = text }

}

public struct CodexUserRequest: Codable, Equatable, Sendable, Identifiable {
  // Request IDs are native JSON-RPC string OR integer IDs, not newly assigned UUIDs.
  public let nativeID: JSONValue
  public let method: String
  public let turnID: String
  public let parameters: JSONValue
  public var id: String { (try? String(data: JSONEncoder().encode(nativeID), encoding: .utf8)) ?? "" }
  public init(nativeID: JSONValue, method: String, turnID: String, parameters: JSONValue) { self.nativeID = nativeID; self.method = method; self.turnID = turnID; self.parameters = parameters }

}

public struct CodexConversation: Codable, Equatable, Sendable {
  public let threadID: String
  public let revision: Int
  public let title: String
  public let ready: Bool
  public let busy: Bool
  public let activeTurnID: String?
  public let messages: [CodexMessage]
  public let requests: [CodexUserRequest]
  /// Native user items with a real turn ID, never an optimistic local composer item.
  public let acceptedMessages: [String: String]
  public let turnStatuses: [String: String]
  public init(threadID: String, revision: Int, title: String, ready: Bool, busy: Bool, activeTurnID: String?, messages: [CodexMessage], requests: [CodexUserRequest], acceptedMessages: [String: String], turnStatuses: [String: String]) { self.threadID = threadID; self.revision = revision; self.title = title; self.ready = ready; self.busy = busy; self.activeTurnID = activeTurnID; self.messages = messages; self.requests = requests; self.acceptedMessages = acceptedMessages; self.turnStatuses = turnStatuses }

}

public struct CodexHistoryPage: Codable, Equatable, Sendable {
  public let messages: [CodexMessage]
  public let nextCursor: String?
  public init(messages: [CodexMessage], nextCursor: String?) { self.messages = messages; self.nextCursor = nextCursor }

}

public enum CodexUserDecision: Codable, Equatable, Sendable {
  case allowOnce, decline
  case answers([String: [String]])
  case elicitation(JSONValue)
}

/// Local delivery records are not a second editable conversation history.
public enum NotebookChatAction: Codable, Equatable, Sendable {
  case send(threadID: String, text: String, context: String)
  case create(title: String)
  case stop(threadID: String, turnID: String)
  case respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision)
  public var threadID: String? {
    switch self {
    case .send(let id, _, _), .stop(let id, _), .respond(let id, _, _): id
    case .create: nil
    }
  }

  /// One human decision belongs to one native request; reopening a panel or
  /// tapping Stop again cannot mint another delivery of that same control.
  /// Text messages and task creation remain independent human submissions.
  public func controlID(author: UUID) -> UUID? {
    let address: [String]
    switch self {
    case .stop(let thread, let turn): address = ["stop", thread.lowercased(), turn.lowercased()]
    case .respond(let thread, let request, _):
      address = ["respond", thread.lowercased(), request.turnID.lowercased(), request.method, request.id]
    case .send, .create: return nil
    }
    var data = Data()
    for part in ["NotebookChatControl/1", author.uuidString.lowercased()] + address {
      data.append(Data("\(part.utf8.count):".utf8)); data.append(Data(part.utf8))
    }
    var bytes = Array(SHA256.hash(data: data).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }
}

public struct NotebookChatInput: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let author: UUID
  public let action: NotebookChatAction
  public let createdAt: Date
  public let attentionContextID: UUID?

  public init(id: UUID = UUID(), author: UUID, action: NotebookChatAction, createdAt: Date = Date(), attentionContextID: UUID? = nil) {
    self.id = id; self.author = author; self.action = action; self.createdAt = createdAt; self.attentionContextID = attentionContextID
  }
  public var isValid: Bool {
    guard createdAt.timeIntervalSince1970.isFinite,
      let bytes = try? JSONEncoder().encode(self), bytes.count <= 96 * 1024 else { return false }
    if let id = action.threadID, UUID(uuidString: id) == nil { return false }
    switch action {
    case .send(_, let text, let context):
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 32768 && context.utf8.count <= 32768
    case .create(let title): return !title.isEmpty && title.utf8.count <= 256
    case .stop(_, let turn): return UUID(uuidString: turn) != nil
    case .respond(_, let request, _): return !request.id.isEmpty && !request.turnID.isEmpty
    }
  }
}

public enum NotebookChatResult: Codable, Equatable, Sendable {
  case created(CodexTask), turn(String), acknowledged
}

public struct NotebookChatJob: Codable, Equatable, Sendable, Identifiable {
  public enum State: String, Codable, Sendable { case saved, attempting, uncertain, accepted, rejected }
  public let input: NotebookChatInput
  public let state: State
  public let result: NotebookChatResult?
  public let error: String?
  public let revision: Int
  public var id: UUID { input.id }

  public init(input: NotebookChatInput, state: State = .saved, result: NotebookChatResult? = nil, error: String? = nil, revision: Int = 0) {
    self.input = input; self.state = state; self.result = result; self.error = error; self.revision = revision
  }
  public var isTerminal: Bool { state == .accepted || state == .rejected }
  public var isValid: Bool {
    guard input.isValid, revision >= 0, (error?.utf8.count ?? 0) <= 4096,
      (state == .accepted) == (result != nil) else { return false }
    guard let result else { return true }
    switch (input.action, result) {
    case (.create, .created(let task)): return UUID(uuidString: task.id) != nil && task.title.utf8.count <= 1024
    case (.send, .turn(let id)): return UUID(uuidString: id) != nil
    case (.stop, .acknowledged), (.respond, .acknowledged): return true
    default: return false
    }
  }
}

public enum NotebookChatQuery: Codable, Equatable, Sendable {
  case job(NotebookChatInput)
  case catalogue(cursor: String?)
  case conversation(threadID: String)
  case history(threadID: String, cursor: String?)
}

public enum NotebookChatReply: Codable, Equatable, Sendable {
  case job(NotebookChatJob), catalogue(CodexTaskPage), conversation(CodexConversation), history(CodexHistoryPage)
  case failure(String)
}

/// Only one outstanding request per iPad uses the coalesced low-priority lane.
/// Retransmission reuses the request ID and the durable mutation's original ID.
public struct NotebookChatEnvelope: Codable, Equatable, Sendable {
  public enum Body: Codable, Equatable, Sendable { case request(NotebookChatQuery), reply(NotebookChatReply) }
  public let id: UUID
  public let body: Body

  public init(id: UUID = UUID(), body: Body) { self.id = id; self.body = body }
  public func isValid(from deviceID: UUID) -> Bool {
    guard let data = try? JSONEncoder().encode(self), data.count <= 192 * 1024 else { return false }
    if case .request(.job(let input)) = body { return input.author == deviceID && input.isValid }
    return true
  }
}

public struct NotebookChatPanelState: Codable, Equatable, Sendable {
  public var threadID: String?
  public var draft: String
  public var sidecarID: UUID?

  public init(threadID: String? = nil, draft: String = "", sidecarID: UUID? = nil) { self.threadID = threadID; self.draft = draft; self.sidecarID = sidecarID }
}
