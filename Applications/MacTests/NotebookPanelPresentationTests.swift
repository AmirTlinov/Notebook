import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPanelPresentationTests: XCTestCase {
  override func setUp() async throws { try await InkRasterRenderer.shared.prepareInk() }

  @MainActor
  func testRepeatingGridKeepsNativePhaseAndOpaqueBackgroundAcrossCameraTilesAndZoomSteps() async throws {
    let threshold = BoardAppearance.minimumDotSpacing / PhysicalPaper.gridSpacing
    let cases: [(SpatialCamera, Double)] = [
      (.init(center: .init(x: -143.75, y: -318.25), scale: 0.09), 2),
      (.init(center: .init(tileX: -2, tileY: 3, localX: WorldPoint.tileSize - 0.25, localY: 0.25), scale: 0.09), 1.25),
      (.init(center: .init(tileX: -1, tileY: 2, localX: 0.25, localY: WorldPoint.tileSize - 0.25), scale: threshold * (1 - 0.000001)), 2),
      (.init(center: .init(tileX: -1, tileY: 3, localX: 0.25, localY: 0.25), scale: threshold * (1 + 0.000001)), 2)
    ]
    let size = CGSize(width: 240, height: 180)
    var previousStep: Double?
    for (index, entry) in cases.enumerated() {
      let (camera, pixelScale) = entry
      let layer = try await SceneCompositionRenderer.panelGridLayer(camera: camera, pixelScale: pixelScale)
      let period = try XCTUnwrap(layer.repeatSize)
      let expectedStep = SpatialBoardGrid.worldStep(cameraScale: camera.scale)
      XCTAssertEqual(Double(period.width), expectedStep)
      XCTAssertEqual(Double(period.height), expectedStep)
      XCTAssertEqual(layer.pixelWidth, Int(ceil(expectedStep * camera.scale * pixelScale)))
      XCTAssertEqual(layer.pixelHeight, layer.pixelWidth)
      XCTAssertEqual(layer.frame.width * camera.scale * pixelScale, Double(layer.pixelWidth), accuracy: 0.000001)
      XCTAssertGreaterThanOrEqual(layer.frame.width, expectedStep)
      XCTAssertLessThan(layer.frame.width - expectedStep, 1 / (camera.scale * pixelScale))
      let anchor = layer.worldOrigin.offsetBy(x: expectedStep / 2, y: expectedStep / 2)
      let nativeAnchor = WorldPoint(tileX: camera.center.tileX, tileY: camera.center.tileY, localX: 0, localY: 0)
      XCTAssertEqual(nativeAnchor.delta(to: anchor).x, 0, accuracy: 0.000001)
      XCTAssertEqual(nativeAnchor.delta(to: anchor).y, 0, accuracy: 0.000001)
      let encoded = try layer.encoded
      XCTAssertEqual(encoded["repeatSize"]?["width"], .number(expectedStep))
      XCTAssertNil(encoded["repeating"], "One explicit period owns repeat placement")
      let cell = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(layer.png)))
      let referenceCanvas = try await SceneRasterCompositor.create(size: size, scale: pixelScale, resources: .shared)
      try await referenceCanvas.drawBoardGrid(camera: camera, size: size, in: .init(origin: .zero, size: size))
      let referencePNG = try await referenceCanvas.finishPNG()
      let reference = try XCTUnwrap(NSBitmapImageRep(data: referencePNG))
      func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
      }
      func darkest(_ bitmap: NSBitmapImageRep, x: Double, y: Double) throws -> NSColor {
        var result = try color(bitmap, x: Int(x), y: Int(y))
        for row in max(0, Int(y) - 2)...min(bitmap.pixelsHigh - 1, Int(y) + 2) {
          for column in max(0, Int(x) - 2)...min(bitmap.pixelsWide - 1, Int(x) + 2) {
            let candidate = try color(bitmap, x: column, y: row)
            if candidate.redComponent < result.redComponent { result = candidate }
          }
        }
        return result
      }
      // The consumer clips the padded image to this period. No seam may expose
      // transparency or replace the accepted native desk with browser paper.
      let background = try color(cell, x: 0, y: 0)
      for position in 0..<cell.pixelsWide {
        for edge in [(position, 0), (position, cell.pixelsHigh - 1), (0, position), (cell.pixelsWide - 1, position)] {
          let pixel = try color(cell, x: edge.0, y: edge.1)
          XCTAssertGreaterThan(pixel.alphaComponent, 0.99)
          XCTAssertEqual(pixel.redComponent, background.redComponent, accuracy: 1.0 / 255)
          XCTAssertEqual(pixel.greenComponent, background.greenComponent, accuracy: 1.0 / 255)
          XCTAssertEqual(pixel.blueComponent, background.blueComponent, accuracy: 1.0 / 255)
        }
      }
      let delta = camera.center.delta(to: nativeAnchor)
      let screenPeriod = expectedStep * camera.scale
      func visibleDot(_ projected: Double) -> Double {
        projected + ceil((8 - projected) / screenPeriod) * screenPeriod
      }
      let dotX = visibleDot(Double(size.width) / 2 + delta.x * camera.scale)
      let dotY = visibleDot(Double(size.height) / 2 + delta.y * camera.scale)
      let nativeBackground = try color(reference,
        x: Int((dotX + screenPeriod / 2) * pixelScale), y: Int(dotY * pixelScale))
      XCTAssertEqual(background.redComponent, nativeBackground.redComponent, accuracy: 1.0 / 255)
      XCTAssertEqual(background.greenComponent, nativeBackground.greenComponent, accuracy: 1.0 / 255)
      XCTAssertEqual(background.blueComponent, nativeBackground.blueComponent, accuracy: 1.0 / 255)
      let cellDot = try darkest(cell, x: screenPeriod * pixelScale / 2, y: screenPeriod * pixelScale / 2)
      let nativeDot = try darkest(reference, x: dotX * pixelScale, y: dotY * pixelScale)
      XCTAssertLessThan(cellDot.redComponent, background.redComponent - 0.01)
      XCTAssertLessThan(nativeDot.redComponent, nativeBackground.redComponent - 0.01,
        "The cell anchor must land on the actual native camera's dots")
      XCTAssertEqual(cellDot.redComponent, nativeDot.redComponent, accuracy: 0.06)
      if index == 3, let previousStep { XCTAssertEqual(expectedStep * 2, previousStep) }
      previousStep = expectedStep
    }
  }

  @MainActor
  func testCanonicalBoardMaterialsSplitSubjectsBeforeFirstDragAndJoinCachedRequests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-materials-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let item = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    try await fixture.move(item.id, boardID: target.id, to: .init(x: -550, y: 0))
    try await fixture.apply([
      .init(kind: .insertElement, target: target, id: "plain-caption", values: ["kind": .string("nativeText"),
        "source": .string("Existing native material"), "worldOrigin": try .encode(WorldPoint.zero),
        "frame": try .encode(PageRect(x: 0, y: 80, width: 280, height: 80))]),
      .init(kind: .appendInkStroke, target: target, id: UUID().uuidString, values: ["width": .number(8),
        "worldOrigin": try .encode(WorldPoint.zero), "points": .array([
          .object(["x": .number(0), "y": .number(300)]),
          .object(["x": .number(500), "y": .number(350)])])])])
    let physicalPresence = fixture.model.presence
    let projection = NotebookPanelAppearanceProjection(viewport: .init(x: 1000, y: 700), pixelScale: 1,
      camera: .init(center: .zero, scale: 0.5))
    var command = NotebookCommand(command: .panelPresentation)
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target, appearance: projection)
    let accepted = command
    let durableBefore = Set(try fixture.store.targetRenderRequests().map(\.id))
    async let first = fixture.send(accepted)
    async let simultaneous = fixture.send(accepted)
    let (reply, joined) = try await (first, simultaneous)
    let appearance = try XCTUnwrap(reply["appearance"])
    XCTAssertEqual(appearance["status"], .string("ready"))
    XCTAssertEqual(joined["appearance"]?["requestID"], appearance["requestID"])
    XCTAssertEqual(joined["appearance"]?["layers"], appearance["layers"], "Concurrent readers borrow the same immutable pixels")
    let layers = try XCTUnwrap(appearance["layers"]?.arrayValues)
    XCTAssertTrue(layers.contains { $0["id"] == .string("board-grid") })
    let cover = try XCTUnwrap(layers.first { $0["itemID"]?.stringValue?.lowercased() == item.id.uuidString.lowercased() })
    let subject = try XCTUnwrap(layers.first { $0["elementID"] == .string("plain-caption") })
    let authored = try XCTUnwrap(fixture.store.readSpatialElement(boardID: target.id, elementID: "plain-caption"))
    let placement = try XCTUnwrap(fixture.store.readElementPlacement(target: target, elementID: authored.id))
    let body = NotebookElementPresentation(authored, placement: placement).frame
    let layerOrigin = try XCTUnwrap(subject["worldOrigin"]).decode(WorldPoint.self)
    let delta = layerOrigin.delta(to: placement.origin)
    let nativeFrame = PageRect(x: delta.x + body.x, y: delta.y + body.y, width: body.width, height: body.height)
    XCTAssertEqual(try XCTUnwrap(subject["frame"]).decode(PageRect.self), nativeFrame)
    XCTAssertEqual(authored.frame.width, 280, "Native fitting preserves the authored layout constraint")
    XCTAssertEqual(reply["elements"]?.arrayValues.first { $0["source"]?["id"] == .string("plain-caption") }?["editable"], .bool(true))
    let card = try XCTUnwrap(reply["cards"]?.arrayValues.first { $0["item"]?["id"]?.stringValue?.lowercased() == item.id.uuidString.lowercased() })
    XCTAssertEqual(card["geometry"]?["width"], .number(834))
    XCTAssertEqual(card["geometry"]?["height"], .number(1194))
    XCTAssertEqual(card["editable"], .bool(true))
    XCTAssertNotNil(card["source"]?["placements"]?.arrayValues.first,
      "The movable native cover carries its exact placement source")
    let inkPixels = try layers.filter { $0["order"] == .number(1000) }.map { try alpha($0, at: .init(x: 250, y: 325)) }
    XCTAssertGreaterThan(inkPixels.max() ?? 0, 0.1, "The ordered native stroke reaches world-addressed pixels")
    XCTAssertGreaterThan(try alpha(cover, at: .init(x: -550, y: 0)), 0.9)
    let staticCoverPixels = try layers.filter { layer in
      if case .number(let rank) = layer["order"] { return rank >= 2000 && layer["itemID"] == nil }
      return false
    }
      .map { try alpha($0, at: .init(x: -550, y: 0)) }
    XCTAssertEqual(staticCoverPixels.max() ?? 0, 0, "The independently movable cover leaves no baked duplicate")
    let held = try layers.map { try XCTUnwrap($0["assetID"]?.stringValue.flatMap(UUID.init(uuidString:))) }
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target, appearance: projection, knownAssets: held)
    let cached = try await fixture.send(command)
    let cachedLayers = try XCTUnwrap(cached["appearance"]?["layers"]?.arrayValues)
    XCTAssertEqual(cachedLayers.map { $0["assetID"] }, layers.map { $0["assetID"] })
    XCTAssertTrue(cachedLayers.allSatisfy { $0["pngBase64"] == nil }, "Held pixels need no repeated PNG encoding")
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target, appearance: projection,
      knownCursor: cached["cursor"]?.stringValue, knownRequestID: appearance["requestID"]?.stringValue.flatMap(UUID.init(uuidString:)))
    let unchanged = try await fixture.send(command)
    XCTAssertEqual(unchanged["unchanged"], .bool(true))
    XCTAssertNil(unchanged["appearance"], "Idle polling performs no image or graph serialization")
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: projection.viewport, pixelScale: projection.pixelScale,
        camera: .init(center: .init(x: 10, y: 0), scale: 0.5)), knownAssets: held)
    let moved = try await fixture.send(command)
    let movedLayers = try XCTUnwrap(moved["appearance"]?["layers"]?.arrayValues)
    for original in [subject, cover] {
      let reused = try XCTUnwrap(movedLayers.first { $0["id"] == original["id"] })
      XCTAssertEqual(reused["assetID"], original["assetID"])
      XCTAssertNil(reused["pngBase64"], "Camera translation reuses the native body")
    }
    XCTAssertEqual(Set(try fixture.store.targetRenderRequests().map(\.id)), durableBefore,
      "Panel camera reads never enter the durable render queue")
    command.panelPresentation = .init(workspaceID: UUID(), target: target, appearance: projection)
    do { _ = try await fixture.send(command); XCTFail("A panel cannot cross its pinned workspace") }
    catch let error as CollaborationError { XCTAssertEqual(error.code, "basis_workspace_mismatch") }
    XCTAssertEqual(fixture.model.presence, physicalPresence, "An addressed projection never moves the native camera")

    let siblingID = UUID()
    try await fixture.apply([.init(kind: .createNotebook, target: target, id: siblingID.uuidString,
      values: ["center": try .encode(WorldPoint(x: -550, y: 0)), "pageID": try .encode(UUID())])])
    let actor = fixture.model.actorID
    try await fixture.model.performStoreCommand { store in
      let sources = try [item.id, siblingID].map { id in
        try XCTUnwrap(store.readBoardItem(id)?.board.placements.first { $0.id == id })
      }
      _ = try store.applyNativePlacementEdits([.init(kind: .stackItems, target: target,
        values: ["itemIDs": try .encode([item.id, siblingID])])], summary: "Prepare native stack",
        sources: sources, actor: actor)
    }
    let stacked = try await fixture.send(accepted)
    let stackedCard = try XCTUnwrap(stacked["cards"]?.arrayValues.first {
      $0["item"]?["id"]?.stringValue?.lowercased() == item.id.uuidString.lowercased()
    })
    let visibleCenter = try XCTUnwrap(stackedCard["center"]).decode(WorldPoint.self)
    let stack = try XCTUnwrap(fixture.store.readBoardItem(item.id)?.board.stack(containing: item.id))
    XCTAssertEqual(visibleCenter, WorkspaceItemStackPresentation.focusedCenter(of: item.id, in: stack))
    XCTAssertNotEqual(visibleCenter, stack.center, "The drag begins at the visible fan member")
    let destination = visibleCenter.offsetBy(x: 40, y: 20)
    var drop = NotebookCommand(command: .panelEdit)
    drop.panelEdit = .init(workspaceID: header.workspaceID, actionID: UUID(), target: target,
      summary: "Pull a visible card from its stack", operations: [.init(kind: .moveItem, target: target,
        id: item.id.uuidString, values: ["center": try .encode(destination)])],
      sources: [try XCTUnwrap(stackedCard["source"]).decode(NotebookPanelEditSource.self)])
    _ = try await fixture.send(drop)
    XCTAssertEqual(try fixture.store.readBoardItem(item.id)?.board.freeItems.first { $0.itemID == item.id }?.center,
      destination, "The native saved drop matches the visible drag without subtracting the fan offset")
  }

  @MainActor
  func testNotebookCardFirstPageOpensNativePixelsAndNavigationWithoutMovingPresence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-notebook-entry-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let item = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    let pageID = try XCTUnwrap(item.firstPageID)
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let page = CollaborationTarget(kind: .page, id: pageID)
    try await fixture.move(item.id, boardID: board.id, to: .zero)
    try await fixture.apply([
      .init(kind: .appendInkStroke, target: page, id: UUID().uuidString,
        values: ["width": .number(12), "points": .array([
          .object(["x": .number(100), "y": .number(140)]),
          .object(["x": .number(300), "y": .number(140)])])]),
      .init(kind: .appendInkStroke, target: page, id: UUID().uuidString,
        values: ["width": .number(1.5), "points": .array([
          .object(["x": .number(100.125), "y": .number(500.375)]),
          .object(["x": .number(300.125), "y": .number(700.375)])])])])
    let nativePresence = fixture.model.presence
    let observedPresence = try await fixture.read(.init(kind: .presence))
    let viewport = SpatialPoint(x: 600, y: 800)
    var command = NotebookCommand(command: .panelPresentation)
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: board,
      appearance: .init(viewport: viewport, pixelScale: 1, camera: .init(center: .zero, scale: 0.5)))
    let overview = try await fixture.send(command)
    let card = try XCTUnwrap(overview["cards"]?.arrayValues.first {
      $0["item"]?["id"]?.stringValue?.lowercased() == item.id.uuidString.lowercased()
    })
    let openedPageID = try XCTUnwrap(card["item"]?["firstPageID"]?.stringValue.flatMap(UUID.init(uuidString:)))
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: .init(kind: .page, id: openedPageID),
      appearance: .init(viewport: viewport, pixelScale: 1))
    let opened = try await fixture.send(command)
    XCTAssertEqual(opened["target"], try .encode(page))
    XCTAssertEqual(opened["appearance"]?["status"], .string("ready"))
    let camera = try XCTUnwrap(opened["appearance"]?["camera"]).decode(SpatialCamera.self)
    XCTAssertEqual(camera.center, WorldPoint(x: 417, y: 597))
    XCTAssertEqual(camera.scale, min(600.0 / 834, 800.0 / 1194), accuracy: 0.000001,
      "Opening the first page uses its native entry projection instead of the board camera")
    XCTAssertEqual(opened["navigation"]?["itemID"], try .encode(item.id))
    XCTAssertEqual(opened["navigation"]?["parentBoard"], try .encode(board))
    XCTAssertEqual(opened["navigation"]?["position"]?["index"], .number(0))
    let layers = try XCTUnwrap(opened["appearance"]?["layers"]?.arrayValues)
    let paper = try layers.filter { $0["order"] == .number(-1) }.map { try alpha($0, at: .init(x: 40, y: 40)) }
    let ink = try layers.filter { $0["order"] == .number(1000) }.map { try alpha($0, at: .init(x: 160, y: 140)) }
    XCTAssertGreaterThan(paper.max() ?? 0, 0.9, "The first page includes actual native paper pixels")
    XCTAssertGreaterThan(ink.max() ?? 0, 0.5, "The addressed first page includes its ordered native handwriting")
    let detailedProjections: [NotebookPanelAppearanceProjection] = [
      .init(viewport: .init(x: 2048, y: 1400), pixelScale: 2,
        camera: .init(center: .init(x: 417, y: 597), scale: 1)),
      .init(viewport: .init(x: 2048, y: 1400), pixelScale: 2,
        camera: .init(center: .init(x: 417, y: 597), scale: 2)),
      .init(viewport: .init(x: 1394, y: 990), pixelScale: 1,
        camera: .init(center: .init(x: 398.7188887550497, y: 572.625185006733), scale: 3.500604197139754))
    ]
    for projection in detailedProjections {
      let scale = try XCTUnwrap(projection.camera).scale
      command.panelPresentation = .init(workspaceID: header.workspaceID, target: page,
        appearance: projection)
      let detailed = try await fixture.send(command)
      let detailedLayers = try XCTUnwrap(detailed["appearance"]?["layers"]?.arrayValues)
      let handwriting = detailedLayers.filter { $0["order"] == .number(1000) }
      XCTAssertFalse(handwriting.isEmpty)
      var decodedPixels = 0
      for layer in detailedLayers {
        let image = try bitmap(layer), frame = try XCTUnwrap(layer["frame"]).decode(PageRect.self)
        decodedPixels += image.pixelsWide * image.pixelsHigh
        if layer["order"] == .number(1000) || layer["order"] == .number(-1) {
          let actualDensity = min(Double(image.pixelsWide) / frame.width, Double(image.pixelsHigh) / frame.height)
          XCTAssertGreaterThanOrEqual(actualDensity, scale * projection.pixelScale * 0.995,
            "Accepted native paper and handwriting must both retain the requested display resolution")
        }
      }
      XCTAssertLessThanOrEqual(decodedPixels, NotebookPanelRenderProjection.maximumDecodedPixels)
      if scale == 2 {
        let source = try await fixture.read(.init(kind: .page, id: pageID)).decode(PageDocument.self)
        let drawing = try source.inkDrawing()
        let materials = try handwriting.map { (frame: try XCTUnwrap($0["frame"]).decode(PageRect.self), image: try bitmap($0)) }
        let material = try XCTUnwrap(materials.first { entry in
          entry.image.pixelsWide >= 64 && entry.image.pixelsHigh >= 64
            && 200.125 >= entry.frame.x && 600.375 >= entry.frame.y
            && 200.125 < entry.frame.x + entry.frame.width && 600.375 < entry.frame.y + entry.frame.height
        }, "The diagonal crosses an admitted native ink region")
        let actual = material.image, frame = material.frame
        // Paper and ink share one output budget, so the admitted region may be
        // clipped rather than a square 1024px tile. Match its exact two-axis
        // pixel grid instead of assuming a particular tile size or density.
        let densityX = Double(actual.pixelsWide) / frame.width
        let densityY = Double(actual.pixelsHigh) / frame.height
        let pixelSize = CGSize(width: actual.pixelsWide, height: actual.pixelsHigh)
        let sharp = try await Task.detached(priority: .utility) {
          guard let image = InkRasterRenderer.shared.render(mesh: SpatialInkMesh.page(drawing),
            size: pixelSize, scale: 1,
            affine: .init(.init(Float(densityX), Float(densityY), -Float(frame.x * densityX), -Float(frame.y * densityY))))
          else { throw SceneRenderError.resourceLimit }
          return image
        }.value
        let reference = NSBitmapImageRep(cgImage: sharp)
        XCTAssertEqual(reference.pixelsWide, actual.pixelsWide)
        XCTAssertEqual(reference.pixelsHigh, actual.pixelsHigh)
        let startX = max(0, min(actual.pixelsWide - 64, Int((200.125 - frame.x) * densityX) - 32))
        let startY = max(0, min(actual.pixelsHigh - 64, Int((600.375 - frame.y) * densityY) - 32))
        var edgeError: CGFloat = 0, edgeSamples = 0
        for y in startY..<(startY + 64) {
          for x in startX..<(startX + 64) {
            let expected = try XCTUnwrap(reference.colorAt(x: x, y: y)).alphaComponent
            guard expected > 0.05 && expected < 0.95 else { continue }
            edgeError += abs(try XCTUnwrap(actual.colorAt(x: x, y: y)).alphaComponent - expected)
            edgeSamples += 1
          }
        }
        XCTAssertGreaterThan(edgeSamples, 20)
        XCTAssertLessThan(edgeError / CGFloat(max(1, edgeSamples)), 0.035,
          "Thin diagonal edges retain native4× detail instead of interpolating a fixed2× page image")
      }
    }
    XCTAssertEqual(fixture.model.presence, nativePresence)
    let afterPresence = try await fixture.read(.init(kind: .presence))
    XCTAssertEqual(afterPresence, observedPresence,
      "Plugin navigation leaves the native selected surface and camera untouched")
  }

  @MainActor
  func testRegionalMaterialPreparationPreservesOrderedCutsAndBaselineAcrossRegionsAndReleasesGeometry() async throws {
    func action(_ sequence: UInt64, _ tool: SpatialInkTool, _ color: SpatialInkColor,
      _ points: [CGPoint], width: Double = 12, targets: [InkElementTarget]? = nil) -> PageInkAction {
      .init(tool: tool, color: color, samples: points.enumerated().map { index, point in
        .init(point: .init(x: point.x, y: point.y), timeOffset: Double(index) / 10,
          width: width, opacity: 1, force: 1, azimuth: 0, altitude: 1)
      }, sequence: sequence, elementTargets: targets)
    }
    let red = SpatialInkColor(red: 1, green: 0, blue: 0)
    let blue = SpatialInkColor(red: 0, green: 0, blue: 1)
    let green = SpatialInkColor(red: 0, green: 1, blue: 0)
    let early = action(1, .pen, red, [.init(x: 10, y: 40), .init(x: 110, y: 40)])
    let moved = action(2, .pen, blue, [.init(x: 48, y: 10), .init(x: 48, y: 86)])
    let later = action(3, .pen, green, [.init(x: 10, y: 65), .init(x: 110, y: 65)])
    let capturedCut = action(4, .eraser, .black, [.init(x: 40, y: 25), .init(x: 56, y: 25)], width: 10)
    let frame = PageRect(x: 8, y: 0, width: 96, height: 96)
    let sourceFrame = PageRect(x: 0, y: 0, width: 96, height: 96)
    let target = InkElementTarget(elementID: "regional-ordered-body", frame: frame)
    let targetCut = action(5, .eraser, .black, [.init(x: 50, y: 50), .init(x: 62, y: 50)],
      width: 8, targets: [target])
    let baselineCut = action(6, .eraser, .black, [.init(x: 105, y: 105)], width: 14)
    let baselineCanvas = try XCTUnwrap(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
      bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    baselineCanvas.setFillColor(NSColor.red.cgColor)
    baselineCanvas.fill(.init(x: 96, y: 96, width: 24, height: 24))
    let baselineImage = try XCTUnwrap(baselineCanvas.makeImage())
    let baseline = try await NotebookPNGEncodingFixture.encode(baselineImage)
    let drawing = PageInkDrawing(baselinePNG: baseline, baselineActionCount: 1,
      actions: [early, moved, later, capturedCut, targetCut, baselineCut])
    let graphic = NotebookGraphic(shape: .freehand, sourceInkIDs: [moved.id], freehand: .init(layers: [
      .init(tool: .pen, color: blue, measured: .init(sourceID: moved.id, measurements: moved.samples, frame: sourceFrame)),
      .init(tool: .eraser, color: .black,
        measured: .init(sourceID: capturedCut.id, measurements: capturedCut.samples, frame: sourceFrame))]))
    let element = AgentElement(id: target.elementID, kind: .graphic, frame: frame, source: "", html: "", graphic: graphic)
    let page = PageDocument(size: .init(width: 128, height: 128), actor: UUID(),
      drawingData: try drawing.dataRepresentation(), elements: [element])
    let resources = SceneRenderResources()
    let reference = try await PageCompositionRenderer.renderInk(page, scale: 2, resources: resources)
    let expected = try XCTUnwrap(NSBitmapImageRep(data: reference.png))
    let regions = [PageRect(x: 0, y: 0, width: 64, height: 128), PageRect(x: 64, y: 0, width: 64, height: 128)]
    func renderRegions() async throws {
      let preparation = try await PageCompositionRenderer.prepareMaterial(page, graph: page.graphicGraph(),
        region: .init(x: 0, y: 0, width: 128, height: 128), scale: 2, resources: resources,
        permitsPreparation: { true })
      let retainedGeometryBytes = resources.reservedBytes
      XCTAssertGreaterThan(retainedGeometryBytes, 0)
      for region in regions {
        let key = try SceneMaterialKey(workspaceID: UUID(), target: .init(kind: .page, id: page.id),
          revision: "regional-cut", role: "page-ink", frame: region, density: 2)
        let body = try await PageCompositionRenderer.renderMaterial(page, ids: nil, region: region,
          scale: 2, key: key, preparation: preparation, resources: resources, permitsPreparation: { true }) { _ in
            throw SceneRenderError.snapshotPending("unexpected_webkit")
          }
        let image = try XCTUnwrap(body.sampledImage(for: .init(width: Double.greatestFiniteMagnitude,
          height: Double.greatestFiniteMagnitude)))
        let png = try await NotebookPNGEncodingFixture.encode(image)
        let actual = try XCTUnwrap(NSBitmapImageRep(data: png))
        body.release()
        for (x, y) in [(56, 40), (56, 65), (48, 40), (56, 25), (56, 50), (64, 65), (110, 110), (105, 105)] {
          guard Double(x) >= region.x, Double(x) < region.x + region.width else { continue }
          let received = try XCTUnwrap(actual.colorAt(x: (x - Int(region.x)) * 2, y: y * 2)?.usingColorSpace(.deviceRGB))
          let native = try XCTUnwrap(expected.colorAt(x: x * 2, y: y * 2)?.usingColorSpace(.deviceRGB))
          for channel in [\NSColor.redComponent, \NSColor.greenComponent, \NSColor.blueComponent, \NSColor.alphaComponent] {
            XCTAssertEqual(received[keyPath: channel], native[keyPath: channel], accuracy: 2.0 / 255,
              "Regional reuse preserves moved-body rank, captured/target cuts and erased baseline pixels")
          }
        }
        // OrderedBody uploads only the body/cut buffers visible in this region
        // and retains them for the cut. Those accounted derived buffers are
        // reusable geometry, whereas all regional pixel backings must retire.
        XCTAssertEqual(resources.rasterAdmission.reservedCount, 0,
          "A finished region releases every temporary raster backing")
        let reusableGeometryBytes = resources.reservedBytes
        XCTAssertGreaterThanOrEqual(reusableGeometryBytes, retainedGeometryBytes)
        let repeated = try await PageCompositionRenderer.renderMaterial(page, ids: nil, region: region,
          scale: 2, key: key, preparation: preparation, resources: resources, permitsPreparation: { true }) { _ in
            throw SceneRenderError.snapshotPending("unexpected_webkit")
          }
        repeated.release()
        XCTAssertEqual(resources.rasterAdmission.reservedCount, 0)
        XCTAssertEqual(resources.reservedBytes, reusableGeometryBytes,
          "Repeated regional pixels reuse the cut's admitted body and cut buffers without growing their geometry")
      }
    }
    try await renderRegions()
    XCTAssertEqual(resources.reservedBytes, 0, "The cut releases its prepared mesh and body clips after its last region")
  }

  @MainActor
  func testForegroundPanelSurvivesPeerInputDuringQueuedCaptureAndKeepsLocalFence() async throws {
    let resources = SceneRenderResources.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-peer-input-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.waitUntil(seconds: 5) {
      resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0
    }
    var blockers: [WebSurfaceLease] = []
    for _ in 0..<resources.maximumBackgroundWebSurfaces {
      blockers.append(try await resources.acquireWebSurface(priority: .background))
    }
    defer { blockers.forEach { $0.release() } }
    try await fixture.start(showingPage: true)
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let page = try XCTUnwrap(fixture.model.activePage)
    let target = CollaborationTarget(kind: .page, id: page.id)
    try await fixture.apply([.init(kind: .insertElement, target: target, id: "queued-foreground-web-\(UUID())",
      values: ["kind": .string("web"), "source": .string("Foreground source"),
        "html": .string("<div style='width:180px;height:120px;background:blue'>Native source</div>"),
        "frame": try .encode(PageRect(x: 20, y: 30, width: 180, height: 120))])])
    var command = NotebookCommand(command: .panelPresentation)
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: .init(x: 600, y: 800), pixelScale: 1))
    let accepted = command
    let durableBefore = Set(try fixture.store.targetRenderRequests().map(\.id))
    let firstCompleted = expectation(description: "Queued foreground capture completes while the peer contact is held")
    let reader = Task { @MainActor in
      defer { firstCompleted.fulfill() }
      return try await fixture.send(accepted)
    }
    defer { reader.cancel() }
    try await fixture.waitUntil(seconds: 5) { resources.pendingWebRequestCount > 0 }

    let peer = UUID(), generation = UUID(), session = UUID()
    fixture.model.peerConnected(.init(deviceID: peer, workspaceID: header.workspaceID,
      displayName: "Held iPad contact"), generation: generation)
    defer { fixture.model.peerDisconnected(peerID: peer, generation: generation) }
    fixture.model.receivePeerTransient(.inputActivity(.init(deviceID: peer, sessionID: session, sequence: 1,
      targets: [.init(kind: .board, id: header.rootBoardID)])), peerID: peer, generation: generation)
    XCTAssertTrue(fixture.model.peerInputIsActive)
    XCTAssertFalse(fixture.model.permitsBackgroundPreparation)
    XCTAssertTrue(fixture.model.permitsPanelPreparation)
    // This second IPC reader also covers admission after peer input began.
    let joinedReader = Task { @MainActor in try await fixture.send(accepted) }
    defer { joinedReader.cancel() }
    blockers.forEach { $0.release() }
    await fulfillment(of: [firstCompleted], timeout: 10)
    let first = try await reader.value, joined = try await joinedReader.value
    XCTAssertTrue(fixture.model.peerInputIsActive, "Rendering completes before the remote contact releases")
    XCTAssertEqual(first["appearance"]?["status"], .string("ready"))
    XCTAssertEqual(joined["appearance"]?["status"], .string("ready"))
    XCTAssertEqual(first["appearance"]?["sourceRevision"], joined["appearance"]?["sourceRevision"])
    let layers = try XCTUnwrap(first["appearance"]?["layers"]?.arrayValues)
    let point = WorldPoint(x: 80, y: 80)
    let webLayer = try XCTUnwrap(layers.first { layer in
      guard layer["id"]?.stringValue?.hasPrefix("page-elements:") == true,
        let frame = try? layer["frame"]?.decode(PageRect.self) else { return false }
      return frame.x <= 80 && frame.y <= 80 && frame.x + frame.width > 80 && frame.y + frame.height > 80
    })
    XCTAssertGreaterThan(try alpha(webLayer, at: point), 0.9, "The reply contains the queued native WebKit pixels")
    XCTAssertEqual(Set(try fixture.store.targetRenderRequests().map(\.id)), durableBefore,
      "Foreground reads do not create durable render requests")

    let contact = UUID()
    fixture.model.inputGate.beginContact(source: contact)
    defer { fixture.model.inputGate.endContact(source: contact) }
    XCTAssertFalse(fixture.model.permitsPanelPreparation)
    do {
      _ = try await fixture.send(accepted)
      XCTFail("Local input must retain its foreground preparation fence")
    } catch let error as CollaborationError { XCTAssertEqual(error.code, "snapshot_pending") }
    fixture.model.inputGate.endContact(source: contact)
    try await fixture.waitUntil(seconds: 5) {
      !fixture.model.inputGate.isActive && fixture.model.permitsPanelPreparation
    }
    XCTAssertTrue(fixture.model.peerInputIsActive, "Local settlement restores the panel while the remote contact stays held")
    XCTAssertTrue(fixture.model.permitsPanelPreparation)
    fixture.model.peerDisconnected(peerID: peer, generation: generation)
    XCTAssertFalse(fixture.model.peerInputIsActive)
    let stopped = await fixture.model.shutdown()
    XCTAssertTrue(stopped)
    XCTAssertFalse(fixture.model.permitsPanelPreparation)
  }

  @MainActor
  func testStoppingTheOwnerCompletesQueuedPanelReadBeforeCapacityReturns() async throws {
    let resources = SceneRenderResources.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-stop-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.waitUntil(seconds: 5) { resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
    var blockers: [WebSurfaceLease] = []
    for _ in 0..<resources.maximumBackgroundWebSurfaces {
      blockers.append(try await resources.acquireWebSurface(priority: .background))
    }
    defer { blockers.forEach { $0.release() } }
    try await fixture.start(showingPage: true)
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let page = try XCTUnwrap(fixture.model.activePage)
    let target = CollaborationTarget(kind: .page, id: page.id)
    try await fixture.apply([.init(kind: .insertElement, target: target, id: "awaiting-native-web-\(UUID())",
      values: ["kind": .string("web"), "source": .string("Accepted material waits for physical admission"),
        "html": .string("<div style='width:180px;height:120px;background:blue'>Native source</div>"),
        "frame": try .encode(PageRect(x: 20, y: 30, width: 180, height: 120))])])
    var command = NotebookCommand(command: .panelPresentation)
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: .init(x: 600, y: 800), pixelScale: 1))
    let accepted = command
    let durableBefore = Set(try fixture.store.targetRenderRequests().map(\.id))
    let replyCompleted = expectation(description: "The accepted IPC request completes before admission returns")
    let ownerStopped = expectation(description: "The owner drains despite unavailable renderer capacity")
    var completions = 0
    let reader = Task { @MainActor in
      do { _ = try await fixture.send(accepted); XCTFail("Cancelled queued presentation returned pixels") }
      catch { }
      completions += 1; replyCompleted.fulfill()
    }
    defer { reader.cancel() }
    try await fixture.waitUntil(seconds: 5) {
      resources.pendingWebRequestCount > 0
    }
    XCTAssertEqual(completions, 0)
    let stopping = Task { @MainActor in
      let stopped = await fixture.model.shutdown()
      XCTAssertTrue(stopped); ownerStopped.fulfill()
    }
    await fulfillment(of: [replyCompleted, ownerStopped], timeout: 5)
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, blockers.count,
      "Cancellation completes without consuming or releasing someone else's admission")
    blockers.forEach { $0.release() }
    await reader.value; await stopping.value
    let stoppedAgain = await fixture.model.shutdown()
    XCTAssertTrue(stoppedAgain)
    XCTAssertEqual(Set(try fixture.store.targetRenderRequests().map(\.id)), durableBefore,
      "Stopping a queued panel read leaves no durable camera request")
  }

  @MainActor
  private func bitmap(_ layer: JSONValue?) throws -> NSBitmapImageRep {
    let base64 = try XCTUnwrap(layer?["pngBase64"]?.stringValue)
    return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Data(base64Encoded: base64))))
  }

  @MainActor
  private func alpha(_ layer: JSONValue, at point: WorldPoint) throws -> CGFloat {
    let frame = try XCTUnwrap(layer["frame"]).decode(PageRect.self)
    let origin = try XCTUnwrap(layer["worldOrigin"]).decode(WorldPoint.self)
    let local = origin.delta(to: point)
    guard local.x >= frame.x, local.y >= frame.y,
      local.x < frame.x + frame.width, local.y < frame.y + frame.height else { return 0 }
    let image = try bitmap(layer)
    let x = Int((local.x - frame.x) / frame.width * Double(image.pixelsWide))
    let y = Int((local.y - frame.y) / frame.height * Double(image.pixelsHigh))
    return try XCTUnwrap(image.colorAt(x: x, y: y)).alphaComponent
  }
}
