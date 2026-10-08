import Foundation
import Testing
import NotebookCore
@testable import NotebookCodex

@Suite("Native events and paged hydration")
struct CodexAppServerStateTests {
  func event(_ method: String, _ fields: [String: JSONValue], request: JSONValue? = nil,
    threadID: String = "thread") -> JSONValue {
    var frame: [String: JSONValue] = ["method": .string(method), "params": .object(fields.merging(["threadId": .string(threadID)]) { _, v in v })]
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

  @Test(arguments: [false, true])
  func quietThreadTerminalAndApprovalSurviveHotThreadWhileConsumerIsPaused(_ approval: Bool) async throws {
    let server = CodexAppServer(installation: .init(binary: URL(fileURLWithPath: "/unused-codex"),
      node: URL(fileURLWithPath: "/unused-node")))
    let a = UUID().uuidString, b = UUID().uuidString
    var hot = CodexAppServerState(threadID: a), quiet = CodexAppServerState(threadID: b)
    try hot.hydrate(thread: .object(["id": .string(a)]), history: [], turns: [])
    try quiet.hydrate(thread: .object(["id": .string(b)]), history: [], turns: [])
    try quiet.accept(event("turn/started", ["turn": .object(["id": .string("quiet-turn"),
      "status": .string("inProgress")])], threadID: b))
    if approval {
      try quiet.accept(event("item/permissions/requestApproval", ["turnId": .string("quiet-turn"),
        "permissions": .object([:])], request: .number(17), threadID: b))
    } else {
      try quiet.accept(event("turn/completed", ["turn": .object(["id": .string("quiet-turn"),
        "status": .string("completed")])], threadID: b))
    }
    var consumer = server.events.makeAsyncIterator()
    await server.publishConversation(quiet)
    try hot.accept(event("item/started", ["turnId": .string("hot-turn"),
      "item": .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("")])], threadID: a))
    // The consumer is paused throughout more than the old global 16-event cap.
    for _ in 0..<64 {
      try hot.accept(event("item/agentMessage/delta", ["turnId": .string("hot-turn"),
        "itemId": .string("answer"), "delta": .string("x")], threadID: a))
      await server.publishConversation(hot)
    }
    let wake: Void? = await consumer.next()
    #expect(wake != nil)
    let pending = await server.drainEvents()
    var byThread: [String: CodexConversation] = [:]
    for case .conversation(let state) in pending { byThread[state.threadID] = state }
    #expect(pending.count == 2)
    let received = try #require(byThread[b])
    #expect(received.generation == quiet.generation); #expect(received.revision == quiet.revision)
    if approval { #expect(received.requests.map(\.nativeID) == [.number(17)]) }
    else { #expect(!received.busy); #expect(received.turnStatuses["quiet-turn"] == "completed") }
    #expect(byThread[a]?.messages.first?.text == String(repeating: "x", count: 64))
    let drained = await server.drainEvents()
    #expect(drained.isEmpty)
    await server.close()
  }

  @Test func publicationBetweenEmptyDrainAndAwaitRetainsTheWakeAndLatestState() async throws {
    let server = CodexAppServer(installation: .init(binary: URL(fileURLWithPath: "/unused-codex"),
      node: URL(fileURLWithPath: "/unused-node")))
    let thread = UUID().uuidString
    var state = CodexAppServerState(threadID: thread)
    try state.hydrate(thread: .object(["id": .string(thread)]), history: [], turns: [])
    try state.accept(event("item/started", ["turnId": .string("turn"),
      "item": .object(["id": .string("answer"), "type": .string("agentMessage"), "text": .string("before")])], threadID: thread))
    var consumer = server.events.makeAsyncIterator()
    await server.publishConversation(state)
    let firstWake: Void? = await consumer.next()
    #expect(firstWake != nil)
    _ = await server.drainEvents()
    let empty = await server.drainEvents()
    #expect(empty.isEmpty)
    // Force exactly the drain/next gap; there is no poll, timer or next event.
    try state.accept(event("item/agentMessage/delta", ["turnId": .string("turn"),
      "itemId": .string("answer"), "delta": .string(" after")], threadID: thread))
    await server.publishConversation(state)
    let nextWake: Void? = await consumer.next()
    #expect(nextWake != nil)
    let pending = await server.drainEvents()
    #expect(pending.count == 1)
    guard case .conversation(let latest) = try #require(pending.first) else {
      Issue.record("The buffered wake did not identify its authoritative conversation"); return
    }
    #expect(latest.revision == state.revision)
    #expect(latest.messages.first?.text == "before after")
    await server.close()
  }

  @Test func detachingKeepsApprovalWhileRemovalAndDisconnectPruneOldGenerations() async throws {
    let server = CodexAppServer(installation: .init(binary: URL(fileURLWithPath: "/unused-codex"),
      node: URL(fileURLWithPath: "/unused-node")))
    let a = UUID().uuidString, b = UUID().uuidString, workspace = UUID(), observation = UUID()
    var idle = CodexAppServerState(threadID: a), approving = CodexAppServerState(threadID: b)
    try idle.hydrate(thread: .object(["id": .string(a)]), history: [], turns: [])
    try approving.hydrate(thread: .object(["id": .string(b)]), history: [], turns: [])
    await server.publishConversation(idle); await server.publishConversation(approving)
    try await server.attach(threadID: b, observationID: observation)
    try approving.accept(event("item/permissions/requestApproval", ["turnId": .string("turn"),
      "permissions": .object([:])], request: .number(23), threadID: b))
    await server.publishConversation(approving)
    await server.detach(threadID: b, observationID: observation)
    try await server.bindWorkspace(workspace, threadID: a)
    try await server.unregisterWorkspace(workspace)
    let detached = await server.drainEvents()
    #expect(detached.count == 1)
    guard case .conversation(let preserved) = try #require(detached.first) else {
      Issue.record("Detaching a view discarded its still-owned native approval"); return
    }
    #expect(preserved.threadID == b); #expect(preserved.requests.count == 1)
    #expect(await server.snapshot(threadID: a) == nil)

    // A queued old state must not cross the actual close/connection boundary.
    await server.publishConversation(approving)
    await server.close()
    var fresh = CodexAppServerState(threadID: b), hot = CodexAppServerState(threadID: a)
    try fresh.hydrate(thread: .object(["id": .string(b)]), history: [], turns: [])
    try hot.hydrate(thread: .object(["id": .string(a)]), history: [], turns: [])
    await server.publishConversation(fresh)
    for _ in 0..<32 {
      try hot.accept(event("thread/status/changed", ["status": .object(["type": .string("idle")])], threadID: a))
      await server.publishConversation(hot)
    }
    let reconnected = await server.drainEvents()
    guard case .unavailable(let error) = try #require(reconnected.first) else {
      Issue.record("Fresh state overtook or evicted the disconnect barrier"); return
    }
    #expect(error == .disconnected)
    var current: [String: CodexConversation] = [:]
    for case .conversation(let value) in reconnected { current[value.threadID] = value }
    #expect(reconnected.count == 3); #expect(current.count == 2)
    #expect(current[b]?.generation == fresh.generation)
    #expect(current[b]?.generation != approving.generation)
    #expect(current[b]?.requests.isEmpty == true)
    await server.publishConversation(fresh)
    await server.invalidateAccountPresentation()
    let invalidated = await server.drainEvents()
    #expect(invalidated.isEmpty)
    #expect(await server.snapshot(threadID: b) == nil)
    await server.close()
  }

}
