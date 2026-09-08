import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class WorkspaceSceneIndexTests: XCTestCase {
  func testOneHundredThousandStoredItemsResolveFourVisibleOwnersWithoutCatalogScan() throws {
    let fixture = itemFixture(count: 100_000)
    let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: fixture.hierarchy, paperSizes: [:])
    for offset in 0..<30 {
      let presence = SessionPresence(mode: .board,
        camera: .init(center: .init(x: 500 + Double(offset % 7), y: 700), scale: 0.4),
        viewport: .init(x: 1194, y: 834))
      let visible = index.workset(presence: presence)
      XCTAssertEqual(visible.items.count, 4)
      XCTAssertTrue(visible.aggregates.isEmpty)
      XCTAssertLessThanOrEqual(visible.examinedEntries, 16,
        "Four visible owners do not require examining one hundred thousand entries")
      XCTAssertLessThanOrEqual(visible.visitedNodes, 768)
      XCTAssertEqual(index.renderedItem(id: fixture.workspace.items.last!.id, presence: presence)?.id,
        fixture.workspace.items.last!.id, "Offscreen owners remain directly addressable")
    }
  }

  func testDenseMixedElementsProduceBoundedExplicitOverviewAndPreservePinnedOwners() throws {
    let count = 100_000
    let actor = UUID(), itemID = UUID(), boardID = WorkspaceRoot.boardID
    let stamp = VersionStamp(counter: 0, actor: actor)
    let item = WorkspaceItem.notebook(id: itemID, title: "Pinned notebook", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: itemID, selectedPageID: item.pageIDs[0], stamp: stamp)
    let elements = (0..<(count - 1)).map { element($0, boardID: boardID, origin: .zero, actor: actor) }
    let board = BoardDocument(freeItems: [.init(itemID: itemID, center: .zero, zIndex: 0, stamp: stamp)],
      elements: elements, stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID, board: board)], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(mode: .board, camera: .init(scale: 0.4), viewport: .init(x: 1194, y: 834))
    let limit = 48
    let pins: Set<WorkspaceSpatialID> = [.item(itemID), .element(elements.last!.id)]
    let visible = index.workset(presence: presence, pinned: pins, limit: limit)
    XCTAssertFalse(visible.aggregates.isEmpty, "Dense content is represented, not silently discarded")
    XCTAssertLessThanOrEqual(visible.items.count + visible.elements.count + visible.aggregates.count, limit + pins.count)
    XCTAssertEqual(visible.items.filter { $0.id == itemID }.count, 1)
    XCTAssertEqual(visible.elements.filter { $0.id == elements.last!.id }.count, 1)
    XCTAssertEqual(visible.items.count + visible.elements.count + visible.aggregates.reduce(0) { $0 + $1.count }, count,
      "Every coincident owner is represented once; pins are excluded from aggregate counts")
    XCTAssertLessThanOrEqual(visible.examinedEntries, limit)
    XCTAssertLessThanOrEqual(visible.visitedNodes, limit * 8)

    let elsewhere = SessionPresence(mode: .board,
      camera: .init(center: .init(x: 100_000, y: 100_000), scale: 1), viewport: presence.viewport)
    let retained = index.workset(presence: elsewhere, pinned: pins, limit: limit)
    XCTAssertEqual(retained.items.map(\.id), [itemID])
    XCTAssertEqual(retained.elements.map(\.id), [elements.last!.id])
    XCTAssertTrue(retained.aggregates.isEmpty)
  }

  func testPreparedProjectionKeepsLocalGeometryAfterTranslationAcrossDistantTiles() throws {
    let origin = WorldPoint(tileX: 1_000_000_000_000, tileY: -1_000_000_000_000, localX: 123.125, localY: 789.375)
    let fixture = itemFixture(count: 1000, origin: origin)
    let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: fixture.hierarchy, paperSizes: [:])
    let presence = SessionPresence(mode: .board,
      camera: .init(center: origin.offsetBy(x: 500, y: 700), scale: 0.4), viewport: .init(x: 1194, y: 834))
    let visible = index.workset(presence: presence)
    XCTAssertEqual(Set(visible.items.map(\.id)), Set([0, 1, 316, 317].map { fixture.workspace.items[$0].id }))
    let first = try XCTUnwrap(index.renderedItem(id: fixture.workspace.items[0].id, presence: presence))
    XCTAssertEqual(first.center, origin)
    let screen = presence.camera.worldToScreen(first.center, viewport: presence.viewport)
    XCTAssertEqual(screen.x, 397, accuracy: 0.000_001)
    XCTAssertEqual(screen.y, 137, accuracy: 0.000_001)
  }

  @MainActor
  func testCameraDocumentSourceAndInteractiveStateKeepPreparedGeometryGeneration() async throws {
    let (model, root) = makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let documentID = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .letter))
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let generation = model.sceneIndexGeneration
    let viewport = SpatialPoint(x: 1194, y: 834)
    for frame in 0..<240 {
      let presence = SessionPresence(boardID: boardID, mode: .board,
        camera: .init(center: .init(x: Double(frame), y: -Double(frame)),
          scale: 0.2 + Double(frame % 30) / 50), viewport: viewport)
      model.updatePresence(presence, settled: false)
      let result = model.sceneWorkset(presence: presence, pinned: [.item(documentID)])
      XCTAssertEqual(result.items.first { $0.id == documentID }?.geometry, .document(.letter))
    }
    XCTAssertEqual(model.sceneIndexGeneration, generation, "Camera changes query prepared metadata; they never rebuild it")
    model.updatePresence(try XCTUnwrap(model.presence), settled: true)
    await model.finishPendingPersistence()
    var document = try XCTUnwrap(model.documents[documentID])
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "A changed sentence", actor: model.actorID))
    model.receivePeerMessage(.document(document))
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    XCTAssertEqual(model.documents[documentID]?.blocks.first?.source, "A changed sentence")
    XCTAssertEqual(model.sceneIndexGeneration, generation, "Document text is not physical paper geometry")
    model.commitDocumentState(documentID: documentID, blockID: "body", value: .object(["step": .number(2)]))
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    XCTAssertEqual(model.documentStates[documentID]?.value(for: "body"), .object(["step": .number(2)]))
    XCTAssertEqual(model.sceneIndexGeneration, generation, "Interactive state does not rebuild spatial metadata")
  }

  @MainActor
  func testModelPublishesMovedAndDeletedSourceToItsExplicitBoardAfterNavigation() async throws {
    let (model, root) = makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let boardA = try XCTUnwrap(model.presence?.boardID)
    let boardB = try XCTUnwrap(model.createBoard(at: .init(x: 40_000, y: 40_000)))
    let creationSaved = await model.finishPendingPersistence()
    XCTAssertTrue(creationSaved, model.persistenceFailure ?? "")
    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    var source = element(0, boardID: boardA, origin: .zero, actor: model.actorID)
    XCTAssertTrue(hierarchy.upsertElement(source, in: boardA, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    await model.reloadExternalChanges()?.value
    try await waitForIndex(model)
    let viewport = SpatialPoint(x: 1194, y: 834)
    let original = SessionPresence(boardID: boardA, mode: .board, camera: .init(scale: 0.5), viewport: viewport)
    let elsewhere = SessionPresence(boardID: boardB, mode: .board, camera: .init(scale: 0.5), viewport: viewport)
    model.updatePresence(elsewhere, settled: true)
    XCTAssertEqual(model.sceneWorkset(presence: original).elements.map(\.id), [source.id])
    XCTAssertTrue(model.sceneWorkset(presence: elsewhere).elements.isEmpty)
    let oldGeneration = model.sceneIndexGeneration

    hierarchy = try XCTUnwrap(model.boardHierarchy)
    let before = source.stamp
    XCTAssertTrue(source.update(source: "Human continuation", worldOrigin: .init(x: 20_000, y: 30_000), actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(source, in: boardA, expected: before, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    await model.reloadExternalChanges()?.value
    try await waitForIndex(model)
    XCTAssertGreaterThan(model.sceneIndexGeneration, oldGeneration)
    XCTAssertTrue(model.sceneWorkset(presence: original).elements.isEmpty)
    let moved = SessionPresence(boardID: boardA, mode: .board,
      camera: .init(center: .init(x: 20_000, y: 30_000), scale: 0.5), viewport: viewport)
    XCTAssertEqual(model.sceneWorkset(presence: moved).elements.first?.source, "Human continuation")
    XCTAssertEqual(model.presence?.boardID, boardB, "Preparation does not take control of the person's camera")

    hierarchy = try XCTUnwrap(model.boardHierarchy)
    XCTAssertEqual(hierarchy.removeElements(ids: [source.id], from: boardA, actor: model.actorID), 1)
    try model.store.saveBoard(hierarchy, items: XCTUnwrap(model.workspace).items)
    await model.reloadExternalChanges()?.value
    try await waitForIndex(model)
    XCTAssertTrue(model.sceneWorkset(presence: moved, pinned: [.element(source.id)]).elements.isEmpty,
      "A pin cannot resurrect an owner deleted by the completed publication")
    await model.finishPendingPersistence()
  }

  @MainActor
  func testNotebookPageSequenceDoesNotWaitForSpatialPreparation() async throws {
    let (model, root) = makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let precedingID = try XCTUnwrap(model.workspace?.selectedItemID)
    let itemID = try XCTUnwrap(model.createNotebook(at: .zero))
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    let before = try XCTUnwrap(model.sceneIndex)
    XCTAssertEqual(before.item(id: itemID)?.pageIDs.count, 1)
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    let deleted = await model.deleteItem(precedingID)
    XCTAssertTrue(deleted)
    XCTAssertEqual(model.workspace?.items.first?.id, itemID,
      "Deleting the preceding owner shifts the current notebook away from its prepared catalog slot")
    for target in 1...3 {
      XCTAssertEqual(model.selectNotebookPage(target, notebookID: itemID), target)
      let current = try XCTUnwrap(model.itemForDisplay(id: itemID))
      XCTAssertEqual(current.pageIDs.count, target + 1)
      XCTAssertEqual(current.pageIDs[target], model.workspace?.selectedPageID,
        "The canonical page sequence accepts the next turn before spatial preparation can finish")
    }
    await model.finishPendingPersistence()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.sceneIndex?.generationID, before.generationID)
    XCTAssertEqual(model.sceneIndex?.item(id: itemID)?.pageIDs.count, 1,
      "The deliberately held presentation generation must not own the live page sequence")
    XCTAssertEqual(model.itemForDisplay(id: itemID)?.pageIDs.count, 4)
    model.inputGate.endContact(source: contact)
    try await waitForIndex(model)
    XCTAssertEqual(model.sceneIndex?.item(id: itemID)?.pageIDs.count, 4)
  }

  @MainActor
  func testPreparedReplacementWaitsForTheCurrentContactBeforePublishing() async throws {
    let (model, root) = makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID)
    let presence = try XCTUnwrap(model.presence)
    let before = try XCTUnwrap(model.sceneIndex?.renderedItem(id: itemID, presence: presence))
    let generation = model.sceneIndexGeneration
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    let destination = before.center.offsetBy(x: 20_000, y: 10_000)
    model.moveItem(itemID, to: destination)
    await model.finishPendingPersistence()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(model.scenePreparationPending)
    XCTAssertEqual(model.sceneIndexGeneration, generation)
    XCTAssertEqual(model.sceneIndex?.renderedItem(id: itemID, presence: presence)?.center, before.center,
      "Background completion cannot replace the physical composition underneath a live contact")
    model.inputGate.endContact(source: contact)
    try await waitForIndex(model)
    XCTAssertGreaterThan(model.sceneIndexGeneration, generation)
    XCTAssertEqual(model.sceneIndex?.renderedItem(id: itemID, presence: presence)?.center, destination)
    await model.finishPendingPersistence()
  }

  @MainActor
  func testGeometryAndPortalProjectionPublishTogetherAfterTheSameContact() async throws {
    let (model, root) = makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    XCTAssertTrue(model.enterBoard(childID))
    let itemID = try XCTUnwrap(model.createNotebook(at: .zero))
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    let oldPortal = try XCTUnwrap(model.scenePortalCamera(boardID: childID))
    let generation = model.sceneIndexGeneration
    let viewport = SpatialPoint(x: 1194, y: 834)
    let childPresence = SessionPresence(boardID: childID, mode: .board,
      camera: .init(center: .init(x: 1234, y: -567), scale: 0.8), viewport: viewport)
    model.updatePresence(childPresence, settled: true)
    let contact = UUID()
    model.inputGate.beginContact(source: contact)
    let destination = WorldPoint(x: 20_000, y: 10_000)
    model.moveItem(itemID, to: destination)
    XCTAssertTrue(model.leaveBoard())
    let expectedPortal = try XCTUnwrap(model.boardHierarchy?.portalCamera(childID))
    XCTAssertNotEqual(expectedPortal, oldPortal)
    await model.finishPendingPersistence()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(model.scenePreparationPending)
    XCTAssertEqual(model.sceneIndexGeneration, generation)
    XCTAssertEqual(model.scenePortalCamera(boardID: childID), oldPortal,
      "A newly normalized portal cannot show the new projection with the old geometry")
    XCTAssertEqual(model.sceneIndex?.renderedItem(id: itemID, presence: childPresence)?.center, .zero)
    model.inputGate.endContact(source: contact)
    try await waitForIndex(model)
    XCTAssertGreaterThan(model.sceneIndexGeneration, generation)
    XCTAssertEqual(model.scenePortalCamera(boardID: childID), expectedPortal)
    XCTAssertEqual(model.sceneIndex?.renderedItem(id: itemID, presence: childPresence)?.center, destination)
    await model.finishPendingPersistence()
  }

  @MainActor
  func testLiveSceneMountsVisibleSVGWorksetInsteadOfThousandOffscreenWebViews() async throws {
    let (model, root) = makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = try XCTUnwrap(model.workspace)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    let stamp = VersionStamp(counter: 1, actor: model.actorID)
    let elements = (0..<1000).map { index in
      let origin = index < 4
        ? WorldPoint(x: Double(index % 2) * 350 - 280, y: Double(index / 2) * 270 - 220)
        : WorldPoint(x: 100_000 + Double(index) * 500, y: 100_000)
      return SpatialElement(id: "visible-workset-\(index)", surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 180, height: 160), worldOrigin: origin,
        source: "Synthetic SVG \(index)",
        html: "<svg viewBox='0 0 180 160'><path d='M20 20L160 140M160 20L20 140' stroke='black'/></svg>", stamp: stamp)
    }
    let board = BoardDocument(freeItems: [.init(itemID: workspace.selectedItemID,
      center: .init(x: -100_000, y: -100_000), zIndex: 0, stamp: stamp)], elements: elements, stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID, board: board)], stamp: stamp)
    XCTAssertTrue(hierarchy.isValid(items: workspace.items))
    try model.store.saveBoard(hierarchy, items: workspace.items)
    await model.reloadExternalChanges()?.value
    try await waitForIndex(model)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.rootViewController = host
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(scale: 1),
      viewport: .init(x: window.bounds.width, y: window.bounds.height))
    model.updatePresence(presence, settled: true)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let deadline = ContinuousClock.now + .seconds(8)
    let workset = model.sceneWorkset(presence: presence)
    XCTAssertEqual(workset.elements.count, 4)
    while elements.prefix(4).contains(where: {
      SceneRenderResources.shared.image(for: agentElementSnapshotSource($0)) == nil
    }) || !webViews(in: host.view).isEmpty {
      guard ContinuousClock.now < deadline else { break }
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertLessThanOrEqual(webViews(in: host.view).count, 6)
    }
    XCTAssertTrue(elements.prefix(4).allSatisfy {
      SceneRenderResources.shared.image(for: agentElementSnapshotSource($0)) != nil
    })
    XCTAssertTrue(webViews(in: host.view).isEmpty,
      "Four visible SVGs keep their rasters, not four idle browser sessions")
    let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: picture)
    attachment.name = "Four visible SVG surfaces from a thousand stored sources"
    attachment.lifetime = .keepAlways
    add(attachment)
    let identities = Set(webViews(in: host.view).map(ObjectIdentifier.init))
    let generation = model.sceneIndexGeneration
    for frame in 0..<24 {
      model.updatePresence(.init(boardID: boardID, mode: .board,
        camera: .init(center: .init(x: Double(frame) / 4, y: 0), scale: 0.85 + Double(frame % 5) / 25),
        viewport: presence.viewport), settled: false)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(Set(webViews(in: host.view).map(ObjectIdentifier.init)), identities)
    }
    XCTAssertEqual(model.sceneIndexGeneration, generation)
    model.updatePresence(try XCTUnwrap(model.presence), settled: true)
    model.selectElement(.spatial(elementID: elements[4].id))
    let pinDeadline = ContinuousClock.now + .seconds(5)
    while SceneRenderResources.shared.image(for: agentElementSnapshotSource(elements[4])) == nil,
      ContinuousClock.now < pinDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(SceneRenderResources.shared.image(for: agentElementSnapshotSource(elements[4])),
      "The pinned offscreen owner gets a completed image through the same limited renderer")
    XCTAssertEqual(model.sceneWorkset(presence: try XCTUnwrap(model.presence),
      pinned: [.element(elements[4].id)]).elements.count, 5)
    model.clearElementSelection()
    let releaseDeadline = ContinuousClock.now + .seconds(5)
    while !webViews(in: host.view).isEmpty, ContinuousClock.now < releaseDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(webViews(in: host.view).isEmpty)
    XCTAssertEqual(model.sceneWorkset(presence: try XCTUnwrap(model.presence)).elements.count, 4)
    await model.finishPendingPersistence()
  }

  private func itemFixture(count: Int, origin: WorldPoint = .zero) -> (workspace: WorkspaceIndex, hierarchy: BoardHierarchy) {
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
    let items = (0..<count).map { index in
      WorkspaceItem.notebook(title: "Synthetic \(index)", pageIDs: [UUID()])
    }
    let placements = items.enumerated().map { index, item in
      FreeItemPlacement(itemID: item.id,
        center: origin.offsetBy(x: Double(index % 316) * 2000, y: Double(index / 316) * 2000),
        zIndex: index, stamp: stamp)
    }
    let workspace = WorkspaceIndex(items: items, selectedItemID: items[0].id, selectedPageID: items[0].pageIDs[0], stamp: stamp)
    let board = BoardDocument(freeItems: placements, stamp: stamp)
    return (workspace, BoardHierarchy(rootBoardID: WorkspaceRoot.boardID,
      boards: [.init(id: WorkspaceRoot.boardID, board: board)], stamp: .init(counter: 0, actor: actor)))
  }

  private func element(_ index: Int, boardID: UUID, origin: WorldPoint, actor: UUID) -> SpatialElement {
    let kinds: [SpatialElementKind] = [.nativeText, .markdown, .web]
    return SpatialElement(id: "metadata-\(index)", surface: .board(boardID), kind: kinds[index % kinds.count],
      frame: .init(x: 0, y: 0, width: 180, height: 160), worldOrigin: origin,
      source: "Synthetic \(index)", html: index % 3 == 2 ? "<svg viewBox='0 0 180 160'/>" : "",
      stamp: .init(counter: 0, actor: actor))
  }

  @MainActor
  private func makeModel() -> (NotebookAppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    return (model, root)
  }

  @MainActor
  private func waitForIndex(_ model: NotebookAppModel) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    repeat {
      await Task.yield()
      if model.sceneIndex != nil && !model.scenePreparationPending { return }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    XCTFail("The latest scene metadata was not published within ten seconds")
  }

  @MainActor
  private func webViews(in view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
  }
}
