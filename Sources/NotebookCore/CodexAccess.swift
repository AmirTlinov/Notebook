import Foundation

/// The built-in profiles are selected on the native Codex thread, not stored as
/// a second permission policy in Notebook or applied to unrelated tasks.
public enum CodexAccessMode: String, Codable, Sendable, CaseIterable {
  case readOnly = ":read-only", workspace = ":workspace", full = ":danger-full-access"
  public var approvalPolicy: String { self == .full ? "never" : "on-request" }
}

public struct CodexAccess: Codable, Equatable, Sendable {
  public let profileID: String?
  public let approvalPolicy: JSONValue
  public let available: [CodexAccessMode]
  public init(profileID: String?, approvalPolicy: JSONValue, available: [CodexAccessMode]) {
    self.profileID = profileID; self.approvalPolicy = approvalPolicy; self.available = available
  }
  public var mode: CodexAccessMode? {
    guard let profileID, let mode = CodexAccessMode(rawValue: profileID), approvalPolicy == .string(mode.approvalPolicy) else { return nil }
    return mode
  }
}

extension CodexUserRequest {
  public var isToolApproval: Bool {
    guard method == "mcpServer/elicitation/request", parameters["mode"] == .string("form"),
      parameters["_meta"]?["codex_approval_kind"] == .string("mcp_tool_call"),
      parameters["requestedSchema"]?["type"] == .string("object"),
      case .object(let fields) = parameters["requestedSchema"]?["properties"], fields.isEmpty else { return false }
    if case .array(let required) = parameters["requestedSchema"]?["required"], !required.isEmpty { return false }
    return true
  }
  public var approvalDecisions: [CodexUserDecision] {
    switch method {
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      let candidates: [(CodexUserDecision, String)] = [(.allowOnce, "accept"), (.allowSession, "acceptForSession"), (.decline, "decline")]
      if case .array(let offered) = parameters["availableDecisions"] {
        return candidates.filter { offered.contains(.string($0.1)) }.map(\.0)
      }
      return candidates.map(\.0)
    case "item/permissions/requestApproval": return [.allowOnce, .allowSession, .decline]
    default:
      guard isToolApproval else { return [] }
      var choices: [CodexUserDecision] = [.allowOnce]
      let offered = parameters["_meta"]?["persist"]
      for (scope, decision) in [("session", CodexUserDecision.allowSession), ("always", .allowAlways)] {
        if offered == .string(scope) || { if case .array(let values) = offered { return values.contains(.string(scope)) }; return false }() { choices.append(decision) }
      }
      return choices + [.decline]
    }
  }
}
