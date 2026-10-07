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
    let layout = SheetCurlLayout(sheetSize: sheetSize)

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
    let layout = SheetCurlLayout(
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
    XCTAssertEqual(lifecycle.lastSettledEndpoint, .open)
    lifecycle.update(ownerID: ownerID, progress: 0, revision: revision)
    lifecycle.update(ownerID: ownerID, progress: 0.4, revision: revision)
    XCTAssertEqual(lifecycle.lastSettledEndpoint, .closed)
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
    PageTurnFrameFixture.install(on: controller)
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
    XCTAssertEqual(controller.capturedCoverCount, 0, "An initially open page has no background cover snapshot demand")
    XCTAssertEqual(controller.submittedCurlFrameCount, 0,
      "Preparing the mounted cover program does not consume screen drawables")
    let curl = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let liveCover = try XCTUnwrap(controller.view.subviews.first { !($0 is SheetCurlMetalView) })
    var firstFrame: SheetCurlMetalView.FrameTiming?, readyProgress: Double?
    var materialBegan: TimeInterval?, materialReady: TimeInterval?, programReady: TimeInterval?
    let prepareMaterial = try XCTUnwrap(controller.prepareMaterial)
    controller.prepareMaterial = { owner, revision, scale in
      materialBegan = CACurrentMediaTime()
      defer { materialReady = CACurrentMediaTime() }
      return try await prepareMaterial(owner, revision, scale)
    }
    let renderingReady = curl.onCoverRenderingReady
    curl.onCoverRenderingReady = { programReady = CACurrentMediaTime(); renderingReady?() }
    curl.onFrameMeasured = { if firstFrame == nil { firstFrame = $0 } }
    curl.onCoverFrameReady = { _, progress, _, readiness in if readiness.isReady { readyProgress = progress } }
    defer {
      controller.prepareMaterial = prepareMaterial; curl.onCoverRenderingReady = renderingReady
      curl.onFrameMeasured = nil; curl.onCoverFrameReady = nil
    }
    let programWasReady = SheetCurlGPU.shared.preparedCoverContext != nil
    XCTAssertTrue(programWasReady,
      "The armed mounted cover prepares its shared program before the first closing gesture")
    let closing = CACurrentMediaTime()
    update(0.7)
    XCTAssertEqual(controller.capturedCoverCount, 0)
    XCTAssertTrue(curl.isHidden)
    XCTAssertEqual(Float(liveCover.alpha), Float(CoverOpeningPhysics.warmCoverOpacity),
      "The pending first curl preserves the open page, not a complete opaque cover")
    // A newer camera pose arrives while capture is pending; the first curl
    // must use it without restarting the accepted closing operation.
    update(0.2)
    let deadline = ContinuousClock.now + .seconds(1)
    while (firstFrame == nil || readyProgress == nil), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let timing = try XCTUnwrap(firstFrame)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(materialBegan), closing,
      "Current cover material belongs to foreground closing, not idle program preparation")
    let acquisition = try XCTUnwrap(timing.drawableAcquisition,
      "A cover submission must consume the completed physical drawable request")
    let clocks: [String: TimeInterval?] = [
      "closing": closing, "materialBegan": materialBegan, "materialReady": materialReady,
      "programReadyMainActor": programReady, "drawableRequested": acquisition.requested,
      "workerBegan": acquisition.workerBegan, "nextDrawableBegan": acquisition.nextDrawableBegan,
      "nextDrawableReturned": acquisition.nextDrawableReturned, "acquisitionDrained": acquisition.drained,
      "acquisitionMainActorDelivery": acquisition.mainActorDeliveryBeforeTake, "drawableTaken": acquisition.taken,
      "encodingBegan": timing.encodingBegan, "submitted": timing.submitted,
      "scheduled": timing.scheduled, "gpuBegan": timing.gpuBegan, "gpuEnded": timing.gpuEnded
    ]
    let trace = clocks.keys.sorted().map { key in
      "\(key)=\(clocks[key]!.map { String($0) } ?? "none")"
    }.joined(separator: "\n")
    let clockProof = XCTAttachment(string: "programWasReady=\(programWasReady)\n\(trace)")
    clockProof.name = "cold-cover-hardware-clocks"; clockProof.lifetime = .keepAlways; add(clockProof)
    XCTAssertLessThanOrEqual(acquisition.nextDrawableBegan, acquisition.nextDrawableReturned)
    XCTAssertLessThanOrEqual(acquisition.nextDrawableReturned, acquisition.taken)
    XCTAssertLessThanOrEqual(acquisition.taken, timing.encodingBegan)
    XCTAssertLessThanOrEqual((timing.submitted - closing) * 1_000, 100,
      "First cold-closing GPU submission includes foreground capture, not OS presentation or photons")
    XCTAssertEqual(try XCTUnwrap(readyProgress), 0.2)
    XCTAssertEqual(controller.capturedCoverCount, 1)
    XCTAssertTrue(liveCover.isHidden, "The opaque result below must belong to the actual curl")
    XCTAssertFalse(curl.isHidden)
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
  func testFullyOpenCoverRejectsQueuedAndChangedBackgroundSnapshots() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    let owner = UUID()
    func update(_ progress: Double, title: String) {
      controller.update(ownerID: owner, progress: progress, revision: revision(title: title),
        backsideColor: .document, preparesCoverMotion: true,
        canPrepare: { true }, cornerRadius: 12, cover: AnyView(Color.red))
    }
    update(0, title: "Before opening")
    window.layoutIfNeeded()
    update(1, title: "Before opening")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(controller.capturedCoverCount, 0, "A queued closed-cover preparation cannot capture behind open paper")
    update(1, title: "Changed while open")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(controller.capturedCoverCount, 0, "Changed hidden cover pixels wait for an actual closing demand")
    update(0.2, title: "Changed while open")
    XCTAssertEqual(controller.capturedCoverCount, 0)
    let curl = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let liveCover = try XCTUnwrap(controller.view.subviews.first { !($0 is SheetCurlMetalView) })
    XCTAssertTrue(curl.isHidden)
    XCTAssertEqual(Float(liveCover.alpha), Float(CoverOpeningPhysics.warmCoverOpacity),
      "Pending closing keeps the open endpoint rather than flashing a complete opaque cover")
    for _ in 0..<100 where controller.submittedCurlFrameCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(controller.submittedCurlFrameCount, 0)
    XCTAssertEqual(controller.capturedCoverCount, 1)
    update(1, title: "Changed while open")
    update(0.4, title: "Changed while open")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(controller.capturedCoverCount, 1, "A valid frozen cover still survives immediate reversal")
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
  func testRestingSnapshotsDoNotConsumeScreenDrawablesBeforeTheRealCurl() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    let gate = NotebookInputGate(), contact = UUID(), owner = UUID()
    func update(_ progress: Double) {
      controller.update(ownerID: owner, progress: progress, revision: revision(title: "Ready snapshot"),
        backsideColor: .document, preparesCoverMotion: true,
        canPrepare: { !gate.isActive }, cornerRadius: 12, cover: AnyView(Color.red))
    }
    update(0)
    for _ in 0..<100 where controller.capturedCoverCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.capturedCoverCount, 1)
    let curl = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? MTKView }.first)
    curl.delegate?.mtkView(curl, drawableSizeWillChange: curl.drawableSize)
    curl.draw()
    update(1); curl.draw()
    XCTAssertEqual(controller.submittedCurlFrameCount, 0,
      "Neither resting endpoint needs an invisible screen drawable")
    gate.beginContact(source: contact)
    update(0.35)
    for _ in 0..<100 where controller.submittedCurlFrameCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(controller.submittedCurlFrameCount, 0,
      "The actual camera-owned curl renders during its accepted contact")
    XCTAssertEqual(controller.capturedCoverCount, 1)
    gate.endContact(source: contact)
  }

  @MainActor
  func testCoverViewDestructionKeepsOutputCreditUntilGPUFence() async throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let resources = SceneRenderResources(byteLimit: 4_096, profile: .interactive)
    let lease = try XCTUnwrap(resources.reserveDerivedBytes(4_096, priority: .input))
    weak var retiredView: SheetCurlMetalView?
    autoreleasepool {
      let view = SheetCurlMetalView(frame: .zero, device: device)
      view.frameLease = lease
      retiredView = view
    }
    XCTAssertNil(retiredView, "Physical retirement must not retain the unmounted view")
    XCTAssertFalse(lease.isReleased, "Unmount retains output credit until the ordered GPU fence completes")
    XCTAssertEqual(resources.reservedBytes, 4_096)
    for _ in 0..<100 where !lease.isReleased {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(lease.isReleased)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testUnchangedLayerDisplayDoesNotBorrowAnotherCoverDrawable() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    let owner = UUID(), coverRevision = revision(title: "One requested frame")
    func update(_ progress: Double) {
      controller.update(ownerID: owner, progress: progress, revision: coverRevision,
        backsideColor: .document, preparesCoverMotion: true,
        canPrepare: { true }, cornerRadius: 12, cover: AnyView(Color.red))
    }
    update(0.2)
    for _ in 0..<100 where controller.submittedCurlFrameCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(controller.submittedCurlFrameCount, 0)
    let curl = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let warmFrames = controller.submittedCurlFrameCount
    // The document page installing beside this cover flushes the layer tree.
    // No new cover pixels, geometry or progress were requested by its owner.
    for _ in 0..<5 { curl.draw() }
    XCTAssertEqual(controller.submittedCurlFrameCount, warmFrames)
    var nextFrame: SheetCurlMetalView.FrameTiming?
    curl.onFrameMeasured = { if nextFrame == nil { nextFrame = $0 } }
    defer { curl.onFrameMeasured = nil }
    update(0.35)
    let demandReturned = CACurrentMediaTime()
    curl.draw()
    // MainActor has not yielded to the finite acquisition's delivery. Repeated
    // display callbacks share this pending request and cannot publish inline.
    for _ in 0..<5 { curl.draw() }
    XCTAssertEqual(controller.submittedCurlFrameCount, warmFrames)
    for _ in 0..<100 where controller.submittedCurlFrameCount == warmFrames || nextFrame == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.submittedCurlFrameCount, warmFrames + 1)
    let acquisition = try XCTUnwrap(try XCTUnwrap(nextFrame).drawableAcquisition)
    XCTAssertLessThanOrEqual(acquisition.requested, demandReturned,
      "The accepted pose starts its one drawable request before returning, without waiting for MTK display")
    for _ in 0..<5 { curl.draw() }
    XCTAssertEqual(controller.submittedCurlFrameCount, warmFrames + 1)
    XCTAssertEqual(controller.capturedCoverCount, 1)
  }

  @MainActor
  func testDetachedCoverKeepsLatestDemandWithoutSubmittingDrawables() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    let owner = UUID(), coverRevision = revision(title: "Detached curl")
    func update(_ progress: Double) {
      controller.update(ownerID: owner, progress: progress, revision: coverRevision,
        backsideColor: .document, preparesCoverMotion: true,
        canPrepare: { true }, cornerRadius: 12, cover: AnyView(Color.red))
    }
    update(0.2)
    for _ in 0..<100 where controller.submittedCurlFrameCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertGreaterThan(controller.submittedCurlFrameCount, 0)
    let curl = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? MTKView }.first)
    let frames = controller.submittedCurlFrameCount
    curl.removeFromSuperview()
    XCTAssertNil(curl.window)
    for progress in [0.2, 0.4, 0.7] { update(progress); curl.draw() }
    XCTAssertEqual(controller.submittedCurlFrameCount, frames)
    controller.view.addSubview(curl)
    for _ in 0..<100 where controller.submittedCurlFrameCount == frames {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(controller.submittedCurlFrameCount, frames + 1)
    XCTAssertEqual(controller.capturedCoverCount, 1)
  }

  @MainActor
  func testFailedMaterialWaitsForSourceChangeInsteadOfRetryingEveryPose() async throws {
    let (window, controller) = try coverWindow()
    defer { window.isHidden = true }
    var preparations = 0
    controller.prepareMaterial = { _, _, _ in
      preparations += 1
      throw SceneRenderError.snapshotPending("fixture_pending_owner")
    }
    let owner = UUID()
    func update(_ progress: Double, title: String = "Pending") {
      controller.update(ownerID: owner, progress: progress, revision: revision(title: title),
        backsideColor: .document, preparesCoverMotion: true,
        canPrepare: { true }, cornerRadius: 12, cover: AnyView(Color.red))
    }
    update(0.2)
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(preparations, 1)
    for progress in [0.3, 0.5, 0.4, 0.6] { update(progress) }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(preparations, 1)
    update(0.4, title: "New source")
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(preparations, 2)
  }

  @MainActor
  private func coverWindow() throws -> (UIWindow, IPadCoverOpeningController) {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 420, height: 600)
    let controller = IPadCoverOpeningController()
    PageTurnFrameFixture.install(on: controller)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    return (window, controller)
  }

  private func revision(title: String) -> CoverRenderingRevision {
    CoverRenderingRevision(
      item: .document(title: title),
      geometry: .uncompiledDocument,
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
