import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPanelMaterialTests: XCTestCase {
  override func setUp() async throws { try await InkRasterRenderer.shared.prepareInk() }

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
