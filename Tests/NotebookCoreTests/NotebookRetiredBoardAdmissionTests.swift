import Foundation
import Testing
@testable import NotebookCore

@Suite("Retired board admission uses the final catalogue cut", .serialized)
struct NotebookRetiredBoardAdmissionTests {
  private final class Fixture {
    let content: NotebookItemLifecycleTests.Fixture
    var store: NotebookStore { content.store }
    let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let actor = UUID(), peerID = UUID()
    let parent: UUID

    init() throws {
      content = try NotebookItemLifecycleTests.Fixture()
      let before = try content.store.loadIndex(), tree = try content.store.loadBoard(items: before.items)
      parent = before.rootBoardID
      #expect(id.uuidString.lowercased() < parent.uuidString.lowercased())
      var after = before, next = tree
      let created = after.createBoard(title: "Earlier addressed child", actor: actor, boardID: id)
      #expect(created != nil)
      let placed = next.createBoard(id, in: parent, near: .zero, actor: actor)
      #expect(placed)
      _ = try store.saveWorkspaceEdits(before: before, after: after, boardBefore: tree, boardAfter: next)
    }

    func stage(_ change: NotebookDurableChange, into peer: NotebookStore) throws {
      for _ in 0..<64 {
        let missing = try peer.missingBlobHashes(for: change)
        if missing.isEmpty { return }
        for hash in missing {
          let count = try store.blobSize(hash: hash); var bytes = Data()
          while Int64(bytes.count) < count {
            bytes += try store.readBlobChunk(hash: hash, offset: Int64(bytes.count), maxBytes: 1_048_576)
          }
          try peer.stageBlob(data: bytes, expectedHash: hash)
        }
      }
      throw NotebookStorageError.invalidTransaction("retired board fixture closure")
    }

    func retire() throws { _ = try store.deleteWorkspaceItem(itemID: id, actor: actor) }

    func spans(_ board: UUID) -> [SpatialInkSpan] {
      [.init(surface: .board(board), samples: [.init(point: .init(x: 10, y: 20),
        worldPoint: .init(x: 10, y: 20), timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])]
    }

    func retainedInk() throws -> SpatialInkJournal {
      var ink = try store.loadSpatialInk()
      let appended = ink.append(tool: .pen, spans: spans(id), actor: actor)
      let stroke = try #require(appended)
      let deactivated = ink.deactivate(stroke.id, actor: actor)
      #expect(deactivated)
      try store.saveSpatialInk(ink)
      try retire()
      return try store.loadSpatialInk()
    }
  }

  @Test func deletionSnapshotCanVisitTheChildBeforeItsParentTombstoneOnAnExistingPeer() throws {
    let f = try Fixture(), peer = NotebookStore(root: f.store.root.appendingPathComponent("snapshot-receiver"))
    try peer.prepareEmptyWorkspace(workspaceID: f.store.workspaceHeader().workspaceID)
    for change in try f.store.changeJournal(after: 0) {
      try f.stage(change, into: peer)
      _ = try peer.applyRemoteChange(change, peerID: f.peerID, generation: f.peerID)
    }
    #expect(try peer.ownerBoardID(of: f.id) == f.parent)
    let node = try #require(try peer.readBoardNode(f.id))
    try f.retire()
    let snapshot = try f.store.commandTransaction(advancesReadRevision: false) {
      try f.store.cloudSnapshot(source: .init(deviceID: f.peerID, generation: f.peerID))
    }
    try f.stage(snapshot.change, into: peer)
    _ = try peer.applyDelivery(snapshot)
    #expect(try peer.peerCursor(peerID: f.peerID, direction: .incoming) == snapshot.change.sequence)
    for store in [peer, NotebookStore(root: peer.root)] {
      #expect(try store.readItemHeader(f.id) == nil)
      #expect(try store.readBoardNode(f.id) == nil)
      #expect(try store.ownerBoardID(of: f.id) == nil)
      let baseline = try store.requireRetiredBoardBaseline(itemID: f.id)
      #expect(try store.boardSourceHeader(baseline, id: f.id).portalCamera == node.portalCamera)
    }
  }

  @Test(arguments: ["append", "reactivate", "remove"])
  func bulkInkPublicationCannotMutateRetainedBoardHistory(mutation: String) throws {
    let f = try Fixture(), before = try f.retainedInk()
    let cursor = try f.store.currentChangeCursor()
    var after = before
    switch mutation {
    case "append":
      let added = after.append(tool: .pen, spans: f.spans(f.id), actor: f.actor)
      #expect(added != nil)
    case "reactivate":
      var action = try #require(before.actions.first)
      let activated = action.setActive(true, actor: f.actor)
      #expect(activated)
      after = .init(actions: [action], stamp: action.stateStamp)
    default:
      after = .init(stamp: try #require(before.stamp.advanced(by: f.actor)))
    }
    #expect(throws: (any Error).self) { try f.store.saveSpatialInk(after) }
    #expect(try f.store.loadSpatialInk() == before)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func bulkLiveInkPublicationRetainsUnchangedHiddenHistory() throws {
    let f = try Fixture(), before = try f.retainedInk()
    let hidden = try #require(before.actions.first)
    var after = before
    let appended = after.append(tool: .pen, spans: f.spans(f.parent), actor: f.actor)
    let added = try #require(appended)
    try f.store.saveSpatialInk(after)
    let saved = try f.store.loadSpatialInk()
    #expect(saved.actions.first { $0.id == hidden.id } == hidden)
    #expect(saved.actions.first { $0.id == added.id } == added)
    #expect(try f.store.readBoardNode(f.id) == nil)
  }
}
