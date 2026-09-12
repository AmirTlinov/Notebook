import Foundation
import Testing
@testable import NotebookCore

@Suite("Computer selection never retargets files, commands or the board")
struct NotebookComputerStoreTests {
  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-computers-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    try body(store, author)
  }
  @Test func installedSingleMacPreferencesMoveOnceWithoutChangingMessageIDsOrContent() throws {
    try fixture { store, author in
      let computer = UUID(), thread = UUID().uuidString
      let input = NotebookChatInput(author: author, action: .send(threadID: thread, text: "Pending", context: ""))
      let saved = try store.saveChatInput(input)
      let panel = NotebookChatPanelState(threadID: thread, draft: "Unsent", sidecarID: computer)
      let file = NotebookFileAddress(computer: computer, project: "project", root: "/code", path: "main.py")
      var window = NotebookFileWindowState(); window.selected = file; window.isOpen = true; window.sidebar = true
      try store.saveFileDraft(.init(address: file, text: "print(4)"))
      try store.commandTransaction(advancesReadRevision: false) {
        try store.currentSQL!.run("INSERT INTO chat_panel(id,value) VALUES(?,?)", [.text(author.uuidString), .blob(try JSONEncoder().encode(panel))])
        try store.currentSQL!.run("INSERT INTO file_window(id,value) VALUES(?,?)", [.text(author.uuidString), .blob(try JSONEncoder().encode(window))])
      }
      let before = try store.archiveContentProof(), revision = try store.currentReadCursor()
      try store.prepareChatComputers(author: author); try store.prepareChatComputers(author: author)
      let cold = NotebookStore(root: store.root)
      #expect(try cold.chatPanel(author: author) == panel)
      #expect(try cold.fileWindow(author: author) == window)
      #expect(try cold.chatJob(input.id) == saved)
      #expect(try cold.chatDestination(input.id) == computer)
      #expect(try cold.routedChatJobs(author: author, computer: computer) == [saved])
      #expect(try cold.archiveContentProof() == before)
      #expect(try cold.currentReadCursor() == revision)
      #expect(try cold.sqlRead { try $0.rows("SELECT id FROM chat_panel WHERE id=?", [.text(author.uuidString)]).isEmpty })
    }
  }
  @Test func equalPathsHaveIndependentWindowsDraftsAndCommandsAcrossColdRestore() throws {
    try fixture { store, author in
      let computers = [UUID(), UUID()], thread = UUID().uuidString
      let before = try store.archiveContentProof(), revision = try store.currentReadCursor()
      for (index, computer) in computers.enumerated() {
        _ = try store.selectChatComputer(computer, author: author)
        try store.saveChatPanel(.init(threadID: thread, draft: "draft \(index)", sidecarID: computer), author: author)
        let address = NotebookFileAddress(computer: computer, project: "same", root: "/code", path: "same.py")
        var draft = NotebookFileDraft(address: address, text: "source \(index)"); draft.scroll = Double(index + 1) * 240; draft.selection = index
        try store.saveFileDraft(draft)
        var window = NotebookFileWindowState(); window.selected = address; window.isOpen = true; window.sidebar = index == 0; window.terminal = index == 1
        try store.saveFileWindow(window, author: author, computer: computer)
        try store.saveRunCommand("echo \(index)", root: .init(computer: computer, project: address.project, root: address.root, path: ""))
      }
      let cold = NotebookStore(root: store.root)
      for (index, computer) in computers.enumerated() {
        let restored = try cold.selectChatComputer(computer, author: author)
        #expect(restored.panel.draft == "draft \(index)")
        #expect(restored.document?.text == "source \(index)")
        #expect(restored.document?.scroll == Double(index + 1) * 240)
        #expect(restored.window.sidebar == (index == 0))
        #expect(try cold.runCommand(root: .init(computer: computer, project: "same", root: "/code", path: "")) == "echo \(index)")
      }
      #expect(try cold.archiveContentProof() == before); #expect(try cold.currentReadCursor() == revision)
    }
  }
  @Test func uncertainCommandCannotMoveToAnotherMacOrClearItsDraft() throws {
    try fixture { store, author in
      let first = UUID(), second = UUID(), thread = UUID().uuidString
      let input = NotebookChatInput(author: author, action: .send(threadID: thread, text: "same text", context: ""))
      for computer in [first, second] { try store.saveChatPanel(.init(threadID: thread, draft: "same text", sidecarID: computer), author: author) }
      _ = try store.saveChatSubmission(input, to: first)
      _ = try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      _ = try store.advanceChatJob(input.id, from: .attempting, to: .uncertain)
      _ = try store.selectChatComputer(second, author: author)
      #expect(throws: NotebookStorageError.self) { try store.saveChatSubmission(input, to: second) }
      #expect(try store.chatDestination(input.id) == first)
      #expect(try store.chatPanel(author: author, computer: second).draft == "same text")
      #expect(try store.routedChatJobs(author: author, computer: second).isEmpty)
      #expect(try store.routedChatJobs(author: author, computer: first).first?.state == .uncertain)
      try store.saveChatPanel(.init(threadID: thread, draft: "late first", sidecarID: first), author: author)
      #expect(try store.activeChatComputer(author: author) == second, "Late persistence is not a selection")
    }
  }
  @Test func corruptTargetRollsBackSelectionAndAcknowledgementLossCanBeReadBack() throws {
    enum Fault: Error { case lost }
    try fixture { store, author in
      let first = UUID(), second = UUID()
      _ = try store.selectChatComputer(first, author: author)
      try store.commandTransaction(advancesReadRevision: false) {
        try store.currentSQL!.run("INSERT INTO file_window(id,value) VALUES(?,?)", [.text(store.chatScope(author: author, computer: second)), .blob(Data("broken".utf8))])
      }
      #expect(throws: (any Error).self) { try store.selectChatComputer(second, author: author) }
      #expect(try store.activeChatComputer(author: author) == first)
      try store.saveFileWindow(.init(), author: author, computer: second)
      let failing = NotebookStore(root: store.root) { if case .afterCommit = $0 { throw Fault.lost } }
      #expect(throws: Fault.self) { try failing.selectChatComputer(second, author: author) }
      #expect(try store.activeChatComputer(author: author) == second)
      #expect(try store.chatComputerWindow(author: author, computer: second).panel.sidecarID == second)
    }
  }
}
