import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Spatial ink windows retain interaction-complete addressed sources", .serialized)
struct NotebookSpatialInkWindowTests {
  private func fixture(_ body: (NotebookStore, UUID, NotebookWorkspaceHeader) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    try body(store, actor, store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194)))
  }
  private func span(_ surface: SurfaceID, _ x: Double, _ end: Double? = nil, targets: [InkElementTarget]? = nil) -> SpatialInkSpan {
    .init(surface: surface, samples: [x, end ?? x + 2].enumerated().map { i, x in
      .init(point: .init(x: x, y: 10), worldPoint: surface.kind == .board ? .init(x: x, y: 10) : nil,
        timeOffset: Double(i), width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    }, elementTargets: targets)
  }

  @Test func aWholeLongContactRetainsItsOffWindowEraserAndBothPhysicalSpans() throws {
    try fixture { store, actor, header in
      let surface = SurfaceID.board(header.rootBoardID), cover = SurfaceID.cover(try #require(store.readItemHeaders(limit: 1).first).id)
      let pen = SpatialInkAction(tool: .pen, spans: [span(surface, 10, 10_000)], stamp: .init(counter: 1, actor: actor))
      let eraser = SpatialInkAction(tool: .eraser, spans: [span(surface, 9_990)], stamp: .init(counter: 2, actor: actor))
      let far = SpatialInkAction(tool: .pen, spans: [span(surface, 30_000)], stamp: .init(counter: 3, actor: actor))
      let crossing = SpatialInkAction(tool: .pen, spans: [span(surface, 20), span(cover, 40)], stamp: .init(counter: 4, actor: actor))
      for action in [pen, eraser, far, crossing] { _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp)) }
      let coverage = [surface: WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)]
      let window = try store.readSpatialInkWindow(coverage: coverage)
      #expect(Set(window.journal.actions.map(\.id)) == [pen.id, eraser.id, crossing.id])
      #expect(window.journal.actions.first { $0.id == pen.id } == pen)
      #expect(window.journal.actions.first { $0.id == crossing.id }?.spans == crossing.spans)
      #expect(window.covers(coverage) && !window.covers([surface: .init(origin: .zero, width: 100_000, height: 100)]))
      let pinned = try store.readSpatialInkWindow(coverage: coverage, pinnedActionIDs: [far.id])
      #expect(pinned.journal.actions.contains { $0.id == far.id })
      _ = try store.commitSpatialInk(.state(actionID: pen.id, creationStamp: pen.stamp, expectedStateStamp: pen.stateStamp,
        isActive: false, stateStamp: .init(counter: 5, actor: actor), journalStamp: .init(counter: 5, actor: actor)))
      let inactive = try NotebookStore(root: store.root).readSpatialInkWindow(coverage: coverage)
      #expect(!inactive.journal.actions.contains { $0.id == pen.id || $0.id == eraser.id })
      #expect(try store.spatialInkHistoryStates(ids: [pen.id])[pen.id]?.result.isActive == false)
      #expect(try store.nativeRedoHistory(domain: .board(header.rootBoardID), actor: actor).isEmpty, "A non-head older contribution cannot create a new redo branch")
    }
  }

  @Test func aColdOffscreenUndoAndRedoUseOnlyExactHistoryHeaders() throws {
    try fixture { store, actor, header in
      let surface = SurfaceID.board(header.rootBoardID), domain = PencilUndoHistory.Domain.board(header.rootBoardID)
      let action = SpatialInkAction(tool: .pen, spans: [span(surface, 50_000)], stamp: .init(counter: 1, actor: actor))
      _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      let cold = NotebookStore(root: store.root)
      #expect(try cold.readSpatialInkWindow(coverage: [surface: .init(origin: .zero, width: 100, height: 100)]).journal.actions.isEmpty)
      #expect(try cold.nativeHistory(domain: domain, actor: actor).first == .ink([action.id]))
      let initial = try #require(cold.spatialInkHistoryStates(ids: [action.id])[action.id])
      #expect(initial.surfaces == [surface] && initial.result.isActive)
      let undone = try cold.commitSpatialInk(.state(actionID: action.id, creationStamp: initial.result.creationStamp,
        expectedStateStamp: initial.result.stateStamp, isActive: false, stateStamp: .init(counter: 2, actor: actor), journalStamp: .init(counter: 2, actor: actor)))
      #expect(try cold.nativeRedoHistory(domain: domain, actor: actor).first == .inkRedo([action.id], undone.stateStamp))
      let reopened = NotebookStore(root: store.root), gate = try #require(reopened.spatialInkHistoryStates(ids: [action.id])[action.id])
      _ = try reopened.commitSpatialInk(.state(actionID: action.id, creationStamp: gate.result.creationStamp,
        expectedStateStamp: gate.result.stateStamp, isActive: true, stateStamp: .init(counter: 3, actor: actor),
        journalStamp: .init(counter: 3, actor: actor), nativeRedo: true))
      let shown = try reopened.readSpatialInkWindow(coverage: [surface: .init(origin: .init(x: 49_990, y: 0), width: 100, height: 100)])
      #expect(shown.journal.actions.first?.id == action.id && shown.journal.actions.first?.spans == action.spans)
    }
  }

  @Test func metadataWitnessIgnoresOffscreenInkButRejectsVisibleAndAddressedMaskAdditions() throws {
    try fixture { store, actor, header in
      let surface = SurfaceID.board(header.rootBoardID), coverage = [SurfaceID.board(header.rootBoardID): WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)]
      let before = try store.readSpatialInkWindowRecords(coverage: coverage, elementIDs: [surface: ["shape"]])
      let far = SpatialInkAction(tool: .pen, spans: [span(surface, 50_000)], stamp: .init(counter: 1, actor: actor))
      _ = try store.commitSpatialInk(.append(far, journalStamp: far.stamp))
      #expect(try before.isCurrent(store))
      let target = InkElementTarget(elementID: "shape", frame: .init(x: 50_000, y: 0, width: 20, height: 20), worldOrigin: .zero)
      let mask = SpatialInkAction(tool: .eraser, spans: [span(surface, 50_005, targets: [target])], stamp: .init(counter: 2, actor: actor))
      _ = try store.commitSpatialInk(.append(mask, journalStamp: mask.stamp))
      #expect(try !before.isCurrent(store))
      let next = try store.readSpatialInkWindowRecords(coverage: coverage)
      let visible = SpatialInkAction(tool: .pen, spans: [span(surface, 10)], stamp: .init(counter: 3, actor: actor))
      _ = try store.commitSpatialInk(.append(visible, journalStamp: visible.stamp))
      #expect(try !next.isCurrent(store))
    }
  }

  @Test func aMovedFigureRetainsItsAddressedMaskOutsideTheQueryRectangle() throws {
    try fixture { store, actor, header in
      let surface = SurfaceID.board(header.rootBoardID)
      let target = InkElementTarget(elementID: "moved", frame: .init(x: 50_000, y: 0, width: 30, height: 30), worldOrigin: .zero)
      let eraser = SpatialInkAction(tool: .eraser, spans: [span(surface, 50_010, targets: [target])], stamp: .init(counter: 1, actor: actor))
      _ = try store.commitSpatialInk(.append(eraser, journalStamp: eraser.stamp))
      let bounds = [surface: WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)]
      #expect(try store.readSpatialInkWindow(coverage: bounds).journal.actions.isEmpty)
      let window = try store.readSpatialInkWindow(coverage: bounds, elementIDs: [surface: ["moved"]])
      #expect(window.journal.actions == [eraser])
      #expect(window.covers(bounds, elements: [surface: ["moved"]]))
    }
  }

  @Test func boundedReferenceReplacementPreservesEveryUnseenContribution() throws {
    try fixture { store, actor, header in
      let surface = SurfaceID.board(header.rootBoardID), target = CollaborationTarget(kind: .board, id: header.rootBoardID)
      var journal = SpatialInkJournal(stamp: .init(counter: 0, actor: actor))
      let acceptedFirst = journal.append(tool: .pen, spans: [span(surface, 10)], actor: actor)
      let first = try #require(acceptedFirst)
      let acceptedHidden = journal.append(tool: .pen, spans: [span(surface, 50_000)], actor: actor)
      let hidden = try #require(acceptedHidden)
      try store.saveSpatialInk(journal)
      let window = try store.readSpatialInkWindow(coverage: [surface: .init(origin: .zero, width: 100, height: 100)])
      let basis = try store.referenceBasis(rootBoardID: header.rootBoardID, targets: [target], surfaces: [surface], inkActionIDs: [first.id])
      #expect(try basis.replacing(ink: [.init(surface: surface, actions: window.journal.actions, baselineActionIDs: [first.id])]) == basis.identities)
      let changed = journal.deactivate(first.id, actor: actor); #expect(changed)
      try store.saveSpatialInk(journal)
      let retained = try #require(journal.actions.first { $0.id == first.id })
      let predicted = try basis.replacing(ink: [.init(surface: surface, actions: [retained], baselineActionIDs: [first.id])])
      #expect(try predicted == store.referenceIdentities(targets: [target]))
      #expect(throws: CollaborationError.self) {
        try basis.replacing(ink: [.init(surface: surface, actions: [hidden], baselineActionIDs: [hidden.id])])
      }
    }
  }

  @Test func bulkHeaderToolReplacementUpdatesWindowClassificationWithoutChangingMeasurements() throws {
    try fixture { store, actor, header in
      let before = try store.loadIndex(), treeBefore = try store.loadBoard(items: before.items), child = UUID()
      var workspace = before, tree = treeBefore
      let created = workspace.createBoard(title: "Bulk ink owner", actor: actor, boardID: child)
      #expect(created != nil)
      let placed = tree.createBoard(child, in: header.rootBoardID, near: .zero, actor: actor)
      #expect(placed)
      _ = try store.saveWorkspaceEdits(before: before, after: workspace, boardBefore: treeBefore, boardAfter: tree)
      let surface = SurfaceID.board(child), coverage = [SurfaceID.board(child): WorkspaceSpatialBounds(origin: .zero, width: 100, height: 100)]
      let far = SpatialInkAction(tool: .pen, spans: [span(surface, 9_990)], stamp: .init(counter: 1, actor: actor))
      let eraser = SpatialInkAction(id: far.id, tool: .eraser, color: far.color, spans: far.spans, stamp: far.stamp)
      let bodyAddress = "spatial-ink.json#/actions/@" + far.id.uuidString.lowercased() + "/spans"
      try store.saveSpatialInk(.init(actions: [far], stamp: far.stamp))
      let body = try store.storedFragments(address: bodyAddress)
      #expect(try store.boardHasContent(child))
      try store.saveSpatialInk(.init(actions: [eraser], stamp: .init(counter: 2, actor: actor)))
      let reopened = NotebookStore(root: store.root)
      #expect(try !reopened.boardHasContent(child))
      #expect(try reopened.storedFragments(address: bodyAddress) == body)
      let long = SpatialInkAction(tool: .pen, spans: [span(surface, 10, 10_000)], stamp: .init(counter: 3, actor: actor))
      try reopened.saveSpatialInk(.init(actions: [eraser, long], stamp: long.stamp))
      #expect(try Set(reopened.readSpatialInkWindow(coverage: coverage).journal.actions.map(\.id)) == [far.id, long.id],
        "A header reclassified as eraser must cover the retained pen outside the viewport")
      try reopened.saveSpatialInk(.init(actions: [far, long], stamp: .init(counter: 4, actor: actor)))
      #expect(try reopened.readSpatialInkWindow(coverage: coverage).journal.actions.map(\.id) == [long.id],
        "The same header reclassified as pen must leave the eraser-only expansion")
      #expect(try reopened.boardHasContent(child))
      #expect(try reopened.storedFragments(address: bodyAddress) == body)
      try reopened.saveSpatialInk(.init(stamp: .init(counter: 5, actor: actor)))
      #expect(try !reopened.boardHasContent(child))
      #expect(try reopened.readSpatialInkWindow(coverage: coverage).journal.actions.isEmpty)
      #expect(try reopened.sqlRead { try $0.rows("SELECT entry FROM ink_ranges").isEmpty }, "Deleting the records cascades through derived bounds")
    }
  }

  @Test func folderContentIndexesOnlyVisibleActivePensAndMigrationKeepsTheirBytes() throws {
    try fixture { store, actor, header in
      let before = try store.loadIndex(), treeBefore = try store.loadBoard(items: before.items), child = UUID()
      var workspace = before, tree = treeBefore
      let created = workspace.createBoard(title: "Ink only", actor: actor, boardID: child)
      #expect(created != nil)
      let placed = tree.createBoard(child, in: header.rootBoardID, near: .zero, actor: actor)
      #expect(placed)
      _ = try store.saveWorkspaceEdits(before: before, after: workspace, boardBefore: treeBefore, boardAfter: tree)
      let surface = SurfaceID.board(child)
      let transparent = SpatialInkAction(tool: .pen, spans: [.init(surface: surface, samples: [
        .init(point: .init(x: 10, y: 10), worldPoint: .init(x: 10, y: 10), timeOffset: 0, width: 3, opacity: 0, force: 1, azimuth: 0, altitude: 1)
      ])], stamp: .init(counter: 1, actor: actor))
      let eraser = SpatialInkAction(tool: .eraser, spans: [span(surface, 10)], stamp: .init(counter: 2, actor: actor))
      for action in [transparent, eraser] { _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp)) }
      #expect(try !store.boardHasContent(child))
      let pen = SpatialInkAction(tool: .pen, spans: [span(surface, 10)], stamp: .init(counter: 3, actor: actor))
      _ = try store.commitSpatialInk(.append(pen, journalStamp: pen.stamp))
      #expect(try store.boardHasContent(child))
      let proof = try store.archiveContentProof(), cursor = try store.currentChangeCursor()
      try store.commandTransaction(advancesReadRevision: false) {
        try store.currentSQL!.run("DROP INDEX ink_surface_content")
        try store.currentSQL!.run("ALTER TABLE ink_surfaces DROP COLUMN has_ink")
        try store.currentSQL!.run("PRAGMA user_version=24")
      }
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.boardHasContent(child))
      #expect(try reopened.archiveContentProof() == proof && reopened.currentChangeCursor() == cursor)
      _ = try reopened.commitSpatialInk(.state(actionID: pen.id, creationStamp: pen.stamp, expectedStateStamp: pen.stateStamp,
        isActive: false, stateStamp: .init(counter: 4, actor: actor), journalStamp: .init(counter: 4, actor: actor)))
      #expect(try !reopened.boardHasContent(child))
    }
  }

  @Test func migrationBuildsOnlyDerivedBoundsWithoutChangingRecordsOrCursors() throws {
    try fixture { store, actor, header in
      let surface = SurfaceID.board(header.rootBoardID)
      let action = SpatialInkAction(tool: .pen, spans: [span(surface, 10)], stamp: .init(counter: 1, actor: actor))
      _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      let before = try store.archiveContentProof(), cursor = try store.currentChangeCursor()
      try store.commandTransaction(advancesReadRevision: false) {
        try store.currentSQL!.run("UPDATE ink_surfaces SET active=0,min_tx=NULL")
        try store.currentSQL!.run("PRAGMA user_version=23")
      }
      let reopened = NotebookStore(root: store.root)
      let window = try reopened.readSpatialInkWindow(coverage: [surface: .init(origin: .zero, width: 100, height: 100)])
      #expect(window.journal.actions == [action])
      #expect(try reopened.archiveContentProof() == before && reopened.currentChangeCursor() == cursor)
    }
  }

  @Test func migrationFrom26RebuildsPainterOrderAndPageCutsWithoutChangingAcceptedInk() throws {
    try fixture { store, actor, header in
      let surface = SurfaceID.board(header.rootBoardID)
      let earlierActor = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
      let laterActor = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
      let oldCut = SpatialInkAction(tool: .eraser, spans: [span(surface, 10)], stamp: .init(counter: 1, actor: laterActor))
      let pen = SpatialInkAction(tool: .pen, spans: [span(surface, 10)], stamp: .init(counter: 2, actor: earlierActor))
      let cut = SpatialInkAction(tool: .eraser, spans: [span(surface, 10)], stamp: .init(counter: 2, actor: laterActor))
      let top = SpatialInkAction(tool: .pen, spans: [span(surface, 10)], stamp: .init(counter: 3, actor: earlierActor))
      for action in [oldCut, pen, cut, top] {
        _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      }
      let spatial = try store.readSpatialInk(surfaces: [surface])
      let selectedSpatial = try #require(spatial.readSet(for: pen.id, on: surface))
      let topSpatial = try #require(spatial.readSet(for: top.id, on: surface))
      #expect(selectedSpatial.erasers.map(\.id) == [cut.id] && topSpatial.erasers.isEmpty)

      let pageID = try #require(store.loadIndex().selectedPageID)
      var page = try store.loadPage(pageID)
      // Paper actions carry local points directly; SpatialInkSpan is only for
      // spatial surfaces and board spans require world coordinates.
      let pageSamples = InkMeasurements([10.0, 12.0].enumerated().map { index, x in
        SpatialInkSample(point: .init(x: x, y: 10), worldPoint: nil,
          timeOffset: Double(index), width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      })
      let pagePen = PageInkAction(tool: .pen, measurements: pageSamples, sequence: 1)
      let pageCut = PageInkAction(tool: .eraser, measurements: pageSamples, sequence: 2)
      let pageTop = PageInkAction(tool: .pen, measurements: pageSamples, sequence: 3)
      let drawing = PageInkDrawing(actions: [pagePen, pageCut, pageTop])
      let replaced = page.replaceDrawing(try drawing.dataRepresentation(), actor: actor)
      #expect(replaced)
      page = try store.savePage(page)
      try page.prepareInkForPresentation()
      let selectedPage = try #require(page.inkSource.readSet(for: pagePen.id, on: .page(pageID)))
      let topPage = try #require(page.inkSource.readSet(for: pageTop.id, on: .page(pageID)))
      #expect(selectedPage.erasers.map(\.id) == [pageCut.id] && topPage.erasers.isEmpty)

      // Retiring a notebook removes live membership but keeps admitted PAGE
      // sources for history and delayed delivery, including native erasers.
      var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
      let created = index.createNotebook(title: "Retired ink", actor: actor, pageSize: page.size)
      let retired = try #require(created)
      let placed = board.addItem(retired.item.id, to: header.rootBoardID, near: .zero, actor: actor)
      #expect(placed)
      var retiredPage = retired.page
      let retiredCut = PageInkAction(tool: .eraser, measurements: pageSamples, sequence: 1)
      let retiredDrawing = PageInkDrawing(actions: [retiredCut])
      let retained = retiredPage.replaceDrawing(try retiredDrawing.dataRepresentation(), actor: actor)
      #expect(retained)
      try store.saveWorkspaceBundle(index: index, page: retiredPage, board: board)
      try store.commandTransaction {
        try store.deleteWorkspaceItemContent(itemID: retired.item.id, actor: actor, human: true)
      }
      #expect(try store.ownerItemID(ofPage: retiredPage.id) == nil)
      #expect(try store.retiredNotebookMembership(ofPage: retiredPage.id)?.itemID == retired.item.id)
      #expect(try store.readStoredPageInkAction(pageID: retiredPage.id, actionID: retiredCut.id) == retiredCut)
      let proof = try store.archiveContentProof(), cursor = try store.currentChangeCursor()

      // v26 had spatial bounds, but neither painter columns nor indexed page
      // cuts. Recreate that real SQLite layout rather than only its version tag.
      try store.commandTransaction(advancesReadRevision: false) {
        let database = try #require(store.currentSQL)
        try database.run("DELETE FROM ink_surfaces WHERE kind='page'")
        try database.run("DROP INDEX ink_surface_paint_order")
        try database.run("ALTER TABLE ink_surfaces DROP COLUMN paint_counter")
        try database.run("ALTER TABLE ink_surfaces DROP COLUMN paint_actor")
        try database.run("PRAGMA user_version=26")
      }

      let reopened = NotebookStore(root: store.root)
      let restoredSpatial = try reopened.readSpatialInk(surfaces: [surface])
      let restoredPage = try reopened.loadPage(pageID)
      try restoredPage.prepareInkForPresentation()
      #expect(try reopened.sqlRead { try $0.rows("PRAGMA user_version").first?[0].integer } == 27)
      #expect(try reopened.archiveContentProof() == proof && reopened.currentChangeCursor() == cursor)
      #expect(restoredSpatial.actions == spatial.actions && restoredPage.preparedInkDrawing == drawing)
      #expect(selectedSpatial.matches(restoredSpatial) && topSpatial.matches(restoredSpatial))
      #expect(selectedPage.matches(restoredPage.inkSource) && topPage.matches(restoredPage.inkSource))
      #expect(try reopened.ownerItemID(ofPage: retiredPage.id) == nil)
      #expect(try reopened.readStoredPageInkAction(pageID: retiredPage.id, actionID: retiredCut.id) == retiredCut)
      #expect(throws: CollaborationError.self) {
        _ = try reopened.readPageInkAction(pageID: retiredPage.id, actionID: retiredCut.id)
      }
      let retiredAddress = pageFile(retiredPage.id) + "#/drawingData/actions/@" + retiredCut.id.uuidString.lowercased()
      let indexed = try reopened.sqlRead {
        try $0.rows("SELECT kind,owner_id,active,tool,paint_counter FROM ink_surfaces WHERE address=?", [.text(retiredAddress)])
      }
      let retiredIndex = try #require(indexed.first)
      #expect(indexed.count == 1 && retiredIndex[0].text == "page"
        && retiredIndex[1].text == retiredPage.id.uuidString.lowercased()
        && retiredIndex[2].integer == 1 && retiredIndex[3].text == "eraser"
        && retiredIndex[4].integer == Int64(retiredCut.sequence))
      try reopened.readTransaction { _ in
        try reopened.validateInkReadSets([selectedSpatial, topSpatial], target: .init(kind: .board, id: header.rootBoardID))
        try reopened.validateInkReadSets([selectedPage, topPage], target: .init(kind: .page, id: pageID))
      }
    }
  }
}
