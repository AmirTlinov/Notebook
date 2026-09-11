import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Native approvals and Codex account state")
struct CodexProtocolTests {
  @Test func unknownRequestIsPreservedButCannotBeApproved() throws {
    let request = CodexUserRequest(nativeID: .number(1), method: "future/request", turnID: "turn", parameters: .object([:]))
    #expect(throws: CodexBridgeError.unsupportedRequest) { try CodexAppServer.response(request: request, decision: .allowOnce) }
  }

  @Test func permissionDecisionIsExplicitAndTurnScoped() throws {
    let permissions: JSONValue = .object(["fileSystem": .object(["write": .array([.string("/tmp/test")])])])
    let request = CodexUserRequest(nativeID: .number(276), method: "item/permissions/requestApproval", turnID: "turn",
      parameters: .object(["permissions": permissions]))
    let allow = try CodexAppServer.response(request: request, decision: .allowOnce)
    let deny = try CodexAppServer.response(request: request, decision: .decline)
    #expect(allow["permissions"] == permissions); #expect(allow["scope"] == .string("turn"))
    #expect(deny["permissions"] == .object([:])); #expect(deny["scope"] == .string("turn"))
  }

  @Test func userInputCannotAnswerAnotherQuestion() throws {
    let request = CodexUserRequest(nativeID: .string("ask"), method: "item/tool/requestUserInput", turnID: "turn",
      parameters: .object(["questions": .array([.object(["id": .string("method")])])]))
    #expect(throws: CodexBridgeError.invalidInput) {
      try CodexAppServer.response(request: request, decision: .answers(["intruder": ["yes"]]))
    }
    let response = try CodexAppServer.response(request: request, decision: .answers(["method": ["Геометрия"]]))
    #expect(response["answers"]?["method"]?["answers"] == .array([.string("Геометрия")]))
  }
  @Test func defaultProviderSignInComesFromCodexWithoutChangingExistingTaskSettings() throws {
    #expect(try CodexAppServer.defaultProviderNeedsSignIn(.object(["account": .null, "requiresOpenaiAuth": .bool(true)])))
    #expect(try !CodexAppServer.defaultProviderNeedsSignIn(.object(["account": .null, "requiresOpenaiAuth": .bool(false)])))
    for type in ["chatgpt", "apiKey", "amazonBedrock"] {
      #expect(try !CodexAppServer.defaultProviderNeedsSignIn(.object([
        "account": .object(["type": .string(type)]), "requiresOpenaiAuth": .bool(true)])))
    }
    for invalid: JSONValue in [.object([:]), .object(["account": .null]),
      .object(["account": .string("token"), "requiresOpenaiAuth": .bool(true)])] {
      #expect(throws: CodexBridgeError.invalidResponse) { try CodexAppServer.defaultProviderNeedsSignIn(invalid) }
    }
  }

}
