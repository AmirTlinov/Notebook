import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookScenePublicationTests: XCTestCase {
  func testEquivalentReadInstallKeepsConcurrentReadAdmittedAndActualEditInvalidatesIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scene-admission-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let presence = try XCTUnwrap(model.presence), target = CollaborationTarget(kind: .board, id: presence.boardID)
    let reference = EditableElementReference.spatial(boardID: presence.boardID, elementID: "read-source")
    let first = model.readAdmission.begin(), second = model.readAdmission.begin()
    defer { model.readAdmission.end(first); model.readAdmission.end(second) }
    _ = try model.store.applyNativeElementEdits([.init(kind: .insertElement, target: target, id: reference.elementID,
      values: ["kind": .string("graphic"), "source": .string(""),
        "frame": .encode(PageRect(x: 20, y: 30, width: 100, height: 80)),
        "worldOrigin": .encode(WorldPoint.zero), "graphic": .encode(NotebookGraphic(shape: .rectangle))])],
      summary: "Сцена из SQL", sources: [model.store.readNativeElementSource(target: target, id: reference.elementID)], actor: model.actorID)
    let state = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport,
      pinnedElements: [presence.boardID: [reference.elementID]], historyActor: model.actorID)
    XCTAssertTrue(model.acceptExternalScene(state, admission: first, observedPresence: presence,
      observedPreparation: presence, itemPins: [:]))
    XCTAssertEqual(model.workspaceHeader, state.header)
    XCTAssertEqual(model.sceneContentCursor, state.header.cursor)
    XCTAssertEqual(model.nativeElementSource(reference)?.spatial, state.elementSource(reference)?.spatial)
    XCTAssertTrue(model.acceptExternalScene(state, admission: second, observedPresence: presence,
      observedPreparation: presence, itemPins: [:]), "An equivalent read installation cannot invent an accepted local mutation")

    let overtaken = model.readAdmission.begin(); defer { model.readAdmission.end(overtaken) }
    XCTAssertTrue(model.performElementOperation(.updateElement, reference: reference,
      values: ["frame": try .encode(PageRect(x: 60, y: 30, width: 100, height: 80))], summary: "Новая правка"))
    XCTAssertFalse(model.acceptExternalScene(state, admission: overtaken, observedPresence: presence,
      observedPreparation: presence, itemPins: [:]), "The real accepted writer slot invalidates an older read immediately")
    let edited = await model.finishPendingPersistence(); XCTAssertTrue(edited)
  }

  func testDurableResultSurvivesFailedRefreshThenDependentEditAndUndo() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scene-refresh-failure-\(UUID())")
    let store = NotebookStore(root: root), fault = NotebookSceneReadFault()
    let reader = NotebookSceneReader(store: store, beforeRead: { try fault.check() })
    let model = NotebookAppModel(store: store, startsNearbySync: false, backgroundSceneReader: reader)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let initiallySaved = await model.finishPendingPersistence(); XCTAssertTrue(initiallySaved)
    let page = try XCTUnwrap(model.activePage), target = CollaborationTarget(kind: .page, id: page.id)
    let reference = EditableElementReference.page(pageID: page.id, elementID: "dependent")
    let a = PageRect(x: 20, y: 30, width: 100, height: 80)
    let b = PageRect(x: 60, y: 30, width: 100, height: 80)
    let c = PageRect(x: 120, y: 30, width: 100, height: 80)
    _ = try store.applyNativeElementEdits([.init(kind: .insertElement, target: target, id: reference.elementID,
      values: ["kind": .string("graphic"), "source": .string(""), "frame": .encode(a),
        "graphic": .encode(NotebookGraphic(shape: .rectangle))])], summary: "Исходная фигура",
      sources: [store.readNativeElementSource(target: target, id: reference.elementID)], actor: model.actorID)
    await model.reloadExternalChanges()?.value
    XCTAssertEqual(model.nativeElementSource(reference)?.page?.frame, a)
    let installedCursor = model.sceneContentCursor
    fault.isUnavailable = true
    XCTAssertTrue(model.performElementOperation(.updateElement, reference: reference,
      values: ["frame": try .encode(b)], summary: "Первое движение"))
    let firstSaved = await model.finishPendingPersistence(boundary: .acceptedInput); XCTAssertTrue(firstSaved)
    await model.reloadExternalChanges()?.value
    let failedRefresh = await model.finishPendingPersistence(); XCTAssertFalse(failedRefresh)
    XCTAssertEqual(model.sceneContentCursor, installedCursor)
    XCTAssertEqual(model.nativeElementSource(reference)?.page?.frame, a)
    XCTAssertEqual(model.elementCommandDrafts[reference]?.frame, b)
    let predecessor = try XCTUnwrap(model.elementCommandSources[reference]).task
    XCTAssertEqual(try store.readNativeElementSource(target: target, id: reference.elementID).page?.frame, b)

    XCTAssertTrue(model.performElementOperation(.updateElement, reference: reference,
      values: ["frame": try .encode(c)], summary: "Зависимое движение"))
    let secondSaved = await model.finishPendingPersistence(boundary: .acceptedInput); XCTAssertTrue(secondSaved)
    XCTAssertEqual(try store.readNativeElementSource(target: target, id: reference.elementID).page?.frame, c)
    model.undoLastSurfaceAction()
    let undone = await model.finishPendingPersistence(boundary: .acceptedInput); XCTAssertTrue(undone)
    XCTAssertEqual(try store.readNativeElementSource(target: target, id: reference.elementID).page?.frame, b)
    fault.isUnavailable = false
    await model.reloadExternalChanges()?.value
    let recovered = await model.finishPendingPersistence(); XCTAssertTrue(recovered)
    XCTAssertEqual(model.nativeElementSource(reference)?.page?.frame, b)
    XCTAssertEqual(model.sceneContentCursor, model.workspaceHeader?.cursor)
    let retained = await predecessor.value
    XCTAssertEqual(retained?.page?.frame, b, "An admitted successor cannot rewrite an already accepted dependent's frozen result")
    XCTAssertNil(model.elementCommandSources[reference])
  }

  func testNewerWindowCursorCannotRetireUnobservedOutputAndPinnedTombstoneCan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("addressed-retirement-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let initial = try XCTUnwrap(model.presence)
    let presence = SessionPresence(boardID: initial.boardID, mode: .board, camera: .init(), viewport: .init(x: 300, y: 300))
    let target = CollaborationTarget(kind: .board, id: presence.boardID), id = "outside-window"
    let reference = EditableElementReference.spatial(boardID: presence.boardID, elementID: id)
    let source = try model.store.readNativeElementSource(target: target, id: id)
    let write = try model.store.applyNativeElementEdits([.init(kind: .insertElement, target: target, id: id,
      values: ["kind": .string("graphic"), "source": .string(""),
        "frame": .encode(PageRect(x: 20, y: 30, width: 100, height: 80)),
        "worldOrigin": .encode(WorldPoint(x: 20_000, y: 0)), "graphic": .encode(NotebookGraphic(shape: .rectangle))])],
      summary: "За окном", sources: [source], actor: model.actorID)
    let output = try XCTUnwrap(write.sources.first)
    let result = NotebookElementCommandResult(page: output.page, spatial: output.spatial, versions: output.versions, target: output.target)
    let dependency = Task<NotebookElementCommandResult?, Never> { result }
    let command = NotebookElementCommand(id: UUID(), task: dependency, cursor: try model.store.currentChangeCursor(), accepted: result)
    model.elementCommandSources[reference] = command
    model.elementCommandDrafts[reference] = .init(source: try XCTUnwrap(output.placementSource), graphic: output.spatial?.graphic)
    _ = try model.store.applyNativeElementEdits([.init(kind: .insertElement, target: target, id: "nearby",
      values: ["kind": .string("graphic"), "source": .string(""),
        "frame": .encode(PageRect(x: 0, y: 0, width: 30, height: 30)), "worldOrigin": .encode(WorldPoint.zero),
        "graphic": .encode(NotebookGraphic(shape: .ellipse))])], summary: "Новый общий курсор",
      sources: [model.store.readNativeElementSource(target: target, id: "nearby")], actor: model.actorID)
    let window = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport)
    XCTAssertGreaterThan(window.header.cursor, command.cursor!)
    XCTAssertNil(window.elementSource(reference))
    model.admitGraphicCommandSources(in: window)
    XCTAssertEqual(model.elementCommandSources[reference], command)
    XCTAssertNil(model.elementCommandDrafts[reference]?.publication)
    let addressed = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport,
      pinnedElements: [presence.boardID: [id]])
    model.admitGraphicCommandSources(in: addressed)
    XCTAssertNil(model.elementCommandSources[reference])
    XCTAssertEqual(model.elementCommandDrafts[reference]?.publication, output)
    let deletion = try model.store.applyNativeElementEdits([.init(kind: .removeElement, target: target, id: id, values: [:])],
      summary: "Удалить", sources: [output], actor: model.actorID)
    let hidden = try XCTUnwrap(deletion.sources.first), hiddenVersions = try XCTUnwrap(hidden.versions)
    XCTAssertEqual(hidden.spatial?.graphic?.visible, false)
    XCTAssertNotEqual(hiddenVersions, output.versions)
    model.elementCommandSources[reference] = command
    let unobserved = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport)
    XCTAssertGreaterThan(unobserved.header.cursor, command.cursor!)
    XCTAssertNil(unobserved.elementSource(reference))
    model.admitGraphicCommandSources(in: unobserved)
    XCTAssertEqual(model.elementCommandSources[reference], command)
    XCTAssertEqual(model.elementCommandDrafts[reference]?.publication, output)
    let removed = try NotebookSceneState.read(store: model.store, presence: presence, viewport: presence.viewport,
      pinnedElements: [presence.boardID: [id]])
    let tombstone = try XCTUnwrap(removed.elementSource(reference))
    XCTAssertEqual(tombstone, hidden, "The pinned cut observes the exact retained hidden body and its causal versions")
    XCTAssertEqual(tombstone.versions, hiddenVersions)
    XCTAssertTrue(tombstone.covers(output))
    XCTAssertFalse(removed.missingPinnedElements[presence.boardID]?.contains(id) == true)
    model.admitGraphicCommandSources(in: removed)
    XCTAssertNil(model.elementCommandSources[reference])
    XCTAssertEqual(model.elementCommandDrafts[reference]?.publication, tombstone)
    XCTAssertEqual(model.elementCommandDrafts[reference]?.graphic?.visible, false)
    model.retireUnshownGraphicCommands()
    XCTAssertNil(model.elementCommandDrafts[reference])
    let retained = await dependency.value
    XCTAssertEqual(retained?.spatial, output.spatial)
  }

  func testNewerPreparedCutSurvivesOldWorkerAndWaitsForInputAdmission() async throws {
    let actor = UUID(), (workspace, original) = source(actor: UUID())
    let owner = NotebookScenePublication(actorID: actor)
    let previousObserver = NotebookNavigationObservation.onWebPreparation
    var dispatched = 0, delivered = false
    NotebookNavigationObservation.onWebPreparation = { event, id, _, _ in
      guard id == actor else { return }
      if event == "scene_index_dispatched" { dispatched += 1 }
      if event == "scene_index_delivered" { delivered = true }
    }
    defer { NotebookNavigationObservation.onWebPreparation = previousObserver }
    owner.onPrepared = { [weak owner] in owner?.publish { _ in false } }
    owner.prepare(workspace: workspace, hierarchy: original, paperSizes: [:], coverageOnly: false)
    XCTAssertEqual(dispatched, 1, "Cold dispatch must precede the next UI opportunity")
    var newer = original
    let id = try XCTUnwrap(workspace.selectedItemID), destination = WorldPoint(x: 120, y: 75)
    XCTAssertTrue(newer.moveItem(id, in: workspace.rootBoardID, to: destination, actor: actor))
    owner.accept(.init(workspace: workspace, hierarchy: newer, paperSizes: [:]), hierarchy: newer, coverageOnly: false)
    try await NotebookPersistenceFenceContract.until { delivered }
    XCTAssertNil(owner.index)
    XCTAssertTrue(owner.isPending)
    XCTAssertEqual(dispatched, 1, "An already prepared SQL cut must not be rebuilt after the old worker finishes")
    owner.publish { _ in true }
    XCTAssertEqual(owner.index?.board(id: workspace.rootBoardID)?.placement(of: id)?.center, destination)
    XCTAssertEqual(owner.indexGeneration, 1)
    XCTAssertEqual(owner.publicationGeneration, 1)
    XCTAssertFalse(owner.isPending)

    // An independently prepared catalog refresh of the same source keeps the
    // displayed geometry generation, even while input holds structural changes.
    let generation = owner.index?.generationID
    owner.accept(.init(workspace: workspace, hierarchy: newer, paperSizes: [:]), hierarchy: newer, coverageOnly: false)
    XCTAssertEqual(owner.index?.generationID, generation)
    XCTAssertEqual(owner.indexGeneration, 1)
    XCTAssertEqual(owner.publicationGeneration, 2)
    XCTAssertFalse(owner.isPending)
  }

  func testWarmRequestsCoalesceAndCancelBeforeDeliveryJoinsTheDispatchedWorker() async throws {
    let actor = UUID(), (workspace, original) = source(actor: UUID())
    let owner = NotebookScenePublication(actorID: actor)
    let previousObserver = NotebookNavigationObservation.onWebPreparation
    var cancelledWorkerEnded = false, dispatched = 0
    NotebookNavigationObservation.onWebPreparation = { event, id, request, _ in
      guard id == actor else { return }
      if event == "scene_index_ended", request == "1" { cancelledWorkerEnded = true }
      if event == "scene_index_dispatched" { dispatched += 1 }
    }
    defer { NotebookNavigationObservation.onWebPreparation = previousObserver }
    owner.onPrepared = { [weak owner] in owner?.publish { _ in true } }
    owner.prepare(workspace: workspace, hierarchy: original, paperSizes: [:], coverageOnly: false)
    let cancelled = try XCTUnwrap(owner.cancel())
    XCTAssertNil(owner.index)
    XCTAssertFalse(owner.isPending)
    XCTAssertEqual(owner.publicationGeneration, 0)
    // Start the replacement before joining the old delivery. Its late result
    // must neither publish nor clear the replacement's driver.
    owner.prepare(workspace: workspace, hierarchy: original, paperSizes: [:], coverageOnly: false)
    await cancelled.value
    XCTAssertTrue(cancelledWorkerEnded, "Draining the driver joins its actual dispatched worker")
    try await NotebookPersistenceFenceContract.until { owner.index != nil }
    XCTAssertEqual(owner.publicationGeneration, 1)
    dispatched = 0
    var latest = original
    let id = try XCTUnwrap(workspace.selectedItemID)
    for step in 1...8 {
      XCTAssertTrue(latest.moveItem(id, in: workspace.rootBoardID, to: .init(x: Double(step) * 25, y: 0), actor: actor))
      owner.prepare(workspace: workspace, hierarchy: latest, paperSizes: [:], coverageOnly: false)
    }
    XCTAssertEqual(dispatched, 0, "Warm synchronous changes share their next delivery opportunity")
    try await NotebookPersistenceFenceContract.until { !owner.isPending }
    XCTAssertEqual(dispatched, 1)
    XCTAssertEqual(owner.indexGeneration, 2)
    XCTAssertEqual(owner.publicationGeneration, 2)
    XCTAssertEqual(owner.index?.board(id: workspace.rootBoardID)?.placement(of: id)?.center, .init(x: 200, y: 0))
  }

  private func source(actor: UUID) -> (WorkspaceIndex, BoardHierarchy) {
    let stamp = VersionStamp(counter: 0, actor: actor)
    let item = WorkspaceItem.notebook(title: "Scene publication", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs[0], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID, boards: [.init(id: workspace.rootBoardID,
      board: .init(freeItems: [.init(itemID: item.id, center: .zero, zIndex: 0, stamp: stamp)], elements: [], stamp: stamp))], stamp: stamp)
    return (workspace, hierarchy)
  }
}

private final class NotebookSceneReadFault: @unchecked Sendable {
  private let lock = NSLock()
  private var unavailable = false
  var isUnavailable: Bool {
    get { lock.lock(); defer { lock.unlock() }; return unavailable }
    set { lock.lock(); defer { lock.unlock() }; unavailable = newValue }
  }
  func check() throws {
    if isUnavailable { throw NSError(domain: "NotebookScenePublicationTests", code: 1) }
  }
}
