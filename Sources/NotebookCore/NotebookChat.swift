import Foundation
import CryptoKit

/// A project is read from Codex; Notebook never creates a second project catalogue.
public struct CodexProject: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let roots: [String]
  public init(id: String, name: String, roots: [String]) { self.id = id; self.name = name; self.roots = roots }
}
/// An explicit native project patch. Omitted fields remain owned by Codex.
public struct CodexProjectEdit: Codable, Equatable, Sendable {
  public let id: String
  public let name: String?
  public let roots: [String]?
  public init(id: String, name: String?, roots: [String]?) { self.id = id; self.name = name; self.roots = roots }
  public var isValid: Bool {
    !id.isEmpty && id.utf8.count <= 256 && (name != nil || roots != nil)
      && (name.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 } ?? true)
      && (roots.map { $0.count <= 32 && Set($0).count == $0.count && $0.allSatisfy { $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4096 && URL(fileURLWithPath: $0).standardizedFileURL.path == $0 } } ?? true)
  }
  public func matches(_ project: CodexProject) -> Bool {
    id == project.id && (name == nil || name == project.name) && (roots == nil || roots == project.roots)
  }
}
public struct CodexProjectPage: Codable, Equatable, Sendable {
  public let projects: [CodexProject]
  public let nextCursor: String?
  public init(projects: [CodexProject], nextCursor: String?) { self.projects = projects; self.nextCursor = nextCursor }
}
public struct CodexTask: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let title: String
  public let cwd: String
  public let projectID: String?
  public let source: String?
  public let updatedAt: Double?
  public init(id: String, title: String, cwd: String, projectID: String? = nil, source: String? = nil, updatedAt: Double? = nil) {
    self.id = id; self.title = title; self.cwd = cwd; self.projectID = projectID; self.source = source; self.updatedAt = updatedAt
  }
}
public struct CodexTaskActivity: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable { case running, waitingForInput, idle, unavailable }
  public let id: String
  public let status: Status
  public let summary: String?
  public init(id: String, status: Status, summary: String? = nil) { self.id = id; self.status = status; self.summary = summary }
}
public struct CodexTaskPage: Codable, Equatable, Sendable {
  public let tasks: [CodexTask]
  public let nextCursor: String?
  /// Codex's default provider, not an override of an existing task's provider.
  public let defaultProviderNeedsSignIn: Bool
  public init(tasks: [CodexTask], nextCursor: String?, defaultProviderNeedsSignIn: Bool = false) {
    self.tasks = tasks; self.nextCursor = nextCursor; self.defaultProviderNeedsSignIn = defaultProviderNeedsSignIn
  }
}

public struct CodexMessage: Codable, Equatable, Sendable, Identifiable {
  public enum Role: String, Codable, Sendable { case user, assistant }
  public struct Activity: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case command, files, tool, search, image, plan, compaction, error }
    public let kind: Kind
    public let status: String?
    public let detail: String?
    public init(kind: Kind, status: String? = nil, detail: String? = nil) { self.kind = kind; self.status = status; self.detail = detail }
  }
  public let activity: Activity?
  public let id: String
  public let turnID: String
  public let clientID: String?
  public let role: Role
  public let text: String
  public let isTruncated: Bool
  public init(id: String, turnID: String, clientID: String?, role: Role, text: String, isTruncated: Bool = false, activity: Activity? = nil) { self.activity = activity; self.isTruncated = isTruncated; self.id = id; self.turnID = turnID; self.clientID = clientID; self.role = role; self.text = text }

}

extension CodexMessage {
  /// Keep every item in this page. Only display text is shortened; native IDs and
  /// the continuation cursor remain authoritative, and the UI names the excerpt.
  public static func transportPage(_ messages: [CodexMessage]) -> [CodexMessage] {
    let budget = max(256, 72 * 1024 / max(1, messages.count))
    func prefix(_ text: String, bytes: Int) -> String {
      if text.utf8.count <= bytes { return text }
      let data = Data(text.utf8.prefix(bytes))
      for removed in 0...min(3, data.count) {
        if let value = String(data: data.dropLast(removed), encoding: .utf8) { return value }
      }
      return ""
    }
    return messages.map { item in
      let textBudget = item.activity?.detail == nil ? budget : budget / 2
      let text = prefix(item.text, bytes: textBudget)
      let detail = item.activity?.detail.map { prefix($0, bytes: budget - text.utf8.count) }
      let activity = item.activity.map { Activity(kind: $0.kind, status: $0.status, detail: detail) }
      return CodexMessage(id: item.id, turnID: item.turnID, clientID: item.clientID, role: item.role,
        text: text, isTruncated: item.isTruncated || text != item.text || detail != item.activity?.detail, activity: activity)
    }
  }
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
  case steer(threadID: String, turnID: String, text: String, context: String)
  case create(title: String, project: CodexProject? = nil)
  case updateProject(CodexProjectEdit)
  case saveFile(NotebookFileAddress)
  case stop(threadID: String, turnID: String)
  case respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision)
  public var threadID: String? {
    switch self {
    case .send(let id, _, _), .steer(let id, _, _, _), .stop(let id, _), .respond(let id, _, _): id
    case .create, .updateProject, .saveFile: nil
    }
  }

  public var message: (threadID: String, text: String, context: String)? {
    switch self {
    case .send(let thread, let text, let context), .steer(let thread, _, let text, let context): (thread, text, context)
    default: nil
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
    case .send, .steer, .create, .updateProject, .saveFile: return nil
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
    case .steer(_, let turn, let text, let context):
      return UUID(uuidString: turn) != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 32768 && context.utf8.count <= 32768
    case .create(let title, let project): return !title.isEmpty && title.utf8.count <= 256 && (project == nil || (project!.id.utf8.count <= 256 && !project!.id.isEmpty && project!.roots.count <= 32 && project!.roots.allSatisfy { $0.hasPrefix("/") && $0.utf8.count <= 4096 }))
    case .updateProject(let edit): return edit.isValid
    case .saveFile(let address): return address.isValid && !address.path.isEmpty
    case .stop(_, let turn): return UUID(uuidString: turn) != nil
    case .respond(_, let request, _): return !request.id.isEmpty && !request.turnID.isEmpty
    }
  }
}

public enum NotebookChatResult: Codable, Equatable, Sendable {
  case created(CodexTask), project(CodexProject), turn(String), acknowledged
  case file(NotebookFileResult)
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
    case (.saveFile(let address), .file(let result)): return address == result.address && result.version.isValid
    case (.updateProject(let edit), .project(let project)): return edit.matches(project)
    case (.create, .created(let task)): return UUID(uuidString: task.id) != nil && task.title.utf8.count <= 1024
    case (.send, .turn(let id)), (.steer, .turn(let id)): return UUID(uuidString: id) != nil
    case (.stop, .acknowledged), (.respond, .acknowledged): return true
    default: return false
    }
  }
}

public enum NotebookChatQuery: Codable, Equatable, Sendable {
  case job(NotebookChatInput)
  case file(NotebookFileQuery)
  case catalogue(cursor: String?, project: CodexProject? = nil)
  case projects(cursor: String?)
  case activity(threadIDs: [String])
  case conversation(threadID: String)
  case history(threadID: String, cursor: String?)
}

public enum NotebookChatReply: Codable, Equatable, Sendable {
  case projects(CodexProjectPage), activity([CodexTaskActivity])
  case job(NotebookChatJob), catalogue(CodexTaskPage), conversation(CodexConversation), history(CodexHistoryPage)
  case conversationUnavailable(threadID: String, reason: String)
  case failure(String)
  case file(NotebookFileReply)
}

/// Only one outstanding request per iPad uses the coalesced low-priority lane.
/// Retransmission reuses the request ID and the durable mutation's original ID.
public struct NotebookChatEnvelope: Codable, Equatable, Sendable {
  public enum Body: Codable, Equatable, Sendable { case request(NotebookChatQuery), reply(NotebookChatReply), event(subscriptionID: UUID, conversation: CodexConversation) }
  public let id: UUID
  public let body: Body

  public init(id: UUID = UUID(), body: Body) { self.id = id; self.body = body }
  public func isValid(from deviceID: UUID) -> Bool {
    guard let data = try? JSONEncoder().encode(self), data.count <= 192 * 1024 else { return false }
    if case .request(.file(let query)) = body { return query.isValid }
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
