import Foundation
import Testing
@testable import NotebookCore

@Suite("Project runs have one durable admission and bounded Mac output")
struct NotebookRunStoreTests {
  private func fixture(_ body: (NotebookStore, NotebookFileAddress, UUID) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    try store.savePresence(.init(mode: .board, camera: .init(center: .init(x: 123, y: -45), scale: 0.31), viewport: .init(x: 834, y: 1194)))
    try body(store, .init(computer: UUID(), project: "demo", root: "/tmp/demo", path: ""), author)
  }
  @Test func admissionIsIdempotentAndAnotherActiveRunCannotReplaceIt() throws {
    try fixture { store, root, author in
      let input = NotebookChatInput(author: author, action: .startRun(.init(root: root, command: "python3 main.py")))
      _ = try store.saveChatInput(input)
      let run = NotebookRunRecord(id: input.id, author: author, request: .init(root: root, command: "python3 main.py"))
      try store.admitRun(run); try store.admitRun(run)
      #expect(try store.activeRuns() == [run])
      #expect(throws: Error.self) { try store.admitRun(.init(id: UUID(), author: author, request: run.request)) }
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      _ = try store.advanceChatJob(input.id, from: .attempting, to: .accepted, result: .run(input.id))
      #expect(try store.saveChatInput(input).result == .run(input.id))
    }
  }
  @Test func outputRingHasExactCursorAndExplicitLostPrefix() throws {
    try fixture { store, root, author in
      let id = UUID(); try store.admitRun(.init(id: id, author: author, request: .init(root: root, command: "echo")))
      for n in 0..<140 { try store.receiveRunEvent(id, .output(Data(repeating: UInt8(n), count: 8192))) }
      var cursor = "0", collected = Data()
      var page = try store.readRun(.init(root: root, runID: id))
      #expect(page.lostPrefix); #expect(page.data.count == 49_152); #expect(page.more)
      while true {
        collected.append(page.data); cursor = page.after
        if !page.more { break }
        page = try store.readRun(.init(root: root, runID: id, after: cursor)); #expect(!page.lostPrefix)
      }
      #expect(collected.count == 1_048_576); #expect(cursor == "140")
      #expect(collected.first == 12); #expect(collected.last == 139)
      try store.receiveRunEvent(id, .exited(-9))
      try store.receiveRunEvent(id, .output(Data("late".utf8)))
      let done = try store.readRun(.init(root: root, runID: id, after: cursor))
      #expect(done.data.isEmpty); #expect(done.record?.exitCode == -9)
      #expect(try store.activeRuns().isEmpty)
    }
  }
  @Test func commandsAndColdRunRecoveryNeverWritePresenceOrMixComputers() throws {
    try fixture { store, root, author in
      let camera = try store.loadPresence(), revision = try store.currentReadCursor()
      let id = UUID(), record = NotebookRunRecord(id: id, author: author, request: .init(root: root, command: "read value"))
      try store.saveRunCommand(try #require(record.request.command), root: root); try store.admitRun(record)
      try store.receiveRunEvent(id, .output(Data("ready\r\n".utf8)))
      let cold = NotebookStore(root: store.root)
      #expect(try cold.runCommand(root: root) == record.request.command)
      #expect(try cold.latestRun(root: root)?.id == id)
      #expect(try cold.loadPresence() == camera); #expect(try cold.currentReadCursor() == revision)
      let other = NotebookFileAddress(computer: UUID(), project: root.project, root: root.root, path: "")
      #expect(try cold.latestRun(root: other) == nil); #expect(try cold.runCommand(root: other).isEmpty)
    }
  }
  @Test func wireRejectsAmbiguousCursorOversizedInputAndFileInsteadOfRoot() {
    let root = NotebookFileAddress(computer: UUID(), project: "demo", root: "/tmp", path: "")
    for cursor in ["01", "-1", "1.0", "9007199254740992"] { #expect(!NotebookRunRead(root: root, after: cursor).isValid) }
    #expect(!NotebookRunRequest(root: root.child("a.py"), command: "echo").isValid)
    #expect(!NotebookRunRequest(root: root, command: " ").isValid)
    let author = UUID()
    #expect(!NotebookChatInput(author: author, action: .writeRun(UUID(), Data(repeating: 0, count: 8193))).isValid)
  }
  @Test func shellIsExplicitAndExistingCommandsAndWindowStateRemainReadable() throws {
    try fixture { store, root, author in
      let shell = NotebookRunRequest(root: root)
      #expect(shell.isValid); #expect(shell.command == nil)
      try store.admitRun(.init(id: UUID(), author: author, request: shell))
      #expect(try NotebookStore(root: store.root).latestRun(root: root)?.request == shell)
      let old = NotebookRunRequest(root: root, command: "printf hello")
      #expect(try JSONDecoder().decode(NotebookRunRequest.self, from: JSONEncoder().encode(old)) == old)
      var state = NotebookFileWindowState(); state.terminal = true; state.terminalFraction = 0.7
      try store.saveFileWindow(state, author: author)
      #expect(try NotebookStore(root: store.root).fileWindow(author: author).terminalFraction == 0.7)
      let previous = try JSONDecoder().decode(NotebookFileWindowState.self, from: Data("{\"isOpen\":false,\"sidebar\":true,\"terminal\":true}".utf8))
      #expect(previous.terminal == true); #expect(previous.terminalFraction == nil)
    }
  }
  @Test func interactiveCharacterBurstsShareAReadWithoutSkippingItsByteLimitedCursor() throws {
    try fixture { store, root, author in
      let id = UUID(); try store.admitRun(.init(id: id, author: author, request: .init(root: root)))
      for _ in 0..<40 { try store.receiveRunEvent(id, .output(Data("x".utf8))) }
      let page = try store.readRun(.init(root: root))
      #expect(page.data.count == 40); #expect(page.after == "40"); #expect(!page.more)
      for _ in 0..<8 { try store.receiveRunEvent(id, .output(Data(repeating: 65, count: 8192))) }
      let first = try store.readRun(.init(root: root, runID: id, after: page.after))
      #expect(first.data.count == 49_152); #expect(first.after == "46"); #expect(first.more)
      let last = try store.readRun(.init(root: root, runID: id, after: first.after))
      #expect(last.data.count == 16_384); #expect(last.after == "48"); #expect(!last.more)
    }
  }
}
