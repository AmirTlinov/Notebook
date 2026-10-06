import Foundation
import Testing
@testable import NotebookCore

@Suite("Material read cuts survive independent delivery bookkeeping")
struct NotebookReadRevisionTests {
  @Test func stagingDiscoveryAcknowledgementAndEchoKeepTheMaterialCursor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = NotebookStore(root: root.appendingPathComponent("source"))
    let replica = NotebookStore(root: root.appendingPathComponent("replica")), actor = UUID()
    let header = try source.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try replica.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let initial = try #require(source.changeJournal(after: 0).first)
    let delivery = NotebookReplicationDelivery(source: .init(deviceID: actor, generation: actor), change: initial)
    let stagingCursor = try replica.currentReadCursor()
    var request = NotebookCommand(command: .read)
    request.queries = [.init(kind: .presence)]; request.expectedCursor = String(stagingCursor)
    let pinned = try NotebookCommandDispatcher(store: replica).handle(request)
    var usedFile = false, staged = 0
    while true {
      let hashes = try replica.prepareIncomingBlobs(delivery, staging: [])
      #expect(try replica.missingBlobHashes(for: initial) == hashes)
      if hashes.isEmpty { break }
      for hash in hashes {
        let count = try source.blobSize(hash: hash)
        let data = try source.readBlobChunk(hash: hash, offset: 0, maxBytes: Int(count))
        if !usedFile {
          let file = root.appendingPathComponent("staged-blob")
          try data.write(to: file)
          try replica.stageBlobs([.file(hash: hash, url: file, byteCount: count)])
          usedFile = true
        } else { try replica.stageBlob(data: data, expectedHash: hash) }
        staged += 1
      }
      #expect(try replica.currentReadCursor() == stagingCursor)
      #expect(try NotebookCommandDispatcher(store: replica).handle(request) == pinned)
    }
    #expect(staged > 1 && usedFile)
    _ = try replica.applyDelivery(delivery)
    #expect(try replica.currentReadCursor() == stagingCursor + 1)
    #expect(throws: CollaborationError.self) { _ = try NotebookCommandDispatcher(store: replica).handle(request) }
    request.expectedCursor = String(try replica.currentReadCursor())
    request.queries = [.init(kind: .workspaceHeader)]
    let material = try NotebookCommandDispatcher(store: replica).handle(request)
    let cursor = try replica.currentReadCursor()
    try replica.acknowledgePeer(peerID: UUID(), through: replica.currentChangeCursor())
    _ = try replica.applyDelivery(delivery)
    _ = try replica.applyRemoteChange(initial, peerID: UUID())
    #expect(try replica.currentReadCursor() == cursor)
    #expect(try NotebookCommandDispatcher(store: replica).handle(request) == material)

    let bytes = Data("<p>Unpublished program</p>".utf8), hash = NotebookProgramPackage.hash(bytes)
    try replica.stageBlobs([.bytes(hash: hash, data: bytes)])
    let package = NotebookProgramPackage(html: "index.html", files: [
      .init(path: "index.html", mimeType: "text/html", byteCount: Int64(bytes.count),
        parts: [.init(sha256: hash, byteCount: bytes.count)])])
    _ = try replica.stageProgramPackage(package)
    #expect(try replica.currentReadCursor() == cursor)
    #expect(try NotebookCommandDispatcher(store: replica).handle(request) == material)
    #expect(try NotebookStore(root: replica.root).currentReadCursor() == cursor)
  }

  @Test func aNestedContentOwnerCannotHideInsideABookkeepingTransaction() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var page = try store.loadPage(#require(store.loadIndex().selectedPageID))
    page.replaceDrawing(pageDrawingFixture(Data([2, 3, 5])), actor: actor)
    let read = try store.currentReadCursor(), delivery = try store.currentChangeCursor()
    try store.commandTransaction(advancesReadRevision: false) {
      try store.savePage(page)
      try store.acknowledgePeer(peerID: UUID(), through: delivery)
    }
    #expect(try store.currentReadCursor() == read + 1)
    #expect(try store.currentChangeCursor() == delivery + 1)
    #expect(try NotebookStore(root: root).loadPage(page.id) == page)
  }

  @Test func localRunAdmissionCancellationAndOutputKeepTheMaterialCut() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let cursor = try store.currentReadCursor(), delivery = try store.currentChangeCursor()
    var request = NotebookCommand(command: .read)
    request.queries = [.init(kind: .workspaceHeader)]; request.expectedCursor = String(cursor)
    let admitted = try NotebookReadCommand(request), reader = NotebookReadSession(store: store)
    let original = try reader.observe { try $0.handle(admitted) }
    let runID = UUID()
    _ = try store.admitScriptRun(.init(op: .start, runID: runID, code: "local lifecycle"))
    _ = try store.setScriptRunState(runID, state: .running)
    _ = try store.appendScriptEvent(runID, kind: "value", value: .string("saved local output"))
    _ = try store.requestScriptRunCancellation(runID)
    _ = try store.setScriptRunState(runID, state: .completed, result: .number(42))
    #expect(try store.currentReadCursor() == cursor && store.currentChangeCursor() == delivery)
    #expect(try reader.observe { try $0.handle(admitted) } == original)
    let saved = try reader.observe { try $0.scriptRunPage(runID, after: 0) }
    #expect(saved["status"] == .string("cancelled"))
    #expect(saved["events"]?.array.first?["value"] == .string("saved local output"))
    let cold = NotebookStore(root: root)
    #expect(try cold.currentReadCursor() == cursor && cold.currentChangeCursor() == delivery)
    #expect(try cold.scriptRun(runID)?.state == .cancelled)
  }
}
