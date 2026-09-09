import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// The complete production scene, including the real cover host, native touch
/// callbacks, SQL command, lightweight index and retained raster cohort.
@MainActor
final class WorkspaceCoverContinuityTests: XCTestCase {
  func testDroppedCoverRetainsItsNativeBodyAndPixelsWhileTheNewIndexWaitsForItsCohort() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cover-continuity-" + UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let (boardID, itemID, delayedElement) = try await Task.detached {
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      let workspace = try store.loadIndex(), before = try store.loadBoard(items: workspace.items)
      var after = before
      let element = SpatialElement(id: "cohort-permit-barrier", surface: .board(header.rootBoardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 64, height: 64), worldOrigin: .init(x: -800, y: -500),
        source: "A finite unrelated raster dependency", html: "<svg width='64' height='64'><rect width='64' height='64' fill='#38624f'/></svg>",
        css: "svg{display:block}", javaScript: "", stamp: .init(counter: 0, actor: actor))
      XCTAssertTrue(after.upsertElement(element, in: header.rootBoardID, expected: nil, actor: actor))
      _ = try store.saveBoardEdits(before: before, after: after)
      return (header.rootBoardID, workspace.selectedItemID,
        try XCTUnwrap(store.readSpatialElement(boardID: header.rootBoardID, elementID: element.id)))
    }.value
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.rootViewController = host
    let viewport = SpatialPoint(x: window.bounds.width, y: window.bounds.height)
    model.updatePresence(.init(boardID: boardID, mode: .board, camera: .init(scale: 0.27),
      viewport: viewport, selectedItemID: itemID), settled: true)
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; model.compositionTiles.cancelPreparation() }
    let resources = SceneRenderResources.shared
    try await waitUntil {
      model.compositionTiles.published != nil && !model.scenePreparationPending
        && !model.inputIsActive && resources.activeBackgroundWebSurfaceCount == 0
        && !self.descendants(host.view, as: NotebookInteractionTouchView.self).isEmpty
    }
    let original = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "No completed initial scene")
    let touchView = try XCTUnwrap(descendants(host.view, as: NotebookInteractionTouchView.self).first)
    let coverController = try XCTUnwrap(controllers(host, as: IPadCoverOpeningController.self).first)
    let inkViews = Set(descendants(coverController.view, as: InkCanvasView.self).map(ObjectIdentifier.init))
    XCTAssertFalse(inkViews.isEmpty)
    XCTAssertTrue(original.plan.allowsLive(.item(itemID), in: .board(boardID)))
    let localSample = CGPoint(x: touchView.bounds.width * 0.72, y: touchView.bounds.height * 0.68)
    let initialSample = touchView.convert(localSample, to: host.view)
    let initialCenter = touchView.convert(CGPoint(x: touchView.bounds.midX, y: touchView.bounds.midY), to: host.view)
    let baseline = try pixelPatch(in: host.view, around: initialSample, name: "cover-before-drop")
    XCTAssertLessThan(baseline.min() ?? 255, 230, "The baseline must contain the actual dyed cover, not blank paper")

    // Hold real shared executor permits, not a timer or a test-only renderer
    // hook. A changed 64px neighbor requires one new raster, while native input,
    // SQLite and the finite index remain free to complete normally.
    var permits: [WebSurfaceLease] = []
    defer { for permit in permits { permit.release() } }
    for _ in 0..<resources.maximumBackgroundWebSurfaces {
      permits.append(try await resources.acquireWebSurface(priority: .background))
    }
    model.commitSpatialElementState(boardID: boardID, rendered: delayedElement, state: .object(["revision": .number(1)]))
    let sourceSaved = await model.finishPendingPersistence()
    XCTAssertTrue(sourceSaved, model.persistenceFailure ?? "The unrelated source must be durable")
    try await waitUntil {
      !model.scenePreparationPending && resources.pendingWebRequestCount > 0
        && model.sceneIndex?.element(id: delayedElement.id, boardID: boardID)?.state == .object(["revision": .number(1)])
    }
    XCTAssertTrue(model.compositionTiles.published === original)
    XCTAssertNil(model.compositionTiles.failure)

    var lifted = false
    let onLift = touchView.onLiftChanged
    touchView.onLiftChanged = { value in lifted = value; onLift(value) }
    let touch = CoverContinuityTouch(window: window)
    touch.point = touchView.convert(CGPoint(x: touchView.bounds.midX, y: touchView.bounds.midY), to: window)
    touchView.touchesBegan([touch], with: nil)
    try await waitUntil { lifted }
    let delta = CGSize(width: 180, height: 35)
    touch.point.x += delta.width; touch.point.y += delta.height
    touchView.touchesMoved([touch], with: nil)
    let previousIndex = model.sceneIndexGeneration
    touchView.touchesEnded([touch], with: nil)
    let accepted = try XCTUnwrap(model.board?.placement(of: itemID))
    XCTAssertEqual(accepted.center.delta(to: .zero).x, -delta.width / 0.27, accuracy: 0.001)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "The drag must use the actual durable placement command")
    try await waitUntil {
      model.sceneIndexGeneration > previousIndex && !model.scenePreparationPending
        && !model.inputIsActive && resources.pendingWebRequestCount > 0
    }
    XCTAssertEqual(model.sceneIndex?.board(id: boardID)?.placement(of: itemID)?.center, accepted.center)
    XCTAssertNotEqual(original.frame.index.board(id: boardID)?.placement(of: itemID)?.center, accepted.center)
    XCTAssertTrue(model.compositionTiles.published === original, "The explicit permit barrier still holds the whole old cohort")
    XCTAssertNil(model.compositionTiles.failure)
    XCTAssertTrue(original.rasters.values.allSatisfy { !$0.isReleased })
    host.view.layoutIfNeeded()
    let observedCenter = touchView.convert(CGPoint(x: touchView.bounds.midX, y: touchView.bounds.midY), to: host.view)
    XCTAssertEqual(observedCenter.x, initialCenter.x + delta.width, accuracy: 0.5,
      "A lightweight index cannot reset the complete moving cover to the previous cohort's placement")
    XCTAssertEqual(observedCenter.y, initialCenter.y + delta.height, accuracy: 0.5)
    XCTAssertTrue(descendants(host.view, as: NotebookInteractionTouchView.self).contains { $0 === touchView })
    XCTAssertTrue(controllers(host, as: IPadCoverOpeningController.self).contains { $0 === coverController },
      "Selection, lift and release must preserve the same physical cover host")
    XCTAssertEqual(Set(descendants(coverController.view, as: InkCanvasView.self).map(ObjectIdentifier.init)), inkViews,
      "The actual installed ink owner is not remounted behind a replacement cover")
    let pendingPixels = try pixelPatch(in: host.view,
      around: .init(x: initialSample.x + delta.width, y: initialSample.y + delta.height), name: "cover-index-before-cohort")
    for channel in 0..<3 {
      XCTAssertEqual(pendingPixels[channel], baseline[channel], accuracy: 12,
        "The entire cover remains painted at its accepted position, not just represented by an ID or counter")
    }

    for permit in permits { permit.release() }; permits.removeAll()
    try await waitUntil { model.compositionTiles.published?.id != original.id && !model.compositionTiles.isPreparing }
    let complete = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "Replacement did not complete")
    XCTAssertEqual(complete.frame.index.board(id: boardID)?.placement(of: itemID)?.center, accepted.center)
    XCTAssertTrue(complete.plan.allowsLive(.item(itemID), in: .board(boardID)), "A held selected owner cannot silently turn into an unrelated tile")
    XCTAssertTrue(controllers(host, as: IPadCoverOpeningController.self).contains { $0 === coverController })
    let finalPixels = try pixelPatch(in: host.view,
      around: .init(x: initialSample.x + delta.width, y: initialSample.y + delta.height), name: "cover-complete-cohort")
    for channel in 0..<3 { XCTAssertEqual(finalPixels[channel], baseline[channel], accuracy: 12) }
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate(), "The addressed scene or native contact did not reach its explicit readiness condition")
  }

  private func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
  }

  private func controllers<T: UIViewController>(_ controller: UIViewController, as type: T.Type) -> [T] {
    (controller as? T).map { [$0] } ?? controller.children.flatMap { controllers($0, as: type) }
  }

  private func pixelPatch(in view: UIView, around point: CGPoint, name: String) throws -> [Double] {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    let cg = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    try bytes.withUnsafeMutableBytes { pixels in
      let context = try XCTUnwrap(CGContext(data: pixels.baseAddress, width: cg.width, height: cg.height,
        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    let x = Int(point.x.rounded()), y = Int(point.y.rounded())
    XCTAssertTrue((5..<(cg.width - 5)).contains(x) && (5..<(cg.height - 5)).contains(y))
    guard (5..<(cg.width - 5)).contains(x), (5..<(cg.height - 5)).contains(y) else { return [255, 255, 255] }
    var sums = [0.0, 0, 0]
    for row in (y - 4)...(y + 4) { for col in (x - 4)...(x + 4) {
      let pixel = (row * cg.width + col) * 4
      for channel in 0..<3 { sums[channel] += Double(bytes[pixel + channel]) }
    }}
    return sums.map { $0 / 81 }
  }
}

@MainActor
private final class CoverContinuityTouch: UITouch {
  var point: CGPoint = .zero
  private weak var referenceWindow: UIWindow?
  init(window: UIWindow) { referenceWindow = window; super.init() }
  override var type: UITouch.TouchType { .direct }
  override var tapCount: Int { 1 }
  override func location(in view: UIView?) -> CGPoint {
    guard let view else { return point }
    return view.convert(point, from: referenceWindow)
  }
  override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
}
