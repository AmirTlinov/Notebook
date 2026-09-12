import Foundation
import Testing
@testable import NotebookCore

@Suite("Accepted live geometry rebases the retained physical scene proof")
struct NotebookReferenceLiveSceneTests {
  private func fixture(_ body: (NotebookStore, UUID, WorkspaceIndex, BoardHierarchy) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var after = before
    for (offset, id) in ["passive-before", "live/a~b", "live-adjacent", "passive-after", "cover-note"].enumerated() {
      let cover = id == "cover-note"
      let element = SpatialElement(id: id, surface: cover ? .cover(workspace.selectedItemID) : .board(workspace.rootBoardID), kind: .nativeText,
        frame: .init(x: Double(offset * 100), y: 20, width: 90, height: 80), worldOrigin: cover ? nil : .zero,
        source: id, stamp: .init(counter: 0, actor: actor))
      let inserted = after.upsertElement(element, in: workspace.rootBoardID, expected: nil, actor: actor)
      #expect(inserted)
    }
    _ = try store.saveBoardEdits(before: before, after: after)
    try body(store, actor, workspace, after)
  }

  private func move(_ id: String, in hierarchy: inout BoardHierarchy, boardID: UUID, actor: UUID, x: Double, width: Double = 90) throws {
    let old = try #require(hierarchy.board(boardID)?.elements.first { $0.id == id })
    var next = old
    let updated = next.update(frame: .init(x: x, y: old.frame.y, width: width, height: old.frame.height), actor: actor)
    #expect(updated)
    let changed = hierarchy.upsertElement(next, in: boardID, expected: old.stamp, actor: actor)
    #expect(changed)
  }

  @Test func twoMovesResizeCoverMoveAndAdjacentDeletionSealAgainstOneOldBasis() throws {
    try fixture { store, actor, workspace, initial in
      let boardID = workspace.rootBoardID, item = workspace.selectedItemID
      let targets = [CollaborationTarget(kind: .board, id: boardID), .init(kind: .cover, id: item, boardID: boardID)]
      let basis = try store.referenceBasis(rootBoardID: boardID, targets: targets, surfaces: [.board(boardID)],
        liveOwners: [.element(boardID: boardID, id: "live/a~b"), .element(boardID: boardID, id: "live-adjacent"),
          .element(boardID: boardID, id: "cover-note"), .item(boardID: boardID, id: item)])
      var before = initial
      for x in [350.0, 520.0] {
        var after = before
        try move("live/a~b", in: &after, boardID: boardID, actor: actor, x: x, width: 140)
        try move("cover-note", in: &after, boardID: boardID, actor: actor, x: x / 2)
        let moved = after.moveItem(item, in: boardID, to: .init(x: x, y: 200), actor: actor)
        #expect(moved)
        let predicted = try basis.replacing(ink: [], workspace: workspace, hierarchy: after)
        _ = try store.saveBoardEdits(before: before, after: after)
        #expect(try predicted == store.referenceIdentities(targets: targets), "Header, item pose, board and cover elements must share one accepted cut")
        before = after
      }
      var removed = before
      let count = removed.removeElements(ids: ["live/a~b", "live-adjacent"], from: boardID, actor: actor)
      #expect(count == 2)
      _ = try store.saveBoardEdits(before: before, after: removed)
      #expect(try basis.replacing(ink: [], workspace: workspace, hierarchy: removed) == store.referenceIdentities(targets: targets),
        "One surviving predecessor bridges both deleted live order members")
      #expect(try store.workspaceHeader().cursor > basis.cursor)
    }
  }

  @Test func newHeaderAndUnseenPassiveChangeCannotForgeTheCurrentWholeScene() throws {
    try fixture { store, actor, workspace, initial in
      let boardID = workspace.rootBoardID, target = CollaborationTarget(kind: .board, id: boardID)
      let basis = try store.referenceBasis(rootBoardID: boardID, targets: [target], surfaces: [],
        liveOwners: [.element(boardID: boardID, id: "live/a~b")])
      var accepted = initial
      try move("live/a~b", in: &accepted, boardID: boardID, actor: actor, x: 320)
      _ = try store.saveBoardEdits(before: initial, after: accepted)
      #expect(try basis.replacing(ink: [], hierarchy: accepted) == store.referenceIdentities(targets: [target]))
      var incoming = accepted
      try move("passive-after", in: &incoming, boardID: boardID, actor: UUID(), x: 900)
      _ = try store.saveBoardEdits(before: accepted, after: incoming)
      // Even supplying a fresh full hierarchy must not grant unseen/passive
      // roots authority to replace their retained old pixels' contribution.
      #expect(try basis.replacing(ink: [], hierarchy: incoming) != store.referenceIdentities(targets: [target]))
      let source = try #require(incoming.board(boardID))
      let mixed = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID,
        board: source.projecting(placements: source.placements,
          elements: try #require(accepted.board(boardID)).elements))], stamp: incoming.stamp)
      #expect(try basis.replacing(ink: [], hierarchy: mixed) != store.referenceIdentities(targets: [target]),
        "The new aggregate header cannot certify stale passive pixels")
      #expect(throws: CollaborationError.self) {
        try store.referenceBasis(rootBoardID: boardID, targets: [target], surfaces: [],
          liveOwners: [.element(boardID: boardID, id: "never-admitted")])
      }
    }
  }

  @Test func installedInkAndAcceptedGeometryComposeInOneRetainedDigest() throws {
    try fixture { store, actor, workspace, initial in
      let board = workspace.rootBoardID, surface = SurfaceID.board(board), target = CollaborationTarget(kind: .board, id: board)
      let basis = try store.referenceBasis(rootBoardID: board, targets: [target], surfaces: [surface],
        liveOwners: [.element(boardID: board, id: "live/a~b")])
      var after = initial
      try move("live/a~b", in: &after, boardID: board, actor: actor, x: 250)
      var ink = try store.readSpatialInk(surfaces: [surface])
      let accepted = ink.append(tool: .pen, spans: [.init(surface: surface, samples: [
        .init(point: .init(x: 25, y: 40), worldPoint: .init(x: 25, y: 40), timeOffset: 0,
          width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])], actor: actor)
      #expect(accepted != nil)
      let capturedInk = try NotebookReferenceInk(surface: surface, actions: ink.actions)
      let predicted = try basis.replacing(ink: [capturedInk], hierarchy: after)
      try store.commandTransaction {
        _ = try store.saveBoardEdits(before: initial, after: after)
        try store.saveSpatialInk(ink)
      }
      #expect(try predicted == store.referenceIdentities(targets: [target]))
      #expect(try basis.replacing(ink: [], hierarchy: after) != predicted)
      #expect(try basis.replacing(ink: [capturedInk]) != predicted)
    }
  }

  @Test func removingEveryAdmittedElementRemovesTheOrderStartEdge() throws {
    try fixture { store, actor, workspace, initial in
      let board = workspace.rootBoardID, cover = CollaborationTarget(kind: .cover, id: workspace.selectedItemID, boardID: board)
      let basis = try store.referenceBasis(rootBoardID: board, targets: [cover], surfaces: [],
        liveOwners: [.element(boardID: board, id: "cover-note")])
      var after = initial
      let count = after.removeElements(ids: ["cover-note"], from: board, actor: actor)
      #expect(count == 1)
      _ = try store.saveBoardEdits(before: initial, after: after)
      #expect(try basis.replacing(ink: [], hierarchy: after) == store.referenceIdentities(targets: [cover]))
    }
  }

  @Test func canonicalPlacementProofRetainsSingletonIntentWithoutAuthoringItsLayout() throws {
    try fixture { store, actor, workspace, initial in
      var expanded = workspace, added = initial
      let created = expanded.createNotebook(title: "Peer", actor: actor, pageSize: .init(width: 834, height: 1194))
      let peer = try #require(created)
      let board = workspace.rootBoardID, item = workspace.selectedItemID
      let inserted = added.addItem(peer.item.id, to: board, near: .init(x: 600, y: 200), actor: actor)
      #expect(inserted)
      _ = try store.saveWorkspaceEdits(before: workspace, after: expanded,
        boardBefore: initial, boardAfter: added, pages: [peer.page])
      var stacked = added
      let stackID = stacked.createStack(moving: item, onto: peer.item.id, in: board, actor: actor)
      let stack = try #require(stackID)
      _ = try store.saveBoardEdits(before: added, after: stacked)
      let target = CollaborationTarget(kind: .board, id: board)
      let basis = try store.referenceBasis(rootBoardID: board, targets: [target], surfaces: [],
        liveOwners: [.item(boardID: board, id: item), .item(boardID: board, id: peer.item.id)])
      let retained = try #require(stacked.board(board)?.placements.first { $0.id == item })
      var unstacked = stacked
      let moved = unstacked.unstackItem(peer.item.id, in: board, at: .init(x: 900, y: 200), actor: actor)
      #expect(moved)
      let canonical = try #require(unstacked.board(board))
      #expect(canonical.placements.first { $0.id == item } == retained)
      #expect(canonical.placement(of: item) != nil)
      #expect(retained.pose?.stackID == stack)
      let frozen = canonical.projecting(placements: canonical.placements, elements: canonical.elements)
      #expect(frozen.placements == canonical.placements, "Frozen source carries authored heads, not rebuilt free or stack rows")
      let rows = try NotebookRecordCodec.encode(JSONValue.encode(unstacked), file: "board.json")
      #expect(rows.contains { $0.collection == "board/placements" && $0.member == item.uuidString.lowercased() })
      #expect(!rows.contains { ["board/freeItems", "board/stacks"].contains($0.collection) })
      _ = try store.saveBoardEdits(before: stacked, after: unstacked)
      #expect(try basis.replacing(ink: [], workspace: expanded, hierarchy: unstacked) == store.referenceIdentities(targets: [target]))
    }
  }
}
