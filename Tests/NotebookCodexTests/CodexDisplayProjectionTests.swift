import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Bounded native items and project cursors")
struct CodexDisplayProjectionTests {
  @Test func activitiesAreNativeItemsAndDoNotExposeReasoning() throws {
    let command: JSONValue = .object(["id": .string("cmd"), "type": .string("commandExecution"), "command": .string("swift test"), "status": .string("inProgress"), "aggregatedOutput": .string("building")])
    let message = try #require(CodexAppServerState.displayMessage(command, turnID: "turn"))
    #expect(message.id == "cmd"); #expect(message.turnID == "turn")
    #expect(message.activity?.kind == .command); #expect(message.activity?.status == "inProgress")
    #expect(message.activity?.detail == "swift test\n\nbuilding")
    #expect(CodexAppServerState.displayMessage(.object(["id": .string("secret"), "type": .string("reasoning"), "content": .array([.string("hidden")])]), turnID: "turn") == nil)
  }
  @Test func projectContinuationBindsBothNativeStreamsToTheSameProject() throws {
    let project = CodexProject(id: "project", name: "Notebook", roots: ["/workspace"])
    var cursor = try CodexProjectTaskCursor(cursor: nil, project: project)
    cursor.members = "canonical-next"; cursor.folders = "folder-next"
    let continuation = try cursor.encoded()
    let encoded = try #require(continuation)
    let decoded = try CodexProjectTaskCursor(cursor: encoded, project: project)
    #expect(decoded.members == "canonical-next"); #expect(decoded.folders == "folder-next")
    #expect(throws: CodexBridgeError.invalidInput) {
      try CodexProjectTaskCursor(cursor: encoded, project: CodexProject(id: "other", name: "Other", roots: project.roots))
    }
    #expect(throws: CodexBridgeError.invalidInput) {
      try CodexProjectTaskCursor(cursor: encoded, project: CodexProject(id: project.id, name: "Notebook", roots: ["/other"]))
    }
    cursor.membersDone = true; cursor.foldersDone = true
    #expect(try cursor.encoded() == nil)
    let noRoots = try CodexProjectTaskCursor(cursor: nil, project: CodexProject(id: "id", name: "name", roots: []))
    #expect(noRoots.foldersDone); #expect(!noRoots.membersDone)
  }
  @Test func nativeActivityDetailsNameTheirExcerpt() throws {
    let item: JSONValue = .object(["id": .string("command"), "type": .string("commandExecution"),
      "command": .string("test"), "aggregatedOutput": .string(String(repeating: "x", count: 9000)), "status": .string("completed")])
    let display = try #require(CodexAppServerState.displayMessage(item, turnID: "turn"))
    #expect(display.activity?.detail?.count == 8192); #expect(display.isTruncated)
    let page = CodexMessage.transportPage([display])
    #expect(page[0].isTruncated)
  }
  @Test func transportPreservesAllItemsAndNamesEveryTextExcerpt() throws {
    let items = (0..<32).map { i in CodexMessage(id: "item-\(i)", turnID: "turn", clientID: nil, role: .assistant,
      text: String(repeating: "🙂привет", count: 3000), activity: .init(kind: .command, status: "completed", detail: String(repeating: "命令", count: 9000))) }
    let page = CodexMessage.transportPage(items)
    #expect(page.map(\.id) == items.map(\.id)); #expect(page.allSatisfy { $0.isTruncated })
    #expect(try JSONEncoder().encode(page).count < 96 * 1024)
    #expect(page.allSatisfy { !$0.text.contains("�") })
  }
}
