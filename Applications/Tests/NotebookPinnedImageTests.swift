import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class NotebookPinnedImageTests: XCTestCase {
  @MainActor
  func testExplicitProgramFreezeBindsSemanticObjectToSendPixelsAndResumesAfterSend() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try XCTUnwrap(model.activePage)
    let source = AgentElement(id: "semantic-wave", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 120),
      source: "Wave probe", html: "<canvas id='field' width='240' height='120' style='display:block;width:100%;height:100%'></canvas>", javaScript: """
      let phase=0;const canvas=document.getElementById('field'),ctx=canvas.getContext('2d');
      const draw=color=>{ctx.fillStyle=color;ctx.fillRect(0,0,240,120)};draw('green');
      notebook.lifecycle({pause:()=>{phase=.5;draw('red')},checkpoint:()=>({phase}),
        resume:()=>{phase=.75;draw('blue')}});
      notebook.semantic(()=>({objectID:'node:12:8',label:'Probe',anchor:{x:.5,y:.5},
        values:[{label:'u',value:2,unit:'mm'}],model:{phase}}));
      notebook.ready(Promise.resolve());
      """, state: .object(["phase": .number(0)]))
    page.replaceElements([source], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let resources = SceneRenderResources.shared, lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let owner = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: .display(scale: 2),
      onInteractionReady: { ready = $0 }, onState: { _, completion in completion(nil); return true })
    owner.programOwner = model
    let focus = InteractiveElementReference.page(pageID: page.id, elementID: source.id)
    owner.bindPresentation(to: focus)
    let web = AgentWebCoordinator.makeWebView(coordinator: owner)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 240, height: 120)
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(web); web.frame = host.view.bounds; window.layoutIfNeeded()
    defer { owner.invalidate(); lease.release(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    owner.load(source, basis: page.programStateBasis(source.id), in: web)
    var deadline = ContinuousClock.now + .seconds(10)
    while !ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(ready)
    let fragment = NotebookAttentionSelection.Fragment(target: .init(kind: .page, id: page.id),
      elementID: source.id, region: source.frame, worldOrigin: nil, pageIndex: nil, label: "Wave")
    model.publishHumanContext(NotebookAttentionSelection(fragments: [fragment], workspace: try XCTUnwrap(model.workspace),
      hierarchy: try XCTUnwrap(model.boardHierarchy), ink: try XCTUnwrap(model.spatialInk), pages: model.pages,
      documents: model.documents, states: model.documentStates))
    await model.finishPendingPersistence()
    deadline = ContinuousClock.now + .seconds(5)
    while model.agentQuestion == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(model.canFreezeProgramForAttention)
    await model.freezeProgramForAttention(); await model.finishPendingPersistence()
    deadline = ContinuousClock.now + .seconds(5)
    while model.selectionSession.isResolvingContext, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(model.agentRequestError)
    XCTAssertFalse(web.isUserInteractionEnabled)
    let question = try XCTUnwrap(model.agentQuestion), reference = try XCTUnwrap(question.references.first)
    let chat = try XCTUnwrap(model.chat)
    let captured = model.captureChatSubmissionContext(chat)
    _ = try await captured.prepare()
    let evidence = try XCTUnwrap(model.store.attentionEvidence(contextID: question.contextID, referenceID: reference.id))
    XCTAssertEqual(evidence.payload["programSemantic"]?["status"], .string("frozen_selection"))
    XCTAssertEqual(evidence.payload["programSemantic"]?["selection"]?["objectID"], .string("node:12:8"))
    XCTAssertEqual(evidence.payload["programSemantic"]?["selection"]?["model"]?["phase"], .number(0.5))
    let image = try XCTUnwrap(evidence.image); try image.validate(reference: reference)
    let red = try pixel(image.png, x: image.pixelWidth / 2, y: image.pixelHeight / 2)
    XCTAssertGreaterThan(red[0], 240); XCTAssertLessThan(red[2], 15)
    try await Task.sleep(for: .milliseconds(100))
    let color = try await web.evaluateJavaScript("Array.from(document.getElementById('field').getContext('2d').getImageData(120,60,1,1).data)") as? [Int]
    XCTAssertEqual(color, [0, 0, 255, 255], "Send resumes this same owner only after fixing the red frame")
    XCTAssertTrue(web.isUserInteractionEnabled)
    XCTAssertEqual(try model.store.attentionEvidence(contextID: question.contextID, referenceID: reference.id), evidence)
    await model.freezeProgramForAttention(); await model.finishPendingPersistence()
    deadline = ContinuousClock.now + .seconds(5)
    while model.selectionSession.isResolvingContext, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(web.isUserInteractionEnabled)
    var editedPage = try model.store.loadPage(page.id)
    let newer = try XCTUnwrap(editedPage.elements.first).updating(state: .object(["phase": .number(0.9)]))
    editedPage.replaceElements([newer], actor: model.actorID)
    try model.store.savePage(editedPage); await model.reloadExternalChanges()?.value
    owner.load(newer, basis: editedPage.programStateBasis(source.id), in: web)
    deadline = ContinuousClock.now + .seconds(5)
    while !owner.hasLiveSource(newer), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(owner.hasLiveSource(newer)); XCTAssertTrue(web.isUserInteractionEnabled)
    let updatedPhase = try await web.evaluateJavaScript("notebook.state.phase") as? Double
    XCTAssertEqual(updatedPhase, 0.9, "A newer accepted state resumes the old hold instead of being lost to suspended apply")
    XCTAssertEqual(try model.store.attentionEvidence(contextID: question.contextID, referenceID: reference.id), evidence)
    let attachment = XCTAttachment(data: image.png, uniformTypeIdentifier: "public.png")
    attachment.name = "semantic-send-frozen-red-frame"; attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testAreaCrossingPaperEdgeKeepsItsPageAndMixedElements() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try XCTUnwrap(model.activePage)
    let elements: [AgentElement] = [
      .init(id: "triangle", kind: .graphic, frame: .init(x: 20, y: 20, width: 80, height: 80),
        source: "", html: "", graphic: .init(shape: .triangle)),
      .init(id: "line", kind: .graphic, frame: .init(x: 20, y: 140, width: 120, height: 20),
        source: "", html: "", graphic: .init(shape: .connector,
          connection: .init(start: .init(point: .init(x: 0, y: 10)), end: .init(point: .init(x: 120, y: 10))))),
      .init(id: "text", kind: .markdown, frame: .init(x: 160, y: 20, width: 120, height: 80),
        source: "Selected text", html: "<p>Selected text</p>"),
      .init(id: "outside", kind: .graphic, frame: .init(x: 400, y: 400, width: 80, height: 80),
        source: "", html: "", graphic: .init(shape: .ellipse))
    ]
    XCTAssertTrue(page.replaceElements(elements, actor: model.actorID))
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let workspace = try XCTUnwrap(model.workspace)
    let center = try XCTUnwrap(model.boardHierarchy?.focusedCenter(of: workspace.selectedItemID, in: workspace.rootBoardID))
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .page,
      camera: .init(center: center, scale: 0.6), viewport: .init(x: 834, y: 1194),
      focusedItemID: workspace.selectedItemID, openProgress: 1, notebookPageID: page.id), settled: true)
    await model.finishPendingPersistence()
    try await mountNotebookScene(model)
    let presence = try XCTUnwrap(model.presence), cohort = try XCTUnwrap(model.compositionTiles.published)
    let item = try XCTUnwrap(model.presentedItem(id: workspace.selectedItemID, cohort: cohort, presence: presence))
    let box = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
    let scale = presence.camera.scale
    let top = CGPoint(x: box.x - 20, y: box.y - 20)
    let bottom = CGPoint(x: box.x + 300 * scale, y: box.y + 200 * scale)
    for (start, end) in [(top, bottom), (bottom, top)] {
      let selection = try XCTUnwrap(NotebookAttentionProjection.capture(start: start, end: end,
        model: model, presence: presence, cohort: cohort,
        installedInk: model.compositionTiles.surfaceRegistry.installedSources()))
      XCTAssertEqual(selection.fragments.count, 1)
      let reference = try XCTUnwrap(selection.resolvedReferences().first)
      XCTAssertEqual(reference.target, .init(kind: .page, id: page.id),
        "Crossing the paper edge must not select the board underneath its visible figures")
      guard reference.target.kind == .page else { continue }
      XCTAssertEqual(reference.region, .init(x: 0, y: 0, width: 300, height: 200))
      XCTAssertNil(reference.elementID)
      let source = try AgentPinnedSource.capture(requestID: UUID(), reference: reference, files: selection.sourceFiles())
      let ids = try XCTUnwrap(source.payload["elements"]?.decode([AgentElement].self)).map(\.id)
      XCTAssertEqual(Set(ids), ["triangle", "line", "text"])
    }
    XCTAssertNil(NotebookAttentionProjection.capture(start: .init(x: box.x - 40, y: box.y - 40),
      end: .init(x: box.x - 10, y: box.y - 10), model: model, presence: presence, cohort: cohort,
      installedInk: model.compositionTiles.surfaceRegistry.installedSources()),
      "A drag wholly outside open paper must not grant the board underneath it")
  }

  @MainActor
  func testWholeBoardSendCapturesInstalledPixelsAfterContextPublicationWithoutControlsOrLaterChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    model.moveItem(try await startedItem(model), to: .init(x: -30_000, y: -30_000))
    let initialSaved = await model.finishPendingPersistence(); XCTAssertTrue(initialSaved)
    let boardID = try XCTUnwrap(model.presence?.boardID)
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    var element = SpatialElement(id: "red-source", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 100, height: 60), worldOrigin: .zero,
      source: "Red SVG", html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 60'><rect width='100' height='60' fill='#ff0000'/></svg>",
      stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(scale: 1), viewport: .init(x: 512, y: 512))
    model.updatePresence(presence, settled: true)
    let window = try await mountNotebookScene(model)
    let address = SceneSourceAddress(plane: .board(boardID), elementID: element.id)
    let deadline = ContinuousClock.now + .seconds(8)
    while model.compositionTiles.published?.hasInstalledPixels(for: address) != true, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let current = try XCTUnwrap(model.presence), cohort = try XCTUnwrap(model.compositionTiles.published)
    XCTAssertTrue(cohort.hasInstalledPixels(for: address))
    // This green application-level overlay covers the source on the window.
    // A source-region PNG must come from the painted subtree beneath it.
    let overlay = UIView(frame: .init(x: 250, y: 250, width: 120, height: 80))
    overlay.backgroundColor = .green; window.addSubview(overlay)
    let selection = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 20, y: 20),
      end: .init(x: 490, y: 490), model: model, presence: current, cohort: cohort,
      installedInk: model.compositionTiles.surfaceRegistry.installedSources()))
    let references = try selection.resolvedReferences()
    let reference = try XCTUnwrap(references.first { $0.target.kind == .board && $0.elementID == nil })
    let fragment = try XCTUnwrap(selection.fragments.first { $0.id == reference.id })
    let capturedSources = NotebookWorkspacePresentedSources.current(model: model, cohort: cohort)
    model.publishHumanContext(selection)
    let contextSaved = await model.finishPendingPersistence(); XCTAssertTrue(contextSaved)
    let contextDeadline = ContinuousClock.now + .seconds(5)
    while model.activeSharedContext == nil, ContinuousClock.now < contextDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNotNil(model.activeSharedContext)
    while model.workspacePresentations.captureFailure(fragment: fragment, expectedSources: capturedSources) != nil,
      ContinuousClock.now < contextDeadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(model.workspacePresentations.captureFailure(fragment: fragment, expectedSources: capturedSources))
    let sent = selection.freezingSubmissionVisuals()
    overlay.removeFromSuperview()
    let previousStamp = element.stamp
    XCTAssertTrue(element.update(source: "Blue SVG",
      html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 60'><rect width='100' height='60' fill='#0000ff'/></svg>", actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(element, in: boardID, expected: previousStamp, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    let result = try await sent.renderPinnedImages(references: references)
    let image = try XCTUnwrap(result.images[reference.id], result.unavailable.description)
    try image.validate(reference: reference)
    let red = try pixel(image.png, x: Int(270 * image.pixelsPerPoint), y: Int(260 * image.pixelsPerPoint))
    XCTAssertGreaterThan(red[0], 240); XCTAssertLessThan(red[1], 15); XCTAssertLessThan(red[2], 15)
    let toolbarArea = try pixel(image.png, x: Int(50 * image.pixelsPerPoint), y: Int(30 * image.pixelsPerPoint))
    XCTAssertLessThan(toolbarArea[0], 240, "The white Space toolbar is outside the painted owner")
    let attachment = XCTAttachment(data: image.png, uniformTypeIdentifier: "public.png")
    attachment.name = "whole-board-send-red-source-without-green-overlay-or-toolbar"
    attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  private func startedItem(_ model: NotebookAppModel) async throws -> UUID {
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    return try XCTUnwrap(model.workspace?.selectedItemID)
  }

  @MainActor
  func testFrozenPageCropKeepsPenEraseOrderAndNeverIncludesOutsidePixels() async throws {
    let pen = PageInkAction(tool: .pen, color: .init(red: 1, green: 0, blue: 0),
      samples: [sample(5, 12, width: 6), sample(28, 12, width: 6)])
    let eraser = PageInkAction(tool: .eraser, samples: [sample(18, 12, width: 10)])
    let outside = PageInkAction(tool: .pen, color: .init(red: 0, green: 0, blue: 1),
      samples: [sample(40, 45, width: 8), sample(58, 45, width: 8)])
    let drawing = PageInkDrawing(actions: [pen, eraser, outside])
    var page = PageDocument(size: .init(width: 64, height: 64), actor: UUID(),
      drawingData: try drawing.dataRepresentation())
    let selection = selection(page: page, region: .init(x: 0, y: 0, width: 32, height: 32))
    let reference = try XCTUnwrap(selection.resolvedReferences().first)
    XCTAssertTrue(page.replaceDrawing(Data(), actor: UUID()), "A later edit cannot change the retained source")
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    let result = try await selection.renderPinnedImages(references: [reference], resources: resources)
    XCTAssertTrue(result.unavailable.isEmpty)
    let image = try XCTUnwrap(result.images[reference.id])
    try image.validate(reference: reference)
    XCTAssertEqual(image.pixelWidth, 64); XCTAssertEqual(image.pixelHeight, 64)
    let penPixel = try pixel(image.png, x: 20, y: 24)
    XCTAssertGreaterThan(penPixel[0], 240); XCTAssertLessThan(penPixel[1], 20)
    let erasedPixel = try pixel(image.png, x: 36, y: 24)
    XCTAssertGreaterThan(erasedPixel[0], 230); XCTAssertGreaterThan(erasedPixel[1], 230)
    XCTAssertFalse(try pixels(image.png).contains { $0[2] > 200 && $0[0] < 40 },
      "Blue handwriting outside the physical grant must not enter the returned PNG")
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testSelectedElementUsesTheContactRasterNotANewerAliasOrOtherLayers() async throws {
    let frame = PageRect(x: 0, y: 0, width: 32, height: 32)
    let selected = AgentElement(id: "selected", kind: .web, frame: frame, source: "A timer", html: "<canvas/>")
    let other = AgentElement(id: "outside-grant", kind: .web, frame: frame, source: "A different object", html: "<canvas/>")
    let page = PageDocument(size: .init(width: 64, height: 64), actor: UUID(), elements: [selected, other])
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    XCTAssertTrue(resources.store(bitmap(width: 32, height: 32, color: .red), for: selected))
    XCTAssertTrue(resources.store(bitmap(width: 32, height: 32, color: .blue), for: other))
    let selection = selection(page: page, region: frame, elementID: selected.id, resources: resources)
    let reference = try XCTUnwrap(selection.resolvedReferences().first)
    // Even an animation with unchanged program/state may publish a newer frame.
    XCTAssertTrue(resources.store(bitmap(width: 32, height: 32, color: .green), for: selected))
    let result = try await selection.renderPinnedImages(references: [reference], resources: resources)
    let image = try XCTUnwrap(result.images[reference.id])
    let value = try pixel(image.png, x: 24, y: 24)
    XCTAssertGreaterThan(value[0], 240); XCTAssertLessThan(value[1], 10); XCTAssertLessThan(value[2], 10)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "Historical pixels must never restart the JavaScript program")
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  @MainActor
  func testSendingCannotReplaceAMissingLiveOwnerWithAnOldCachedProgramFrame() async throws {
    let element = AgentElement(id: "animated", kind: .web, frame: .init(x: 0, y: 0, width: 32, height: 32),
      source: "Animated program", html: "<canvas/>")
    let page = PageDocument(size: .init(width: 64, height: 64), actor: UUID(), elements: [element])
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    XCTAssertTrue(resources.store(bitmap(width: 32, height: 32, color: .red), for: element))
    let captured = selection(page: page, region: element.frame, elementID: element.id,
      resources: resources, capturesLivePrograms: true)
    let reference = try XCTUnwrap(captured.resolvedReferences().first)
    let sent = captured.freezingSubmissionVisuals()
    let visual = try await sent.renderPinnedImages(references: [reference], resources: resources)
    XCTAssertNil(visual.images[reference.id])
    XCTAssertEqual(visual.unavailable[reference.id], "snapshot_pending: historical_live_frame_unavailable")
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "Sending must never start a replacement program")
  }

  @MainActor
  func testFrozenLargeElementKeepsInstalledCropOriginDensityAndEntry() async throws {
    let stamp = VersionStamp(counter: 0, actor: UUID())
    let paper = WorkspaceItem.notebook(title: "Other paper", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [paper], selectedItemID: paper.id, selectedPageID: paper.pageIDs[0], stamp: stamp)
    let boardID = workspace.rootBoardID
    let element = SpatialElement(id: "large-visible-program", surface: .board(boardID), kind: .web,
      frame: .init(x: 20, y: 30, width: 4000, height: 3000), worldOrigin: .zero,
      source: "A large live program", html: "<canvas/>", stamp: stamp)
    let source = agentElementSnapshotSource(element)
    let crop = PageRect(x: 1000, y: 2000, width: 32, height: 24)
    let rasterSource = SceneRasterSource.agentRegion(source, crop)
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let pixels = UIGraphicsImageRenderer(size: .init(width: 32, height: 24), format: format).image {
      UIColor.red.setFill(); $0.fill(.init(x: 0, y: 0, width: 16, height: 24))
      UIColor.blue.setFill(); $0.fill(.init(x: 16, y: 0, width: 16, height: 24))
    }
    XCTAssertTrue(resources.store(pixels, for: rasterSource))
    let installed = try XCTUnwrap(resources.retainRaster(for: rasterSource))
    let hierarchy = BoardHierarchy(rootBoardID: boardID,
      boards: [.init(id: boardID, board: BoardDocument(freeItems: [
        .init(itemID: paper.id, center: .init(x: 100_000, y: 100_000), zIndex: 0, stamp: stamp)
      ], elements: [element], stamp: stamp))], stamp: stamp)
    let fragments: [NotebookAttentionSelection.Fragment] = [
      .init(target: .init(kind: .board, id: boardID), elementID: element.id,
        region: .init(x: 1040, y: 2038, width: 8, height: 8), worldOrigin: .zero, pageIndex: nil, label: "Shown crop"),
      .init(target: .init(kind: .board, id: boardID), elementID: element.id,
        region: .init(x: 990, y: 2038, width: 8, height: 8), worldOrigin: .zero, pageIndex: nil, label: "Outside retained pixels")
    ]
    let visuals = NotebookFrozenVisualSources.capture(fragments: fragments, hierarchy: hierarchy,
      pages: [:], documents: [:], states: [:], installedSources: [.init(plane: .board(boardID), elementID: element.id): installed],
      resources: resources)
    let selection = NotebookAttentionSelection(fragments: fragments, workspace: workspace, hierarchy: hierarchy,
      ink: .init(stamp: stamp), pages: [:], documents: [:], states: [:], visuals: visuals)
    let references = try selection.resolvedReferences()
    XCTAssertTrue(resources.store(bitmap(width: 32, height: 24, color: .green), for: rasterSource))
    let result = try await selection.renderPinnedImages(references: references, resources: resources)
    let image = try XCTUnwrap(result.images[references[0].id])
    XCTAssertEqual(image.pixelWidth, 8); XCTAssertEqual(image.pixelHeight, 8)
    XCTAssertEqual(image.pixelsPerPoint, 1, "Frozen evidence cannot invent source detail by enlarging the old pixels")
    let value = try pixel(image.png, x: 3, y: 3)
    XCTAssertLessThan(value[0], 10); XCTAssertLessThan(value[1], 10); XCTAssertGreaterThan(value[2], 240)
    XCTAssertEqual(result.unavailable[references[1].id], "snapshot_pending: historical_region_unavailable")
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testMissingHistoricalProgramFrameIsAnExplicitGapAndDoesNotExecuteIt() async throws {
    let frame = PageRect(x: 0, y: 0, width: 32, height: 32)
    let element = AgentElement(id: "uncached", kind: .web, frame: frame, source: "A live program", html: "<canvas/>")
    let page = PageDocument(size: .init(width: 64, height: 64), actor: UUID(), elements: [element])
    let resources = SceneRenderResources()
    let selection = selection(page: page, region: frame, elementID: element.id, resources: resources)
    let references = try selection.resolvedReferences()
    let result = try await selection.renderPinnedImages(references: references, resources: resources)
    XCTAssertTrue(result.images.isEmpty)
    XCTAssertEqual(result.unavailable[references[0].id], "snapshot_pending: historical_frame_unavailable")
    XCTAssertEqual(resources.activeWebSurfaceCount, 0); XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testAChangedRegionCannotReuseTheFrozenSelectionAndOversizeDoesNotAllocate() async throws {
    let page = PageDocument(size: .init(width: 2048, height: 2048), actor: UUID())
    let selection = selection(page: page, region: .init(x: 0, y: 0, width: 2048, height: 2048))
    let reference = try XCTUnwrap(selection.resolvedReferences().first)
    let resources = SceneRenderResources()
    let tooLarge = try await selection.renderPinnedImages(references: [reference], resources: resources)
    XCTAssertEqual(tooLarge.unavailable[reference.id], "resource_limit")
    XCTAssertEqual(resources.residentBytes, 0); XCTAssertEqual(resources.reservedBytes, 0)
    let redirected = CollaborationReference(id: reference.id, target: reference.target,
      region: .init(x: 100, y: 100, width: 64, height: 64), revision: reference.revision, label: reference.label)
    do {
      _ = try await selection.renderPinnedImages(references: [redirected], resources: resources)
      XCTFail("Keeping an ID is not permission to change the completed contact's physical region")
    } catch let error as CollaborationError { XCTAssertEqual(error.code, "source_conflict") }
  }

  @MainActor
  func testLongThinRegionCannotBypassTheImageDimensionLimit() async throws {
    let reference = CollaborationReference(target: .init(kind: .board, id: UUID()),
      region: .init(x: 0, y: 0, width: 2049, height: 4), worldOrigin: .zero,
      revision: String(repeating: "0", count: 64), label: "Thin board region")
    let resources = SceneRenderResources()
    do {
      _ = try await NotebookPinnedImageRenderer.render(reference: reference, page: nil, document: nil,
        state: nil, element: nil, visuals: nil, resources: resources)
      XCTFail("A low pixel count does not permit an unsupported image dimension")
    } catch SceneRenderError.resourceLimit { }
    XCTAssertEqual(resources.residentBytes, 0); XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testDraggedCornerDoesNotExpandATinyIntersectionIntoAWholeCoverGrant() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let itemID = try XCTUnwrap(model.workspace?.selectedItemID), boardID = try XCTUnwrap(model.presence?.boardID)
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    let privateElement = SpatialElement(id: "outside-small-intersection", surface: .cover(itemID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 100, height: 100), source: "Not inside the granted corner",
      stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(privateElement, in: boardID, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(scale: 0.25), viewport: .init(x: 512, y: 512))
    model.updatePresence(presence, settled: true)
    await model.finishPendingPersistence()
    var deadline = ContinuousClock.now + .seconds(5)
    while model.scenePreparationPending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let frame = WorkspaceSceneFrame(index: try XCTUnwrap(model.sceneIndex), presence: presence, portalCamera: model.scenePortalCamera)
    model.prepareComposition(presence: presence, frame: frame, pinned: [.item(itemID)], displayScale: 2)
    deadline = ContinuousClock.now + .seconds(5)
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try await mountNotebookScene(model)
    let shown = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "")
    defer { model.compositionTiles.removePublishedCoverage() }
    let item = try XCTUnwrap(shown.frame.workset(boardID: boardID).items.first { $0.id == itemID })
    let box = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
    for intersection in [2.0, 0.25] {
      let selection = try XCTUnwrap(NotebookAttentionProjection.capture(
        start: .init(x: box.x - 98, y: box.y - 98),
        end: .init(x: box.x + intersection, y: box.y + intersection),
        model: model, presence: presence, cohort: shown,
        installedInk: model.compositionTiles.surfaceRegistry.installedSources()))
      let reference = try XCTUnwrap(selection.resolvedReferences().first { $0.target.kind == .cover })
      XCTAssertNil(reference.elementID, "An area intersection is not a second tap on the corner's element")
      let region = try XCTUnwrap(reference.region)
      XCTAssertEqual(region.x, 0); XCTAssertEqual(region.y, 0)
      XCTAssertEqual(region.width, intersection / presence.camera.scale)
      XCTAssertEqual(region.height, intersection / presence.camera.scale)
      let source = try AgentPinnedSource.capture(requestID: UUID(), reference: reference, files: selection.sourceFiles())
      let grantedElements = try XCTUnwrap(source.payload["elements"]?.decode([JSONValue].self))
      XCTAssertEqual(grantedElements.count, 0,
        "The complete program beyond the tiny intersection must not enter the request")
    }
  }

  @MainActor
  func testContactUsesTheShownCohortWhenTheModelAlreadyContainsAnotherProjection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: -30_000, y: -30_000))
    await model.finishPendingPersistence()
    let boardID = try XCTUnwrap(model.presence?.boardID)
    // Moving the initially open paper also moves its reading camera. Admit
    // this test's board window before loading its sources: there is no live
    // workspace view yet to resume a cold request made by prepareComposition.
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(scale: 1), viewport: .init(x: 512, y: 512))
    model.updatePresence(presence, settled: true)
    let positioned = await model.finishPendingPersistence()
    XCTAssertTrue(positioned)
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    let old = SpatialElement(id: "z-visible-svg", surface: .board(boardID), kind: .web,
      frame: .init(x: 0, y: 0, width: 100, height: 60), worldOrigin: .zero,
      source: "Old visible SVG", html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 60'><rect width='100' height='60' fill='red'/></svg>", stamp: .init(counter: 0, actor: model.actorID))
    let fillers = (0..<7).map { offset in
      SpatialElement(id: "a-\(offset)", surface: .board(boardID), kind: .nativeText,
        frame: .init(x: -160, y: 0, width: 32, height: 32), worldOrigin: .zero, source: "\(offset)",
        stamp: .init(counter: 0, actor: model.actorID))
    }
    for filler in fillers {
      XCTAssertTrue(hierarchy.upsertElement(filler, in: boardID, expected: nil, actor: model.actorID))
    }
    XCTAssertTrue(hierarchy.upsertElement(old, in: boardID, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    await model.finishPendingPersistence()
    var deadline = ContinuousClock.now + .seconds(5)
    while model.scenePreparationPending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let index = try XCTUnwrap(model.sceneIndex)
    XCTAssertEqual(index.element(id: old.id, boardID: boardID), old)
    XCTAssertTrue(fillers.allSatisfy { index.element(id: $0.id, boardID: boardID) != nil })
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: model.scenePortalCamera)
    model.prepareComposition(presence: presence, frame: frame, pinned: Set(fillers.map { .element($0.id) }), displayScale: 2)
    deadline = ContinuousClock.now + .seconds(5)
    let address = SceneSourceAddress(plane: .board(boardID), elementID: old.id)
    while model.compositionTiles.published?.sourceReceipts[address]?.hasCurrentPixels != true, model.compositionTiles.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let shown = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "")
    defer { model.compositionTiles.removePublishedCoverage() }
    XCTAssertFalse(shown.plan.allowsLive(.element(old.id), in: .board(boardID)))
    XCTAssertEqual(shown.sourceReceipts[address]?.hasCurrentPixels, true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 512, height: 512)
    let host = UIHostingController(rootView: FrozenAttentionTileSurface(cohort: shown, presence: presence))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    deadline = ContinuousClock.now + .seconds(5)
    while !shown.isPaintInstalled, ContinuousClock.now < deadline {
      window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(shown.isPaintInstalled)
    // Keep this native presentation fixed while a newer model projection is
    // admitted. The contact must use the old pixels still mounted in this host.
    var moved = old
    XCTAssertTrue(moved.update(frame: .init(x: 500, y: 400, width: 100, height: 60), actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(moved, in: boardID, expected: old.stamp, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    deadline = ContinuousClock.now + .seconds(5)
    while model.scenePreparationPending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertNotEqual(model.sceneIndex?.generationID, shown.frame.index.generationID)
    let selected = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 276, y: 276),
      end: .init(x: 276, y: 276), model: model, presence: presence, cohort: shown, installedInk: [:]))
    let reference = try XCTUnwrap(selected.resolvedReferences().first)
    XCTAssertEqual(reference.elementID, old.id)
    XCTAssertEqual(reference.region, .init(x: 0, y: 0, width: 100, height: 60), "A tap pins the full frame in the completed contact, not at send time")
    XCTAssertEqual(reference.worldOrigin, .zero)
    let files = try selected.sourceFiles()
    let captured = try XCTUnwrap(files["board.json"]?.decode(BoardHierarchy.self).board(boardID)?.elements.first { $0.id == old.id })
    XCTAssertEqual(captured, old, "Unshown model geometry must not redirect a physical grant")
  }

  @MainActor
  private func selection(page: PageDocument, region: PageRect, elementID: String? = nil,
    resources: SceneRenderResources? = nil, capturesLivePrograms: Bool = false) -> NotebookAttentionSelection {
    let stamp = VersionStamp(counter: 0, actor: UUID())
    let item = WorkspaceItem.notebook(title: "Frozen page", pageIDs: [page.id])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: page.id, stamp: stamp)
    let board = BoardDocument(freeItems: [.init(itemID: item.id, center: .zero, zIndex: 0, stamp: stamp)], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID,
      boards: [.init(id: workspace.rootBoardID, board: board)], stamp: stamp)
    let fragments: [NotebookAttentionSelection.Fragment] = [.init(target: .init(kind: .page, id: page.id),
      elementID: elementID, region: region, worldOrigin: nil, pageIndex: nil, label: "Frozen")]
    let visuals = resources.map { NotebookFrozenVisualSources.capture(fragments: fragments, hierarchy: hierarchy,
      pages: [page.id: page], documents: [:], states: [:], capturesLivePrograms: capturesLivePrograms, resources: $0) }
    return .init(fragments: fragments, workspace: workspace, hierarchy: hierarchy,
      ink: .init(stamp: stamp), pages: [page.id: page], documents: [:], states: [:], visuals: visuals)
  }

  private func sample(_ x: Double, _ y: Double, width: Double) -> SpatialInkSample {
    .init(point: .init(x: x, y: y), timeOffset: 0, width: width, opacity: 1, force: 1, azimuth: 0, altitude: 1)
  }
  @MainActor
  private func bitmap(width: Double, height: Double, color: UIColor) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 2
    return UIGraphicsImageRenderer(size: .init(width: width, height: height), format: format).image {
      color.setFill(); $0.fill(.init(x: 0, y: 0, width: width, height: height))
    }
  }
  private func pixel(_ png: Data, x: Int, y: Int) throws -> [UInt8] {
    let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
    return try pixels(png)[y * image.width + x]
  }
  private func pixels(_ png: Data) throws -> [[UInt8]] {
    let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // Decoded CGImage rows already have their stored top-to-bottom order.
    // Flipping here would inspect height - 1 - y instead of the granted pixel.
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    return (0..<(image.width * image.height)).map { index in Array(UnsafeBufferPointer(start: bytes + index * 4, count: 4)) }
  }
}

private struct FrozenAttentionTileSurface: View {
  let cohort: SceneCompositionCohort
  let presence: SessionPresence

  var body: some View {
    ZStack { plane(.elements); plane(.covers) }.ignoresSafeArea()
  }

  private func plane(_ layer: ScenePaintPosition.Layer) -> some View {
    SceneCameraPlane(presence: presence, revision: cohort.paintID,
      installation: cohort.installation(for: layer)) { anchor in
      ZStack {
        ForEach(SceneCompositionTileBandView.bands(in: cohort, plane: .board(presence.boardID), layer: layer, presence: anchor)) { band in
          band.zIndex(Double(band.rank))
        }

      }
    }
  }
}
