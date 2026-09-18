import Foundation
import Testing
@testable import NotebookCore

@Suite("Retired page source ownership is not a reusable UUID", .serialized)
struct NotebookPageSourceOwnershipTests {
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    var store: NotebookStore { content.store }
    var actor: UUID { content.actor }
    let neighbor: UUID
    let boardID: UUID

    init() throws {
      content = try NotebookItemLifecycleTests.Fixture()
      var index = try content.store.loadIndex()
      boardID = index.rootBoardID
      var board = try content.store.loadBoard(items: index.items)
      let creation = index.createNotebook(title: "Other notebook", actor: content.actor, pageSize: content.size)
      let created = try #require(creation)
      neighbor = created.item.id
      let placed = board.addItem(neighbor, to: boardID, near: .zero, actor: content.actor)
      #expect(placed)
      try content.store.saveWorkspaceBundle(index: index, page: created.page, board: board)
    }

    func packet(_ rows: [NotebookStoredFragment], sequence: UInt64, pageOrderRoots: [String] = []) throws -> NotebookDurableChange {
      try store.commandTransaction {
        let records = try rows.map { row in
          NotebookRecordMutation(address: row.address,
            blobHash: try store.currentSQL!.putBlob(NotebookStore.storageEncoder.encode(row)))
        }
        let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: try store.workspaceHeader().workspaceID,
          records: records, pageOrderRoots: pageOrderRoots)
        let bytes = try NotebookStore.storageEncoder.encode(manifest)
        let hash = try store.currentSQL!.putBlob(bytes)
        return .init(sequence: sequence, transactionID: manifest.transactionID, manifestHash: hash, byteCount: bytes.count)
      }
    }
  }

  @Test(arguments: [false, true])
  func aRetiredPageCannotBeBornInAnotherNotebook(createNotebook: Bool) throws {
    let f = try Fixture(), pageID = f.content.pageID
    try f.store.commandTransaction {
      try f.store.deleteWorkspaceItemContent(itemID: f.content.itemID, actor: f.actor, human: true)
    }
    let birthKey = fieldKey(["items", f.content.itemID.uuidString.lowercased(), "pageIDs", pageID.uuidString.lowercased()])
    let birthAddress = "workspace.json#/collaboration/fields/@" + fieldKey([birthKey])
    #expect(try !f.store.storedFragments(address: birthAddress, descendants: false).isEmpty,
      "The original native birth remains even when its live membership is gone")
    let cursor = try f.store.currentChangeCursor(), newItemID = UUID()
    #expect(throws: (any Error).self) {
      if createNotebook {
        var index = try f.store.loadIndex(), board = try f.store.loadBoard(items: index.items)
        guard let created = index.createNotebook(title: "Illegitimate second owner", actor: f.actor,
          pageSize: f.content.size, itemID: newItemID, pageID: pageID) else {
          throw NotebookStorageError.invalidTransaction("retired UUID refused")
        }
        guard board.addItem(newItemID, to: f.boardID, near: .zero, actor: f.actor) else {
          throw NotebookStorageError.invalidTransaction("fixture placement")
        }
        try f.store.saveWorkspaceBundle(index: index, page: created.page, board: board)
      } else {
        try f.store.commandTransaction {
          let admission = try f.store.makePageAppendAdmission(itemID: f.neighbor, pageID: pageID, actor: f.actor, human: true)
          try f.store.publishPageAppend(page: .init(id: pageID, size: f.content.size, actor: f.actor), admission: admission, human: true)
        }
      }
    }
    #expect(try f.store.ownerItemID(ofPage: pageID) == nil)
    #expect(try f.store.readItemHeader(newItemID) == nil)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func aReceivedCausalFieldAloneDoesNotAuthorizeAnArbitraryOrphanPage() throws {
    let f = try Fixture(), pageID = UUID(), peer = UUID()
    let key = fieldKey(["items", f.content.itemID.uuidString.lowercased(), "pageIDs", pageID.uuidString.lowercased()])
    let address = "workspace.json#/collaboration/fields/@" + fieldKey([key])
    let stamp = try #require(try f.store.workspaceHeader().stamp.advanced(by: peer))
    let field = NotebookStoredFragment(address: address, file: "workspace.json", parent: "workspace.json#",
      collection: "collaboration/fields", member: key, position: 0,
      value: try .encode(ContentFieldVersion(stamp: stamp, human: true)), collections: [])
    let workspace = try #require(try f.store.storedFragments(address: "workspace.json#", descendants: false).first)
    // An independently received causal tombstone need not be invalid. Its name
    // nevertheless proves neither an admitted page birth nor a source owner.
    let metadata = try f.packet([workspace, field], sequence: 1)
    #expect(try f.store.missingBlobHashes(for: metadata).isEmpty)
    _ = try f.store.applyRemoteChange(metadata, peerID: peer)
    #expect(try !f.store.storedFragments(address: address, descendants: false).isEmpty)

    var orphan = PageDocument(id: pageID, size: f.content.size, actor: peer)
    let replaced = orphan.replaceElements([.init(id: "phantom", kind: .markdown,
      frame: .init(x: 0, y: 0, width: 100, height: 100), source: "Never admitted", html: "<p>Never admitted</p>")], actor: peer)
    #expect(replaced)
    let page = try f.packet(NotebookRecordCodec.encode(.encode(orphan.materializingCausalVersions()), file: pageFile(pageID)), sequence: 2)
    #expect(try f.store.missingBlobHashes(for: page).isEmpty)
    // Refusing this payload or acknowledging it without allocating a source
    // are both safe. Do not demand that all causal tombstones be rejected.
    do { _ = try f.store.applyRemoteChange(page, peerID: peer) }
    catch is NotebookStorageError { }
    #expect(try f.store.ownerItemID(ofPage: pageID) == nil)
    #expect(try !f.store.hasStoredValue(pageFile(pageID)), "A field-name claim cannot allocate a retained PAGE owner")
    #expect(throws: (any Error).self) { _ = try f.store.loadPage(pageID) }
    #expect(throws: (any Error).self) { _ = try f.store.readContentHeader(target: .init(kind: .page, id: pageID)) }
    #expect(throws: (any Error).self) { _ = try f.store.savePage(orphan) }
  }

  @Test func admissionAddsOnlyTheDerivedIndexAndReservationUsesAPointSeek() throws {
    let f = try Fixture(), cursor = try f.store.currentChangeCursor()
    let header = try f.store.workspaceHeader()
    try f.store.commandTransaction {
      try f.store.currentSQL!.run("DROP INDEX record_page_births")
      try f.store.currentSQL!.run("PRAGMA user_version=8")
    }
    let reopened = NotebookStore(root: f.store.root)
    #expect(try reopened.workspaceHeader() == header)
    #expect(try reopened.currentChangeCursor() == cursor)
    let plan = try reopened.sqlRead { database in
      try database.rows("EXPLAIN QUERY PLAN " + NotebookStore.pageBirthReservationQuery,
        [.text(f.content.pageID.uuidString.lowercased())]).compactMap { $0.last?.text }.joined(separator: " ")
    }
    #expect(plan.contains("SEARCH records USING INDEX record_page_births"))
    #expect(!plan.contains("SCAN records"), "A reservation lookup cannot scan every historical membership field")
    #expect(throws: (any Error).self) { try reopened.requireUnreservedPageID(f.content.pageID) }
    try reopened.requireUnreservedPageID(UUID())
  }
  @Test func aFreshSnapshotAdmitsTheHiddenTypedSourceWithoutResurrectingItsNotebook() throws {
    let f = try Fixture(), pageID = f.content.pageID
    try f.content.write(pageID, text: "SnapshotRetainedSource")
    try f.store.commandTransaction {
      try f.store.deleteWorkspaceItemContent(itemID: f.content.itemID, actor: f.actor, human: false)
    }
    let peerID = UUID(), peer = NotebookStore(root: f.store.root.appendingPathComponent("snapshot-peer"))
    try peer.prepareEmptyWorkspace(workspaceID: f.store.workspaceHeader().workspaceID)
    let snapshot = try f.store.commandTransaction(advancesReadRevision: false) {
      try f.store.cloudSnapshot(source: .init(deviceID: peerID, generation: peerID))
    }
    var complete = false
    for _ in 0..<64 {
      let missing = try peer.missingBlobHashes(for: snapshot.change)
      if missing.isEmpty { complete = true; break }
      for hash in missing {
        let size = try f.store.blobSize(hash: hash)
        var bytes = Data()
        while Int64(bytes.count) < size {
          bytes += try f.store.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576)
        }
        try peer.stageBlob(data: bytes, expectedHash: hash)
      }
    }
    #expect(complete)
    _ = try peer.applyDelivery(snapshot)
    for store in [peer, NotebookStore(root: peer.root)] {
      #expect(try store.readItemHeader(f.content.itemID) == nil)
      #expect(try store.ownerItemID(ofPage: pageID) == nil)
      #expect(try store.pageSourceOwnerID(ofPage: pageID) == f.content.itemID)
      #expect(throws: (any Error).self) { _ = try store.loadPage(pageID) }
      #expect(try store.search("SnapshotRetainedSource").total == 0)
      try store.commandTransaction { _ = try store.requireRetiredPageBaseline(pageID: pageID, itemID: f.content.itemID) }
    }
  }

  @Test(arguments: [false, true])
  func aFullRetiredBaselineRequiresOneAdmissionAndValidTypedContent(splitBeforePage: Bool) throws {
    let f = try Fixture(), pageID = f.content.pageID, file = pageFile(pageID)
    try f.content.write(pageID, text: "Admitted only with birth closure")
    try f.store.commandTransaction {
      try f.store.deleteWorkspaceItemContent(itemID: f.content.itemID, actor: f.actor, human: false)
    }
    let rows: [NotebookStoredFragment] = try f.store.readTransaction { store in
      try store.currentSQL!.rows("SELECT address,file FROM records ORDER BY address").compactMap { row in
        guard !NotebookStore.localRecord(row[1].text!) else { return nil }
        return try store.storedFragments(address: row[0].text!, descendants: false).first
      }
    }
    let roots = try Set(rows.filter { $0.collection == "pageOrders" }.flatMap { row in
      let order = try row.value.decode(NotebookPageOrderRegister.self)
      return order.heads.map(\.valueRoot) + [order.visibleRoot]
    }).sorted()
    let peerID = UUID(), peer = NotebookStore(root: f.store.root.appendingPathComponent("admission-peer"))
    try peer.prepareEmptyWorkspace(workspaceID: f.store.workspaceHeader().workspaceID)
    func transfer(_ change: NotebookDurableChange) throws {
      for _ in 0..<64 {
        let missing = try peer.missingBlobHashes(for: change)
        if missing.isEmpty { return }
        for hash in missing {
          let size = try f.store.blobSize(hash: hash)
          var bytes = Data()
          while Int64(bytes.count) < size {
            bytes += try f.store.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576)
          }
          try peer.stageBlob(data: bytes, expectedHash: hash)
        }
      }
      throw NotebookStorageError.invalidTransaction("fixture source dependencies")
    }
    if splitBeforePage {
      // This is stronger than a causal field alone: the native retired typed
      // order and every birth field are accepted, but there is still no PAGE.
      let metadata = try f.packet(rows.filter { $0.file != file }, sequence: 1, pageOrderRoots: roots)
      try transfer(metadata)
      _ = try peer.applyRemoteChange(metadata, peerID: peerID)
      #expect(try peer.retiredNotebookMembership(ofPage: pageID)?.itemID == f.content.itemID)
      #expect(try peer.pageSourceOwnerID(ofPage: pageID) == nil)
      let page = try f.packet(rows.filter { $0.file == file }, sequence: 2)
      try transfer(page)
      _ = try peer.applyRemoteChange(page, peerID: peerID)
      #expect(try peer.peerCursor(peerID: peerID, direction: .incoming) == 2)
    } else {
      // Hashes are internally consistent; it is the native typed source that
      // is malformed. Complete birth closure does not bypass semantic checks.
      let malformed = rows.map { row in
        row.address == file + "#/elements/@label"
          ? row.replacing(value: row.value.setting("frame", .object([
              "x": .number(0), "y": .number(0), "width": .number(-1), "height": .number(100)])))
          : row
      }
      let packet = try f.packet(malformed, sequence: 1, pageOrderRoots: roots)
      try transfer(packet)
      #expect(throws: (any Error).self) { _ = try peer.applyRemoteChange(packet, peerID: peerID) }
      #expect(try peer.peerCursor(peerID: peerID, direction: .incoming) == 0)
    }
    #expect(try !peer.hasStoredValue(file))
    #expect(try peer.pageSourceOwnerID(ofPage: pageID) == nil)
    #expect(throws: (any Error).self) { _ = try peer.loadPage(pageID) }
  }

}
