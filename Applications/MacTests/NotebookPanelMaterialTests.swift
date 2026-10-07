import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPanelMaterialTests: XCTestCase {
  override func setUp() async throws { try await InkRasterRenderer.shared.prepareInk() }

  @MainActor
  func testWarmPanelMaterialKeepsItsActualLeafWitnessAndRefreshesForSameSourcePixels() async throws {
    let (fixture, header, target) = try await fixture()
    try await fixture.apply([.init(kind: .insertElement, target: target, id: "program", values: [
      "kind": .string("web"), "source": .string("Saved program"),
      "html": .string("<svg viewBox='0 0 16 16'/>"), "worldOrigin": try .encode(WorldPoint.zero),
      "frame": try .encode(PageRect(x: -8, y: -8, width: 16, height: 16))])])
    let revision = try fixture.store.workspaceHeader().cursor
    let source = SceneCompositionSource(store: fixture.store, revision: revision,
      workspaceID: header.workspaceID, recordPixelDependencies: true)
    let value = try await source.readElementForPaint("program", boardID: target.id)
    let leaf = SceneRasterSource.agent(agentElementSnapshotSource(try XCTUnwrap(value).element))
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, profile: .headless)
    func image(_ color: NSColor) -> NSImage {
      let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
      return NSImage(cgImage: context.makeImage()!, size: .init(width: 16, height: 16))
    }
    XCTAssertTrue(resources.store(image(.blue), for: leaf))
    let firstLeaf = try XCTUnwrap(resources.retainRaster(for: leaf))
    let used = firstLeaf.leafRasters
    firstLeaf.release()
    let renderer = SceneCompositionRenderer(source: source, resources: resources)
    let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: .zero, scale: 1), viewport: .init(x: 256, y: 256), pixelScale: 1)
    let presence = SessionPresence(boardID: target.id, mode: .board,
      camera: projection.camera, viewport: projection.viewport)
    let first = try await renderer.renderPanel(presence: presence, projection: projection,
      editableIDs: ["program"], movableItemIDs: [], knownAssets: [])
    let original = try XCTUnwrap(first.layers.first { $0.elementID == "program" })
    XCTAssertEqual(original.leafRasters, used)
    XCTAssertTrue(first.leafRasters.contains(try XCTUnwrap(used.first)))

    let warm = try await renderer.renderPanel(presence: presence, projection: projection,
      editableIDs: ["program"], movableItemIDs: [], knownAssets: Set(first.layers.map(\.assetID)))
    let reused = try XCTUnwrap(warm.layers.first { $0.elementID == "program" })
    XCTAssertEqual(reused.assetID, original.assetID)
    XCTAssertEqual(reused.leafRasters, used, "A cache hit carries its original leaf entry, not a fresh source lookup")
    XCTAssertNil(reused.png)

    XCTAssertTrue(resources.store(image(.red), for: leaf))
    XCTAssertFalse(resources.leafRastersAreCurrent(warm.leafRasters))
    let currentLeaf = try XCTUnwrap(resources.retainRaster(for: leaf))
    let current = currentLeaf.leafRasters
    currentLeaf.release()
    let updated = try await renderer.renderPanel(presence: presence, projection: projection,
      editableIDs: ["program"], movableItemIDs: [], knownAssets: Set(first.layers.map(\.assetID)))
    let repainted = try XCTUnwrap(updated.layers.first { $0.elementID == "program" })
    XCTAssertNotEqual(repainted.assetID, original.assetID)
    XCTAssertEqual(repainted.leafRasters, current)
    let pixel = try color(repainted.encoded, x: 8, y: 8)
    XCTAssertGreaterThan(pixel.redComponent, 0.95)
    XCTAssertLessThan(pixel.blueComponent, 0.05)
  }

  @MainActor
  func testBudgetDemotedElementBodiesNeverCreateDiscardedMaterialRasters() async throws {
    let (fixture, header, target) = try await fixture()
    // Wide passive bodies keep the interleaved bands over the aggregate
    // budget until independent bodies rejoin the ordinary painter.
    let center = WorldPoint.zero
    let optional = Set((0..<16).map { String(format: "budget-%02d", $0 * 2 + 1) })
    try await fixture.apply((0..<33).map { index in
      let id = String(format: "budget-%02d", index)
      let color = index.isMultiple(of: 2) ? SpatialInkColor(red: 0, green: 0, blue: 1)
        : SpatialInkColor(red: 0.5 + Double(index) / 80, green: 0, blue: 0)
      return .init(kind: .insertElement, target: target, id: id, values: ["kind": .string("graphic"),
        "source": .string(""), "graphic": try .encode(NotebookGraphic(shape: .rectangle,
          style: .init(stroke: color, strokeWidth: 1, fill: color))),
        "worldOrigin": try .encode(center),
        "frame": try .encode(index.isMultiple(of: 2)
          ? PageRect(x: -768, y: -768, width: 1536, height: 1536)
          : PageRect(x: -10, y: -10, width: 20, height: 20))])
    })
    let current = try fixture.store.workspaceHeader()
    let source = SceneCompositionSource(store: fixture.store, revision: current.cursor,
      workspaceID: header.workspaceID, recordPixelDependencies: true)
    // Keep every produced entry resident so absence cannot be explained by eviction.
    let resources = SceneRenderResources(byteLimit: 512 * 1024 * 1024, profile: .headless)
    let renderer = SceneCompositionRenderer(source: source, resources: resources)
    let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: center, scale: 1), viewport: .init(x: 1536, y: 1536), pixelScale: 1)
    let presence = SessionPresence(boardID: target.id, mode: .board,
      camera: projection.camera, viewport: projection.viewport)
    // The response owns small PNG grants until its last layer borrow ends.
    do {
      let result = try await renderer.renderPanel(presence: presence, projection: projection,
        editableIDs: optional, movableItemIDs: [], knownAssets: [])
      let admitted = Set(result.layers.compactMap(\.elementID)), discarded = optional.subtracting(admitted)
      XCTAssertFalse(discarded.isEmpty, "Interleaved passive bands force the real aggregate budget to demote bodies")
      for id in discarded {
        let value = try await source.readElementForPaint(id, boardID: target.id)
        let read = try XCTUnwrap(value)
        let presentation = read.placement.map { NotebookElementPresentation(read.element, placement: $0) }
        let key = try await source.elementMaterialKey(read, boardID: target.id, presentation: presentation, density: 1)
        let unexpected = resources.retainMaterial(key)
        XCTAssertNil(unexpected, "A demoted body must not begin raster/PNG preparation before admission")
        unexpected?.release()
      }
      XCTAssertEqual(resources.rasterCount, Set(result.layers.map(\.assetID)).count,
        "Only final cohort pixels were produced; no discarded material or eviction hides wasted work")
      XCTAssertLessThan(resources.peakAccountedBytes, resources.byteLimit)
      XCTAssertLessThanOrEqual(result.layers.count, 96)
      XCTAssertLessThanOrEqual(result.layers.reduce(0) { $0 + $1.pixelWidth * $1.pixelHeight },
        NotebookPanelRenderProjection.maximumDecodedPixels)
      for layer in result.layers where layer.repeatSize == nil {
        XCTAssertGreaterThanOrEqual(min(Double(layer.pixelWidth) / layer.frame.width,
          Double(layer.pixelHeight) / layer.frame.height), 0.995)
      }
      let sample = center.offsetBy(x: -5, y: -5)
      let covering = result.layers.filter { layer in
        let point = layer.worldOrigin.delta(to: sample)
        return layer.repeatSize == nil && point.x >= layer.frame.x && point.y >= layer.frame.y
          && point.x < layer.frame.x + layer.frame.width && point.y < layer.frame.y + layer.frame.height
      }.sorted { $0.order < $1.order }
      // Empty ink tiles still cover this point above the element bands. Check
      // the displayed source-over result, not the highest layer's clear pixel.
      var pixel = (red: CGFloat(0), blue: CGFloat(0), alpha: CGFloat(0))
      for layer in covering {
        let point = layer.worldOrigin.delta(to: sample)
        let image = try bitmap(layer.encoded)
        let color = try XCTUnwrap(image.colorAt(x: Int((point.x - layer.frame.x) * Double(layer.pixelWidth) / layer.frame.width),
          y: Int((point.y - layer.frame.y) * Double(layer.pixelHeight) / layer.frame.height))?.usingColorSpace(.deviceRGB))
        let alpha = color.alphaComponent
        pixel = (color.redComponent * alpha + pixel.red * (1 - alpha),
          color.blueComponent * alpha + pixel.blue * (1 - alpha), alpha + pixel.alpha * (1 - alpha))
      }
      XCTAssertGreaterThan(pixel.alpha, 0.95)
      XCTAssertGreaterThan(pixel.blue, 0.95, "The last passive body remains above every admitted red subject")
      XCTAssertLessThan(pixel.red, 0.05)
      let repeated = try await renderer.renderPanel(presence: presence, projection: projection,
        editableIDs: optional, movableItemIDs: [], knownAssets: Set(result.layers.map(\.assetID)))
      XCTAssertEqual(repeated.layers.map(\.assetID), result.layers.map(\.assetID))
      XCTAssertEqual(repeated.layers.map(\.order), result.layers.map(\.order))
      XCTAssertTrue(repeated.layers.allSatisfy { $0.png == nil })
    }
    XCTAssertEqual(resources.reservedBytes, 0, "Every transient grant ends with the response; entry PNG residency stays charged")
  }

  @MainActor
  func testBudgetDemotedCoverCellsNeverAllocateIndependentMaterialPixels() async throws {
    let (fixture, header, target) = try await fixture()
    let ids = (0..<16).map { _ in UUID() }, center = WorldPoint(x: 2048, y: 2048)
    try await fixture.apply(ids.map { id in
      .init(kind: .createNotebook, target: target, id: id.uuidString,
        values: ["center": try .encode(center), "pageID": try .encode(UUID())])
    })
    let current = try fixture.store.workspaceHeader()
    let source = SceneCompositionSource(store: fixture.store, revision: current.cursor,
      workspaceID: header.workspaceID, recordPixelDependencies: true)
    let resources = SceneRenderResources(byteLimit: 512 * 1024 * 1024, profile: .headless)
    let renderer = SceneCompositionRenderer(source: source, resources: resources)
    let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: center, scale: 1), viewport: .init(x: 2048, y: 2048), pixelScale: 2)
    let result = try await renderer.renderPanel(presence: .init(boardID: target.id, mode: .board,
      camera: projection.camera, viewport: projection.viewport), projection: projection,
      editableIDs: [], movableItemIDs: Set(ids), knownAssets: [])
    XCTAssertLessThan(Set(result.layers.compactMap(\.itemID)).count, ids.count,
      "The crowded cohort still demotes bodies before preparing any pixels")
    XCTAssertFalse(result.diagnostics.contains { $0.kind == "quality_limit" }, "Empty ink cannot consume the cover budget")
    for layer in result.layers where layer.repeatSize == nil {
      XCTAssertGreaterThanOrEqual(min(Double(layer.pixelWidth) / layer.frame.width,
        Double(layer.pixelHeight) / layer.frame.height) + 0.000001, projection.camera.scale * projection.pixelScale)
    }
    XCTAssertEqual(resources.rasterCount, Set(result.layers.map(\.assetID)).count,
      "No independent cover cells may be prepared and then thrown away")
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertLessThan(resources.peakAccountedBytes, resources.byteLimit)
    XCTAssertLessThanOrEqual(result.layers.count, 96)
    XCTAssertLessThanOrEqual(result.layers.reduce(0) { $0 + $1.pixelWidth * $1.pixelHeight },
      NotebookPanelRenderProjection.maximumDecodedPixels)
  }

  @MainActor
  func testLocalEditAndTranslationReuseUnchangedPixelsWhileTextAndSizeRefresh() async throws {
    let (fixture, header, target) = try await fixture()
    let ids = ["caption", "neighbor"] + (0..<14).map { "note-\($0)" }
    try await fixture.apply(ids.enumerated().map { index, id in
      .init(kind: .insertElement, target: target, id: id, values: ["kind": .string("nativeText"),
        "source": .string("Original \(id)"), "worldOrigin": try .encode(WorldPoint.zero),
        "frame": try .encode(PageRect(x: Double(index % 4) * 230 - 450,
          y: Double(index / 4) * 160 - 300, width: 200, height: 80))])
    })
    let first = try await render(fixture, header: header, target: target)
    XCTAssertEqual(first.count, ids.count)
    let original = try XCTUnwrap(first["caption"])
    XCTAssertNotNil(original["pngBase64"])
    try await fixture.apply([.init(kind: .updateElement, target: target, id: "neighbor",
      values: ["source": .string("A different neighboring sentence")])])
    let changed = try await render(fixture, header: header, target: target, known: first)
    for id in ids where id != "neighbor" {
      XCTAssertEqual(changed[id]?["assetID"], first[id]?["assetID"])
      XCTAssertNil(changed[id]?["pngBase64"], "A neighboring edit must not repaint or encode this body")
    }
    XCTAssertNotEqual(changed["neighbor"]?["assetID"], first["neighbor"]?["assetID"])
    XCTAssertNotNil(changed["neighbor"]?["pngBase64"])

    try await fixture.apply([.init(kind: .updateElement, target: target, id: "caption",
      values: ["frame": try .encode(PageRect(x: -150, y: 60, width: 200, height: 80))])])
    let moved = try await render(fixture, header: header, target: target, known: changed)
    XCTAssertEqual(moved["caption"]?["assetID"], original["assetID"])
    XCTAssertNil(moved["caption"]?["pngBase64"])
    XCTAssertNotEqual(moved["caption"]?["frame"], original["frame"])

    try await fixture.apply([.init(kind: .updateElement, target: target, id: "caption",
      values: ["source": .string("Replacement")])])
    let edited = try await render(fixture, header: header, target: target, known: moved)
    XCTAssertNotEqual(edited["caption"]?["assetID"], original["assetID"])
    XCTAssertNotEqual(edited["caption"]?["pngBase64"], original["pngBase64"])
    XCTAssertNotNil(edited["caption"]?["pngBase64"])
    XCTAssertEqual(edited["neighbor"]?["assetID"], changed["neighbor"]?["assetID"])

    try await fixture.apply([.init(kind: .updateElement, target: target, id: "caption",
      values: ["frame": try .encode(PageRect(x: -150, y: 60, width: 80, height: 80))])])
    let resized = try await render(fixture, header: header, target: target, known: edited)
    XCTAssertNotEqual(resized["caption"]?["assetID"], edited["caption"]?["assetID"])
    XCTAssertNotEqual(resized["caption"]?["pixelWidth"], edited["caption"]?["pixelWidth"])
    XCTAssertEqual(resized["neighbor"]?["assetID"], changed["neighbor"]?["assetID"])
  }

  @MainActor
  func testMovingBoundEndpointRefreshesConnectorWithoutChangingItsAuthoredSource() async throws {
    let (fixture, header, target) = try await fixture()
    let connection = NotebookGraphic(shape: .connector,
      style: .init(stroke: .init(red: 0.9, green: 0.1, blue: 0.1), strokeWidth: 8),
      connection: .init(start: .init(point: .zero, binding: .init(elementID: "left")),
        end: .init(point: .zero, binding: .init(elementID: "right")), routing: .elbow))
    try await fixture.apply([
      .init(kind: .insertElement, target: target, id: "left", values: ["kind": .string("graphic"),
        "source": .string(""), "graphic": try .encode(NotebookGraphic(shape: .rectangle)),
        "worldOrigin": try .encode(WorldPoint.zero),
        "frame": try .encode(PageRect(x: -220, y: -80, width: 100, height: 80))]),
      .init(kind: .insertElement, target: target, id: "right", values: ["kind": .string("graphic"),
        "source": .string(""), "graphic": try .encode(NotebookGraphic(shape: .rectangle)),
        "worldOrigin": try .encode(WorldPoint.zero),
        "frame": try .encode(PageRect(x: 120, y: 80, width: 100, height: 80))]),
      .init(kind: .insertElement, target: target, id: "link", values: ["kind": .string("graphic"),
        "source": .string(""), "graphic": try .encode(connection),
        "worldOrigin": try .encode(WorldPoint.zero),
        "frame": try .encode(PageRect(x: -220, y: -80, width: 440, height: 240))])])
    let authored = try XCTUnwrap(fixture.store.readSpatialElement(boardID: target.id, elementID: "link"))
    let first = try await render(fixture, header: header, target: target, materialIDs: ["left", "right", "link"])
    XCTAssertNotNil(first["link"]?["pngBase64"])
    try await fixture.apply([.init(kind: .updateElement, target: target, id: "right",
      values: ["frame": try .encode(PageRect(x: 120, y: 160, width: 100, height: 80))])])
    let moved = try await render(fixture, header: header, target: target, known: first, materialIDs: ["left", "right", "link"])
    XCTAssertEqual(try fixture.store.readSpatialElement(boardID: target.id, elementID: "link"), authored)
    XCTAssertNotEqual(moved["link"]?["assetID"], first["link"]?["assetID"])
    XCTAssertNotNil(moved["link"]?["pngBase64"])
    XCTAssertNotEqual(moved["link"]?["pngBase64"], first["link"]?["pngBase64"])
    for id in ["left", "right"] {
      XCTAssertEqual(moved[id]?["assetID"], first[id]?["assetID"])
      XCTAssertNil(moved[id]?["pngBase64"], "Only the connector's local pixels changed")
    }
  }

  @MainActor
  func testTranslatedRotatedTextKeepsPixelsAndChangingBasisRefreshesThem() async throws {
    let (fixture, header, target) = try await fixture()
    let angle = Double.pi / 7, cosine = cos(angle), sine = sin(angle)
    let width = 200 * cosine + 80 * sine, height = 200 * sine + 80 * cosine
    let basis = NotebookElementBasis(size: .init(x: 200, y: 80),
      transform: .init(a: 200 * cosine / width, b: 200 * sine / height,
        c: -80 * sine / width, d: 80 * cosine / height, tx: 80 * sine / width, ty: 0))
    try await fixture.apply([.init(kind: .insertElement, target: target, id: "rotated",
      values: ["kind": .string("nativeText"), "source": .string("Rotated note"),
        "textStyle": try .encode(NativeTextStyle(fontSize: 20)),
        "worldOrigin": try .encode(WorldPoint.zero), "basis": try .encode(basis),
        "frame": try .encode(PageRect(x: -200.125, y: -100.875, width: width, height: height))])])
    let first = try await render(fixture, header: header, target: target, materialIDs: ["rotated"])
    let original = try XCTUnwrap(first["rotated"])
    let image = try bitmap(original)
    XCTAssertTrue((0..<image.pixelsHigh).contains { y in
      (0..<image.pixelsWide).contains { x in (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
    }, "The reused source must contain the actual native text")
    var previous = first
    for offset in [SpatialPoint(x: 60.375, y: 80.125), .init(x: -17.1, y: -23.7), .init(x: -200.125, y: -100.875)] {
      try await fixture.apply([.init(kind: .updateElement, target: target, id: "rotated",
        values: ["frame": try .encode(PageRect(x: offset.x, y: offset.y, width: width, height: height))])])
      let moved = try await render(fixture, header: header, target: target, known: previous, materialIDs: ["rotated"])
      XCTAssertEqual(moved["rotated"]?["assetID"], original["assetID"],
        "World translation must not enter the rotated body's pixel basis")
      XCTAssertNil(moved["rotated"]?["pngBase64"])
      XCTAssertNotEqual(moved["rotated"]?["frame"], previous["rotated"]?["frame"])
      previous = moved
    }
    try await fixture.apply([.init(kind: .updateElement, target: target, id: "rotated",
      values: ["basis": try .encode(NotebookElementBasis(size: .init(x: 200, y: 80),
        transform: .init(a: 0.8, b: 0.2, c: 0.2, d: 0.8, tx: 0, ty: 0)))])])
    let changed = try await render(fixture, header: header, target: target, known: previous, materialIDs: ["rotated"])
    XCTAssertNotEqual(changed["rotated"]?["assetID"], original["assetID"])
    XCTAssertNotNil(changed["rotated"]?["pngBase64"])
    XCTAssertNotEqual(changed["rotated"]?["pngBase64"], original["pngBase64"])
  }

  @MainActor
  func testMeasuredErasureAndUndoRefreshOnlyTheAffectedBody() async throws {
    let (fixture, header, target) = try await fixture()
    fixture.model.updatePresence(.init(boardID: target.id, mode: .board,
      camera: .init(scale: 1), viewport: .init(x: 1000, y: 700)), settled: true)
    let frame = PageRect(x: -140, y: -100, width: 160, height: 160)
    let red = SpatialInkColor(red: 1, green: 0, blue: 0)
    let graphic = NotebookGraphic(shape: .rectangle, style: .init(stroke: red, strokeWidth: 2, fill: red))
    let neighbor = NotebookGraphic(shape: .rectangle,
      style: .init(strokeWidth: 2, fill: .init(red: 0, green: 1, blue: 0)))
    try await fixture.apply(["paint", "neighbor"].enumerated().map { index, id in
      .init(kind: .insertElement, target: target, id: id,
        values: ["kind": .string("graphic"), "source": .string(""), "graphic": try .encode(index == 0 ? graphic : neighbor),
          "worldOrigin": try .encode(WorldPoint.zero),
          "frame": try .encode(PageRect(x: frame.x + Double(index) * 280, y: frame.y,
            width: frame.width, height: frame.height))])
    })
    let first = try await render(fixture, header: header, target: target, materialIDs: ["paint", "neighbor"])
    let original = try XCTUnwrap(first["paint"])
    let before = try color(original, x: 80, y: 80)
    XCTAssertGreaterThan(before.alphaComponent, 0.95)
    XCTAssertGreaterThan(before.redComponent, 0.95)
    let sample = SpatialInkSample(point: .init(x: -60, y: -20), worldPoint: .init(x: -60, y: -20),
      timeOffset: 0, width: 40, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    let action = try XCTUnwrap(fixture.model.appendSpatialInk(tool: .eraser, color: .black,
      spans: [.init(surface: .board(target.id), samples: [sample],
        elementTargets: [.init(elementID: "paint", frame: frame, worldOrigin: .zero)])]))
    let saved = await fixture.model.finishPendingPersistence(); XCTAssertTrue(saved)
    let erased = try await render(fixture, header: header, target: target, known: first, materialIDs: ["paint", "neighbor"])
    let cut = try XCTUnwrap(erased["paint"])
    XCTAssertNotEqual(cut["assetID"], original["assetID"])
    XCTAssertLessThan(try color(cut, x: 80, y: 80).alphaComponent, 0.05)
    XCTAssertGreaterThan(try color(cut, x: 120, y: 120).alphaComponent, 0.95)
    XCTAssertEqual(erased["neighbor"]?["assetID"], first["neighbor"]?["assetID"])
    XCTAssertNil(erased["neighbor"]?["pngBase64"])

    fixture.model.undoLastSurfaceAction()
    let undone = await fixture.model.finishPendingPersistence(); XCTAssertTrue(undone)
    XCTAssertEqual(try fixture.store.readSpatialInk(surfaces: [.board(target.id)])
      .actions.first { $0.id == action.id }?.isActive, false)
    let restored = try await render(fixture, header: header, target: target, known: erased, materialIDs: ["paint", "neighbor"])
    let restoredPaint = try XCTUnwrap(restored["paint"])
    XCTAssertEqual(restoredPaint["assetID"], original["assetID"], "Undo reuses the original uncut pixels")
    XCTAssertGreaterThan(try color(restoredPaint, x: 80, y: 80).alphaComponent, 0.95)
    XCTAssertEqual(restored["neighbor"]?["assetID"], first["neighbor"]?["assetID"])
    XCTAssertNil(restored["neighbor"]?["pngBase64"])
  }

  @MainActor
  func testProgramStateChangesItsPixelsWithoutRepaintingItsNeighbor() async throws {
    let (fixture, header, target) = try await fixture()
    try await fixture.apply([
      .init(kind: .insertElement, target: target, id: "a-program", values: ["kind": .string("web"),
        "source": .string(""), "worldOrigin": try .encode(WorldPoint.zero),
        "frame": try .encode(PageRect(x: -220, y: -60, width: 160, height: 120)),
        "html": .string("<div id='paint' style='position:absolute;inset:0'></div>"),
        "javaScript": .string("""
        const draw = () => { document.getElementById('paint').style.background = notebook.state.color; };
        addEventListener('notebookstate', draw);
        notebook.ready(Promise.resolve().then(draw));
        """), "state": .object(["color": .string("rgb(255, 0, 0)")])]),
      .init(kind: .insertElement, target: target, id: "neighbor", values: ["kind": .string("nativeText"),
        "source": .string("Unchanged native note"), "worldOrigin": try .encode(WorldPoint.zero),
        "frame": try .encode(PageRect(x: 40, y: -60, width: 200, height: 120))])])
    let first = try await render(fixture, header: header, target: target, materialIDs: ["a-program", "neighbor"])
    let before = try color(XCTUnwrap(first["a-program"]), x: 80, y: 60)
    XCTAssertGreaterThan(before.redComponent, 0.95)
    XCTAssertLessThan(before.blueComponent, 0.05)
    try await fixture.apply([.init(kind: .setElementState, target: target, id: "a-program",
      values: ["state": .object(["color": .string("rgb(0, 0, 255)")])])])
    let changed = try await render(fixture, header: header, target: target, known: first, materialIDs: ["a-program", "neighbor"])
    let program = try XCTUnwrap(changed["a-program"])
    XCTAssertNotEqual(program["assetID"], first["a-program"]?["assetID"])
    let after = try color(program, x: 80, y: 60)
    XCTAssertLessThan(after.redComponent, 0.05)
    XCTAssertGreaterThan(after.blueComponent, 0.95)
    XCTAssertEqual(changed["neighbor"]?["assetID"], first["neighbor"]?["assetID"])
    XCTAssertNil(changed["neighbor"]?["pngBase64"])
    let repeated = try await render(fixture, header: header, target: target, known: changed, materialIDs: ["a-program", "neighbor"])
    XCTAssertEqual(repeated["a-program"]?["assetID"], program["assetID"])
    XCTAssertNil(repeated["a-program"]?["pngBase64"])
  }

  @MainActor
  private func bitmap(_ layer: JSONValue) throws -> NSBitmapImageRep {
    let encoded = try XCTUnwrap(layer["pngBase64"]?.stringValue)
    return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(Data(base64Encoded: encoded))))
  }

  @MainActor
  private func color(_ layer: JSONValue, x: Int, y: Int) throws -> NSColor {
    try XCTUnwrap(bitmap(layer).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
  }

  @MainActor
  private func fixture() async throws -> (MacCommandFixture, NotebookWorkspaceHeader, CollaborationTarget) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-local-pixels-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let item = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    try await fixture.move(item.id, boardID: target.id, to: .init(x: 5000, y: 0))
    return (fixture, header, target)
  }

  @MainActor
  private func render(_ fixture: MacCommandFixture, header: NotebookWorkspaceHeader,
    target: CollaborationTarget, known: [String: JSONValue] = [:],
    materialIDs: Set<String>? = nil) async throws -> [String: JSONValue] {
    let assets = known.values.compactMap { $0["assetID"]?.stringValue.flatMap(UUID.init(uuidString:)) }
    let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: .zero, scale: 1), viewport: .init(x: 1000, y: 700), pixelScale: 1)
    let began = ContinuousClock.now
    let layers: [JSONValue]
    if let materialIDs {
      // Manipulation admission excludes bound, transformed and erased subjects.
      // Exercise their actual pixels at the material owner's boundary instead.
      let current = try fixture.store.workspaceHeader()
      let source = SceneCompositionSource(store: fixture.store, revision: current.cursor,
        workspaceID: header.workspaceID, recordPixelDependencies: true)
      let renderer = SceneCompositionRenderer(source: source,
        permitsPreparation: { fixture.model.permitsBackgroundPreparation })
      let result = try await renderer.renderPanel(presence: .init(boardID: target.id, mode: .board,
        camera: projection.camera, viewport: projection.viewport), projection: projection,
        editableIDs: materialIDs, movableItemIDs: [], knownAssets: Set(assets))
      layers = try result.layers.map { try $0.encoded }
    } else {
      var command = NotebookCommand(command: .panelPresentation)
      command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
        appearance: .init(viewport: projection.viewport, pixelScale: projection.pixelScale,
          camera: projection.camera), knownAssets: assets)
      let reply = try await fixture.send(command)
      XCTAssertEqual(reply["appearance"]?["status"], .string("ready"))
      layers = try XCTUnwrap(reply["appearance"]?["layers"]?.arrayValues)
    }
    let elapsed = began.duration(to: .now).components
    let subjects = layers.filter { $0["elementID"] != nil }
    let encoded = subjects.compactMap { $0["pngBase64"]?.stringValue }
    let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    print("PANEL_MATERIALS ms=\(milliseconds) subjects=\(subjects.count) encoded=\(encoded.count) base64Bytes=\(encoded.reduce(0) { $0 + $1.utf8.count })")
    return Dictionary(uniqueKeysWithValues: subjects.compactMap { layer in
      layer["elementID"]?.stringValue.map { ($0, layer) }
    })
  }
}
