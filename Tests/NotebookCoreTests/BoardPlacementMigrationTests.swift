import Foundation
import Testing
@testable import NotebookCore

@Suite("One explicit current-data placement migration")
struct BoardPlacementMigrationTests {
  private func versionTwo(_ board: BoardDocument) throws -> JSONValue {
    .object(["format": .number(2), "freeItems": try .encode(board.freeItems),
      "stacks": try .encode(board.stacks), "elements": try .encode(board.elements),
      "stamp": try .encode(board.stamp), "collaboration": try board.collaboration.map(JSONValue.encode) ?? .null])
  }

  /// Only a test fixture writes pre-upgrade rows directly. Production never
  /// decodes or publishes this structure except at the explicit migration cut.
  private func installStoredVersionTwo(_ store: NotebookStore) throws -> JSONValue {
    let hierarchy = try store.loadBoard(items: store.loadIndex().items)
    let value = try JSONValue.encode(hierarchy).setting("boards", .array(hierarchy.boards.map { node in
      try JSONValue.encode(node).setting("board", versionTwo(node.board))
    }))
    var fragments: [NotebookStoredFragment] = []
    for row in try NotebookRecordCodec.encode(value, file: "board.json") {
      guard row.collection == "boards" else { fragments.append(row); continue }
      var header = row.value, collections = row.collections
      for name in ["freeItems", "stacks"] {
        let members = header["board"]?[name]?.array ?? []
        header = header.setting("board", header["board"]!.setting(name, nil))
        collections.append(.init(path: ["board", name], kind: .array))
        for (position, member) in members.enumerated() {
          let id = try #require(member.memberIdentity)
          fragments.append(.init(address: row.address + "/board/" + name + "/@" + id,
            file: "board.json", parent: row.address, collection: "board/" + name,
            member: id, position: position, value: member, collections: []))
        }
      }
      fragments.append(.init(address: row.address, file: row.file, parent: row.parent,
        collection: row.collection, member: row.member, position: row.position, value: header, collections: collections))
    }
    try store.commandTransaction {
      let db = store.currentSQL!
      for row in try db.rows("SELECT address,hash FROM records WHERE file='board.json'") {
        try store.updateBoardContribution(address: row[0].text!, previous: row[1].text, next: nil, database: db)
        try store.noteReferenceChange(row[0].text!, file: "board.json", database: db)
      }
      try db.run("DELETE FROM records WHERE file='board.json'")
      for row in fragments {
        let hash = try db.putBlob(NotebookStore.storageEncoder.encode(row))
        try db.run("INSERT INTO records(address,file,parent,collection,member,position,hash) VALUES(?,?,?,?,?,?,?)", [
          .text(row.address), .text(row.file), row.parent.map(NotebookSQLValue.text) ?? .null,
          .text(row.collection), .text(row.member), .integer(Int64(row.position)), .text(hash)])
        try store.updateBoardContribution(address: row.address, previous: nil, next: hash, database: db)
        if ["boards", "board/freeItems", "board/stacks", "board/elements"].contains(row.collection) {
          try db.noteOwner(.referenceRoot, row.address)
        }
      }
    }
    return value
  }

  @Test func normalOpenConvertsOnceAndRetainsContentsCursorsAndImmutableBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), peer = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let before = try store.collaborationContent(), cursor = try store.currentChangeCursor()
    let manifest = try #require(try store.changeJournal(after: 0).first)
    let bytes = try store.readBlobChunk(hash: manifest.manifestHash, offset: 0, maxBytes: 1_048_576)
    try store.acknowledgePeer(peerID: peer, through: cursor)
    let legacy = try installStoredVersionTwo(store)
    let reopened = NotebookStore(root: root)
    #expect(try reopened.loadIndex() == before.workspace)
    let receipt = try #require(try reopened.migrateBoardPlacements())
    #expect(receipt.sourceCursor == cursor)
    #expect(try receipt.sourceHash == collaborationHash(legacy))
    let board = try reopened.loadBoard(items: before.workspace.items)
    #expect(board.boards.allSatisfy { $0.board.format == 3 })
    #expect(board.board(header.rootBoardID)?.freeItems == before.hierarchy.board(header.rootBoardID)?.freeItems)
    #expect(try reopened.loadPage(before.workspace.selectedPageID!) == before.pages.first { $0.id == before.workspace.selectedPageID! })
    #expect(try reopened.peerCursor(peerID: peer, direction: .outgoing) == cursor)
    #expect(try reopened.readBlobChunk(hash: manifest.manifestHash, offset: 0, maxBytes: 1_048_576) == bytes)
    let next = try reopened.currentChangeCursor()
    #expect(next == cursor + 1)
    #expect(try reopened.migrateBoardPlacements() == receipt)
    #expect(try reopened.currentChangeCursor() == next)
    let oldRows = try reopened.sqlRead { try $0.rows("SELECT address FROM records WHERE file='board.json' AND (collection IN ('board/freeItems','board/stacks') OR member LIKE 'freeItems/%' OR member LIKE 'stacks/%')") }
    #expect(oldRows.isEmpty)
    #expect(try reopened.readBoardItem(before.workspace.items[0].id)?.board.itemIDs == [before.workspace.items[0].id])
    #expect(throws: CollaborationError.self) { _ = try reopened.changeJournal(after: 0) }
    #expect(try reopened.changeJournal(after: cursor).count == 1)
    let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let files = try reopened.collaborationContent().sourceFiles()
    #expect(try reopened.referenceRevision(target: target) == NotebookStore.referenceRevision(target: target, files: files))
    #expect(try receipt.resultHash == collaborationHash(try #require(try reopened.storedValue("board.json"))))
    let orphaned = try reopened.sqlRead { try $0.rows("SELECT 1 FROM reference_contributions WHERE address LIKE '%/board/freeItems/%' OR address LIKE '%/board/stacks/%'") }
    #expect(orphaned.isEmpty)
  }

  @Test func anUnacknowledgedPeerBlocksAdmissionWithoutPartiallyMigrating() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), peer = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try store.acknowledgePeer(peerID: peer, through: 0)
    _ = try installStoredVersionTwo(store)
    do { _ = try store.migrateBoardPlacements(); Issue.record("Missing peer content was skipped") }
    catch let error as CollaborationError { #expect(error.code == "placement_migration_pending_peer") }
    let db = try NotebookSQLConnection(url: store.databaseURL, writable: false)
    #expect(try db.rows("SELECT json_extract(CAST(b.data AS TEXT),'$.value.board.format') FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.collection='boards'").first?[0].integer == 2)
    #expect(try db.rows("SELECT 1 FROM records WHERE file='local/migrations/board-placements-v3.json'").isEmpty)
    #expect(try db.rows("SELECT MAX(sequence) FROM change_log").first?[0].integer == 1)
  }

  @Test func equalOldJoinedFieldsDoNotGiveDifferentGeometryTheSameAuthoredDot() throws {
    let actor = UUID(), unrelated = UUID(), item = UUID()
    let shared = ContentFieldVersion(stamp: .init(counter: 1, actor: unrelated), human: true,
      observed: [actor.uuidString.lowercased(): 1, unrelated.uuidString.lowercased(): 1])
    let fields = CollaborativeContent(fields: Dictionary(uniqueKeysWithValues: ["exists", "center", "zIndex", "stamp"].map {
      (fieldKey(["freeItems", item.uuidString.lowercased(), $0]), shared)
    }))
    func source(counter: UInt64, center: WorldPoint) throws -> JSONValue {
      .object(["format": .number(2), "freeItems": try .encode([FreeItemPlacement(itemID: item, center: center,
        zIndex: Int(counter), stamp: .init(counter: counter, actor: actor))]), "stacks": .array([]), "elements": .array([]),
        "stamp": try .encode(VersionStamp(counter: 1, actor: unrelated)), "collaboration": try .encode(fields)])
    }
    let original = try source(counter: 0, center: .zero)
    let accepted = try source(counter: 1, center: .init(x: -500, y: -522))
    var a = try BoardDocument.migratingStoredVersionTwo(original)
    var b = try BoardDocument.migratingStoredVersionTwo(accepted)
    let oldA = a, oldB = b
    _ = try a.merge(oldB, itemIDs: [item]); _ = try b.merge(oldA, itemIDs: [item])
    #expect(a == b)
    #expect(a.freeItems[0].center == .init(x: -500, y: -522))
    #expect(a.placements[0].heads.count == 1)
    #expect(a.placements[0].stamp == .init(counter: 1, actor: actor))
    #expect(throws: CollaborationError.self) {
      _ = try NotebookStore.referenceRevision(target: .init(kind: .board, id: WorkspaceRoot.boardID), files: [
        "workspace.json": .object([:]), "board.json": .object(["boards": .array([
          .object(["id": .string(WorkspaceRoot.boardID.uuidString), "board": original])])])])
    }
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit])
  func anInterruptedMigrationLeavesTheOriginalRowsAndDeliveryCutIntact(fault: NotebookStorageFault) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    _ = try installStoredVersionTwo(store)
    func identities() throws -> [String] {
      let db = try NotebookSQLConnection(url: store.databaseURL, writable: false)
      return try db.rows("SELECT address||':'||hash FROM records ORDER BY address").compactMap { $0[0].text }
    }
    let before = try identities()
    let interrupted = NotebookStore(root: root) { point in if point == fault { throw CocoaError(.fileWriteUnknown) } }
    #expect(throws: (any Error).self) { _ = try interrupted.migrateBoardPlacements() }
    #expect(try identities() == before)
    let migrated = try #require(try store.migrateBoardPlacements())
    #expect(migrated.sourceCursor == 1)
    #expect(try store.currentChangeCursor() == 2)
  }

  @Test func deletingTheLastChildDoesNotMakeItsPlacementTombstoneHoldAnEmptyBoard() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), tree = try store.loadBoard(items: index.items)
    let createdBoard = index.createBoard(title: "Empty again", actor: actor)
    let child = try #require(createdBoard)
    let created = tree.createBoard(child.id, in: header.rootBoardID, near: .zero, actor: actor)
    #expect(created)
    try store.saveBoardWorkspaceBundle(index: index, board: tree, boardID: child.id)
    let createdNotebook = index.createNotebook(title: "Remove", actor: actor, pageSize: .init(width: 834, height: 1194))
    let nested = try #require(createdNotebook)
    let added = tree.addItem(nested.item.id, to: child.id, near: .zero, actor: actor)
    #expect(added)
    try store.saveWorkspaceBundle(index: index, page: nested.page, board: tree)
    _ = try store.deleteWorkspaceItem(itemID: nested.item.id, actor: actor)
    let old = try #require(try store.loadBoard(items: store.loadIndex().items).board(child.id))
    #expect(old.itemIDs.isEmpty)
    #expect(old.placements.count == 1 && old.placements[0].pose == nil)
    _ = try store.deleteWorkspaceItem(itemID: child.id, actor: actor)
    #expect(try store.readBoardNodeHeader(child.id) == nil)
    #expect(try store.loadBoard(items: store.loadIndex().items).isValid(items: store.loadIndex().items))
  }

  @Test func anOldPartialManifestIsRejectedBeforeCursorOrContentChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), peer = UUID()
    let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let tx = UUID(), old = try JSONValue.encode(NotebookChangeManifest(transactionID: tx, workspaceID: header.workspaceID,
      records: [.init(address: "board.json#/boards/@" + header.rootBoardID.uuidString.lowercased() + "/board/freeItems/@" + UUID().uuidString.lowercased(), blobHash: nil)])).setting("format", .number(3))
    let data = try NotebookStore.storageEncoder.encode(old), hash = try collaborationHash(old)
    try store.stageBlob(data: data, expectedHash: hash)
    let change = NotebookDurableChange(sequence: 1, transactionID: tx, manifestHash: hash, byteCount: data.count)
    let before = try store.workspaceHeader()
    do { _ = try store.applyRemoteChange(change, peerID: peer); Issue.record("An old partial packet was accepted") }
    catch let error as CollaborationError { #expect(error.code == "placement_peer_upgrade_required") }
    #expect(try store.workspaceHeader() == before)
    #expect(try store.peerCursor(peerID: peer, direction: .incoming) == 0)
  }

  @Test func aNewReplicaUsesACurrentSeedAndThenContinuesTheSameJournal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root.appendingPathComponent("source")), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try store.savePresence(.init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)))
    _ = try installStoredVersionTwo(store)
    _ = try store.migrateBoardPlacements()
    let cursor = try store.currentChangeCursor()
    let seedURL = root.appendingPathComponent("new-replica")
    _ = try store.prepareDeviceSnapshot(at: seedURL, presence: store.loadPresence(), preservingLocalState: false, resumingFrom: actor)
    let seed = NotebookStore(root: seedURL)
    #expect(try seed.peerCursor(peerID: actor, direction: .incoming) == cursor)
    let changes = try seed.changeJournal(after: 0)
    #expect(changes.count == 1)
    let manifest = try seed.commandTransaction { try seed.validatedManifest(changes[0]) }
    #expect(manifest.format == 4)
    #expect(try seed.loadBoard(items: seed.loadIndex().items) == store.loadBoard(items: store.loadIndex().items))
    _ = try seed.validateArchiveSnapshot()
    let item = try store.loadIndex().items[0].id
    let moved = try store.moveWorkspaceItem(itemID: item, in: store.workspaceHeader().rootBoardID,
      to: .init(x: 321, y: 654), actor: actor)
    #expect(moved)
    let delta = try #require(try store.changeJournal(after: cursor).first)
    while true {
      let missing = try seed.missingBlobHashes(for: delta)
      if missing.isEmpty { break }
      for hash in missing {
        var bytes = Data()
        let size = try store.blobSize(hash: hash)
        while Int64(bytes.count) < size {
          bytes += try store.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576)
        }
        try seed.stageBlob(data: bytes, expectedHash: hash)
      }
    }
    _ = try seed.applyRemoteChange(delta, peerID: actor)
    let committed = try seed.currentChangeCursor()
    _ = try seed.applyRemoteChange(delta, peerID: actor)
    #expect(try seed.currentChangeCursor() == committed)
    #expect(try seed.readBoardItem(item)?.board.placement(of: item)?.center == .init(x: 321, y: 654))
  }
}
