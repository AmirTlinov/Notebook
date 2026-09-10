import Foundation
import Testing
@testable import NotebookCore

@Suite("Placement reads one bounded physical region")
struct NotebookPlacementTests {
  private struct Fixture {
    let store: NotebookStore
    let actor = UUID()
    let header: NotebookWorkspaceHeader
    let item: NotebookItemHeader
    var board: CollaborationTarget { .init(kind: .board, id: header.rootBoardID) }

    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-placement-" + UUID().uuidString))
      header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      item = try #require(store.readItemHeaders(limit: 1).first)
    }
    func clean() { try? FileManager.default.removeItem(at: store.root) }
    func request(target: CollaborationTarget? = nil, origin: WorldPoint? = .init(x: 3000, y: 3000),
      id: String = "new", movable: [CollaborationSubject] = [], contextID: UUID? = nil,
      additionalOwners: [CollaborationTarget] = [], anchor: CollaborationReference? = nil) throws -> CollaborationPlacementRequest {
      let target = target ?? board
      return .init(target: target, expectedRevision: try store.targetContentRevision(target: target),
        items: [.init(id: id, size: .init(width: 100, height: 80), relativeTo: anchor, direction: anchor == nil ? .free : .right)],
        movable: movable, contextID: contextID, additionalOwners: additionalOwners, worldOrigin: origin)
    }
    func complete(_ request: CollaborationPlacementRequest, ink: [PageRect] = []) throws -> CollaborationPlacement {
      let pending = try store.suggestCollaborationPlacement(request)
      #expect(pending.status == .snapshotPending)
      let render = try #require(pending.renderRequest)
      try JSONEncoder().encode(TargetRenderReceipt(request: render, status: "ready", inkRegions: ink)).write(to: store.targetReceiptURL(render.id), options: .atomic)
      return try store.suggestCollaborationPlacement(request)
    }
    func elements(_ elements: [SpatialElement]) throws {
      let index = try store.loadIndex(), before = try store.loadBoard(items: index.items)
      var after = before
      for element in elements {
        let changed = after.upsertElement(element, in: header.rootBoardID, expected: nil, actor: actor)
        #expect(changed)
      }
      _ = try store.saveBoardEdits(before: before, after: after)
    }
    func element(_ id: String, origin: WorldPoint = .init(x: 3000, y: 3000),
      frame: SpatialRect = .init(x: 20, y: 20, width: 100, height: 80), surface: SurfaceID? = nil) -> SpatialElement {
      let surface = surface ?? .board(header.rootBoardID)
      return .init(id: id, surface: surface, kind: .markdown, frame: frame,
        worldOrigin: surface.kind == .board ? origin : nil, source: id, stamp: .init(counter: 0, actor: actor))
    }
    func createNotebook(at center: WorldPoint) throws -> WorkspaceItem {
      let before = try store.loadIndex(), boardBefore = try store.loadBoard(items: before.items)
      var after = before, boardAfter = boardBefore
      let created = after.createNotebook(title: "Другой носитель", actor: actor, pageSize: .init(width: 834, height: 1194))
      let item = try #require(created)
      let added = boardAfter.addItem(item.item.id, to: header.rootBoardID, near: center, actor: actor)
      #expect(added)
      _ = try store.saveWorkspaceEdits(before: before, after: after, boardBefore: boardBefore, boardAfter: boardAfter, pages: [item.page])
      return item.item
    }
    func corrupt(_ addresses: [String]) throws {
      try store.commandTransaction {
        for address in addresses {
          try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
            [.blob(Data("deliberately corrupted unrelated fixture".utf8)), .text(address)])
        }
      }
    }
  }

  @Test func unrelatedHeavyOwnersContextsHistoryAndOffWindowProgramsAreNotRead() throws {
    let f = try Fixture(); defer { f.clean() }
    let foreign = try f.createNotebook(at: .init(x: -100_000, y: 100_000))
    let documentID = UUID()
    _ = try f.store.applyCollaborationAction(.init(summary: "Далёкий документ", expected: [
      .init(target: f.board, revision: f.store.targetContentRevision(target: f.board)),
      .init(target: .init(kind: .workspace, id: f.header.rootBoardID), revision: f.store.loadIndex().stamp.revision)], operations: [
      .init(kind: .createDocument, target: f.board, id: documentID.uuidString, values: ["center": try .encode(WorldPoint(x: 100_000, y: -100_000)), "paperSize": .string("a4")])]), actor: f.actor)
    try f.elements([f.element("near"), f.element("far", origin: .init(x: -100_000, y: -100_000)),
      f.element("foreign-cover", surface: .cover(foreign.id))])
    let context = try f.store.appendContext(references: [.init(target: .init(kind: .page, id: foreign.pageIDs[0]), revision: "frozen")], author: .human, actor: f.actor)
    let action = try #require(f.store.collaborationActions().first)
    let request = try f.request(), before = try f.complete(request)
    let boardAddress = "board.json#/boards/@" + f.header.rootBoardID.uuidString.lowercased()
    try f.corrupt(["pages/" + foreign.pageIDs[0].uuidString.lowercased() + ".json#",
      "documents/" + documentID.uuidString.lowercased() + ".json#",
      "document-states/" + documentID.uuidString.lowercased() + ".json#", "spatial-ink.json#",
      "collaboration/actions/" + action.id.uuidString.lowercased() + ".json#",
      "collaboration/contexts/" + context.id.uuidString.lowercased() + ".json#",
      boardAddress + "/board/elements/@far", boardAddress + "/board/elements/@foreign-cover"])
    #expect(throws: (any Error).self) { try f.store.collaborationSnapshot() }
    let after = try f.store.suggestCollaborationPlacement(request)
    #expect(after.status == .ready)
    #expect(after.placements.map(\.frame) == before.placements.map(\.frame))
    #expect(after.sourceRevision == before.sourceRevision)
    #expect(after.expected.first?.sourceRevision == before.expected.first?.sourceRevision)
  }

  @Test func fullSourceCASRejectsInkWithTheSameGeometryStampButNotAnotherCamera() throws {
    let f = try Fixture(); defer { f.clean() }
    let request = try f.request(), budget = NotebookPlacementBudget()
    let cut = try f.store.readPlacement(request, budget: budget)
    let before = try f.store.targetContentRevision(target: f.board)
    var ink = try f.store.readSpatialInk(surfaces: [.board(f.header.rootBoardID)])
    let span = SpatialInkSpan(surface: .board(f.header.rootBoardID), samples: [
      .init(point: .init(x: 10, y: 10), worldPoint: .init(x: 3010, y: 3010), timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    let added = ink.append(tool: .pen, spans: [span], actor: f.actor)
    #expect(added != nil)
    try f.store.saveSpatialInk(ink)
    #expect(try f.store.targetContentRevision(target: f.board) == before)
    let cursor = try f.store.currentChangeCursor()
    do { _ = try f.store.placementRender(cut, budget: budget); Issue.record("Old ink must not authorize the render") }
    catch let error as CollaborationError { #expect(error.code == "source_conflict") }
    #expect(try f.store.currentChangeCursor() == cursor)

    let fresh = try f.store.readPlacement(request, budget: .init())
    try f.store.savePresence(.init(boardID: f.header.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 20000, y: 30000), scale: 0.1), viewport: .init(x: 834, y: 1194), focusedItemID: nil))
    let render = try f.store.placementRender(fresh, budget: .init())
    #expect(render.sourceRevision == fresh.sourceRevision)
  }

  @Test func explicitOffWindowAnchorAndCanonicalIDCollisionRemainAddressed() throws {
    let f = try Fixture(); defer { f.clean() }
    let id = UUID().uuidString
    try f.elements([f.element(id, origin: .init(x: 30_000, y: 30_000))])
    let request = try f.request(anchor: .init(target: f.board, elementID: id, revision: "frozen"))
    let cut = try f.store.readPlacement(request, budget: .init())
    let reference = try #require(request.items[0].relativeTo)
    #expect(cut.geometry?.anchor(reference) == .init(x: 27020, y: 27020, width: 100, height: 80))
    #expect(cut.geometry?.obstacles.isEmpty == true)
    do { _ = try f.store.suggestCollaborationPlacement(f.request(id: id.lowercased())); Issue.record("Off-window ID exists") }
    catch let error as CollaborationError { #expect(error.code == "invalid_placement") }
    do {
      _ = try f.store.suggestCollaborationPlacement(f.request(movable: [.init(target: f.board, elementID: id),
        .init(target: f.board, elementID: id.lowercased())], additionalOwners: [f.board]))
      Issue.record("UUID spelling does not create two movable owners")
    } catch let error as CollaborationError { #expect(error.code == "invalid_placement") }
    let planned = try f.complete(request)
    #expect(planned.placements.first?.frame == .init(x: 20, y: 20, width: 100, height: 80))
  }

  @Test func scopeUsesOnlyItsAddressedContextAndTheSameRegionalPredicateAsApply() throws {
    let f = try Fixture(); defer { f.clean() }
    try f.elements([f.element("near")])
    let region = CollaborationReference(target: f.board, region: .init(x: 30, y: 30, width: 20, height: 20), worldOrigin: .init(x: 3000, y: 3000), revision: "frozen")
    let source = try f.store.appendContext(references: [region], author: .human, actor: f.actor)
    let unrelated = try f.store.appendContext(references: [.init(target: f.board, elementID: "different", revision: "different")], author: .human, actor: f.actor, select: true)
    let files = try f.store.collaborationSnapshot()
    try f.corrupt(["collaboration/contexts/" + unrelated.id.uuidString.lowercased() + ".json#"])
    let subject = CollaborationSubject(target: f.board, elementID: "near")
    let request = try f.request(movable: [subject], contextID: source.id)
    #expect(try f.store.readPlacement(request, budget: .init()).movable.count == 1)
    try NotebookStore.requireCompositionScope(subject, references: [region], additionalOwners: [], files: files)
    let outside = CollaborationReference(target: f.board, region: .init(x: 0, y: 0, width: 10, height: 10), worldOrigin: .zero, revision: "old")
    let denied = try f.store.appendContext(references: [outside], author: .human, actor: f.actor)
    #expect(throws: CollaborationError.self) { try f.store.readPlacement(f.request(movable: [subject], contextID: denied.id), budget: .init()) }
    #expect(throws: CollaborationError.self) { try NotebookStore.requireCompositionScope(subject, references: [outside], additionalOwners: [], files: files) }
    #expect(try f.store.readPlacement(f.request(movable: [subject], additionalOwners: [f.board]), budget: .init()).movable.count == 1)
  }

  @Test func stackConservativeFramesAreCompleteAcrossTileEdgesAndNeverSplit() throws {
    let f = try Fixture(); defer { f.clean() }
    var ids = [f.item.id]
    for _ in 0..<4 { ids.append(try f.createNotebook(at: .init(x: -900, y: -700)).id) }
    let index = try f.store.loadIndex(), before = try f.store.loadBoard(items: index.items)
    var after = before
    let moved = after.moveItem(ids[0], in: f.header.rootBoardID, to: .init(x: -900, y: -700), actor: f.actor)
    #expect(moved)
    for id in ids.dropFirst() {
      let stack = after.createStack(moving: id, onto: ids[0], in: f.header.rootBoardID, actor: f.actor)
      #expect(stack != nil)
    }
    _ = try f.store.saveBoardEdits(before: before, after: after)
    let request = try f.request(origin: .zero), cut = try f.store.readPlacement(request, budget: .init())
    let geometry = try #require(cut.geometry), g = WorkspaceItemGeometry.notebook
    let expected = ids.compactMap { id -> PageRect? in
      guard let center = after.board(f.header.rootBoardID)?.focusedCenter(of: id) else { return nil }
      let delta = compositionDelta(from: .zero, to: center)
      return .init(x: delta.x - g.width * 1.5, y: delta.y - g.height / 2 - g.width, width: g.width * 3, height: g.height + g.width * 2)
    }
    #expect(geometry.obstacles.count == 5)
    #expect(geometry.obstacles.allSatisfy { !$0.canMove && expected.contains($0.frame) })
    do { _ = try f.store.suggestCollaborationPlacement(f.request(origin: .zero, movable: [.init(target: .init(kind: .cover, id: ids[0], boardID: f.header.rootBoardID))], additionalOwners: [.init(kind: .cover, id: ids[0], boardID: f.header.rootBoardID)])); Issue.record("A stack is indivisible") }
    catch let error as CollaborationError { #expect(error.code == "placement_unavailable") }
  }

  @Test func denseRegionsAndSQLExhaustionReturnBudgetFailureWithoutAPlanOrWrite() throws {
    let f = try Fixture(); defer { f.clean() }
    let address = "board.json#/boards/@" + f.header.rootBoardID.uuidString.lowercased()
    try f.store.commandTransaction {
      for offset in 0...NotebookPlacementBudget.maximumObstacles {
        let element = f.element("dense-" + String(format: "%05d", offset))
        try f.store.writeFragment(.init(address: address + "/board/elements/@" + element.id, file: "board.json", parent: address,
          collection: "board/elements", member: element.id, position: offset, value: try .encode(element), collections: []), database: f.store.currentSQL!)
      }
    }
    let request = try f.request(), cursor = try f.store.currentChangeCursor()
    for budget in [NotebookPlacementBudget(), .init(sqlSteps: 100)] {
      do { _ = try f.store.readPlacement(request, budget: budget); Issue.record("The complete query exceeds its budget") }
      catch let error as CollaborationError { #expect(error.code == "placement_budget") }
    }
    do { _ = try f.store.suggestCollaborationPlacement(request); Issue.record("No partial ready or unavailable result") }
    catch let error as CollaborationError { #expect(error.code == "placement_budget") }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.targetRenderRequests().isEmpty)
  }

  @Test func unsupportedOwnersKeepTheirUnavailableDTOAndRealCanonicalSource() throws {
    let f = try Fixture(); defer { f.clean() }
    let target = CollaborationTarget(kind: .workspace, id: f.header.rootBoardID)
    let source = try f.store.referenceRevision(target: target)
    let result = try f.store.suggestCollaborationPlacement(f.request(target: target))
    #expect(result.status == .unavailable && result.placements.isEmpty && result.moves.isEmpty)
    #expect(result.sourceRevision == source && result.expected.first?.sourceRevision == source)
  }

  @Test func documentCoverUsesItsPaperSizeWithoutReadingBlocksOrState() throws {
    let f = try Fixture(); defer { f.clean() }
    let before = try f.store.loadIndex(), boardBefore = try f.store.loadBoard(items: before.items)
    var after = before, boardAfter = boardBefore
    let created = after.createDocument(title: "Letter", actor: f.actor)
    let item = try #require(created)
    let document = DocumentDocument(id: item.id, actor: f.actor, paperSize: .letter)
    let state = DocumentStateJournal(id: item.id, actor: f.actor)
    let added = boardAfter.addItem(item.id, to: f.header.rootBoardID, near: .init(x: 3000, y: 3000), actor: f.actor)
    #expect(added)
    _ = try f.store.saveWorkspaceEdits(before: before, after: after, boardBefore: boardBefore, boardAfter: boardAfter, documents: [document], states: [state])
    let target = CollaborationTarget(kind: .cover, id: item.id, boardID: f.header.rootBoardID)
    let request = try f.request(target: target)
    try f.corrupt(["document-states/" + item.id.uuidString.lowercased() + ".json#"])
    let cut = try f.store.readPlacement(request, budget: .init()), expected = WorkspaceItemGeometry.document(.letter)
    #expect(cut.geometry?.extent == .init(width: expected.width, height: expected.height))
    #expect(cut.sourceRevision == (try f.store.referenceRevision(target: target)))
    #expect(try f.complete(request).status == .ready)
  }

  @Test func aCoverUsesItsOwnerIndexRatherThanScanningOtherCovers() throws {
    let f = try Fixture(); defer { f.clean() }
    let foreign = try f.createNotebook(at: .init(x: 100_000, y: 100_000))
    let parent = "board.json#/boards/@" + f.header.rootBoardID.uuidString.lowercased()
    try f.store.commandTransaction {
      for offset in 0..<1_024 {
        let element = f.element("foreign-" + String(format: "%05d", offset), surface: .cover(foreign.id))
        try f.store.writeFragment(.init(address: parent + "/board/elements/@" + element.id, file: "board.json", parent: parent,
          collection: "board/elements", member: element.id, position: offset, value: try .encode(element), collections: []), database: f.store.currentSQL!)
      }
    }
    let target = CollaborationTarget(kind: .cover, id: f.item.id, boardID: f.header.rootBoardID)
    let request = try f.request(target: target), budget = NotebookPlacementBudget()
    let cut = try f.store.readPlacement(request, budget: budget)
    #expect(cut.geometry?.obstacles.isEmpty == true)
    #expect(budget.inspectedObstacles == 0 && budget.sqlSteps > 0 && budget.sqlSteps < 2_000)
    #expect(try f.complete(request).status == .ready)
  }

  @Test func aSourceByteLimitIsCheckedBeforeRehydrationAndCancellationDoesNotEnqueue() async throws {
    let f = try Fixture(); defer { f.clean() }
    let target = CollaborationTarget(kind: .page, id: try #require(f.item.firstPageID)), request = try f.request(target: target)
    let file = "pages/" + target.id.uuidString.lowercased() + ".json"
    let address = file + "#/drawingData"
    try f.store.commandTransaction {
      try f.store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
        [.blob(Data(repeating: 120, count: NotebookPlacementBudget.maximumSourceBytes + 1)), .text(address)])
    }
    do { _ = try f.store.suggestCollaborationPlacement(request); Issue.record("Do not decode an oversized source") }
    catch let error as CollaborationError { #expect(error.code == "placement_budget" && error.message.contains("source_bytes")) }
    let cancelled = Task { () throws -> Bool in
      withUnsafeCurrentTask { $0?.cancel() }
      do { _ = try f.store.suggestCollaborationPlacement(f.request()); return false }
      catch is CancellationError { return true }
    }
    #expect(try await cancelled.value)
    #expect(try f.store.targetRenderRequests().isEmpty)
  }

  @Test func extremeTiledRequestsFailWithoutArithmeticTraps() throws {
    let f = try Fixture(); defer { f.clean() }
    #expect(throws: CollaborationError.self) {
      try f.store.suggestCollaborationPlacement(f.request(origin: .init(tileX: .max, tileY: .max, localX: WorldPoint.tileSize - 1, localY: WorldPoint.tileSize - 1)))
    }
    let origin = WorldPoint(tileX: Int64.max - 10, tileY: Int64.min + 10, localX: 15, localY: 25)
    let cut = try f.store.readPlacement(f.request(origin: origin), budget: .init())
    #expect(cut.geometry?.origin == origin && cut.geometry?.obstacles.isEmpty == true)
    let cursor = try f.store.currentChangeCursor()
    do { _ = try f.store.suggestCollaborationPlacement(f.request(origin: origin)); Issue.record("No rounded render may be published") }
    catch let error as CollaborationError { #expect(error.code == "invalid_placement") }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.targetRenderRequests().isEmpty)
    // JSONValue's existing numeric wire is Double-backed; this test does not
    // claim an Int64-extreme render round trip. Its exactly representable far
    // tile still must retain the local placement, rather than flatten world X.
    let renderable = WorldPoint(tileX: 1_000_000_000_000, tileY: -1_000_000_000_000, localX: 15, localY: 25)
    let result = try f.complete(f.request(origin: renderable))
    #expect(result.status == .ready && result.placements.first?.worldOrigin == renderable)
  }
}
