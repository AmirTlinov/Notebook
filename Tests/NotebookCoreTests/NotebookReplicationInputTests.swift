import Foundation
import Testing
@testable import NotebookCore

@Suite("Delivery protects only the admitted physical input owner")
struct NotebookReplicationInputTests {
  @Test func pageContentDoesNotLockItsBoardOrCover() throws {
    try fixture { a, b, source, header, item, page in
      let delivery = try editPage(a, source: source, page: page)
      try stage(delivery, a, b)
      let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
      let cover = CollaborationTarget(kind: .cover, id: item, boardID: header.rootBoardID)
      let before = try b.referenceIdentities(targets: [board, cover])
      #expect(try b.applyDelivery(delivery, protectingInputOn: [board, cover]) == delivery.change.sequence)
      #expect(try b.referenceIdentities(targets: [board, cover]) == before)
      #expect(try b.loadPage(page).elements.map(\.id) == ["incoming"])
    }
  }

  @Test func samePageRollsBackContentAndCursorThenAcceptsExactlyOnceAfterLift() throws {
    try fixture { a, b, source, _, _, page in
      let delivery = try editPage(a, source: source, page: page)
      try stage(delivery, a, b)
      let target = CollaborationTarget(kind: .page, id: page)
      let identity = try b.referenceIdentities(targets: [target])
      let cursor = try b.incomingCursor(source: source), revision = try b.currentReadCursor()
      do { try b.applyDelivery(delivery, protectingInputOn: [target]); Issue.record("An active surface was overwritten") }
      catch let error as CollaborationError { #expect(error.code == "input_active") }
      #expect(try b.loadPage(page).elements.isEmpty)
      #expect(try b.referenceIdentities(targets: [target]) == identity)
      #expect(try b.incomingCursor(source: source) == cursor)
      #expect(try b.currentReadCursor() == revision)
      #expect(try b.applyDelivery(delivery) == delivery.change.sequence)
      let accepted = try b.currentChangeCursor()
      #expect(try b.applyDelivery(delivery, protectingInputOn: [target]) == delivery.change.sequence,
        "A duplicate carries no material change and must not wait for another contact")
      #expect(try b.currentChangeCursor() == accepted)
      #expect(try b.loadPage(page).elements.map(\.id) == ["incoming"])
    }
  }

  @Test func movingTheActiveCoverProtectsItsBasisEvenWhenItsMaterialIsUnchanged() throws {
    try fixture { a, b, source, header, item, _ in
      let cover = CollaborationTarget(kind: .cover, id: item, boardID: header.rootBoardID)
      let identity = try a.referenceIdentities(targets: [cover])
      #expect(try moveTestItem(store: a, itemID: item, in: header.rootBoardID, to: .init(x: 380, y: 90), actor: source.deviceID))
      #expect(try a.referenceIdentities(targets: [cover]) == identity)
      let delivery = NotebookReplicationDelivery(source: source, change: try #require(a.changeJournal(after: header.cursor).first))
      try stage(delivery, a, b)
      do { try b.applyDelivery(delivery, protectingInputOn: [cover]); Issue.record("The active basis moved") }
      catch let error as CollaborationError { #expect(error.code == "input_active") }
      #expect(try b.incomingCursor(source: source) == header.cursor)
      #expect(try b.applyDelivery(delivery) == delivery.change.sequence)
    }
  }

  private func fixture(_ body: (NotebookStore, NotebookStore, NotebookReplicationSource, NotebookWorkspaceHeader, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = NotebookStore(root: root.appendingPathComponent("a")), b = NotebookStore(root: root.appendingPathComponent("b")), actor = UUID()
    let header = try a.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let item = try #require(a.loadIndex().items.first), page = try #require(item.pageIDs.first)
    try b.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let source = NotebookReplicationSource(deviceID: actor, generation: actor)
    try receiveFixtureChanges(from: a, to: b, peerID: actor)
    try body(a, b, source, header, item.id, page)
  }

  private func editPage(_ store: NotebookStore, source: NotebookReplicationSource, page: UUID) throws -> NotebookReplicationDelivery {
    let cursor = try store.currentChangeCursor()
    var value = try store.loadPage(page)
    let changed = value.replaceElements([.init(id: "incoming", kind: .graphic, frame: .init(x: 20, y: 30, width: 50, height: 60), source: "", html: "",
      graphic: .init(shape: .rectangle))], actor: source.deviceID)
    #expect(changed)
    _ = try store.savePage(value)
    return .init(source: source, change: try #require(store.changeJournal(after: cursor).first))
  }

  private func stage(_ delivery: NotebookReplicationDelivery, _ a: NotebookStore, _ b: NotebookStore) throws {
    while true {
      let hashes = try b.missingBlobHashes(for: delivery.change)
      if hashes.isEmpty { return }
      for hash in hashes {
        let size = try a.blobSize(hash: hash)
        try b.stageBlob(data: a.readBlobChunk(hash: hash, offset: 0, maxBytes: Int(size)), expectedHash: hash)
      }
    }
  }
}
