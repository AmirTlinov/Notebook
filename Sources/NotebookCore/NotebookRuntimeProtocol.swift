import Foundation

/// Process/bootstrap commands travel on the existing IPC envelope. Their
/// execution belongs to the application launch owner, never a workspace store.
public struct NotebookRuntimeWorkspaceRequest: Codable, Equatable, Sendable {
  public enum Action: String, Codable, Sendable { case list, create, select, rename, retry }
  public let action: Action
  public let id: UUID?
  public let name: String?
  public init(action: Action, id: UUID? = nil, name: String? = nil) {
    self.action = action; self.id = id; self.name = name
  }
  public func validate() throws {
    let valid: Bool
    switch action {
    case .list: valid = id == nil && name == nil
    case .retry: valid = name == nil
    case .create: valid = id != nil && name != nil
    case .select: valid = id != nil && name == nil
    case .rename: valid = id != nil && name != nil
    }
    guard valid else {
      throw CollaborationError("invalid_runtime_workspace", "Команде пространства нужны поля её действия: id для выбора, id и name для создания или переименования.")
    }
  }
}

public struct NotebookRuntimeBootstrapStatus: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable { case opening, ready, workspaceRequired, failed }
  public let kind: String
  public let ready: Bool
  public let pid: Int
  public let protocolVersion: Int
  public let build: String
  public let state: State
  public let workspaceID: UUID?
  public let socketKey: String?
  public let message: String?
  public init(ready: Bool, pid: Int, build: String, state: State, workspaceID: UUID? = nil, socketKey: String? = nil, message: String? = nil) {
    kind = "notebookRuntime"; self.ready = ready; self.pid = pid; self.state = state
    protocolVersion = 1; self.build = build
    self.workspaceID = workspaceID; self.socketKey = socketKey; self.message = message
  }
}

public struct NotebookRuntimeWorkspace: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let local: Bool
  public let remote: Bool
  public let deleting: Bool
  public init(id: UUID, name: String, local: Bool, remote: Bool, deleting: Bool) {
    self.id = id; self.name = name; self.local = local; self.remote = remote; self.deleting = deleting
  }
}

public struct NotebookRuntimeWorkspaceResponse: Codable, Equatable, Sendable {
  public let status: NotebookRuntimeBootstrapStatus
  public let workspaces: [NotebookRuntimeWorkspace]
  public let error: String?
  public let catalogError: String?
  public init(status: NotebookRuntimeBootstrapStatus, workspaces: [NotebookRuntimeWorkspace], error: String? = nil, catalogError: String? = nil) {
    self.status = status; self.workspaces = workspaces; self.error = error; self.catalogError = catalogError
  }
}
