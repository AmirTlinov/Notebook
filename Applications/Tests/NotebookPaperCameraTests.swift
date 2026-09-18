import NotebookCore
import UIKit
import XCTest
@testable import Notebook

/// The application's mounted camera owner receives the measured gesture. UI
/// tests separately exercise the hardware recognizers on the physical iPad.
@MainActor
final class NotebookPaperCameraTests: XCTestCase {
  func testOpenNotebookKeepsAnchoredZoomAndPanAfterRelease() async throws {
    try await checkPaperCamera(document: false)
  }

  func testOpenDocumentKeepsAnchoredZoomAndPanAfterRelease() async throws {
    try await checkPaperCamera(document: true)
  }

  private func checkPaperCamera(document: Bool) async throws {
    let (model, window) = try await scene(document: document)
    let start = try XCTUnwrap(model.presence)
    let pair = CGPoint(x: start.viewport.x * 0.4, y: start.viewport.y * 0.43)
    let moved = CGPoint(x: pair.x + 42, y: pair.y + 27)
    let owner = try coordinator(in: window)
    owner.onCamera(.began(centroid: pair))
    for scale in [CGFloat(0.96), 1.4, 0.015, 4, 0.15, 1.1] {
      owner.onCamera(.changed(scale: scale, velocity: 0.2, elapsed: 0.2, centroid: moved))
      try await Task.sleep(for: .milliseconds(35))
      let actual = try XCTUnwrap(model.presence)
      XCTAssertEqual(actual.mode, start.mode, "An ordinary paper gesture cannot become a cover gesture")
      XCTAssertEqual(actual.openProgress, 1)
      XCTAssertEqual(actual.focusedItemID, start.focusedItemID)
      XCTAssertEqual(actual.notebookPageID, start.notebookPageID)
      XCTAssertEqual(actual.selectedItemID, start.selectedItemID)
      assertCamera(actual.camera, equals: start.camera.pinched(by: scale,
        from: .init(x: pair.x, y: pair.y), to: .init(x: moved.x, y: moved.y), viewport: start.viewport))
    }
    owner.onCamera(.ended(scale: 1.1, velocity: -0.2, elapsed: 0.3, centroid: moved))
    try await Task.sleep(for: .milliseconds(450))
    let released = try XCTUnwrap(model.presence)
    XCTAssertEqual(released.mode, start.mode)
    XCTAssertEqual(released.openProgress, 1)
    assertCamera(released.camera, equals: start.camera.pinched(by: 1.1,
      from: .init(x: pair.x, y: pair.y), to: .init(x: moved.x, y: moved.y), viewport: start.viewport))
    XCTAssertFalse(owner.defersHorizontalMotionToPageTurn, "Zoomed paper owns two-finger panning, not a curl")

    let panEnd = CGPoint(x: moved.x + 90, y: moved.y + 12)
    owner.onCamera(.began(centroid: moved))
    owner.onCamera(.changed(scale: 1, velocity: 0, elapsed: 0.2, centroid: panEnd))
    owner.onCamera(.ended(scale: 1, velocity: 0, elapsed: 0.3, centroid: panEnd))
    try await Task.sleep(for: .milliseconds(100))
    let panned = try XCTUnwrap(model.presence)
    XCTAssertEqual(panned.mode, start.mode)
    XCTAssertEqual(panned.documentPageIndex, start.documentPageIndex)
    assertCamera(panned.camera, equals: released.camera.pinched(by: 1,
      from: .init(x: moved.x, y: moved.y), to: .init(x: panEnd.x, y: panEnd.y), viewport: start.viewport))
  }

  func testBoardZoomCannotAcquireNotebookContentEvenOnALargeFirstSample() async throws {
    let (model, window) = try await scene(document: false, startsOnBoard: true)
    let start = try XCTUnwrap(model.presence)
    let pair = CGPoint(x: start.viewport.x / 2, y: start.viewport.y / 2)
    let owner = try coordinator(in: window)
    owner.onCamera(.began(centroid: pair))
    for factor: CGFloat in [1.2, 4, 0.01, 2] {
      owner.onCamera(.changed(scale: factor, velocity: 2, elapsed: 0.2, centroid: pair))
      let actual = try XCTUnwrap(model.presence)
      XCTAssertEqual(actual.mode, .board)
      XCTAssertNil(actual.focusedItemID)
      XCTAssertEqual(actual.openProgress, 0)
      assertCamera(actual.camera, equals: start.camera.pinched(by: factor,
        from: .init(x: pair.x, y: pair.y), to: .init(x: pair.x, y: pair.y), viewport: start.viewport))
    }
    owner.onCamera(.ended(scale: 2, velocity: 2, elapsed: 0.3, centroid: pair))
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(model.presence?.mode, .board)
    XCTAssertEqual(model.presence?.openProgress, 0)
  }

  func testSeparateZoomReversalAndCancellationKeepThePageOwner() async throws {
    let (model, window) = try await scene(document: false)
    let start = try XCTUnwrap(model.presence)
    let owner = try coordinator(in: window)
    let pair = CGPoint(x: start.viewport.x / 2, y: start.viewport.y / 2)
    for factor: CGFloat in [0.1, 10, 0.25, 4] {
      owner.onCamera(.began(centroid: pair))
      owner.onCamera(.changed(scale: factor, velocity: 1, elapsed: 0.2, centroid: pair))
      owner.onCamera(.ended(scale: factor, velocity: 1, elapsed: 0.3, centroid: pair))
      try await Task.sleep(for: .milliseconds(40))
      XCTAssertEqual(model.presence?.mode, .page)
      XCTAssertEqual(model.presence?.openProgress, 1)
      XCTAssertEqual(model.presence?.notebookPageID, start.notebookPageID)
    }
    let beforeCancel = try XCTUnwrap(model.presence)
    owner.onCamera(.began(centroid: pair))
    owner.onCamera(.changed(scale: 0.01, velocity: -2, elapsed: 0.2, centroid: pair))
    owner.onCamera(.cancelled)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(model.presence?.mode, .page)
    XCTAssertEqual(model.presence?.openProgress, 1)
    XCTAssertEqual(model.presence?.notebookPageID, start.notebookPageID)
    assertCamera(try XCTUnwrap(model.presence).camera, equals: beforeCancel.camera)
  }

  private func scene(document: Bool, startsOnBoard: Bool = false) async throws -> (NotebookAppModel, UIWindow) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paper-camera-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let item = try XCTUnwrap(document ? model.createDocument(at: .zero, paperSize: .a4) : model.workspace?.selectedItemID)
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved)
    let board = try XCTUnwrap(model.workspace?.rootBoardID)
    let center = try XCTUnwrap(model.boardHierarchy?.focusedCenter(of: item, in: board))
    let nativeScene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let size = nativeScene.effectiveGeometry.coordinateSpace.bounds.size
    let viewport = SpatialPoint(x: size.width, y: size.height)
    let fit = model.itemGeometry(item).fitScale(viewport: viewport)
    model.updatePresence(.init(boardID: board, mode: startsOnBoard ? .board : document ? .document : .page,
      camera: .init(center: center, scale: fit * (startsOnBoard ? 0.35 : 1)), viewport: viewport,
      focusedItemID: startsOnBoard ? nil : item, openProgress: startsOnBoard ? 0 : 1), settled: true)
    return (model, try await mountNotebookScene(model))
  }

  private func coordinator(in window: UIWindow) throws -> WorkspaceGestureLayer.Coordinator {
    try XCTUnwrap(window.gestureRecognizers?.compactMap { $0.delegate as? WorkspaceGestureLayer.Coordinator }.first)
  }

  private func assertCamera(_ actual: SpatialCamera, equals expected: SpatialCamera,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.scale, expected.scale, accuracy: 1e-10, file: file, line: line)
    let delta = expected.center.delta(to: actual.center)
    XCTAssertEqual(delta.x, 0, accuracy: 1e-8, file: file, line: line)
    XCTAssertEqual(delta.y, 0, accuracy: 1e-8, file: file, line: line)
  }
}
