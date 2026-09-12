import Foundation
import Testing
@testable import NotebookCore

@Suite("Installed ink replaces only its retained physical contribution")
struct NotebookReferenceInkTests {
  private func fixture(_ body: (NotebookStore, UUID, NotebookWorkspaceHeader) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    try body(store, actor, store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194)))
  }

  private func span(_ surface: SurfaceID, x: Double = 0) -> SpatialInkSpan {
    .init(surface: surface, samples: [.init(point: .init(x: x, y: 2),
      worldPoint: surface.kind == .board ? .init(x: x, y: 2) : nil,
      timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
  }

  @Test func finishedPenEraseAndUndoRebaseWithoutWaitingForANewCohort() throws {
    try fixture { store, actor, header in
      let item = try #require(try store.readItemHeaders(limit: 1).first)
      let targets = [CollaborationTarget(kind: .board, id: header.rootBoardID),
        .init(kind: .cover, id: item.id, boardID: header.rootBoardID)]
      let surfaces = [SurfaceID.board(header.rootBoardID), .cover(item.id)]
      let basis = try store.referenceBasis(rootBoardID: header.rootBoardID, targets: targets, surfaces: surfaces)
      var journal = try store.readSpatialInk(surfaces: surfaces)
      let acceptedPen = journal.append(tool: .pen, spans: surfaces.map { span($0) }, actor: actor)
      let pen = try #require(acceptedPen)
      let acceptedEraser = journal.append(tool: .eraser, spans: surfaces.map { span($0, x: 5) }, actor: actor)
      let eraser = try #require(acceptedEraser)
      for actionID in [nil, Optional(eraser.id), Optional(pen.id)] {
        if let actionID { let changed = journal.deactivate(actionID, actor: actor); #expect(changed) }
        try store.saveSpatialInk(journal)
        let retained = try surfaces.map { try NotebookReferenceInk(surface: $0, actions: journal.actions) }
        #expect(try basis.replacing(ink: retained) == store.referenceIdentities(targets: targets))
      }
      #expect(try store.workspaceHeader().cursor > basis.cursor)
    }
  }

  @Test func preparedChildNeedsOnlyItsCompleteHashBasisNotAnOldSampleCopy() throws {
    try fixture { store, actor, header in
      let before = try store.loadIndex(), boardBefore = try store.loadBoard(items: before.items)
      var after = before, boardAfter = boardBefore
      let child = UUID()
      let created = after.createBoard(title: "", actor: actor, boardID: child)
      #expect(created != nil)
      let placed = boardAfter.createBoard(child, in: header.rootBoardID, near: .zero, actor: actor)
      #expect(placed)
      _ = try store.saveWorkspaceEdits(before: before, after: after, boardBefore: boardBefore, boardAfter: boardAfter)
      let targets = [CollaborationTarget(kind: .board, id: header.rootBoardID),
        .init(kind: .cover, id: child, boardID: header.rootBoardID), .init(kind: .board, id: child)]
      let surface = SurfaceID.board(child)
      var journal = try store.readSpatialInk(surfaces: [surface])
      let accepted = journal.append(tool: .pen, spans: [span(surface)], actor: actor)
      let first = try #require(accepted)
      try store.saveSpatialInk(journal)
      let basis = try store.referenceBasis(rootBoardID: header.rootBoardID, targets: targets, surfaces: [surface])
      let deactivated = journal.deactivate(first.id, actor: actor)
      #expect(deactivated)
      try store.saveSpatialInk(journal)
      let replacement = try NotebookReferenceInk(surface: surface, actions: journal.actions)
      #expect(try basis.replacing(ink: [replacement]) == store.referenceIdentities(targets: targets),
        "The portal-cover intermediate must carry the changed child's identity to its parent")
      #expect(throws: CollaborationError.self) {
        try basis.replacing(ink: [NotebookReferenceInk(surface: .cover(child), actions: [])])
      }
    }
  }

  @Test func anUnchangedMaximumClockStillNamesTheExactOwnerAndStaticCASRejects() throws {
    try fixture { store, actor, header in
      let target = CollaborationTarget(kind: .board, id: header.rootBoardID), surface = SurfaceID.board(header.rootBoardID)
      var journal = SpatialInkJournal(stamp: .init(counter: 100, actor: actor))
      try store.saveSpatialInk(journal)
      let basis = try store.referenceBasis(rootBoardID: header.rootBoardID, targets: [target], surfaces: [surface])
      let lower = SpatialInkAction(tool: .pen, spans: [span(surface)], stamp: .init(counter: 1, actor: UUID()))
      let merged = journal.merge(.init(actions: [lower], stamp: lower.stamp))
      #expect(merged)
      #expect(journal.stamp.counter == 100)
      try store.saveSpatialInk(journal)
      let identity = try #require(basis.replacing(ink: [NotebookReferenceInk(surface: surface, actions: journal.actions)]).first)
      #expect(try identity.revision == store.referenceRevision(target: target))
      let reference = CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 10, height: 10),
        worldOrigin: .zero, revision: identity.revision, label: "Captured")
      let item = try #require(try store.readItemHeaders(limit: 1).first)
      #expect(try store.moveWorkspaceItem(itemID: item.id, in: header.rootBoardID, to: .init(x: 150, y: 0), actor: actor))
      #expect(throws: CollaborationError.self) {
        try store.appendContext(references: [reference], author: .human, actor: actor, select: true, sourceWorkspaceID: header.workspaceID)
      }
      #expect(try store.sharedContexts(contextID: nil).contexts.isEmpty)
    }
  }
}
