import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookChatControllerTests: XCTestCase {
  func testOneTranscriptMergesLiveAndPagedHistoryAndRefreshesLoadedCataloguesQuietly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-sync-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    var chat: NotebookChatController!, historyReads: [String?] = [], generation = 0, catalogueReads = 0
    var held: NotebookChatEnvelope?
    func message(_ i: Int, text: String? = nil) -> CodexMessage { .init(id: "m\(i)", turnID: "turn", clientID: nil, role: .assistant, text: text ?? "Message \(i)") }
    let tasks = (0..<12).map { CodexTask(id: UUID().uuidString, title: "Task \($0)", cwd: "/fixture") }
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .projects: reply = .projects(.init(projects: [.init(id: "p", name: "Version \(generation)", roots: ["/fixture"])], nextCursor: nil))
      case .catalogue(let cursor, _):
        catalogueReads += 1
        let current = generation == 0 ? tasks : Array(tasks.dropFirst())
        reply = .catalogue(.init(tasks: cursor == nil ? Array(current.prefix(8)) : Array(current.dropFirst(8)), nextCursor: cursor == nil ? "next" : nil))
      case .activity(let ids):
        XCTAssertLessThanOrEqual(ids.count, 8); reply = .activity(ids.map { .init(id: $0, status: .idle) })
      case .history(_, let cursor):
        historyReads.append(cursor)
        if generation == 2 {
          reply = .history(.init(messages: (cursor == nil ? 19...22 : 6...19).map { message($0) }, nextCursor: cursor == nil ? "bridge" : "older-still")); break
        }
        if cursor != nil { held = envelope; return }
        reply = .history(.init(messages: [message(4), message(5)], nextCursor: "older"))
      case .conversation:
        if generation == 2 {
          reply = .conversation(.init(threadID: thread, revision: 2, title: "Task", ready: true, busy: false, activeTurnID: nil,
            messages: (20...22).map { message($0) }, requests: [], acceptedMessages: [:], turnStatuses: [:])); break
        }
        reply = .conversation(.init(threadID: thread, revision: 1, title: "Task", ready: true, busy: true, activeTurnID: "turn",
          messages: [message(3), message(4), message(5, text: "Live text"), message(6)], requests: [], acceptedMessages: [:], turnStatuses: [:]))
      default: return XCTFail("Silent synchronization cannot submit work")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    func wait(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertTrue(condition())
    }
    await chat.start(); await chat.connect(peer); chat.expanded = true
    try await wait { chat.tasks.count == 8 && !chat.loadingCatalogue }
    chat.catalogue(next: true)
    try await wait { chat.tasks.count == 12 && !chat.loadingCatalogue }
    generation = 1
    chat.synchronizeVisibleIfDue(now: .now + .seconds(20))
    try await wait { chat.tasks.count == 11 && chat.projects.first?.name == "Version 1" }
    XCTAssertFalse(chat.tasks.contains(tasks[0])); XCTAssertTrue(chat.tasks.contains(tasks[11]), "Refreshing the head must keep the loaded tail")
    chat.select(.init(id: thread, title: "Task", cwd: "/fixture"))
    try await wait { chat.messages.map(\.id) == ["m3", "m4", "m5", "m6"] }
    chat.loadEarlier(); chat.loadEarlier()
    try await wait { held != nil }
    XCTAssertEqual(historyReads.count, 2, "One scroll demand owns the continuation")
    let old = try XCTUnwrap(held)
    chat.receive(.init(id: old.id, body: .reply(.history(.init(messages: [message(1), message(2), message(3), message(4)], nextCursor: nil)))), peerID: peer)
    try await wait { chat.messages.count == 6 && !chat.loadingHistory }
    XCTAssertEqual(chat.messages.map(\.id), (1...6).map { "m\($0)" })
    XCTAssertEqual(chat.messages.first(where: { $0.id == "m5" })?.text, "Live text")
    XCTAssertFalse(chat.canLoadEarlier); XCTAssertTrue(chat.jobs.isEmpty)
    chat.disconnect(peer); generation = 2; await chat.connect(peer)
    try await wait { chat.messages.count == 22 && chat.conversation?.revision == 2 }
    XCTAssertEqual(chat.messages.map(\.id), (1...22).map { "m\($0)" }, "A reconnect fills the missing interval rather than splicing two distant windows together")
    chat.selectProject(chat.projects.first); chat.browsesChats = false
    generation = 3; chat.synchronizeVisibleIfDue(now: .now + .seconds(20))
    try await wait { chat.selectedProject?.name == "Version 3" }
    XCTAssertFalse(chat.browsesChats, "A remote project rename cannot navigate away from the conversation")
    XCTAssertEqual(chat.threadID, thread)
    chat.expanded = false
    let readCount = catalogueReads
    chat.synchronizeVisibleIfDue(now: .now + .seconds(60))
    try await Task.sleep(for: .milliseconds(40)); XCTAssertEqual(catalogueReads, readCount)
    await chat.stop(); let saved = await queue.flush(); XCTAssertTrue(saved)
  }

  func testLaterAccessChoiceDoesNotWaitOnAnOlderUnknownGrant() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-access-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let old = NotebookChatInput(author: author, action: .setAccess(threadID: thread, mode: .full))
    _ = try store.saveChatSubmission(old, to: peer)
    _ = try store.advanceChatJob(old.id, from: .saved, to: .attempting)
    _ = try store.advanceChatJob(old.id, from: .attempting, to: .uncertain)
    let later = NotebookChatInput(author: author, action: .setAccess(threadID: thread, mode: .workspace))
    _ = try store.saveChatSubmission(later, to: peer)
    _ = try store.advanceChatJob(later.id, from: .saved, to: .attempting)
    _ = try store.advanceChatJob(later.id, from: .attempting, to: .accepted, result: .acknowledged)
    try store.saveChatPanel(.init(threadID: thread, draft: "", sidecarID: peer), author: author)
    let queue = NotebookPersistenceQueue(store: store)
    let chat = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("No access change is repeated on restore") }
    await chat.start()
    XCTAssertEqual(chat.jobs.count, 2)
    XCTAssertFalse(chat.accessChangePending, "The last explicit choice is confirmed; an older unknown result stays recorded without an endless spinner")
    XCTAssertEqual(chat.jobs.first(where: { $0.id == old.id })?.state, .uncertain)
    await chat.stop(); let saved = await queue.flush(); XCTAssertTrue(saved)
  }

  func testUncertainCreationKeepsItsIDWithoutPoisoningTheCurrentConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-creation-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let input = NotebookChatInput(author: author, action: .create(title: "New", project: nil))
    _ = try store.saveChatSubmission(input, to: peer)
    _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
    let receipt = try store.advanceChatJob(input.id, from: .attempting, to: .uncertain, error: "Codex: timeout")
    let queue = NotebookPersistenceQueue(store: store)
    var chat: NotebookChatController!, offers = 0
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .job(let offered): XCTAssertEqual(offered.id, input.id); offers += 1; reply = .job(receipt)
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
      case .history: reply = .history(.init(messages: [], nextCursor: nil))
      case .conversation: reply = .conversation(.init(threadID: thread, revision: 1, title: "Existing", ready: true, busy: false,
        activeTurnID: nil, messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:]))
      default: reply = .failure("No new creation is allowed")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    await chat.start(); await chat.connect(peer); chat.select(.init(id: thread, title: "Existing", cwd: "/tmp")); chat.expanded = true
    let deadline = ContinuousClock.now + .seconds(5)
    while (offers < 2 || chat.conversation == nil), .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertGreaterThanOrEqual(offers, 2); XCTAssertNotNil(chat.conversation)
    XCTAssertNil(chat.error, "An old creation timeout cannot become a current connection failure")
    XCTAssertEqual(chat.pendingCreations.map(\.id), [input.id], "The unresolved request remains visible in the chat list")
    XCTAssertEqual(chat.threadID, thread); XCTAssertEqual(chat.jobs.count, 1)
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }

  func testEventsBelongToCurrentPeerSubscriptionAndCannotOverwriteNewerText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-chat-events-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    var controller: NotebookChatController!
    var subscription: UUID?
    let subscribed = expectation(description: "Native conversation subscription")
    func snapshot(_ revision: Int) -> CodexConversation {
      .init(threadID: thread, revision: revision, title: "Task", ready: true, busy: false, activeTurnID: nil,
        messages: [.init(id: "native", turnID: "turn", clientID: nil, role: .assistant, text: "revision \(revision)")],
        requests: [], acceptedMessages: [:], turnStatuses: [:])
    }
    controller = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return XCTFail("Expected request") }
      let reply: NotebookChatReply
      switch query {
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil, defaultProviderNeedsSignIn: false))
      case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
      case .history: reply = .history(.init(messages: [], nextCursor: nil))
      case .activity: reply = .activity([])
      case .conversation:
        subscription = envelope.id
        controller.receive(.init(body: .event(subscriptionID: envelope.id, conversation: snapshot(3))), peerID: peer)
        reply = .conversation(snapshot(2)); subscribed.fulfill()
      default: return XCTFail("No work was submitted")
      }
      controller.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    await controller.start(); controller.select(.init(id: thread, title: "Task", cwd: "/tmp"))
    controller.expanded = true; controller.draft = "retained"; await controller.connect(peer)
    await fulfillment(of: [subscribed], timeout: 6)
    try await Task.sleep(for: .milliseconds(50))
    let id = try XCTUnwrap(subscription)
    XCTAssertEqual(controller.conversation?.revision, 3, "Older query reply cannot replace a newer event")
    controller.receive(.init(body: .event(subscriptionID: id, conversation: snapshot(4))), peerID: UUID())
    controller.receive(.init(body: .event(subscriptionID: UUID(), conversation: snapshot(4))), peerID: peer)
    XCTAssertEqual(controller.conversation?.revision, 3)
    controller.disconnect(peer); await controller.connect(peer)
    controller.receive(.init(body: .event(subscriptionID: id, conversation: snapshot(5))), peerID: peer)
    XCTAssertEqual(controller.conversation?.revision, 3); XCTAssertEqual(controller.draft, "retained")
    await controller.stop(); let saved = await queue.flush(); XCTAssertTrue(saved)
  }

  func testOfflineQueueAdmitsInOrderWhileEarlierReceiptsDisappearAndNeverChangesIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-chat-delivery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    var controller: NotebookChatController!
    var offers: [UUID] = [], envelopeIDs: [UUID: UUID] = [:]
    let admitted = expectation(description: "All saved messages reached the same Mac in order")
    controller = .init(persistence: queue, author: author) { envelope, destination in
      XCTAssertEqual(destination, peer)
      guard case .request(let query) = envelope.body else { return XCTFail("Expected a query") }
      let reply: NotebookChatReply
      switch query {
      case .job(let input):
        if let previous = envelopeIDs[input.id] {
          XCTAssertEqual(previous, envelope.id, "An unacknowledged transport retry retains its request ID")
        } else {
          envelopeIDs[input.id] = envelope.id
          offers.append(input.id)
          if offers.count == 1 { return } // Lost reply: do not invent a second message.
        }
        let job = NotebookChatJob(input: input, state: .accepted, result: .turn(UUID().uuidString), revision: 2)
        reply = .job(job)
        if offers.count == 3 { admitted.fulfill() }
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil, defaultProviderNeedsSignIn: true))
      case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
      case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: .idle) })
      case .history: reply = .history(.init(messages: [], nextCursor: nil))
      default: return XCTFail("Collapsed panel must not poll a conversation")
      }
      controller.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    let inputs = [300, 100, 200].map { time in
      NotebookChatInput(author: author, action: .send(threadID: thread, text: "Часы \(time)", context: ""),
        createdAt: Date(timeIntervalSince1970: Double(time)))
    }
    for input in inputs { _ = try store.saveChatSubmission(input) }
    let expected = inputs.map(\.id)
    await controller.start()
    controller.select(.init(id: thread, title: "Урок", cwd: "/tmp"))
    XCTAssertEqual(controller.pendingMessages.map(\.id), expected, "Clearing the editor cannot hide saved outgoing text")
    controller.select(.init(id: UUID().uuidString, title: "Другая задача", cwd: "/tmp"))
    XCTAssertTrue(controller.pendingMessages.isEmpty, "Another task never displays this outbox")
    controller.select(.init(id: thread, title: "Урок", cwd: "/tmp"))
    await controller.connect(peer)
    await fulfillment(of: [admitted], timeout: 10)
    await controller.stop()
    XCTAssertEqual(offers, expected)
    XCTAssertEqual(Set(offers).count, 3)
    XCTAssertTrue(controller.defaultProviderNeedsSignIn, "Default-provider notice must not block a saved existing task's own provider")
    let flushed = await queue.flush(); XCTAssertTrue(flushed)
    XCTAssertTrue(controller.pendingMessages.isEmpty, "Native acceptance removes the local outgoing projection")
  }

  func testPermissionAndStopKeepTheirNativeAddressAcrossTapsTaskChangesAndRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-chat-controls-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let request = CodexUserRequest(nativeID: .number(7), method: "item/commandExecution/requestApproval",
      turnID: UUID().uuidString, parameters: .object(["command": .string("read this file")]))
    let first = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("An offline approval cannot send itself") }
    await first.start(); first.select(.init(id: thread, title: "Урок", cwd: "/tmp"))
    await first.respond(request, decision: .allowOnce, threadID: thread)
    let job = try XCTUnwrap(first.decisionJob(request, threadID: thread))
    first.expanded = false; first.expanded = true
    await first.respond(request, decision: .allowOnce, threadID: thread)
    XCTAssertEqual(first.jobs, [job])
    await first.stop()
    let second = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("An offline approval cannot send itself") }
    await second.start()
    XCTAssertEqual(second.threadID, thread)
    second.select(.init(id: UUID().uuidString, title: "Другая задача", cwd: "/tmp"))
    await second.respond(request, decision: .allowOnce, threadID: thread)
    XCTAssertEqual(second.jobs, [job])
    await second.respond(request, decision: .decline, threadID: thread)
    XCTAssertNotNil(second.error)
    XCTAssertEqual(second.jobs, [job], "A second button cannot rewrite the accepted human decision")
    await second.stopTurn(threadID: thread, turnID: request.turnID)
    await second.stopTurn(threadID: thread, turnID: request.turnID)
    XCTAssertEqual(second.jobs.count, 2)
    XCTAssertTrue(second.jobs.allSatisfy { $0.input.action.threadID == thread }, "A delayed tap addresses the shown task, not the later selection")
    await second.stop()
    let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }
  func testProjectsAndActivitySelectTheNativeThreadWithoutStartingWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-projects-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let project = CodexProject(id: UUID().uuidString, name: "Notebook", roots: ["/fixture/Notebook"])
    let task = CodexTask(id: UUID().uuidString, title: "Продолжить настоящую работу", cwd: "/fixture/Notebook", projectID: project.id, source: "cli")
    let turn = UUID().uuidString
    weak var receiver: NotebookChatController?
    var submitted: [NotebookChatInput] = [], filtered = false
    let chat = NotebookChatController(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return XCTFail("Expected a query") }
      let reply: NotebookChatReply
      switch query {
      case .file, .run, .resizeRun, .voice: return XCTFail("File and terminal panels are closed")
      case .projects: reply = .projects(.init(projects: [project], nextCursor: nil))
      case .catalogue(_, let selected):
        if selected == project { filtered = true }
        reply = .catalogue(.init(tasks: [task], nextCursor: nil))
      case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: .running, summary: "Выполняется swift test") })
      case .history(let id, _):
        XCTAssertEqual(id, task.id); reply = .history(.init(messages: [], nextCursor: nil))
      case .conversation(let id):
        XCTAssertEqual(id, task.id)
        reply = .conversation(.init(threadID: id, revision: 1, title: task.title, ready: true, busy: false, activeTurnID: nil,
          messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:]))
      case .job(let input):
        submitted.append(input)
        reply = .job(.init(input: input, state: .accepted, result: .turn(turn), revision: 2))
      }
      receiver?.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    receiver = chat
    func wait(_ test: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while !test(), .now < deadline { try await Task.sleep(for: .milliseconds(30)) }
      XCTAssertTrue(test())
    }
    await chat.start(); chat.expanded = true; await chat.connect(peer)
    try await wait { chat.projects == [project] && chat.activities[task.id]?.status == .running }
    chat.selectProject(project)
    try await wait { filtered && chat.tasks == [task] }
    XCTAssertTrue(submitted.isEmpty); XCTAssertTrue(chat.jobs.isEmpty)
    chat.select(task)
    try await wait { chat.conversation?.threadID == task.id }
    XCTAssertTrue(submitted.isEmpty, "Opening the real transcript cannot create a task or start a turn")
    chat.draft = "Продолжай эту работу"
    let saved = await chat.sendMessage(threadID: task.id, text: chat.draft, context: "")
    XCTAssertTrue(saved)
    try await wait { !submitted.isEmpty }
    XCTAssertEqual(submitted.count, 1); XCTAssertEqual(submitted.first?.action.threadID, task.id)
    chat.browsesChats = true
    let hidden = await chat.sendMessage(threadID: task.id, text: "Not to a hidden chat", context: "")
    XCTAssertFalse(hidden)
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }

}
