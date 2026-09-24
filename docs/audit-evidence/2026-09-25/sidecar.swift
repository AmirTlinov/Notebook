import Foundation
import NotebookCore
import NotebookCodex
private actor NativeOwner: NotebookCodexConversationOwner, NotebookCodexCatalogueOwner, NotebookCodexProcessOwner, NotebookCodexVoiceOwner {
  var processStarts = 0, voiceStarts = 0
  func startProcess(id: UUID, request: NotebookRunRequest, publish: @escaping @Sendable (NotebookProcessEvent) async throws -> Void) async throws { processStarts += 1; try await publish(.running) }
  func writeProcess(id: UUID, data: Data) async throws { }
  func resizeProcess(id: UUID, columns: Int, rows: Int) async throws { }
  func stopProcess(id: UUID) async throws { }
  func startVoice(id: UUID, request: NotebookVoiceStart) { voiceStarts += 1 }
  func stopVoice(id: UUID) { }
  func voiceState(id: UUID) -> NotebookVoiceState? { nil }

  let thread = UUID().uuidString, turn = UUID().uuidString
  var busy = false, unknown = false
  var projectEdits = 0
  var project: CodexProject?
  var accessMode = CodexAccessMode.workspace
  var model = CodexModelSelection(model: "fixture", effort: "low")
  var modelChanges = 0
  var pendingRequests: [CodexUserRequest] = []
  var submittedAttachments: [CodexInputAttachment] = []
  var accessChanges = 0
  var sent: [UUID] = [], interrupted: [String] = [], decisions: [CodexUserDecision] = []
  var accepted: [CodexMessage] = []
  var stopIsStale = false
  var needsSignIn = false
  var slowCreation = false
  var failsCreationSetup = false
  func failCreationSetup() { failsCreationSetup = true }
  func delayCreation() { slowCreation = true }
  func requireSignIn(_ required: Bool) { needsSignIn = required }
  func finishBeforeStop() { stopIsStale = true }
  func configure(busy: Bool = false, unknown: Bool = false) { self.busy = busy; self.unknown = unknown }
  func counts() -> (Int, Int) { (sent.count, interrupted.count) }
  var selected: Set<String> = []; var detachCount = 0
  func attach(threadID: String) { selected.insert(threadID) }
  func detach(threadID: String) { selected.remove(threadID); detachCount += 1 }
  func close() { }
  func snapshot(threadID: String) -> CodexConversation? {
    .init(threadID: threadID, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Математика", ready: true, busy: busy, activeTurnID: busy ? turn : nil,
      messages: accepted, requests: pendingRequests, acceptedMessages: [:], turnStatuses: [:],
      access: .init(profileID: accessMode.rawValue, approvalPolicy: .string(accessMode.approvalPolicy), available: CodexAccessMode.allCases), model: model)
  }
  func send(threadID: String, clientMessageID: UUID, text: String, context: String?, attachments: [CodexInputAttachment]) throws -> String {
    submittedAttachments = attachments
    sent.append(clientMessageID)
    accepted.append(.init(id: UUID().uuidString, turnID: turn, clientID: clientMessageID.uuidString.lowercased(), role: .user, text: text))
    if unknown { throw CodexBridgeError.acceptanceUnknown }
    return turn
  }
  func steer(threadID: String, turnID: String, clientMessageID: UUID, text: String, context: String?, attachments: [CodexInputAttachment]) throws -> String {
    guard turnID == turn else { throw CodexBridgeError.staleTurn }
    return try send(threadID: threadID, clientMessageID: clientMessageID, text: text, context: context, attachments: attachments)
  }
  func interrupt(threadID: String, turnID: String) throws {
    if stopIsStale { throw CodexBridgeError.staleTurn }
    interrupted.append(turnID)
  }
  func respond(threadID: String, request: CodexUserRequest, decision: CodexUserDecision) { decisions.append(decision); pendingRequests.removeAll { $0 == request } }
  func setModel(threadID: String, selection: CodexModelSelection) throws {
    modelChanges += 1; model = selection
    if unknown { throw CodexBridgeError.acceptanceUnknown }
  }
  func compact(threadID: String) { }
  func setAccess(threadID: String, mode: CodexAccessMode) throws {
    accessChanges += 1; accessMode = mode
    if unknown { throw CodexBridgeError.acceptanceUnknown }
  }
  func activities(threadIDs: [String]) -> [CodexTaskActivity] { threadIDs.map { .init(id: $0, status: .idle) } }
  func readProject(id: String) -> CodexProject { project ?? .init(id: id, name: "Notebook", roots: ["/tmp"]) }
  func createProject(name: String, path: String, idempotencyKey: UUID) throws -> CodexProject { .init(id: idempotencyKey.uuidString, name: name, roots: [path]) }
  func updateProject(_ edit: CodexProjectEdit) throws -> CodexProject {
    projectEdits += 1
    let value = CodexProject(id: edit.id, name: edit.name ?? "Notebook", roots: edit.roots ?? ["/tmp"])
    project = value
    if unknown { throw CodexBridgeError.acceptanceUnknown }
    return value
  }
  func largeRequests() -> [CodexUserRequest] {
    pendingRequests = (1...4).map { .init(nativeID: .number(Double($0)),
      generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!,
      method: "item/permissions/requestApproval", turnID: turn,
      parameters: .object(["permissions": .object(["fixture": .string(String(repeating: "x", count: 60_000))])])) }
    return pendingRequests
  }
  func models() -> [CodexModelOption] { [.init(id: "fixture", name: "Fixture", efforts: ["low", "high"], defaultEffort: "low")] }
  func resources(threadID: String, kind: CodexResourceKind, cursor: String?) -> CodexResourcePage { .init(resources: []) }
  func projects(cursor: String?) -> CodexProjectPage { .init(projects: [], nextCursor: nil) }
  func tasks(cursor: String?, project: CodexProject?) -> CodexTaskPage { .init(tasks: [.init(id: thread, title: "Математика", cwd: "/tmp")], nextCursor: nil, defaultProviderNeedsSignIn: needsSignIn) }
  func history(threadID: String, cursor: String?) -> CodexHistoryPage { .init(messages: accepted, nextCursor: nil) }
  func create(directory: URL, title: String, workspaceID: UUID, project: CodexProject?, onCreated: @escaping @Sendable (CodexTask) async throws -> Void) async throws -> CodexTask {
    if slowCreation { try await Task.sleep(for: .seconds(5)) }
    if needsSignIn { throw CodexBridgeError.signInRequired }
    let task = CodexTask(id: thread, title: title, cwd: directory.path)
    try await onCreated(task)
    if failsCreationSetup { throw CodexBridgeError.disconnected }
    return task
  }
}

@main struct Probe {
 @MainActor static func main() async throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("notebook-audit-sidecar-"+UUID().uuidString)
  defer { try? FileManager.default.removeItem(at:root) }
  let store=NotebookStore(root:root), peer=UUID(), native=NativeOwner()
  let header=try store.initializeWorkspace(actor:peer,pageSize:.init(width:400,height:600))
  let queue=NotebookPersistenceQueue(store:store)
  let service=NotebookCodexSidecar(persistence:queue,bridge:native,metadata:native,workspaceID:header.workspaceID,directory:root.appendingPathComponent("task"))
  for _ in 0..<3 {
   let reply=await service.receive(.init(body:.request(.conversation(threadID:UUID().uuidString))),peerID:peer)
   guard case .reply(.conversation) = reply?.body else { fatalError("missing conversation") }
   _=await service.receive(.init(body:.request(.activity(threadIDs:[]))),peerID:peer)
  }
  print("CLOSED_PANELS count=3 retainedSelections=\(await native.selected.count) detachCalls=\(await native.detachCount)")
  _=await service.receive(.init(body:.request(.conversation(threadID:UUID().uuidString))),peerID:peer)
  _=await service.receive(.init(body:.request(.conversation(threadID:native.thread))),peerID:peer)
  print("DIRECT_SWITCH retainedSelections=\(await native.selected.count) detachCalls=\(await native.detachCount)")
  service.detachView()
  print("DETACH_VIEW retainedSelections=\(await native.selected.count) detachCalls=\(await native.detachCount)")
  await native.configure(busy:true)
  service.start()
  try await Task.sleep(for:.milliseconds(200))
  let input=NotebookChatInput(author:peer,action:.stop(threadID:native.thread,turnID:native.turn))
  let start=ContinuousClock.now
  _=await service.receive(.init(body:.request(.job(input))),peerID:peer)
  let accepted=start.duration(to:.now)
  while await native.interrupted.isEmpty, start.duration(to:.now) < .seconds(3) { try await Task.sleep(for:.milliseconds(5)) }
  print("STOP savedAfter=\(accepted) nativeInterruptAfter=\(start.duration(to:.now)) interruptCalls=\(await native.interrupted.count)")
  await service.stop()
  _=await queue.flush()
 }
}
