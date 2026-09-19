import Foundation
import Testing
@testable import NotebookCore

@Suite("Scene pixels follow content, not navigation")
struct NotebookScenePaintRevisionTests {
  @Test func navigationAndOwnCameraKeepBoardPixelsButNestedCameraAndInkInvalidate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
    var next = workspace, tree = before
    let child = UUID()
    let created = next.createBoard(title: "Child", actor: actor, boardID: child)
    #expect(created != nil)
    let placed = tree.createBoard(child, in: header.rootBoardID, near: .zero, actor: actor)
    #expect(placed)
    _ = try store.saveWorkspaceEdits(before: workspace, after: next, boardBefore: before, boardAfter: tree)
    let board = CollaborationTarget(kind: .board, id: child)
    let parent = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let first = try store.scenePaintRevision(target: board)
    let parentFirst = try store.scenePaintRevision(target: parent)
    let cursor = try store.workspaceHeader().cursor
    try store.savePresence(.init(boardID: child, mode: .board,
      camera: .init(center: .init(x: 300, y: 200), scale: 1.5), viewport: .init(x: 800, y: 600)))
    #expect(try store.workspaceHeader().cursor == cursor, "Presence is device-local, not a content commit")
    #expect(try store.scenePaintRevision(target: board) == first)
    #expect(try store.scenePaintRevision(target: parent) == parentFirst)
    var moved = tree
    let cameraChanged = moved.updatePortalCamera(.init(center: .init(x: 300, y: 200), scale: 1.5), for: child, actor: actor)
    #expect(cameraChanged)
    _ = try store.saveBoardEdits(before: tree, after: moved)
    #expect(try store.scenePaintRevision(target: board) == first, "Own entry camera is not content")
    #expect(try store.scenePaintRevision(target: parent) != parentFirst, "The parent paints the child's new portal camera")

    let surface = SurfaceID.board(child)
    var journal = SpatialInkJournal(stamp: .init(counter: 100, actor: actor))
    try store.saveSpatialInk(journal)
    let inkBefore = try store.scenePaintRevision(target: board)
    let action = SpatialInkAction(tool: .pen, spans: [.init(surface: surface, samples: [
      .init(point: .init(x: 10, y: 10), worldPoint: .init(x: 10, y: 10), timeOffset: 0,
        width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], stamp: .init(counter: 1, actor: UUID()))
    let merged = journal.merge(.init(actions: [action], stamp: action.stamp))
    #expect(merged)
    #expect(journal.stamp.counter == 100)
    try store.saveSpatialInk(journal)
    let withInk = try store.scenePaintRevision(target: board)
    #expect(withInk != inkBefore, "A lower-clock merge must invalidate pixels too")
    let undone = journal.deactivate(action.id, actor: actor)
    #expect(undone)
    try store.saveSpatialInk(journal)
    #expect(try store.scenePaintRevision(target: board) != withInk)
  }
}
