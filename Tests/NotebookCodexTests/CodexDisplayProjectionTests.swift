import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Bounded native project and conversation display")
struct CodexDisplayProjectionTests {
  let thread = "01a08819-fe31-7ba2-b2a3-b20a3ca8e56e"
  func raw(turns: [JSONValue], requests: [JSONValue] = []) -> JSONValue {
    .object(["type": .string("broadcast"), "method": .string("thread-stream-state-changed"), "version": .number(11), "sourceClientId": .string("owner"),
      "params": .object(["hostId": .string("local"), "conversationId": .string(thread), "change": .object([
        "type": .string("snapshot"), "revision": .number(1), "conversationState": .object([
          "id": .string(thread), "hostId": .string("local"), "title": .string("Настоящий чат"), "resumeState": .string("resumed"),
          "threadRuntimeStatus": .object(["type": .string("active")]), "turns": .array(turns), "requests": .array(requests)])])])])
  }
  func frame(_ value: JSONValue) throws -> Data {
    let data = try JSONEncoder().encode(value)
    var size = UInt32(data.count).littleEndian
    return withUnsafeBytes(of: &size) { Data($0) } + data
  }
  func project(_ value: JSONValue) throws -> JSONValue {
    try JSONDecoder().decode(CodexWireProjection.self, from: JSONEncoder().encode(value)).value
  }
  @Test func largeHistoryUsesPrivateFileAndKeepsOnlyIndexedTail() throws {
    let hidden = String(repeating: "private-reasoning-do-not-display", count: 400_000)
    let items: [JSONValue] = (0..<140).map { i in
      i == 0 ? .object(["type": .string("reasoning"), "id": .string("hidden"), "content": .array([.string(hidden)])]) :
        .object(["type": .string("agentMessage"), "id": .string("item-\(i)"), "text": .string("Публичный ответ \(i)")])
    }
    let value = raw(turns: [.object(["turnId": .string("turn"), "status": .string("inProgress"), "items": .array(items)])])
    let bytes = try frame(value), decoder = CodexDesktopFrames()
    #expect(bytes.count > CodexDesktopProtocol.frameLimit)
    let first = try decoder.append(bytes.prefix(20)); #expect(first.isEmpty)
    let temporary = try #require(decoder.temporaryURL)
    let permissions = try FileManager.default.attributesOfItem(atPath: temporary.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    let result = try #require(decoder.append(bytes.dropFirst(20)).first)
    #expect(!FileManager.default.fileExists(atPath: temporary.path)); #expect(decoder.temporaryURL == nil)
    #expect(try JSONEncoder().encode(result).count < 32_768)
    var state = CodexStreamState(threadID: thread, owner: "owner")
    let accepted = try state.accept(result)
    let display = try #require(accepted)
    #expect(display.busy); #expect(display.activeTurnID == "turn")
    #expect(display.messages.count == 64); #expect(display.messages.last?.id == "item-139")
    #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("private-reasoning"))
  }
  @Test func fragmentedProjectedFramesKeepUnicodeAndNativeIDs() throws {
    let item: JSONValue = .object(["type": .string("agentMessage"), "id": .string("native"), "text": .string("∫ x² dx 👨‍👩‍👧‍👦")])
    let value = raw(turns: [.object(["turnId": .string("turn"), "status": .string("completed"), "items": .array([item])])])
    let bytes = try frame(value), expected = try project(value)
    for split in 0..<bytes.count {
      let decoder = CodexDesktopFrames()
      let decoded = try decoder.append(bytes.prefix(split)) + decoder.append(bytes.dropFirst(split))
      #expect(decoded == [expected])
    }
  }
  @Test func closingPartialFrameRemovesOnlyItsOwnTemporaryFile() throws {
    var decoder: CodexDesktopFrames? = CodexDesktopFrames()
    var count = UInt32(2 * 1_048_576).littleEndian
    _ = try decoder?.append(withUnsafeBytes(of: &count) { Data($0) } + Data([123]))
    let temporary = try #require(decoder?.temporaryURL)
    decoder = nil
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
  }
  @Test func permissionsRemainExactAndLargeRequestsRefuseInsteadOfTruncating() throws {
    let command = String(repeating: "a", count: 20_000)
    let request: JSONValue = .object(["id": .number(7), "method": .string("item/commandExecution/requestApproval"), "params": .object([
      "threadId": .string(thread), "turnId": .string("turn"), "command": .string(command)])])
    var state = CodexStreamState(threadID: thread, owner: "owner")
    let accepted = try state.accept(project(raw(turns: [], requests: [request])))
    let display = try #require(accepted)
    #expect(display.requests.first?.parameters["command"] == .string(command))
    let huge: JSONValue = .object(["id": .number(8), "params": .object(["command": .string(String(repeating: "x", count: 70_000))])])
    #expect(throws: CodexBridgeError.historyLimit) { try project(raw(turns: [], requests: [huge])) }
  }
  @Test func activitiesAreNativeItemsAndDoNotExposeReasoning() throws {
    let command: JSONValue = .object(["id": .string("cmd"), "type": .string("commandExecution"), "command": .string("swift test"), "status": .string("inProgress"), "aggregatedOutput": .string("building")])
    let message = try #require(CodexStreamState.displayMessage(command, turnID: "turn"))
    #expect(message.id == "cmd"); #expect(message.turnID == "turn")
    #expect(message.activity?.kind == .command); #expect(message.activity?.status == "inProgress")
    #expect(message.activity?.detail == "swift test\n\nbuilding")
    #expect(CodexStreamState.displayMessage(.object(["id": .string("secret"), "type": .string("reasoning"), "content": .array([.string("hidden")])]), turnID: "turn") == nil)
  }
  @Test func oldItemEditsPreserveIndicesWithoutRehydratingHistory() throws {
    let items: [JSONValue] = (0..<140).map { .object(["id": .string("item-\($0)"), "type": .string("agentMessage"), "text": .string("visible")]) }
    var state = CodexStreamState(threadID: thread, owner: "owner")
    _ = try state.accept(project(raw(turns: [.object(["turnId": .string("turn"), "status": .string("inProgress"), "items": .array(items)])])))
    func patch(_ op: String, index: Int, value: JSONValue?, revision: Int) throws -> JSONValue {
      var row: [String: JSONValue] = ["op": .string(op), "path": .array([.string("turns"), .number(0), .string("items"), .number(Double(index))])]
      if let value { row["value"] = value }
      return try project(.object(["type": .string("broadcast"), "method": .string("thread-stream-state-changed"), "version": .number(11), "sourceClientId": .string("owner"),
        "params": .object(["hostId": .string("local"), "conversationId": .string(thread), "change": .object(["type": .string("patches"), "baseRevision": .number(Double(revision - 1)), "revision": .number(Double(revision)), "patches": .array([.object(row)])])])]))
    }
    _ = try state.accept(patch("replace", index: 0, value: items[0], revision: 2))
    #expect(state.value?["turns"]?.array?[0]["items"]?.array?[0] == .null)
    _ = try state.accept(patch("add", index: 0, value: items[0], revision: 3))
    #expect(state.value?["turns"]?.array?[0]["items"]?.array?.count == 141)
    #expect(state.value?["turns"]?.array?[0]["items"]?.array?[0] == .null)
    _ = try state.accept(patch("remove", index: 0, value: nil, revision: 4))
    #expect(state.value?["turns"]?.array?[0]["items"]?.array?.count == 140)
    _ = try state.accept(patch("replace", index: 139, value: .object(["id": .string("last"), "type": .string("agentMessage"), "text": .string("new")]), revision: 5))
    #expect(state.value?["turns"]?.array?[0]["items"]?.array?.last?["id"] == .string("last"))
  }
  @Test func oldUserAcceptanceSurvivesDisplayEviction() throws {
    let user: JSONValue = .object(["id": .string("user"), "type": .string("userMessage"), "clientId": .string("client"), "content": .array([.textInput("original")])])
    let commands: [JSONValue] = (0..<140).map { .object(["id": .string("cmd-\($0)"), "type": .string("commandExecution"), "command": .string("test"), "status": .string("completed")]) }
    var state = CodexStreamState(threadID: thread, owner: "owner")
    let accepted = try state.accept(project(raw(turns: [.object(["turnId": .string("turn"), "status": .string("completed"), "items": .array([user] + commands)])])))
    let display = try #require(accepted)
    #expect(display.acceptedMessages["client"] == "turn")
    #expect(!display.messages.contains { $0.id == "user" })
    #expect(state.value?["turns"]?.array?[0]["items"]?.array?[0]["content"] == nil)
    #expect(state.value?["turns"]?.array?[0]["items"]?.array?[0]["clientId"] == .string("client"))
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
    let display = try #require(CodexStreamState.displayMessage(item, turnID: "turn"))
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
