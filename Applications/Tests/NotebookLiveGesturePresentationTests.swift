import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookLiveGesturePresentationTests: XCTestCase {
  func testMountedArtifactAndCornersStayAtBothDropsWhileTheOldCohortIsRetained() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-continuity-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    let pencil = UUID()
    addTeardownBlock { @MainActor in
      model.inputGate.endPencilAction(source: pencil)
      host.rootView = AnyView(EmptyView()); window.isHidden = true; window.rootViewController = nil
      let saved = await model.shutdown(); XCTAssertTrue(saved)
      if saved { try FileManager.default.removeItem(at: root) }
    }
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let initialSave = await model.finishPendingPersistence(); XCTAssertTrue(initialSave)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID)
    let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
    var after = before
    let element = SpatialElement(id: "accepted-artifact", surface: .board(boardID), kind: .web,
      frame: .init(x: 100, y: 200, width: 180, height: 120), worldOrigin: .zero,
      source: "An already mounted artifact", html: "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 180 120'><rect width='180' height='120' fill='#8c1ec8'/></svg>",
      css: "html,body,svg{margin:0;width:100%;height:100%;display:block}", stamp: .init(counter: 0, actor: model.actorID))
    XCTAssertTrue(after.upsertElement(element, in: boardID, expected: nil, actor: model.actorID))
    _ = try model.store.saveBoardEdits(before: before, after: after)
    await model.reloadExternalChanges()?.value
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    let presence = SessionPresence(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 417, y: 597), scale: 1), viewport: .init(x: 834, y: 1194))
    model.updatePresence(presence, settled: true)
    host.rootView = AnyView(SpatialWorkspaceView().environment(model).environment(\.displayScale, 2).ignoresSafeArea())
    window.rootViewController = host; window.makeKeyAndVisible()
    try await waitUntil {
      model.compositionTiles.published?.plan.allowsLive(.element(element.id), in: .board(boardID)) == true
        && !model.scenePreparationPending && !model.inputIsActive
        && SceneRenderResources.shared.image(for: agentElementSnapshotSource(element)) != nil
    }
    let original = try XCTUnwrap(model.compositionTiles.published)
    let pixels = try XCTUnwrap(SceneRenderResources.shared.image(for: agentElementSnapshotSource(element))?.cgImage)
    try await waitUntil { self.raster(in: host.view, image: pixels) != nil }
    let body = try XCTUnwrap(raster(in: host.view, image: pixels))
    let recognizer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? SceneSelectionRecognizer }.first)
    let observer = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? NotebookContactObserver }.first)
    let reference = EditableElementReference.spatial(boardID: boardID, elementID: element.id)
    let initialInk = model.spatialInk
    var expected = CGRect(x: 100, y: 200, width: 180, height: 120)
    assertFrame(body.convert(body.bounds, to: host.view), equals: expected)
    let baseline = try pixelPatch(in: host.view, at: .init(x: expected.midX, y: expected.midY), name: "artifact-before-drag")
    XCTAssertGreaterThan(baseline[0], 100); XCTAssertLessThan(baseline[1], 70); XCTAssertGreaterThan(baseline[2], 160)

    for (index, delta) in [CGSize(width: 120, height: 60), CGSize(width: 140, height: 50)].enumerated() {
      // Deliver the same native contact to its installed lifetime observer and
      // selection recognizer. Neither a new fixture host nor a model-only
      // projection supplies the pixels inspected below.
      // A window-mounted recognizer resets through UIKit's event cycle. Do
      // not send another synthetic down while a queued reset can erase it.
      // The previous Pencil barrier still retains the same old cohort here.
      try await waitUntil(diagnostic: {
        "UIKit has not finished the preceding contact: selection \(recognizer.state.rawValue), observer \(observer.state.rawValue)"
      }) { recognizer.state == .possible && observer.state == .possible }
      model.inputGate.endPencilAction(source: pencil)
      let touch = LiveArtifactTouch(window: window)
      touch.point = host.view.convert(.init(x: expected.midX, y: expected.midY), to: window)
      let nativePoint = touch.location(in: recognizer.coordinateView)
      let sourceIsInstalled = window.gestureRecognizers?.contains { $0 === recognizer } == true
      XCTAssertTrue(sourceIsInstalled, "The physical selection recognizer must not be replaced between drops")
      XCTAssertEqual(recognizer.state, .possible, "The synthetic contact starts after UIKit reset, drop \(index + 1)")
      XCTAssertNotNil(recognizer.onLift?(nativePoint),
        "The installed point route must resolve the shown artifact, drop \(index + 1), point \(nativePoint), body \(body.convert(body.bounds, to: host.view)), selection \(String(describing: model.selectionSession.target)), error \(model.agentRequestError ?? "none")")
      observer.touchesBegan([touch], with: UIEvent())
      recognizer.touchesBegan([touch], with: UIEvent())
      try await waitUntil(diagnostic: {
        "Hold \(index + 1) was not accepted; recognizer \(recognizer.state.rawValue), enabled \(recognizer.isEnabled), installed \(window.gestureRecognizers?.contains { $0 === recognizer } == true), anchor \(String(describing: recognizer.coordinateView?.bounds)), point \(nativePoint), admission \(model.inputGate.permitsNewContact), Pencil \(model.inputGate.hasActivePencil), selection \(String(describing: model.selectionSession.target)), manipulation \(String(describing: model.selectionSession.manipulation?.reference)), error \(model.agentRequestError ?? "none")"
      }) { model.selectionSession.manipulation?.reference == reference }
      touch.point.x += delta.width; touch.point.y += delta.height
      recognizer.touchesMoved([touch], with: UIEvent())
      recognizer.touchesEnded([touch], with: UIEvent())
      observer.touchesEnded([touch], with: UIEvent())
      // A real input barrier prevents the asynchronous composition from
      // rescuing a lost drop. This does not fabricate a replacement cohort.
      XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
      expected = expected.offsetBy(dx: delta.width, dy: delta.height)
      XCTAssertNil(model.selectionSession.manipulation)
      XCTAssertEqual(model.boardHierarchy?.board(boardID)?.elements.first { $0.id == element.id }?.frame,
        .init(x: expected.minX, y: expected.minY, width: expected.width, height: expected.height))
      try await waitUntil {
        host.view.layoutIfNeeded()
        return self.framesEqual(body.convert(body.bounds, to: host.view), expected)
      }
      XCTAssertTrue(model.compositionTiles.published === original, "The whole old cohort remains held at this sample")
      XCTAssertTrue(raster(in: host.view, image: pixels) === body, "The same admitted native body follows the accepted edit")
      try assertCornerFrame(in: host.view, expected: expected)
      let shown = try pixelPatch(in: host.view, at: .init(x: expected.midX, y: expected.midY), name: "artifact-after-drop-\(index + 1)-old-cohort")
      for channel in 0..<3 { XCTAssertEqual(shown[channel], baseline[channel], accuracy: 12) }
      XCTAssertEqual(model.presence?.camera, presence.camera)
      XCTAssertEqual(model.spatialInk, initialInk)
    }

    model.inputGate.endPencilAction(source: pencil)
    let resize = try XCTUnwrap(model.beginElementManipulation(reference, kind: .resize(.topLeading)))
    XCTAssertTrue(model.finishElementManipulation(resize, translation: .init(x: -40, y: -30)))
    XCTAssertTrue(model.inputGate.beginPencilAction(source: pencil))
    expected = .init(x: expected.minX - 40, y: expected.minY - 30, width: expected.width + 40, height: expected.height + 30)
    try await waitUntil {
      host.view.layoutIfNeeded()
      return self.framesEqual(body.convert(body.bounds, to: host.view), expected)
    }
    XCTAssertTrue(model.compositionTiles.published === original)
    try assertCornerFrame(in: host.view, expected: expected)
    let resized = try pixelPatch(in: host.view, at: .init(x: expected.minX + 30, y: expected.minY + 30), name: "artifact-resized-old-cohort")
    for channel in 0..<3 { XCTAssertEqual(resized[channel], baseline[channel], accuracy: 12) }
    model.inputGate.endPencilAction(source: pencil)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    XCTAssertEqual(try model.store.readSpatialElement(boardID: boardID, elementID: element.id)?.frame,
      .init(x: expected.minX, y: expected.minY, width: expected.width, height: expected.height))
  }

  private func assertCornerFrame(in view: UIView, expected: CGRect) throws {
    let controls = try XCTUnwrap(descendants(view, as: NotebookElementControlsView.self).first)
    let corners = (controls.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
    XCTAssertEqual(corners.count, 4)
    for corner in NotebookElementCorner.allCases {
      let accessibility = try XCTUnwrap(corners.first { $0.accessibilityIdentifier == "resize-agent-element-" + corner.rawValue })
      let region = accessibility.accessibilityFrameInContainerSpace
      let center = controls.convert(CGPoint(x: region.midX, y: region.midY), to: view)
      let expectedPoint = corner.point(in: expected)
      XCTAssertEqual(center.x, expectedPoint.x, accuracy: 0.5)
      XCTAssertEqual(center.y, expectedPoint.y, accuracy: 0.5)
    }
  }

  private func raster(in view: UIView, image: CGImage) -> AgentSnapshotRasterView? {
    descendants(view, as: AgentSnapshotRasterView.self).first { ($0.layer.contents as AnyObject?) === image }
  }

  private func descendants<T: UIView>(_ view: UIView, as type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
  }

  private func framesEqual(_ actual: CGRect, _ expected: CGRect) -> Bool {
    abs(actual.minX - expected.minX) < 0.5 && abs(actual.minY - expected.minY) < 0.5
      && abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5
  }

  private func assertFrame(_ actual: CGRect, equals expected: CGRect) {
    XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5); XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5)
    XCTAssertEqual(actual.width, expected.width, accuracy: 0.5); XCTAssertEqual(actual.height, expected.height, accuracy: 0.5)
  }

  private func waitUntil(diagnostic: () -> String = { "The admitted native artifact did not present its accepted frame" },
    _ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate(), diagnostic(), file: file, line: line)
    guard predicate() else { throw CocoaError(.featureUnsupported) }
  }

  private func pixelPatch(in view: UIView, at point: CGPoint, name: String) throws -> [Double] {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    let cg = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let x = Int(point.x.rounded()), y = Int(point.y.rounded())
    guard (5..<(cg.width - 5)).contains(x), (5..<(cg.height - 5)).contains(y) else { throw CocoaError(.coderInvalidValue) }
    var sums = [0.0, 0, 0]
    for row in (y - 4)...(y + 4) { for column in (x - 4)...(x + 4) {
      let offset = row * context.bytesPerRow + column * 4
      for channel in 0..<3 { sums[channel] += Double(bytes[offset + channel]) }
    }}
    return sums.map { $0 / 81 }
  }
}

@MainActor
private final class LiveArtifactTouch: UITouch {
  weak var sourceWindow: UIWindow?
  var point = CGPoint.zero
  init(window: UIWindow) { sourceWindow = window; super.init() }
  override var type: UITouch.TouchType { .direct }
  override var tapCount: Int { 1 }
  override func location(in view: UIView?) -> CGPoint {
    guard let view, let sourceWindow else { return point }; return view.convert(point, from: sourceWindow)
  }
}
