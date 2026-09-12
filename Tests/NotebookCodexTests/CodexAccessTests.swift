import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Native access choices")
struct CodexAccessTests {
  private func tool(persist: JSONValue? = nil) -> CodexUserRequest {
    var meta: [String: JSONValue] = ["codex_approval_kind": .string("mcp_tool_call")]
    meta["persist"] = persist
    return .init(nativeID: .number(7), method: "mcpServer/elicitation/request", turnID: "turn", parameters: .object([
      "mode": .string("form"), "_meta": .object(meta), "requestedSchema": .object(["type": .string("object"), "properties": .object([:])])]))
  }
  @Test func rememberedMCPChoiceUsesOnlyThePersistenceAdvertisedByCodex() throws {
    let request = tool(persist: .array([.string("session"), .string("always")]))
    #expect(request.approvalDecisions == [.allowOnce, .allowSession, .allowAlways, .decline])
    for (decision, scope) in [(CodexUserDecision.allowSession, "session"), (.allowAlways, "always")] {
      let reply = try CodexAppServer.response(request: request, decision: decision)
      #expect(reply == .object(["action": .string("accept"), "content": .object([:]), "_meta": .object(["persist": .string(scope)])]))
    }
    #expect(try CodexAppServer.response(request: request, decision: .allowOnce)["_meta"] == nil)
    #expect(throws: CodexBridgeError.unsupportedRequest) { try CodexAppServer.response(request: tool(), decision: .allowAlways) }
    #expect(tool(persist: .string("session")).approvalDecisions == [.allowOnce, .allowSession, .decline])
  }
  @Test func sessionFilesystemGrantCannotExpandTheRequestedPermissions() throws {
    let permissions: JSONValue = .object(["fileSystem": .object(["read": .array([.string("/one/file")])])])
    let request = CodexUserRequest(nativeID: .string("native"), method: "item/permissions/requestApproval", turnID: "turn", parameters: .object(["permissions": permissions]))
    #expect(try CodexAppServer.response(request: request, decision: .allowSession) == .object(["permissions": permissions, "scope": .string("session")]))
    #expect(try CodexAppServer.response(request: request, decision: .decline)["permissions"] == .object([:]))
    #expect(throws: CodexBridgeError.unsupportedRequest) { try CodexAppServer.response(request: request, decision: .allowAlways) }
    let command = CodexUserRequest(nativeID: .number(1), method: "item/commandExecution/requestApproval", turnID: "turn",
      parameters: .object(["availableDecisions": .array([.string("accept"), .string("decline")])]))
    #expect(command.approvalDecisions == [.allowOnce, .decline])
    #expect(throws: CodexBridgeError.unsupportedRequest) { try CodexAppServer.response(request: command, decision: .allowSession) }
  }
  @Test func genericFormsAreNotMistakenForEmptyToolApprovals() {
    let request = CodexUserRequest(nativeID: .number(2), method: "mcpServer/elicitation/request", turnID: "turn", parameters: .object([
      "mode": .string("form"), "_meta": .object(["codex_approval_kind": .string("mcp_tool_call")]),
      "requestedSchema": .object(["type": .string("object"), "properties": .object(["account": .object(["type": .string("string")])])])]))
    #expect(!request.isToolApproval); #expect(request.approvalDecisions.isEmpty)
  }
  @Test func settingsArePublishedOnlyFromTheMatchingNativeThread() throws {
    var state = CodexAppServerState(threadID: "current")
    state.access = .init(profileID: CodexAccessMode.workspace.rawValue, approvalPolicy: .string("on-request"), available: CodexAccessMode.allCases)
    func event(_ thread: String) -> JSONValue { .object(["method": .string("thread/settings/updated"), "params": .object([
      "threadId": .string(thread), "threadSettings": .object(["activePermissionProfile": .object(["id": .string(":danger-full-access")]), "approvalPolicy": .string("never")])])]) }
    #expect(try !state.accept(event("other"))); #expect(state.view.access?.mode == .workspace)
    #expect(try state.accept(event("current"))); #expect(state.view.access?.mode == .full)
    #expect(state.view.access?.available == CodexAccessMode.allCases)
    #expect(CodexAccess(profileID: ":danger-full-access", approvalPolicy: .string("on-request"), available: []).mode == nil)
  }
}
