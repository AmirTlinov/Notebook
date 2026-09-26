import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookChatControllerTests: XCTestCase {
  func testLongMessageLoadsAutomaticallyRetriesAndKeepsBodyAcrossStatusUpdates() async throws {
    try await longMessageContent(replacingError:false)
    try await longMessageContent(replacingError:true)
  }

  private func longMessageContent(replacingError:Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-content-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = NotebookStore(root:root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor:author,pageSize:.init(width:834,height:1194))
    let queue = NotebookPersistenceQueue(store:store)
    let native = CodexMessage(id:"long",turnID:UUID().uuidString,clientID:nil,role:.assistant,
      text:String(repeating:"Полный ответ 🙂\n",count:20_000)).identifyingContent()
    let header = try XCTUnwrap(CodexMessage.transportPage([native],byteBudget:2048).first)
    let transfer = try CodexMessageTransfer(threadID:thread,message:native)
    var chat: NotebookChatController!, fail = true, reads = 0, subscription: UUID?
    let generation = UUID()
    func conversation(_ revision:Int) -> CodexConversation {
      .init(threadID:thread,generation:generation,revision:revision,title:"Task",ready:true,busy:false,activeTurnID:nil,
        messages:[header],requests:[],acceptedMessages:[:],turnStatuses:[:])
    }
    chat = .init(persistence:queue,author:author) { envelope,_ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .projects: reply = .projects(.init(projects:[],nextCursor:nil))
      case .catalogue: reply = .catalogue(.init(tasks:[],nextCursor:nil))
      case .activity(let ids): reply = .activity(ids.map { .init(id:$0,status:.idle) })
      case .run: reply = .run(.init(record:nil))
      case .history(_, let cursor):
        reply = cursor == nil ? .history(.init(messages:[header],nextCursor:"earlier")) : .failure("Unrelated history failure")
      case .conversation: subscription = envelope.id; reply = .conversation(conversation(1))
      case .message(let read):
        reads += 1
        if fail { reply = .failure("Injected interrupted read") }
        else {
          if replacingError, read.offset == 0 { chat.loadEarlier() }
          do { reply = .message(.part(try transfer.part(offset:read.offset))) }
          catch { return XCTFail("Invalid transfer offset") }
        }
      default: return XCTFail("A content read cannot submit native work")
      }
      chat.receive(.init(id:envelope.id,body:.reply(reply)),peerID:peer)
    }
    func wait(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !condition(), .now < deadline { try await Task.sleep(for:.milliseconds(10)) }
      XCTAssertTrue(condition())
    }
    await chat.start(); await chat.connect(peer); chat.expanded = true
    chat.select(.init(id:thread,title:"Task",cwd:"/fixture"))
    try await wait { reads > 0 && chat.error?.contains("полное сообщение") == true }
    XCTAssertTrue(chat.messages.first?.isTruncated == true)
    fail = false; chat.retryMessageContent(native.id)
    XCTAssertNil(chat.error,"Manual retry clears only its own visible read failure")
    try await wait { chat.messages.first?.text == native.text && chat.messages.first?.isTruncated == false }
    if replacingError {
      try await wait { chat.error == "Unrelated history failure" }
      XCTAssertEqual(chat.error,"Unrelated history failure","Successful content loading cannot erase a later history failure")
      chat.retryMessageContent(native.id)
      XCTAssertEqual(chat.error,"Unrelated history failure","Retry does not own another operation's error")
    } else { XCTAssertNil(chat.error,"Successful loading leaves no stale full-message failure") }
    let before = reads, body = chat.messages
    if let subscription { chat.receive(.init(body:.event(subscriptionID:subscription,conversation:conversation(2))),peerID:peer) }
    await Task.yield()
    XCTAssertEqual(chat.messages,body); XCTAssertEqual(reads,before,"Status-only headers do not download or replace an already assembled body")
    await chat.stop(); _ = await queue.flush()
  }

  func testGrowingMessagePublishesCompletedTransferBeforeTheStreamStops() async throws {
    try await growingMessage(authoritativeError:false)
  }

  func testUnavailableMessageRevokesEarlierTransferEvenWhenStreamingResumes() async throws {
    try await growingMessage(authoritativeError:true)
  }

  private func growingMessage(authoritativeError:Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-growing-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = NotebookStore(root:root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor:author,pageSize:.init(width:834,height:1194))
    let queue = NotebookPersistenceQueue(store:store), turn = UUID().uuidString, generation = UUID()
    let bodies = (1...3).map { revision in CodexMessage(id:"growing",turnID:turn,clientID:nil,role:.assistant,
      text:String(repeating:"Продолжающийся ответ 🙂\n",count:3000)+"Revision \(revision)").identifyingContent() }
    let headers = try bodies.map { try XCTUnwrap(CodexMessage.transportPage([$0],byteBudget:2048).first) }
    let transfers = try bodies.map { try CodexMessageTransfer(threadID:thread,message:$0) }
    var chat: NotebookChatController!, subscription: UUID?, transferIndex = 0, observedIntermediate = false
    var held: (NotebookChatEnvelope,CodexMessagePart)?, replaced = false, staleContinuations = 0
    func conversation(_ index:Int, complete:CodexMessage? = nil) -> CodexConversation {
      .init(threadID:thread,generation:generation,revision:index+1,title:"Task",ready:true,busy:complete == nil,
        activeTurnID:complete == nil ? turn : nil,messages:[complete ?? headers[index]],requests:[],acceptedMessages:[:],turnStatuses:[:])
    }
    chat = .init(persistence:queue,author:author) { envelope,_ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .projects: reply = .projects(.init(projects:[],nextCursor:nil))
      case .catalogue: reply = .catalogue(.init(tasks:[],nextCursor:nil))
      case .activity(let ids): reply = .activity(ids.map { .init(id:$0,status:.running) })
      case .run: reply = .run(.init(record:nil))
      case .history: reply = .history(.init(messages:[],nextCursor:nil))
      case .conversation: subscription = envelope.id; reply = .conversation(conversation(0))
      case .message(let read):
        if read.offset == 0, transferIndex == 1 {
          XCTAssertTrue(chat.messages.first?.text == bodies[transferIndex-1].text,
            "A newer header must not starve the preceding completed immutable body")
          observedIntermediate = true
        }
        do {
          let index = read.transferID.flatMap { id in transfers.firstIndex { $0.id == id } } ?? transferIndex
          if replaced, index == 1 { staleContinuations += 1 }
          let part = try transfers[index].part(offset:read.offset)
          if index == 1, !replaced { held = (envelope,part); return }
          if index == 0, part.offset + part.data.count == part.totalBytes, let subscription {
            transferIndex += 1
            chat.receive(.init(body:.event(subscriptionID:subscription,conversation:conversation(transferIndex))),peerID:peer)
          }
          reply = .message(.part(part))
        } catch { return XCTFail("Invalid exact transfer") }
      default: return XCTFail("Reading a streaming message cannot execute work")
      }
      chat.receive(.init(id:envelope.id,body:.reply(reply)),peerID:peer)
    }
    await chat.start(); await chat.connect(peer); chat.expanded = true
    chat.select(.init(id:thread,title:"Task",cwd:"/fixture"))
    let deadline = ContinuousClock.now + .seconds(5)
    while held == nil, .now < deadline { try await Task.sleep(for:.milliseconds(10)) }
    XCTAssertTrue(observedIntermediate); XCTAssertNotNil(held)
    XCTAssertTrue(chat.presentationMessages.first?.isTruncated == true,
      "The completed body remains visible but cannot pretend the latest revision is loaded")
    let final = CodexMessage(id:"growing",turnID:turn,clientID:nil,role:.assistant,
      text:"Authoritative replacement",isTruncated:authoritativeError,
      contentRevision:authoritativeError ? "unavailable-revision" : nil,
      activity:authoritativeError ? .init(kind:.error,status:"failed",detail:"Native message unavailable") : nil).identifyingContent()
    if let subscription { chat.receive(.init(body:.event(subscriptionID:subscription,conversation:conversation(2,complete:final))),peerID:peer) }
    XCTAssertEqual(chat.messages.first?.text,final.text,"An authoritative unavailable message cannot hide behind an older completed body")
    replaced = true; transferIndex = 2
    if let subscription { chat.receive(.init(body:.event(subscriptionID:subscription,conversation:conversation(2))),peerID:peer) }
    if let (envelope,part) = held { chat.receive(.init(id:envelope.id,body:.reply(.message(.part(part)))),peerID:peer) }
    let completedLimit = ContinuousClock.now + .seconds(5)
    while chat.messages.first?.text != bodies[2].text, .now < completedLimit { try await Task.sleep(for:.milliseconds(10)) }
    XCTAssertTrue(chat.messages.first?.text == bodies[2].text)
    XCTAssertEqual(staleContinuations,0,"Replacement permanently revokes the old transfer, even when another header immediately requeues this ID")
    XCTAssertFalse(chat.presentationMessages.first?.isTruncated ?? true)
    await chat.stop(); _ = await queue.flush()
  }

  func testStopUsesReservedControlSlotWhileFileReplyIsMissing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("control-slot-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    var chat: NotebookChatController!, held: NotebookChatEnvelope?
    let readStarted = expectation(description: "File read remains outstanding")
    let stopDelivered = expectation(description: "Stop admitted without waiting for file read")
    var control: NotebookChatInput?
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .file:
        if held == nil { held = envelope; readStarted.fulfill() }; return
      case .job(let input):
        if control == nil { control = input; stopDelivered.fulfill() }
        XCTAssertNotNil(held)
        reply = .job(.init(input: input, state: .accepted, result: .acknowledged, revision: 2))
      case .run: reply = .run(.init(record: nil))
      case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .activity: reply = .activity([])
      default: return XCTFail("Unexpected query")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    await chat.start(); await chat.connect(peer)
    let reading = Task { try? await chat.directQuery(.file(.directory(.init(computer: peer, project: "fixture", root: "/fixture", path: ""), after: nil))) }
    await fulfillment(of: [readStarted], timeout: 3)
    let thread = UUID().uuidString, turn = UUID().uuidString
    let stopping = Task { await chat.stopTurn(threadID: thread, turnID: turn) }
    await fulfillment(of: [stopDelivered], timeout: 1)
    await stopping.value
    XCTAssertEqual(control?.action, .stop(threadID: thread, turnID: turn))
    if let held { chat.receive(.init(id: held.id, body: .reply(.failure("Read intentionally interrupted"))), peerID: peer) }
    _ = await reading.value; await chat.stop(); _ = await queue.flush()
    XCTAssertEqual(try store.chatJob(XCTUnwrap(control?.id))?.state, .accepted)
  }

  func testNewDraftOpensImmediatelyAndFirstMessageWaitsDurablyForCreation() async throws {
    try await firstMessageCreation(changesSelection: false)
  }

  func testDelayedCreationSendsItsFrozenMessageWithoutStealingAnotherChatOrDraft() async throws {
    try await firstMessageCreation(changesSelection: true)
  }

  func testLocalNewDraftRestoresItsProjectAndTextWithoutCreatingRemoteWork() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("new-chat-draft-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let project = CodexProject(id: "fixture", name: "Fixture", roots: ["/fixture"])
    let chat = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("A draft cannot start remote work") }
    await chat.start(); chat.draft = "Unsent"; XCTAssertTrue(chat.beginDraft(project: project))
    await chat.stop(); _ = await queue.flush()
    // Interrupt after the UI records Send but before its durable admission.
    var panel = try store.chatPanel(author: author)
    panel.creationID = UUID(); try store.saveChatPanel(panel, author: author)
    let restored = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("Restoring a draft cannot start remote work") }
    await restored.start()
    XCTAssertFalse(restored.browsesChats); XCTAssertNil(restored.threadID)
    XCTAssertNil(restored.creationID)
    XCTAssertEqual(restored.draft, "Unsent"); XCTAssertEqual(restored.selectedProject, project)
    XCTAssertTrue(restored.jobs.isEmpty); XCTAssertTrue(restored.canSendDraft)
    await restored.stop(); _ = await queue.flush()
  }

  private func firstMessageCreation(changesSelection: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-creation-selection-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let previous = CodexTask(id: UUID().uuidString, title: "Previous empty task", cwd: "/fixture")
    let created = CodexTask(id: UUID().uuidString, title: "New empty task", cwd: "/fixture")
    var chat: NotebookChatController!, offered: (NotebookChatEnvelope, NotebookChatInput)?
    var offers = 0
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .job(let input):
        if case .create = input.action { offers += 1; offered = (envelope, input); return }
        guard case .send(let thread, let text, let context) = input.action else { return XCTFail("Unexpected command") }
        XCTAssertEqual(thread, created.id); XCTAssertEqual(text, "Привет"); XCTAssertEqual(context, "Frozen attention")
        reply = .job(.init(input: input, state: .accepted, result: .turn(UUID().uuidString), revision: 2))
      case .run: reply = .run(.init(record: nil))
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
      case .history: reply = .history(.init(messages: [], nextCursor: nil))
      case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: .idle) })
      case .conversation(let id): reply = .conversation(.init(threadID: id, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1,
        title: id == created.id ? created.title : previous.title, ready: true, busy: false,
        activeTurnID: nil, messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:]))
      default: return XCTFail("Unexpected creation query: \(query)")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    func wait(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertTrue(condition())
    }
    await chat.start(); await chat.connect(peer); chat.expanded = true; chat.select(previous)
    try await wait { chat.conversation?.threadID == previous.id && chat.catalogues[.chats]?.loaded == true }
    XCTAssertFalse(chat.browsesChats); XCTAssertTrue(chat.tasks.isEmpty)

    chat.draft = "Привет"
    let attachment = CodexInputAttachment(kind: .skill, name: "Skill", path: "/fixture/SKILL.md")
    chat.attach(attachment)
    let project = CodexProject(id: "fixture", name: "Fixture", roots: ["/fixture"])
    // Even a blocked writer cannot delay opening the local draft.
    let writer = DispatchSemaphore(value: 0)
    defer { writer.signal() }
    queue.enqueue(owner: .command(.read)) { _ in _ = writer.wait(timeout: .now() + 8); return false }
    XCTAssertTrue(chat.beginDraft(project: project))
    XCTAssertFalse(chat.browsesChats); XCTAssertNil(chat.threadID)
    XCTAssertEqual(chat.draft, "Привет"); XCTAssertEqual(chat.attachments, [attachment])
    XCTAssertEqual(chat.selectedProject, project); XCTAssertTrue(chat.canSendDraft)
    XCTAssertNil(offered); XCTAssertTrue(chat.jobs.isEmpty)
    let destination = chat.messageDestination
    let saving = Task { await chat.sendMessage(to: destination, text: chat.draft, context: "Frozen attention", attachments: chat.attachments) }
    try await wait { chat.saving }
    XCTAssertFalse(chat.canSendDraft)
    let duplicate = await chat.sendMessage(to: destination, text: "Привет", context: "Frozen attention", attachments: [attachment])
    XCTAssertFalse(duplicate)
    writer.signal(); let saved = await saving.value; XCTAssertTrue(saved)
    try await wait { offered != nil }
    XCTAssertFalse(chat.browsesChats); XCTAssertNil(chat.threadID)
    XCTAssertTrue(chat.draft.isEmpty); XCTAssertTrue(chat.attachments.isEmpty)
    let request = try XCTUnwrap(offered)
    if changesSelection { chat.select(previous); chat.draft = "Newer draft" }
    let expectedThread = changesSelection ? previous.id : created.id
    let receipt = NotebookChatJob(input: request.1, state: .accepted, result: .created(created), revision: 2)
    chat.receive(.init(id: request.0.id, body: .reply(.job(receipt))), peerID: peer)
    try await wait { chat.threadID == expectedThread && chat.jobs.count == 2 && chat.jobs.allSatisfy(\.isTerminal) }
    XCTAssertFalse(chat.browsesChats)
    XCTAssertTrue(chat.tasks.isEmpty, "An empty native history catalogue cannot revoke the actual creation receipt")
    XCTAssertEqual(offers, 1); XCTAssertTrue(chat.messages.isEmpty)
    chat.catalogue()
    try await wait { chat.catalogues[.chats]?.loading == false }
    XCTAssertEqual(chat.threadID, expectedThread); XCTAssertFalse(chat.browsesChats)
    XCTAssertEqual(chat.draft, changesSelection ? "Newer draft" : "")
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
    XCTAssertEqual(try store.chatPanel(author: author, computer: peer).threadID, expectedThread)
    XCTAssertEqual(try store.chatJob(request.1.id)?.result, .created(created))
  }

  func testWorkStatusUsesOnlyCurrentPublicProgressAndStopsForDecisionsOrDisconnect() {
    let messages: [CodexMessage] = [
      .init(id: "old", turnID: "old", clientID: nil, role: .assistant, text: "Old status", phase: "commentary"),
      .init(id: "tool", turnID: "turn", clientID: nil, role: .assistant, text: "Читаю файл", activity: .init(kind: .files, status: "inProgress")),
      .init(id: "progress", turnID: "turn", clientID: nil, role: .assistant, text: "Проверяю\nизменение", phase: "commentary")]
    func value(active: Bool = true, requests: [CodexUserRequest] = []) -> CodexConversation {
      .init(threadID: "task", generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Task", ready: true, busy: active, activeTurnID: active ? "turn" : nil,
        messages: messages, requests: requests, acceptedMessages: [:], turnStatuses: [:])
    }
    let status = NotebookChatWorkStatus(conversation: value(), connected: true)
    XCTAssertEqual(status?.title, "Проверяю изменение"); XCTAssertEqual(status?.turnID, "turn"); XCTAssertEqual(status?.running, true)
    let offline = NotebookChatWorkStatus(conversation: value(), connected: false)
    XCTAssertEqual(offline?.running, false); XCTAssertEqual(offline?.title, "Mac не в сети · состояние задачи неизвестно")
    let request = CodexUserRequest(nativeID: .number(7), method: "item/tool/requestUserInput", turnID: "turn", parameters: .object([:]))
    let question = NotebookChatWorkStatus(conversation: value(requests: [request]), connected: true)
    XCTAssertEqual(question?.title, "Нужно ваше решение"); XCTAssertEqual(question?.running, false)
    XCTAssertNil(NotebookChatWorkStatus(conversation: value(active: false), connected: true))
  }
  func testCompanionKeepsOneSubscriptionDraftAndUnreadReceipts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("compact-chat-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), peer = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    var chat: NotebookChatController!, subscription: UUID?, collapsed = false
    func snapshot(_ revision: Int, working: Bool = true) -> CodexConversation {
      let replies = (1...revision).map { CodexMessage(id: "reply-\($0)", turnID: "turn-\($0)", clientID: nil, role: .assistant, text: "Useful answer \($0)", phase: "final_answer") }
      let progress = CodexMessage(id: "progress", turnID: "working", clientID: nil, role: .assistant, text: "Internal progress", phase: "commentary")
      return .init(threadID: thread, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: revision, title: "One task", ready: true, busy: working, activeTurnID: working ? "working" : nil,
        messages: replies + [progress], requests: [], acceptedMessages: [:], turnStatuses: [:])
    }
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .run: reply = .run(.init(record: nil))
      case .conversation: subscription = envelope.id; reply = .conversation(snapshot(1))
      case .history: reply = .history(.init(messages: [], nextCursor: nil))
      case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .activity(let ids):
        XCTAssertFalse(collapsed && ids.isEmpty, "An empty activity query removes the native subscription and cannot represent collapse")
        reply = .activity(ids.map { .init(id: $0, status: .idle) })
      default: return XCTFail("Presentation cannot create a job or approve access")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    await chat.start(); chat.select(.init(id: thread, title: "One task", cwd: "/fixture")); chat.expanded = true
    chat.draft = "Retained draft"; await chat.connect(peer)
    let deadline = ContinuousClock.now + .seconds(4)
    while subscription == nil, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let id = try XCTUnwrap(subscription)
    try await Task.sleep(for: .milliseconds(30))
    collapsed = true; chat.expanded = false
    chat.receive(.init(body: .event(subscriptionID: id, conversation: snapshot(2))), peerID: peer)
    XCTAssertFalse(chat.expanded); XCTAssertEqual(chat.unreadReplies.map(\.id), ["reply-2"])
    chat.refreshCompanionReplies()
    chat.receive(.init(body: .event(subscriptionID: id, conversation: snapshot(3))), peerID: peer)
    XCTAssertEqual(chat.unreadReplies.map(\.id), ["reply-2", "reply-3"])
    XCTAssertEqual(chat.messages.count, 4); XCTAssertEqual(chat.draft, "Retained draft"); XCTAssertTrue(chat.jobs.isEmpty)
    XCTAssertTrue(chat.companionReplies.isEmpty, "Current work retains its status rather than presenting an older reply")
    chat.receive(.init(body: .event(subscriptionID: id, conversation: snapshot(3, working: false))), peerID: peer)
    XCTAssertEqual(chat.companionReplies.last?.id, "reply-3")
    chat.dismissCompanionReply("reply-2")
    XCTAssertEqual(chat.companionReplies.last?.id, "reply-3", "A stale close action cannot dismiss a newer answer")
    chat.dismissCompanionReply("reply-3")
    chat.refreshCompanionReplies()
    chat.receive(.init(body: .event(subscriptionID: id, conversation: snapshot(3, working: false))), peerID: peer)
    XCTAssertTrue(chat.companionReplies.isEmpty); XCTAssertEqual(chat.unreadReplies.map(\.id), ["reply-2", "reply-3"])
    chat.receive(.init(body: .event(subscriptionID: id, conversation: snapshot(4, working: false))), peerID: peer)
    XCTAssertEqual(chat.companionReplies.last?.id, "reply-4"); XCTAssertEqual(chat.jobs.count, 0)
    let ends = try XCTUnwrap(chat.readPosition?.previewEndsAt["reply-4"])
    chat.refreshCompanionReplies(at: ends.addingTimeInterval(1))
    XCTAssertTrue(chat.companionReplies.isEmpty); XCTAssertEqual(chat.unreadReplies.count, 3)
    chat.revealReply("reply-2")
    XCTAssertTrue(chat.expanded); XCTAssertEqual(chat.revealedMessageID, "reply-2"); XCTAssertTrue(chat.unreadReplies.isEmpty)
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
    let restored = try store.chatPanel(author: author, computer: peer)
    XCTAssertEqual(restored.draft, "Retained draft"); XCTAssertEqual(restored.readPosition?.readThrough, "reply-4")
  }

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
      case .run: reply = .run(.init(record: nil))
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
          reply = .conversation(.init(threadID: thread, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 2, title: "Task", ready: true, busy: false, activeTurnID: nil,
            messages: (20...22).map { message($0) }, requests: [], acceptedMessages: [:], turnStatuses: [:])); break
        }
        reply = .conversation(.init(threadID: thread, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Task", ready: true, busy: true, activeTurnID: "turn",
          messages: [message(3), message(4), message(5, text: "Live text"), message(6)], requests: [], acceptedMessages: [:], turnStatuses: [:]))
      default: return XCTFail("Silent synchronization cannot submit work: \(query)")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    func wait(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertTrue(condition())
    }
    await chat.start(); await chat.connect(peer); chat.expanded = true
    try await wait { chat.tasks.count == 8 && chat.catalogues[.chats]?.loading == false }
    chat.catalogue(next: true)
    try await wait { chat.tasks.count == 12 && chat.catalogues[.chats]?.loading == false }
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
      case .run: reply = .run(.init(record: nil))
      case .job(let offered): XCTAssertEqual(offered.id, input.id); offers += 1; reply = .job(receipt)
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .projects: reply = .projects(.init(projects: [], nextCursor: nil))
      case .history: reply = .history(.init(messages: [], nextCursor: nil))
      case .conversation: reply = .conversation(.init(threadID: thread, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Existing", ready: true, busy: false,
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
      .init(threadID: thread, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: revision, title: "Task", ready: true, busy: false, activeTurnID: nil,
        messages: [.init(id: "native", turnID: "turn", clientID: nil, role: .assistant, text: "revision \(revision)")],
        requests: [], acceptedMessages: [:], turnStatuses: [:])
    }
    controller = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return XCTFail("Expected request") }
      let reply: NotebookChatReply
      switch query {
      case .run: reply = .run(.init(record: nil))
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
      case .run: reply = .run(.init(record: nil))
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
      case .conversation(let thread): reply = .conversation(.init(threadID: thread, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Task", ready: true, busy: false,
        activeTurnID: nil, messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:]))
      default: return XCTFail("Only the same conversation and saved outbox may be queried")
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
      case .run: reply = .run(.init(record: nil))
      case .message: return XCTFail("No truncated message exists in this scenario")
      case .requestDetails, .stopWaiting, .account, .models, .resources, .file, .resizeRun, .voice, .dictation: return XCTFail("File, terminal, and audio panels are closed")
      case .projects: reply = .projects(.init(projects: [project], nextCursor: nil))
      case .catalogue(_, let selected):
        if selected == project { filtered = true }
        reply = .catalogue(.init(tasks: [task], nextCursor: nil))
      case .activity(let ids): reply = .activity(ids.map { .init(id: $0, status: .running, summary: "Выполняется swift test") })
      case .history(let id, _):
        XCTAssertEqual(id, task.id); reply = .history(.init(messages: [], nextCursor: nil))
      case .conversation(let id):
        XCTAssertEqual(id, task.id)
        reply = .conversation(.init(threadID: id, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: task.title, ready: true, busy: false, activeTurnID: nil,
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
    try await wait { filtered && chat.catalogues[.project(project.id)]?.tasks == [task] }
    XCTAssertEqual(chat.tasks, [task], "Project browsing does not replace the all-chats window")
    XCTAssertTrue(submitted.isEmpty); XCTAssertTrue(chat.jobs.isEmpty)
    chat.select(task)
    try await wait { chat.conversation?.threadID == task.id }
    XCTAssertTrue(submitted.isEmpty, "Opening the real transcript cannot create a task or start a turn")
    chat.draft = "Продолжай эту работу"
    let saved = await chat.sendMessage(to: .thread(task.id), text: chat.draft, context: "")
    XCTAssertTrue(saved)
    try await wait { !submitted.isEmpty }
    XCTAssertEqual(submitted.count, 1); XCTAssertEqual(submitted.first?.action.threadID, task.id)
    chat.browsesChats = true
    let hidden = await chat.sendMessage(to: .thread(task.id), text: "Not to a hidden chat", context: "")
    XCTAssertFalse(hidden)
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }

  func testProjectFoldersOwnTheirPagesWithoutFilteringAllChatsOrChangingTheWorkingProject() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-folders-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory), author = UUID(), peer = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store)
    let first = CodexProject(id: "first", name: "Notebook", roots: ["/fixture/Notebook"])
    let second = CodexProject(id: "second", name: "Research", roots: ["/fixture/Research"])
    let empty = CodexProject(id: "empty", name: "Empty", roots: ["/fixture/Empty"])
    let recent = CodexTask(id: UUID().uuidString, title: "Recent", cwd: "/fixture/Notebook", projectID: first.id)
    let older = CodexTask(id: UUID().uuidString, title: "Older worktree", cwd: "/worktrees/old", projectID: first.id)
    let other = CodexTask(id: UUID().uuidString, title: "Another project", cwd: "/fixture/Research", projectID: second.id)
    var chat: NotebookChatController!, reads: [(String?, String?)] = [], held: NotebookChatEnvelope?, hold = false, renamed = false
    chat = .init(persistence: queue, author: author) { envelope, _ in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .run: reply = .run(.init(record: nil))
      case .projects:
        reply = .projects(.init(projects: [first, renamed ? .init(id: second.id, name: "Renamed", roots: second.roots) : second, empty], nextCursor: nil))
      case .catalogue(let cursor, let project):
        reads.append((project?.id, cursor))
        if hold, project?.id == first.id { held = envelope; return }
        if project?.id == first.id { reply = .catalogue(.init(tasks: cursor == nil ? [recent] : [older], nextCursor: cursor == nil ? "first-older" : nil)) }
        else if project?.id == second.id { reply = .catalogue(.init(tasks: [other], nextCursor: nil)) }
        else if project?.id == empty.id { reply = .catalogue(.init(tasks: [], nextCursor: nil)) }
        else { reply = .catalogue(.init(tasks: [recent, other], nextCursor: nil)) }
      case .history: reply = .history(.init(messages: [], nextCursor: nil))
      case .activity(let ids):
        XCTAssertLessThanOrEqual(ids.count, 8); reply = .activity(ids.map { .init(id: $0, status: .idle) })
      case .conversation(let id): reply = .conversation(.init(threadID: id, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Native", ready: true, busy: false, activeTurnID: nil,
        messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:]))
      default: return XCTFail("Browsing is read-only, not a task or process launch: \(query)")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    func wait(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(6)
      while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertTrue(condition())
    }
    await chat.start(); await chat.connect(peer); chat.expanded = true
    try await wait { chat.projects.count == 3 && chat.tasks.count == 2 }
    chat.select(recent); chat.draft = "Keep the draft"
    chat.browse(.projects)
    XCTAssertTrue(reads.allSatisfy { $0.0 == nil }, "Closed folders must not load their tasks eagerly")
    chat.toggleProject(first); chat.toggleProject(second); chat.toggleProject(empty)
    try await wait { chat.catalogues[.project(empty.id)]?.loaded == true && chat.catalogues[.project(second.id)]?.tasks == [other] }
    XCTAssertEqual(chat.catalogues[.project(empty.id)]?.tasks, [])
    XCTAssertEqual(chat.threadID, recent.id); XCTAssertEqual(chat.selectedProject, first)
    chat.catalogue(next: true, project: first)
    try await wait { chat.catalogues[.project(first.id)]?.tasks == [recent, older] }
    XCTAssertEqual(chat.tasks, [recent, other], "A child outside the recent page belongs only to its folder window")
    XCTAssertTrue(reads.contains { $0.0 == first.id && $0.1 == "first-older" })
    chat.toggleProject(first)
    let firstReads = reads.filter { $0.0 == first.id }.count
    chat.synchronizeVisibleIfDue(now: .now + .seconds(20))
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(reads.filter { $0.0 == first.id }.count, firstReads, "Collapsed folders are not polled")
    chat.browse(.chats)
    XCTAssertEqual(chat.tasks, [recent, other]); XCTAssertEqual(chat.expandedProjects, [second.id, empty.id])
    chat.select(other)
    XCTAssertEqual(chat.selectedProject, second); XCTAssertEqual(chat.runs.selectedRoot?.root, second.roots[0])
    XCTAssertEqual(chat.draft, "Keep the draft"); XCTAssertTrue(chat.jobs.isEmpty)
    renamed = true; chat.synchronizeVisibleIfDue(now: .now + .seconds(20))
    try await wait { chat.selectedProject?.name == "Renamed" }
    XCTAssertFalse(chat.browsesChats); XCTAssertEqual(chat.threadID, other.id)

    // A late folder read from a disconnected computer cannot republish its window.
    chat.browse(.projects); hold = true; chat.toggleProject(first)
    try await wait { held != nil }
    let late = try XCTUnwrap(held)
    chat.disconnect(peer)
    chat.receive(.init(id: late.id, body: .reply(.catalogue(.init(tasks: [], nextCursor: nil)))), peerID: peer)
    XCTAssertEqual(chat.catalogues[.project(first.id)]?.tasks, [recent, older])
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
  }

}
