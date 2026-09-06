import CoreGraphics
import MetalKit
import NotebookCore
import SwiftUI
import UIKit
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

  func testRestingShadowHandsSheetLightingToCurl() {
    XCTAssertEqual(CoverOpeningPhysics.restingShadowVisibility(0), 1)
    XCTAssertEqual(
      CoverOpeningPhysics.restingShadowVisibility(
        CoverOpeningPhysics.shadowHandoffProgress / 2
      ),
      0.5,
      accuracy: 0.001
    )
    XCTAssertEqual(
      CoverOpeningPhysics.restingShadowVisibility(
        CoverOpeningPhysics.shadowHandoffProgress
      ),
      0
    )
    XCTAssertEqual(CoverOpeningPhysics.restingShadowVisibility(1), 0)
    XCTAssertEqual(CoverOpeningPhysics.systemShadowSize, 0)
    XCTAssertEqual(CoverOpeningPhysics.systemShadowAmount, 0)
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
    lifecycle.storeCapturedCover(snapshot)
    lifecycle.settleAtClosedEndpoint(keepingPreparedSnapshot: true)
    lifecycle.update(ownerID: ownerID, progress: 0.42, revision: revision)
    XCTAssertTrue(lifecycle.capturedCover === snapshot)
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
    lifecycle.storeCapturedCover(snapshot)
    lifecycle.settleAtClosedEndpoint(keepingPreparedSnapshot: true)
    lifecycle.update(ownerID: ownerID, progress: 0.35, revision: firstRevision)
    lifecycle.update(ownerID: ownerID, progress: 0.7, revision: secondRevision)

    XCTAssertTrue(lifecycle.capturedCover === snapshot)

    lifecycle.update(ownerID: ownerID, progress: 1, revision: secondRevision)
    lifecycle.settleAtOpenEndpoint()
    XCTAssertNil(lifecycle.capturedCover)
  }

  func testClosedCoverKeepsOnlyAnArmedCurrentSnapshot() {
    let ownerID = UUID()
    let firstRevision = revision(title: "Cover A")
    let secondRevision = revision(title: "Cover B")
    let firstSnapshot = snapshot()
    let secondSnapshot = snapshot()
    var lifecycle = CoverSnapshotLifecycle()

    lifecycle.update(ownerID: ownerID, progress: 0, revision: firstRevision)
    lifecycle.storeCapturedCover(firstSnapshot)
    lifecycle.settleAtClosedEndpoint(keepingPreparedSnapshot: true)
    XCTAssertFalse(lifecycle.needsCurrentSnapshot)
    XCTAssertTrue(lifecycle.capturedCover === firstSnapshot)

    lifecycle.update(ownerID: ownerID, progress: 0, revision: secondRevision)
    lifecycle.settleAtClosedEndpoint(keepingPreparedSnapshot: true)
    XCTAssertTrue(lifecycle.needsCurrentSnapshot)
    XCTAssertNil(lifecycle.capturedCover)

    lifecycle.storeCapturedCover(secondSnapshot)
    lifecycle.settleAtClosedEndpoint(keepingPreparedSnapshot: false)
    XCTAssertNil(lifecycle.capturedCover)
  }

  @MainActor
  func testClosingFromAnInitiallyOpenPageKeepsAnOpaqueCover() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
    let controller = IPadCoverOpeningController()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let owner = UUID()
    let coverRevision = revision(title: "Opaque cover")
    func update(_ progress: Double) {
      controller.update(
        ownerID: owner, progress: progress, revision: coverRevision,
        backsideColor: .document, preparesCoverMotion: true, canPrepare: { true }, cornerRadius: 12,
        cover: AnyView(Color.red))
    }
    update(1)
    try await Task.sleep(for: .milliseconds(250))
    update(0.2)
    try await Task.sleep(for: .milliseconds(250))
    let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let proof = XCTAttachment(image: image)
    proof.name = "opaque-cover-after-open-start"
    proof.lifetime = .keepAlways
    add(proof)
    let cg = try XCTUnwrap(image.cgImage)
    var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: cg.width, height: cg.height,
        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let red = stride(from: 0, to: pixels.count, by: 4).filter {
      pixels[$0] > 150 && pixels[$0 + 1] < 100 && pixels[$0 + 2] < 100
    }.count
    XCTAssertGreaterThan(
      Double(red) / Double(cg.width * cg.height), 0.15,
      "Закрывающаяся обложка сохраняет плотный цвет")
  }

  @MainActor
  func testRestingCoverDefersCaptureDuringContactAndReusesItForOpening() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    let gate = NotebookInputGate(), contact = UUID(), owner = UUID()
    func update(_ progress: Double) {
      controller.update(ownerID: owner, progress: progress, revision: revision(title: "Resting"),
        backsideColor: .document, preparesCoverMotion: true,
        canPrepare: { !gate.isActive }, cornerRadius: 12, cover: AnyView(Color.red))
    }
    gate.beginContact(source: contact)
    update(0)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(controller.capturedCoverCount, 0, "Камера не готовит неподвижную обложку")
    gate.endContact(source: contact)
    for _ in 0..<100 where gate.isActive { await Task.yield() }
    XCTAssertFalse(gate.isActive)
    update(0)
    for _ in 0..<100 where controller.capturedCoverCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.capturedCoverCount, 1, "После ввода готовится один снимок")
    gate.beginContact(source: contact)
    update(0)
    update(0.3)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(controller.capturedCoverCount, 1, "Раскрытие использует уже готовую обложку")
    gate.endContact(source: contact)
  }

  @MainActor
  func testQueuedRestingCaptureRechecksContactWithoutAViewUpdate() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    let gate = NotebookInputGate(), contact = UUID()
    controller.update(ownerID: UUID(), progress: 0, revision: revision(title: "Queued"),
      backsideColor: .document, preparesCoverMotion: true,
      canPrepare: { !gate.isActive }, cornerRadius: 12, cover: AnyView(Color.red))
    window.layoutIfNeeded()
    gate.beginContact(source: contact)
    // No controller update: the callback must consult the current input owner.
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(controller.capturedCoverCount, 0)
    gate.endContact(source: contact)
  }

  @MainActor
  func testQueuedCaptureDoesNotPrepareAnAbandonedCandidate() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    let owner = UUID()
    func update(prepares: Bool) {
      controller.update(ownerID: owner, progress: 0, revision: revision(title: "Candidate"),
        backsideColor: .document, preparesCoverMotion: prepares,
        canPrepare: { true }, cornerRadius: 12, cover: AnyView(Color.red))
    }
    update(prepares: true)
    window.layoutIfNeeded()
    update(prepares: false)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(controller.capturedCoverCount, 0, "Устаревшее задание не захватывает новый снимок")
  }

  @MainActor
  func testQueuedWarmFrameRechecksContactAndResumesAfterIt() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    let gate = NotebookInputGate(), contact = UUID(), owner = UUID()
    func update() {
      controller.update(ownerID: owner, progress: 0, revision: revision(title: "Warm frame"),
        backsideColor: .document, preparesCoverMotion: true,
        canPrepare: { !gate.isActive }, cornerRadius: 12, cover: AnyView(Color.red))
    }
    update()
    for _ in 0..<100 where controller.submittedCurlFrameCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(controller.submittedCurlFrameCount, 0)
    let curl = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? MTKView }.first)
    let submitted = controller.submittedCurlFrameCount
    gate.beginContact(source: contact)
    // A frame requested before UIKit delivers the next SwiftUI update is still
    // background preparation, not a visible curl owned by the current pinch.
    curl.delegate?.mtkView(curl, drawableSizeWillChange: curl.drawableSize)
    curl.draw()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(controller.submittedCurlFrameCount, submitted)
    gate.endContact(source: contact)
    for _ in 0..<100 where gate.isActive { await Task.yield() }
    XCTAssertFalse(gate.isActive)
    update()
    for _ in 0..<100 where controller.submittedCurlFrameCount == submitted {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(controller.submittedCurlFrameCount, submitted,
      "Ожидающий кадр возобновляется без нового снимка и без смены прогресса")
    XCTAssertEqual(controller.capturedCoverCount, 1)
  }

  @MainActor
  private func coverWindow() throws -> (UIWindow, IPadCoverOpeningController) {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
    let controller = IPadCoverOpeningController()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    return (window, controller)
  }

  private func revision(title: String) -> CoverRenderingRevision {
    CoverRenderingRevision(
      item: .document(title: title),
      geometry: .document(.a4),
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
