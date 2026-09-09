import NotebookCore
import XCTest
@testable import Notebook

final class SharedAttentionTests: XCTestCase {
  @MainActor
  func testReceivedCatalogKeepsThePhysicalReadersSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let original = try XCTUnwrap(model.workspace)
    var presence = SessionPresence(boardID:original.rootBoardID,mode:.page,
      camera:.init(center:try XCTUnwrap(model.board?.focusedCenter(of:original.selectedItemID)),scale:1),
      viewport:.init(x:834,y:1194),focusedItemID:original.selectedItemID,openProgress:1)
    presence = presence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(presence,settled:true)
    let newItem = try XCTUnwrap(model.createNotebook(at:.init(x:1600,y:0)))
    model.selectItem(original.selectedItemID)
    var remote = try XCTUnwrap(model.collaborationContent)
    XCTAssertTrue(remote.workspace.selectItem(newItem,actor:UUID()))
    let encoded = try JSONEncoder().encode(remote.workspace)
    let values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNil(values["selectedItemID"])
    XCTAssertNil(values["selectedPageID"])
    let remoteRoot = root.appendingPathComponent("peer")
    let peer = NotebookStore(root: remoteRoot), peerID = UUID()
    await model.finishPendingPersistence()
    try NotebookPeerFixture.copy(from: model.store, to: peer, peerID: model.actorID)
    let remotePresence = try XCTUnwrap(model.presence).selecting(itemID: newItem,
      pageID: remote.workspace.selectedPageID)
    try peer.savePresence(remotePresence)
    try await NotebookPeerFixture.deliver(from: peer, to: model, peerID: peerID)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
    XCTAssertEqual(model.workspace?.selectedItemID,original.selectedItemID)
    XCTAssertEqual(model.workspace?.selectedPageID,original.selectedPageID)
    XCTAssertEqual(model.presence,presence)
  }

  @MainActor
  func testReferenceTracksItsPageWhenNotebookMovesAndSourceChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace), page = try XCTUnwrap(model.activePage)
    let center = try XCTUnwrap(model.board?.focusedCenter(of:workspace.selectedItemID))
    var presence = SessionPresence(boardID:workspace.rootBoardID,mode:.page,camera:.init(center:center,scale:1),
      viewport:.init(x:834,y:1194),focusedItemID:workspace.selectedItemID,openProgress:1)
    presence = presence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(presence,settled:true)
    try await waitForScene(model)
    let selection = try XCTUnwrap(NotebookAttentionProjection.capture(start:.init(x:100,y:100),end:.init(x:220,y:200),model:model,presence:presence,
      cohort: XCTUnwrap(model.compositionTiles.published), installedInk: [:]))
    let prepared = try await Task.detached { try selection.resolvedReferences() }.value
    let reference = try XCTUnwrap(prepared.first)
    XCTAssertEqual(reference.target,.init(kind:.page,id:page.id))
    XCTAssertEqual(model.locationTitle(for: reference), "Тетрадь · лист 1")
    model.isPointing = true
    model.publishHumanContext(selection)
    XCTAssertFalse(model.isPointing)
    XCTAssertFalse(model.referenceChanged(reference))
    model.moveItem(workspace.selectedItemID,to:center.offsetBy(x:100,y:50))
    try await waitForScene(model)
    XCTAssertFalse(model.referenceChanged(reference))
    let moved = try XCTUnwrap(NotebookAttentionProjection.frame(reference,model:model,presence:presence))
    XCTAssertEqual(moved.minX,200,accuracy:1)
    XCTAssertEqual(moved.minY,150,accuracy:1)
    let action = CollaborationAction(summary:"Подпись",expected:[.init(target:reference.target,revision:page.agentStamp.revision)],operations:[
      .init(kind:.insertElement,target:reference.target,id:"caption",values:["kind":.string("markdown"),"source":.string("Мысль"),"frame":.object(["x":.number(300),"y":.number(80),"width":.number(200),"height":.number(80)])])])
    _ = try model.store.applyCollaborationAction(action,actor:UUID()); await model.reloadExternalChanges()?.value
    XCTAssertFalse(model.referenceChanged(reference), "Без точного снимка области нельзя объявлять её изменённой")
    XCTAssertEqual(model.referenceStatusLabel(reference), "Проверяется область")
  }

  @MainActor
  func testDeliveryAndDisplayRequireDifferentEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store:.init(root:root),startsNearbySync:false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize:NotebookAppModel.defaultPageSize)
    let page = try XCTUnwrap(model.activePage), workspace = try XCTUnwrap(model.workspace)
    let target = CollaborationTarget(kind:.page,id:page.id)
    let action = CollaborationAction(summary:"Подпись",expected:[.init(target:target,revision:page.agentStamp.revision)],operations:[
      .init(kind:.insertElement,target:target,id:"caption",values:["kind":.string("web"),"source":.string("<p>Meaning</p>"),"frame":.object(["x":.number(300),"y":.number(80),"width":.number(200),"height":.number(80)])])])
    _ = try model.store.applyCollaborationAction(action,actor:UUID())
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    XCTAssertFalse(try XCTUnwrap(model.store.deviceActionReceipts().first).displayComplete)
    var presence = SessionPresence(boardID:workspace.rootBoardID,mode:.page,camera:.init(center:try XCTUnwrap(model.board?.focusedCenter(of:workspace.selectedItemID)),scale:1),viewport:.init(x:834,y:1194),focusedItemID:workspace.selectedItemID,openProgress:1)
    presence = presence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(presence,settled:true)
    try await waitForScene(model)
    model.confirmVisibleActions(presence:presence)
    await model.finishPendingPersistence()
    XCTAssertFalse(try XCTUnwrap(model.store.deviceActionReceipts().first).displayComplete)
    await model.refreshCollaborationDetails()
    model.confirmVisibleActions(presence:presence)
    await model.finishPendingPersistence()
    XCTAssertFalse(try XCTUnwrap(model.store.deviceActionReceipts().first).displayComplete, "Подготовленные адреса ещё не являются показом")
    model.pagePresented(try XCTUnwrap(model.activePage),ready:true)
    model.confirmVisibleActions(presence:presence)
    await model.finishPendingPersistence()
    XCTAssertTrue(try XCTUnwrap(model.store.deviceActionReceipts().first).displayComplete)
  }
  @MainActor
  func testOneAreaKeepsReferencesToSeveralPhysicalOwners() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    model.moveItem(first, to: .zero)
    let second = try XCTUnwrap(model.createNotebook(at: .init(x: 1100, y: 0)))
    let workspace = try XCTUnwrap(model.workspace)
    var presence = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
      camera: .init(center: .init(x: 550, y: 0), scale: 0.3), viewport: .init(x: 834, y: 1194))
    presence = presence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(presence, settled: true)
    try await waitForScene(model)
    let selection = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 80, y: 350), end: .init(x: 760, y: 850), model: model, presence: presence,
      cohort: XCTUnwrap(model.compositionTiles.published), installedInk: cohortInkSources(XCTUnwrap(model.compositionTiles.published))))
    let references = try await Task.detached { try selection.resolvedReferences() }.value
    XCTAssertTrue(references.contains { $0.target.id == first && $0.target.kind == .cover })
    XCTAssertTrue(references.contains { $0.target.id == second && $0.target.kind == .cover })
    model.publishHumanContext(selection)
    await model.finishPendingPersistence()
    let context = try XCTUnwrap(model.activeSharedContext)
    XCTAssertEqual(context.entries.first?.references, references)
    model.requestShow(try XCTUnwrap(references.first))
    XCTAssertEqual(model.returnPlaces.last?.presence, presence)
    model.requestReturnToPlace()
    XCTAssertEqual(model.requestedReturn?.presence, presence)
    XCTAssertNil(model.requestedReference)
  }

  @MainActor
  func testOverviewDoesNotAcknowledgeDetailedAgentResultAsShown() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: -20_000, y: -20_000))
    await model.finishPendingPersistence()
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let target = CollaborationTarget(kind: .board, id: boardID)
    let action = CollaborationAction(summary: "Два связанных пояснения",
      expected: [.init(target: target, revision: try XCTUnwrap(model.board).stamp.revision)],
      operations: (0..<2).map { index in
        .init(kind: .insertElement, target: target, id: "overview-caption-\(index)", values: [
          "kind": .string("nativeText"), "source": .string("Пояснение \(index)"),
          "frame": .object(["x": .number(0), "y": .number(0), "width": .number(100), "height": .number(80)]),
          "worldOrigin": .object(["tileX": .number(0), "tileY": .number(0),
            "localX": .number(Double(index) * 150), "localY": .number(0)])])
      })
    _ = try model.store.applyCollaborationAction(action, actor: UUID())
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    try await waitForScene(model)
    await model.refreshCollaborationDetails()
    var presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 100, y: 0), scale: 1), viewport: .init(x: 834, y: 1194))
    presence = presence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(presence, settled: true)
    let index = try XCTUnwrap(model.sceneIndex)
    let overview = index.workset(presence: presence, limit: 1)
    XCTAssertFalse(overview.aggregates.isEmpty)
    XCTAssertTrue(overview.elements.isEmpty)
    model.confirmVisibleActions(presence: presence, scene: overview)
    await model.finishPendingPersistence()
    XCTAssertFalse(try XCTUnwrap(model.store.deviceActionReceipts().first { $0.id == action.id }).displayComplete,
      "A region label is not the displayed source, even when its exact revision is saved")
    let otherGeneration = WorkspaceSceneIndex(workspace: try XCTUnwrap(model.workspace),
      hierarchy: try XCTUnwrap(model.boardHierarchy), paperSizes: model.documents.mapValues(\.paperSize)).workset(presence: presence)
    XCTAssertEqual(otherGeneration.elements.count, 2)
    XCTAssertNotEqual(otherGeneration.generationID, index.generationID)
    model.confirmVisibleActions(presence: presence, scene: otherGeneration)
    await model.finishPendingPersistence()
    XCTAssertFalse(try XCTUnwrap(model.store.deviceActionReceipts().first { $0.id == action.id }).displayComplete,
      "A callback from a different presentation generation cannot acknowledge the newly published sources")
    let detailed = index.workset(presence: presence)
    XCTAssertEqual(detailed.elements.count, 2)
    model.confirmVisibleActions(presence: presence, scene: detailed)
    await model.finishPendingPersistence()
    XCTAssertTrue(try XCTUnwrap(model.store.deviceActionReceipts().first { $0.id == action.id }).displayComplete)
  }

  @MainActor
  func testPointingReturnsTheToolBeforePreparationAndKeepsTheSeenSourceAfterNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(model.workspace?.selectedItemID)
    let page = try XCTUnwrap(model.activePage)
    let second = try XCTUnwrap(model.createNotebook(at: .init(x: 2000, y: 0)))
    model.selectItem(first)
    let workspace = try XCTUnwrap(model.workspace)
    let center = try XCTUnwrap(model.board?.focusedCenter(of: first))
    var presence = SessionPresence(boardID: workspace.rootBoardID, mode: .page,
      camera: .init(center: center, scale: 1), viewport: .init(x: 834, y: 1194), focusedItemID: first, openProgress: 1)
    presence = presence.selecting(itemID: model.presence?.selectedItemID, pageID: model.presence?.notebookPageID)
    model.updatePresence(presence, settled: true)
    try await waitForScene(model)
    let selection = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 100, y: 100),
      end: .init(x: 240, y: 180), model: model, presence: presence,
      cohort: XCTUnwrap(model.compositionTiles.published), installedInk: [:]))
    model.isPointing = true
    model.publishHumanContext(selection)
    XCTAssertFalse(model.isPointing, "A control action must not wait for JSON, hashing or the file lock")
    XCTAssertEqual(model.presence, presence)
    model.selectItem(second)
    var later = page
    XCTAssertTrue(later.replaceElements([.init(id: "later-text", kind: .markdown,
      frame: .init(x: 120, y: 120, width: 100, height: 40), source: "New meaning", html: "<p>New meaning</p>")], actor: UUID()))
    let laterPage = later
    _ = try await model.performStoreCommand { try $0.saveMergedPage(laterPage) }
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    let context = try XCTUnwrap(model.activeSharedContext)
    let reference = try XCTUnwrap(context.entries.first?.references.first)
    XCTAssertEqual(reference.target, .init(kind: .page, id: page.id))
    XCTAssertEqual(reference.revision, try NotebookStore.referenceRevision(target: reference.target,
      files: ["pages/\(page.id.uuidString.lowercased()).json": .encode(page)]))
    XCTAssertNotEqual(reference.revision, try model.store.referenceRevision(target: reference.target))
    XCTAssertEqual(model.workspace?.selectedItemID, second)
  }

  @MainActor
  private func waitForScene(_ model: NotebookAppModel) async throws {
    await model.finishPendingPersistence()
    let deadline = ContinuousClock.now + .seconds(5)
    while model.scenePreparationPending, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(model.scenePreparationPending)
    XCTAssertNotNil(model.sceneIndex)
    let presence = try XCTUnwrap(model.presence), index = try XCTUnwrap(model.sceneIndex)
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: model.scenePortalCamera)
    model.prepareComposition(presence: presence, frame: frame,
      pinned: presence.focusedItemID.map { [.item($0)] } ?? [], displayScale: 2)
    let compositionDeadline = ContinuousClock.now + .seconds(5)
    while model.compositionTiles.published?.plan.revision != model.workspaceHeader?.cursor,
      model.compositionTiles.failure == nil, ContinuousClock.now < compositionDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.compositionTiles.published?.plan.revision, model.workspaceHeader?.cursor,
      model.compositionTiles.failure ?? "A pointing contact needs a completed physical cohort")
  }
}
