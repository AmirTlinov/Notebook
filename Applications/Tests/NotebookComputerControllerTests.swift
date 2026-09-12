import XCTest
@testable import NotebookCore
@testable import Notebook

@MainActor final class NotebookComputerControllerTests: XCTestCase {
  func testFailedDraftWriteKeepsTheSelectedComputerAndUnsavedTextUntilRetry() async throws {
    enum Fault: Error { case disk }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("computer-write-failure-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("fail-commit"), author = UUID(), first = UUID(), second = UUID()
    let store = NotebookStore(root: root) { point in if case .beforeCommit = point, FileManager.default.fileExists(atPath: marker.path) { throw Fault.disk } }
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    try store.saveChatPanel(.init(threadID: UUID().uuidString, draft: "initial", sidecarID: first), author: author)
    let queue = NotebookPersistenceQueue(store: store)
    let controller = NotebookChatController(persistence: queue, author: author) { _, _ in }
    await controller.start()
    controller.updateComputers([.init(deviceID: first, workspaceID: UUID(), displayName: "First"), .init(deviceID: second, workspaceID: UUID(), displayName: "Second")])
    try Data().write(to: marker)
    controller.draft = "still mine"
    let failed = await queue.flush(); XCTAssertFalse(failed)
    await controller.chooseComputer(second)
    XCTAssertEqual(controller.computerID, first); XCTAssertEqual(controller.draft, "still mine")
    XCTAssertEqual(try store.activeChatComputer(author: author), first)
    try FileManager.default.removeItem(at: marker); queue.retry()
    let saved = await queue.flush(); XCTAssertTrue(saved)
    await controller.chooseComputer(second); XCTAssertEqual(controller.computerID, second)
    await controller.chooseComputer(first); XCTAssertEqual(controller.draft, "still mine")
    await controller.stop()
  }

  func testTwoMacsRestoreTheirOwnMaterialAndNeverExchangePendingCommands() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("two-macs-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID(), first = UUID(), second = UUID(), workspace = UUID(), thread = UUID().uuidString
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let project = CodexProject(id: "same-project", name: "Code", roots: ["/fixture"])
    let addresses = [first, second].map { NotebookFileAddress(computer: $0, project: project.id, root: "/fixture", path: "same.py") }
    let peers = [first, second].enumerated().map { NotebookTransportIdentity(deviceID: $0.element, workspaceID: workspace, displayName: "Mac \($0.offset)") }
    for (index, address) in addresses.enumerated() {
      try store.saveChatPanel(.init(threadID: thread, draft: "draft \(index)", sidecarID: address.computer), author: author)
      var window = NotebookFileWindowState(); window.project = project; window.selected = address; window.isOpen = true; window.sidebar = index == 0
      try store.saveFileWindow(window, author: author, computer: address.computer)
      var draft = NotebookFileDraft(address: address, text: "original \(index)"); draft.scroll = Double(200 + index)
      try store.saveFileDraft(draft)
    }
    try store.savePresence(.init(mode: .board, camera: .init(center: .init(x: -240, y: 731), scale: 0.42), viewport: .init(x: 834, y: 1194)))
    let fragment = NotebookCodeFragment(file: addresses[0], sourceHash: NotebookFileVersion.hash(Data("original 0".utf8)), utf16Offset: 0,
      text: "original 0", width: 600, height: 120, fontSize: 15, stamp: .init(counter: 1, actor: author))
    try store.captureCodeFragment(fragment)
    let queue = NotebookPersistenceQueue(store: store)
    var chat: NotebookChatController!, offered: [(UUID, NotebookChatInput)] = []
    chat = .init(persistence: queue, author: author) { envelope, computer in
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      switch query {
      case .projects: reply = .projects(.init(projects: [project], nextCursor: nil))
      case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
      case .history: reply = .history(.init(messages: [], nextCursor: nil))
      case .job(let input):
        offered.append((computer, input))
        reply = .job(.init(input: input, state: .accepted, result: .turn(UUID().uuidString), revision: 2))
      default: reply = .failure("Not needed for the offline restoration scenario")
      }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: computer)
    }
    await chat.start(); chat.updateComputers(peers)
    let presence = try store.loadPresence()
    XCTAssertEqual(chat.files.document?.address, addresses[0])
    let sent = await chat.sendMessage(threadID: thread, text: "draft 0", context: "")
    XCTAssertTrue(sent)
    let originalID = try XCTUnwrap(chat.jobs.first?.id)
    await chat.connect(second)
    XCTAssertEqual(chat.computerID, first, "A second connection never steals the selection")
    await chat.chooseComputer(second)
    XCTAssertEqual(chat.draft, "draft 1"); XCTAssertEqual(chat.files.document?.text, "original 1")
    XCTAssertEqual(chat.files.document?.scroll, 201); XCTAssertFalse(chat.files.window.sidebar)
    XCTAssertTrue(chat.jobs.isEmpty)
    chat.files.edit("edited second", address: addresses[1], selection: 3, scroll: 500)
    let runInput = try await chat.sessionCommand(.writeRun(UUID(), Data("bound to first".utf8)), computer: first)
    XCTAssertEqual(runInput.state, .saved)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(offered.contains { $0.1.id == originalID || $0.1.id == runInput.id })
    await chat.files.open(addresses[0])
    XCTAssertEqual(chat.computerID, first, "A trusted file link chooses its actual Mac")
    XCTAssertEqual(chat.files.document?.text, "original 0"); XCTAssertEqual(chat.files.document?.scroll, 200)
    await chat.connect(first)
    let deadline = ContinuousClock.now + .seconds(5)
    while offered.filter({ $0.1.id == originalID || $0.1.id == runInput.id }).count < 2, .now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(offered.contains { $0.0 == first && $0.1.id == originalID })
    XCTAssertTrue(offered.contains { $0.0 == first && $0.1.id == runInput.id })
    XCTAssertFalse(offered.contains { $0.0 == second && ($0.1.id == originalID || $0.1.id == runInput.id) })
    chat.updateComputers([peers[1]])
    XCTAssertFalse(chat.connected); XCTAssertEqual(chat.files.document?.text, "original 0", "Revocation retains local material")
    XCTAssertEqual(try store.codeFragment(fragment.id), fragment)
    XCTAssertTrue(chat.files.notes.fragments.contains(fragment), "Revocation does not delete Notebook annotations")
    await chat.chooseComputer(second)
    XCTAssertEqual(chat.files.document?.text, "edited second"); XCTAssertEqual(chat.files.document?.scroll, 500)
    await chat.stop(); let flushed = await queue.flush(); XCTAssertTrue(flushed)
    XCTAssertEqual(try store.loadPresence(), presence)
    let cold = NotebookChatController(persistence: queue, author: author) { _, _ in XCTFail("Cold restore is offline") }
    await cold.start()
    XCTAssertEqual(cold.computerID, second); XCTAssertEqual(cold.draft, "draft 1")
    XCTAssertEqual(cold.files.document?.text, "edited second"); XCTAssertEqual(cold.files.document?.scroll, 500)
    await cold.stop()
  }
}
