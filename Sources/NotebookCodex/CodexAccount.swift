import Foundation
import NotebookCore

/// One account ceremony per official host profile, independent of workspace/UI.
struct CodexAccountSession {
  var revision = UUID()
  var initialized = false
  var account: CodexAccountState.Account?
  var requiresSignIn = true
  var attempt: UUID?
  var login: CodexAccountState.Login?
  var message: String?
  var changing = false
  var lastLogoutRevision: UUID?

  mutating func read(_ value: JSONValue) throws {
    let needs = try CodexAppServer.defaultProviderNeedsSignIn(value)
    let current = value["account"]
    let next: CodexAccountState.Account?
    if let type = current?["type"]?.string {
      next = .init(type: type, email: current?["email"]?.string, plan: current?["planType"]?.string)
    } else { next = nil }
    if account?.identity != next?.identity { revision = UUID() }
    account = next
    // A confirmed native account supersedes a delayed/missed login completion event.
    if next != nil { login = nil }
    requiresSignIn = needs; initialized = true
  }

  mutating func receive(_ frame: JSONValue) -> Bool {
    switch frame["method"]?.string {
    case "account/login/completed":
      guard frame["params"]?["loginId"]?.string == login?.id else { return true }
      login = nil
      message = frame["params"]?["success"] == .bool(true) ? "Вход выполнен." : "Вход не завершён или код истёк. Начните вход снова."
      revision = UUID()
      return true
    case "account/updated": revision = UUID(); return true
    case "account/rateLimits/updated": return true
    default: return false
    }
  }

  static func deviceLogin(_ value: JSONValue) throws -> CodexAccountState.Login {
    guard value["type"] == .string("chatgptDeviceCode"), let id = value["loginId"]?.string,
      let link = value["verificationUrl"]?.string, let url = URL(string: link), let code = value["userCode"]?.string else {
      throw CodexBridgeError.invalidResponse
    }
    let login = CodexAccountState.Login(id: id, verificationURL: url, userCode: code)
    guard login.isValid else { throw CodexBridgeError.unsafeEndpoint }
    return login
  }

  static func limits(_ value: JSONValue) throws -> [CodexAccountState.Limit] {
    let buckets = value["rateLimitsByLimitId"]?.object ?? value["rateLimits"].map { ["codex": $0] } ?? [:]
    guard buckets.count <= 64 else { throw CodexBridgeError.invalidResponse }
    var result: [CodexAccountState.Limit] = []
    for (id, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
      for name in ["primary", "secondary"] {
        guard let window = bucket[name], window != .null else { continue }
        guard let used = window["usedPercent"]?.integer else { throw CodexBridgeError.invalidResponse }
        result.append(.init(id: id + "/" + name, usedPercent: used,
          durationMinutes: window["windowDurationMins"]?.integer,
          resetsAt: window["resetsAt"]?.integer.map { Date(timeIntervalSince1970: Double($0)) }))
      }
    }
    return result
  }
}

extension CodexAppServer {
  public func account(_ query: CodexAccountQuery, includeLimits: Bool = true) async throws -> CodexAccountState {
    let rpc = try await connect()
    guard !accountSession.changing else { throw CodexBridgeError.busy }
    var ownsGate: Bool
    if case .read = query { ownsGate = false } else { ownsGate = true; accountSession.changing = true }
    defer { if ownsGate { accountSession.changing = false } }
    try await refreshAccount(rpc)
    switch query {
    case .read: break
    case .beginLogin(let attempt):
      guard !hasActiveWork() else { throw CodexBridgeError.busy }
      if accountSession.attempt != attempt {
        guard accountSession.account == nil, accountSession.login == nil else { throw CodexBridgeError.busy }
        // Claim before the native request. A lost reply must never start a second OAuth flow.
        accountSession.attempt = attempt; accountSession.message = "Проверяется начало входа. При потере ответа начните вход заново явно."
        let result = try await rpc.request("account/login/start", params: .object(["type": .string("chatgptDeviceCode")]))
        accountSession.login = try CodexAccountSession.deviceLogin(result); accountSession.message = nil
      }
    case .cancelLogin(let id):
      if accountSession.login?.id == id {
        _ = try await rpc.request("account/login/cancel", params: .object(["loginId": .string(id)]))
        accountSession.login = nil; accountSession.message = "Вход отменён."
      }
    case .logout(let revision):
      if accountSession.lastLogoutRevision != revision {
        guard revision == accountSession.revision else { throw CodexBridgeError.staleRequest }
        guard !hasActiveWork(), accountSession.login == nil else { throw CodexBridgeError.busy }
        // One-way admission, including an uncertain response. Never log out a later account on retry.
        accountSession.lastLogoutRevision = revision
        _ = try await rpc.request("account/logout", params: .object([:]))
        accountSession.account = nil; accountSession.requiresSignIn = true; accountSession.revision = UUID()
        accountSession.message = "Вы вышли из общего профиля Codex на Mac. Устройства Notebook остаются сопряжены."
        invalidateAccountPresentation()
      }
    }
    // Account admission is complete. A slow rate-limit read must not hold the
    // mutation gate or stall independent task controls. Capture its own revision.
    let presentation = accountSession
    if ownsGate { accountSession.changing = false; ownsGate = false }
    let limits: [CodexAccountState.Limit]?
    if includeLimits, presentation.account?.type == "chatgpt" {
      limits = try? CodexAccountSession.limits(await rpc.request("account/rateLimits/read", params: .object([:])))
    } else { limits = nil }
    return .init(revision: presentation.revision, account: presentation.account,
      requiresSignIn: presentation.requiresSignIn, login: presentation.login,
      limits: limits, message: presentation.message)
  }

  /// Concurrent readers share a native read; only login/logout owns the mutation
  /// gate. A notification invalidates an older snapshot instead of restoring it.
  private func refreshAccount(_ rpc: CodexRPC) async throws {
    if let read = accountRead { try await read.task.value; return }
    let id = UUID(), revision = accountSession.revision
    let task = Task {
      let value = try await rpc.request("account/read", params: .object(["refreshToken": .bool(false)]))
      guard accountSession.revision == revision else { throw CodexBridgeError.unavailable }
      let identity = accountSession.account?.identity, initialized = accountSession.initialized
      try accountSession.read(value)
      if initialized, identity != accountSession.account?.identity { invalidateAccountPresentation() }
    }
    accountRead = (id, task)
    defer { if accountRead?.id == id { accountRead = nil } }
    try await task.value
  }

}
