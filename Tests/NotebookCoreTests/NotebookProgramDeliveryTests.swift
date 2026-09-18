import Foundation
import Testing
@testable import NotebookCore

@Suite("Program publications retain a complete immutable dependency closure", .serialized)
struct NotebookProgramDeliveryTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("program-delivery-\(UUID())")
    let a: NotebookStore, b: NotebookStore
    let actor = UUID(), peerID = UUID()
    let pageID: UUID, boardID: UUID, workspaceID: UUID
    init() throws {
      a = NotebookStore(root: root.appendingPathComponent("a")); b = NotebookStore(root: root.appendingPathComponent("b"))
      let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      workspaceID = header.workspaceID; boardID = header.rootBoardID
      pageID = try #require(a.loadIndex().selectedPageID)
      try b.prepareEmptyWorkspace(workspaceID: workspaceID)
      try sync()
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var page: CollaborationTarget { .init(kind: .page, id: pageID) }
    func package(_ tag: String, large: Bool = false) throws -> (String, NotebookProgramPackage) {
      let bytes = Data(("export const value='" + tag + "';").utf8)
      var files: [NotebookProgramPackage.File] = []
      if large {
        let a = Data(repeating: 29, count: NotebookProgramPackage.partBytes), b = Data(repeating: 31, count: 73)
        for data in [a,b] { try self.a.stageBlob(data: data, expectedHash: NotebookProgramPackage.hash(data)) }
        files.append(.init(path: "data.bin", mimeType: "application/octet-stream", byteCount: Int64(a.count+b.count),
          parts: [a,b].map { .init(sha256: NotebookProgramPackage.hash($0), byteCount: $0.count) }))
      }
      try a.stageBlob(data: bytes, expectedHash: NotebookProgramPackage.hash(bytes))
      files.append(.init(path: "main.js", mimeType: "text/javascript", byteCount: Int64(bytes.count),
        parts: [.init(sha256: NotebookProgramPackage.hash(bytes), byteCount: bytes.count)]))
      let p = NotebookProgramPackage(javaScript: "main.js", files: files)
      return (try a.stageProgramPackage(p), p)
    }
    @discardableResult func publish(_ hash: String, insert: Bool = true) throws -> CollaborationReceipt {
      var values: [String: JSONValue] = ["programPackage": .string(hash)]
      if insert { values.merge(["kind": .string("web"), "source": .string(""), "html": .string(""),
        "frame": try .encode(PageRect(x: 10, y: 10, width: 320, height: 320))]) { _,v in v } }
      return try a.applyCollaborationAction(.init(summary: "Program source", expected: [.init(target: page, revision: a.targetContentRevision(target: page))],
        operations: [.init(kind: insert ? .insertElement : .updateElement, target: page, id: "program", values: values)]), actor: actor)
    }
    func copy(_ hash: String, to store: NotebookStore? = nil) throws {
      var data = Data(); let size = try a.blobSize(hash: hash)
      while Int64(data.count) < size { data.append(try a.readBlobChunk(hash: hash, offset: Int64(data.count), maxBytes: 1_048_576)) }
      try (store ?? b).stageBlob(data: data, expectedHash: hash)
    }
    func stage(_ change: NotebookDurableChange, excluding: String? = nil, to store: NotebookStore? = nil) throws {
      let target = store ?? b
      for _ in 0..<100 {
        let hashes = try target.missingBlobHashes(for: change).filter { $0 != excluding }
        if hashes.isEmpty { return }
        for hash in hashes { try copy(hash, to: target) }
      }
      Issue.record("Dependency discovery did not terminate")
    }
    func sync() throws {
      for change in try a.changeJournal(after: b.peerCursor(peerID: peerID, direction: .incoming)) {
        try stage(change); _ = try b.applyRemoteChange(change, peerID: peerID)
      }
    }
  }

  @Test func publicationRejectsMissingBytesAndAmbiguousInlineSourcesWithoutAChange() throws {
    let f = try Fixture(), cursor = try f.a.currentChangeCursor()
    #expect(throws: (any Error).self) { try f.publish(String(repeating: "a", count: 64)) }
    #expect(try f.a.currentChangeCursor() == cursor)
    #expect(try f.a.loadPage(f.pageID).elements.isEmpty)
    let (hash, _) = try f.package("one")
    try f.publish(hash)
    let element = try #require(f.a.loadPage(f.pageID).elements.first)
    #expect(element.updating(state: .number(4)).programPackage == hash)
    #expect(element.updating(frame: .init(x: 0, y: 0, width: 100, height: 100)).programPackage == hash)
    let before = try f.a.currentChangeCursor()
    #expect(throws: (any Error).self) {
      try f.a.applyCollaborationAction(.init(summary: "Two sources", expected: [.init(target: f.page, revision: f.a.targetContentRevision(target: f.page))],
        operations: [.init(kind: .updateElement, target: f.page, id: "program", values: ["html": .string("<p>conflict</p>")])]), actor: f.actor)
    }
    #expect(try f.a.currentChangeCursor() == before)
  }

  @Test func withheldLastPartCannotPublishOrAdvanceCursorThenColdReplicaReadsAcrossParts() throws {
    let f = try Fixture(), (hash, package) = try f.package("large", large: true)
    let before = try f.b.peerCursor(peerID: f.peerID, direction: .incoming)
    try f.publish(hash)
    let change = try #require(f.a.changeJournal(after: before).last), missing = package.files[0].parts[1].sha256
    try f.stage(change, excluding: missing)
    #expect(try f.b.missingBlobHashes(for: change) == [missing])
    #expect(throws: NotebookStorageError.self) { try f.b.applyRemoteChange(change, peerID: f.peerID) }
    #expect(try f.b.peerCursor(peerID: f.peerID, direction: .incoming) == before)
    #expect(try f.b.loadPage(f.pageID).elements.isEmpty)
    try f.copy(missing); _ = try f.b.applyRemoteChange(change, peerID: f.peerID)
    _ = try f.b.applyRemoteChange(change, peerID: f.peerID)
    let cold = NotebookStore(root: f.root.appendingPathComponent("b"))
    #expect(try cold.loadPage(f.pageID).elements.first?.programPackage == hash)
    let restored = try cold.readProgramPackage(hash)
    #expect(try cold.readProgramFile(restored.files[0], offset: Int64(NotebookProgramPackage.partBytes - 2), maxBytes: 4) == Data([29,29,31,31]))
    // The discovery index cannot conceal a subsequently missing dependency.
    try cold.commandTransaction { try cold.currentSQL!.run("DELETE FROM blobs WHERE hash=?", [.text(missing)]) }
    #expect(try cold.missingBlobHashes(for: change) == [missing])
    #expect(throws: NotebookStorageError.self) { try cold.applyRemoteChange(change, peerID: f.peerID) }
  }

  @Test func sourceReplacementRejectsOldCheckpointAndNullReturnsToInlineAfterReplication() throws {
    let f = try Fixture(), (first, _) = try f.package("first"), (second, _) = try f.package("second")
    try f.publish(first); try f.sync()
    let old = try f.a.loadPage(f.pageID), element = try #require(old.elements.first), basis = try #require(old.programStateBasis("program"))
    let replacement = try f.publish(second, insert: false)
    #expect(try f.a.checkpointProgramState(target: f.page, rendered: element, state: .number(1), basis: basis, actor: f.actor) == nil)
    try f.sync()
    #expect(try f.b.loadPage(f.pageID).elements.first?.programPackage == second)
    _ = try f.a.undoCollaborationAction(replacement.id, actor: f.actor); try f.sync()
    #expect(try f.b.loadPage(f.pageID).elements.first?.programPackage == first)
    _ = try f.a.applyCollaborationAction(.init(summary: "Inline replacement", expected: [.init(target: f.page, revision: f.a.targetContentRevision(target: f.page))],
      operations: [.init(kind: .updateElement, target: f.page, id: "program", values: ["programPackage": .null, "source": .string("inline"), "html": .string("<p>inline</p>")])]), actor: f.actor)
    try f.sync()
    #expect(try f.b.loadPage(f.pageID).elements.first?.programPackage == nil)
    #expect(try f.b.loadPage(f.pageID).elements.first?.html == "<p>inline</p>")
  }

  @Test func snapshotAndCloudOutboxRetainBothCurrentAndUndoPackagesWithoutPublishingHistoricalScene() throws {
    let f = try Fixture(), (first, firstPackage) = try f.package("old"), (second, secondPackage) = try f.package("current")
    try f.publish(first); let replacement = try f.publish(second, insert: false)
    let source = try f.a.replicationSource(deviceID: f.actor), account = "program-cloud"
    try f.a.prepareCloudStorage(); try f.a.enableCloud(account: account, source: source)
    try f.a.prepareCloudUpload(account: account, source: source)
    var hashes: Set<String> = [], delivery: NotebookReplicationDelivery?
    for _ in 0..<100 {
      let records = try f.a.cloudOutbox(account: account, limit: 16)
      if records.isEmpty { break }
      hashes.formUnion(records.compactMap(\.hash)); delivery = records.compactMap(\.delivery).first ?? delivery
      try f.a.acknowledgeCloudRecords(records.map(\.id), account: account)
    }
    let expected = Set([first,second] + (firstPackage.files + secondPackage.files).flatMap(\.parts).map(\.sha256))
    #expect(expected.isSubset(of: hashes))
    let snapshot = try #require(delivery), cold = NotebookStore(root: f.root.appendingPathComponent("cold"))
    try cold.prepareEmptyWorkspace(workspaceID: f.workspaceID)
    try f.stage(snapshot.change, excluding: first, to: cold)
    #expect(try cold.missingBlobHashes(for: snapshot.change).contains(first))
    #expect(throws: (any Error).self) { try cold.applyDelivery(snapshot) }
    try f.copy(first, to: cold); try f.stage(snapshot.change, to: cold)
    _ = try cold.applyDelivery(snapshot)
    #expect(try cold.loadPage(f.pageID).elements.first?.programPackage == second)
    _ = try cold.undoCollaborationAction(replacement.id, actor: UUID())
    #expect(try cold.loadPage(f.pageID).elements.first?.programPackage == first)
    #expect(try cold.readProgramPackage(first) == firstPackage)
  }

  @Test func stateHashSpellingsAreNotDependenciesAndOldWireCannotSmugglePackageFields() throws {
    let f = try Fixture(), (hash, _) = try f.package("one")
    let fake = String(repeating: "f", count: 64)
    let row = try NotebookStoredFragment(address: "pages/x.json#/elements/@e", file: "pages/x.json", parent: "pages/x.json#",
      collection: "elements", member: "e", position: 0, value: .encode(AgentElement(id: "e", kind: .web,
        frame: .init(x: 0, y: 0, width: 100, height: 100), source: "", html: "", state: .object(["programPackage": .string(fake)]))), collections: [])
    #expect(try f.a.programPackageHashes(in: row).isEmpty)
    try f.publish(hash)
    let change = try #require(f.a.changeJournal(after: f.b.peerCursor(peerID: f.peerID, direction: .incoming)).last)
    let raw = try f.a.readBlobChunk(hash: change.manifestHash, offset: 0, maxBytes: change.byteCount)
    let value = try JSONDecoder().decode(JSONValue.self, from: raw).setting("format", .number(8))
    let bytes = try NotebookStore.storageEncoder.encode(value), forgedHash = NotebookProgramPackage.hash(bytes)
    try f.a.stageBlob(data: bytes, expectedHash: forgedHash)
    let forged = NotebookDurableChange(sequence: change.sequence, transactionID: change.transactionID, manifestHash: forgedHash, byteCount: bytes.count)
    #expect(throws: (any Error).self) { try f.stage(forged) }
    #expect(try f.b.loadPage(f.pageID).elements.isEmpty)
  }

  @Test func boardAndDocumentUseTheSamePublicationAndDeliveryAsPages() throws {
    let f = try Fixture(), (hash, _) = try f.package("shared"), documentID = UUID()
    let board = CollaborationTarget(kind: .board, id: f.boardID)
    let basis = try f.a.readBasis(targets: [board, .init(kind: .workspace, id: f.boardID)])
    _ = try f.a.applyCollaborationAction(.init(summary: "Board and document", expected: basis.owners, operations: [
      .init(kind: .insertElement, target: board, id: "board-program", values: ["kind": .string("web"), "source": .string(""),
        "programPackage": .string(hash), "frame": try .encode(SpatialRect(x: 0, y: 0, width: 400, height: 400)), "worldOrigin": try .encode(WorldPoint.zero)]),
      .init(kind: .createDocument, target: board, id: documentID.uuidString, values: ["center": try .encode(WorldPoint.zero),
        "paperSize": .string("a4"), "blocks": .array([.object(["id": .string("doc-program"), "kind": .string("interactive"),
          "html": .string(""), "programPackage": .string(hash)])])])
    ]), actor: f.actor)
    try f.sync()
    #expect(try f.b.loadBoard(items: f.b.loadIndex().items).board(f.boardID)?.elements.first?.programPackage == hash)
    #expect(try f.b.loadDocument(documentID).blocks.first?.programPackage == hash)
    let target = CollaborationTarget(kind: .document, id: documentID)
    _ = try f.a.applyCollaborationAction(.init(summary: "Document inline", expected: [.init(target: target, revision: f.a.targetContentRevision(target: target))],
      operations: [.init(kind: .updateBlock, target: target, id: "doc-program", values: ["programPackage": .null, "html": .string("<p>inline</p>")])]), actor: f.actor)
    try f.sync()
    #expect(try f.b.loadDocument(documentID).blocks.first?.programPackage == nil)
    #expect(try f.b.loadDocument(documentID).blocks.first?.html == "<p>inline</p>")
  }

  @Test func retainedConcurrentSourceHeadsRemainOfflineDependenciesButStateHeadsDoNot() throws {
    let f = try Fixture(), (a, _) = try f.package("hidden-a"), (b, _) = try f.package("hidden-b")
    let left = ContentFieldVersion(stamp: .init(counter: 3, actor: UUID()), human: true)
      .retainingValue(.object(["programPackage": .string(a)]))
    let right = ContentFieldVersion(stamp: .init(counter: 3, actor: UUID()), human: false)
      .retainingValue(.object(["programPackage": .string(b)]))
    let heads = try left.joining(right), file = pageFile(f.pageID), key = "elements/retired/content"
    let row = try NotebookStoredFragment(address: file + "#/collaboration/fields/@" + fieldKey([key]), file: file, parent: file + "#",
      collection: "collaboration/fields", member: key, position: 0, value: .encode(heads), collections: [])
    #expect(try f.a.programPackageHashes(in: row) == [a,b])
    let stateKey = "elements/retired/state"
    let state = NotebookStoredFragment(address: file + "#/collaboration/fields/@" + fieldKey([stateKey]), file: file, parent: file + "#",
      collection: "collaboration/fields", member: stateKey, position: 0, value: row.value, collections: [])
    #expect(try f.a.programPackageHashes(in: state).isEmpty)
    try f.a.commandTransaction { _ = try f.a.writeFragment(row, database: f.a.currentSQL!) }
    let snapshot = try f.a.commandTransaction { try f.a.cloudSnapshot(source: f.a.replicationSource(deviceID: f.actor)) }
    try f.stage(snapshot.change, excluding: b)
    #expect(try f.b.missingBlobHashes(for: snapshot.change).contains(b))
    #expect(throws: (any Error).self) { try f.b.applyDelivery(snapshot) }
    try f.copy(b); try f.stage(snapshot.change)
    _ = try f.b.applyDelivery(snapshot)
    #expect(try f.b.readProgramPackage(a) == f.a.readProgramPackage(a))
    #expect(try f.b.readProgramPackage(b) == f.a.readProgramPackage(b))
    #expect(try f.b.loadPage(f.pageID).elements.isEmpty)
  }

}
