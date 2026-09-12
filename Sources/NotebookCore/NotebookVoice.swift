import Foundation

/// A WebRTC offer carries no Codex credential. Authorization and the selected
/// task remain on its paired Mac's existing App Server connection.
public struct NotebookVoiceStart: Codable, Equatable, Sendable {
  public let threadID: String
  public let sdp: String
  public init(threadID: String, sdp: String) { self.threadID = threadID; self.sdp = sdp }
  public var isValid: Bool { UUID(uuidString: threadID) != nil && sdp.hasPrefix("v=0") && sdp.utf8.count <= 65_536 && !sdp.contains("\0") }
}
public struct NotebookVoiceState: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable { case starting, active, ending, ended, failed }
  public let id: UUID
  public let threadID: String
  public var phase: Phase
  public var sdp: String?
  public var userText: String
  public var assistantText: String
  public var error: String?
  public var isActive: Bool { phase == .starting || phase == .active || phase == .ending }
  public init(id: UUID, threadID: String, phase: Phase = .starting, sdp: String? = nil, userText: String = "", assistantText: String = "", error: String? = nil) {
    self.id = id; self.threadID = threadID; self.phase = phase; self.sdp = sdp; self.userText = userText; self.assistantText = assistantText; self.error = error
  }
}
