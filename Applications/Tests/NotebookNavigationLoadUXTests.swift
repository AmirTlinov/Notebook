import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

/// Native-installation deadlines start before mounting the cold root. Exact
/// source/runtime receipts time that boundary; pixels and usable controls are
/// checked independently afterward. These timestamps do not establish OS display.
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
    let fixtureIndex = try store.loadIndex()
    let expectedElements: [AgentElement]
    if board {
      let hierarchy = try store.loadBoard(items: fixtureIndex.items)
      expectedElements = hierarchy.board(fixtureIndex.rootBoardID)?.elements.map(agentElementSnapshotSource) ?? []
    } else {
      expectedElements = try store.loadPage(XCTUnwrap(fixtureIndex.selectedPageID)).elements
        .filter { $0.kind == .web }.map(agentElementSnapshotSource)
    }
    let expected = Dictionary(uniqueKeysWithValues: expectedElements.map { ($0.id, SceneRasterSource.agent($0)) })
    XCTAssertEqual(expected.count, programs ? 24 : 13)
    var firstInstalled: ContinuousClock.Instant?, allInstalled: ContinuousClock.Instant?
    var installations: [String: SceneSourceInstallation] = [:]
    precondition(NotebookNavigationObservation.onSourceInstalled == nil)
    NotebookNavigationObservation.onSourceInstalled = { installation, at in
      guard let source = installation.source.agentElement,
        expected[source.id] == .agent(source), installation.requiresVisibility,
        installation.isInstalled else { return }
      if firstInstalled == nil { firstInstalled = at }
      // A passive blue raster can be first useful native material. The complete
      // program cohort requires every exact, mounted, author-ready live runtime.
      if programs && installation.runtimeToken == nil { return }
      installations[source.id] = installation
      if allInstalled == nil, installations.count == expected.count,
        installations.values.allSatisfy({ $0.isInstalled }) { allInstalled = at }
    }
    defer { NotebookNavigationObservation.onSourceInstalled = nil }
    let start = ContinuousClock.now
    var webPhases: [(String, UUID, String?, ContinuousClock.Instant)] = []
    var compositionPhases: [(UUID, String, ContinuousClock.Instant)] = []
    precondition(NotebookNavigationObservation.onWebPreparation == nil)
    NotebookNavigationObservation.onWebPreparation = { stage, lease, source, at in
      guard webPhases.count < 512 else { return }
      webPhases.append((stage, lease, source, at))
    }
    model.compositionTiles.onPreparationPhase = { id, stage in
      guard compositionPhases.count < 128 else { return }
      compositionPhases.append((id, stage, .now))
    }
    defer {
      NotebookNavigationObservation.onWebPreparation = nil
      model.compositionTiles.onPreparationPhase = nil
      let composition = compositionPhases.map { "\(start.duration(to: $0.2)) \($0.1) owner=\($0.0)" }
      let web = webPhases.map { "\(start.duration(to: $0.3)) \($0.0) owner=\($0.1) source=\($0.2 ?? "unbound")" }
      let phases = XCTAttachment(string: (composition + web).joined(separator: "\n"))
      phases.name = "Cold source preparation events"; phases.lifetime = .keepAlways; add(phases)
    }
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
    // The source owner timestamps installation itself. Polling only waits for
    // that receipt; it performs no window readback or layout and cannot rebase
    // either deadline. Five seconds is a diagnostic/setup watchdog, not a budget.
    let setupLimit = start + .seconds(5)
    while allInstalled == nil, ContinuousClock.now < setupLimit {
      try await Task.sleep(for: .milliseconds(2))
    }
    // Cold observation ends with this cohort's setup. Subsequent correctness
    // reads and accepted turns own their own observation interval and hooks.
    NotebookNavigationObservation.onSourceInstalled = nil
    NotebookNavigationObservation.onWebPreparation = nil
    model.compositionTiles.onPreparationPhase = nil
    let first = measuresOpening ? NotebookUXObservation.Result(matched: firstInstalled != nil,
      elapsed: start.duration(to: firstInstalled ?? .now), budget: NotebookUXObservation.firstUsefulFrame) : nil
    let result = NotebookUXObservation.Result(matched: allInstalled != nil,
      elapsed: start.duration(to: allInstalled ?? .now),
      budget: measuresOpening ? NotebookUXObservation.coldOpening : .seconds(5))
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
    }
    await startup.value
    // Readback and DOM queries validate correctness after the owner event;
    // their execution time cannot establish or erase an earlier display time.
    let acceptedInstallations = Array(installations.values)
    let pixels = try await authoredPixels(window: window, probes: probes) {
      acceptedInstallations.count == expected.count && acceptedInstallations.allSatisfy { $0.isInstalled }
    }
    let pixelsMatched = try pixels.matches(probes)
    XCTAssertTrue(pixelsMatched, "Every exact authored element must be visible independently of native installation readiness")
    if let first {
      XCTAssertTrue(first.passed, "First exact authored native installation: \(first.milliseconds) ms, matched=\(first.matched), budget=150 ms; OS first-pixel time is unmeasured")
      XCTAssertTrue(result.passed, "Complete exact native cohort: \(result.milliseconds) ms, matched=\(result.matched), budget=1000 ms; OS display time is unmeasured")
    } else { XCTAssertTrue(result.passed, "Cannot prepare the real scene for the independent gesture scenario") }
    let milestones = XCTAttachment(string: "Native installation only: first=\(first.map { String($0.milliseconds) } ?? "gesture-setup"); all=\(result.milliseconds); matched=\(result.matched); exactSources=\(installations.count)/\(expected.count); programsRequireLiveRuntime=\(programs); independentPixelsCorrect=\(pixelsMatched). Origin precedes mounting; 150/1000ms ceilings unchanged. OS first-pixel/display deadlines remain unmeasured. Pixel readback and DOM correctness run afterward; no capture cost is subtracted.")
    milestones.name = "Cold opening milestones"; milestones.lifetime = .keepAlways; add(milestones)
    let shot = XCTAttachment(image: pixels.image)
    shot.name = "Independent authored pixels after native installation measurement"; shot.lifetime = .keepAlways; add(shot)
    let resources = SceneRenderResources.shared
    let usage = XCTAttachment(string: "web=\(resources.activeWebSurfaceCount); queued=\(resources.pendingWebRequestCount); bytes=\(resources.residentBytes + resources.reservedBytes)/\(resources.byteLimit)")
    usage.name = "Cold navigation resource use"; usage.lifetime = .keepAlways; add(usage)
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
    guard result.matched, pixelsMatched else { return }
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
    var materialPhases: [(String, UUID, UUID?, UUID?, UUID?, TimeInterval)] = []
    var omittedMaterialPhases = 0
    precondition(NotebookNavigationObservation.onPageMaterialPreparation == nil)
    NotebookNavigationObservation.onPageMaterialPreparation = { stage, owner, page, frame, operation, time in
      guard materialPhases.count < 128 else { omittedMaterialPhases += 1; return }
      materialPhases.append((stage, owner, page, frame, operation, time))
    }
    defer {
      NotebookNavigationObservation.onPageMaterialPreparation = nil
      phases.append("material events (omitted=\(omittedMaterialPhases)):")
      phases.append(contentsOf: materialPhases.map {
        "material: uptime=\($0.5),stage=\($0.0),owner=\($0.1),page=\($0.2?.uuidString ?? "nil"),frame=\($0.3?.uuidString ?? "nil"),composition=\($0.4?.uuidString ?? "nil")"
      })
    }
    let captureEpoch = ContinuousClock.now
    var capturePhases: [(String, UUID, String?, ContinuousClock.Instant)] = []
    var omittedCapturePhases = 0
    precondition(NotebookNavigationObservation.onWebPreparation == nil)
    NotebookNavigationObservation.onWebPreparation = { stage, lease, source, time in
      guard stage.hasPrefix("accepted_capture_") else { return }
      guard capturePhases.count < 192 else { omittedCapturePhases += 1; return }
      capturePhases.append((stage, lease, source, time))
    }
    defer {
      NotebookNavigationObservation.onWebPreparation = nil
      phases.append("accepted capture events (omitted=\(omittedCapturePhases)):")
      phases.append(contentsOf: capturePhases.map {
        "capture: elapsed=\(captureEpoch.duration(to: $0.3)),stage=\($0.0),lease=\($0.1),source=\($0.2 ?? "nil")"
      })
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
      let preparation=index.map { "presented=\(owner.presentedPageIndices.contains($0)),capturable=\(owner.preparedPageIndices.contains($0))" } ?? "missing"
      let ink=sheet.map { descendants($0.view).compactMap {$0 as? InkCanvasView}.map {
        "material=\($0.acceptedMaterialIsReady),frame=\($0.acceptedFrameIsReady),empty=\($0.acceptedMaterialIsEmpty),hidden=\($0.isHidden),publication=\($0.framePublicationState)"
      }} ?? []
      return "sheet=\(label),id=\(sheet.map {String(describing:ObjectIdentifier($0))} ?? "nil"),page=\(String(describing:page?.id)),stamp=\(String(describing:page?.agentStamp)),readiness=\(preparation),ink=\(ink); slots=\(slots); raster=\(resources.rasterAdmission); derivedWaiters=\(resources.pendingDerivedRequestCount); web=\(resources.activeWebSurfaceCount),pendingWeb=\(resources.pendingWebRequestCount)"
    }
    let receiveFailure=native.onFailure,receiveFrames=native.onFramesAcquired,acquire=native.acquireSheetFrame
    let receiveStage=native.onStageLiveSheet,receiveResolution=native.resolveOperation
    let curl=try XCTUnwrap(descendants(native.view).compactMap {$0 as? SheetCurlMetalView}.first)
    let receiveFrame=curl.onPageFrameReady,receiveMeasurement=curl.onFrameMeasured
    var submissions:[SheetCurlMetalView.FrameTiming]=[]
    var arrowUptime:TimeInterval=0,pairEnded:TimeInterval?,stageUptime:TimeInterval?
    curl.onFrameMeasured = { timing in
      if arrowUptime>0,timing.operationID != nil,timing.encodingBegan>=arrowUptime,submissions.count < 6 {
        submissions.append(timing)
      }
      receiveMeasurement?(timing)
    }
    var sawFirstFrame=false,sawEndpoint=false
    var expectedLanding=1
    var landing:(operation:UUID,at:ContinuousClock.Instant,uptime:TimeInterval,presented:Bool)?
    native.resolveOperation = { id,outcome,presented,notify in
      receiveResolution(id,outcome,presented,notify)
      // The page owner has now installed the landing, published its selection,
      // and consumed the operation. Record that event before diagnostic work;
      // the waiting task's next scheduling opportunity is not this timestamp.
      let at=ContinuousClock.now,uptime=CACurrentMediaTime()
      if arrowUptime>0,landing == nil,outcome == .completed,
        owner.displayedIndex == expectedLanding,owner.currentPagePreparation.isReady {
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
      curl.onFrameMeasured=receiveMeasurement
    }
    phases.append("before arrow: \(owner.navigationStateDescription)")
    let wallAnchor=Date().timeIntervalSince1970,uptimeAnchor=CACurrentMediaTime()
    phases.append("clock anchor: unix=\(wallAnchor),uptime=\(uptimeAnchor)")
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
    // Timestamps originate in the clock/encoder/GPU, and are joined by the
    // admitted operation. Formatting and image readback happen after landing.
    for timing in submissions where timing.operationID == receipt.operation {
      phases.append("curl submission: operation=\(receipt.operation),sequence=\(timing.sequence),clockRequest=\(String(describing:timing.clockRequested)),displayCallback=\(String(describing:timing.displayUpdateReceived)),encoding=\(timing.encodingBegan),submitted=\(timing.submitted),GPU=\(timing.gpuBegan)...\(timing.gpuEnded),targetOS=\(timing.targetPresentation)")
    }
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

    // The system UI regression occurs on the return after the target's full
    // live cohort has replaced its passive rasters. Exercise that same role
    // boundary here; a successful first landing cannot certify its inverse.
    let targetPage=try XCTUnwrap(model.notebookPage(at:1,in:notebook))
    let targetSources=targetPage.elements.filter(\.requiresLiveRuntime).map(agentElementSnapshotSource)
    func targetRuntimesInstalled()->Bool {
      guard let sheet=native.page else { return false }
      let owners=descendants(sheet.view).compactMap {($0 as? WKWebView)?.navigationDelegate as? AgentWebCoordinator}
      return targetSources.allSatisfy { source in
        owners.contains { $0.hasLiveSource(source) && $0.installation(for:source)?.isInstalled == true }
      }
    }
    let runtimeDeadline=ContinuousClock.now + .seconds(2)
    while !targetRuntimesInstalled(),ContinuousClock.now<runtimeDeadline {try await Task.sleep(for:.milliseconds(2))}
    phases.append("before reverse: \(owner.navigationStateDescription)")
    XCTAssertTrue(targetRuntimesInstalled(),"Every target program must become a real installed runtime before the reverse command")
    expectedLanding=0;landing=nil;pairEnded=nil;stageUptime=nil;sawFirstFrame=false;sawEndpoint=false
    submissions.removeAll(keepingCapacity:true)
    let reverseStart=ContinuousClock.now
    arrowUptime=CACurrentMediaTime()
    phases.append("reverse begin: uptime=\(arrowUptime)")
    XCTAssertTrue(model.notebookPageNavigation.send(.step(-1),ownerID:notebook,source:revision))
    let reverseDeadline=reverseStart + .seconds(2)
    while landing == nil,ContinuousClock.now<reverseDeadline {try await Task.sleep(for:.milliseconds(2))}
    phases.append("after reverse: ownerLanding=\(String(describing:landing)); \(owner.navigationStateDescription)")
    for sheet in native.children { phases.append("reverse sheet: \(captureState(sheet))") }
    let reverseReceipt=try XCTUnwrap(landing,"Returning to the retained page must complete after its programs became passive")
    for timing in submissions where timing.operationID == reverseReceipt.operation {
      phases.append("reverse curl submission: operation=\(reverseReceipt.operation),sequence=\(timing.sequence),clockRequest=\(String(describing:timing.clockRequested)),displayCallback=\(String(describing:timing.displayUpdateReceived)),encoding=\(timing.encodingBegan),submitted=\(timing.submitted),GPU=\(timing.gpuBegan)...\(timing.gpuEnded),targetOS=\(timing.targetPresentation)")
    }
    XCTAssertEqual(owner.displayedIndex,0)
    XCTAssertTrue(owner.currentPagePreparation.isReady)
    XCTAssertLessThanOrEqual(reverseStart.duration(to:reverseReceipt.at),NotebookUXObservation.pageLanding)
    let restoredProbes=probes.map { ($0.0,NotebookUXObservation.Color.red) }
    let restoredPixels=try NotebookUXObservation.Pixels(window:window)
    XCTAssertTrue(try restoredPixels.matches(restoredProbes),
      "The return must show all 24 accepted states")
    XCTAssertTrue(try restoredPixels.matches([(.init(x:100,y:1045),.blue),(.init(x:190,y:1045),.paper)]),
      "The return must show the leaf 0 marker and clear the leaf 1 marker")
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
    // Writable paper can open before its programs. Complete authored pixels
    // have their own receipt, still within the SAME original opening ceiling.
    while controller?.presentedPageIndices.contains(0) != true, CACurrentMediaTime() - began < 2 {
      try await Task.sleep(for: .milliseconds(2))
    }
    XCTAssertTrue(controller?.presentedPageIndices.contains(0) == true,
      "All source installations must follow writable paper within the original two seconds")
    let page = try XCTUnwrap(controller).view!
    let scale = min(page.bounds.width / 834, page.bounds.height / 1194)
    let probes = (0..<(programs ? 24:13)).map { index -> (CGPoint, NotebookUXObservation.Color) in
      let frame = NotebookNavigationLoadFixture.frame(index, programs: programs)
      let local = CGPoint(x: (page.bounds.width - 834 * scale) / 2 + CGFloat(frame.x + 155) * scale,
        y: (page.bounds.height - 1194 * scale) / 2 + CGFloat(frame.y + (programs ? 20:145)) * scale)
      return (page.convert(local, to: window), changedFirstProgram && index == 0 ? .red:.blue)
    }
    let acceptedPageID = model.activePage?.id
    let acceptedSources = model.activePage?.elementSourceIdentity
    let pixels = try await authoredPixels(window: window, probes: probes) {
      model.activePage?.id == acceptedPageID && model.activePage?.elementSourceIdentity == acceptedSources
        && controller?.presentedPageIndices.contains(0) == true
    }
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

  /// Remote WebKit pixels can arrive after their exact native installation.
  /// This bounded image check follows the recorded app deadlines; its readback
  /// and waiting time are diagnostics, never an alternative latency receipt.
  private func authoredPixels(window: UIWindow, probes: [(CGPoint, NotebookUXObservation.Color)],
    stillInstalled: () -> Bool) async throws -> NotebookUXObservation.Pixels {
    let deadline = ContinuousClock.now + .seconds(1)
    var pixels = try NotebookUXObservation.Pixels(window: window)
    while try !pixels.matches(probes), ContinuousClock.now < deadline, stillInstalled() {
      try await Task.sleep(for: .milliseconds(16))
      pixels = try NotebookUXObservation.Pixels(window: window)
    }
    XCTAssertTrue(stillInstalled(), "Image correctness cannot borrow a replaced source installation")
    return pixels
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
