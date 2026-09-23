import Foundation
import Testing
@testable import NotebookCore

@Suite("Lifecycle inverse blobs are an admitted receipt dependency", .serialized)
struct NotebookActionInverseTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("action-inverse-\(UUID())")
    let source: NotebookStore, peer: NotebookStore
    let peerID = UUID(), actionID = UUID()
    let index: WorkspaceIndex
    let workspaceID: UUID
    init() throws {
      source = NotebookStore(root: root.appendingPathComponent("source"))
      peer = NotebookStore(root: root.appendingPathComponent("peer"))
      _ = try source.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
      index = try source.loadIndex(); workspaceID = try source.workspaceHeader().workspaceID
      try peer.prepareEmptyWorkspace(workspaceID: workspaceID)
      for change in try source.changeJournal(after: 0) {
        try stage(change)
        _ = try peer.applyRemoteChange(change, peerID: peerID)
      }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func copy(_ hash: String) throws {
      let bytes = try source.blobSize(hash: hash)
      let data = try source.readBlobChunk(hash: hash, offset: 0, maxBytes: max(1, Int(bytes)))
      try peer.stageBlob(data: data, expectedHash: hash)
    }
    func stage(_ change: NotebookDurableChange, excluding: String? = nil) throws {
      for _ in 0..<100 {
        let missing = try peer.missingBlobHashes(for: change).filter { $0 != excluding }
        if missing.isEmpty { return }
        for hash in missing { try copy(hash) }
      }
      Issue.record("Fixture dependency discovery did not terminate")
    }
    func fragment(_ name: String) throws -> NotebookStoredFragment {
      let file = pageFile(index.selectedPageID!)
      let value = AgentElement(id: name, kind: .markdown, frame: .init(x: 0, y: 0, width: 100, height: 100), source: "historical", html: "<p>historical</p>")
      return try .init(address: file + "#/elements/@" + name, file: file, parent: file + "#",
        collection: "elements", member: name, position: 0, value: .encode(value), collections: [])
    }
    func publish(_ reference: NotebookLifecycleInverseReference, restoration: NotebookLifecycleInverseReference? = nil) throws -> NotebookDurableChange {
      let before = try source.currentChangeCursor()
      let action = CollaborationAction(id: actionID, summary: "Inverse fixture", expected: [], operations: [
        .init(kind: .renameItem, target: .init(kind: .board, id: index.rootBoardID), id: index.selectedItemID.uuidString, values: ["title": .string("Fixture")])])
      var receipt = CollaborationReceipt(id: actionID, action: action, createdAt: Date(), revisions: [], changes: [])
      receipt.lifecycleInverse = reference
      if let restoration {
        receipt.undo = .init(restored: 1, preserved: [], completedAt: Date())
        receipt.undo?.restorationInverse = restoration
      }
      try source.publishCollaboration(writes: ["collaboration/actions/" + actionID.uuidString.lowercased() + ".json": .encode(receipt)])
      return try #require(source.changeJournal(after: before).last)
    }
    func bundle(name: String = "retired", wrongAction: Bool = false, pageOrder: Bool = false, ink: InkMeasurements? = nil) throws -> (NotebookLifecycleInverseReference, String, String, [String]) {
      try source.commandTransaction {
        let db = source.currentSQL!
        var row = try fragment(name), orderHashes: [String] = []
        if pageOrder {
          let vector = try NotebookPageOrderVector.build((0..<65).map { _ in UUID() }, write: { node in
            let hash = try db.putBlob(node.canonicalData()); orderHashes.append(hash); return hash
          })
          let order = try NotebookPageOrderRegister.authored(root: vector, stamp: .init(counter: 50, actor: UUID()), human: true, previous: nil)
          let id = index.selectedItemID.uuidString.lowercased()
          row = try .init(address: "workspace.json#/pageOrders/@" + id, file: "workspace.json", parent: "workspace.json#",
            collection: "pageOrders", member: id, position: 0, value: .encode(order), collections: [])
        }
        if let ink {
          let file=pageFile(index.selectedPageID!),parent=file+"#/drawingData/actions/@"+UUID().uuidString.lowercased()
          row=try .init(address:parent+"/samples",file:file,parent:parent,collection:"samples",member:"",position:0,
            value:.encode(ink),collections:[])
        }
        let before = try db.putBlob(db.encodedStoredFragment(row))
        let part = NotebookLifecycleInversePart(format: 1, workspaceID: workspaceID, actionID: wrongAction ? UUID() : actionID,
          ordinal: 0, records: [.init(address: row.address, beforeHash: before, afterHash: nil)])
        let partHash = try db.putBlob(NotebookStore.storageEncoder.encode(part))
        let root = NotebookLifecycleInverseRoot(format: 1, workspaceID: workspaceID, actionID: actionID, recordCount: 1, parts: [partHash])
        let rootHash = try db.putBlob(NotebookStore.storageEncoder.encode(root))
        return (.init(rootHash: rootHash, recordCount: 1), partHash, before, orderHashes)
      }
    }
  }

  @Test func historicalInkBodyIsRequiredBeforeAckAndIncludedInCloudClosure() throws {
    let f=try Fixture(),samples=(0..<300).map { i in
      SpatialInkSample(point:.init(x:Double(i),y:Double(i%13)),timeOffset:Double(i)/128,
        width:4,opacity:0.5,force:0.75,azimuth:0,altitude:1)
    }
    let ink=InkMeasurements(samples), (reference,_,before,_)=try f.bundle(ink:ink)
    let hash=try f.source.sqlRead { db in
      try #require(JSONDecoder().decode(NotebookStoredFragment.self,from:db.blob(before)).inkBodyHashes.first)
    }
    let change=try f.publish(reference),cursor=try f.peer.peerCursor(peerID:f.peerID,direction:.incoming)
    try f.stage(change,excluding:hash)
    #expect(try f.peer.missingBlobHashes(for:change) == [hash])
    #expect(throws:NotebookStorageError.self) { try f.peer.applyRemoteChange(change,peerID:f.peerID) }
    #expect(try f.peer.peerCursor(peerID:f.peerID,direction:.incoming) == cursor)
    try f.copy(hash);try f.stage(change)
    _=try f.peer.applyRemoteChange(change,peerID:f.peerID)
    let restored=try f.peer.readTransaction { store in try store.readLifecycleInverseFragment(hash:before).value.decode(InkMeasurements.self) }
    #expect(try restored.encodedRelations() == ink.encodedRelations())
    try f.peer.commandTransaction {
      var bytes=try f.peer.currentSQL!.blob(hash);bytes[bytes.count-1] ^= 1
      try f.peer.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?",[.blob(bytes),.text(hash)])
    }
    #expect(throws:NotebookStorageError.blobHashMismatch) { try f.peer.applyRemoteChange(change,peerID:f.peerID) }
    let account="ink-body-cloud",source=try f.source.replicationSource(deviceID:UUID())
    try f.source.prepareCloudStorage();try f.source.enableCloud(account:account,source:source)
    try f.source.prepareCloudUpload(account:account,source:source)
    var hashes=Set<String>()
    while true {
      let rows=try f.source.cloudOutbox(account:account,limit:16)
      if rows.isEmpty { break }
      hashes.formUnion(rows.compactMap(\.hash))
      try f.source.acknowledgeCloudRecords(rows.map(\.id),account:account)
    }
    #expect(hashes.contains(hash) && hashes.contains(before))
  }

  @Test func closedCaptureBuildsAPagedRoundTripAndEmptyCaptureHasNoRoot() throws {
    let f = try Fixture(), empty = UUID()
    try f.source.commandTransaction {
      let db = f.source.currentSQL!
      try db.withActionRecordCapture(actionID: empty) {}
      #expect(try f.source.saveLifecycleInverse(actionID: empty) == nil)
      _ = try db.withActionRecordCapture(actionID: f.actionID) {
        for index in 0..<193 { try f.source.writeFragment(f.fragment(String(format: "%04d", index)), database: db) }
        #expect(throws: NotebookStorageError.self) { try f.source.saveLifecycleInverse(actionID: f.actionID) }
      }
      let reference = try #require(try f.source.saveLifecycleInverse(actionID: f.actionID))
      #expect(reference.recordCount == 193)
      var count = 0, previous = ""
      try f.source.visitLifecycleInverse(reference: reference, actionID: f.actionID) { row in
        #expect(row.address > previous && row.beforeHash == nil && row.afterHash != nil)
        previous = row.address; count += 1
      }
      #expect(count == 193)
    }
  }

  @Test func restorationCaptureHasItsOwnEvidenceButRemainsBoundToTheOriginalAction() throws {
    let f = try Fixture(), captureID = UUID(), fragment = try f.fragment("restoration")
    try f.source.commandTransaction {
      let db = f.source.currentSQL!
      _ = try db.withActionRecordCapture(actionID: f.actionID) { try f.source.writeFragment(fragment, database: db) }
      let original = try #require(try f.source.saveLifecycleInverse(actionID: f.actionID))
      try db.withActionRecordCapture(actionID: captureID) { try f.source.removeFragment(fragment.address, database: db) }
      let restoration = try #require(try f.source.saveLifecycleInverse(actionID: f.actionID, captureID: captureID))
      #expect(original != restoration)
      var restoredRows = 0
      try f.source.visitLifecycleInverse(reference: restoration, actionID: f.actionID) { row in
        #expect(row.address == fragment.address && row.beforeHash != nil && row.afterHash == nil)
        restoredRows += 1
      }
      #expect(restoredRows == 1)
      #expect(throws: NotebookStorageError.self) { try f.source.visitLifecycleInverse(reference: restoration, actionID: captureID) { _ in } }
    }
  }

  @Test func anUndoReceiptCannotAcknowledgeItsMissingRestorationRoot() throws {
    let f = try Fixture(), (original, _, _, _) = try f.bundle()
    // The sender has a valid receipt; only the receiver lacks this root.
    let (restoration, _, _, _) = try f.bundle(name: "missing-at-peer")
    let change = try f.publish(original, restoration: restoration), cursor = try f.peer.peerCursor(peerID: f.peerID, direction: .incoming)
    try f.stage(change, excluding: restoration.rootHash)
    #expect(try f.peer.missingBlobHashes(for: change).contains(restoration.rootHash))
    #expect(throws: NotebookStorageError.self) { try f.peer.applyRemoteChange(change, peerID: f.peerID) }
    #expect(try f.peer.peerCursor(peerID: f.peerID, direction: .incoming) == cursor)
  }

  @Test func restorationBodiesAreIndependentDependenciesUnderTheSameActionIdentity() throws {
    let f = try Fixture(), (original, _, _, _) = try f.bundle()
    let (restoration, part, body, _) = try f.bundle(name: "restored-body")
    let change = try f.publish(original, restoration: restoration), cursor = try f.peer.peerCursor(peerID: f.peerID, direction: .incoming)
    try f.copy(restoration.rootHash); try f.copy(part)
    try f.stage(change, excluding: body)
    #expect(try f.peer.missingBlobHashes(for: change).contains(body))
    #expect(throws: NotebookStorageError.self) { try f.peer.applyRemoteChange(change, peerID: f.peerID) }
    #expect(try f.peer.peerCursor(peerID: f.peerID, direction: .incoming) == cursor)
    try f.copy(body); try f.stage(change)
    _ = try f.peer.applyRemoteChange(change, peerID: f.peerID)
    var count = 0
    try f.peer.visitLifecycleInverse(reference: original, actionID: f.actionID) { _ in count += 1 }
    try f.peer.visitLifecycleInverse(reference: restoration, actionID: f.actionID) { _ in count += 1 }
    #expect(count == 2)
    #expect(try f.peer.readPageElement(pageID: f.index.selectedPageID!, elementID: "restored-body") == nil)
  }

  @Test func aReceiptWithoutItsInverseRootCannotAdvanceTheIncomingCursor() throws {
    let f = try Fixture(), reference = NotebookLifecycleInverseReference(rootHash: String(repeating: "1", count: 64), recordCount: 1)
    let change = try f.publish(reference), cursor = try f.peer.peerCursor(peerID: f.peerID, direction: .incoming)
    try f.stage(change, excluding: reference.rootHash)
    #expect(try f.peer.missingBlobHashes(for: change).contains(reference.rootHash))
    #expect(throws: NotebookStorageError.self) { try f.peer.applyRemoteChange(change, peerID: f.peerID) }
    #expect(try f.peer.peerCursor(peerID: f.peerID, direction: .incoming) == cursor)
    #expect(try !f.peer.hasStoredValue("collaboration/actions/" + f.actionID.uuidString.lowercased() + ".json"))
  }

  @Test func missingHistoricalBodyIsRequestedBeforeReceiptAck() throws {
    let f = try Fixture(), (reference, part, before, _) = try f.bundle()
    let change = try f.publish(reference), cursor = try f.peer.peerCursor(peerID: f.peerID, direction: .incoming)
    try f.copy(reference.rootHash); try f.copy(part)
    try f.stage(change, excluding: before)
    #expect(try f.peer.missingBlobHashes(for: change).contains(before))
    #expect(throws: NotebookStorageError.self) { try f.peer.applyRemoteChange(change, peerID: f.peerID) }
    #expect(try f.peer.peerCursor(peerID: f.peerID, direction: .incoming) == cursor)
    try f.copy(before); try f.stage(change)
    _ = try f.peer.applyRemoteChange(change, peerID: f.peerID)
    var count = 0
    try f.peer.readTransaction { store in
      try store.visitLifecycleInverse(reference: reference, actionID: f.actionID) { _ in count += 1 }
    }
    #expect(count == 1)
    #expect(try f.peer.readPageElement(pageID: f.index.selectedPageID!, elementID: "retired") == nil,
      "Admission retains inverse blobs without applying their old content")
  }

  @Test func corruptAlreadyDiscoveredPartIsStillRejectedBeforeAck() throws {
    let f = try Fixture(), (reference, part, before, _) = try f.bundle()
    let change = try f.publish(reference), cursor = try f.peer.peerCursor(peerID: f.peerID, direction: .incoming)
    for hash in [reference.rootHash, part, before] { try f.copy(hash) }
    try f.stage(change)
    try f.peer.commandTransaction {
      let data = try f.peer.currentSQL!.blob(part)
      var corrupt = data; corrupt[corrupt.startIndex] = 32
      try f.peer.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(corrupt), .text(part)])
    }
    #expect(throws: NotebookStorageError.self) { try f.peer.applyRemoteChange(change, peerID: f.peerID) }
    #expect(try f.peer.peerCursor(peerID: f.peerID, direction: .incoming) == cursor)
  }

  @Test func partBoundToAnotherActionIsNotAnAdmittedInverse() throws {
    let f = try Fixture(), (reference, part, before, _) = try f.bundle(wrongAction: true)
    let change = try f.publish(reference), cursor = try f.peer.peerCursor(peerID: f.peerID, direction: .incoming)
    for hash in [reference.rootHash, part, before] { try f.copy(hash) }
    #expect(throws: (any Error).self) {
      try f.stage(change)
      _ = try f.peer.applyRemoteChange(change, peerID: f.peerID)
    }
    #expect(try f.peer.peerCursor(peerID: f.peerID, direction: .incoming) == cursor)
  }

  @Test func aSnapshotCoveredPrefixDoesNotRequireItsAbsentHistoricalManifest() throws {
    let f = try Fixture(), before = try f.source.currentChangeCursor()
    var page = try f.source.loadPage(f.index.selectedPageID!)
    let element = try f.fragment("snapshot-live").value.decode(AgentElement.self)
    let edited = page.replaceElements([element], actor: UUID())
    #expect(edited)
    _ = try f.source.savePage(page)
    let old = try #require(f.source.changeJournal(after: before).first)
    let source = NotebookReplicationSource(deviceID: f.peerID, generation: f.peerID)
    let snapshot = try f.source.commandTransaction(advancesReadRevision: false) {
      try f.source.cloudSnapshot(source: source)
    }
    try f.stage(snapshot.change)
    _ = try f.peer.applyDelivery(snapshot)
    #expect(throws: NotebookStorageError.self) { try f.peer.blobSize(hash: old.manifestHash) }
    let historical = NotebookReplicationDelivery(source: source, change: old)
    #expect(try !f.peer.deliveryNeedsContent(historical))
    #expect(try f.peer.applyDelivery(historical) == snapshot.change.sequence)
    #expect(try f.peer.readPageElement(pageID: f.index.selectedPageID!, elementID: "snapshot-live") != nil)
  }

  @Test func aKnownReceiptCannotUseDedupeToAcknowledgeCorruptInverseBytes() throws {
    let f = try Fixture(), (reference, part, _, _) = try f.bundle()
    let change = try f.publish(reference)
    try f.stage(change)
    _ = try f.peer.applyRemoteChange(change, peerID: f.peerID)
    try f.peer.commandTransaction {
      var bytes = try f.peer.currentSQL!.blob(part); bytes[bytes.startIndex] = 32
      try f.peer.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(bytes), .text(part)])
    }
    #expect(throws: NotebookStorageError.self) { try f.peer.applyRemoteChange(change, peerID: f.peerID) }
    #expect(try f.peer.peerCursor(peerID: f.peerID, direction: .incoming) == change.sequence)
  }

  @Test func cloudSnapshotIncludesHistoricalInverseAndRealPageOrderNodeClosure() throws {
    let f = try Fixture(), (reference, part, before, orderHashes) = try f.bundle(pageOrder: true)
    let (restoration, restorationPart, restorationBody, _) = try f.bundle(name: "cloud-restoration")
    _ = try f.publish(reference, restoration: restoration)
    let account = "inverse-cloud", source = try f.source.replicationSource(deviceID: UUID())
    try f.source.prepareCloudStorage(); try f.source.enableCloud(account: account, source: source)
    #expect(NotebookChangeManifest(transactionID: UUID(), workspaceID: f.workspaceID, records: []).format == 24)
    try f.source.prepareCloudUpload(account: account, source: source)
    var hashes = Set<String>()
    for _ in 0..<100 {
      let records = try f.source.cloudOutbox(account: account, limit: 16)
      if records.isEmpty { break }
      hashes.formUnion(records.compactMap(\.hash))
      try f.source.acknowledgeCloudRecords(records.map(\.id), account: account)
    }
    #expect(Set([reference.rootHash, part, before, restoration.rootHash, restorationPart, restorationBody] + orderHashes).isSubset(of: hashes))
  }
}
