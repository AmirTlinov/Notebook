import Foundation

/// One user-selected command on one computer/project/root. The run UUID is
/// also its durable chat input UUID; reconnecting is a read, not another start.
public struct NotebookRunRequest: Codable, Equatable, Sendable {
  public let root: NotebookFileAddress
  public let command: String
  public let replacing: UUID?
  public let columns: Int
  public let rows: Int
  public init(root: NotebookFileAddress, command: String, replacing: UUID? = nil, columns: Int = 80, rows: Int = 24) {
    self.root = root; self.command = command; self.replacing = replacing; self.columns = columns; self.rows = rows
  }
  public var isValid: Bool { root.isValid && root.path.isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && command.utf8.count <= 8192 && !command.contains("\0") && (20...500).contains(columns) && (4...200).contains(rows) }
}
public struct NotebookRunRecord: Codable, Equatable, Sendable, Identifiable {
  public enum Phase: String, Codable, Sendable { case starting, running, exited, interrupted }
  public let id: UUID
  public let author: UUID
  public let request: NotebookRunRequest
  public var phase: Phase
  public var exitCode: Int?
  public var error: String?
  public let createdAt: Date
  public var isActive: Bool { phase == .starting || phase == .running }
  public init(id: UUID, author: UUID, request: NotebookRunRequest, phase: Phase = .starting, exitCode: Int? = nil, error: String? = nil, createdAt: Date = Date()) {
    self.id = id; self.author = author; self.request = request; self.phase = phase; self.exitCode = exitCode; self.error = error; self.createdAt = createdAt
  }
}
public struct NotebookRunOutput: Codable, Equatable, Sendable {
  public let record: NotebookRunRecord?
  public let data: Data
  public let after: String
  public let lostPrefix: Bool
  public let more: Bool
  public init(record: NotebookRunRecord?, data: Data = Data(), after: String = "0", lostPrefix: Bool = false, more: Bool = false) {
    self.record = record; self.data = data; self.after = after; self.lostPrefix = lostPrefix; self.more = more
  }
}
public struct NotebookRunRead: Codable, Equatable, Sendable {
  public let root: NotebookFileAddress
  public let runID: UUID?
  public let after: String
  public init(root: NotebookFileAddress, runID: UUID? = nil, after: String = "0") { self.root = root; self.runID = runID; self.after = after }
  public var isValid: Bool { root.isValid && root.path.isEmpty && UInt64(after).map { $0 <= VersionStamp.maximumCounter && String($0) == after } == true }
}
public enum NotebookProcessEvent: Sendable {
  case running
  case output(Data)
  case exited(Int)
  case interrupted(String)
}
