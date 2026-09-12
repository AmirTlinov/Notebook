import Foundation
import Testing
@testable import NotebookCore

@Suite("Board edit preconditions name complete content, not its largest clock")
struct NotebookBoardContentRevisionTests {
  private func fixture(_ body: (NotebookStore, WorkspaceIndex, BoardHierarchy) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex()
    try body(store, workspace, store.loadBoard(items: workspace.items))
  }

  @Test func lowerClockConcurrentHumanMoveInvalidatesTheOldCompletePrecondition() throws {
    try fixture { store, workspace, initial in
      let boardID = workspace.rootBoardID, itemID = workspace.selectedItemID
      let base = try #require(initial.board(boardID))
      let prior = try #require(base.placements.first { $0.id == itemID })
      let agent = UUID(), human = UUID()
      let machine = try WorkspacePlacement.authored(itemID: itemID,
        pose: .init(center: .init(x: 10_000, y: 10_000), zIndex: 1),
        stamp: .init(counter: 100, actor: agent), human: false, previous: prior)
      let person = try WorkspacePlacement.authored(itemID: itemID,
        pose: .init(center: .init(x: 12_000, y: 13_000), zIndex: 2),
        stamp: .init(counter: 1, actor: human), human: true, previous: prior)
      func tree(_ placement: WorkspacePlacement) -> BoardHierarchy {
        let board = BoardDocument(placements: [placement], elements: base.elements,
          stamp: placement.stamp, collaboration: base.collaboration)
        return .init(rootBoardID: boardID, boards: [.init(id: boardID, board: board)], stamp: board.stamp)
      }
      let high = tree(machine), low = tree(person)
      _ = try store.saveBoardEdits(before: initial, after: high)
      let oldRevision = try #require(try store.boardContentRevision(boardID))
      let oldStamp = try #require(try store.readBoardNode(boardID)?.board.stamp)
      let joined = try high.merging(low, items: workspace.items)
      #expect(joined.board(boardID)?.stamp == oldStamp)
      #expect(joined.board(boardID)?.placements.first?.pose == person.pose)
      #expect(joined.board(boardID)?.placements.first?.heads.count == 2)

      let publishedRevision = try store.commandTransaction {
        _ = try store.saveBoardEdits(before: high, after: joined)
        let revision = try #require(try store.boardContentRevision(boardID))
        #expect(revision != oldRevision, "The content digest changes before the deferred scene frontier refresh")
        return revision
      }
      #expect(try store.readBoardNode(boardID)?.board.stamp == oldStamp)
      #expect(try store.boardContentRevision(boardID) == publishedRevision)
      let target = CollaborationTarget(kind: .board, id: boardID)
      #expect(try store.targetContentRevision(target: target) == publishedRevision)

      func action(revision: String) throws -> CollaborationAction {
        .init(additionalOwners: [.init(kind: .cover, id: itemID, boardID: boardID)],
          summary: "Переместить рассмотренную тетрадь", expected: [.init(target: target, revision: revision)],
          operations: [.init(kind: .moveItem, target: target, id: itemID.uuidString,
            values: ["center": try .encode(WorldPoint(x: 250, y: 350))])])
      }
      do { _ = try store.applyCollaborationAction(action(revision: oldRevision), actor: agent); Issue.record("Stale content was admitted") }
      catch let error as CollaborationError {
        #expect(error.code == "revision_conflict")
        #expect(error.expected == oldRevision && error.actual == publishedRevision)
      }
      #expect(try store.boardContentRevision(boardID) == publishedRevision)
      let receipt = try store.applyCollaborationAction(action(revision: publishedRevision), actor: agent)
      #expect(try receipt.revisions.first { $0.target == target }?.revision == store.boardContentRevision(boardID))
    }
  }

  @Test func boundedSceneAndWireReadCarryTheCompleteBoardCut() throws {
    try fixture { store, workspace, initial in
      let boardID = workspace.rootBoardID, itemID = workspace.selectedItemID
      var moved = initial
      let accepted = moved.moveItem(itemID, in: boardID, to: .init(x: 20_000, y: 20_000), actor: UUID())
      #expect(accepted)
      _ = try store.saveBoardEdits(before: initial, after: moved)
      let complete = try #require(try store.boardContentRevision(boardID))
      let bounds = WorkspaceSpatialBounds(origin: .zero, width: 10, height: 10)
      let window = try store.readSceneWindow(boardID: boardID, bounds: bounds, limit: 1)
      #expect(window.boards.first?.board.placements.isEmpty == true)
      #expect(window.boardContentRevisions == [boardID: complete])

      var scene = NotebookReadQuery(kind: .sceneWindow, id: boardID, limit: 1)
      scene.bounds = .init(anchor: .zero, region: .init(x: 0, y: 0, width: 10, height: 10))
      var command = NotebookCommand(command: .read)
      command.queries = [scene, .init(kind: .boardContentRevision, id: boardID)]
      let read = try NotebookCommandDispatcher(store: store).handle(command)
      let values = try #require(read["values"]?.array)
      #expect(values[0]["boardContentRevisions"]?[boardID.uuidString.lowercased()]?.string == complete)
      #expect(values[1].string == complete)
    }
  }

  @Test func pencilKeepsItsOwnRevisionAndCompleteBoardLookupReadsOneHeader() throws {
    try fixture { store, workspace, _ in
      let boardID = workspace.rootBoardID, target = CollaborationTarget(kind: .board, id: boardID)
      let before = try #require(try store.boardContentRevision(boardID))
      let reference = try store.referenceRevision(target: target)
      let surface = SurfaceID.board(boardID)
      var ink = try store.readSpatialInk(surfaces: [surface])
      let appended = ink.append(tool: .pen, spans: [.init(surface: surface, samples: [
        .init(point: .init(x: 25, y: 40), worldPoint: .init(x: 25, y: 40), timeOffset: 0,
          width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])], actor: UUID())
      #expect(appended != nil)
      try store.saveSpatialInk(ink)
      #expect(try store.referenceRevision(target: target) != reference)
      #expect(try store.boardContentRevision(boardID) == before)
      try store.readTransaction { snapshot in
        try snapshot.currentSQL!.limitReads(.init(rows: 1, bytes: 4_096, valueBytes: 4_096, reason: "one_board_header"))
        #expect(try snapshot.boardContentRevision(boardID) == before)
      }
      #expect(try store.boardContentRevision(UUID()) == nil)
    }
  }

  @Test func portalCameraChangesTheSceneButNeverInvalidatesAnIndependentContentEdit() throws {
    try fixture { store, workspace, initial in
      let actor = UUID()
      var index = workspace, hierarchy = initial
      let created = index.createBoard(title: "Доска внутри", actor: actor)
      let child = try #require(created)
      let added = hierarchy.createBoard(child.id, in: workspace.rootBoardID, near: .zero, actor: actor)
      #expect(added)
      _ = try store.saveWorkspaceEdits(before: workspace, after: index, boardBefore: initial, boardAfter: hierarchy)
      let content = try #require(try store.boardContentRevision(child.id))
      let scene = try #require(try store.workspaceHeader().boardRevision)
      var cameraOnly = hierarchy
      let camera = BoardPortalCamera(center: .init(x: 370, y: -240), scale: 0.64)
      let changed = cameraOnly.updatePortalCamera(camera, for: child.id, actor: actor)
      #expect(changed)
      #expect(cameraOnly.board(child.id) == hierarchy.board(child.id))
      _ = try store.saveBoardEdits(before: hierarchy, after: cameraOnly)
      #expect(try store.workspaceHeader().boardRevision != scene)
      #expect(try store.boardContentRevision(child.id) == content)

      let target = CollaborationTarget(kind: .board, id: child.id)
      let action = CollaborationAction(summary: "Добавить пояснение независимо от камеры",
        expected: [.init(target: target, revision: content)], operations: [
          .init(kind: .insertElement, target: target, id: "camera-independent-note", values: [
            "kind": .string("nativeText"), "source": .string("Камера не меняет содержание"),
            "worldOrigin": try .encode(WorldPoint.zero),
            "frame": try .encode(SpatialRect(x: 20, y: 30, width: 300, height: 180))])])
      let receipt = try store.applyCollaborationAction(action, actor: UUID())
      let after = try #require(try store.readBoardNode(child.id))
      #expect(after.portalCamera == camera)
      #expect(after.board.elements.map(\.id) == ["camera-independent-note"])
      #expect(try store.boardContentRevision(child.id) != content)
      #expect(try receipt.revisions.first { $0.target == target }?.revision == store.boardContentRevision(child.id))
    }
  }

  @Test func theContentHeaderProjectionRequiresTheExactCommittedBlob() throws {
    try fixture { store, workspace, _ in
      let address = "board.json#/boards/@" + workspace.rootBoardID.uuidString.lowercased()
      let row = try #require(try store.sqlRead { database in
        try database.rows("SELECT r.hash,b.data FROM records r JOIN blobs b ON b.hash=r.hash WHERE r.address=?", [.text(address)]).first
      })
      let hash = try #require(row[0].text), bytes = try #require(row[1].blob)
      // Deliberately violate the immutable blob invariant only in this isolated
      // fixture. Whitespace preserves valid JSON but no longer has its saved hash.
      let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      try database.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(bytes + Data([0x20])), .text(hash)])
      #expect(throws: NotebookStorageError.blobHashMismatch) { _ = try store.boardContentRevision(workspace.rootBoardID) }
    }
  }
}
