import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

/// Pixel deadlines start before mounting the cold root. A queued/ready status,
/// one fast element, or a late correct screenshot cannot pass these checks.
@MainActor final class NotebookNavigationLoadUXTests: XCTestCase {
  func testColdNotebookWithThirteenDenseSVGsShowsEveryElementWithinBudget() async throws {
    try await cold(programs: false, board: false)
  }
  func testColdNotebookWithTwentyFourProgramsShowsEveryControlWithinBudget() async throws {
    try await cold(programs: true, board: false)
  }
  func testColdBoardWithTwentyFourProgramsShowsEveryControlWithinBudget() async throws {
    try await cold(programs: true, board: true)
  }

  func testContinuousPinchWithTwentyFourProgramsHasNoLateInputSamples() async throws {
    try await cold(programs: true, board: true, measuresPinch: true)
  }

  func testDensePageTurnsDoNotBlockTheMainRunLoop() async throws {
    try await cold(programs:false,board:false,measuresTurns:true)
  }

  func testTwentyFourProgramPagesReachTheRequestedLeafWithinBudget() async throws {
    try await cold(programs:true,board:false,measuresTurns:true)
  }

  private func cold(programs: Bool, board: Bool, measuresPinch: Bool = false, measuresTurns: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-load-\(UUID())")
    let store = NotebookStore(root: root)
    try NotebookNavigationLoadFixture.seed(store, programs: programs, board: board)
    if !board {
      let workspace = try store.loadIndex(), hierarchy = try store.loadBoard(items: workspace.items)
      let center = try XCTUnwrap(hierarchy.focusedCenter(of: NotebookNavigationLoadFixture.notebookID, in: workspace.rootBoardID))
      try store.savePresence(.init(boardID: workspace.rootBoardID, mode: .page,
        camera: .init(center: center, scale: 1), viewport: .init(x: 834, y: 1194),
        focusedItemID: NotebookNavigationLoadFixture.notebookID, openProgress: 1,
        selectedItemID: NotebookNavigationLoadFixture.notebookID, notebookPageID: workspace.selectedPageID))
    }
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    addTeardownBlock { @MainActor in window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let start = ContinuousClock.now
    window.rootViewController = UIHostingController(rootView: SpatialWorkspaceView().environment(model).ignoresSafeArea())
    window.makeKeyAndVisible()
    // Observe while bootstrap runs. start() also awaits nonvisual services:
    // measuring only after it returns can miss an already displayed first
    // frame. The origin still precedes both mounting and bootstrap.
    let startup = Task { await model.start(pageSize: .init(width: 834, height: 1194)) }
    defer { startup.cancel() }
    let probes = (0..<(programs ? 24 : 13)).map { index -> (CGPoint, NotebookUXObservation.Color) in
      let frame = NotebookNavigationLoadFixture.frame(index, programs: programs)
      return (.init(x: frame.x + 155, y: frame.y + (programs ? 20 : 145)), .blue)
    }
    let measuresOpening = !measuresPinch && !measuresTurns
    let first = measuresOpening ? try await NotebookUXObservation.observe(since: start,
      budget: NotebookUXObservation.firstUsefulFrame) {
      // Do not keep copying a known-empty full window while WebKit/SwiftUI
      // needs that same main actor to install the first frame. Readiness can
      // only enable a pixel probe; it cannot itself satisfy this deadline.
      let views = descendants(window)
      let rasterIsMounted = views.contains { $0 is AgentSnapshotRasterView && $0.layer.contents != nil }
      let sources = board
        ? model.presence.flatMap { model.boardHierarchy?.board($0.boardID)?.elements.map(agentElementSnapshotSource) } ?? []
        : model.activePage?.elements.filter { $0.kind == .web } ?? []
      let liveIsMounted = views.compactMap { $0 as? WKWebView }.contains { web in
        sources.contains { (web.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource($0) == true }
      }
      guard rasterIsMounted || liveIsMounted else { return false }
      let pixels = try NotebookUXObservation.Pixels(window: window)
      return try probes.contains { try pixels.matches([$0]) }
    } : nil
    let result = try await NotebookUXObservation.observe(since: start,
      budget: measuresOpening ? NotebookUXObservation.coldOpening : .seconds(5)) {
      if programs {
        let sources = board
          ? model.presence.flatMap { model.boardHierarchy?.board($0.boardID)?.elements.map(agentElementSnapshotSource) } ?? []
          : model.activePage?.elements.filter { $0.kind == .web } ?? []
        let views = descendants(window).compactMap { $0 as? WKWebView }
        guard sources.count == 24, sources.allSatisfy({ source in
          views.contains { ($0.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource(source) == true }
        }) else { return false }
      }
      return try NotebookUXObservation.Pixels(window: window).matches(probes)
    }
    if programs && result.matched {
      // A static blue screenshot is insufficient. Each mounted runtime must
      // have usable DOM and exactly one boot before the system-tap UI journey.
      let webs = descendants(window).compactMap { $0 as? WKWebView }
      var buttons = 0
      for web in webs {
        let value = try await web.evaluateJavaScript("({buttons:document.querySelectorAll('button[aria-label^=\"Load 0 control\"]').length,boots:window.loadBoots||0})")
        if let value = value as? [String: Int], value["buttons", default: 0] > 0 {
          buttons += value["buttons", default: 0]; XCTAssertEqual(value["boots"], 1)
        }
      }
      XCTAssertEqual(buttons, 24, "Every displayed control must actually be running, not a placeholder or stale raster")
      if measuresOpening {
        XCTAssertLessThanOrEqual(start.duration(to: .now), NotebookUXObservation.coldOpening,
          "All 24 visible runtimes must also have usable DOM within the original cold-opening deadline")
      }
    }
    await startup.value
    // Cold deadlines are asserted only after both measurements and DOM checks;
    // recording a failed first-milestone screenshot must not stall the second.
    // Gesture lanes get a setup watchdog, not a cold-performance exemption:
    // the three separate cold tests retain their 150/1000 ms gates.
    if let first {
      XCTAssertTrue(first.passed, "First authored pixels: \(first.milliseconds) ms, matched=\(first.matched), budget=\(NotebookUXObservation.firstUsefulFrame)")
      XCTAssertTrue(result.passed, "All authored pixels: \(result.milliseconds) ms, matched=\(result.matched), budget=1000 ms")
    } else { XCTAssertTrue(result.passed, "Cannot prepare the real scene for the independent gesture scenario") }
    let milestones = XCTAttachment(string: "first=\(first.map { String($0.milliseconds) } ?? "gesture-setup"); all=\(result.milliseconds); matched=\(result.matched)")
    milestones.name = "Cold opening milestones"; milestones.lifetime = .keepAlways; add(milestones)
    let shot = XCTAttachment(image: try NotebookUXObservation.Pixels(window: window).image)
    shot.name = "All authored elements at the cold-opening deadline"; shot.lifetime = .keepAlways; add(shot)
    let resources = SceneRenderResources.shared
    let usage = XCTAttachment(string: "web=\(resources.activeWebSurfaceCount); queued=\(resources.pendingWebRequestCount); bytes=\(resources.residentBytes + resources.reservedBytes)/\(resources.byteLimit)")
    usage.name = "Cold navigation resource use"; usage.lifetime = .keepAlways; add(usage)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
    guard result.matched else { return }
    if programs { try await assertVisibleCSSMotion(window) }
    if measuresTurns {
      var delays: [Double] = []
      let owner = NotebookNavigationLoadFixture.notebookID
      let revision = try XCTUnwrap(model.notebookPageRoot(owner))
      let controller = try XCTUnwrap(descendants(window).compactMap { $0.next as? IPadPageTurnController }.first)
      var requested: [Int: Double] = [:], landed: [Int: Double] = [:]
      let origin = CACurrentMediaTime()
      for sample in 0..<240 {
        let due = origin + Double(sample)/120
        let remaining = due-CACurrentMediaTime()
        if remaining > 0 { try await Task.sleep(for:.seconds(remaining)) }
        if sample == 0 || sample == 60 {
          // Fixed-cadence input time, not the time the main queue eventually
          // handles it; command preparation and animation are both charged.
          requested[sample == 0 ? 1 : 2] = due
          XCTAssertTrue(model.notebookPageNavigation.send(.step(1),ownerID:owner,source:revision))
        }
        delays.append((CACurrentMediaTime()-due)*1_000)
        let index = controller.displayedIndex
        if let began = requested[index], landed[index] == nil {
          landed[index] = (CACurrentMediaTime() - began) * 1_000
        }
      }
      let report = "Fixed 120 Hz main-queue probes during dense turns: max=\(delays.max() ?? .infinity) ms; delays=\(delays). Queue responsiveness, not FPS or GPU presentation."
      let attachment = XCTAttachment(string:report); attachment.name="dense-page-turn-main-loop"; attachment.lifetime = .keepAlways; add(attachment)
      XCTAssertEqual(delays.count,240)
      XCTAssertLessThanOrEqual(delays.max() ?? .infinity,NotebookUXObservation.cameraSampleMS,report)
      let owners = descendants(window).compactMap { $0.next as? IPadPageTurnController }
      let status = "page preparation=\(model.permitsPagePreparation); requested=\(requested); landed=\(landed); modelPage=\(String(describing:model.workspace?.selectedPageID)); owners=\(owners.map { "\($0.navigationStateDescription),ready=\($0.preparedPageIndices.sorted()),hosts=\($0.cachedPageIdentities.keys.sorted())" }); web=\(resources.activeWebSurfaceCount); pendingWeb=\(resources.pendingWebRequestCount); loadedPages=\(model.pages.count)"
      print(status)
      let readiness = XCTAttachment(string:status); readiness.name="page-window-readiness"; readiness.lifetime = .keepAlways; add(readiness)
      for index in 1...2 {
        let elapsed = try XCTUnwrap(landed[index], "Requested page never reached presentation")
        XCTAssertLessThanOrEqual(Duration.milliseconds(elapsed), NotebookUXObservation.pageLanding,
          "Page \(index): original command → presented landing, including preparation and curl")
      }
      XCTAssertEqual(model.presence?.notebookPageID.flatMap { model.notebookPageIndex($0,in:owner) },2)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches([
        (.init(x:280,y:1045),.blue),(.init(x:100,y:1045),.paper),(.init(x:190,y:1045),.paper)
      ]),"The actually landed sheet, not just its counter, must be the second requested page")
      // Pixel readback is deliberately OUTSIDE the cadence measurement above.
      // Its own conservative deadline includes capture cost and never starts
      // after the command. Both target identity and every authored element count.
      for target in [1, 2] {
        let began = ContinuousClock.now
        XCTAssertTrue(model.notebookPageNavigation.send(.step(target == 1 ? -1 : 1), ownerID: owner, source: revision))
        try await assertUX("complete-presented-page-\(target)", since: began,
          budget: NotebookUXObservation.pageLanding, window: window) {
          guard controller.displayedIndex == target else { return false }
          let markers: [(CGPoint, NotebookUXObservation.Color)] = (0..<4).map {
            (.init(x: 100 + $0 * 90, y: 1045), $0 == target ? .blue : .paper)
          }
          return try NotebookUXObservation.Pixels(window: window).matches(probes + markers)
        }
      }
    }
    if measuresPinch {
      let basis = try XCTUnwrap(model.presence)
      let pinch = try HeldCoveragePinch(window: window, presence: basis)
      let monitor = NotebookGestureLatency(window: window)
      var delivery = NotebookUXObservation.CameraDelivery()
      pinch.recognizer.onCameraHandled = { input, entered, handled in
        guard let camera = model.presence?.camera else { return }
        delivery.receipts.append(.init(id: input, scale: camera.scale, center: camera.center,
          entered: entered, handled: handled))
      }
      defer { pinch.recognizer.onCameraHandled = nil; pinch.end(); monitor.stop() }
      let origin = CACurrentMediaTime()
      for sample in 0..<120 {
        let due = origin + Double(sample) / 120
        let remaining = due - CACurrentMediaTime()
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        // Out and in with continuous held contacts, no settle/prewarm between
        // samples and no deadline reset after a stall.
        let scale = 1 - 0.45 * sin(Double(sample) / 119 * .pi)
        monitor.input(due: due, needsPresentation: false) { pinch.move(center: .zero, scale: scale) }
        let input = try XCTUnwrap(pinch.recognizer.cameraInput)
        if let previous = delivery.inputs.last {
          XCTAssertEqual(input.contactID, previous.id.contactID)
          XCTAssertEqual(input.revision, previous.id.revision + 1)
        }
        delivery.inputs.append(.init(id: input, due: due,
          scale: scale, center: .zero, requiresAction: pinch.recognizer.intent == .magnification))
      }
      await Task.yield()
      XCTAssertTrue(model.inputIsActive, "The entire replay must precede finger-up")
      try await monitor.drain()
      // UIUpdateLink reports scheduled UIKit update opportunities, not a
      // displayed frame. ProMotion may coalesce them even without a hitch.
      // The companion real-pinch XCTHitchMetric is the display performance gate;
      // this continuous held replay strictly checks every input deadline.
      XCTAssertEqual(monitor.samples.count,120)
      XCTAssertTrue(monitor.samples.allSatisfy {
        NotebookUXObservation.acceptsCameraSample(due: $0.due, entered: $0.entered, handled: $0.handled)
      }, "EVERY camera handler <=5 ms; queue+handler <=16.67 ms. Missing timestamps, queue backlog and averaging cannot pass")
      // UIKit may queue/coalesce the recognizer's target action AFTER
      // touchesMoved returns. A fast ingestion call cannot certify that the
      // actual camera handler (including native projection) was prompt.
      XCTAssertEqual(pinch.recognizer.intent, .magnification)
      XCTAssertEqual(delivery.inputs.count, 120)
      XCTAssertTrue(delivery.passed,
        "Every input needs a same-contact measured pose ACK, within its ORIGINAL 5/16.67 ms ceilings; coalescing never resets time")
      let handling = XCTAttachment(string: delivery.report)
      handling.name = "Actual camera handler delivery"; handling.lifetime = .keepAlways; add(handling)
      let timing = XCTAttachment(string: monitor.samples.enumerated().map { index, sample in
        "\(index): queue=\(sample.entered.map { ($0-sample.due)*1_000 } ?? -1)ms; execution=\(sample.entered.map { (sample.handled-$0)*1_000 } ?? -1)ms; total=\((sample.handled-sample.due)*1_000)ms; UIKit=\(sample.uiSubmitted.map { ($0-sample.due)*1_000 } ?? -1)ms"
      }.joined(separator:"\n"))
      timing.name="held-pinch-input-and-update-diagnostics"; timing.lifetime = .keepAlways; add(timing)
      XCTAssertTrue(try NotebookUXObservation.Pixels(window: window).matches(probes),
        "All material must be visible after zoom returns, before either finger lifts")
      try await assertVisibleCSSMotion(window)
      XCTAssertTrue(model.inputIsActive, "CSS pixels must keep animating while BOTH fingers remain down")
    }
  }

  private func assertVisibleCSSMotion(_ window: UIWindow) async throws {
    let before = try pulsePositions(window)
    try await Task.sleep(for: .milliseconds(150))
    let middle = try pulsePositions(window)
    try await Task.sleep(for: .milliseconds(150))
    let after = try pulsePositions(window)
    for i in 0..<24 {
      XCTAssertGreaterThan(max(abs(after[i]-before[i]),abs(middle[i]-before[i])),2,
        "CSS animation \(i) must change actual visible pixels, not merely report a live context")
    }
  }

  private func pulsePositions(_ window:UIWindow) throws -> [Double] {
    let image = try NotebookUXObservation.Pixels(window:window).image
    return try (0..<24).map { i in
      let frame = NotebookNavigationLoadFixture.frame(i,programs:true)
      let strip = try XCTUnwrap(image.cgImage?.cropping(to:.init(x:frame.x,y:frame.y+104,width:170,height:1)))
      var rgba = [UInt8](repeating:0,count:170*4)
      try rgba.withUnsafeMutableBytes { bytes in
        let context = try XCTUnwrap(CGContext(data:bytes.baseAddress,width:170,height:1,bitsPerComponent:8,
          bytesPerRow:680,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(strip,in:.init(x:0,y:0,width:170,height:1))
      }
      let white = (0..<170).filter { rgba[$0*4] > 220 && rgba[$0*4+1] > 220 && rgba[$0*4+2] > 220 }
      XCTAssertGreaterThanOrEqual(white.count,5,"The animation's current bright mark must be visible")
      return Double(white.reduce(0,+))/Double(max(1,white.count))
    }
  }

  private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
