import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed SQL catalogue at product scale", .serialized)
struct NotebookSQLScaleTests {
  @Test func oneHundredThousandOwnersKeepAnEditAndItsJournalAddressed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-sql-scale-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), stamp = VersionStamp(counter: 0, actor: actor)
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let initial = try store.loadIndex(), firstID = initial.items[0].id
    let boardAddress = "board.json#/boards/@" + header.rootBoardID.uuidString.lowercased()
    // The scale fixture streams through the same single row writer in one
    // command; it does not retain 100000 page documents in the test process.
    try store.commandTransaction {
      let database = store.currentSQL!
      for offset in 1..<100_000 {
        let id = UUID(), page = UUID(), itemAddress = "workspace.json#/items/@" + id.uuidString.lowercased()
        try store.writeFragment(.init(address: itemAddress, file: "workspace.json", parent: "workspace.json#", collection: "items", member: id.uuidString.lowercased(), position: offset,
          value: .object(["id": .string(id.uuidString), "kind": .string("notebook"), "title": .string("Notebook \(offset)")]), collections: [.init(path: ["pageIDs"], kind: .array)]), database: database)
        try store.writeFragment(.init(address: itemAddress + "/pageIDs/@" + page.uuidString.lowercased(), file: "workspace.json", parent: itemAddress, collection: "pageIDs", member: page.uuidString.lowercased(), position: 0, value: .string(page.uuidString), collections: []), database: database)
        try store.savePage(PageDocument(id: page, size: .init(width: 834, height: 1194), actor: actor))
        let placement = FreeItemPlacement(itemID: id, center: .init(x: Double(offset % 1000) * 5000 + 5000, y: Double(offset / 1000) * 5000), zIndex: offset, stamp: stamp)
        try store.writeFragment(.init(address: boardAddress + "/board/freeItems/@" + id.uuidString.lowercased(), file: "board.json", parent: boardAddress, collection: "board/freeItems", member: id.uuidString.lowercased(), position: offset, value: try .encode(placement), collections: []), database: database)
      }
    }
    let full = try store.workspaceHeader()
    #expect(full.itemCount == 100_000)
    let initialChange = try #require(try store.changeJournal(after: header.cursor).first)
    let manifest = try JSONDecoder().decode(NotebookChangeManifest.self, from: store.readBlobChunk(hash: initialChange.manifestHash, offset: 0, maxBytes: 1_048_576))
    #expect(manifest.records.isEmpty)
    #expect(manifest.parts.count > 1)
    for hash in manifest.parts { #expect(try store.blobSize(hash: hash) < 67_108_864) }
    let window = try store.readSceneWindow(boardID: header.rootBoardID, bounds: .init(origin: .init(x: -500, y: -700), width: 1000, height: 1400), limit: 32, pinnedIDs: [firstID])
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
    let delta = try JSONDecoder().decode(NotebookChangeManifest.self, from: store.readBlobChunk(hash: changes[0].manifestHash, offset: 0, maxBytes: 1_048_576))
    #expect(delta.parts.isEmpty)
    #expect(delta.records.count < 64)
    #expect(delta.records.allSatisfy { $0.address.hasPrefix("board.json#") })
    #expect(try store.readWorkingSet(itemIDs: [firstID], pageIDs: [initial.items[0].pageIDs[0]], boardIDs: [header.rootBoardID], surfaces: []).pages.count == 1)
  }
}
