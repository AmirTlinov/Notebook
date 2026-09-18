import Foundation
import Testing
@testable import NotebookCore

@Suite("Retired document source/state keep one hidden native owner", .serialized)
struct NotebookRetiredDocumentSourceTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retired-document-\(UUID())")
    let a: NotebookStore, b: NotebookStore
    let human = UUID(), agent = UUID(), peerA = UUID(), peerB = UUID()
    let id: UUID
    init() throws {
      a = NotebookStore(root: root.appendingPathComponent("a")); b = NotebookStore(root: root.appendingPathComponent("b"))
      let header = try a.initializeWorkspace(actor: human, pageSize: .init(width: 834, height: 1194))
      var index = try a.loadIndex(), board = try a.loadBoard(items: a.loadIndex().items)
      let creation = index.createDocument(title: "Retained document", actor: human)
      let item = try #require(creation); id = item.id
      let placed = board.addItem(id, to: header.rootBoardID, near: .zero, actor: human)
      #expect(placed)
      try a.saveDocumentWorkspaceBundle(index: index,
        document: .init(id: id, actor: human, blocks: [.markdown(id: "body", source: "Before retirement")]),
        state: .init(id: id, actor: human), board: board)
      try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
      try send(a, b, peerA)
      try send(b, a, peerB)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func stage(_ change: NotebookDurableChange, _ source: NotebookStore, _ destination: NotebookStore) throws {
      for _ in 0..<64 {
        let missing = try destination.missingBlobHashes(for: change)
        if missing.isEmpty { return }
        for hash in missing {
          let size = try source.blobSize(hash: hash); var bytes = Data()
          while Int64(bytes.count) < size { bytes += try source.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576) }
          try destination.stageBlob(data: bytes, expectedHash: hash)
        }
      }
      throw NotebookStorageError.invalidTransaction("fixture document dependencies")
    }
    func send(_ source: NotebookStore, _ destination: NotebookStore, _ peer: UUID) throws {
      for change in try source.changeJournal(after: destination.peerCursor(peerID: peer, direction: .incoming)) {
        try stage(change, source, destination)
        _ = try destination.applyRemoteChange(change, peerID: peer)
      }
    }
    func retire() throws {
      try a.commandTransaction { try a.deleteWorkspaceItemContent(itemID: id, actor: agent, human: false) }
    }
    func packet(_ rows: [NotebookStoredFragment], sequence: UInt64) throws -> NotebookDurableChange {
      try a.commandTransaction {
        let mutations = try rows.map { row in NotebookRecordMutation(address: row.address,
          blobHash: try a.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(row))) }
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: try a.workspaceHeader().workspaceID, records: mutations)
        let data = try NotebookStore.storageEncoder.encode(manifest), hash = try a.currentSQL!.putBlob(data)
        return .init(sequence: sequence, transactionID: manifest.transactionID, manifestHash: hash, byteCount: data.count)
      }
    }
  }

  @Test func independentlyDeliveredHumanSourceAndStateRemainHiddenAfterDeletion() throws {
    let f = try Fixture(), cachedSource = try f.a.loadDocument(f.id), cachedState = try f.a.loadDocumentState(f.id)
    try f.retire()
    var source = try f.b.loadDocument(f.id), state = try f.b.loadDocumentState(f.id)
    let changed = source.replaceBlockSource(id: "body", source: "LateHumanDocumentSource", actor: f.human)
    let committed = state.commit(blockID: "body", value: .number(42), actor: f.human)
    #expect(changed && committed)
    _ = try f.b.saveMergedDocument(source)
    try f.b.saveDocumentState(state)
    let cursor = try f.b.currentChangeCursor()
    try f.send(f.b, f.a, f.peerB)
    #expect(try f.a.peerCursor(peerID: f.peerB, direction: .incoming) == cursor)
    for store in [f.a, NotebookStore(root: f.a.root)] {
      #expect(try store.readItemHeader(f.id) == nil)
      #expect(try store.documentSourceOwnerID(f.id) == f.id)
      #expect(try store.storedMember(file: documentFile(f.id), collection: "blocks", id: "body")?.decode(DocumentBlock.self).source == "LateHumanDocumentSource")
      #expect(try store.storedMember(file: stateFile(f.id), collection: "records", id: "body")?.decode(DocumentStateRecord.self).value == .number(42))
      #expect(throws: (any Error).self) { _ = try store.loadDocument(f.id) }
      #expect(throws: (any Error).self) { _ = try store.loadDocumentState(f.id) }
      #expect(throws: (any Error).self) { try store.saveDocument(cachedSource) }
      #expect(throws: (any Error).self) { try store.saveDocumentState(cachedState) }
      #expect(throws: (any Error).self) { _ = try store.readContentHeader(target: .init(kind: .document, id: f.id)) }
      #expect(try store.search("LateHumanDocumentSource").total == 0)
    }
  }

  @Test func aFreshSnapshotAdmitsBothRetiredOwnersWithoutRestoringVisibility() throws {
    let f = try Fixture(); try f.retire()
    let fresh = NotebookStore(root: f.root.appendingPathComponent("snapshot")), peer = UUID()
    try fresh.prepareEmptyWorkspace(workspaceID: f.a.workspaceHeader().workspaceID)
    let snapshot = try f.a.commandTransaction(advancesReadRevision: false) {
      try f.a.cloudSnapshot(source: .init(deviceID: peer, generation: peer))
    }
    try f.stage(snapshot.change, f.a, fresh); _ = try fresh.applyDelivery(snapshot)
    for store in [fresh, NotebookStore(root: fresh.root)] {
      #expect(try store.readItemHeader(f.id) == nil)
      #expect(try store.documentSourceOwnerID(f.id) == f.id)
      try store.commandTransaction { _ = try store.requireRetiredDocumentBaseline(itemID: f.id) }
      #expect(throws: (any Error).self) { _ = try store.loadDocument(f.id) }
      #expect(throws: (any Error).self) { _ = try store.loadDocumentState(f.id) }
    }
  }

  @Test(arguments: [false, true])
  func causalMetadataOrOneTypedRootCannotAllocateAnOrphanPair(includeSourceWithMetadata: Bool) throws {
    let f = try Fixture(), orphanID = UUID(), peer = UUID(), stamp = VersionStamp(counter: 1, actor: UUID())
    var metadata = [try #require(try f.a.storedFragments(address: "workspace.json#", descendants: false).first)]
    for field in ["exists", "kind"] {
      let key = fieldKey(["items", orphanID.uuidString.lowercased(), field])
      metadata.append(.init(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), file: "workspace.json",
        parent: "workspace.json#", collection: "collaboration/fields", member: key, position: 0,
        value: try .encode(ContentFieldVersion(stamp: stamp, human: true)), collections: []))
    }
    let source = try NotebookRecordCodec.encode(.encode(DocumentDocument(id: orphanID, actor: f.human)), file: documentFile(orphanID))
    let state = try NotebookRecordCodec.encode(.encode(DocumentStateJournal(id: orphanID, actor: f.human)), file: stateFile(orphanID))
    if includeSourceWithMetadata { metadata += source }
    let first = try f.packet(metadata, sequence: 1)
    _ = try f.a.applyRemoteChange(first, peerID: peer)
    let second = try f.packet(source + state, sequence: 2)
    _ = try f.a.applyRemoteChange(second, peerID: peer)
    #expect(try f.a.peerCursor(peerID: peer, direction: .incoming) == 2)
    #expect(try f.a.documentSourceOwnerID(orphanID) == nil)
    #expect(try !f.a.hasStoredValue(documentFile(orphanID)))
    #expect(try !f.a.hasStoredValue(stateFile(orphanID)))
  }
  @Test(arguments: [false, true])
  func retiredPageAndDocumentCannotBeExpandedThroughElementReferences(document: Bool) throws {
    let f = try Fixture(), target: CollaborationTarget, itemID: UUID, element: String
    if document {
      target = .init(kind: .document, id: f.id); itemID = f.id; element = "body"
    } else {
      let index = try f.a.loadIndex(), notebook = try #require(index.items.first { $0.kind == .notebook })
      let pageID = try #require(notebook.pageIDs.first)
      var page = try f.a.loadPage(pageID)
      let edited = page.replaceElements([.init(id: "label", kind: .markdown,
        frame: .init(x: 0, y: 0, width: 100, height: 100), source: "Hidden page reference", html: "<p>Hidden page reference</p>")], actor: f.human)
      #expect(edited); _ = try f.a.savePage(page)
      target = .init(kind: .page, id: pageID); itemID = notebook.id; element = "label"
    }
    let whole = CollaborationReference(target: target, revision: try f.a.referenceRevision(target: target))
    let part = CollaborationReference(target: target, elementID: element,
      revision: try f.a.referenceRevision(target: target, elementID: element))
    #expect(try f.a.referenceStatus(whole).status == .current)
    #expect(try f.a.referenceStatus(part).status == .current)
    try f.a.commandTransaction { try f.a.deleteWorkspaceItemContent(itemID: itemID, actor: f.agent, human: false) }
    let cursor = try f.a.currentChangeCursor()
    for store in [f.a, NotebookStore(root: f.a.root)] {
      #expect(throws: (any Error).self) { _ = try store.referenceSourceFiles(target: target, elementID: element) }
      #expect(throws: (any Error).self) { _ = try store.referenceSourceFiles(target: target) }
      #expect(throws: (any Error).self) { _ = try store.targetContentRevision(target: target) }
      #expect(try store.referenceStatus(whole).status == .targetMissing)
      #expect(try store.referenceStatus(part).status == .targetMissing)
      #expect(throws: (any Error).self) {
        _ = try store.observeContent(scope: .init(target: target, ids: [element], fields: [.content], expand: [.incoming, .outgoing]))
      }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

}
