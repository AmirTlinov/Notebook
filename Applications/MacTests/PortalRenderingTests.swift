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
    try await AgentElementSnapshotCache.shared.prepare(elements.filter { $0.kind != .nativeText }.map(agentElementSnapshotSource))
    for size in [SpatialPoint(x: 834, y: 1_194), SpatialPoint(x: 1_366, y: 1_024)] {
      let camera = BoardPortalProjection.entryCamera(portalCamera: hierarchy.portalCamera(childID)!, viewport: size)
      let presence = SessionPresence(boardID: childID, mode: .board, camera: camera, viewport: size)
      let fill = BoardPortalProjection.fillScale(viewport: size)
      let portal = BoardPortalPreview(boardID: childID, pixelScale: fill,
        remainingPortalPasses: WorkspaceSceneProjection.portalPasses,
        transitionViewport: size, rendersSettledSnapshot: true)
        .scaleEffect(fill)
        .frame(width: size.x, height: size.y).clipped().environment(model)
      let active = SettledSpatialWorkspaceView(workspace: workspace,
        board: hierarchy.board(childID)!, spatialInk: ink, presence: presence).environment(model)
      let portalPresence = SessionPresence(boardID: childID, mode: .board, camera: camera,
        viewport: BoardPortalProjection.renderViewport(viewport: size))
      let surfaces = WorkspaceSceneProjection.snapshotLayers(workspace: workspace, hierarchy: hierarchy,
        presence: presence, documents: model.documents).ink
        + WorkspaceSceneProjection.snapshotLayers(workspace: workspace, hierarchy: hierarchy,
          presence: portalPresence, documents: model.documents).ink
      let inkRasters = try await SpatialInkRasterSnapshot.prepare(surfaces, journal: ink)
      let first = try pixels(portal.environment(\.spatialInkRasterSnapshot, inkRasters), size: size)
      let second = try pixels(active.environment(\.spatialInkRasterSnapshot, inkRasters), size: size)
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
        let portal = BoardPortalPreview(boardID: childID, pixelScale: parent.scale,
          remainingPortalPasses: WorkspaceSceneProjection.portalPasses,
          transitionViewport: size, rendersSettledSnapshot: true)
          .scaleEffect(parent.scale)
          .frame(width: size.x, height: size.y)
          .offset(x: -24 * parent.scale, y: 17 * parent.scale)
          .frame(width: size.x, height: size.y).clipped().environment(model)
        let active = SettledSpatialWorkspaceView(workspace: workspace,
          board: try XCTUnwrap(hierarchy.board(childID)), spatialInk: try XCTUnwrap(model.spatialInk),
          presence: .init(boardID: childID, mode: .board, camera: camera, viewport: size)).environment(model)
        let first = try pixels(portal, size: size), second = try pixels(active, size: size)
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
    XCTAssertNotNil(AgentElementSnapshotCache.shared.image(for: agentElementSnapshotSource(element)))
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
  private func pixels<V: View>(_ view: V, size: SpatialPoint) throws -> [UInt8] {
    let renderer = ImageRenderer(content: view.frame(width: size.x, height: size.y))
    renderer.proposedSize = ProposedViewSize(width: size.x, height: size.y)
    renderer.scale = 1
    let image = try XCTUnwrap(renderer.cgImage)
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
