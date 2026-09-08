import AppKit
import CryptoKit
import NotebookCore
import SwiftUI
import XCTest
@testable import Notebook

final class PortalRenderingTests: XCTestCase {
  @MainActor
  func testPortalAndActiveBoardRenderTheSameContentAtHandoff() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    let workspace = try XCTUnwrap(model.workspace)
    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    let actor = UUID()
    let stamp = VersionStamp(counter: 0, actor: actor)
    let elements = [
      SpatialElement(id: "native", surface: .board(childID), kind: .nativeText,
        frame: SpatialRect(x: 0, y: 0, width: 460, height: 90),
        worldOrigin: WorldPoint(x: -300, y: -450), source: "Живая доска", stamp: stamp),
      SpatialElement(id: "markdown", surface: .board(childID), kind: .markdown,
        frame: SpatialRect(x: 0, y: 0, width: 460, height: 160),
        worldOrigin: WorldPoint(x: -300, y: -320), source: "# Формула и текст",
        html: "<h1>Формула и текст</h1><p><b>Готовая</b> разметка</p>", stamp: stamp),
      SpatialElement(id: "svg", surface: .board(childID), kind: .web,
        frame: SpatialRect(x: 0, y: 0, width: 460, height: 210),
        worldOrigin: WorldPoint(x: -300, y: -100), source: "<svg>",
        html: "<svg viewBox='0 0 460 210'><rect width='460' height='210' fill='#19a08f'/><circle cx='230' cy='105' r='70' fill='#ed6729'/></svg>", stamp: stamp),
    ]
    for element in elements {
      XCTAssertTrue(hierarchy.upsertElement(element, in: childID, expected: nil, actor: actor))
    }
    XCTAssertTrue(hierarchy.updatePortalCamera(BoardPortalCamera(scale: 0.85), for: childID, actor: actor))
    model.receivePeerMessage(.board(hierarchy))
    var ink = try XCTUnwrap(model.spatialInk)
    for (tool, y, width) in [(SpatialInkTool.pen, 280.0, 35.0), (.eraser, 280.0, 16.0)] {
      let points = [-240.0, 0, 240].map { x in
        SpatialInkSample(point: .zero, worldPoint: WorldPoint(x: x, y: y),
          timeOffset: (x + 240) / 100, width: width, opacity: 1,
          force: 1, azimuth: 0, altitude: 1)
      }
      _ = ink.append(tool: tool, spans: [SpatialInkSpan(surface: .board(childID), samples: points)], actor: actor)
    }
    model.receivePeerMessage(.spatialInk(ink))
    for size in [SpatialPoint(x: 834, y: 1_194), SpatialPoint(x: 1_366, y: 1_024)] {
      let camera = BoardPortalProjection.entryCamera(portalCamera: hierarchy.portalCamera(childID)!, viewport: size)
      let presence = SessionPresence(boardID: childID, mode: .board, camera: camera, viewport: size)
      let sourceIndex = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: model.documents.mapValues(\.paperSize))
      let painter = SceneCompositionRenderer(index: sourceIndex, hierarchy: hierarchy, journal: ink)
      let parent = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
        camera: BoardPortalProjection.parentBoundaryCamera(portalCenter: .zero, viewport: size), viewport: size)
      let first = try pixels(try await painter.render(presence: parent, scale: 1).png, size: size)
      let second = try pixels(try await painter.render(presence: presence, scale: 1).png, size: size)
      XCTAssertEqual(first.count, second.count)
      let difference = zip(first, second).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
        / Double(first.count * 255)
      XCTContext.runActivity(named: "Сравнение портала \(Int(size.x)) × \(Int(size.y)): MAE \(difference)") { activity in
        let attachment = XCTAttachment(string: "normalized_pixel_MAE=\(difference); channels=\(first.count)")
        attachment.lifetime = .keepAlways
        activity.add(attachment)
      }
      XCTAssertLessThan(difference, 0.003, "Готовые слои и стёртые чернила сохраняют изображение при передаче: \(size)")
      XCTAssertGreaterThan(first.filter { $0 < 150 }.count, 5_000)
    }
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
  }

  @MainActor
  func testSequentialCompositionKeepsOverlapsCoversAndNestedPortals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let notebook = try XCTUnwrap(model.workspace?.selectedItemID)
    model.moveItem(notebook, to: .init(x: -350, y: 0))
    let portal = try XCTUnwrap(model.createBoard(at: .init(x: 650, y: 0)))
    let document = try XCTUnwrap(model.createDocument(at: .init(x: 1550, y: 0), paperSize: .letter))
    let workspace = try XCTUnwrap(model.workspace)
    var hierarchy = try XCTUnwrap(model.boardHierarchy)
    let actor = UUID(), stamp = VersionStamp(counter: 0, actor: UUID())
    let elements = [
      SpatialElement(id: "behind-covers", surface: .board(workspace.rootBoardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 2000, height: 180), worldOrigin: .init(x: -800, y: 400),
        source: "red band", html: "<svg width='2000' height='180'><rect width='2000' height='180' fill='red' fill-opacity='.5'/></svg>", stamp: stamp),
      SpatialElement(id: "on-cover", surface: .cover(notebook), kind: .web,
        frame: .init(x: 120, y: 420, width: 580, height: 280), source: "transparent circle",
        html: "<svg width='580' height='280'><circle cx='290' cy='140' r='125' fill='blue' fill-opacity='.5'/></svg>", stamp: stamp),
      SpatialElement(id: "in-portal", surface: .board(portal), kind: .web,
        frame: .init(x: 0, y: 0, width: 600, height: 700), worldOrigin: .init(x: -300, y: -350),
        source: "green field", html: "<svg width='600' height='700'><rect width='600' height='700' fill='green'/></svg>", stamp: stamp),
      SpatialElement(id: "title", surface: .cover(document), kind: .nativeText,
        frame: .init(x: 60, y: 600, width: 500, height: 90), source: "Связанный документ", stamp: stamp)
    ]
    for element in elements {
      XCTAssertTrue(hierarchy.upsertElement(element,
        in: element.surface == .board(portal) ? portal : workspace.rootBoardID, expected: nil, actor: actor))
    }
    _ = hierarchy.updatePortalCamera(.init(scale: 0.8), for: portal, actor: actor)
    model.receivePeerMessage(.board(hierarchy))
    var ink = try XCTUnwrap(model.spatialInk)
    for (tool, width) in [(SpatialInkTool.pen, 42.0), (.eraser, 13.0)] {
      let samples = [100.0, 650.0].map { x in SpatialInkSample(point: .init(x: x, y: 550),
        timeOffset: x / 1000, width: width, opacity: 1, force: 1, azimuth: 0, altitude: 1) }
      _ = ink.append(tool: tool, spans: [.init(surface: .cover(notebook), samples: samples)], actor: actor)
    }
    model.receivePeerMessage(.spatialInk(ink))
    let sourceIndex = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: model.documents.mapValues(\.paperSize))
    for scale in [0.3, 0.6] {
      let size = SpatialPoint(x: 1194, y: 834)
      let presence = SessionPresence(boardID: workspace.rootBoardID, mode: .board,
        camera: .init(center: .init(x: 400, y: 0), scale: scale), viewport: size)
      let painter = SceneCompositionRenderer(index: sourceIndex, hierarchy: hierarchy, journal: ink)
      let result = try await painter.render(presence: presence, scale: 1)
      let actual = try XCTUnwrap(NSImage(data: result.png))
      let actualPixels = try pixels(result.png, size: size)
      let halves = try await SceneRasterCompositor.create(size: .init(width: size.x, height: size.y),
        scale: 1, resources: .shared)
      for half in 0..<2 {
        let left = Double(half) * size.x / 2
        let center = presence.camera.screenToWorld(.init(x: left + size.x / 4, y: size.y / 2), viewport: size)
        let portion = SessionPresence(boardID: presence.boardID, mode: .board,
          camera: .init(center: center, scale: scale), viewport: .init(x: size.x / 2, y: size.y))
        let pixels = try await painter.render(presence: portion, scale: 1, transitionViewport: size)
        try await halves.drawPNG(pixels.png, in: .init(x: left, y: 0, width: size.x / 2, height: size.y))
      }
      let expectedPixels = try pixels(try await halves.finishPNG(), size: size)
      let difference = zip(actualPixels, expectedPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
        / Double(actualPixels.count * 255)
      XCTContext.runActivity(named: "Composition \(scale), MAE \(difference)") { activity in
        let attachment = XCTAttachment(image: actual); attachment.name = "Sequential"; attachment.lifetime = .keepAlways; activity.add(attachment)
      }
      XCTAssertLessThan(difference, 0.003, "Independent regions must join without losing layers or shifting pixels: \(difference)")
    }
    await model.finishPendingPersistence()
  }

  @MainActor
  func testOffCenterPortalGridKeepsTheScreenPixelScaleAtHandoff() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    let workspace = try XCTUnwrap(model.workspace)
    let hierarchy = try XCTUnwrap(model.boardHierarchy)
    let portalCamera = try XCTUnwrap(hierarchy.portalCamera(childID))
    for size in [SpatialPoint(x: 834, y: 1194), SpatialPoint(x: 1194, y: 834)] {
      let fill = BoardPortalProjection.fillScale(viewport: size)
      for ratio in [1.2, 1.8] {
        let parent = SpatialCamera(center: .init(x: 24, y: -17), scale: fill * ratio)
        let camera = try XCTUnwrap(BoardPortalProjection.enteringCamera(from: parent,
          portalCamera: portalCamera, portalCenter: .zero, viewport: size))
        let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: model.documents.mapValues(\.paperSize))
        let painter = SceneCompositionRenderer(index: index, hierarchy: hierarchy, journal: try XCTUnwrap(model.spatialInk))
        let first = try pixels(try await painter.render(presence: .init(boardID: workspace.rootBoardID,
          mode: .board, camera: parent, viewport: size), scale: 1).png, size: size)
        let second = try pixels(try await painter.render(presence: .init(boardID: childID,
          mode: .board, camera: camera, viewport: size), scale: 1).png, size: size)
        let difference = zip(first, second).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
          / Double(first.count * 255)
        XCTContext.runActivity(named: "Сетка \(Int(size.x)) × \(Int(size.y)), \(ratio): MAE \(difference)") { activity in
          let attachment = XCTAttachment(string: "normalized_pixel_MAE=\(difference)")
          attachment.lifetime = .keepAlways; activity.add(attachment)
        }
        XCTAssertLessThan(difference, 0.0001,
          "Сетка сохраняет шаг и размер точек в экранных пикселях при передаче вне центра: \(size), \(ratio)")
      }
    }
    await model.finishPendingPersistence()
  }

  @MainActor
  func testIndependentMergeRepublishesPNGWithTheSameHierarchyClock() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let notebookID = try XCTUnwrap(model.workspace?.selectedItemID)
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    let base = try XCTUnwrap(model.boardHierarchy)
    let workspace = try XCTUnwrap(model.workspace)
    var left = base
    var right = base
    let high = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
    let low = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    XCTAssertTrue(left.moveItem(notebookID, in: workspace.rootBoardID, to: WorldPoint(x: 2_000, y: 0), actor: high))
    let element = SpatialElement(id: "arrived", surface: .board(childID), kind: .web,
      frame: SpatialRect(x: 0, y: 0, width: 800, height: 800), worldOrigin: WorldPoint(x: -400, y: -400), source: "<svg>",
      html: "<svg width='800' height='800'><rect width='800' height='800' fill='red'/></svg>",
      stamp: VersionStamp(counter: 0, actor: low))
    XCTAssertTrue(right.upsertElement(element, in: childID, expected: nil, actor: low))
    model.updatePresence(SessionPresence(boardID: workspace.rootBoardID, mode: .board,
      camera: SpatialCamera(scale: 0.6), viewport: SpatialPoint(x: 834, y: 1_194)), settled: true)
    model.receivePeerMessage(.board(left))
    let before = try await receipt(store: store, revision: left.revision)
    model.receivePeerMessage(.board(right))
    await model.finishPendingPersistence()
    let merged = try XCTUnwrap(model.boardHierarchy)
    XCTAssertEqual(merged.stamp, left.stamp)
    XCTAssertNotEqual(merged.revision, left.revision)
    let after = try await receipt(store: store, revision: merged.revision)
    XCTAssertNotEqual(after.pngSHA256, before.pngSHA256)
    XCTAssertNotNil(SceneRenderResources.shared.image(for: agentElementSnapshotSource(element)))
    XCTAssertEqual(after.pngSHA256, SHA256.hash(data: try Data(contentsOf: store.currentViewPreviewURL))
      .map { String(format: "%02x", $0) }.joined())
  }

  @MainActor
  func testMinimumZoomExitAndReentryPersistsTheSameCamera() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    model.start(pageSize: NotebookAppModel.defaultPageSize)
    let childID = try XCTUnwrap(model.createBoard(at: .zero))
    model.enterBoard(childID)
    let camera = SpatialCamera(center: WorldPoint(x: 7_000, y: -4_000), scale: SpatialCamera.minimumScale)
    let viewport = SpatialPoint(x: 1_366, y: 1_024)
    model.updatePresence(SessionPresence(boardID: childID, mode: .board,
      camera: camera, viewport: viewport), settled: true)
    XCTAssertTrue(model.leaveBoard())
    let workspace = try XCTUnwrap(model.workspace)
    await model.finishPendingPersistence()
    let saved = try store.loadBoard(items: workspace.items)
    XCTAssertLessThan(try XCTUnwrap(saved.portalCamera(childID)).scale, SpatialCamera.minimumScale)
    model.enterBoard(childID)
    XCTAssertEqual(model.presence?.camera, camera)
  }

  @MainActor
  private func receipt(store: NotebookStore, revision: String) async throws -> CurrentViewReceipt {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(12)
    while clock.now < deadline {
      if let data = try? Data(contentsOf: store.currentViewRevisionURL),
        let receipt = try? JSONDecoder().decode(CurrentViewReceipt.self, from: data),
        receipt.boardRevision == revision { return receipt }
      try await Task.sleep(for: .milliseconds(30))
    }
    throw NSError(domain: "PortalReceiptTimeout", code: 1)
  }

  @MainActor
  private func pixels(_ png: Data, size: SpatialPoint) throws -> [UInt8] {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
    let image = try XCTUnwrap(bitmap.cgImage)
    XCTAssertEqual(image.width, Int(size.x)); XCTAssertEqual(image.height, Int(size.y))
    var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try result.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return result
  }
}
