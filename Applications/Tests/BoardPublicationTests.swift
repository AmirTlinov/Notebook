import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class BoardPublicationTests: XCTestCase {
  func testReadInkRevisionCannotAcknowledgeAnUnpresentedNativeCanvas() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194))
    model.updatePresence(presence, settled: true)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let target = CollaborationTarget(kind: .board, id: boardID)
    let action = try model.store.applyCollaborationAction(.init(summary: "Показать линию",
      expected: [.init(target: target, revision: try XCTUnwrap(model.board).stamp.revision,
        inkRevision: try XCTUnwrap(model.spatialInk).stamp.revision)], operations: [
        .init(kind: .appendInkStroke, target: target, id: UUID().uuidString, values: [
          "worldOrigin": try .encode(WorldPoint.zero), "points": .array([
            .object(["x": .number(0), "y": .number(0)]), .object(["x": .number(100), "y": .number(0)])])])]), actor: UUID())
    await model.reloadExternalChanges()?.value
    try await waitUntil { !model.scenePreparationPending }
    await model.refreshCollaborationDetails()
    XCTAssertTrue(model.collaborationDetailsAreCurrent)
    let scene = try XCTUnwrap(model.sceneIndex).workset(presence: presence)
    model.confirmVisibleActions(presence: presence, scene: scene)
    let recorded = await model.finishPendingPersistence(); XCTAssertTrue(recorded)
    XCTAssertFalse(try XCTUnwrap(model.store.deviceActionReceipts().first { $0.id == action.id }).displayComplete,
      "A matching model/index and delivery receipt are not a native frame")
  }

  func testChangedSQLCutRefreshesTheMountedBoardWithoutCameraOrNavigation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    addTeardownBlock { @MainActor in
      host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil
      let saved = await model.shutdown(); XCTAssertTrue(saved)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 417, y: 597), scale: 1), viewport: .init(x: 834, y: 1194))
    model.updatePresence(presence, settled: true)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).environment(\.displayScale, 2).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    try await waitUntil { model.compositionTiles.published != nil }
    let old = try XCTUnwrap(model.compositionTiles.published)
    let oldPresence = try XCTUnwrap(model.presence)
    let target = CollaborationTarget(kind: .board, id: boardID), strokeID = UUID()
    let action = try model.store.applyCollaborationAction(.init(summary: "Линия агента",
      expected: [.init(target: target, revision: try XCTUnwrap(model.board).stamp.revision,
        inkRevision: try XCTUnwrap(model.spatialInk).stamp.revision)], operations: [
        .init(kind: .appendInkStroke, target: target, id: strokeID.uuidString, values: [
          "worldOrigin": try .encode(WorldPoint.zero), "width": .number(16),
          "points": .array([.object(["x": .number(100), "y": .number(200)]),
            .object(["x": .number(700), "y": .number(200)])])])]), actor: UUID())
    await model.reloadExternalChanges()?.value
    // A real later durable write invalidates the read cut before its next
    // raster. No navigation or periodic reload is allowed to rescue the scene.
    let cut = try model.store.currentChangeCursor()
    try model.store.saveDeviceActionReceipt(.init(id: UUID(), deviceID: model.actorID))
    XCTAssertGreaterThan(try model.store.currentChangeCursor(), cut)
    try await waitUntil {
      (try? model.compositionTiles.surfaceRegistry.installedSource(on: .board(boardID))?.referenceInk()
        .actions.contains { $0.id == strokeID && $0.isActive }) == true
    }
    XCTAssertFalse(model.compositionTiles.published === old)
    XCTAssertEqual(model.presence?.camera, oldPresence.camera)
    XCTAssertNil(model.compositionTiles.failure)
    XCTAssertEqual(model.collaborationActions.first?.id, action.id)
    let canvas = try XCTUnwrap(model.compositionTiles.surfaceRegistry.canvas(for: .board(boardID)))
    try await waitUntil { canvas.isStableFramePresented && canvas.window === window }
    let before = try inkPixels(host.view, attachment: "agent-ink-without-navigation")
    XCTAssertGreaterThan(before, 1000, "The received line must be visible, not merely installed in a source record")
    await model.refreshCollaborationDetails()
    model.confirmVisibleActions(presence: try XCTUnwrap(model.presence),
      scene: try XCTUnwrap(model.compositionTiles.published).frame.workset(boardID: boardID))
    let confirmed = await model.finishPendingPersistence(); XCTAssertTrue(confirmed)
    XCTAssertTrue(try XCTUnwrap(model.store.deviceActionReceipts().first { $0.id == action.id }).displayComplete)
    model.selectEraserWidth(40)
    // Let SwiftUI install the selected tool before the native Pencil arrives.
    try await Task.sleep(for: .milliseconds(50))
    let pencil = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SpatialPencilGestureRecognizer }.first)
    let touch = PublicationPencilTouch(window: window), event = UIEvent()
    touch.point = .init(x: 80, y: 200); pencil.touchesBegan([touch], with: event)
    XCTAssertTrue(model.inputGate.hasActivePencil)
    for x in stride(from: 100, through: 720, by: 20) {
      touch.point = .init(x: x, y: 200); touch.sampleTime += 0.02
      pencil.touchesMoved([touch], with: event)
    }
    pencil.touchesEnded([touch], with: event)
    let eraser = try XCTUnwrap(model.spatialInk?.actions.last)
    XCTAssertEqual(eraser.tool, .eraser)
    let erased = await model.finishPendingPersistence(); XCTAssertTrue(erased)
    try await waitUntil { canvas.isStableFramePresented && ((try? self.inkPixels(host.view)) ?? before) < before / 10 }
    _ = try inkPixels(host.view, attachment: "native-pencil-erasure")
    XCTAssertTrue(try model.store.readSpatialInk(surfaces: [.board(boardID)]).actions.contains { $0.id == eraser.id && $0.isActive })
    host.rootView = AnyView(EmptyView())
    let stopped = await model.shutdown(); XCTAssertTrue(stopped)
    let cold = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    addTeardownBlock { @MainActor in let saved = await cold.shutdown(); XCTAssertTrue(saved) }
    await cold.start(pageSize: NotebookAppModel.defaultPageSize)
    host.rootView = AnyView(SpatialWorkspaceView().environment(cold).environment(\.displayScale, 2).ignoresSafeArea())
    try await waitUntil { cold.compositionTiles.published != nil }
    let coldCanvas = try XCTUnwrap(cold.compositionTiles.surfaceRegistry.canvas(for: .board(boardID)))
    try await waitUntil { coldCanvas.isStableFramePresented && coldCanvas.window === window }
    XCTAssertEqual(Set(try XCTUnwrap(coldCanvas.installedSpatialSource).referenceInk().actions.filter(\.isActive).map(\.id)),
      [strokeID, eraser.id], "The cold canvas contains both the original line and the later eraser")
    XCTAssertLessThan(try inkPixels(host.view, attachment: "erasure-after-cold-start"), before / 10,
      "Erased pixels cannot return after cold reading the durable source")
    XCTAssertEqual(cold.presence?.camera, oldPresence.camera)
  }

  private func inkPixels(_ view: UIView, attachment name: String? = nil) throws -> Int {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
      UIColor.white.setFill(); context.fill(view.bounds)
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    if let name {
      let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    let cg = try XCTUnwrap(image.cgImage)
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
    var count = 0
    for y in 170..<230 { for x in 90..<710 {
      let offset = y * bitmap.bytesPerRow + x * 4
      if bytes[offset] < 90 && bytes[offset + 1] < 90 && bytes[offset + 2] < 90 { count += 1 }
    } }
    return count
  }

  private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate(), "The mounted board did not publish its current source", file: file, line: line)
    guard predicate() else { throw CocoaError(.featureUnsupported) }
  }
}

@MainActor
private final class PublicationPencilTouch: UITouch {
  weak var sourceWindow: UIWindow?
  var point = CGPoint.zero
  var sampleTime: TimeInterval = 1
  init(window: UIWindow) { sourceWindow = window; super.init() }
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func preciseLocation(in view: UIView?) -> CGPoint {
    guard let view, let sourceWindow else { return point }; return view.convert(point, from: sourceWindow)
  }
  override func location(in view: UIView?) -> CGPoint { preciseLocation(in: view) }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
