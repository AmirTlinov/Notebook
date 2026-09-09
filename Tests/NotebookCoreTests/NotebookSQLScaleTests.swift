import Foundation
import Testing
@testable import NotebookCore

private func readScaleManifest(_ change: NotebookDurableChange, from store: NotebookStore) throws -> NotebookChangeManifest {
  guard (1...67_108_864).contains(change.byteCount) else { throw NotebookStorageError.limitExceeded("scale_manifest_bytes") }
  return try store.readTransaction { store in
    guard try store.blobSize(hash: change.manifestHash) == Int64(change.byteCount) else {
      throw NotebookStorageError.invalidTransaction("scale manifest byte count")
    }
    var data = Data(); data.reserveCapacity(change.byteCount)
    while data.count < change.byteCount {
      let count = min(1_048_576, change.byteCount - data.count)
      let chunk = try store.readBlobChunk(hash: change.manifestHash, offset: Int64(data.count), maxBytes: count)
      guard chunk.count == count else { throw NotebookStorageError.invalidTransaction("scale manifest chunk length") }
      data.append(chunk)
    }
    return try JSONDecoder().decode(NotebookChangeManifest.self, from: data)
  }
}

@Suite("Addressed SQL catalogue at product scale", .serialized)
struct NotebookSQLScaleTests {
  @Test func aScaleManifestUsesEveryChunkAndRejectsInexactOrOverbudgetLengths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-manifest-chunks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 100, height: 140))
    let manifest = NotebookChangeManifest(transactionID: UUID(), workspaceID: header.workspaceID,
      records: [.init(address: "workspace.json#", blobHash: nil)],
      pageOrderRoots: (0..<20_000).map { String(format: "%064x", $0) })
    let data = try NotebookStore.storageEncoder.encode(manifest)
    let hash = try store.commandTransaction { try store.currentSQL!.putBlob(data) }
    func change(_ byteCount: Int) -> NotebookDurableChange {
      .init(sequence: 1, transactionID: manifest.transactionID, manifestHash: hash, byteCount: byteCount)
    }
    #expect(data.count > 1_048_576)
    #expect(try readScaleManifest(change(data.count), from: store) == manifest)
    for length in [data.count - 1, data.count + 1] {
      #expect(throws: NotebookStorageError.invalidTransaction("scale manifest byte count")) {
        try readScaleManifest(change(length), from: store)
      }
    }
    for length in [-1, 0, 67_108_865] {
      #expect(throws: NotebookStorageError.limitExceeded("scale_manifest_bytes")) {
        try readScaleManifest(change(length), from: store)
      }
    }
  }

  @Test func oneHundredThousandOwnersKeepAnEditAndItsJournalAddressed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-sql-scale-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor)
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let initial = try store.loadIndex(), firstID = initial.items[0].id
    let boardAddress = "board.json#/boards/@" + header.rootBoardID.uuidString.lowercased()
    let started = ContinuousClock.now
    let seed = NotebookStore(root: root) { phase in
      print("CATALOG_SCALE_PHASE phase=\(phase) elapsed=\(started.duration(to: .now))")
    }
    // The scale fixture streams through the same single row writer in one
    // command; it does not retain 100000 page documents in the test process.
    try seed.commandTransaction {
      let database = store.currentSQL!
      for offset in 1..<100_000 {
        let id = UUID(), page = UUID(), itemAddress = "workspace.json#/items/@" + id.uuidString.lowercased()
        try store.writeFragment(.init(address: itemAddress, file: "workspace.json", parent: "workspace.json#", collection: "items", member: id.uuidString.lowercased(), position: offset,
          value: .object(["id": .string(id.uuidString), "kind": .string("notebook"), "title": .string("Notebook \(offset)")]), collections: [.init(path: ["pageIDs"], kind: .array)]), database: database)
        try store.writeFragment(.init(address: itemAddress + "/pageIDs/@" + page.uuidString.lowercased(), file: "workspace.json", parent: itemAddress, collection: "pageIDs", member: page.uuidString.lowercased(), position: 0, value: .string(page.uuidString), collections: []), database: database)
        try store.savePage(PageDocument(id: page, size: .init(width: 834, height: 1194), actor: actor))
        let valueRoot = try NotebookPageOrderVector.build([page], write: { try store.writePageOrderNode($0) })
        try store.writePageOrder(.authored(root: valueRoot, stamp: stamp, human: true, previous: nil), itemID: id)
        let owner = id.uuidString.lowercased(), version = try JSONValue.encode(ContentFieldVersion(stamp: stamp, human: true))
        let fields = ["exists", "title", "kind", "pageIDs"].map { fieldKey(["items", owner, $0]) }
          + [fieldKey(["items", owner, "pageIDs", page.uuidString.lowercased()])]
        for key in fields {
          try store.writeFragment(.init(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]),
            file: "workspace.json", parent: "workspace.json#", collection: "collaboration/fields", member: key,
            position: 0, value: version, collections: []), database: database)
        }
        // Half the distant archive shares X=0 with the query; the other half
        // shares Y=0. Both signs must be skipped by the two-axis SQL index.
        let distance = Double(offset + 1) * 5_000
        let center: WorldPoint
        switch offset % 4 {
        case 0: center = .init(x: 0, y: distance)
        case 1: center = .init(x: 0, y: -distance)
        case 2: center = .init(x: distance, y: 0)
        default: center = .init(x: -distance, y: 0)
        }
        let placement = FreeItemPlacement(itemID: id, center: center, zIndex: offset, stamp: stamp)
        try store.writeFragment(.init(address: boardAddress + "/board/freeItems/@" + id.uuidString.lowercased(), file: "board.json", parent: boardAddress, collection: "board/freeItems", member: id.uuidString.lowercased(), position: offset, value: try .encode(placement), collections: []), database: database)
      }
      print("CATALOG_SCALE_PHASE phase=rows_completed elapsed=\(started.duration(to: .now))")
    }
    let counts = try store.sqlRead { database in
      try ["SELECT count(*) FROM records",
        "SELECT count(*) FROM records WHERE parent='workspace.json#' AND collection='collaboration/fields'",
        "SELECT count(*) FROM records WHERE parent='workspace.json#' AND collection='pageOrders'",
        "SELECT count(*) FROM records WHERE parent='workspace.json#' AND collection='pageOrderNodes'"].map {
          try database.rows($0).first![0].integer!
        }
    }
    print("CATALOG_SCALE_ROWS records=\(counts[0]) causal_fields=\(counts[1]) order_registers=\(counts[2]) order_nodes=\(counts[3])")
    let full = try store.workspaceHeader()
    #expect(full.itemCount == 100_000)
    let initialChange = try #require(try store.changeJournal(after: header.cursor).first)
    let manifest = try readScaleManifest(initialChange, from: store)
    print("CATALOG_SCALE_PHASE phase=manifest_decoded elapsed=\(started.duration(to: .now)) manifest_bytes=\(initialChange.byteCount)")
    #expect(manifest.records.isEmpty)
    #expect(manifest.parts.count > 1)
    for hash in manifest.parts { #expect(try store.blobSize(hash: hash) < 67_108_864) }
    let window = try store.readSceneWindow(boardID: header.rootBoardID, bounds: .init(origin: .init(x: -500, y: -700), width: 1000, height: 1400), limit: 32, pinnedIDs: [firstID])
    print("CATALOG_SCALE_PHASE phase=window_read elapsed=\(started.duration(to: .now))")
    #expect(window.items.map(\.id) == [firstID])
    let projection = BoardHierarchy(rootBoardID: header.rootBoardID, boards: window.boards, stamp: full.boardStamp!)
    var moved = projection
    let changed = moved.moveItem(firstID, in: header.rootBoardID, to: .init(x: -100, y: 20), actor: actor)
    #expect(changed)
    _ = try store.saveBoardEdits(before: projection, after: moved)
    #expect(try store.workspaceHeader().itemCount == 100_000)
    #expect(try store.workspaceHeader().boardRevision != full.boardRevision)
    let changes = try store.changeJournal(after: full.cursor)
    #expect(changes.count == 1)
    let delta = try readScaleManifest(changes[0], from: store)
    #expect(delta.parts.isEmpty)
    #expect(delta.records.count < 64)
    #expect(delta.records.allSatisfy { $0.address.hasPrefix("board.json#") })
    #expect(try store.readWorkingSet(itemIDs: [firstID], pageIDs: [initial.items[0].pageIDs[0]], boardIDs: [header.rootBoardID], surfaces: []).pages.count == 1)

    let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let request = CollaborationPlacementRequest(target: target, expectedRevision: try store.targetContentRevision(target: target),
      items: [.init(id: "scale-proposal", size: .init(width: 100, height: 80))], worldOrigin: .zero)
    let budget = NotebookPlacementBudget()
    let cut = try store.readPlacement(request, budget: budget)
    #expect(budget.inspectedObstacles == 1)
    #expect(budget.sqlSteps > 0 && budget.sqlSteps < 50_000)
    #expect(try cut.sourceRevision == store.referenceRevision(target: target))
    let pending = try store.suggestCollaborationPlacement(request)
    #expect(pending.status == .snapshotPending)
    let render = try #require(pending.renderRequest)
    try JSONEncoder().encode(TargetRenderReceipt(request: render, status: "ready")).write(to: store.targetReceiptURL(render.id), options: .atomic)
    let planned = try store.suggestCollaborationPlacement(request)
    let size = WorkspaceItemGeometry.notebook
    let expected = NotebookStore.freeCollaborationFrame(size: .init(width: 100, height: 80), extent: .init(width: 2048, height: 2048),
      anchor: .init(x: 20, y: 20, width: 1, height: 1), direction: "free", obstacles: [
        .init(x: -100 - size.width / 2, y: 20 - size.height / 2, width: size.width, height: size.height)])
    #expect(planned.status == .ready && planned.placements.first?.frame == expected)
    print("PLACEMENT_SCALE owners=100000 inspected=\(budget.inspectedObstacles) sql_vm_steps=\(budget.sqlSteps)")
    print("CATALOG_SCALE_PHASE phase=addressed_checks_completed elapsed=\(started.duration(to: .now))")
  }
}
