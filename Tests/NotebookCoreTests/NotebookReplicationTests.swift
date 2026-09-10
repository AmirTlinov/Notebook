import Foundation
import Testing
@testable import NotebookCore

@Suite("SQL peer transactions")
struct NotebookReplicationTests {
  private func transfer(_ change: NotebookDurableChange, from source: NotebookStore, to destination: NotebookStore, peer: UUID) throws -> UInt64 {
    while true {
      let hashes = try destination.missingBlobHashes(for: change)
      if hashes.isEmpty { break }
      for hash in hashes {
        let size = try source.blobSize(hash: hash)
        var data = Data()
        while Int64(data.count) < size { data += try source.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576) }
        try destination.stageBlob(data: data, expectedHash: hash)
      }
    }
    return try destination.applyRemoteChange(change, peerID: peer)
  }

  @Test func anOldEchoCannotRegressTheFrontierOfRetainedPortalNodes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b")), actor = UUID(), peer = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try a.loadIndex(), board = try a.loadBoard(items: index.items)
    let createdChild = index.createBoard(title: "Child", actor: actor)
    let child = try #require(createdChild)
    let createdBoard = board.createBoard(child.id, in: header.rootBoardID, near: .zero, actor: actor)
    #expect(createdBoard)
    try a.saveBoardWorkspaceBundle(index: index, board: board, boardID: child.id)
    let createdNotebook = index.createNotebook(title: "Inside", actor: actor, pageSize: .init(width: 834, height: 1194))
    let notebook = try #require(createdNotebook)
    let addedNotebook = board.addItem(notebook.item.id, to: child.id, near: .zero, actor: actor)
    #expect(addedNotebook)
    try a.saveWorkspaceBundle(index: index, page: notebook.page, board: board)
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    for change in try a.changeJournal(after: 0) { _ = try transfer(change, from: a, to: b, peer: actor) }
    var remoteIndex = try b.loadIndex(), remoteBoard = try b.loadBoard(items: remoteIndex.items)
    let createdDocument = remoteIndex.createDocument(title: "Remote", actor: peer)
    let document = try #require(createdDocument)
    let addedDocument = remoteBoard.addItem(document.id, to: header.rootBoardID, near: .zero, actor: peer)
    #expect(addedDocument)
    try b.saveDocumentWorkspaceBundle(index: remoteIndex, document: .init(id: document.id, actor: peer, blocks: [.markdown(id: "body", source: "Delivered")]), state: .init(id: document.id, actor: peer), board: remoteBoard)
    let center = WorldPoint(x: 370, y: -240)
    #expect(try a.moveWorkspaceItem(itemID: notebook.item.id, in: child.id, to: center, actor: actor))
    let local = try a.workspaceHeader(), node = try #require(try a.readBoardNodeHeader(child.id))
    let before = BoardHierarchy(rootBoardID: header.rootBoardID, boards: [node], stamp: try #require(local.boardStamp))
    var after = before
    let camera = BoardPortalCamera(center: center, scale: 0.51)
    let cameraUpdated = after.updatePortalCamera(camera, for: child.id, actor: actor)
    #expect(cameraUpdated)
    _ = try a.saveBoardEdits(before: before, after: after)
    for change in try b.changeJournal(after: 0) { _ = try transfer(change, from: b, to: a, peer: peer) }
    let result = try a.loadBoard(items: a.loadIndex().items)
    #expect(result.portalCamera(child.id) == camera)
    #expect(result.board(child.id)?.freeItems.first(where: { $0.itemID == notebook.item.id })?.center == center)
    #expect(try a.readItemHeader(document.id)?.kind == .document)
    #expect(try a.loadDocument(document.id).blocks.first?.source == "Delivered")
    let applied = try a.peerCursor(peerID: peer, direction: .incoming)
    #expect(try applied == b.currentChangeCursor())
  }

  @Test func manifestCannotRetargetAnExistingWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b"))
    let first = try a.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let second = try b.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    #expect(first.rootBoardID == second.rootBoardID)
    #expect(first.workspaceID != second.workspaceID)
    #expect(throws: NotebookStorageError.self) { try transfer(a.changeJournal(after: 0)[0], from: a, to: b, peer: UUID()) }
    #expect(try b.workspaceHeader().workspaceID == second.workspaceID)
    #expect(try b.currentChangeCursor() == second.cursor)
    #expect(throws: NotebookStorageError.self) { try b.prepareEmptyWorkspace(workspaceID: first.workspaceID) }
  }

  @Test func twoCopiesConvergeAndEachPeerAcknowledgesTheSameCommittedTransaction() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b"))
    let actorA = UUID(), actorB = UUID(), peerA = UUID(), peerB = UUID()
    let header = try a.initializeWorkspace(actor: actorA, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let initial = try a.changeJournal(after: 0)[0]
    #expect(try transfer(initial, from: a, to: b, peer: peerA) == 1)
    let originalB = try b.changeJournal(after: 0)[0]
    #expect(try transfer(originalB, from: b, to: a, peer: peerB) == 1)
    let index = try a.loadIndex(), item = index.items[0]
    let aBoard = try a.loadBoard(items: index.items)
    let rename = CollaborationAction(summary: "Rename one owner", expected: [
      .init(target: .init(kind: .workspace, id: header.rootBoardID), revision: index.stamp.revision),
      .init(target: .init(kind: .board, id: header.rootBoardID), revision: aBoard.board(header.rootBoardID)!.stamp.revision)],
      operations: [.init(kind: .renameItem, target: .init(kind: .board, id: header.rootBoardID), id: item.id.uuidString, values: ["title": .string("Independent title")])])
    _ = try a.applyCollaborationAction(rename, actor: actorA)
    let renamed = try a.loadIndex()
    let bBoard = try b.loadBoard(items: index.items)
    var moved = bBoard
    let movedOK = moved.moveItem(item.id, in: header.rootBoardID, to: .init(x: -5000, y: 120), actor: actorB)
    #expect(movedOK)
    _ = try b.saveBoardEdits(before: bBoard, after: moved)
    let title = try a.changeJournal(after: initial.sequence)[0], placement = try b.changeJournal(after: originalB.sequence)[0]
    #expect(try transfer(title, from: a, to: b, peer: peerA) == 2)
    #expect(try transfer(placement, from: b, to: a, peer: peerB) == 2)
    #expect(try JSONValue.encode(a.loadIndex()) == JSONValue.encode(b.loadIndex()))
    #expect(try a.loadBoard(items: renamed.items) == b.loadBoard(items: renamed.items))
    #expect(try a.workspaceHeader().boardRevision == b.workspaceHeader().boardRevision)
    let aCursor = try a.currentChangeCursor()
    #expect(try a.applyRemoteChange(placement, peerID: peerB) == 2)
    #expect(try a.currentChangeCursor() == aCursor)
    let relayed = NotebookDurableChange(sequence: 1, transactionID: placement.transactionID, manifestHash: placement.manifestHash, byteCount: placement.byteCount)
    let anotherPeer = UUID()
    #expect(try a.applyRemoteChange(relayed, peerID: anotherPeer) == 1)
    #expect(try a.peerCursor(peerID: anotherPeer, direction: .incoming) == 1)
  }

  @Test func aNewHumanDocumentPublishesItsBirthVersionsWithTheCatalog() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b")), actor = UUID(), peer = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    _ = try transfer(a.changeJournal(after: 0)[0], from: a, to: b, peer: peer)
    var index = try a.loadIndex(), tree = try a.loadBoard(items: index.items)
    let id = UUID(), document = DocumentDocument(id: id, actor: actor, blocks: [.markdown(id: "body", source: "Human original")])
    _ = index.createDocument(title: "Document", actor: actor, documentID: id)
    _ = tree.addItem(id, to: header.rootBoardID, near: .zero, actor: actor)
    try a.saveDocumentWorkspaceBundle(index: index, document: document, state: .init(id: id, actor: actor), board: tree)
    _ = try transfer(a.changeJournal(after: header.cursor)[0], from: a, to: b, peer: peer)
    let local = try a.loadDocument(id), remote = try b.loadDocument(id)
    #expect(local == remote)
    #expect(remote.blocks == document.blocks)
    #expect(remote.collaboration?.fields.isEmpty == false)
    #expect(remote.collaboration?.fields.values.allSatisfy { $0.human && $0.stamp.actor == actor } == true)
  }

  @Test func historicalRequestAndResponseReplicateWithoutReopeningExecution() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b")), human = UUID(), mac = UUID(), peerA = UUID(), peerB = UUID()
    let header = try a.initializeWorkspace(actor: human, pageSize: .init(width: 834, height: 1194))
    let target = CollaborationTarget(kind: .page, id: try #require(a.loadIndex().selectedPageID))
    let files = try a.referenceSourceFiles(target: target)
    let reference = CollaborationReference(target: target, revision: try NotebookStore.referenceRevision(target: target, files: files))
    let context = try a.appendContext(references: [reference], author: .human, actor: human, text: "Selection")
    let id = UUID(), source = try AgentPinnedSource.capture(requestID: id, reference: reference, files: files)
    let request = AgentRequest(id: id, contextID: context.id, questionEntryID: context.entry.id,
      grant: try .init(mode: .question, references: [reference]), authorDeviceID: human, sourceIDs: [source.id])
    try a.publishRecords(writes: [a.agentRequestFile(id): .encode(request), a.agentSourceFile(id, source.id): .encode(source)])
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    for change in try a.changeJournal(after: 0) { _ = try transfer(change, from: a, to: b, peer: peerA) }
    #expect(try b.agentRequest(id)?.request == request)
    let execution = AgentExecution(requestID: id, executionID: UUID(), status: .completed,
      stamp: .init(counter: 2, actor: mac), responseSequence: 1, responseBytes: 6, receiptIDs: [])
    let chunk = AgentResponseChunk(requestID: id, executionID: execution.executionID, sequence: 1, text: "Answer")
    try b.publishRecords(writes: [b.agentExecutionFile(id): .encode(execution), b.agentChunkFile(id, 1): .encode(chunk)])
    for change in try b.changeJournal(after: 0) { _ = try transfer(change, from: b, to: a, peer: peerB) }
    let result = try #require(try a.agentRequest(id))
    #expect(result.status == .completed && result.responseText == "Answer")
    let before = try a.currentChangeCursor(), received = try a.peerCursor(peerID: peerB, direction: .incoming)
    var stale = try #require(result.execution)
    stale.status = .running; stale.answerEntryID = nil
    stale.stamp = .init(counter: stale.stamp.counter + 1, actor: mac)
    try b.publishRecords(writes: [b.agentExecutionFile(id): .encode(stale)])
    let invalid = try #require(b.changeJournal(after: received).first)
    #expect(throws: NotebookStorageError.self) { try transfer(invalid, from: b, to: a, peer: peerB) }
    #expect(try a.currentChangeCursor() == before)
    #expect(try a.peerCursor(peerID: peerB, direction: .incoming) == received)
    #expect(try a.agentRequest(id)?.status == .completed)
  }
}
