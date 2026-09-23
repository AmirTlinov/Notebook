@testable import NotebookCore
import Darwin
import XCTest
@testable import Notebook

final class NotebookPersistenceTests: XCTestCase {
  private enum TestFailure: Error { case unavailable }

  @MainActor
  func testUnaddressableCreationCannotChangeOptimisticOrDurableOwners() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let initiallySaved = await model.finishPendingPersistence()
    XCTAssertTrue(initiallySaved)
    let workspace = model.workspace, hierarchy = model.boardHierarchy, presence = model.presence
    let header = try model.store.workspaceHeader(), pageIDs = Set(model.pages.keys)
    for tile in [WorldPoint.maximumTileIndex + 1, -WorldPoint.maximumTileIndex - 1] {
      let point = WorldPoint(tileX: tile, tileY: tile, localX: 0, localY: 0)
      XCTAssertNil(model.createNotebook(at: point))
      XCTAssertNil(model.createDocument(at: point, paperSize: .a4))
      XCTAssertNil(model.createBoard(at: point))
    }
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertEqual(model.workspace, workspace)
    XCTAssertEqual(model.boardHierarchy, hierarchy)
    XCTAssertEqual(model.presence, presence)
    XCTAssertEqual(Set(model.pages.keys), pageIDs)
    XCTAssertEqual(try model.store.workspaceHeader(), header)
  }

  @MainActor
  func testNativeCommitAdvancesRenderIdentityWithoutReplacingTheCameraOrLocalOwner() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    _ = await model.finishPendingPersistence()
    let item = try XCTUnwrap(model.presence?.selectedItemID)
    let before = try XCTUnwrap(model.workspaceHeader), presence = model.presence
    let center = WorldPoint(x: 140, y: -110)
    model.moveItem(item, to: center)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let after = try XCTUnwrap(model.workspaceHeader)
    XCTAssertGreaterThan(after.cursor, before.cursor,
      "A native write equal to its optimistic value is still a new durable render revision")
    XCTAssertEqual(after, try model.store.workspaceHeader())
    XCTAssertEqual(model.board?.focusedCenter(of: item), center)
    XCTAssertEqual(model.presence, presence)
  }

  @MainActor
  func testRejectedCommandDoesNotWakeDeliveryOrExecutorAsIfItCommitted() async throws {
    enum Rejected: Error { case sourceConflict }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = NotebookPersistenceQueue(store: .init(root: root))
    var commits = 0
    queue.onCommit = { _ in commits += 1 }
    do {
      let _: Bool = try await queue.submit(publishesChanges: true) { _ in throw Rejected.sourceConflict }
      XCTFail("The rejected command cannot report success")
    } catch Rejected.sourceConflict { }
    let saved = await queue.flush()
    XCTAssertTrue(saved, "A domain rejection does not poison the native input queue")
    XCTAssertEqual(commits, 0, "No commit notification may create a retry loop after a rejected command")
  }

  @MainActor
  func testRejectedAddressedInkReconcilesInsteadOfBlockingOrAnnouncingACommit() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let queue=NotebookPersistenceQueue(store:.init(root:root))
    var rejected=0,merged=0,commits=0
    queue.onCommit={ _ in commits += 1 };queue.onContentMerged={ merged += 1 }
    queue.enqueue(owner:.pageInk(UUID()),onRejected:{ error in
      XCTAssertEqual(error.code,"revision_conflict");rejected += 1
    }) { _ in throw CollaborationError("revision_conflict","The peer changed the gate") }
    queue.enqueue(owner:.pageInk(UUID())) { _ in false }
    let saved=await queue.flush()
    XCTAssertTrue(saved);XCTAssertNil(queue.failure);XCTAssertEqual(queue.pendingCount,0)
    XCTAssertEqual(rejected,1);XCTAssertEqual(merged,1);XCTAssertEqual(commits,1)
  }

  @MainActor
  func testPreparedRejectionDoesNotBlockIndependentAcceptedWrites() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let queue=NotebookPersistenceQueue(store:.init(root:root))
    var commits=0;queue.onCommit={ _ in commits += 1 }
    let rejected=queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> Int in
      { _ in throw CollaborationError("revision_conflict","Changed source") }
    },publishesChanges:true)
    let accepted=queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> Int in
      { _ in 7 }
    },publishesChanges:true)
    let flushed=await queue.flush();XCTAssertTrue(flushed)
    do { _=try await rejected.value;XCTFail("A stale command must be rejected") }
    catch let error as CollaborationError { XCTAssertEqual(error.code,"revision_conflict") }
    let value=try await accepted.value;XCTAssertEqual(value,7)
    XCTAssertNil(queue.failure);XCTAssertEqual(queue.pendingCount,0);XCTAssertEqual(commits,1)
  }

  @MainActor
  func testPreparedStorageFailureRetainsItsResultAndLaterAcceptedCommandsForRetry() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let ready=root.appendingPathComponent("ready"),first=root.appendingPathComponent("first")
    let queue=NotebookPersistenceQueue(store:.init(root:root))
    var commits=0;queue.onCommit={ _ in commits += 1 }
    let accepted=queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> Int in
      { _ in
        guard FileManager.default.fileExists(atPath:ready.path) else { throw TestFailure.unavailable }
        try Data("accepted".utf8).write(to:first);return 1
      }
    },publishesChanges:true)
    let failed=await queue.flush();XCTAssertFalse(failed)
    XCTAssertNotNil(queue.failure);XCTAssertEqual(queue.pendingCount,1);XCTAssertEqual(commits,0)
    let later=queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> Int in
      { _ in
        guard FileManager.default.fileExists(atPath:first.path) else { throw TestFailure.unavailable }
        return 2
      }
    },publishesChanges:true)
    XCTAssertEqual(queue.pendingCount,2,"Already blocked storage still retains a new accepted command")
    try Data().write(to:ready);queue.retry()
    let saved=await queue.flush();XCTAssertTrue(saved)
    let firstValue=try await accepted.value,laterValue=try await later.value
    XCTAssertEqual(firstValue,1);XCTAssertEqual(laterValue,2)
    XCTAssertEqual(commits,2);XCTAssertEqual(queue.pendingCount,0);XCTAssertNil(queue.failure)
  }

  @MainActor
  func testLostReadbackRetriesTheSavedActionAndRejectsAStaleDependentEdit() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    let (workspace,_)=try store.loadOrCreate(actor:actor,pageSize:NotebookAppModel.defaultPageSize)
    _=try store.loadOrCreateSpatialInk(actor:actor)
    let target=CollaborationTarget(kind:.page,id:try XCTUnwrap(workspace.selectedPageID))
    let queue=NotebookPersistenceQueue(store:store),readbackReady=root.appendingPathComponent("readback-ready")
    let actionID=UUID(),command=NotebookNativeElementCommand([.init(kind:.insertElement,target:target,id:"figure",values:[
      "kind":.string("graphic"),"source":.string(""),"graphic":try .encode(NotebookGraphic(shape:.rectangle)),
      "frame":try .encode(PageRect(x:20,y:20,width:100,height:100))])],summary:"Accepted figure",
      sources:[.init(target:target,id:"figure")],actionID:actionID,actor:actor)
    let saved=queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> NotebookNativeElementCommand.Output in
      { store in
        let result=try command.apply(to:store)
        guard FileManager.default.fileExists(atPath:readbackReady.path) else { throw TestFailure.unavailable }
        return result
      }
    },publishesChanges:true)
    let failed=await queue.flush();XCTAssertFalse(failed)
    let committed=try XCTUnwrap(store.readPageElement(pageID:target.id,elementID:"figure"))
    XCTAssertEqual(committed.frame.x,20)
    let peer=try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"figure",values:[
      "frame":try .encode(PageRect(x:160,y:20,width:100,height:100))])],summary:"Peer move",
      sources:[.init(target:target,id:"figure",page:committed)],actor:UUID())
    let dependent=queue.enqueuePreparedCommand(Task { () throws -> @Sendable (NotebookStore) throws -> CollaborationReceipt in
      let first=try await saved.value
      return { store in
        try store.applyNativeElementEdits([.init(kind:.removeElement,target:target,id:"figure")],summary:"Old cut",
          sources:first.sources,actor:actor).receipt
      }
    })
    try Data().write(to:readbackReady);queue.retry()
    let retried=await queue.flush();XCTAssertTrue(retried)
    let result=try await saved.value
    XCTAssertEqual(result.receipt.id,actionID);XCTAssertEqual(result.sources[0].page,committed)
    do { _=try await dependent.value;XCTFail("Retry cannot substitute a peer source for the accepted predecessor") }
    catch let error as CollaborationError { XCTAssertEqual(error.code,"revision_conflict") }
    XCTAssertEqual(try store.collaborationActions().count,2)
    XCTAssertEqual(try store.readPageElement(pageID:target.id,elementID:"figure"),peer.sources[0].page)
    XCTAssertNil(queue.failure);XCTAssertEqual(queue.pendingCount,0)
  }

  @MainActor
  func testBlockedStorageKeepsAcceptedFigureAndReleasesTheSaveBoundary() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store=NotebookStore(root:root),queue=NotebookPersistenceQueue(store:store)
    let model=NotebookAppModel(store:store,startsNearbySync:false,persistenceQueue:queue)
    retainNotebookUntilTeardown(model,removing:root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let initiallySaved=await model.finishPendingPersistence();XCTAssertTrue(initiallySaved)
    var page=try XCTUnwrap(model.activePage)
    let original=PageRect(x:20,y:30,width:100,height:100)
    XCTAssertTrue(page.replaceElements([.init(id:"retained",kind:.graphic,frame:original,source:"",html:"",
      graphic:.init(shape:.rectangle))],actor:model.actorID))
    try store.savePage(page);await model.reloadExternalChanges()?.value
    let ready=root.appendingPathComponent("ready")
    queue.enqueue { _ in
      guard FileManager.default.fileExists(atPath:ready.path) else { throw TestFailure.unavailable }
      return false
    }
    let reference=EditableElementReference.page(pageID:page.id,elementID:"retained")
    let moved=PageRect(x:180,y:30,width:100,height:100)
    XCTAssertTrue(model.performElementOperation(.updateElement,reference:reference,
      values:["frame":try .encode(moved)],summary:"Retained move"))
    model.clearSelection()
    let released=expectation(description:"Failed storage releases the save boundary, not the accepted edit")
    var saved:Bool?
    let waiting=Task { saved=await model.finishPendingPersistence();released.fulfill() }
    await fulfillment(of:[released],timeout:2)
    XCTAssertEqual(saved,false)
    XCTAssertNotNil(model.persistenceFailure)
    XCTAssertEqual(model.acceptedElementSource(reference)?.page?.frame,moved)
    XCTAssertEqual(try store.loadPage(page.id).element(id:"retained")?.frame,original)
    try Data().write(to:ready);queue.retry()
    await waiting.value
    let retried=await model.finishPendingPersistence();XCTAssertTrue(retried)
    XCTAssertEqual(try store.loadPage(page.id).element(id:"retained")?.frame,moved)
    XCTAssertNil(model.persistenceFailure)
  }

  @MainActor
  func testAcceptedUndoReservesItsWriterPositionBeforeTheNextContact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false, persistenceQueue: queue)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let initiallySaved = await model.finishPendingPersistence(); XCTAssertTrue(initiallySaved)
    var page = try XCTUnwrap(model.activePage)
    let pageID = page.id, original = PageRect(x: 20, y: 30, width: 100, height: 100)
    XCTAssertTrue(page.replaceElements([.init(id: "ordered", kind: .graphic, frame: original, source: "", html: "",
      graphic: .init(shape: .rectangle))], actor: model.actorID))
    try store.savePage(page); await model.reloadExternalChanges()?.value
    let blocker = try NotebookSQLWriteBlocker(store: store); defer { try? blocker.release() }
    XCTAssertTrue(model.performElementOperation(.updateElement, reference: .page(pageID: pageID, elementID: "ordered"),
      values: ["frame": try .encode(PageRect(x: 180, y: 30, width: 100, height: 100))], summary: "Move before Undo"))
    model.undoLastSurfaceAction()
    let reached = expectation(description: "A fence after accepted Undo must see the inverse, not the pending move")
    queue.enqueueCommand({ try $0.readPageElement(pageID: pageID, elementID: "ordered") }) { result in
      do { let element = try result.get(); XCTAssertEqual(element?.frame, original) }
      catch { XCTFail("\(error)") }
      reached.fulfill()
    }
    let action = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 400, y: 400), timeOffset: 0,
      width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: pageID))
    XCTAssertNotNil(model.acceptDrawingAction(action, pageID: pageID, stamp: stamp))
    try blocker.release()
    let persisted = await model.finishPendingPersistence(); XCTAssertTrue(persisted)
    await fulfillment(of: [reached], timeout: 2)
    let cold = NotebookStore(root: root)
    XCTAssertEqual(try cold.loadPage(pageID).element(id: "ordered")?.frame, original)
    XCTAssertEqual(try cold.loadPage(pageID).inkDrawing().action(id: action.id)?.isActive, true)
    XCTAssertEqual(try cold.nativeHistory(domain: .page(pageID), actor: model.actorID), [.ink([action.id])])
  }

  @MainActor
  func testAcceptedUndoSurvivesItsOwnStorageFailureAndReleasesTheSaveBoundary() async throws {
    for committed in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let blocked = root.appendingPathComponent("block-undo")
      let store = NotebookStore(root: root) { point in
        let matches: Bool
        switch point {
        case .beforeCommit: matches = !committed
        case .afterCommit: matches = committed
        default: matches = false
        }
        if matches, FileManager.default.fileExists(atPath: blocked.path) { throw TestFailure.unavailable }
      }
      let queue = NotebookPersistenceQueue(store: store)
      let model = NotebookAppModel(store: store, startsNearbySync: false, persistenceQueue: queue)
      retainNotebookUntilTeardown(model, removing: root)
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      let started = await model.finishPendingPersistence(); XCTAssertTrue(started)
      let pageID = try XCTUnwrap(model.activePage?.id), target = CollaborationTarget(kind: .page, id: pageID)
      let figure = try store.applyNativeGraphicAction(.init(summary: "Undo storage test", expected: [
        .init(target: target, revision: store.targetContentRevision(target: target))], operations: [
        .init(kind: .insertElement, target: target, id: "undo-fault", values: ["kind": .string("graphic"),
          "source": .string(""), "frame": try .encode(PageRect(x: 20, y: 20, width: 100, height: 100)),
          "graphic": try .encode(NotebookGraphic(shape: .rectangle))])]), actor: model.actorID)
      await model.reloadExternalChanges()?.value
      let ready = await model.finishPendingPersistence(); XCTAssertTrue(ready)
      try Data().write(to: blocked)
      defer { try? FileManager.default.removeItem(at: blocked); queue.retry() }
      model.undoCollaboration(figure.id)
      var saved: Bool?
      let released = expectation(description: "Failed Undo storage releases Save, not the inverse")
      let waiting = Task { saved = await model.finishPendingPersistence(); released.fulfill() }
      await fulfillment(of: [released], timeout: 2)
      XCTAssertEqual(saved, false); XCTAssertNotNil(model.persistenceFailure)
      XCTAssertEqual(try store.collaborationAction(figure.id).undo != nil, committed)
      let action = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 400, y: 400), timeOffset: 0,
        width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
      let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: pageID))
      XCTAssertNotNil(model.acceptDrawingAction(action, pageID: pageID, stamp: stamp))
      XCTAssertNil(try store.loadPage(pageID).inkDrawing().action(id: action.id))
      try FileManager.default.removeItem(at: blocked); queue.retry()
      await waiting.value
      let retried = await model.finishPendingPersistence(); XCTAssertTrue(retried)
      let cold = NotebookStore(root: root)
      XCTAssertNotNil(try cold.collaborationAction(figure.id).undo)
      XCTAssertEqual(try cold.loadPage(pageID).inkDrawing().action(id: action.id)?.isActive, true)
      XCTAssertEqual(try cold.nativeHistory(domain: .page(pageID), actor: model.actorID), [.ink([action.id])])
      XCTAssertEqual(try cold.collaborationActions().count, 1, "An uncertain inverse never becomes a second action")
      XCTAssertNil(model.persistenceFailure)
    }
  }

  @MainActor
  func testContentCommandDrainsTheLatestPencilGeneration() {
    let gate = NotebookInputGate(), page = UUID(), pencil = UUID()
    var tails: [NotebookInputCompletion] = []
    gate.registerPageFinisher(source: page) { _, completion in tails.append(completion) }
    gate.setCurrentPageSource(page, isCurrent: true)
    var ran = false
    gate.performAfterPageInput { ran = true }
    XCTAssertEqual(tails.count, 1)
    gate.beginPencilAction(source: pencil)
    gate.endPencilAction(source: pencil)
    tails.removeFirst()()
    XCTAssertFalse(ran, "The old tail cannot release a command past a new lifted contact")
    XCTAssertEqual(tails.count, 1)
    tails.removeFirst()()
    XCTAssertTrue(ran)
    gate.unregisterPageFinisher(source: page)
  }

  @MainActor
  func testDeletionWaitsAgainForASecondAlreadyLiftedPencilContact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    _ = model.createNotebook(at: .init(x: 1_000, y: 0))
    let initiallySaved = await model.finishPendingPersistence()
    XCTAssertTrue(initiallySaved)
    let pageSource = UUID(), pencilSource = UUID()
    let secondDrain = expectation(description: "The new serialization tail must also drain")
    var finishes = 0
    var held: [NotebookInputCompletion] = []
    var mayFinish = false
    model.inputGate.registerPageFinisher(source: pageSource) { _, completion in
      finishes += 1
      if finishes == 1 {
        completion()
        model.inputGate.beginPencilAction(source: pencilSource)
        model.inputGate.endPencilAction(source: pencilSource)
      } else if mayFinish {
        completion()
      } else {
        held.append(completion)
        if finishes == 2 { secondDrain.fulfill() }
      }
    }
    model.inputGate.setCurrentPageSource(pageSource, isCurrent: true)
    let deletion = Task { await model.deleteItem(first) }
    await fulfillment(of: [secondDrain], timeout: 2)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(model.inputGate.hasActivePencil)
    XCTAssertFalse(model.isItemBeingDeleted(first))
    XCTAssertTrue(model.workspace?.items.contains { $0.id == first } == true,
      "A lifted contact still owns its accepted, unpublished ink")
    mayFinish = true
    for completion in held { completion() }
    held = []
    let deleted = await deletion.value
    XCTAssertTrue(deleted)
    model.inputGate.unregisterPageFinisher(source: pageSource)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }

  @MainActor
  func testDeletionRechecksPencilAfterItsContinuationResumes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    _ = model.createNotebook(at: .init(x: 1_000, y: 0))
    let initiallySaved = await model.finishPendingPersistence()
    XCTAssertTrue(initiallySaved)
    let pageSource = UUID(), pencilSource = UUID()
    let resumed = expectation(description: "The finisher resumes before the next Pencil-down")
    var finishes = 0
    model.inputGate.registerPageFinisher(source: pageSource) { _, completion in
      finishes += 1
      completion()
      if finishes == 1 {
        model.inputGate.beginPencilAction(source: pencilSource)
        resumed.fulfill()
      }
    }
    model.inputGate.setCurrentPageSource(pageSource, isCurrent: true)
    let deletion = Task { await model.deleteItem(first) }
    await fulfillment(of: [resumed], timeout: 2)
    // Let the resumed deletion run while the new contact still owns its frame.
    for _ in 0..<20 { await Task.yield() }
    XCTAssertTrue(model.inputGate.hasActivePencil)
    XCTAssertFalse(model.isItemBeingDeleted(first))
    XCTAssertTrue(model.workspace?.items.contains { $0.id == first } == true)
    model.inputGate.endPencilAction(source: pencilSource)
    let deleted = await deletion.value
    XCTAssertTrue(deleted)
    XCTAssertGreaterThanOrEqual(finishes, 2)
    model.inputGate.unregisterPageFinisher(source: pageSource)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
  }

  @MainActor
  func testSelectionAndBoardEditDuringDeletionKeepTheirLaterCausalVersions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    let second = try XCTUnwrap(model.createNotebook(at: .init(x: 1_000, y: 0)))
    let third = try XCTUnwrap(model.createNotebook(at: .init(x: 2_000, y: 0)))
    model.selectItem(first)
    let initialSaved = await model.finishPendingPersistence()
    XCTAssertTrue(initialSaved)
    let counter = try XCTUnwrap(model.workspace?.stamp.counter)
    let firstPage = try XCTUnwrap(model.workspace?.selectedPageID)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let deletion = Task { await model.deleteItem(first) }
    let deadline = ContinuousClock.now + .seconds(2)
    while model.workspace?.stamp.counter == counter, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(try XCTUnwrap(model.workspace?.stamp.counter), counter,
      "A suspended deletion reserves its clock before another human command")
    XCTAssertTrue(model.isItemBeingDeleted(first))
    XCTAssertNil(model.selectNotebookPage(1, notebookID: first, expectedRoot: model.notebookPageRoot(first) ?? ""),
      "A deleted notebook cannot accept a new page behind its deletion fence")
    XCTAssertNil(model.reserveDrawingAction(pageID: firstPage))
    model.selectItem(third)
    let moved = WorldPoint(x: 1_100, y: 200)
    model.moveItem(second, to: moved)
    let current = try XCTUnwrap(model.presence)
    var nextPresence = SessionPresence(boardID: current.boardID, mode: .cover,
      camera: .init(center: .init(x: 2_000, y: 0), scale: 0.5), viewport: current.viewport,
      focusedItemID: third, openProgress: 0)
    nextPresence = nextPresence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(nextPresence, settled: true)
    try lock.release()
    let deleted = await deletion.value
    XCTAssertTrue(deleted)
    XCTAssertFalse(model.isItemBeingDeleted(first))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let index = try model.store.loadIndex()
    XCTAssertEqual(index.selectedItemID, third)
    XCTAssertEqual(model.workspace?.selectedItemID, third)
    XCTAssertFalse(index.items.contains { $0.id == first })
    let resolvedPage = try XCTUnwrap(index.item(id: third)?.pageIDs.first)
    XCTAssertEqual(model.presence, nextPresence.selecting(itemID: third, pageID: resolvedPage),
      "Addressed selection resolves the unknown page without changing the exact camera")
    let board = try model.store.loadBoard(items: index.items)
    XCTAssertEqual(board.board(index.rootBoardID)?.focusedCenter(of: second), moved)
  }

  @MainActor
  func testContactReleaseCannotOvertakeItsAcceptedInk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    let queue = NotebookPersistenceQueue(store: store)
    let log = root.appendingPathComponent("order")
    let owner = UUID(), page = UUID()
    for (key, value) in [(NotebookPersistenceQueue.Owner.page(page), "previous ink"),
      (.inputActivity(owner), "active"), (.page(page), "ink"), (.inputActivity(owner), "released")] {
      queue.enqueue(owner: key) { _ in
        let previous = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try (previous + value + "\n").write(to: log, atomically: true, encoding: .utf8)
        return false
      }
    }
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "previous ink\nactive\nink\nreleased\n")
  }

  @MainActor
  func testCreationCannotOvertakeAnAcceptedBoardMove() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    let center = WorldPoint(x: -30_000, y: -30_000)
    model.moveItem(first, to: center)
    let portal = try XCTUnwrap(model.createBoard(at: .zero))
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    let workspace = try model.store.loadIndex()
    let board = try model.store.loadBoard(items: workspace.items)
    XCTAssertNotNil(board.board(portal))
    XCTAssertEqual(board.board(workspace.rootBoardID)?.focusedCenter(of: first), center)
    XCTAssertEqual(model.workspaceHeader?.boardRevision, try model.store.workspaceHeader().boardRevision)
    XCTAssertEqual(model.boardHierarchy?.board(portal)?.stamp, board.board(portal)?.stamp)
  }

  @MainActor
  func testFirstStrokeOfProvisionalPageSurvivesDelayedCreationAndReload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let initialSaved = await model.finishPendingPersistence()
    XCTAssertTrue(initialSaved)
    let lock = try NotebookSQLWriteBlocker(store: model.store)
    defer { try? lock.release() }
    let item = try XCTUnwrap(model.workspace?.selectedItemID)
    XCTAssertEqual(model.selectNotebookPage(1, notebookID: item, expectedRoot: model.notebookPageRoot(item) ?? ""), 1)
    let pageID = try XCTUnwrap(model.activePage?.id)
    let stamp = try XCTUnwrap(model.reserveDrawingAction(pageID: pageID))
    let action = PageInkAction(tool: .pen, samples: [
      .init(point: .init(x: 20, y: 30), timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
      .init(point: .init(x: 120, y: 130), timeOffset: 0.1, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    ])
    let accepted = model.acceptDrawingAction(action, pageID: pageID, stamp: stamp)
    XCTAssertNotNil(accepted, "The contact finishes without waiting for the storage lock")
    try lock.release()
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertNil(model.persistenceFailure)
    let restored = try PageInkDrawing.decode(store.loadPage(pageID).drawingData)
    XCTAssertEqual(restored.activeActions.map(\.id), [action.id])
    XCTAssertTrue(try store.loadIndex().items.contains { $0.pageIDs.contains(pageID) })
  }

  @MainActor
  func testPeerDisconnectCannotBeOvertakenByAcceptedActiveContact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let peer = UUID(), generation = UUID()
    model.peerConnected(.init(deviceID: peer, workspaceID: try model.store.workspaceHeader().workspaceID,
      displayName: "Test Mac"), generation: generation)
    let activity = NotebookInputActivity(deviceID: peer, sessionID: UUID(), sequence: 1,
      targets: [.init(kind: .board, id: WorkspaceRoot.boardID)])
    model.receivePeerTransient(.inputActivity(activity), peerID: peer, generation: generation)
    model.peerDisconnected(peerID: peer, generation: generation)
    model.receivePeerTransient(.inputActivity(activity), peerID: peer, generation: generation)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    XCTAssertFalse(model.peerInputIsActive)
    XCTAssertFalse(try model.store.inputActivities().contains { $0.deviceID == peer })
  }

  @MainActor
  func testCreationFencePrecedesFirstStrokeAndFailedWriteIsRetried() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    let queue = NotebookPersistenceQueue(store: store)
    let ready = root.appendingPathComponent("ready")
    let owner = root.appendingPathComponent("owner")
    let ink = root.appendingPathComponent("ink")
    queue.enqueue { _ in
      guard FileManager.default.fileExists(atPath: ready.path) else { throw TestFailure.unavailable }
      try Data("page".utf8).write(to: owner)
      return false
    }
    queue.enqueue(owner: .page(UUID())) { _ in
      XCTAssertTrue(FileManager.default.fileExists(atPath: owner.path))
      try Data("first stroke".utf8).write(to: ink)
      return false
    }
    let failed = await queue.flush()
    XCTAssertFalse(failed)
    XCTAssertNotNil(queue.failure)
    XCTAssertEqual(queue.pendingCount, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ink.path))
    try Data().write(to: ready)
    queue.retry()
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertNil(queue.failure)
    XCTAssertEqual(try String(contentsOf: ink, encoding: .utf8), "first stroke")
  }

  @MainActor
  func testPageInkCoalescingRetainsThePendingElementSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let id = try XCTUnwrap(store.loadIndex().selectedPageID)
    var page = try store.loadPage(id)
    XCTAssertTrue(page.replaceElements([.init(id: "text", kind: .nativeText,
      frame: .init(x: 10, y: 10, width: 100, height: 50), source: "Keep", html: "Keep")], actor: actor))
    let acceptedPage = page
    let action = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 20, y: 20),
      timeOffset: 0, width: 3, opacity: 1, force: 0.5, azimuth: 0, altitude: 1)])
    let ink = try page.prepareInkChange(.append(action), stamp: .init(counter: 1, actor: actor))
    let queue = NotebookPersistenceQueue(store: store)
    queue.enqueue(owner: .page(id)) { try $0.savePage(acceptedPage); return false }
    queue.enqueue(owner:.pageInk(id)) { try $0.commitPageInk(pageID:id,command:.init(ink)).stamp != ink.stamp }
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    let restored = try store.loadPage(id)
    XCTAssertEqual(restored.elements, acceptedPage.elements)
    XCTAssertEqual(try PageInkDrawing.decode(restored.drawingData).actions.map(\.id), [action.id])
  }

  @MainActor
  func testCoalescingDoesNotCrossCreationOrDisconnectFence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepare()
    let queue = NotebookPersistenceQueue(store: store)
    let peer = UUID(), session = UUID()
    let board = CollaborationTarget(kind: .board, id: WorkspaceRoot.boardID)
    let active = NotebookInputActivity(deviceID: peer, sessionID: session, sequence: 1, targets: [board])
    queue.enqueue(owner: .inputActivity(peer)) { try $0.saveInputActivity(active); return false }
    queue.enqueue { try $0.resetInputActivities(); return false }
    let inactive = NotebookInputActivity(deviceID: peer, sessionID: UUID(), sequence: 1, targets: [])
    queue.enqueue(owner: .inputActivity(peer)) { try $0.saveInputActivity(inactive); return false }
    let saved = await queue.flush()
    XCTAssertTrue(saved)
    XCTAssertEqual(try store.inputActivities(), [inactive])
  }

  @MainActor
  func testQueuedCommandReceivesFailureWithoutLosingDurablePredecessor() async throws {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let queue = NotebookPersistenceQueue(store: store)
    queue.enqueue { _ in throw TestFailure.unavailable }
    do {
      let _: Int = try await queue.submit { _ in XCTFail("A command cannot overtake a failed save"); return 1 }
      XCTFail("Expected explicit persistence failure")
    } catch { XCTAssertNotNil(queue.failure) }
    XCTAssertEqual(queue.pendingCount, 1)
  }
}
