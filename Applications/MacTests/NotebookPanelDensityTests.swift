import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPanelDensityTests: XCTestCase {
  override func setUp() async throws { try await InkRasterRenderer.shared.prepareInk() }

  @MainActor
  func testMagnifiedNativeCoverKeepsScreenDensityAndReusesLocalCells() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-density-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let item = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    try await fixture.move(item.id, boardID: target.id, to: .zero)
    try await fixture.apply([.init(kind: .appendInkStroke, target: target, id: UUID().uuidString,
      values: ["width": .number(1.5), "worldOrigin": try .encode(WorldPoint.zero), "points": .array([
        .object(["x": .number(-100.125), "y": .number(-100.375)]),
        .object(["x": .number(100.125), "y": .number(100.375)])])])])
    let nativePresence = fixture.model.presence
    var command = NotebookCommand(command: .panelPresentation)
    let view = NotebookPanelAppearanceProjection(viewport: .init(x: 800, y: 600), pixelScale: 4,
      camera: .init(center: .zero, scale: 4))
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target, appearance: view)
    let reply = try await fixture.send(command)
    let appearance = try XCTUnwrap(reply["appearance"])
    let layers = try XCTUnwrap(appearance["layers"]?.arrayValues)
    let covers = layers.filter { $0["itemID"]?.stringValue?.lowercased() == item.id.uuidString.lowercased() }
    XCTAssertGreaterThan(covers.count, 1, "A magnified notebook needs regional native pixels at its requested display density")
    let required = try XCTUnwrap(view.camera).scale * view.pixelScale
    var pixels = 0
    for layer in layers {
      let width = try XCTUnwrap(layer["pixelWidth"]).decode(Double.self), height = try XCTUnwrap(layer["pixelHeight"]).decode(Double.self)
      pixels += Int(width * height)
    }
    XCTAssertLessThanOrEqual(pixels, NotebookPanelRenderProjection.maximumDecodedPixels)
    XCTAssertLessThanOrEqual(layers.count, 96)
    for cover in covers {
      let frame = try XCTUnwrap(cover["frame"]).decode(PageRect.self)
      let width = try XCTUnwrap(cover["pixelWidth"]).decode(Double.self), height = try XCTUnwrap(cover["pixelHeight"]).decode(Double.self)
      XCTAssertGreaterThanOrEqual(width / frame.width + 0.000001, required)
      XCTAssertGreaterThanOrEqual(height / frame.height + 0.000001, required)
      XCTAssertLessThanOrEqual(width, 2048); XCTAssertLessThanOrEqual(height, 2048)
      let body = try XCTUnwrap(cover["subjectFrame"]).decode(PageRect.self)
      XCTAssertEqual(body.width, 834); XCTAssertEqual(body.height, 1194)
      let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(cover["pngBase64"]?.stringValue)))
      let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
      XCTAssertEqual(bitmap.pixelsWide, Int(width)); XCTAssertEqual(bitmap.pixelsHigh, Int(height))
    }
    XCTAssertFalse(appearance["diagnostics"]?.arrayValues.contains { $0["kind"] == .string("quality_limit") } == true)
    let ink = try XCTUnwrap(layers.first { layer in
      guard layer["order"] == .number(1000),
        let origin = try? layer["worldOrigin"]?.decode(WorldPoint.self),
        let frame = try? layer["frame"]?.decode(PageRect.self) else { return false }
      let offset = origin.delta(to: .init(x: -20, y: -20))
      return offset.x >= frame.x && offset.y >= frame.y
        && offset.x + 16 <= frame.x + frame.width && offset.y + 16 <= frame.y + frame.height
    })
    let inkFrame = try XCTUnwrap(ink["frame"]).decode(PageRect.self)
    let inkOrigin = try XCTUnwrap(ink["worldOrigin"]).decode(WorldPoint.self)
    let actual = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(ink["pngBase64"]?.stringValue)))))
    // World tiles follow physical paper spacing. Their upward pixel refinement
    // can exceed requested density; compare on their exact admitted grid.
    let cameraScale = min(SpatialCamera.maximumScale, max(SpatialCamera.minimumScale, Double(actual.pixelsWide) / inkFrame.width))
    let nativeSize = CGSize(width: inkFrame.width * cameraScale, height: inkFrame.height * cameraScale)
    let nativeCamera = SpatialCamera(center: inkOrigin.offsetBy(x: inkFrame.x + inkFrame.width / 2,
      y: inkFrame.y + inkFrame.height / 2), scale: cameraScale)
    let rasterScale = Double(actual.pixelsWide) / nativeSize.width
    let journal = try fixture.store.loadSpatialInk()
    let referenceImage = try await Task.detached(priority: .utility) {
      let strokes = SpatialInkComposer.boardLayers(board: .board(target.id), journal: journal,
        camera: nativeCamera, viewport: .init(x: nativeSize.width, y: nativeSize.height))
      guard let image = InkRasterRenderer.shared.render(layers: strokes, size: nativeSize, scale: rasterScale)
      else { throw SceneRenderError.resourceLimit }
      return image
    }.value
    let reference = NSBitmapImageRep(cgImage: referenceImage)
    XCTAssertEqual(reference.pixelsWide, actual.pixelsWide); XCTAssertEqual(reference.pixelsHigh, actual.pixelsHigh)
    let inkOffset = inkOrigin.delta(to: .init(x: -20, y: -20))
    let left = max(0, Int(ceil((inkOffset.x - inkFrame.x) / inkFrame.width * Double(actual.pixelsWide))))
    let top = max(0, Int(ceil((inkOffset.y - inkFrame.y) / inkFrame.height * Double(actual.pixelsHigh))))
    let right = min(actual.pixelsWide, Int(floor((inkOffset.x + 16 - inkFrame.x) / inkFrame.width * Double(actual.pixelsWide))))
    let bottom = min(actual.pixelsHigh, Int(floor((inkOffset.y + 16 - inkFrame.y) / inkFrame.height * Double(actual.pixelsHigh))))
    var edgeError: CGFloat = 0, edgeSamples = 0
    for y in top..<bottom {
      for x in left..<right {
        let expected = try XCTUnwrap(reference.colorAt(x: x, y: y)).alphaComponent
        guard expected > 0.05 && expected < 0.95 else { continue }
        edgeError += abs(try XCTUnwrap(actual.colorAt(x: x, y: y)).alphaComponent - expected)
        edgeSamples += 1
      }
    }
    XCTAssertGreaterThan(edgeSamples, 20)
    XCTAssertLessThan(edgeError / CGFloat(max(1, edgeSamples)), 0.035,
      "Magnified board pen edges retain the requested detail instead of scaling a fixed 2x mask")
    let coverage = try XCTUnwrap(appearance["coverage"])
    let anchor = try XCTUnwrap(coverage["anchor"]).decode(WorldPoint.self)
    let region = try XCTUnwrap(coverage["region"]).decode(PageRect.self)
    let camera = try XCTUnwrap(view.camera), origin = camera.screenToWorld(.zero, viewport: view.viewport)
    let offset = anchor.delta(to: origin)
    XCTAssertLessThanOrEqual(region.x, offset.x); XCTAssertLessThanOrEqual(region.y, offset.y)
    XCTAssertGreaterThanOrEqual(region.x + region.width, offset.x + view.viewport.x / camera.scale)
    XCTAssertGreaterThanOrEqual(region.y + region.height, offset.y + view.viewport.y / camera.scale)
    let held = try layers.map { try XCTUnwrap($0["assetID"]?.stringValue.flatMap(UUID.init(uuidString:))) }
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: view.viewport, pixelScale: view.pixelScale, camera: .init(center: .init(x: 1, y: 0), scale: 4)),
      knownAssets: held)
    let translated = try await fixture.send(command)
    let reused = try XCTUnwrap(translated["appearance"]?["layers"]?.arrayValues)
      .filter { $0["itemID"]?.stringValue?.lowercased() == item.id.uuidString.lowercased() }
    XCTAssertEqual(reused.map { $0["assetID"] }, covers.map { $0["assetID"] })
    XCTAssertTrue(reused.allSatisfy { $0["pngBase64"] == nil }, "A one-point pan borrows the completed native cells")
    XCTAssertEqual(fixture.model.presence, nativePresence)
  }
}
