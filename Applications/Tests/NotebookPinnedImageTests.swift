import NotebookCore
import UIKit
import XCTest
@testable import Notebook

final class NotebookPinnedImageTests: XCTestCase {
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
    let shown = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "")
    defer { model.compositionTiles.removePublishedCoverage() }
    let item = try XCTUnwrap(shown.frame.workset(boardID: boardID).items.first { $0.id == itemID })
    let box = item.geometry.screenFrame(center: item.center, camera: presence.camera, viewport: presence.viewport)
    for intersection in [2.0, 0.25] {
      let selection = try XCTUnwrap(NotebookAttentionProjection.capture(
        start: .init(x: box.x - 98, y: box.y - 98),
        end: .init(x: box.x + intersection, y: box.y + intersection),
        model: model, presence: presence, cohort: shown))
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
    var hierarchy = try model.store.loadBoard(items: model.store.loadIndex().items)
    let old = SpatialElement(id: "visible-text", surface: .board(boardID), kind: .nativeText,
      frame: .init(x: 0, y: 0, width: 100, height: 60), worldOrigin: .zero,
      source: "Old visible", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(hierarchy.upsertElement(old, in: boardID, expected: nil, actor: model.actorID))
    try model.store.saveBoard(hierarchy, items: model.store.loadIndex().items)
    await model.reloadExternalChanges()?.value
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(scale: 1), viewport: .init(x: 512, y: 512))
    model.updatePresence(presence, settled: true)
    await model.finishPendingPersistence()
    var deadline = ContinuousClock.now + .seconds(5)
    while model.scenePreparationPending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let frame = WorkspaceSceneFrame(index: try XCTUnwrap(model.sceneIndex), presence: presence, portalCamera: model.scenePortalCamera)
    model.prepareComposition(presence: presence, frame: frame, pinned: [.element(old.id)], displayScale: 2)
    deadline = ContinuousClock.now + .seconds(5)
    while model.compositionTiles.published == nil, model.compositionTiles.failure == nil,
      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let shown = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "")
    defer { model.compositionTiles.removePublishedCoverage() }
    XCTAssertTrue(model.transformSpatialElement(elementID: old.id, by: .init(x: 500, y: 400)))
    await model.finishPendingPersistence()
    deadline = ContinuousClock.now + .seconds(5)
    while model.scenePreparationPending, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertNotEqual(model.sceneIndex?.generationID, shown.frame.index.generationID)
    let selected = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 276, y: 276),
      end: .init(x: 276, y: 276), model: model, presence: presence, cohort: shown))
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
    resources: SceneRenderResources? = nil) -> NotebookAttentionSelection {
    let stamp = VersionStamp(counter: 0, actor: UUID())
    let item = WorkspaceItem.notebook(title: "Frozen page", pageIDs: [page.id])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: page.id, stamp: stamp)
    let board = BoardDocument(freeItems: [.init(itemID: item.id, center: .zero, zIndex: 0, stamp: stamp)], stamp: stamp)
    let hierarchy = BoardHierarchy(rootBoardID: workspace.rootBoardID,
      boards: [.init(id: workspace.rootBoardID, board: board)], stamp: stamp)
    let fragments: [NotebookAttentionSelection.Fragment] = [.init(target: .init(kind: .page, id: page.id),
      elementID: elementID, region: region, worldOrigin: nil, pageIndex: nil, label: "Frozen")]
    let visuals = resources.map { NotebookFrozenVisualSources.capture(fragments: fragments, hierarchy: hierarchy,
      pages: [page.id: page], documents: [:], states: [:], resources: $0) }
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
