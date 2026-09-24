import Foundation
import CryptoKit
import Testing
@testable import NotebookCore

@Suite("Codex delivery survives lost acknowledgements without a second executor")
struct NotebookChatStoreTests {
  @Test(arguments: [false, true])
  func existingV22OutboxIsAdmittedBeforeReadingFirstMessages(alreadyHasColumn: Bool) throws {
    try fixture { store, author in
      let computer = UUID(), creation = NotebookChatInput(author: author, action: .create(title: "Before upgrade"))
      let first = NotebookChatFirstMessage(text: "Unsent first message", context: "frozen")
      let oldJob = try store.saveChatSubmission(creation, to: computer, firstMessage: alreadyHasColumn ? first : nil)
      let panel = NotebookChatPanelState(draft: "Keep my draft", sidecarID: computer)
      try store.saveChatPanel(panel, author: author)
      try store.acknowledgePeer(peerID: computer, through: 0)
      let database = try store.prepareDatabase()
      let deliveryFloor = try database.rows("SELECT value FROM metadata WHERE key='ink_outgoing_floor'").first?[0].text
      let identity = try database.rows("SELECT value FROM metadata WHERE key='workspace_id'").first![0].text
      let records = try database.rows("SELECT address,hash FROM records ORDER BY address").map { $0[0].text! + ":" + $0[1].text! }
      let cursor = try database.rows("SELECT MAX(sequence) FROM change_log").first![0].integer
      if !alreadyHasColumn { try database.run("ALTER TABLE chat_jobs DROP COLUMN first_message") }
      try database.run("PRAGMA user_version=22")

      // Enter through the same first read that failed on the installed iPad,
      // not through the fresh-workspace schema builder.
      let upgraded = NotebookStore(root: store.root)
      #expect(try upgraded.chatFirstMessage(creation.id) == (alreadyHasColumn ? first : nil))
      #expect(try upgraded.chatPanel(author: author, computer: computer) == panel)
      #expect(try upgraded.chatJob(creation.id) == oldJob)
      #expect(try upgraded.chatDestination(creation.id) == computer)
      #expect(try upgraded.peerCursor(peerID: computer, direction: .outgoing) == 0)
      #expect(try database.rows("SELECT value FROM metadata WHERE key='ink_outgoing_floor'").first?[0].text == deliveryFloor)
      #expect(try database.rows("PRAGMA user_version").first![0].integer == NotebookStore.currentDatabaseVersion)
      #expect(try database.rows("SELECT value FROM metadata WHERE key='workspace_id'").first![0].text == identity)
      #expect(try database.rows("SELECT address,hash FROM records ORDER BY address").map { $0[0].text! + ":" + $0[1].text! } == records)
      #expect(try database.rows("SELECT MAX(sequence) FROM change_log").first![0].integer == cursor)

      let next = NotebookChatInput(author: author, action: .create(title: "After upgrade"))
      let nextMessage = NotebookChatFirstMessage(text: "After upgrade", context: "")
      _ = try upgraded.saveChatSubmission(next, to: computer, firstMessage: nextMessage)
      let task = CodexTask(id: UUID().uuidString, title: "After upgrade", cwd: "/fixture")
      let receipt = NotebookChatJob(input: next, state: .accepted, result: .created(task), revision: 1)
      _ = try upgraded.receiveChatReceipt(receipt)
      _ = try NotebookStore(root: store.root).receiveChatReceipt(receipt)
      #expect(try upgraded.chatJob(nextMessage.id)?.input == nextMessage.input(threadID: task.id, author: author))
    }
  }

  @Test func firstMessageSurvivesRestartAndCreationReceiptReleasesExactlyOneOrdinarySend() throws {
    try fixture { store, author in
      let computer = UUID(), creation = NotebookChatInput(author: author, action: .create(title: "New"))
      let attachment = CodexInputAttachment(kind: .skill, name: "Skill", path: "/fixture/SKILL.md")
      let first = NotebookChatFirstMessage(text: "Привет", context: "frozen", attentionContextID: UUID(), attachments: [attachment])
      try store.saveChatPanel(.init(draft: first.text, sidecarID: computer, attachments: [attachment], creationID: creation.id), author: author)
      _ = try store.saveChatSubmission(creation, to: computer, firstMessage: first)
      #expect(try store.chatPanel(author: author).draft.isEmpty)
      #expect(try store.pendingChatJobs().map(\.id) == [creation.id])
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.chatFirstMessage(creation.id) == first)
      let unknown = NotebookChatJob(input: creation, state: .uncertain, error: "Disconnected", revision: 1)
      _ = try reopened.receiveChatReceipt(unknown)
      #expect(try reopened.chatJob(first.id) == nil)
      let other = UUID().uuidString
      try reopened.saveChatPanel(.init(threadID: other, draft: "Newer draft", sidecarID: computer), author: author)
      let task = CodexTask(id: UUID().uuidString, title: "New", cwd: "/fixture")
      let accepted = NotebookChatJob(input: creation, state: .accepted, result: .created(task), revision: 2)
      _ = try reopened.receiveChatReceipt(accepted)
      _ = try reopened.receiveChatReceipt(accepted)
      _ = try reopened.receiveChatReceipt(unknown)
      #expect(try reopened.chatJob(first.id)?.input == first.input(threadID: task.id, author: author))
      #expect(try reopened.chatDestination(first.id) == computer)
      #expect(try reopened.pendingChatJobs().map(\.id) == [first.id])
      #expect(try reopened.chatPanel(author: author).threadID == other)
      #expect(try reopened.chatPanel(author: author).draft == "Newer draft")
    }
  }

  @Test func invalidOrConflictingFirstMessageCannotPartiallyCommitCreation() throws {
    try fixture { store, author in
      let creation = NotebookChatInput(author: author, action: .create(title: "New"))
      #expect(throws: (any Error).self) {
        try store.saveChatSubmission(creation, firstMessage: .init(text: " ", context: ""))
      }
      #expect(try store.chatJob(creation.id) == nil)
      let first = NotebookChatFirstMessage(text: "Saved", context: "")
      _ = try store.saveChatSubmission(creation, firstMessage: first)
      #expect(throws: (any Error).self) {
        try store.saveChatSubmission(creation, firstMessage: .init(text: "Different", context: ""))
      }
      let rejected = NotebookChatJob(input: creation, state: .rejected, error: "Sign in", revision: 1)
      _ = try store.receiveChatReceipt(rejected)
      #expect(try store.chatFirstMessage(creation.id) == first)
      #expect(try store.chatJob(first.id) == nil)
    }
  }

  @Test func largeLaserPixelsUseEvidenceBlobsWhileTheJobRemainsASmallPacket() throws {
    try fixture { store, author in
      let region = PageRect(x:0,y:0,width:1,height:1)
      let reference = CollaborationReference(target:.init(kind:.page,id:UUID()),region:region,revision:"frozen-laser-source")
      var png = try #require(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
      png.append(Data(repeating:0,count:300_000)) // Artificial oversized payload exercises framing, not PNG rendering.
      let image = try AgentPinnedImage(referenceID:reference.id,sourceRevision:reference.revision,region:region,
        worldOrigin:nil,pageIndex:nil,pixelWidth:1,pixelHeight:1,pixelsPerPoint:1,png:png,
        sha256:SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined())
      let before = try store.readContextSelection()
      let attachments = try store.saveChatImageAttachments([.init(reference:reference,image:image)],author:author)
      #expect(attachments.count == 1); #expect(attachments[0].imagePNG == nil)
      #expect(try store.readContextSelection() == before)
      let input = NotebookChatInput(author:author,action:.send(threadID:UUID().uuidString,text:"Explain",context:""),attachments:attachments)
      #expect(input.isValid)
      #expect(try JSONEncoder().encode(input).count < 2048)
      let resolved = try #require(try store.resolvedChatImageAttachments(attachments))
      #expect(resolved[0].imagePNG == png)
      #expect(!NotebookChatInput(author:author,action:input.action,attachments:resolved).isValid,
        "Resolved pixels cannot accidentally go back through the short chat packet")
      let missing = CodexInputAttachment(kind:.image,name:"missing",path:"notebook-laser:"+UUID().uuidString+"/"+UUID().uuidString)
      #expect(try store.resolvedChatImageAttachments([missing]) == nil)
    }
  }
  enum Fault: Error { case injected }
  func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-chat-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    try body(store, author)
  }
  func input(_ author: UUID, id: UUID = UUID(), text: String = "Почему x² ≥ 0?") -> NotebookChatInput {
    .init(id: id, author: author, action: .send(threadID: "00000000-0000-0000-0000-000000000001", text: text, context: ""), createdAt: Date(timeIntervalSince1970: 100))
  }

  @Test func approvalDetailsUseTheControlLaneAndDecisionsAreGenerationBound() {
    let author = UUID(), first = UUID(), second = UUID()
    let read = NotebookChatQuery.requestDetails(threadID: "thread", generation: first, requestID: "1")
    #expect(read.isInteractiveControl)
    func action(_ generation: UUID) -> NotebookChatAction {
      .respond(threadID: "thread", request: .init(nativeID: .number(1), generation: generation,
        method: "item/commandExecution/requestApproval", turnID: "turn", parameters: .object([:])), decision: .decline)
    }
    #expect(action(first).controlID(author: author) == action(first).controlID(author: author))
    #expect(action(first).controlID(author: author) != action(second).controlID(author: author))
  }

  @Test func endingUnknownObservationPreservesOutcomeAndFreesAdmissionWithoutReplay() throws {
    try fixture { store, author in
      let message = input(author)
      _ = try store.saveChatInput(message)
      _ = try store.advanceChatJob(message.id, from: .saved, to: .attempting)
      _ = try store.advanceChatJob(message.id, from: .attempting, to: .uncertain)
      #expect(throws: (any Error).self) { try store.stopWaitingForChatJob(message.id, author: UUID()) }
      let finished = try store.stopWaitingForChatJob(message.id, author: author)
      #expect(finished.state == .unconfirmed && finished.isTerminal && finished.result == nil)
      #expect(try store.pendingChatJobs().isEmpty)
      #expect(try store.saveChatInput(message) == finished)
      #expect(try store.stopWaitingForChatJob(message.id, author: author) == finished)
      #expect(throws: (any Error).self) { try store.advanceChatJob(message.id, from: .unconfirmed, to: .saved) }
    }
  }
  @Test func nativeCreationCheckpointAndControlPayloadSurviveReopening() throws {
    try fixture { store, author in
      let creation = NotebookChatInput(author: author, action: .create(title: "Task"))
      _ = try store.saveChatInput(creation)
      _ = try store.advanceChatJob(creation.id, from: .saved, to: .attempting)
      let task = CodexTask(id: UUID().uuidString, title: "Codex", cwd: "/tmp")
      try store.recordCreatedChatTask(creation.id, task: task)
      _ = try store.advanceChatJob(creation.id, from: .attempting, to: .uncertain)
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.chatJob(creation.id)?.createdTask == task)
      let action = NotebookChatAction.stop(threadID: UUID().uuidString, turnID: UUID().uuidString)
      let control = NotebookChatInput(id: action.controlID(author: author)!, author: author, action: action)
      _ = try store.saveChatInput(control, to: author)
      #expect(try reopened.savedChatControl(action, author: author, computer: author)?.input == control)
    }
  }

  @Test func attachmentsCommitWithTheirMessageAndCannotClearANewerSelection() throws {
    try fixture { store, author in
      let thread = UUID().uuidString, computer = UUID()
      let file = CodexInputAttachment(kind: .file, name: "code.swift", path: "/tmp/code.swift")
      let plugin = CodexInputAttachment(kind: .plugin, name: "plugin", path: "plugin://exact@market")
      try store.saveChatPanel(.init(threadID: thread, draft: "Read", sidecarID: computer, attachments: [file]), author: author)
      let first = NotebookChatInput(author: author, action: .send(threadID: thread, text: "Read", context: ""), attachments: [file])
      _ = try store.saveChatSubmission(first, to: computer)
      let cleared = try store.chatPanel(author: author, computer: computer)
      #expect(cleared.draft.isEmpty); #expect(cleared.attachments == nil)
      #expect(try store.chatJob(first.id)?.input.attachments == [file])
      try store.saveChatPanel(.init(threadID: thread, draft: "Read", sidecarID: computer, attachments: [plugin]), author: author)
      _ = try store.saveChatSubmission(first, to: computer)
      #expect(try store.chatPanel(author: author, computer: computer).attachments == [plugin])
      #expect(try store.chatPanel(author: author, computer: computer).draft == "Read")
      #expect(try store.chatPanel(author: author, computer: UUID()).attachments == nil)
    }
  }

  @Test func oneShotImagesStayInTheirDurableMessageButNeverInTheNextDraft() throws {
    try fixture { store, author in
      let thread = UUID().uuidString, computer = UUID()
      let file = CodexInputAttachment(kind:.file,name:"code.swift",path:"/tmp/code.swift")
      let image = CodexInputAttachment(kind:.image,name:"Лазер",path:"notebook-laser:"+UUID().uuidString+"/"+UUID().uuidString)
      try store.saveChatPanel(.init(threadID:thread,draft:"Explain",sidecarID:computer,attachments:[file]),author:author)
      let input = NotebookChatInput(author:author,action:.send(threadID:thread,text:"Explain",context:""),attachments:[file,image])
      _ = try store.saveChatSubmission(input,to:computer)
      let panel = try store.chatPanel(author:author,computer:computer)
      #expect(panel.draft.isEmpty); #expect(panel.attachments == nil)
      #expect(try store.chatJob(input.id)?.input.attachments == [file,image])
      _ = try store.saveChatSubmission(input,to:computer)
      #expect(try store.chatJob(input.id)?.input == input)
      #expect(try store.chatPanel(author:author,computer:computer).attachments == nil)
    }
  }

  @Test func currentStoredCreationWithoutProjectStillDecodesAndOlderWireVersionRefuses() throws {
    let action = try JSONDecoder().decode(NotebookChatAction.self, from: Data(#"{"create":{"title":"Task"}}"#.utf8))
    #expect(action == .create(title: "Task", project: nil))
    let packet = NotebookTransportPacket(sequence: 1, message: .transient(.codex(.init(body: .reply(.failure("notice"))))))
    let bytes = try JSONEncoder().encode(packet)
    var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    object["version"] = 2
    #expect(throws: NotebookTransportError.unsupportedVersion) {
      try NotebookTransportFraming.decode(JSONSerialization.data(withJSONObject: object))
    }
  }

  @Test func steeringClearsOnlyItsOwnDraftAndKeepsItsIdentityAndTurn() throws {
    try fixture { store, author in
      let thread = UUID().uuidString, turn = UUID().uuidString
      try store.saveChatPanel(.init(threadID: thread, draft: "clarify", sidecarID: nil), author: author)
      let input = NotebookChatInput(author: author, action: .steer(threadID: thread, turnID: turn, text: "clarify", context: "source"))
      let saved = try store.saveChatSubmission(input)
      #expect(try store.chatPanel(author: author).draft.isEmpty)
      #expect(try store.saveChatInput(input) == saved)
      #expect(try JSONDecoder().decode(NotebookChatInput.self, from: JSONEncoder().encode(input)) == input)
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      #expect(try store.advanceChatJob(input.id, from: .attempting, to: .accepted, result: .turn(turn)).isValid)
    }
  }
  @Test func conversationEventsCannotCoalesceAwayADeliveryReply() throws {
    let state = CodexConversation(threadID: UUID().uuidString, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Task", ready: true, busy: false, activeTurnID: nil,
      messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:])
    let event = NotebookTransportTransient.codex(.init(body: .event(subscriptionID: UUID(), conversation: state)))
    let response = NotebookTransportTransient.codex(.init(body: .reply(.conversation(state))))
    #expect(response.priority < event.priority)
  }

  @Test func projectEditIsNativeScopedAndReplaysTheSameDurableReceipt() throws {
    try fixture { store, author in
      let edit = CodexProjectEdit(id: "native-project", name: "New name", roots: nil)
      let input = NotebookChatInput(author: author, action: .updateProject(edit))
      #expect(input.isValid); #expect(input.action.threadID == nil)
      let saved = try store.saveChatInput(input)
      #expect(try store.saveChatInput(input) == saved)
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      let result = CodexProject(id: edit.id, name: "New name", roots: ["/newer-native-root"])
      let receipt = try store.advanceChatJob(input.id, from: .attempting, to: .accepted, result: .project(result))
      #expect(try store.saveChatInput(input) == receipt)
      #expect(!CodexProjectEdit(id: edit.id, name: nil, roots: ["relative/path"]).isValid)
      #expect(!CodexProjectEdit(id: edit.id, name: nil, roots: ["/same", "/same"]).isValid)
      #expect(!edit.matches(.init(id: "other", name: "New name", roots: [])))
    }
  }
  @Test func exactReplayIsNotAnotherMessageAndCollisionCannotEditIt() throws {
    try fixture { store, author in
      let input = input(author), saved = try store.saveChatInput(input)
      #expect(try store.saveChatInput(input) == saved)
      #expect(throws: NotebookStorageError.self) { try store.saveChatInput(self.input(author, id: input.id, text: "different")) }
      #expect(try store.pendingChatJobs() == [saved])
    }
  }
  @Test func controlIdentityNamesAuthorThreadTurnAndNativeRequestButNotTheDecision() throws {
    let author = UUID(), thread = UUID().uuidString, turn = UUID().uuidString
    let request = CodexUserRequest(nativeID: .number(7), method: "item/commandExecution/requestApproval", turnID: turn, parameters: .object([:]))
    let allow = NotebookChatAction.respond(threadID: thread, request: request, decision: .allowOnce)
    let decline = NotebookChatAction.respond(threadID: thread, request: request, decision: .decline)
    #expect(allow.controlID(author: author) == decline.controlID(author: author))
    #expect(allow.controlID(author: author) != allow.controlID(author: UUID()))
    let stringID = CodexUserRequest(nativeID: .string("7"), method: request.method, turnID: turn, parameters: request.parameters)
    #expect(allow.controlID(author: author) != NotebookChatAction.respond(threadID: thread, request: stringID, decision: .allowOnce).controlID(author: author))
    let stop = NotebookChatAction.stop(threadID: thread, turnID: turn)
    #expect(stop.controlID(author: author) == stop.controlID(author: author))
    #expect(stop.controlID(author: author) != NotebookChatAction.stop(threadID: thread, turnID: UUID().uuidString).controlID(author: author))
    #expect(stop.controlID(author: author) != allow.controlID(author: author))
    #expect(NotebookChatAction.send(threadID: thread, text: "Вопрос", context: "").controlID(author: author) == nil)
  }
  @Test func draftBindingAndQueueDoNotInvalidateCanvasOrReplicateHistory() throws {
    try fixture { store, author in
      let read = try store.currentReadCursor(), changes = try store.currentChangeCursor()
      let panel = NotebookChatPanelState(threadID: UUID().uuidString, draft: "интеграл ∫", sidecarID: UUID())
      try store.saveChatPanel(panel, author: author)
      let input = input(author)
      _ = try store.saveChatInput(input)
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      #expect(try store.currentReadCursor() == read)
      #expect(try store.currentChangeCursor() == changes)
      #expect(try NotebookStore(root: store.root).chatPanel(author: author) == panel)
    }
  }
  @Test(arguments: [NotebookStorageFault.beforeCommit, .afterCommit])
  func disconnectAtAttemptBoundaryNeverErasesAnAcceptedAttempt(fault: NotebookStorageFault) throws {
    try fixture { store, author in
      let input = input(author); _ = try store.saveChatInput(input)
      let failing = NotebookStore(root: store.root) { point in
        if String(describing: fault) == String(describing: point) { throw Fault.injected }
      }
      #expect(throws: Fault.self) { try failing.advanceChatJob(input.id, from: .saved, to: .attempting) }
      let recovered = try #require(try NotebookStore(root: store.root).chatJob(input.id))
      #expect(recovered.state == (String(describing: fault) == String(describing: NotebookStorageFault.afterCommit) ? .attempting : .saved))
      #expect(try store.saveChatInput(input) == recovered)
    }
  }
  @Test func recoveryMustReconcileAndCannotRequeueUncertainAcceptance() throws {
    try fixture { store, author in
      let input = input(author); _ = try store.saveChatInput(input)
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      _ = try store.advanceChatJob(input.id, from: .attempting, to: .uncertain)
      #expect(throws: NotebookStorageError.self) { try store.advanceChatJob(input.id, from: .uncertain, to: .saved) }
      let receipt = try store.advanceChatJob(input.id, from: .uncertain, to: .accepted, result: .turn(UUID().uuidString))
      #expect(try store.pendingChatJobs().isEmpty)
      #expect(try store.saveChatInput(input) == receipt)
      #expect(throws: NotebookStorageError.self) { try store.advanceChatJob(input.id, from: .accepted, to: .attempting) }
    }
  }
  @Test func receiptOrderingDoesNotRegressAfterReconnect() throws {
    try fixture { store, author in
      let input = input(author); let saved = try store.saveChatInput(input)
      let accepted = NotebookChatJob(input: input, state: .accepted, result: .turn(UUID().uuidString), revision: 2)
      #expect(try store.receiveChatReceipt(accepted) == accepted)
      #expect(try store.receiveChatReceipt(saved) == accepted)
      #expect(try store.receiveChatReceipt(accepted) == accepted)
      #expect(throws: NotebookStorageError.self) {
        try store.receiveChatReceipt(.init(input: input, state: .uncertain, revision: 3))
      }
    }
  }
  @Test func submissionClearsOnlyItsOwnDraftInTheSameTransaction() throws {
    try fixture { store, author in
      let input = input(author), thread = input.action.threadID!
      try store.saveChatPanel(.init(threadID: thread, draft: "Почему x² ≥ 0?"), author: author)
      let failing = NotebookStore(root: store.root) { if case .afterCommit = $0 { throw Fault.injected } }
      #expect(throws: Fault.self) { try failing.saveChatSubmission(input) }
      #expect(try store.chatJob(input.id) != nil)
      #expect(try store.chatPanel(author: author).draft.isEmpty)
      try store.saveChatPanel(.init(threadID: thread, draft: "Новый черновик"), author: author)
      _ = try store.saveChatSubmission(input)
      #expect(try store.chatPanel(author: author).draft == "Новый черновик")
    }
  }
  @Test func peerIdentityAndEnvelopeBudgetAreEnforced() throws {
    let author = UUID(), input = input(author)
    let envelope = NotebookChatEnvelope(body: .request(.job(input)))
    #expect(envelope.isValid(from: author))
    #expect(!envelope.isValid(from: UUID()))
    #expect(!NotebookChatEnvelope(body: .reply(.failure(String(repeating: "x", count: 200 * 1024)))).isValid(from: author))
    #expect(try JSONDecoder().decode(NotebookChatEnvelope.self, from: JSONEncoder().encode(envelope)) == envelope)
    #expect(!self.input(author, text: String(repeating: "x", count: 32769)).isValid)
  }
  @Test func queueIsBoundedAndDoesNotDiscardUnknownMessages() throws {
    try fixture { store, author in
      for _ in 0..<128 { _ = try store.saveChatInput(input(author)) }
      #expect(throws: NotebookStorageError.self) { try store.saveChatInput(input(author)) }
      #expect(try store.pendingChatJobs().count == 128)
      #expect(try store.recentChatJobs(author: author).count == 32)
    }
  }
}

@Suite("Frozen Notebook attention is not a second execution grant")
struct NotebookAttentionEvidenceTests {
  @Test func evidenceSurvivesLaterSourceEditsAndHasNoAgentRequest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-attention-chat-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let pageID = try #require(store.loadIndex().selectedPageID), target = CollaborationTarget(kind: .page, id: pageID)
    let files = try store.referenceSourceFiles(target: target)
    let reference = CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 120, height: 120),
      revision: try NotebookStore.referenceRevision(target: target, files: files))
    let context = try store.appendContext(references: [reference], author: .human, actor: author, select: true)
    let source = try AgentPinnedSource.capture(requestID: context.id, reference: reference, files: files)
      .withVisual(nil, unavailable: "fixture_without_pixels")
    #expect(try !store.hasAttentionEvidence(contextID: context.id))
    try store.saveAttentionEvidence([source], contextID: context.id)
    #expect(try store.hasAttentionEvidence(contextID: context.id))
    let cursor = try store.currentChangeCursor()
    try store.saveAttentionEvidence([source], contextID: context.id)
    #expect(try store.currentChangeCursor() == cursor)
    var page = try store.loadPage(pageID)
    page.replaceElements([.init(id: "later", kind: .markdown, frame: .init(x: 10, y: 10, width: 40, height: 40), source: "human", html: "<p>human</p>")], actor: author)
    try store.savePage(page)
    #expect(try store.referenceRevision(target: target) != reference.revision)
    #expect(try NotebookStore(root: root).attentionEvidence(contextID: context.id, referenceID: reference.id) == source)
    #expect(try store.sqlRead { try $0.rows("SELECT address FROM records WHERE file LIKE 'agent/requests/%' LIMIT 1").isEmpty })
    let changed = try source.withVisual(nil, unavailable: "cannot replace the historical reason")
    #expect(throws: NotebookStorageError.self) { try store.saveAttentionEvidence([changed], contextID: context.id) }
  }
}
