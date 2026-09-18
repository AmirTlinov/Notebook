import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Lifecycle inverse bounded backing and accepted order proof", .serialized)
struct NotebookActionInverseScaleTests {
  private func fixture(_ body: (NotebookStore, WorkspaceIndex, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inverse-scale-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, store.loadIndex(), actor)
  }

  private func steps(_ db: NotebookSQLConnection) -> Int64 {
    var count: Int64 = 0, statement = sqlite3_next_stmt(db.handle, nil)
    while let next = statement {
      count += Int64(sqlite3_stmt_status(next, SQLITE_STMTSTATUS_VM_STEP, 0))
      statement = sqlite3_next_stmt(db.handle, next)
    }
    return count
  }

  @Test func seventeenThousandRawChangesProduceTwoBoundedPartsAndOneOrderedStream() throws {
    try fixture { store, index, _ in
      let actionID = UUID(), total = 17_001, file = pageFile(index.selectedPageID!)
      try store.commandTransaction {
        let db = store.currentSQL!
        try db.withActionRecordCapture(actionID: actionID) {
          for offset in 0..<total {
            let id = String(format: "%06d", offset)
            let element = AgentElement(id: id, kind: .markdown,
              frame: .init(x: 0, y: 0, width: 100, height: 100), source: "Original", html: "<p>Original</p>")
            let fragment = try NotebookStoredFragment(address: file + "#/elements/@" + id, file: file,
              parent: file + "#", collection: "elements", member: id, position: offset,
              value: .encode(element), collections: [])
            let hash = try db.putBlob(NotebookStore.storageEncoder.encode(fragment))
            // Isolate the backing from a 17k-object UI/reference-index seed.
            // This is the same raw first-before/last-after capture seam tested
            // separately through the physical writer's hooks.
            try db.recordActionRecordChange(address: fragment.address, beforeHash: hash, afterHash: nil)
          }
        }
        let reference = try #require(try store.saveLifecycleInverse(actionID: actionID))
        let root = try store.readLifecycleInverseRoot(reference: reference, actionID: actionID)
        #expect(reference.recordCount == total && root.parts.count == 2)
        let first = try store.readLifecycleInversePart(hash: root.parts[0], actionID: actionID, ordinal: 0)
        let last = try store.readLifecycleInversePart(hash: root.parts[1], actionID: actionID, ordinal: 1)
        #expect(first.records.count == 16_384 && last.records.count == total - 16_384)
        #expect(first.records.last!.address < last.records.first!.address)
        var count = 0, after = ""
        try store.visitLifecycleInverse(reference: reference, actionID: actionID) { row in
          #expect(row.address > after && row.beforeHash != nil && row.afterHash == nil)
          after = row.address; count += 1
        }
        #expect(count == total)
      }
    }
  }

  @Test func anAcceptedHistoricalOrderDoesNotReenumerateItsUnchangedPageIdentities() throws {
    try fixture { store, index, actor in
      let actionID = UUID(), item = index.selectedItemID.uuidString.lowercased()
      var rootHash = ""
      // Real canonical nodes and the existing typed closure validator, but no
      // 4096 physical pages or notebook projection. This tests proof reuse only.
      try store.commandTransaction {
        rootHash = try NotebookPageOrderVector.build((0..<4_096).map { _ in UUID() }, write: { try store.currentSQL!.putBlob($0.canonicalData()) })
        try store.currentSQL!.noteOwner(.orderRoot, rootHash)
      }
      let reference = try store.commandTransaction {
        let db = store.currentSQL!
        let order = try NotebookPageOrderRegister.authored(root: rootHash,
          stamp: .init(counter: 50, actor: actor), human: true, previous: nil)
        let row = try NotebookStoredFragment(address: "workspace.json#/pageOrders/@" + item, file: "workspace.json",
          parent: "workspace.json#", collection: "pageOrders", member: item, position: 0,
          value: .encode(order), collections: [])
        let hash = try db.putBlob(NotebookStore.storageEncoder.encode(row))
        try db.withActionRecordCapture(actionID: actionID) {
          try db.recordActionRecordChange(address: row.address, beforeHash: hash, afterHash: nil)
        }
        return try #require(try store.saveLifecycleInverse(actionID: actionID))
      }
      try store.readTransaction { _ in
        let db = store.currentSQL!
        let accepted = try db.rows("SELECT 1 FROM page_order_nodes WHERE hash=?", [.text(rootHash)])
        #expect(!accepted.isEmpty)
        let start = steps(db)
        var count = 0
        try store.visitLifecycleInverse(reference: reference, actionID: actionID) { _ in count += 1 }
        let work = steps(db) - start
        print("S8 inverse accepted root: pages=4096 VMsteps=\(work)")
        #expect(count == 1)
        #expect(work < 2_000, "An already admitted immutable root is a proof, not a request to reread 4096 unchanged page IDs; VM steps: \(work)")
      }
    }
  }

  @Test func localAcceptedOrderProofDoesNotOmitCloudDependenciesForAFreshPeer() throws {
    try fixture { store, index, actor in
      let actionID = UUID(), item = index.selectedItemID.uuidString.lowercased()
      var orderHashes: [String] = [], orderRoot = ""
      try store.commandTransaction {
        orderRoot = try NotebookPageOrderVector.build((0..<65).map { _ in UUID() }, write: { node in
          let hash = try store.currentSQL!.putBlob(node.canonicalData()); orderHashes.append(hash); return hash
        })
        try store.currentSQL!.noteOwner(.orderRoot, orderRoot)
      }
      let reference = try store.commandTransaction {
        let db = store.currentSQL!
        let order = try NotebookPageOrderRegister.authored(root: orderRoot,
          stamp: .init(counter: 50, actor: actor), human: true, previous: nil)
        let fragment = try NotebookStoredFragment(address: "workspace.json#/pageOrders/@" + item, file: "workspace.json",
          parent: "workspace.json#", collection: "pageOrders", member: item, position: 0,
          value: .encode(order), collections: [])
        let body = try db.putBlob(NotebookStore.storageEncoder.encode(fragment))
        try db.withActionRecordCapture(actionID: actionID) {
          try db.recordActionRecordChange(address: fragment.address, beforeHash: body, afterHash: nil)
        }
        return try #require(try store.saveLifecycleInverse(actionID: actionID))
      }
      let action = CollaborationAction(id: actionID, summary: "Historical inverse", expected: [], operations: [
        .init(kind: .renameItem, target: .init(kind: .board, id: index.rootBoardID), id: item, values: ["title": .string("Historical")])])
      var receipt = CollaborationReceipt(id: actionID, action: action, createdAt: Date(), revisions: [], changes: [])
      receipt.lifecycleInverse = reference
      try store.publishCollaboration(writes: ["collaboration/actions/" + actionID.uuidString.lowercased() + ".json": .encode(receipt)])
      let peer = NotebookStore(root: store.root.appendingPathComponent("fresh-peer")), account = "inverse-fresh-cloud"
      try peer.prepareEmptyWorkspace(workspaceID: store.workspaceHeader().workspaceID)
      let source = try store.replicationSource(deviceID: actor), peerSource = try peer.replicationSource(deviceID: UUID())
      try store.prepareCloudStorage(); try store.enableCloud(account: account, source: source)
      try peer.prepareCloudStorage(); try peer.enableCloud(account: account, source: peerSource)
      try store.prepareCloudUpload(account: account, source: source)
      let heldHash = try #require(orderHashes.first)
      var held: (NotebookCloudRecord, Data)?, delivery: NotebookReplicationDelivery?, uploaded = Set<String>()
      for _ in 0..<100 {
        let records = try store.cloudOutbox(account: account, limit: 16)
        if records.isEmpty { break }
        for record in records {
          if let value = record.delivery {
            delivery = value; try peer.stageCloudDelivery(value, account: account, localSource: peerSource)
          } else if let hash = record.hash {
            uploaded.insert(hash)
            let bytes = try store.readBlobChunk(hash: hash, offset: record.offset, maxBytes: max(1, record.byteCount))
            if hash == heldHash { held = (record, bytes) }
            else { try peer.stageCloudChunk(record, data: bytes, account: account) }
          }
        }
        try store.acknowledgeCloudRecords(records.map(\.id), account: account)
      }
      #expect(Set(orderHashes).isSubset(of: uploaded), "Accepted locally does not mean uploaded to a fresh account")
      func installComplete() throws {
        while let record = try peer.nextCompleteCloudBlob(account: account) {
          let file = peer.root.appendingPathComponent("assembly")
          defer { try? FileManager.default.removeItem(at: file) }
          try peer.assembleCloudBlob(record, account: account, file: file)
          try peer.installCloudBlob(record, account: account, file: file)
        }
      }
      try installComplete()
      let snapshot = try #require(delivery)
      #expect(try peer.missingBlobHashes(for: snapshot.change).contains(heldHash))
      #expect(throws: NotebookStorageError.self) { try peer.applyCloudDelivery(snapshot, account: account) }
      #expect(try peer.incomingCursor(source: source) == 0)
      let chunk = try #require(held)
      try peer.stageCloudChunk(chunk.0, data: chunk.1, account: account); try installComplete()
      #expect(try peer.missingBlobHashes(for: snapshot.change).isEmpty)
      _ = try peer.applyCloudDelivery(snapshot, account: account)
      #expect(try peer.incomingCursor(source: source) == snapshot.change.sequence)
      #expect(try peer.pageCount(in: index.selectedItemID) == 1,
        "Historical inverse admission cannot install its 65-page value into content")
    }
  }

  @Test func acceptedChildrenDoNotProveANewRootWithDuplicatePageIdentity() throws {
    try fixture { store, index, actor in
      let actionID = UUID(), shared = UUID(), item = index.selectedItemID.uuidString.lowercased()
      var children: [String] = []
      try store.commandTransaction {
        for _ in 0..<2 {
          let node = NotebookPageOrderNode(height: 0, count: 32, pages: [shared] + (0..<31).map { _ in UUID() })
          let hash = try store.currentSQL!.putBlob(node.canonicalData())
          children.append(hash); try store.currentSQL!.noteOwner(.orderRoot, hash)
        }
      }
      let reference = try store.commandTransaction {
        let db = store.currentSQL!
        let forged = NotebookPageOrderNode(height: 1, count: 64, children: children)
        let root = try db.putBlob(forged.canonicalData())
        let order = try NotebookPageOrderRegister.authored(root: root,
          stamp: .init(counter: 50, actor: actor), human: true, previous: nil)
        let row = try NotebookStoredFragment(address: "workspace.json#/pageOrders/@" + item, file: "workspace.json",
          parent: "workspace.json#", collection: "pageOrders", member: item, position: 0,
          value: .encode(order), collections: [])
        let hash = try db.putBlob(NotebookStore.storageEncoder.encode(row))
        try db.withActionRecordCapture(actionID: actionID) {
          try db.recordActionRecordChange(address: row.address, beforeHash: hash, afterHash: nil)
        }
        return try #require(try store.saveLifecycleInverse(actionID: actionID))
      }
      #expect(throws: NotebookStorageError.self) {
        try store.visitLifecycleInverse(reference: reference, actionID: actionID) { _ in }
      }
    }
  }


  @Test func rawInverseAddressOrderMatchesSQLiteBinaryForUnicodeMembers() throws {
    try fixture { store, _, _ in
      let actionID = UUID(), file = "shared-order-fixture.json"
      // Distinct identifiers, including a decomposed scalar sequence. This is
      // physical SQL address order, not a locale or human-facing title order.
      let members = ["é", "z", "o\u{0308}", "я", "ё", "中", "a"]
      try store.commandTransaction {
        let db = store.currentSQL!
        try db.withActionRecordCapture(actionID: actionID) {
          for member in members {
            let fragment = NotebookStoredFragment(address: file + "#/members/@" + member, file: file,
              parent: file + "#", collection: "members", member: member, position: 0,
              value: .string(member), collections: [])
            let hash = try db.putBlob(NotebookStore.storageEncoder.encode(fragment))
            try db.recordActionRecordChange(address: fragment.address, beforeHash: hash, afterHash: nil)
          }
        }
        let expected = try db.actionRecordCapturePage(actionID: actionID).map(\.address)
        let binary = expected.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        #expect(expected.map { Array($0.utf8) } == binary.map { Array($0.utf8) })
        let reference = try #require(try store.saveLifecycleInverse(actionID: actionID))
        var visited: [String] = []
        try store.visitLifecycleInverse(reference: reference, actionID: actionID) { visited.append($0.address) }
        #expect(visited.map { Array($0.utf8) } == expected.map { Array($0.utf8) })
      }
    }
  }


  @Test func inverseBodyCannotSubstituteACanonicallyEquivalentButDifferentSQLAddress() throws {
    try fixture { store, _, _ in
      let actionID = UUID(), file = "shared-order-fixture.json"
      let named = file + "#/members/@é", stored = file + "#/members/@e\u{0301}"
      #expect(named == stored) // Swift canonical equivalence is not SQL identity.
      #expect(!named.utf8.elementsEqual(stored.utf8))
      let reference = try store.commandTransaction {
        let db = store.currentSQL!
        let fragment = NotebookStoredFragment(address: stored, file: file, parent: file + "#",
          collection: "members", member: "e\u{0301}", position: 0, value: .string("old body"), collections: [])
        let body = try db.putBlob(NotebookStore.storageEncoder.encode(fragment))
        let workspaceID = try store.workspaceHeader().workspaceID
        let part = NotebookLifecycleInversePart(format: 1, workspaceID: workspaceID, actionID: actionID,
          ordinal: 0, records: [.init(address: named, beforeHash: body, afterHash: nil)])
        let partHash = try db.putBlob(NotebookStore.storageEncoder.encode(part))
        let root = NotebookLifecycleInverseRoot(format: 1, workspaceID: workspaceID, actionID: actionID,
          recordCount: 1, parts: [partHash])
        return try NotebookLifecycleInverseReference(rootHash: db.putBlob(NotebookStore.storageEncoder.encode(root)), recordCount: 1)
      }
      #expect(throws: NotebookStorageError.self) {
        try store.visitLifecycleInverse(reference: reference, actionID: actionID) { _ in }
      }
    }
  }

}
