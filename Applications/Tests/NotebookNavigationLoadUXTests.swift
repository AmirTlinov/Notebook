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
  func testClosedDenseNotebookOpensThroughItsMountedDoubleTapOwner() async throws {
    try await cold(programs: false, board: false, opensCover: true)
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
  func testTwentyFourProgramsCommitThroughTheirRuntimesBeforeTheNextPageCapture() async throws {
    try await cold(programs:true,board:false,changesProgramsBeforeTurn:true)
  }

  private func cold(programs: Bool, board: Bool, measuresPinch: Bool = false, measuresTurns: Bool = false,
    opensCover: Bool = false, changesProgramsBeforeTurn: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-load-\(UUID())")
    let store = NotebookStore(root: root)
    try NotebookNavigationLoadFixture.seed(store, programs: programs, board: board)
    if !board && !opensCover {
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
    if opensCover {
      await startup.value
      try await openDenseCover(model: model, window: window)
      return
    }
    let probes = (0..<(programs ? 24 : 13)).map { index -> (CGPoint, NotebookUXObservation.Color) in
      let frame = NotebookNavigationLoadFixture.frame(index, programs: programs)
      return (.init(x: frame.x + 155, y: frame.y + (programs ? 20 : 145)), .blue)
    }
    let measuresOpening = !measuresPinch && !measuresTurns && !changesProgramsBeforeTurn
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
    if changesProgramsBeforeTurn {
      try await changeProgramsAndTurn(model:model,window:window)
      return
    }
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
      var preparationPhases: [(TimeInterval, String)] = []
      var omittedPhases = 0
      model.compositionTiles.onPreparationPhase = { _, phase in
        if preparationPhases.count < 128 { preparationPhases.append((CACurrentMediaTime(), phase)) }
        else { omittedPhases += 1 }
      }
      defer { model.compositionTiles.onPreparationPhase = nil }
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
      let preparation = XCTAttachment(string: "Scene preparation events during held input; wall time, not CPU or FPS; omitted=\(omittedPhases)\n"
        + preparationPhases.map { "\(($0.0-origin)*1000)ms: \($0.1)" }.joined(separator: "\n"))
      preparation.name = "Held camera scene preparation"; preparation.lifetime = .keepAlways; add(preparation)
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

  /// A real runtime-state/capture boundary. The mounted camera callbacks stand
  /// in for pinch kinematics; focus, JS commits, close/reopen and borrowing use
  /// their installed owners. The system-input UI journey remains separate.
  private func changeProgramsAndTurn(model:NotebookAppModel,window:UIWindow) async throws {
    let notebook=NotebookNavigationLoadFixture.notebookID,pageID=try XCTUnwrap(model.activePage?.id)
    let sourceIDs=try XCTUnwrap(model.activePage).elements.filter(\.requiresLiveRuntime).map(\.id)
    XCTAssertEqual(sourceIDs.count,24)
    var phases:[String]=[]
    defer {
      let note=XCTAttachment(string:phases.joined(separator:"\n"))
      note.name="24-program-state-to-native-capture";note.lifetime = .keepAlways;add(note)
    }
    func cameraGesture(_ scale:Double) async throws {
      let camera=try XCTUnwrap(window.gestureRecognizers?.compactMap {$0.delegate as? WorkspaceGestureLayer.Coordinator}.first)
      let center=CGPoint(x:window.bounds.midX,y:window.bounds.midY)
      camera.onCamera(.began(centroid:center))
      camera.onCamera(.changed(scale:scale,velocity:scale>1 ? 1:-1,elapsed:0.2,centroid:center))
      camera.onCamera(.ended(scale:scale,velocity:scale>1 ? 1:-1,elapsed:0.3,centroid:center))
      let deadline=ContinuousClock.now+NotebookUXObservation.opening
      while model.presencePhase != .settled,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(2))}
      _ = try XCTUnwrap(model.presencePhase == .settled ? model.presence:nil,"The mounted camera must settle")
      phases.append("camera scale=\(scale), mode=\(String(describing:model.presence?.mode)), actualScale=\(String(describing:model.presence?.camera.scale))")
    }
    try await cameraGesture(1.4)
    for (index,id) in sourceIDs.enumerated() {
      let source=agentElementSnapshotSource(try XCTUnwrap(model.pages[pageID]?.element(id:id)))
      func currentWeb()->WKWebView? { descendants(window).compactMap {$0 as? WKWebView}.first {
        ($0.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource(source) == true
      } }
      let runtimeDeadline=ContinuousClock.now+NotebookUXObservation.opening
      while currentWeb() == nil,ContinuousClock.now<runtimeDeadline {try await Task.sleep(for:.milliseconds(2))}
      let web=try XCTUnwrap(currentWeb(),"The exact accepted program must remain in its real WK runtime: \(id)")
      // The existing native focus owner authorizes the synthetic DOM event.
      _ = try await web.evaluateJavaScript("window.fixtureFocusAdmitted=false;addEventListener('notebookcapacity',()=>window.fixtureFocusAdmitted=true,{once:true});true")
      model.interactiveElementFocus = .page(pageID:pageID,elementID:id)
      let focusDeadline=ContinuousClock.now+NotebookUXObservation.opening
      var admitted=false
      while !admitted,ContinuousClock.now<focusDeadline {
        admitted=(try await web.evaluateJavaScript("window.fixtureFocusAdmitted")) as? Bool == true
        if !admitted {try await Task.sleep(for:.milliseconds(2))}
      }
      _ = try XCTUnwrap(admitted ? web:nil,"Native focus must authorize program \(id)")
      _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
      let stateDeadline=ContinuousClock.now+NotebookUXObservation.opening
      while model.pages[pageID]?.element(id:id)?.state["count"] != .number(1),ContinuousClock.now<stateDeadline {
        try await Task.sleep(for:.milliseconds(2))
      }
      let accepted=try XCTUnwrap(model.pages[pageID]?.element(id:id))
      phases.append("accepted \(index) \(id): state=\(accepted.state), stamp=\(String(describing:model.pages[pageID]?.agentStamp))")
      _ = try XCTUnwrap(accepted.state["count"] == .number(1) ? accepted:nil,"The real program commit must reach accepted model state")
      if index == 0 {
        try await cameraGesture(1/1.4)
        _ = try XCTUnwrap(model.presence?.mode == .board ? model.presence:nil,"Zoom-out must close the notebook before runtime restoration")
        try await openDenseCover(model:model,window:window,programs:true,changedFirstProgram:true)
        XCTAssertEqual(model.pages[pageID]?.element(id:id)?.state["count"],.number(1))
      }
    }
    let owner=try XCTUnwrap(descendants(window).compactMap {$0.next as? IPadPageTurnController}.first)
    let native=owner.sheetController,resources=SceneRenderResources.shared
    func captureState(_ sheet:UIViewController?)->String {
      let label=sheet?.view.accessibilityIdentifier ?? "nil"
      let index=label.split(separator:"-").last.flatMap {Int($0)}
      let page=index.flatMap {model.notebookPage(at:$0,in:notebook)}
      let webs=sheet.map {descendants($0.view).compactMap {$0 as? WKWebView}} ?? []
      let slots=page?.elements.filter(\.requiresLiveRuntime).map { source in
        let current=agentElementSnapshotSource(source)
        let owners=webs.compactMap {$0.navigationDelegate as? AgentWebCoordinator}.filter {$0.hasLiveSource(current)}
        let installations=owners.compactMap {$0.installation(for:current)}
        let available=index.map {owner.pageTurnActivity.hasElementFrame(page:$0,source:current)} ?? false
        return "\(source.id):state=\(source.state),provider=\(available),live=\(owners.count),installations=\(installations.map { "\($0.runtimeToken ?? "none")/installed=\($0.isInstalled)" }),diagnostics=\(resources.diagnostics(for:[current]))"
      } ?? []
      return "sheet=\(label),id=\(sheet.map {String(describing:ObjectIdentifier($0))} ?? "nil"),page=\(String(describing:page?.id)),stamp=\(String(describing:page?.agentStamp)); slots=\(slots); raster=\(resources.rasterAdmission); derivedWaiters=\(resources.pendingDerivedRequestCount); web=\(resources.activeWebSurfaceCount),pendingWeb=\(resources.pendingWebRequestCount)"
    }
    let receiveFailure=native.onFailure,receiveFrames=native.onFramesAcquired,acquire=native.acquireSheetFrame
    let receiveStage=native.onStageLiveSheet,receiveResolution=native.resolveOperation
    let curl=try XCTUnwrap(descendants(native.view).compactMap {$0 as? SheetCurlMetalView}.first)
    let receiveFrame=curl.onPageFrameReady
    var arrowUptime:TimeInterval=0,pairEnded:TimeInterval?,stageUptime:TimeInterval?
    var sawFirstFrame=false,sawEndpoint=false
    var landing:(operation:UUID,at:ContinuousClock.Instant,uptime:TimeInterval,presented:Bool)?
    native.resolveOperation = { id,outcome,presented,notify in
      receiveResolution(id,outcome,presented,notify)
      // The page owner has now installed the landing, published its selection,
      // and consumed the operation. Record that event before diagnostic work;
      // the waiting task's next scheduling opportunity is not this timestamp.
      let at=ContinuousClock.now,uptime=CACurrentMediaTime()
      if arrowUptime>0,landing == nil,outcome == .completed,
        owner.displayedIndex == 1,owner.currentPagePreparation.isReady {
        landing=(id,at,uptime,presented)
      }
    }
    native.onFailure = { error in
      phases.append("native failure: \(String(reflecting:error)); controller=\(owner.navigationStateDescription)")
      receiveFailure(error)
    }
    native.onFramesAcquired = { timing in
      pairEnded=timing.ended
      phases.append("pair acquired: \(timing.began)...\(timing.ended),pixels=\(timing.pixels),arrowToBegin=\(timing.began-arrowUptime),arrowToEnd=\(timing.ended-arrowUptime)")
      receiveFrames?(timing)
    }
    native.onStageLiveSheet = { sheet in
      let time=CACurrentMediaTime();stageUptime=time
      phases.append("stage live: uptime=\(time),arrowToStage=\(time-arrowUptime),pairEndToStage=\(String(describing:pairEnded.map {time-$0})),sheet=\(sheet.view.accessibilityIdentifier ?? "nil")")
      receiveStage(sheet)
    }
    curl.onPageFrameReady = { frame,progress,sequence,readiness in
      if readiness.isReady, !sawFirstFrame || (progress == 1 && !sawEndpoint) {
        let time=CACurrentMediaTime()
        phases.append("curl frame: callbackUptime=\(time),arrowToCallback=\(time-arrowUptime),progress=\(progress),sequence=\(sequence),OS=\(String(describing:readiness.presentedTime)),arrowToOS=\(String(describing:readiness.presentedTime.map {$0-arrowUptime}))")
        sawFirstFrame=true
        if progress == 1 {sawEndpoint=true}
      }
      let endpointForwardBegan=progress == 1 && readiness.isReady ? CACurrentMediaTime():nil
      receiveFrame?(frame,progress,sequence,readiness)
      if let endpointForwardBegan {
        let ended=CACurrentMediaTime()
        phases.append("endpoint callback forwarded: began=\(endpointForwardBegan),ended=\(ended),duration=\(ended-endpointForwardBegan),arrowToEnd=\(ended-arrowUptime)")
      }
    }
    native.acquireSheetFrame = { sheet in
      phases.append("acquire begin: sheet=\(sheet.view.accessibilityIdentifier ?? "nil")")
      let began=CACurrentMediaTime()
      do {
        let frame=try await acquire(sheet)
        phases.append("acquire result: sheet=\(sheet.view.accessibilityIdentifier ?? "nil"),frame=\(frame.id),elapsed=\(CACurrentMediaTime()-began)")
        return frame
      } catch {
        phases.append("acquire error: \(String(reflecting:error)),elapsed=\(CACurrentMediaTime()-began),sheet=\(sheet.view.accessibilityIdentifier ?? "nil")")
        throw error
      }
    }
    defer {
      native.onFailure=receiveFailure;native.onFramesAcquired=receiveFrames;native.acquireSheetFrame=acquire
      native.onStageLiveSheet=receiveStage;native.resolveOperation=receiveResolution;curl.onPageFrameReady=receiveFrame
    }
    phases.append("before arrow: \(captureState(native.page)); \(owner.navigationStateDescription)")
    let revision=try XCTUnwrap(model.notebookPageRoot(notebook)),start=ContinuousClock.now
    arrowUptime=CACurrentMediaTime()
    phases.append("arrow begin: uptime=\(arrowUptime)")
    XCTAssertTrue(model.notebookPageNavigation.send(.step(1),ownerID:notebook,source:revision))
    // Let the runtime's existing eight-second typed failure reach the diagnostic
    // wrapper. This does not extend the command-to-landing performance budget.
    let deadline=start + .seconds(9)
    while landing == nil,ContinuousClock.now<deadline {
      try await Task.sleep(for:.milliseconds(2))
    }
    // Full runtime diagnostics and pixel readback begin only after the event
    // measurement. No observation cost is subtracted from application time.
    phases.append("after arrow: ownerLanding=\(String(describing:landing)),stageToOwnerLanding=\(String(describing:landing.flatMap { receipt in stageUptime.map {receipt.uptime-$0} })); \(captureState(native.page)); \(owner.navigationStateDescription). Landing time comes from the owner's terminal event; OS presentation is the separate curl receipt above.")
    let receipt=try XCTUnwrap(landing,
      "All accepted program states must permit the actual neighbouring page capture and owner-completed landing")
    let elapsed=start.duration(to:receipt.at)
    phases.append("commandToOwnerLanding=\(elapsed),arrowToOwnerLanding=\(receipt.uptime-arrowUptime),operation=\(receipt.operation),presented=\(receipt.presented)")
    XCTAssertEqual(owner.displayedIndex,1)
    XCTAssertTrue(owner.currentPagePreparation.isReady)
    XCTAssertLessThanOrEqual(elapsed,NotebookUXObservation.pageLanding,
      "The 450ms command-to-owner-landing budget is unchanged; 9s above is only the diagnostic watchdog")
    let probes=(0..<24).map { index -> (CGPoint,NotebookUXObservation.Color) in
      let frame=NotebookNavigationLoadFixture.frame(index,programs:true)
      return (.init(x:frame.x+155,y:frame.y+20),.blue)
    }
    XCTAssertTrue(try NotebookUXObservation.Pixels(window:window).matches(probes+[(.init(x:190,y:1045),.blue)]))
  }

  private func openDenseCover(model: NotebookAppModel, window: UIWindow,
    programs:Bool = false,changedFirstProgram:Bool = false) async throws {
    let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
    func coverInput() -> NotebookInteractionTouchView? {
      var hit = window.hitTest(center, with: nil)
      while let view = hit {
        if let cover = view as? NotebookInteractionTouchView { return cover }
        hit = view.superview
      }
      return nil
    }
    let setupDeadline = ContinuousClock.now + .seconds(5)
    while (model.compositionTiles.published?.isPaintInstalled != true || coverInput() == nil),
      ContinuousClock.now < setupDeadline { try await Task.sleep(for: .milliseconds(5)) }
    let cover = try XCTUnwrap(coverInput(), "The closed cover must own the actual center hit")
    XCTAssertEqual(model.presence?.mode, .board)
    XCTAssertTrue(descendants(window).allSatisfy { !($0.next is IPadPageTurnController) },
      "This lane must start before paper has mounted or prewarmed")
    let began = CACurrentMediaTime()
    let first = DenseCoverTouch(window: window, view: cover, point: center, count: 1)
    cover.touchesBegan([first], with: nil); cover.touchesEnded([first], with: nil)
    try await Task.sleep(for: .milliseconds(200))
    let secondCover = try XCTUnwrap(coverInput(), "Selection must retain the physical cover input owner")
    let second = DenseCoverTouch(window: window, view: secondCover, point: center, count: 2)
    let pulseOrigin = CACurrentMediaTime()
    secondCover.touchesBegan([second], with: nil); secondCover.touchesEnded([second], with: nil)
    var delays: [Double] = [], milestones: [String: Double] = [:]
    milestones["inputHandled"] = (CACurrentMediaTime() - pulseOrigin) * 1_000
    var controller: IPadPageTurnController?
    for sample in 0..<240 {
      let due = pulseOrigin + Double(sample) / 120
      if due > CACurrentMediaTime() { try await Task.sleep(for: .seconds(due - CACurrentMediaTime())) }
      delays.append((CACurrentMediaTime() - due) * 1_000)
      if controller == nil {
        controller = descendants(window).compactMap { $0.next as? IPadPageTurnController }.first
        if controller != nil { milestones["mounted"] = (CACurrentMediaTime() - began) * 1_000 }
      }
      if controller?.presentedPageIndices.contains(0) == true, milestones["presented"] == nil {
        milestones["presented"] = (CACurrentMediaTime() - began) * 1_000
      }
      if controller?.preparedPageIndices.contains(0) == true, milestones["capturable"] == nil {
        milestones["capturable"] = (CACurrentMediaTime() - began) * 1_000
      }
      if model.presence?.mode == .page, model.presence?.openProgress == 1,
        model.presencePhase == .settled, controller?.currentPagePreparation.isReady == true {
        milestones["opened"] = (CACurrentMediaTime() - began) * 1_000
        break
      }
      if CACurrentMediaTime() - began >= 2 { break }
    }
    let report = "board → native cover touch(count1,count2) → page; milestones(ms)=\(milestones); queueMax(ms)=\(delays.max() ?? 0); delays=\(delays); controller=\(controller?.navigationStateDescription ?? "unmounted"); presented=\(controller?.presentedPageIndices.sorted() ?? []); capture=\(controller?.preparedPageIndices.sorted() ?? []); permits=\(model.permitsPagePreparation); phase=\(model.presencePhase); failure=\(model.persistenceFailure ?? model.compositionTiles.failure ?? "none"). Main-loop samples and installed sources, not OS presentation. Pixel capture follows timing."
    let attachment = XCTAttachment(string: report)
    attachment.name = "dense-cover-opening-owner-boundaries"; attachment.lifetime = .keepAlways; add(attachment)
    let opened = try XCTUnwrap(milestones["opened"], report)
    XCTAssertLessThanOrEqual(opened, 2_000, "The companion UI double-tap keeps its original 2-second opening watchdog")
    let page = try XCTUnwrap(controller).view!
    let scale = min(page.bounds.width / 834, page.bounds.height / 1194)
    let probes = (0..<(programs ? 24:13)).map { index -> (CGPoint, NotebookUXObservation.Color) in
      let frame = NotebookNavigationLoadFixture.frame(index, programs: programs)
      let local = CGPoint(x: (page.bounds.width - 834 * scale) / 2 + CGFloat(frame.x + 155) * scale,
        y: (page.bounds.height - 1194 * scale) / 2 + CGFloat(frame.y + (programs ? 20:145)) * scale)
      return (page.convert(local, to: window), changedFirstProgram && index == 0 ? .red:.blue)
    }
    let pixels=try NotebookUXObservation.Pixels(window:window)
    let failed=try probes.enumerated().filter { try !pixels.matches([$0.element]) }
    if !failed.isEmpty {
      let shot=XCTAttachment(image:pixels.image)
      shot.name="dense-cover-opening-pixels";shot.lifetime = .keepAlways;add(shot)
      let webs=descendants(page).compactMap {$0 as? WKWebView}
      let slots=(model.activePage?.elements.filter(\.requiresLiveRuntime) ?? []).map { element in
        let source=agentElementSnapshotSource(element)
        let installed=webs.filter {($0.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource(source) == true}
        let native=installed.map { "bounds=\($0.bounds),window=\($0.convert($0.bounds,to:window)),hidden=\($0.isHidden),alpha=\($0.alpha)" }
        return "\(element.id):state=\(element.state),frame=\(element.frame),native=\(native)"
      }
      let failedProbes=failed.map { "\($0.offset):point=\($0.element.0),color=\($0.element.1)" }
      let detail=XCTAttachment(string:"failed=\(failedProbes); controllerBounds=\(page.bounds),window=\(page.convert(page.bounds,to:window)),scale=\(scale); presence=\(String(describing:model.presence)); slots=\(slots)")
      detail.name="dense-cover-opening-pixel-coordinates";detail.lifetime = .keepAlways;add(detail)
    }
    XCTAssertTrue(failed.isEmpty,"Every authored element must be visible after the real cover opens")
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

@MainActor private final class DenseCoverTouch: UITouch {
  let sourceWindow: UIWindow
  let sourceView: UIView
  let point: CGPoint
  let count: Int
  init(window: UIWindow, view: UIView, point: CGPoint, count: Int) {
    sourceWindow = window; sourceView = view; self.point = point; self.count = count; super.init()
  }
  override var view: UIView? { sourceView }
  override var window: UIWindow? { sourceWindow }
  override var type: UITouch.TouchType { .direct }
  override var tapCount: Int { count }
  override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
}
