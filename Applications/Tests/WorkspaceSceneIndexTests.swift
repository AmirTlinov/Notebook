import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class WorkspaceSceneIndexTests: XCTestCase {
  func testCoverEraserQueriesTheRetainedLocalIndexWithoutBoardFallback() throws {
    let actor=UUID(),stamp=VersionStamp(counter:0,actor:actor)
    let boardID=WorkspaceRoot.boardID,itemID=UUID(),pageID=UUID()
    let item=WorkspaceItem.notebook(id:itemID,title:"Cover",pageIDs:[pageID])
    let element=SpatialElement(id:"cover-text",surface:.cover(itemID),kind:.nativeText,
      frame:.init(x:20,y:30,width:180,height:80),source:"Visible",stamp:stamp)
    let board=BoardDocument(freeItems:[.init(itemID:itemID,center:.zero,zIndex:0,stamp:stamp)],
      elements:[element],stamp:stamp)
    let workspace=WorkspaceIndex(items:[item],selectedItemID:itemID,selectedPageID:pageID,stamp:stamp)
    let hierarchy=BoardHierarchy(rootBoardID:boardID,boards:[.init(id:boardID,board:board)],stamp:stamp)
    let index=WorkspaceSceneIndex(workspace:workspace,hierarchy:hierarchy,paperSizes:[:])
    let eraser=NotebookSpatialEraserSource(boardID:boardID,index:index,
      graph:try XCTUnwrap(index.graphicGraph(boardID:boardID)),
      delta:.init(ids:[],elements:[:],excluded:[]))
    let result=try eraser.query(surface:.cover(itemID),
      bounds:.init(origin:.zero.offsetBy(x:10,y:20),width:40,height:40))
    XCTAssertEqual(result.targets.map(\.elementID),[element.id])
    XCTAssertNil(result.targets[0].worldOrigin)
    XCTAssertLessThan(result.visitedNodes,8)
  }

  func testOutsideStackFanStaysInTheIndexButCannotBecomeACameraDestination() throws {
    let actor = UUID(), first = WorkspaceItem.notebook(title: "Inside", pageIDs: [UUID()])
    let last = WorkspaceItem.notebook(title: "Outside", pageIDs: [UUID()])
    let stamp = VersionStamp(counter: 0, actor: actor)
    let stack = WorkspaceItemStack(center: .init(tileX: WorldPoint.maximumTileIndex,
      tileY: 0, localX: WorldPoint.tileSize - 1, localY: 100), zIndex: 0,
      itemIDs: [first.id, last.id], stamp: stamp)
    let workspace = WorkspaceIndex(items: [first, last], selectedItemID: first.id,
      selectedPageID: first.pageIDs[0], stamp: stamp)
    let boardID = WorkspaceRoot.boardID
    let hierarchy = BoardHierarchy(rootBoardID: boardID,
      boards: [.init(id: boardID, board: .init(freeItems: [], stacks: [stack], stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    XCTAssertNotNil(index.focusedCenter(itemID: first.id, boardID: boardID))
    XCTAssertNil(index.focusedCenter(itemID: last.id, boardID: boardID))
    let focus = try XCTUnwrap(WorkspaceItemStackPresentation.focusedCenter(of: last.id, in: stack))
    XCTAssertFalse(focus.isValid)
    let size = WorkspaceItemGeometry.notebook
    let fan = WorkspaceSpatialBounds(origin: focus.offsetBy(x: -size.width / 2, y: -size.height / 2),
      width: size.width, height: size.height)
    let page = try XCTUnwrap(index.readPaintOrder(boardID: boardID, bounds: fan))
    let entry = try XCTUnwrap(page.entries.first { $0.id == .item(last.id) })
    XCTAssertTrue(entry.bounds.contains(fan), "Address refusal must not shrink the rendered fan's indexed envelope")
  }

  func testColdSceneRestoresAnOutsideFanAsAnOverviewAtItsStoredAnchor() throws {
    try assertColdStackRestoration(firstCatalogueItemIsOutside: true)
  }

  func testColdSceneOpensTheInsideFanWhenItIsTheFirstCatalogueAddress() throws {
    try assertColdStackRestoration(firstCatalogueItemIsOutside: false)
  }

  private func assertColdStackRestoration(firstCatalogueItemIsOutside: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), viewport = SpatialPoint(x: 834, y: 1194)
    let pageSize = PageSize(width: viewport.x, height: viewport.y)
    // Without persisted presence, the scene selects the first UUID from the
    // addressed catalog, not the transient selection of a WorkspaceIndex.
    // Exercise both physical outcomes without letting random UUID order choose
    // which branch this test actually visits.
    let low = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
    let high = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"))
    let firstID = firstCatalogueItemIsOutside ? high : low
    let secondID = firstCatalogueItemIsOutside ? low : high
    let header = try store.initializeWorkspace(actor: actor, pageSize: pageSize, initialNotebookID: firstID)
    var workspace = try store.loadIndex()
    let second = try XCTUnwrap(workspace.createNotebook(title: "Outer fan", actor: actor,
      pageSize: pageSize, itemID: secondID))
    var hierarchy = try store.loadBoard(items: [workspace.items[0]])
    let anchor = WorldPoint(tileX: WorldPoint.maximumTileIndex, tileY: 0,
      localX: WorldPoint.tileSize - 1, localY: 100)
    XCTAssertTrue(hierarchy.moveItem(firstID, in: header.rootBoardID, to: anchor, actor: actor))
    XCTAssertTrue(hierarchy.addItem(second.item.id, to: header.rootBoardID, near: anchor, actor: actor))
    _ = try XCTUnwrap(hierarchy.createStack(moving: second.item.id, onto: firstID, in: header.rootBoardID, actor: actor))
    try store.saveWorkspaceBundle(index: workspace, page: second.page, board: hierarchy)
    let before = try store.workspaceHeader()
    XCTAssertNil(before.selectedItemID, "The fixture must not supply a stored selection")
    let selectedID = firstCatalogueItemIsOutside ? secondID : firstID
    XCTAssertEqual(try store.readItemHeaders(limit: 1).first?.id, selectedID)
    let insideFocus = try XCTUnwrap(hierarchy.focusedCenter(of: firstID, in: header.rootBoardID))
    let focus = try XCTUnwrap(hierarchy.focusedCenter(of: secondID, in: header.rootBoardID))
    XCTAssertTrue(insideFocus.isValid)
    XCTAssertFalse(focus.isValid)
    let scene = try NotebookSceneState.read(store: store, presence: nil, viewport: viewport)
    XCTAssertTrue(scene.presence.isValid)
    XCTAssertEqual(scene.presence.mode, firstCatalogueItemIsOutside ? .board : .page)
    XCTAssertEqual(scene.presence.camera.center, firstCatalogueItemIsOutside ? anchor : insideFocus)
    XCTAssertEqual(scene.presence.focusedItemID, firstCatalogueItemIsOutside ? nil : firstID)
    XCTAssertEqual(scene.presence.selectedItemID, selectedID)
    XCTAssertEqual(try store.workspaceHeader(), before, "Restoration cannot relocate the stack or rewrite the catalog")
    let size = WorkspaceItemGeometry.notebook
    let fan = WorkspaceSpatialBounds(origin: focus.offsetBy(x: -size.width / 2, y: -size.height / 2),
      width: size.width, height: size.height)
    let painted = try store.readScenePaintOrder(boardID: header.rootBoardID, bounds: fan)
    let entry = try XCTUnwrap(painted.entries.first { $0.id == .item(second.item.id) })
    XCTAssertTrue(entry.bounds.contains(fan), "SQLite retains the same outside projection, without encoding it as a physical address")
    let invalid = SessionPresence(mode: .board,
      camera: .init(center: focus), viewport: viewport)
    XCTAssertThrowsError(try NotebookSceneState.read(store: store, presence: invalid, viewport: viewport))
  }

  func testOneHundredThousandStoredItemsResolveFourVisibleOwnersWithoutCatalogScan() throws {
    let fixture = itemFixture(count: 100_000)
    let index = WorkspaceSceneIndex(workspace: fixture.workspace, hierarchy: fixture.hierarchy, paperSizes: [:])
    let boardID=WorkspaceRoot.boardID
    let firstBounds=try XCTUnwrap(index.paintEntry(id:.item(fixture.workspace.items[0].id),boardID:boardID)?.bounds)
    let selection=try XCTUnwrap(index.interactionCandidates(boardID:boardID,bounds:firstBounds,kinds:.items))
    XCTAssertEqual(selection.entries.map(\.id),[.item(fixture.workspace.items[0].id)])
    XCTAssertLessThan(selection.statistics.visitedNodes,256,
      "A local lasso must borrow the scene index instead of scanning one hundred thousand items")
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
    func mark(_ label:String) {
      var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
      let status=withUnsafeMutablePointer(to:&info) { pointer in pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
      print("GUI292 100k \(label): footprint=\(status == KERN_SUCCESS ? info.phys_footprint : 0), elementStride=\(MemoryLayout<SpatialElement>.stride), sourceStride=\(MemoryLayout<NotebookElementPlacement.Source>.stride)");fflush(stdout)
    }
    mark("start")
    let count = 100_000
    let actor = UUID(), itemID = UUID(), boardID = WorkspaceRoot.boardID
    let stamp = VersionStamp(counter: 0, actor: actor)
    let item = WorkspaceItem.notebook(id: itemID, title: "Pinned notebook", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: itemID, selectedPageID: item.pageIDs[0], stamp: stamp)
    let group=SpatialElement(id:"metadata-group",surface:.board(boardID),kind:.group,
      frame:.init(x:0,y:0,width:180,height:160),worldOrigin:.zero,source:"",
      basis:.init(size:.init(x:180,y:160)),stamp:stamp)
    let children=(0..<4).map { index in
      SpatialElement(id:"metadata-\(index)",surface:.board(boardID),kind:.nativeText,
        frame:.init(x:Double(index)*20,y:0,width:18,height:16),worldOrigin:.zero,
        source:"Child \(index)",parentID:group.id,stamp:stamp)
    }
    let elements = [group] + children + (4..<(count - 1)).map {
      element($0, boardID: boardID, origin: .zero, actor: actor)
    }
    mark("sources")
    let board = BoardDocument(freeItems: [.init(itemID: itemID, center: .zero, zIndex: 0, stamp: stamp)],
      elements: elements, stamp: stamp)
    let graph=board.graphicGraph()
    let reverseStart=ProcessInfo.processInfo.systemUptime
    let descendants=graph.descendantIDs(of:[group.id])
    let reverseSeconds=ProcessInfo.processInfo.systemUptime-reverseStart
    let ancestryScanStart=ProcessInfo.processInfo.systemUptime
    let scanned=Set(board.elements.compactMap { element in
      graph.placement(element.id)?.descends(from:group.id) == true ? element.id : nil
    })
    let ancestryScanSeconds=ProcessInfo.processInfo.systemUptime-ancestryScanStart
    XCTAssertEqual(descendants,Set(children.map(\.id)));XCTAssertEqual(scanned,descendants)
    print("GUI285 100k live whole delta: retained_us=\(reverseSeconds*1_000_000), full_scan_us=\(ancestryScanSeconds*1_000_000), ratio=\(ancestryScanSeconds/max(reverseSeconds,Double.leastNonzeroMagnitude))");fflush(stdout)
    let lookupID=elements.last!.id,iterations=100
    var lookupChecksum=0,scanChecksum=0
    let lookupStart=ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations { lookupChecksum += board.element(id:lookupID)?.id.count ?? 0 }
    let lookupSeconds=ProcessInfo.processInfo.systemUptime-lookupStart
    let scanStart=ProcessInfo.processInfo.systemUptime
    for _ in 0..<iterations { scanChecksum += board.elements.first(where:{ $0.id == lookupID })?.id.count ?? 0 }
    let scanSeconds=ProcessInfo.processInfo.systemUptime-scanStart
    XCTAssertEqual(lookupChecksum,scanChecksum)
    print("GUI285 100k element source: retained_us=\(lookupSeconds*1_000_000/Double(iterations)), linear_us=\(scanSeconds*1_000_000/Double(iterations)), ratio=\(scanSeconds/max(lookupSeconds,Double.leastNonzeroMagnitude))");fflush(stdout)
    let hierarchy = BoardHierarchy(rootBoardID: boardID, boards: [.init(id: boardID, board: board)], stamp: stamp)
    mark("hierarchy")
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    mark("index")
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

    XCTAssertThrowsError(try index.interactionCandidates(boardID:boardID,
      bounds:.init(origin:.zero,width:180,height:160),kinds:.elements,limit:96)) { error in
      XCTAssertEqual((error as? CollaborationError)?.code,"selection_limit")
    }

    let eraser = NotebookSpatialEraserSource(boardID: boardID, index: index,
      graph: try XCTUnwrap(index.graphicGraph(boardID: boardID)),
      delta:.init(ids:[],elements:[:],excluded:[]))
    let emptyEraser = try eraser.query(surface: .board(boardID),
      bounds: .init(origin: .init(x: 1_000_000, y: 1_000_000), width: 24, height: 24))
    XCTAssertTrue(emptyEraser.targets.isEmpty)
    XCTAssertLessThan(emptyEraser.visitedNodes, 8,
      "Pencil-down and a local eraser segment borrow the retained tree instead of materializing 100k targets")
    XCTAssertThrowsError(try eraser.query(surface: .board(boardID),
      bounds: .init(origin: .zero, width: 180, height: 160), limit: 96)) { error in
      XCTAssertEqual((error as? CollaborationError)?.code,"eraser_limit",
        "Dense contact must fail explicitly instead of erasing an arbitrary prefix")
    }

    mark("visible query")
    let elsewhere = SessionPresence(mode: .board,
      camera: .init(center: .init(x: 100_000, y: 100_000), scale: 1), viewport: presence.viewport)
    let retained = index.workset(presence: elsewhere, pinned: pins, limit: limit)
    XCTAssertEqual(retained.items.map(\.id), [itemID])
    XCTAssertEqual(retained.elements.map(\.id), [elements.last!.id])
    XCTAssertTrue(retained.aggregates.isEmpty)
    mark("done")
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
    let model = await makeModel()
    let documentID = try XCTUnwrap(model.createDocument(at: .zero, paperSize: .letter))
    await model.finishPendingPersistence()
    var document = try model.store.loadDocument(documentID)
    XCTAssertTrue(document.replaceContent(blocks: document.blocks + [
      .interactive(id: "counter", html: "<button>Next</button>", initialState: .object(["step": .number(0)]))
    ], actor: model.actorID))
    _ = try model.store.saveMergedDocument(document)
    await model.reloadExternalChanges()?.value
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
    XCTAssertNil(model.documents[documentID], "Camera work does not hydrate a closed document body")
    document = try model.store.loadDocument(documentID)
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "A changed sentence", actor: model.actorID))
    _ = try model.store.saveMergedDocument(document)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    XCTAssertEqual(try model.store.loadDocument(documentID).blocks.first?.source, "A changed sentence")
    XCTAssertEqual(model.sceneIndexGeneration, generation, "Document text is not physical paper geometry")
    let presence = try XCTUnwrap(model.presence)
    model.updatePresence(.init(boardID: boardID, mode: .document,
      camera: presence.camera, viewport: viewport, focusedItemID: documentID,
      openProgress: 1, selectedItemID: documentID), settled: true)
    await model.finishPendingPersistence()
    await model.reloadExternalChanges()?.value
    try await waitForIndex(model)
    let openedGeneration = model.sceneIndexGeneration
    document = try XCTUnwrap(model.documents[documentID])
    XCTAssertNotNil(model.commitDocumentState(documentID: documentID, blockID: "counter",
      value: .object(["step": .number(2)]), sourceVersion: document.sourceVersion(blockID: "counter")))
    await model.finishPendingPersistence()
    try await waitForIndex(model)
    XCTAssertEqual(model.documentStates[documentID]?.value(for: "counter"), .object(["step": .number(2)]))
    XCTAssertEqual(model.sceneIndexGeneration, openedGeneration, "Interactive state does not rebuild spatial metadata")
  }

  @MainActor
  func testModelPublishesMovedAndDeletedSourceToItsExplicitBoardAfterNavigation() async throws {
    let model = await makeModel()
    let boardA = try XCTUnwrap(model.presence?.boardID)
    let boardB = try XCTUnwrap(model.createBoard(at: .init(x: 40_000, y: 40_000)))
    let creationSaved = await model.finishPendingPersistence()
    XCTAssertTrue(creationSaved, model.persistenceFailure ?? "")
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    var source = element(0, boardID: boardA, origin: .zero, actor: model.actorID)
    XCTAssertTrue(hierarchy.upsertElement(source, in: boardA, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    try await waitForIndex(model)
    let viewport = SpatialPoint(x: 1194, y: 834)
    let original = SessionPresence(boardID: boardA, mode: .board, camera: .init(scale: 0.5), viewport: viewport)
    let elsewhere = SessionPresence(boardID: boardB, mode: .board, camera: .init(scale: 0.5), viewport: viewport)
    model.updatePresence(elsewhere, settled: true)
    let originalRead = try await model.performStoreCommand { store in
      try store.readSceneWindow(boardID: boardA, bounds: NotebookSceneState.bounds(for: original))
    }
    XCTAssertEqual(originalRead.boards.first { $0.id == boardA }?.board.elements.map(\.id), [source.id])
    XCTAssertTrue(model.sceneWorkset(presence: elsewhere).elements.isEmpty)
    let oldGeneration = model.sceneIndexGeneration

    hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    let before = source.stamp
    XCTAssertTrue(source.update(source: "Human continuation", worldOrigin: .init(x: 20_000, y: 30_000), actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(source, in: boardA, expected: before, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    try await waitForIndex(model)
    XCTAssertGreaterThan(model.sceneIndexGeneration, oldGeneration)
    XCTAssertTrue(model.sceneWorkset(presence: original).elements.isEmpty)
    let moved = SessionPresence(boardID: boardA, mode: .board,
      camera: .init(center: .init(x: 20_000, y: 30_000), scale: 0.5), viewport: viewport)
    let movedRead = try await model.performStoreCommand { store in
      try store.readSceneWindow(boardID: boardA, bounds: NotebookSceneState.bounds(for: moved))
    }
    XCTAssertEqual(movedRead.boards.first { $0.id == boardA }?.board.elements.first?.source, "Human continuation")
    XCTAssertNil(model.sceneIndex?.element(id: source.id, boardID: boardA),
      "Reading an addressed offscreen owner does not retain the archive in the scene")
    XCTAssertEqual(model.presence?.boardID, boardB, "Preparation does not take control of the person's camera")

    hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    XCTAssertEqual(hierarchy.removeElements(ids: [source.id], from: boardA, actor: model.actorID), 1)
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    try await waitForIndex(model)
    XCTAssertTrue(model.sceneWorkset(presence: moved, pinned: [.element(source.id)]).elements.isEmpty,
      "A pin cannot resurrect an owner deleted by the completed publication")
    await model.finishPendingPersistence()
  }

  @MainActor
  func testNotebookPageSequenceDoesNotWaitForSpatialPreparation() async throws {
    let model = await makeModel()
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
    XCTAssertNil(model.itemForDisplay(id: precedingID),
      "A durably deleted owner cannot be displayed while an unrelated contact delays scene publication")
    XCTAssertNotNil(model.itemForDisplay(id: itemID))
    for target in 1...3 {
      XCTAssertEqual(model.selectNotebookPage(target, notebookID: itemID, expectedRoot: model.notebookPageRoot(itemID) ?? ""), target)
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
    let model = await makeModel()
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
    let model = await makeModel()
    func assertSaved(_ phase: String) async {
      let saved = await model.finishPendingPersistence()
      XCTAssertTrue(saved, "\(phase): \(model.persistenceFailure ?? "unsuccessful source publication")")
    }
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    await assertSaved("Create parent portal")
    try await waitForIndex(model)
    XCTAssertTrue(model.enterBoard(childID))
    let itemID = try XCTUnwrap(model.createNotebook(at: .zero))
    await assertSaved("Create notebook in child")
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
    await assertSaved("Move item and normalize portal during contact")
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
    await assertSaved("Persist completed contact")
  }

  @MainActor
  func testLiveSceneMountsVisibleSVGWorksetInsteadOfThousandOffscreenWebViews() async throws {
    let model = await makeModel()
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
    defer { window.isHidden = true; window.rootViewController = nil; model.compositionTiles.cancelPreparation() }
    let deadline = ContinuousClock.now + .seconds(12)
    let workset = model.sceneWorkset(presence: presence)
    let visibleAddresses = Set(elements.prefix(4).map {
      SceneSourceAddress(plane: .board(boardID), elementID: $0.id)
    })
    XCTAssertEqual(workset.elements.count, 4)
    func visiblePixelsInstalled() -> Bool {
      guard let current = model.compositionTiles.published else { return false }
      return visibleAddresses.allSatisfy { current.hasInstalledPixels(for: $0) }
    }
    while !visiblePixelsInstalled(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertLessThanOrEqual(SceneRenderResources.shared.activeWebSurfaceCount, 6)
    }
    let cohort = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "")
    XCTAssertTrue(cohort.runtimeOwners.isEmpty, "Proven static SVGs need pixels, not persistent program runtimes")
    XCTAssertEqual(cohort.rasters.count, cohort.plan.tiles.count)
    XCTAssertLessThanOrEqual(cohort.plan.liveOwners.count + 1, 8)
    XCTAssertTrue(visiblePixelsInstalled())
    XCTAssertEqual(Set(cohort.sourceReceipts.keys), visibleAddresses,
      "The 996 offscreen drawings create neither preparation demand nor native owners")
    XCTAssertTrue(webViews(in: host.view).isEmpty)
    let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: picture)
    attachment.name = "Four independently ready static SVGs without persistent WebKit"
    attachment.lifetime = .keepAlways
    add(attachment)
    let generation = model.sceneIndexGeneration
    for frame in 0..<24 {
      model.updatePresence(.init(boardID: boardID, mode: .board,
        camera: .init(center: .init(x: Double(frame) / 4, y: 0), scale: 0.85 + Double(frame % 5) / 25),
        viewport: presence.viewport), settled: false)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertTrue(webViews(in: host.view).isEmpty)
      XCTAssertTrue(visiblePixelsInstalled(), "Camera movement preserves actual installed drawing pixels")
    }
    XCTAssertEqual(model.sceneIndexGeneration, generation)
    XCTAssertNil(model.interactiveElementFocus)
    model.updatePresence(presence, settled: true)
    let restoreDeadline = ContinuousClock.now + .seconds(10)
    while !visiblePixelsInstalled(), ContinuousClock.now < restoreDeadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(visiblePixelsInstalled())
    model.selectElement(.spatial(boardID: boardID, elementID: elements[4].id))
    let offscreenAddress = SceneSourceAddress(plane: .board(boardID), elementID: elements[4].id)
    let pinDeadline = ContinuousClock.now + .seconds(8)
    while model.compositionTiles.published?.sourceReceipts[offscreenAddress]?.hasCurrentPixels != true,
      ContinuousClock.now < pinDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let pinned = try XCTUnwrap(model.compositionTiles.published)
    let pinnedDemand = try XCTUnwrap(pinned.sourceReceipts[offscreenAddress]?.demand)
    let pinnedRaster = try XCTUnwrap(pinned.sourceRasters[offscreenAddress])
    XCTAssertNotNil(pinnedRaster.image(for: pinnedDemand.rasterSource, minimumScale: pinnedDemand.minimumScale),
      "The offscreen selection has an exact prepared source, without inventing mounted-pixel proof")
    XCTAssertFalse(pinned.runtimeOwners.contains(offscreenAddress))
    XCTAssertEqual(model.sceneWorkset(presence: try XCTUnwrap(model.presence),
      pinned: [.element(elements[4].id)]).elements.count, 5)
    model.endSurfaceEditing()
    let releaseDeadline = ContinuousClock.now + .seconds(5)
    while model.compositionTiles.published?.sourceReceipts[offscreenAddress] != nil,
      ContinuousClock.now < releaseDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(webViews(in: host.view).isEmpty)
    XCTAssertNil(model.compositionTiles.published?.sourceReceipts[offscreenAddress])
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
  private func makeModel() async -> NotebookAppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    return model
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
