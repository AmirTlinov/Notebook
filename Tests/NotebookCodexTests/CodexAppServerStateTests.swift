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
}
