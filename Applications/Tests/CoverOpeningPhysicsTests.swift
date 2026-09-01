import CoreGraphics
import NotebookCore
import XCTest

@testable import Notebook

final class CoverOpeningPhysicsTests: XCTestCase {
  func testProgressHasExactAndReversibleEndpoints() {
    XCTAssertEqual(CoverOpeningPhysics.clamped(-0.4), 0)
    XCTAssertEqual(CoverOpeningPhysics.clamped(0), 0)
    XCTAssertEqual(CoverOpeningPhysics.clamped(0.37), 0.37)
    XCTAssertEqual(CoverOpeningPhysics.clamped(1), 1)
    XCTAssertEqual(CoverOpeningPhysics.clamped(1.4), 1)

    XCTAssertTrue(CoverOpeningPhysics.isClosed(0))
    XCTAssertFalse(CoverOpeningPhysics.isClosed(0.01))
    XCTAssertFalse(CoverOpeningPhysics.isOpen(0.99))
    XCTAssertTrue(CoverOpeningPhysics.isOpen(1))
  }

  func testCurlRadiusFollowsThePhysicalSheetWidth() {
    let regular = CoverOpeningPhysics.curlRadius(
      for: CGRect(x: 0, y: 0, width: 834, height: 1_194)
    )
    let doubled = CoverOpeningPhysics.curlRadius(
      for: CGRect(x: 0, y: 0, width: 1_668, height: 2_388)
    )

    XCTAssertEqual(
      regular,
      Float(834 * CoverOpeningPhysics.curlRadiusRatio),
      accuracy: 0.001
    )
    XCTAssertEqual(doubled, regular * 2, accuracy: 0.001)
  }

  func testCurlCanvasCarriesTheCoverOutsideTheNotebookFrame() {
    let sheetSize = CGSize(width: 834, height: 1_194)
    let layout = CoverCurlLayout(sheetSize: sheetSize)

    XCTAssertEqual(layout.sheetFrame.size, sheetSize)
    XCTAssertGreaterThan(
      layout.sheetFrame.minX,
      sheetSize.width,
      "The opening side needs one full cover plus room for its shadow"
    )
    XCTAssertEqual(
      layout.canvasFrameAroundSheet.minX + layout.sheetFrame.minX,
      0,
      accuracy: 0.001
    )
    XCTAssertEqual(
      layout.canvasFrameAroundSheet.minY + layout.sheetFrame.minY,
      0,
      accuracy: 0.001
    )
  }

  func testCurlCanvasKeepsTheSheetFrameExactAtRetinaScale() {
    let layout = CoverCurlLayout(
      sheetSize: CGSize(width: 834, height: 1_194)
    )
    let drawable = CGSize(
      width: layout.canvasSize.width * 2,
      height: layout.canvasSize.height * 2
    )

    XCTAssertEqual(
      layout.sheetExtent(inDrawableSize: drawable),
      CGRect(
        x: layout.sheetFrame.minX * 2,
        y: layout.sheetFrame.minY * 2,
        width: 1_668,
        height: 2_388
      )
    )
  }

  func testOneFrozenCoverSurvivesOpeningAndImmediateReversal() {
    let ownerID = UUID()
    let revision = revision(title: "Cover A")
    let snapshot = snapshot()
    var lifecycle = CoverSnapshotLifecycle()

    lifecycle.update(ownerID: ownerID, progress: 0, revision: revision)
    lifecycle.settleAtClosedEndpoint()
    lifecycle.update(ownerID: ownerID, progress: 0.42, revision: revision)
    lifecycle.storeCapturedCover(snapshot)
    lifecycle.update(ownerID: ownerID, progress: 1, revision: revision)
    lifecycle.settleAtOpenEndpoint()
    lifecycle.update(ownerID: ownerID, progress: 0.58, revision: revision)

    XCTAssertTrue(lifecycle.capturedCover === snapshot)
  }

  func testContentChangeWaitsForAnEndpointBeforeReplacingTheCover() {
    let ownerID = UUID()
    let firstRevision = revision(title: "Cover A")
    let secondRevision = revision(title: "Cover B")
    let snapshot = snapshot()
    var lifecycle = CoverSnapshotLifecycle()

    lifecycle.update(ownerID: ownerID, progress: 0, revision: firstRevision)
    lifecycle.settleAtClosedEndpoint()
    lifecycle.update(ownerID: ownerID, progress: 0.35, revision: firstRevision)
    lifecycle.storeCapturedCover(snapshot)
    lifecycle.update(ownerID: ownerID, progress: 0.7, revision: secondRevision)

    XCTAssertTrue(lifecycle.capturedCover === snapshot)

    lifecycle.update(ownerID: ownerID, progress: 1, revision: secondRevision)
    lifecycle.settleAtOpenEndpoint()
    XCTAssertNil(lifecycle.capturedCover)
  }

  private func revision(title: String) -> CoverRenderingRevision {
    CoverRenderingRevision(
      item: .document(title: title),
      elements: [],
      journal: nil
    )
  }

  private func snapshot() -> CGImage {
    let context = CGContext(
      data: nil,
      width: 2,
      height: 2,
      bitsPerComponent: 8,
      bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
  }
}
