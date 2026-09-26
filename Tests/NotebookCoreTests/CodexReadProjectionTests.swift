import Foundation
import Testing
import NotebookCore

@Suite("One native reading projection for Mac and iPad")
struct CodexReadProjectionTests {
  @Test func newAttachmentCanRestartRevisionWithoutKeepingOldBusy() {
    let old = UUID(), new = UUID()
    func state(_ epoch: UUID, _ revision: Int, busy: Bool = false) -> CodexConversation {
      .init(threadID: "task", generation: epoch, revision: revision, title: "", ready: true, busy: busy,
        activeTurnID: busy ? "turn" : nil, messages: [], requests: [], acceptedMessages: [:], turnStatuses: [:])
    }
    #expect(!state(old, 1).succeeds(state(old, 100, busy: true)))
    #expect(state(new, 1).succeeds(state(old, 100, busy: true)))
  }
  @Test func overlappingOlderPrefixIsNotAppendedAndHistoryCannotOverwriteLive() {
    func item(_ id: String, text: String? = nil) -> CodexMessage {
      .init(id: id, turnID: "turn", clientID: nil, role: .assistant, text: text ?? id)
    }
    let live = [item("2", text: "new")]
    let merged = CodexTranscript.merging(live, [item("1"), item("2", text: "old"), item("3")], preferIncoming: false)
    #expect(merged.map(\.id) == ["1", "2", "3"])
    #expect(merged[1].text == "new")
    #expect(CodexTranscript.merging(merged, [item("0")], preferIncoming: false, before: "1").map(\.id) == ["0", "1", "2", "3"])
  }
  @Test func refreshRetainsExpandedPageDepthAndRejectsCursorCycles() throws {
    func task(_ id: String) -> CodexTask { .init(id: id, title: id, cwd: "/tmp") }
    var read = CodexReadWindow<CodexTask>()
    try read.append([task("1")], next: "page2")
    #expect(read.needsPage(refreshing: true, loadedPages: 2))
    try read.append([task("1"), task("2")], next: "page3")
    #expect(!read.needsPage(refreshing: true, loadedPages: 2))
    #expect(read.items.map(\.id) == ["1", "2"])
    #expect(throws: NotebookTransportError.invalidAcknowledgement) { try read.append([], next: "page2") }
  }
  @Test func longNativeItemTransfersLosslesslyInBoundedPartsAndRepeatedHeaderKeepsBody() throws {
    let native = CodexMessage(id:"large",turnID:"turn",clientID:nil,role:.assistant,
      text:String(repeating:"Полный ответ 🙂 ",count:20_000),activity:.init(kind:.command,detail:String(repeating:"output\n",count:20_000))).identifyingContent()
    let header = try #require(CodexMessage.transportPage([native],byteBudget:2048).first)
    #expect(header.isTruncated); #expect(header.contentRevision == native.contentRevision)
    let transfer = try CodexMessageTransfer(threadID:"thread",message:native)
    var assembly = CodexMessageAssembly(), complete: CodexMessage?
    repeat {
      let part = try transfer.part(offset:assembly.offset)
      #expect(NotebookChatEnvelope(body:.reply(.message(.part(part)))).isValid(from:UUID()))
      if try assembly.append(part) { complete = try assembly.decode() }
    } while complete == nil
    #expect(complete?.text == native.text); #expect(complete?.activity == native.activity)
    #expect(assembly.digest == native.contentRevision)
    let full = try #require(complete).identifyingContent()
    #expect(CodexTranscript.merging([full],[header],preferIncoming:true) == [full])
    var mixed = CodexMessageAssembly(); _ = try mixed.append(transfer.part(offset:0))
    let other = try CodexMessageTransfer(threadID:"thread",message:native)
    #expect(throws:NotebookTransportError.invalidAcknowledgement) { try mixed.append(other.part(offset:mixed.offset)) }
    #expect(throws:NotebookTransportError.invalidAcknowledgement) { try mixed.append(transfer.part(offset:0)) }
  }

}
