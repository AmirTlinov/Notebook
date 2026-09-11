import Foundation
import Testing
@testable import NotebookCore

@Suite("Project files retain versions and drafts independently of the board")
struct NotebookProjectFileTests {
  private func address(_ computer: UUID = UUID(), path: String = "main.py") -> NotebookFileAddress { .init(computer: computer, project: "project", root: "/tmp/project", path: path) }
  @Test func addressNamesTheComputerAndRejectsTraversal() {
    let a = address()
    #expect(a.isValid); #expect(a.id != address().id)
    #expect(a.id == address(a.computer).id)
    for path in ["../secret", "/etc/passwd", "a/../b", "a//b", "a/", "a/./b", "a\0"] { #expect(!address(path: path).isValid) }
  }
  @Test func disjointEditsMergeAndRealConflictsKeepBoth() {
    #expect(NotebookFileMerge.combine(base: "a\nb\nc\nd", local: "A\nb\nc\nd", remote: "a\nb\nc\nD") == "A\nb\nc\nD")
    #expect(NotebookFileMerge.combine(base: "a\nb\nc", local: "a\nB\nc", remote: "a\nother\nc") == nil)
    #expect(NotebookFileMerge.combine(base: "a\nb\nc\nd", local: "a\ninsert\nb\nc\nd", remote: "a\nb\nc\nD") == "a\ninsert\nb\nc\nD")
    #expect(NotebookFileMerge.combine(base: "a\nb\nc\nd", local: "a\nc\nd", remote: "a\nb\nc\nD") == "a\nc\nD")
    var draft = NotebookFileDraft(address: address(), text: "a\nb")
    draft.text = "a\nlocal"; draft.receive("a\nremote")
    #expect(draft.base == "a\nb" && draft.text == "a\nlocal" && draft.other == "a\nremote")
  }
  @Test func manySeparatedChangesMergeWithoutQuadraticArchiveWork() {
    let lines = (0..<400).map { "line \($0)" }
    for index in stride(from: 0, to: 200, by: 7) {
      var local = lines, remote = lines, merged = lines
      local[index] = "human"; remote[index + 200] = "agent"
      merged[index] = "human"; merged[index + 200] = "agent"
      #expect(NotebookFileMerge.combine(base: lines.joined(separator: "\n"), local: local.joined(separator: "\n"), remote: remote.joined(separator: "\n")) == merged.joined(separator: "\n"))
    }
  }
  @Test func chunksAreBoundToAddressAuthorAndDigestAndReplayWithoutAnotherWrite() throws {
    try NotebookChatStoreTests().fixture { store, author in
      let address = address(), data = Data(String(repeating: "let x = 1\n", count: 18_000).utf8)
      let version = try store.cacheFileVersion(data, address: address)
      let first = try store.filePart(version, address: address, offset: 0)
      #expect(first.data.count == NotebookFileVersion.chunkBytes)
      #expect(throws: (any Error).self) { try store.filePart(version, address: self.address(), offset: 0) }
      let edit = NotebookFileEdit(address: address, base: String(decoding: data, as: UTF8.self), text: "print(4)\n")
      let payload = try JSONEncoder().encode(edit), id = UUID(), hash = NotebookFileVersion.hash(payload)
      var offset = 0
      while offset < payload.count {
        let end = min(payload.count, offset + NotebookFileVersion.chunkBytes)
        let chunk = NotebookFileUpload(id: id, digest: hash, total: payload.count, offset: offset, data: payload.subdata(in: offset..<end))
        #expect(try store.stageFileUpload(chunk, author: author) == end)
        #expect(try store.stageFileUpload(chunk, author: author) == end)
        #expect(throws: (any Error).self) { try store.stageFileUpload(chunk, author: UUID()) }
        offset = end
      }
      #expect(try store.stagedFileEdit(id, author: author) == edit)
    }
  }
  @Test func draftSubmissionAndReceiptDoNotWriteCameraOrSharedContent() throws {
    try NotebookChatStoreTests().fixture { store, author in
      try store.savePresence(.init(mode: .board, camera: .init(center: .init(x: 321, y: -456), scale: 0.43), viewport: .init(x: 834, y: 1194)))
      let presence = try store.loadPresence(), before = try store.archiveContentProof()
      var draft = NotebookFileDraft(address: address(), text: "base")
      draft.text = "draft"; draft.scroll = 750; draft.selection = 2; draft.pending = UUID(); draft.submitted = draft.text
      let input = NotebookChatInput(id: draft.pending!, author: author, action: .saveFile(draft.address))
      _ = try store.saveFileSubmission(input, draft: draft)
      var window = NotebookFileWindowState(); window.selected = draft.address; window.isOpen = true; window.sidebar = true
      try store.saveFileWindow(window, author: author)
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.fileDraft(draft.address) == draft)
      #expect(try reopened.fileWindow(author: author) == window)
      #expect(try reopened.chatJob(input.id)?.input == input)
      #expect(try reopened.loadPresence() == presence)
      #expect(try reopened.archiveContentProof() == before)
      #expect(input.isValid)
    }
  }
  @Test func maximumTextFitsTheTransferWithoutEscapingDependentLimits() throws {
    let text = String(repeating: "\t", count: NotebookFileVersion.maximumBytes)
    let value = NotebookFileEdit(address: address(), base: text, text: text)
    let bytes = try JSONEncoder().encode(value)
    #expect(bytes.count <= 6 * 1024 * 1024)
    #expect(try JSONDecoder().decode(NotebookFileEdit.self, from: bytes) == value)
  }
  @Test func acceptedSaveMergesTypingThatContinuedWhileMacWasWriting() {
    var draft = NotebookFileDraft(address: address(), text: "a\nb\nc")
    draft.text = "A\nb\nC"
    draft.receive("A\nB\nc", submitted: "A\nb\nc")
    #expect(draft.text == "A\nB\nC" && draft.base == "A\nB\nc" && draft.other == nil)
  }
}
