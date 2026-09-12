import XCTest
import WebKit
import NotebookCore
@testable import Notebook

@MainActor final class NotebookRunControllerTests: XCTestCase {
  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), .now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(predicate())
  }
  func testRealTerminalParsesPTYAndReconnectsSameProcessWithoutMovingPaper() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory.appendingPathComponent("ipad")), mac = NotebookStore(root: directory.appendingPathComponent("mac"))
    let author = UUID(), computer = UUID(), project = CodexProject(id: "demo", name: "Demo", roots: ["/tmp/demo"])
    for db in [store, mac] { _ = try db.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194)) }
    try store.savePresence(.init(mode: .board, camera: .init(center: .init(x: 123, y: -456), scale: 0.31), viewport: .init(x: 834, y: 1194)))
    let before = try store.loadPresence(), queue = NotebookPersistenceQueue(store: store)
    var chat: NotebookChatController!, starts = 0, inputs: [Data] = []
    chat = .init(persistence: queue, author: author) { envelope, peer in
      XCTAssertEqual(peer, computer)
      guard case .request(let query) = envelope.body else { return }
      let reply: NotebookChatReply
      do {
        switch query {
        case .catalogue: reply = .catalogue(.init(tasks: [], nextCursor: nil))
        case .projects: reply = .projects(.init(projects: [project], nextCursor: nil))
        case .run(let read): reply = .run(try mac.readRun(read))
        case .resizeRun: reply = .acknowledged
        case .job(let input):
          var job = try mac.saveChatInput(input)
          if job.state == .saved {
            _ = try mac.advanceChatJob(input.id, from: .saved, to: .attempting)
            let result: NotebookChatResult
            switch input.action {
            case .startRun(let request):
              starts += 1; try mac.admitRun(.init(id: input.id, author: input.author, request: request))
              try mac.receiveRunEvent(input.id, .output(Data("\u{1b}[32mREADY\u{1b}[0m\r\n".utf8))); result = .run(input.id)
            case .writeRun(let id, let bytes): inputs.append(bytes); try mac.receiveRunEvent(id, .output(bytes)); result = .acknowledged
            default: throw NotebookTransportError.invalidAcknowledgement
            }
            job = try mac.advanceChatJob(input.id, from: .attempting, to: .accepted, result: result)
          }
          reply = .job(job)
        default: reply = .failure("outside terminal scenario")
        }
      } catch { reply = .failure(error.localizedDescription) }
      chat.receive(.init(id: envelope.id, body: .reply(reply)), peerID: peer)
    }
    await chat.start(); chat.connect(computer); chat.selectProject(project); chat.expanded = true
    let root = try XCTUnwrap(chat.runs.selectedRoot)
    let container = UIView(frame: .init(x: 0, y: 0, width: 560, height: 280))
    let host = UIViewController(); host.view = container
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 560, height: 280); window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let owner = NotebookTerminalView.Coordinator(runs: chat.runs, root: root)
    owner.connected(true); owner.mount(container)
    defer { owner.close() }
    try await wait { owner.ready && chat.runs.root == root && !chat.runs.loadingCommand }
    chat.runs.command = "python3 main.py"; await chat.runs.start()
    try await wait { chat.runs.record?.phase == .running }
    let id = try XCTUnwrap(chat.runs.record?.id), web = try XCTUnwrap(owner.web)
    let rendered = try await web.evaluateJavaScript("terminal.buffer.active.getLine(0).translateToString(true)") as? String
    XCTAssertEqual(rendered, "READY")
    let image = try await web.takeSnapshot(configuration: nil)
    let attachment = XCTAttachment(image: image); attachment.name = "project-terminal-ansi"; attachment.lifetime = .keepAlways; add(attachment)
    _ = try await web.evaluateJavaScript("terminal.input('привет\\r',true)")
    try await wait { !inputs.isEmpty }
    XCTAssertEqual(inputs, [Data("привет\r".utf8)])
    chat.expanded = false; chat.disconnect(computer); owner.close()
    try mac.receiveRunEvent(id, .output(Data("\r\nWHILE_OFFLINE\r\n".utf8)))
    XCTAssertTrue(try XCTUnwrap(mac.runRecord(id)).isActive)
    chat.connect(computer)
    let reopened = NotebookTerminalView.Coordinator(runs: chat.runs, root: root)
    reopened.connected(true); reopened.mount(container)
    defer { reopened.close() }
    try await wait { reopened.ready && chat.runs.record?.id == id }
    XCTAssertEqual(starts, 1); XCTAssertEqual(chat.runs.command, "python3 main.py")
    let text = try await XCTUnwrap(reopened.web).evaluateJavaScript("Array.from({length:terminal.buffer.active.length},(_,i)=>terminal.buffer.active.getLine(i).translateToString(true)).join('\\n')") as? String
    XCTAssertTrue(text?.contains("WHILE_OFFLINE") == true)
    XCTAssertEqual(try store.loadPresence(), before)
    reopened.close(); await chat.stop()
    let flushed = await queue.flush(); XCTAssertTrue(flushed)
    XCTAssertEqual(try store.runCommand(root: root), "python3 main.py")
    XCTAssertNil(reopened.web); XCTAssertNil(reopened.lease)
  }
}
