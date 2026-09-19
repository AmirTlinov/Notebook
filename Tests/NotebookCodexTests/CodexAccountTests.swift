import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite struct CodexAccountTests {
  @Test func deviceCodeNeverAcceptsAnArbitraryLoginOrigin() throws {
    func response(_ url: String) -> JSONValue { .object(["type": .string("chatgptDeviceCode"), "loginId": .string(UUID().uuidString),
      "verificationUrl": .string(url), "userCode": .string("ABCD-EFGH")]) }
    #expect(try CodexAccountSession.deviceLogin(response("https://auth.openai.com/codex/device")).isValid)
    for url in ["http://auth.openai.com/codex/device", "https://auth.openai.com.evil.test/codex/device", "https://user@auth.openai.com/codex/device", "https://auth.openai.com/codex/device?token=x", "http://127.0.0.1:1455/auth/callback"] {
      #expect(throws: CodexBridgeError.unsafeEndpoint) { try CodexAccountSession.deviceLogin(response(url)) }
    }
  }
  @Test func accountRevisionTracksIdentityAndNullLimitsStayUnknown() throws {
    var session = CodexAccountSession()
    let account: JSONValue = .object(["requiresOpenaiAuth": .bool(true), "account": .object(["type": .string("chatgpt"), "email": .string("fixture@example.test"), "planType": .string("pro")])])
    session.login = .init(id: UUID().uuidString, verificationURL: URL(string: "https://auth.openai.com/codex/device")!, userCode: "ABCD-EFGH")
    try session.read(account); let revision = session.revision
    #expect(session.login == nil)
    try session.read(account); #expect(session.revision == revision)
    #expect(session.initialized && !session.requiresSignIn)
    #expect(try CodexAccountSession.limits(.object(["rateLimits": .null])).isEmpty)
    #expect(CodexAccountState.Account(type: "chatgpt", email: "x", plan: "pro").identity == CodexAccountState.Account(type: "chatgpt", email: "x", plan: "plus").identity)
    try session.read(.object(["requiresOpenaiAuth": .bool(true), "account": .null]))
    #expect(session.account == nil && session.requiresSignIn && session.revision != revision)
  }
  @Test func completionOnlyClearsItsNativeLoginAndLimitsAreRemaining() throws {
    var session = CodexAccountSession(); let id = UUID().uuidString
    session.login = .init(id: id, verificationURL: URL(string: "https://auth.openai.com/codex/device")!, userCode: "ABCD-EFGH")
    let received1 = session.receive(.object(["method": .string("account/login/completed"), "params": .object(["loginId": .string(UUID().uuidString), "success": .bool(false)])]))
    #expect(received1)
    #expect(session.login != nil)
    let received2 = session.receive(.object(["method": .string("account/login/completed"), "params": .object(["loginId": .string(id), "success": .bool(false)])]))
    #expect(received2)
    #expect(session.login == nil && session.message != nil)
    let limits = try CodexAccountSession.limits(.object(["rateLimitsByLimitId": .object(["codex": .object(["primary": .object(["usedPercent": .number(23), "windowDurationMins": .number(300)]), "secondary": .null])])]))
    #expect(limits.count == 1 && limits[0].remainingPercent == 77 && limits[0].resetsAt == nil)
  }
}
