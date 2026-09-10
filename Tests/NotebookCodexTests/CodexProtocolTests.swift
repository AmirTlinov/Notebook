import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Desktop frames, owner identity and canonical stream")
struct CodexProtocolTests {
  let thread = "01a08ad3-dc00-72c1-93f5-7b006b7e7dc0"
  let owner = "desktop-owner"

  func envelope(_ change: JSONValue, version: Int = 11, owner: String = "desktop-owner", thread: String? = nil) -> JSONValue {
    .object(["type": .string("broadcast"), "method": .string("thread-stream-state-changed"),
      "version": .number(Double(version)), "sourceClientId": .string(owner),
      "params": .object(["hostId": .string("local"), "conversationId": .string(thread ?? self.thread), "change": change])])
  }
  func snapshot(revision: Int = 1, turns: [JSONValue] = [], requests: [JSONValue] = []) -> JSONValue {
    envelope(.object(["type": .string("snapshot"), "revision": .number(Double(revision)),
      "conversationState": .object(["id": .string(thread), "hostId": .string("local"), "title": .string("Математика"),
        "resumeState": .string("resumed"), "turns": .array(turns), "requests": .array(requests),
        "threadRuntimeStatus": .object(["type": .string("idle")])])]))
  }
  func patch(_ operations: [JSONValue], base: Int = 1, revision: Int = 2) -> JSONValue {
    envelope(.object(["type": .string("patches"), "baseRevision": .number(Double(base)),
      "revision": .number(Double(revision)), "patches": .array(operations)]))
  }
  func op(_ name: String, _ path: [JSONValue], _ value: JSONValue? = nil) -> JSONValue {
    var fields: [String: JSONValue] = ["op": .string(name), "path": .array(path)]
    fields["value"] = value
    return .object(fields)
  }

  @Test func fragmentedFrameAndUnicode() throws {
    let value: JSONValue = .object(["text": .string("∫ x² dx 👨‍👩‍👧‍👦")])
    for framing in [CodexFrames.Framing.length, .lines] {
      let encoded = try CodexFrames.encode(value, framing: framing)
      for split in 0...encoded.count {
        var decoder = CodexFrames(framing: framing)
        let values = try decoder.append(Data(encoded.prefix(split))) + decoder.append(Data(encoded.dropFirst(split)))
        #expect(values == [value]); #expect(decoder.buffer.isEmpty); #expect(decoder.partialSince == nil)
      }
    }
  }

  @Test func multipleFrames() throws {
    var decoder = CodexFrames(framing: .length)
    let a: JSONValue = .object(["n": .number(1)]), b: JSONValue = .object(["n": .number(2)])
    #expect(try decoder.append(CodexFrames.encode(a, framing: .length) + CodexFrames.encode(b, framing: .length)) == [a, b])
  }

  @Test(arguments: [Data([0, 0, 0, 0]), Data([255, 255, 255, 255]), Data([1, 0, 0, 1])])
  func rejectsBadLengths(_ bytes: Data) {
    var decoder = CodexFrames(framing: .length)
    #expect(throws: CodexBridgeError.invalidFrame) { try decoder.append(bytes) }
  }

  @Test(arguments: ["[]\n", "NaN\n", "{\"a\":Infinity}\n", "\n", "{bad}\n"])
  func rejectsMalformedJSON(_ input: String) {
    var decoder = CodexFrames(framing: .lines)
    #expect(throws: CodexBridgeError.invalidFrame) { try decoder.append(Data(input.utf8)) }
  }

  @Test func partialDeadlineDoesNotSlideWithMoreBytes() throws {
    var decoder = CodexFrames(framing: .length)
    _ = try decoder.append(Data([100, 0, 0, 0]))
    let start = ContinuousClock.now.advanced(by: .seconds(-11)); decoder.partialSince = start
    _ = try decoder.append(Data([123]))
    #expect(decoder.partialSince == start)
    #expect(throws: CodexBridgeError.timeout) { try decoder.checkDeadline() }
  }

  @Test func idleHasNoDeadline() throws {
    let decoder = CodexFrames(framing: .length)
    try decoder.checkDeadline()
  }

  @Test func ownerVersionAndConversationAreChecked() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    let change = try #require(snapshot()["params"]?["change"])
    #expect(throws: CodexBridgeError.wrongOwner) { try state.accept(envelope(change, owner: "intruder")) }
    #expect(throws: CodexBridgeError.incompatibleVersion) { try state.accept(envelope(change, version: 12)) }
    #expect(throws: CodexBridgeError.invalidResponse) { try state.accept(envelope(change, thread: UUID().uuidString)) }
    #expect(state.value == nil)
  }

  @Test func snapshotAndPatchesAreAtomic() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    #expect(try state.accept(snapshot())?.title == "Математика")
    let before = state.value
    #expect(throws: CodexBridgeError.invalidResponse) {
      try state.accept(patch([op("replace", [.string("title")], .string("не публиковать")),
        op("replace", [.string("missing"), .string("child")], .null)]))
    }
    #expect(state.value == before); #expect(state.revision == 1)
    #expect(try state.accept(patch([op("replace", [.string("title")], .string("Алгебра"))]))?.title == "Алгебра")
  }

  @Test func revisionGapAndDuplicatePatchReject() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    _ = try state.accept(snapshot())
    #expect(throws: CodexBridgeError.revisionGap) { try state.accept(patch([], base: 2, revision: 3)) }
    #expect(throws: CodexBridgeError.revisionGap) { try state.accept(patch([], base: 1, revision: 1)) }
    #expect(state.revision == 1)
  }

  @Test func oldSnapshotDoesNotRollBack() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    _ = try state.accept(snapshot(revision: 8))
    #expect(try state.accept(snapshot(revision: 7)) == nil)
    #expect(state.revision == 8)
  }

  @Test func optimisticInputIsNotAcceptance() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    let turn: JSONValue = .object(["turnId": .null, "status": .string("inProgress"),
      "params": .object(["clientUserMessageId": .string("client")]), "items": .array([])])
    let received = try state.accept(snapshot(turns: [turn]))
    let projection = try #require(received)
    #expect(projection.busy); #expect(projection.acceptedMessages.isEmpty); #expect(projection.activeTurnID == nil)
  }

  @Test func nativeUserItemProvesAcceptedID() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    let item: JSONValue = .object(["type": .string("userMessage"), "id": .string("item"), "clientId": .string("client"),
      "content": .array([.textInput("x²")])])
    let turn: JSONValue = .object(["turnId": .string("turn"), "status": .string("completed"), "items": .array([item])])
    let received = try state.accept(snapshot(turns: [turn]))
    let projection = try #require(received)
    #expect(projection.acceptedMessages == ["client": "turn"])
    #expect(projection.messages.first?.text == "x²")
  }

  @Test func itemAppendReplaceAndRemove() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    _ = try state.accept(snapshot(turns: [.object(["turnId": .string("turn"), "status": .string("completed"), "items": .array([])])]))
    let path: [JSONValue] = [.string("turns"), .number(0), .string("items"), .number(0)]
    let item: JSONValue = .object(["type": .string("agentMessage"), "id": .string("a"), "text": .string("x")])
    #expect(try state.accept(patch([op("add", path, item)]))?.messages.first?.text == "x")
    #expect(try state.accept(patch([op("replace", path + [.string("text")], .string("x²"))], base: 2, revision: 3))?.messages.first?.text == "x²")
    #expect(try state.accept(patch([op("remove", path)], base: 3, revision: 4))?.messages.isEmpty == true)
  }

  @Test func oneRevisionCannotNameDifferentSnapshots() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    _ = try state.accept(snapshot())
    #expect(throws: CodexBridgeError.invalidResponse) {
      try state.accept(snapshot(turns: [.object(["turnId": .string("other"), "items": .array([])])]))
    }
  }

  @Test func clientIDCannotIdentifyTwoAcceptedTurns() throws {
    var state = CodexStreamState(threadID: thread, owner: owner)
    let item: JSONValue = .object(["type": .string("userMessage"), "id": .string("item"), "clientId": .string("client"),
      "content": .array([.textInput("x²")])])
    let turns: [JSONValue] = ["first", "second"].map { .object([
      "turnId": .string($0), "status": .string("completed"), "items": .array([item])]) }
    #expect(throws: CodexBridgeError.invalidResponse) { try state.accept(snapshot(turns: turns)) }
    #expect(state.value == nil)
  }

  @Test func unknownRequestIsPreservedButCannotBeApproved() throws {
    let request = CodexUserRequest(nativeID: .number(1), method: "future/request", turnID: "turn", parameters: .object([:]))
    #expect(throws: CodexBridgeError.unsupportedRequest) { try CodexDesktopBridge.response(request: request, decision: .allowOnce) }
  }

  @Test func permissionDecisionIsExplicitAndTurnScoped() throws {
    let permissions: JSONValue = .object(["fileSystem": .object(["write": .array([.string("/tmp/test")])])])
    let request = CodexUserRequest(nativeID: .number(276), method: "item/permissions/requestApproval", turnID: "turn",
      parameters: .object(["permissions": permissions]))
    let allow = try CodexDesktopBridge.response(request: request, decision: .allowOnce)
    let deny = try CodexDesktopBridge.response(request: request, decision: .decline)
    #expect(allow.2["permissions"] == permissions); #expect(allow.2["scope"] == .string("turn"))
    #expect(deny.2["permissions"] == .object([:])); #expect(deny.2["scope"] == .string("turn"))
  }

  @Test func userInputCannotAnswerAnotherQuestion() throws {
    let request = CodexUserRequest(nativeID: .string("ask"), method: "item/tool/requestUserInput", turnID: "turn",
      parameters: .object(["questions": .array([.object(["id": .string("method")])])]))
    #expect(throws: CodexBridgeError.invalidInput) {
      try CodexDesktopBridge.response(request: request, decision: .answers(["intruder": ["yes"]]))
    }
    let response = try CodexDesktopBridge.response(request: request, decision: .answers(["method": ["Геометрия"]]))
    #expect(response.2["answers"]?["method"]?["answers"] == .array([.string("Геометрия")]))
  }
}
