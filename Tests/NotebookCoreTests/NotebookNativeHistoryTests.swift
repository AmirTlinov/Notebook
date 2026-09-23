import Foundation
import Testing
@testable import NotebookCore

@Suite("Native history follows the material transaction")
struct NotebookNativeHistoryTests {
  private enum Failure: Error { case disk }
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let actor = UUID()
    let store: NotebookStore
    let pageID: UUID
    init() throws {
      store = .init(root: root)
      let (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      pageID = workspace.selectedPageID!
    }
    func append(_ id: UUID = UUID(), to destination: NotebookStore? = nil) throws -> NotebookPageInkCommand {
      let store = destination ?? store, page = try store.loadPage(pageID)
      let action = PageInkAction(id: id, tool: .pen, samples: [.init(point: .init(x: 10, y: 20), timeOffset: 0,
        width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
      let change = try page.prepareInkChange(.append(action), stamp: page.drawingStamp.advanced(by: actor)!)
      let command = NotebookPageInkCommand(change)
      _ = try store.commitPageInk(pageID: pageID, command: command)
      return command
    }
    func shape() throws -> CollaborationReceipt {
      let target = CollaborationTarget(kind: .page, id: pageID)
      return try store.applyNativeGraphicAction(.init(summary: "Figure", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
          .init(kind: .insertElement, target: target, id: "figure", values: ["kind": .string("graphic"), "source": .string(""),
            "frame": .encode(PageRect(x: 100, y: 100, width: 80, height: 70)), "graphic": .encode(NotebookGraphic())])]), actor: actor)
    }
  }

  @Test func mixedOrderAndItsInversesSurviveReopeningWithoutPrioritizingCommands() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let first = UUID(), last = UUID()
    _ = try f.append(first)
    let figure = try f.shape()
    let command = try f.append(last)
    let reopened = NotebookStore(root: f.root)
    #expect(try reopened.nativeHistory(domain: .page(f.pageID), actor: f.actor) == [.ink([first]), .command(figure.id), .ink([last])])
    _ = try reopened.commitPageInk(pageID: f.pageID, command: command)
    #expect(try reopened.nativeHistory(domain: .page(f.pageID), actor: f.actor).count == 3, "An uncertain append retry is not another gesture")
    let page = try reopened.loadPage(f.pageID)
    let undo = try page.prepareInkChange(.setActive([last],false), stamp: page.drawingStamp.advanced(by: f.actor)!)
    _ = try reopened.commitPageInk(pageID: f.pageID, command: .init(undo))
    #expect(try reopened.nativeHistory(domain: .page(f.pageID), actor: f.actor) == [.ink([first]), .command(figure.id)])
    _ = try reopened.undoCollaborationAction(figure.id, actor: f.actor)
    #expect(try NotebookStore(root: f.root).nativeHistory(domain: .page(f.pageID), actor: f.actor) == [.ink([first])])
    #expect(try reopened.nativeHistory(domain: .page(UUID()), actor: f.actor).isEmpty)
    #expect(try reopened.nativeHistory(domain: .page(f.pageID), actor: UUID()).isEmpty)
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func inkHistoryHasTheSameCommitOutcomeAsItsMaterial(_ fault: NotebookStorageFault) throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let id = UUID()
    let failing = NotebookStore(root: f.root) { point in
      if String(describing: point) == String(describing: fault) { throw Failure.disk }
    }
    #expect(throws: Failure.self) { try f.append(id, to: failing) }
    let committed: Bool
    if case .afterCommit = fault { committed = true } else { committed = false }
    #expect(try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor) == (committed ? [.ink([id])] : []))
    #expect((try f.store.loadPage(f.pageID).inkDrawing().action(id: id) != nil) == committed)
  }

  @Test func theDirectoryRetainsOnlyThirtyTwoIdentitiesAndNoMeasurements() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let ids = (0..<40).map { _ in UUID() }
    for id in ids { _ = try f.append(id) }
    let entries = try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor)
    #expect(entries == ids.suffix(32).map { .ink([$0]) })
    #expect(try JSONEncoder().encode(entries).count < 4096)
    #expect(try f.store.loadPage(f.pageID).inkDrawing().activeActions.count == 40)
  }

  @Test func portalCoverAndInnerBoardKeepSeparateOrdersDespiteTheSameUUID() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let workspace = try f.store.loadIndex(), before = try f.store.loadBoard(items: workspace.items)
    var next = workspace, tree = before
    let id = UUID()
    let created = next.createBoard(title: "Portal", actor: f.actor, boardID: id)
    let placed = tree.createBoard(id, in: workspace.rootBoardID, near: .zero, actor: f.actor)
    #expect(created != nil)
    #expect(placed)
    _ = try f.store.saveWorkspaceEdits(before: workspace, after: next, boardBefore: before, boardAfter: tree)
    func append(_ surface: SurfaceID, counter: UInt64) throws -> SpatialInkAction {
      let action = SpatialInkAction(tool: .pen, spans: [.init(surface: surface, samples: [.init(point: .init(x: 20, y: 20),
        worldPoint: surface.kind == .board ? .zero : nil, timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])],
        stamp: .init(counter: counter, actor: f.actor))
      _ = try f.store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      return action
    }
    let inner = try append(.board(id), counter: 1), cover = try append(.cover(id), counter: 2)
    let reopened = NotebookStore(root: f.root)
    #expect(try reopened.nativeHistory(domain: .board(id), actor: f.actor) == [.ink([inner.id])])
    #expect(try reopened.nativeHistory(domain: .cover(id), actor: f.actor) == [.ink([cover.id])])
    #expect(try reopened.nativeHistory(domain: .document(id), actor: f.actor).isEmpty)
    _ = try reopened.commitSpatialInk(.state(actionID: cover.id, creationStamp: cover.stamp, isActive: false,
      stateStamp: .init(counter: 3, actor: f.actor), journalStamp: .init(counter: 3, actor: f.actor)))
    #expect(try reopened.nativeHistory(domain: .board(id), actor: f.actor) == [.ink([inner.id])])
    #expect(try reopened.nativeHistory(domain: .cover(id), actor: f.actor).isEmpty)
  }

  @Test func aPeerInverseCannotRemainTheHeadOfLocalUndo() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let first = UUID(), last = UUID()
    _ = try f.append(first)
    let figure = try f.shape()
    _ = try f.append(last)
    let peer = UUID(), page = try f.store.loadPage(f.pageID)
    let change = try page.prepareInkChange(.setActive([last],false), stamp: page.drawingStamp.advanced(by: peer)!)
    _ = try f.store.commitPageInk(pageID: f.pageID, command: .init(change))
    _ = try f.store.undoCollaborationAction(figure.id, actor: peer)
    #expect(try NotebookStore(root: f.root).nativeHistory(domain: .page(f.pageID), actor: f.actor) == [.ink([first])])
  }

  @Test func nativeUndoKeepsPeerAdmissionButDoesNotWaitForItsOwnQueuedRelease() throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let figure = try f.shape(), peer = UUID(), target = CollaborationTarget(kind: .page, id: f.pageID)
    try f.store.saveInputActivity(.init(deviceID: f.actor, sessionID: UUID(), sequence: 1, targets: [target]))
    do {
      _ = try f.store.undoCollaborationAction(figure.id, actor: f.actor)
      Issue.record("The public entry point cannot borrow native input ownership")
    } catch let error as CollaborationError { #expect(error.code == "input_active") }
    try f.store.saveInputActivity(.init(deviceID: peer, sessionID: UUID(), sequence: 1, targets: [target]))
    do {
      _ = try f.store.undoNativeAction(figure.id, actor: f.actor)
      Issue.record("A peer's active contact must still prevent the inverse")
    } catch let error as CollaborationError { #expect(error.code == "input_active") }
    #expect(try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor) == [.command(figure.id)])
    try f.store.resetInputActivity(deviceID: peer)
    let undone = try f.store.undoNativeAction(figure.id, actor: f.actor)
    #expect(undone.undo != nil)
    #expect(try f.store.inputActivities().first?.isActive == true, "Undo cannot release a newer local contact")
    #expect(try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor).isEmpty)
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func nativeInverseAndHistoryRetryTheSameAtomicOutcome(_ fault: NotebookStorageFault) throws {
    let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let figure = try f.shape()
    let failing = NotebookStore(root: f.root) { point in
      if String(describing: point) == String(describing: fault) { throw Failure.disk }
    }
    #expect(throws: Failure.self) { try failing.undoNativeAction(figure.id, actor: f.actor) }
    let committed: Bool
    if case .afterCommit = fault { committed = true } else { committed = false }
    #expect((try f.store.collaborationAction(figure.id).undo != nil) == committed)
    #expect(try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor) == (committed ? [] : [.command(figure.id)]))
    let saved = try f.store.undoNativeAction(figure.id, actor: f.actor)
    #expect(try NotebookStore(root: f.root).undoNativeAction(figure.id, actor: f.actor) == saved)
    #expect(try f.store.nativeHistory(domain: .page(f.pageID), actor: f.actor).isEmpty)
  }

}
