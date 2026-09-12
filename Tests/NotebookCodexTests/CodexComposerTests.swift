import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Native composer contract") struct CodexComposerTests {
  @Test func cataloguePreservesServerEffortsAndDefaultInsteadOfInventingOptions() throws {
    let row: JSONValue = .object(["model": .string("future-model"), "displayName": .string("Future Model"),
      "defaultReasoningEffort": .string("new-effort"), "isDefault": .bool(true),
      "supportedReasoningEfforts": .array([.object(["reasoningEffort": .string("low")]), .object(["reasoningEffort": .string("new-effort")])])])
    let model = try CodexAppServer.modelOption(row)
    #expect(model.id == "future-model"); #expect(model.efforts == ["low", "new-effort"])
    #expect(model.defaultEffort == "new-effort"); #expect(model.isDefault)
  }
  @Test func attachmentsAreNativeInputsAndFilePathsRemainExplicit() throws {
    let attachments: [CodexInputAttachment] = [
      .init(kind: .file, name: "file.swift", path: "/tmp/file.swift"),
      .init(kind: .skill, name: "skill", path: "/tmp/SKILL.md"),
      .init(kind: .plugin, name: "plugin", path: "plugin://plugin@market"),
      .init(kind: .app, name: "app", path: "app://app-id")]
    let input = try CodexAppServer.composerInput(text: "Посмотри", attachments: attachments)
    #expect(input.count == 5); #expect(input[0]["text"]?.string?.contains("/tmp/file.swift") == true)
    #expect(input[2]["type"] == .string("skill")); #expect(input[3]["path"] == .string("plugin://plugin@market"))
    #expect(input[4]["type"] == .string("mention"))
    #expect(!CodexInputAttachment(kind: .file, name: "bad", path: "/tmp/../secret").isValid)
    #expect(throws: CodexBridgeError.invalidInput) { try CodexAppServer.composerInput(text: "", attachments: attachments + attachments) }
  }
  @Test func usageTracksLastContextNotAccumulatedTokensAndSurvivesHydration() throws {
    var state = CodexAppServerState(threadID: "thread")
    let event: JSONValue = .object(["method": .string("thread/tokenUsage/updated"), "params": .object([
      "threadId": .string("thread"), "turnId": .string("turn"), "tokenUsage": .object([
        "last": .object(["totalTokens": .number(75)]), "total": .object(["totalTokens": .number(900)]), "modelContextWindow": .number(100)])])])
    #expect(try state.accept(event)); #expect(state.view.contextUsage?.used == 75)
    #expect(state.view.contextUsage?.fraction == 0.75)
    try state.hydrate(thread: .object(["id": .string("thread")]), history: [], turns: [.object(["id": .string("active"), "status": .string("inProgress")])])
    #expect(state.view.activeTurnID == "active")
    #expect(state.view.contextUsage?.fraction == 0.75)
    #expect(try state.accept(.object(["method": .string("thread/settings/updated"), "params": .object([
      "threadId": .string("thread"), "threadSettings": .object(["model": .string("different"), "effort": .string("high"), "approvalPolicy": .string("on-request")])])])))
    #expect(state.view.model == .init(model: "different", effort: "high")); #expect(state.view.contextUsage == nil)
    #expect(CodexContextUsage(used: 2, window: nil).fraction == nil)
  }
}
