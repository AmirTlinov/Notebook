import Foundation
import CryptoKit

/// Public account presentation only. OAuth credentials never enter Notebook's wire or store.
public enum CodexAccountQuery: Codable, Equatable, Sendable {
  case read
  case beginLogin(attempt: UUID)
  case cancelLogin(id: String)
  case logout(revision: UUID)
}

public struct CodexAccountState: Codable, Equatable, Sendable {
  public struct Account: Codable, Equatable, Sendable {
    public let type: String
    public let email: String?
    public let plan: String?
    /// Public identity fingerprint only, never an OAuth credential. Plan/limits
    /// are deliberately excluded: a subscription change is not a new person.
    public var identity: String {
      SHA256.hash(data: Data((type + "\n" + (email ?? "")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public init(type: String, email: String?, plan: String?) { self.type = type; self.email = email; self.plan = plan }
  }
  public struct Login: Codable, Equatable, Sendable {
    public let id: String
    public let verificationURL: URL
    public let userCode: String
    public init(id: String, verificationURL: URL, userCode: String) {
      self.id = id; self.verificationURL = verificationURL; self.userCode = userCode
    }
    public var isValid: Bool {
      UUID(uuidString: id) != nil && verificationURL.scheme == "https"
        && verificationURL.host == "auth.openai.com" && verificationURL.path == "/codex/device"
        && verificationURL.user == nil && verificationURL.password == nil && verificationURL.port == nil
        && verificationURL.query == nil && verificationURL.fragment == nil
        && !userCode.isEmpty && userCode.utf8.count <= 64
    }
  }
  public struct Limit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let usedPercent: Int
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
    public init(id: String, usedPercent: Int, durationMinutes: Int?, resetsAt: Date?) {
      self.id = id; self.usedPercent = usedPercent; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }
  }
  public let revision: UUID
  public let account: Account?
  public let requiresSignIn: Bool
  public let login: Login?
  public let limits: [Limit]?
  public let message: String?
  public init(revision: UUID, account: Account?, requiresSignIn: Bool, login: Login? = nil,
    limits: [Limit]? = nil, message: String? = nil) {
    self.revision = revision; self.account = account; self.requiresSignIn = requiresSignIn
    self.login = login; self.limits = limits; self.message = message
  }
}
