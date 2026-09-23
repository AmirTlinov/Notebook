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

  @Test func pageInkRedoKeepsTheExactIdentityAndNewInputCutsOnlyItsOwnFuture() throws {
    let f=try Fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let first=UUID(),last=UUID();_ = try f.append(first);_ = try f.append(last)
    func change(_ id:UUID,_ active:Bool) throws {
      let page=try f.store.loadPage(f.pageID)
      let mutation=try page.prepareInkChange(.setActive([id],active),stamp:page.drawingStamp.advanced(by:f.actor)!)
      _ = try f.store.commitPageInk(pageID:f.pageID,command:.init(mutation,nativeRedo:active))
    }
    try change(last,false)
    let reopened=NotebookStore(root:f.root),domain=PencilUndoHistory.Domain.page(f.pageID)
    let gate=try #require(reopened.loadPage(f.pageID).inkDrawing().action(id:last)?.stateStamp)
    #expect(try reopened.nativeHistory(domain:domain,actor:f.actor) == [.ink([first])])
    #expect(try reopened.nativeRedoHistory(domain:domain,actor:f.actor) == [.inkRedo([last],gate)])
    try change(last,true)
    #expect(try reopened.nativeHistory(domain:domain,actor:f.actor) == [.ink([first]),.ink([last])])
    #expect(try reopened.nativeRedoHistory(domain:domain,actor:f.actor).isEmpty)
    try change(last,false)
    _ = try f.append()
    #expect(try reopened.nativeRedoHistory(domain:domain,actor:f.actor).isEmpty)
    #expect(throws:CollaborationError.self) { try change(last,true) }
    #expect(try reopened.loadPage(f.pageID).inkDrawing().action(id:last)?.isActive == false)
  }

  @Test func nativeRedoCreatesOneNewReversibleActionWithoutRevivingTheOldReceipt() throws {
    let f=try Fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let shape=try f.shape(),domain=PencilUndoHistory.Domain.page(f.pageID)
    _ = try f.store.undoNativeAction(shape.id,actor:f.actor)
    #expect(try f.store.nativeRedoHistory(domain:domain,actor:f.actor) == [.command(shape.id)])
    let repeatedID=UUID(),reopened=NotebookStore(root:f.root)
    let repeated=try reopened.redoNativeAction(shape.id,actionID:repeatedID,actor:f.actor)
    #expect(repeated.redoOf == shape.id)
    #expect(try reopened.redoNativeAction(shape.id,actionID:repeatedID,actor:f.actor) == repeated)
    #expect(try reopened.collaborationAction(shape.id).undo != nil)
    #expect(try reopened.loadPage(f.pageID).element(id:"figure") != nil)
    #expect(try reopened.nativeHistory(domain:domain,actor:f.actor) == [.command(repeatedID)])
    #expect(try reopened.nativeRedoHistory(domain:domain,actor:f.actor).isEmpty)
    _ = try reopened.undoNativeAction(repeatedID,actor:f.actor)
    #expect(try reopened.loadPage(f.pageID).element(id:"figure") == nil)
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func nativeRedoAndDirectoryCommitAtomicallyAndRetryByTheSameID(_ fault: NotebookStorageFault) throws {
    let f=try Fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let shape=try f.shape(),repeatedID=UUID(),domain=PencilUndoHistory.Domain.page(f.pageID)
    _ = try f.store.undoNativeAction(shape.id,actor:f.actor)
    let failing=NotebookStore(root:f.root) { point in
      if String(describing:point) == String(describing:fault) { throw Failure.disk }
    }
    #expect(throws:Failure.self) { try failing.redoNativeAction(shape.id,actionID:repeatedID,actor:f.actor) }
    let committed:Bool
    if case .afterCommit=fault { committed=true } else { committed=false }
    #expect((try f.store.loadPage(f.pageID).element(id:"figure") != nil) == committed)
    #expect(try f.store.nativeHistory(domain:domain,actor:f.actor) == (committed ? [.command(repeatedID)] : []))
    #expect(try f.store.nativeRedoHistory(domain:domain,actor:f.actor) == (committed ? [] : [.command(shape.id)]))
    let saved=try f.store.redoNativeAction(shape.id,actionID:repeatedID,actor:f.actor)
    #expect(saved.redoOf == shape.id)
    #expect(try f.store.nativeHistory(domain:domain,actor:f.actor) == [.command(repeatedID)])
  }

  @Test func peerEditOfSharedElementOrderAfterUndoCannotBeOverwrittenByRedo() throws {
    let f=try Fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let shape=try f.shape(),domain=PencilUndoHistory.Domain.page(f.pageID)
    _ = try f.store.undoNativeAction(shape.id,actor:f.actor)
    let peer=UUID(),target=CollaborationTarget(kind:.page,id:f.pageID)
    _ = try f.store.applyNativeGraphicAction(.init(summary:"Peer",expected:[
      .init(target:target,revision:f.store.targetContentRevision(target:target))],operations:[
        .init(kind:.insertElement,target:target,id:"peer",values:["kind":.string("graphic"),
          "source":.string(""),"frame":.encode(PageRect(x:200,y:100,width:70,height:50)),
          "graphic":.encode(NotebookGraphic())])]),actor:peer)
    #expect(throws:CollaborationError.self) {
      try f.store.redoNativeAction(shape.id,actionID:UUID(),actor:f.actor)
    }
    #expect(try f.store.loadPage(f.pageID).element(id:"peer") != nil)
    #expect(try f.store.loadPage(f.pageID).element(id:"figure") == nil)
    #expect(try f.store.nativeRedoHistory(domain:domain,actor:f.actor) == [.command(shape.id)])
  }

  @Test func sameValuePeerABAAfterUndoCannotBorrowTheInverseDot() throws {
    let f=try Fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    _ = try f.shape()
    let target=CollaborationTarget(kind:.page,id:f.pageID),peer=UUID()
    func update(_ source:String,_ actor:UUID) throws -> CollaborationReceipt {
      try f.store.applyNativeGraphicAction(.init(summary:"Source",expected:[
        .init(target:target,revision:f.store.targetContentRevision(target:target))],operations:[
          .init(kind:.updateElement,target:target,id:"figure",values:["source":.string(source)])]),actor:actor)
    }
    let changed=try update("before",f.actor)
    _ = try f.store.undoNativeAction(changed.id,actor:f.actor)
    _ = try update("other",peer)
    _ = try update("",peer)
    #expect(try f.store.loadPage(f.pageID).element(id:"figure")?.source == "")
    #expect(throws:CollaborationError.self) {
      try NotebookStore(root:f.root).redoNativeAction(changed.id,actionID:UUID(),actor:f.actor)
    }
    #expect(try f.store.loadPage(f.pageID).element(id:"figure")?.source == "")
  }

  @Test func pageInkRedoRejectsPeerABAOfItsCausalStateAfterColdReopen() throws {
    let f=try Fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let id=UUID(),peer=UUID(),domain=PencilUndoHistory.Domain.page(f.pageID)
    _ = try f.append(id)
    func set(_ active:Bool,_ actor:UUID) throws {
      let page=try f.store.loadPage(f.pageID)
      let changed=try page.prepareInkChange(.setActive([id],active),stamp:page.drawingStamp.advanced(by:actor)!)
      _ = try f.store.commitPageInk(pageID:f.pageID,command:.init(changed))
    }
    try set(false,f.actor)
    let ownGate=try #require(f.store.loadPage(f.pageID).inkDrawing().action(id:id)?.stateStamp)
    try set(true,peer);try set(false,peer)
    let cold=NotebookStore(root:f.root)
    #expect(try cold.nativeRedoHistory(domain:domain,actor:f.actor).isEmpty)
    #expect(try cold.loadPage(f.pageID).inkDrawing().action(id:id)?.isActive == false)
    let page=try cold.loadPage(f.pageID)
    let forged=try page.prepareInkChange(.setActive([id],true),stamp:page.drawingStamp.advanced(by:f.actor)!)
    #expect(forged.expectedVisibility[id]?.stateStamp != ownGate)
    #expect(throws:CollaborationError.self) {
      try cold.commitPageInk(pageID:f.pageID,command:.init(forged,nativeRedo:true))
    }
  }

  @Test func aStaleRedoHeadDoesNotExposeAnOlderUndoneContact() throws {
    let f=try Fixture();defer { try? FileManager.default.removeItem(at:f.root) }
    let first=UUID(),last=UUID(),peer=UUID(),domain=PencilUndoHistory.Domain.page(f.pageID)
    _ = try f.append(first);_ = try f.append(last)
    func set(_ id:UUID,_ active:Bool,_ actor:UUID) throws {
      let page=try f.store.loadPage(f.pageID)
      let mutation=try page.prepareInkChange(.setActive([id],active),stamp:page.drawingStamp.advanced(by:actor)!)
      _ = try f.store.commitPageInk(pageID:f.pageID,command:.init(mutation))
    }
    try set(last,false,f.actor);try set(first,false,f.actor)
    #expect(try f.store.nativeRedoHistory(domain:domain,actor:f.actor).count == 2)
    try set(first,true,peer);try set(first,false,peer)
    #expect(try NotebookStore(root:f.root).nativeRedoHistory(domain:domain,actor:f.actor).isEmpty)
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
    _ = try reopened.commitSpatialInk(.state(actionID: cover.id, creationStamp: cover.stamp, expectedStateStamp: cover.stateStamp, isActive: false,
      stateStamp: .init(counter: 3, actor: f.actor), journalStamp: .init(counter: 3, actor: f.actor)))
    #expect(try reopened.nativeHistory(domain: .board(id), actor: f.actor) == [.ink([inner.id])])
    #expect(try reopened.nativeHistory(domain: .cover(id), actor: f.actor).isEmpty)
    #expect(try reopened.nativeRedoHistory(domain:.cover(id),actor:f.actor)
      == [.inkRedo([cover.id],.init(counter:3,actor:f.actor))])
    #expect(try reopened.nativeRedoHistory(domain:.board(id),actor:f.actor).isEmpty)
    _ = try reopened.commitSpatialInk(.state(actionID:cover.id,creationStamp:cover.stamp,
      expectedStateStamp:.init(counter:3,actor:f.actor),isActive:true,
      stateStamp:.init(counter:4,actor:f.actor),journalStamp:.init(counter:4,actor:f.actor),nativeRedo:true))
    #expect(try reopened.nativeHistory(domain:.cover(id),actor:f.actor) == [.ink([cover.id])])
    #expect(try reopened.nativeHistory(domain:.board(id),actor:f.actor) == [.ink([inner.id])])
    _ = try reopened.commitSpatialInk(.state(actionID:cover.id,creationStamp:cover.stamp,
      expectedStateStamp:.init(counter:4,actor:f.actor),isActive:false,
      stateStamp:.init(counter:5,actor:f.actor),journalStamp:.init(counter:5,actor:f.actor)))
    let fresh = try append(.cover(id),counter:6)
    #expect(try reopened.nativeRedoHistory(domain:.cover(id),actor:f.actor).isEmpty)
    #expect(throws:CollaborationError.self) {
      try reopened.commitSpatialInk(.state(actionID:cover.id,creationStamp:cover.stamp,
        expectedStateStamp:.init(counter:5,actor:f.actor),isActive:true,
        stateStamp:.init(counter:7,actor:f.actor),journalStamp:.init(counter:7,actor:f.actor),nativeRedo:true))
    }
    #expect(try reopened.loadSpatialInk().actions.first(where:{$0.id == cover.id})?.isActive == false)
    #expect(try reopened.nativeHistory(domain:.cover(id),actor:f.actor) == [.ink([fresh.id])])
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
