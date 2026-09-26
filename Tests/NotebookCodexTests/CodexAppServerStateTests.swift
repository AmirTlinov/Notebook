import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Native events and paged hydration")
struct CodexAppServerStateTests {
  func event(_ method: String, _ fields: [String: JSONValue], request: JSONValue? = nil) -> JSONValue {
    var frame: [String: JSONValue] = ["method": .string(method), "params": .object(fields.merging(["threadId": .string("thread")]) { _, v in v })]
    frame["id"] = request; return .object(frame)
  }
  @Test func nativeItemsStreamWithoutDuplicateRowsOrHiddenReasoning() throws {
    var state = CodexAppServerState(threadID: "thread")
    try state.accept(event("turn/started", ["turn": .object(["id": .string("turn"), "status": .string("inProgress")])]))
    let item: JSONValue = .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string(""), "phase": .string("final_answer")])
    try state.accept(event("item/started", ["turnId": .string("turn"), "item": item]))
    try state.accept(event("item/agentMessage/delta", ["turnId": .string("turn"), "itemId": .string("answer"), "delta": .string("Ответ")]))
    #expect(state.view.messages.first?.phase == "final_answer"); #expect(state.view.messages.first?.text == "Ответ"); #expect(state.view.busy)
    try state.accept(event("item/completed", ["turnId": .string("turn"), "item": .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("Ответ готов")])]))
    try state.accept(event("item/completed", ["turnId": .string("turn"), "item": .object(["id": .string("hidden"), "type": .string("reasoning"), "text": .string("private")])]))
    try state.accept(event("turn/completed", ["turn": .object(["id": .string("turn"), "status": .string("completed")])]))
    #expect(state.view.messages.count == 1); #expect(state.view.messages[0].id == "answer")
    #expect(!state.view.busy); #expect(state.view.turnStatuses["turn"] == "completed")
  }
  @Test func lateHistoryCannotOverwriteNewEvents() throws {
    var state = CodexAppServerState(threadID: "thread")
    try state.accept(event("item/completed", ["turnId": .string("turn"), "item": .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("new")])]))
    try state.hydrate(thread: .object(["id": .string("thread"), "name": .string("Task")]),
      history: [.init(id: "answer", turnID: "turn", clientID: nil, role: .assistant, text: "old")], turns: [])
    #expect(state.view.messages[0].text == "new"); #expect(state.view.ready)
  }
  @Test func reconnectKeepsHistoricalStopDespiteNewerRuntimeEvents() throws {
    var state = CodexAppServerState(threadID: "thread")
    try state.accept(event("thread/status/changed", ["status": .object(["type": .string("idle")])]))
    try state.accept(event("turn/completed", ["turn": .object(["id": .string("newest"), "status": .string("completed")])]))
    try state.hydrate(thread: .object(["id": .string("thread"), "status": .object(["type": .string("active")])]),
      history: [.init(id: "old-tool", turnID: "stopped", clientID: nil, role: .assistant,
        text: "Operation admitted", activity: .init(kind: .tool, status: "completed"))],
      turns: [.object(["id": .string("newest"), "status": .string("inProgress")]),
        .object(["id": .string("stopped"), "status": .string("interrupted")])])
    #expect(state.view.turnStatuses == ["newest": "completed", "stopped": "interrupted"])
    #expect(!state.view.busy); #expect(state.view.activeTurnID == nil)
  }
  @Test func historicalTurnMetadataDoesNotTakeOverCurrentWork() throws {
    var state = CodexAppServerState(threadID: "thread")
    try state.hydrate(thread: .object(["id": .string("thread"), "status": .object(["type": .string("active")])]),
      history: [], turns: [.object(["id": .string("newest"), "status": .string("inProgress")]),
        .object(["id": .string("older"), "status": .string("inProgress")]),
        .object(["id": .string("stopped"), "status": .string("interrupted")])])
    #expect(state.view.busy); #expect(state.view.activeTurnID == "newest")
    #expect(state.view.turnStatuses["stopped"] == "interrupted")
  }
  @Test func requestsResolveByNativeIDAndDoNotResolveTheirNeighbor() throws {
    var state = CodexAppServerState(threadID: "thread")
    for id in [JSONValue.number(8), .string("8")] {
      try state.accept(event("item/tool/requestUserInput", ["turnId": .string("turn"), "questions": .array([])], request: id))
    }
    #expect(state.view.requests.count == 2)
    try state.accept(event("serverRequest/resolved", ["requestId": .number(8)]))
    #expect(state.view.requests.map(\.nativeID) == [.string("8")])
  }
  @Test func longTurnKeepsOnlyBoundedPublicItems() throws {
    var state = CodexAppServerState(threadID: "thread")
    for i in 0..<1000 {
      try state.accept(event("item/completed", ["turnId": .string("turn"), "item": .object(["id": .string("item-\(i)"), "type": .string("agentMessage"), "text": .string("text")])]))
    }
    #expect(state.view.messages.count == 64); #expect(state.view.messages.last?.id == "item-999")
  }
  @Test func streamedTextAccountingMatchesTheExactTransferEncoder() throws {
    let controls = String(String.UnicodeScalarView((0..<32).map { UnicodeScalar($0)! }))
    let samples = ["", "plain / path", "quote\" and \\", controls, "🙂é\u{2028}\u{2029}\u{007F}", "e\u{0301}", "👩‍👩‍👧‍👦"]
    for text in samples {
      let empty = CodexMessage(id:"quoted\"/id",turnID:"turn🙂",clientID:"client",role:.assistant,text:"",
        contentRevision:"not encoded",activity:.init(kind:.tool,status:"inProgress",detail:"\n/"),attachments:["a\\b"],phase:"final_answer")
      let filled = CodexMessage(id:empty.id,turnID:empty.turnID,clientID:empty.clientID,role:empty.role,text:text,
        contentRevision:empty.contentRevision,activity:empty.activity,attachments:empty.attachments,phase:empty.phase)
      let actual = try CodexMessageTransfer.encode(filled).count - CodexMessageTransfer.encode(empty).count
      #expect(CodexAppServerState.encodedTextBytes(text,within:actual) == actual)
      if actual > 0 { #expect(CodexAppServerState.encodedTextBytes(text,within:actual-1) == nil) }
    }
    let combined = samples.joined()
    let chunks = try samples.map { try #require(CodexAppServerState.encodedTextBytes($0,within:CodexMessageTransfer.maximumBytes)) }
    #expect(CodexAppServerState.encodedTextBytes(combined,within:CodexMessageTransfer.maximumBytes) == chunks.reduce(0,+))
  }

  @Test func cumulativeNativeDeltasBecomeExplicitlyUnavailableWithoutStoppingOtherItems() throws {
    var state = CodexAppServerState(threadID:"thread")
    try state.accept(event("turn/started",["turn":.object(["id":.string("turn"),"status":.string("inProgress")])]))
    let prefix = String(repeating:"x",count:5*1_048_576)
    let initial = event("item/started",["turnId":.string("turn"),"item":.object(["id":.string("large"),"type":.string("agentMessage"),"text":.string(prefix)])])
    let delta = event("item/agentMessage/delta",["turnId":.string("turn"),"itemId":.string("large"),"delta":.string(String(repeating:"y",count:4*1_048_576))])
    #expect(try JSONEncoder().encode(initial).count < CodexMessageTransfer.maximumBytes)
    #expect(try JSONEncoder().encode(delta).count < CodexMessageTransfer.maximumBytes,"Each RPC frame is legal; their cumulative body is not")
    try state.accept(initial); #expect(state.view.messages.first?.text == prefix)
    #expect(try state.accept(delta))
    let unavailable = try #require(state.view.messages.first), revision = state.view.revision
    #expect(unavailable.isTruncated); #expect(unavailable.activity?.kind == .error)
    #expect(unavailable.text.utf8.count < 256); #expect(unavailable.activity?.detail?.contains("8 МиБ") == true)
    #expect(throws: CollaborationError.self) { try CodexMessageTransfer(threadID:"thread",message:unavailable) }
    for _ in 0..<100 {
      #expect(try !state.accept(event("item/agentMessage/delta",["turnId":.string("turn"),"itemId":.string("large"),"delta":.string("ignored")])))
    }
    #expect(state.view.revision == revision); #expect(state.view.messages.first == unavailable); #expect(state.view.busy)
    try state.accept(event("item/started",["turnId":.string("turn"),"item":.object(["id":.string("next"),"type":.string("agentMessage"),"text":.string("next")])]))
    try state.accept(event("item/agentMessage/delta",["turnId":.string("turn"),"itemId":.string("next"),"delta":.string(" works")]))
    #expect(state.view.messages.last?.text == "next works"); #expect(state.view.messages.first == unavailable)
    try state.accept(event("item/completed",["turnId":.string("turn"),"item":.object(["id":.string("large"),"type":.string("agentMessage"),"text":.string("Authoritative final")])]))
    let restored = try #require(state.view.messages.first)
    #expect(!restored.isTruncated); #expect(restored.text == "Authoritative final")
    #expect(restored.contentRevision != unavailable.contentRevision)
    _ = try CodexMessageTransfer(threadID:"thread",message:restored)
    try state.accept(event("turn/completed",["turn":.object(["id":.string("turn"),"status":.string("completed")])]))
    #expect(!state.view.busy)
  }

  @Test func cumulativeBudgetIncludesEscapingAndAllMetadataAtTheExactByteBoundary() throws {
    var state = CodexAppServerState(threadID:"thread")
    try state.accept(event("item/started",["turnId":.string("turn"),"item":.object(["id":.string("answer"),"type":.string("agentMessage"),"text":.string(""),"phase":.string("commentary")])]))
    let head = try #require(state.view.messages.first)
    let remaining = try CodexMessageTransfer.maximumBytes - CodexMessageTransfer.encode(head).count
    let quoted = String(repeating:"\"",count:remaining/4)
    let tail = String(repeating:"x",count:remaining-2*quoted.utf8.count)
    for text in [quoted,tail] {
      let frame = event("item/agentMessage/delta",["turnId":.string("turn"),"itemId":.string("answer"),"delta":.string(text)])
      #expect(try JSONEncoder().encode(frame).count < CodexMessageTransfer.maximumBytes)
      try state.accept(frame)
    }
    let exact = try #require(state.view.messages.first)
    #expect(!exact.isTruncated); #expect(try CodexMessageTransfer.encode(exact).count == CodexMessageTransfer.maximumBytes)
    _ = try CodexMessageTransfer(threadID:"thread",message:exact)
    try state.accept(event("item/agentMessage/delta",["turnId":.string("turn"),"itemId":.string("answer"),"delta":.string("/")]))
    #expect(state.view.messages.first?.isTruncated == true)
  }

  @Test func hydratedItemsUseTheSameBudgetAndWindowEvictionRemovesOnlyTheirAccounting() throws {
    var state = CodexAppServerState(threadID:"thread")
    try state.hydrate(thread:.object(["id":.string("thread")]),history:[
      .init(id:"large",turnID:"turn",clientID:nil,role:.assistant,text:String(repeating:"x",count:CodexMessageTransfer.maximumBytes)),
      .init(id:"small",turnID:"turn",clientID:nil,role:.assistant,text:"small")],turns:[])
    #expect(state.view.messages.first?.isTruncated == true)
    try state.accept(event("item/agentMessage/delta",["turnId":.string("turn"),"itemId":.string("small"),"delta":.string(" delta")]))
    #expect(state.view.messages.last?.text == "small delta")
    for i in 0..<64 { try state.accept(event("item/completed",["turnId":.string("turn"),"item":.object(["id":.string("item-\(i)"),"type":.string("agentMessage"),"text":.string("ok")])])) }
    #expect(state.view.messages.count == 64); #expect(!state.view.messages.contains { $0.id == "large" || $0.id == "small" })
    try state.accept(event("item/started",["turnId":.string("new-turn"),"item":.object(["id":.string("large"),"type":.string("agentMessage"),"text":.string("new")])]))
    try state.accept(event("item/agentMessage/delta",["turnId":.string("new-turn"),"itemId":.string("large"),"delta":.string(" delta")]))
    #expect(state.view.messages.last?.text == "new delta"); #expect(state.view.messages.last?.isTruncated == false)
  }

  @Test func longStreamingMessagePreservesTailAndStatusKeepsContentIdentity() throws {
    var state = CodexAppServerState(threadID:"thread")
    let prefix = String(repeating:"x",count:20_000)
    try state.accept(event("item/started",["turnId":.string("turn"),"item":.object(["id":.string("answer"),"type":.string("agentMessage"),"text":.string(prefix)])]))
    try state.accept(event("item/agentMessage/delta",["turnId":.string("turn"),"itemId":.string("answer"),"delta":.string(" конец🙂")]))
    let before = try #require(state.view.messages.first)
    #expect(before.text == prefix+" конец🙂"); #expect(!before.isTruncated); #expect(before.contentRevision != nil)
    try state.accept(event("thread/status/changed",["status":.object(["type":.string("idle")])]))
    #expect(state.view.messages.first == before)
  }

}
