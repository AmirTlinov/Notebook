import NotebookCore
import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

/// Diagnoses owner/UI opportunities. These runs retain exact sources and OS
/// receipts, but their extra observation is separate from latency acceptance.
@MainActor final class NotebookFirstPresentationSchedulingTests: XCTestCase {
  func testImmediatePresentationPolicyInTheActualScene() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let visible = scene.windows.filter { !$0.isHidden }
    let previousKey = visible.first(where: \.isKeyWindow)
    visible.forEach { $0.isHidden = true }
    let window = UIWindow(windowScene: scene)
    window.frame = scene.coordinateSpace.bounds
    let controller = UIViewController()
    controller.view.backgroundColor = .white
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer {
      window.isHidden = true; window.rootViewController = nil
      visible.forEach { $0.isHidden = false }; previousKey?.makeKey()
    }
    let dot = UIView(frame: .init(x: 80, y: 80, width: 20, height: 20))
    dot.backgroundColor = .black; controller.view.addSubview(dot)
    window.layoutIfNeeded()
    for sceneBound in [false, true] {
      let trace = NotebookSchedulingObservation(scene: scene)
      let policy = sceneBound ? UIUpdateLink(windowScene: scene) : UIUpdateLink(view: dot)
      var updates = 0
      var requestedDuringUpdates: [Bool] = []
      policy.addAction(to: .beforeCATransactionCommit) { link, info in
        updates += 1
        requestedDuringUpdates.append(link.wantsImmediatePresentation)
        dot.frame.origin.x = 80 + CGFloat(updates % 2)
        trace.record("control_commit", modelTime: info.modelTime,
          deadline: info.completionDeadlineTime, target: info.estimatedPresentationTime,
          immediate: info.isImmediatePresentationExpected, lowLatency: info.isPerformingLowLatencyPhases)
      }
      policy.requiresContinuousUpdates = true
      policy.wantsImmediatePresentation = true
      let requestBeforeEnabling = policy.wantsImmediatePresentation
      let rate = Float(scene.screen.maximumFramesPerSecond)
      policy.preferredFrameRateRange = .init(minimum: rate, maximum: rate, preferred: rate)
      policy.isEnabled = true
      let requestAfterEnabling = policy.wantsImmediatePresentation
      policy.wantsImmediatePresentation = true
      let requestAfterEnabledAssignment = policy.wantsImmediatePresentation
      let deadline = ContinuousClock.now + .seconds(2)
      while updates < 12, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
      let requestBeforeDisabling = policy.wantsImmediatePresentation
      policy.isEnabled = false; trace.stop()
      add(try trace.attachment(scenario: sceneBound ? "immediate-scene-control" : "immediate-view-control"))
      let context = "activation=\(scene.activationState.rawValue),scene=\(scene.coordinateSpace.bounds),window=\(window.frame),screen=\(scene.screen.bounds),key=\(window.isKeyWindow),visibleWindows=\(scene.windows.filter { !$0.isHidden }.count),lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled),thermal=\(ProcessInfo.processInfo.thermalState.rawValue),requestBeforeEnabling=\(requestBeforeEnabling),requestAfterEnabling=\(requestAfterEnabling),requestAfterEnabledAssignment=\(requestAfterEnabledAssignment),requestBeforeDisabling=\(requestBeforeDisabling),requestedDuringUpdates=\(requestedDuringUpdates)"
      let attachment = XCTAttachment(string: context)
      attachment.name = sceneBound ? "immediate-scene-context" : "immediate-view-context"
      attachment.lifetime = .keepAlways; add(attachment)
      XCTAssertGreaterThanOrEqual(updates, 12, context)
    }
  }

  func testColdProgramConstructorsAgainstUIOpportunities() async throws { try await cold(programs: true) }
  func testColdSVGExecutorsAgainstUIOpportunities() async throws { try await cold(programs: false) }

  private func cold(programs: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduling-cold-\(UUID())")
    let store = NotebookStore(root: root)
    try NotebookNavigationLoadFixture.seed(store, programs: programs)
    let index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
    let center = try XCTUnwrap(hierarchy.focusedCenter(of: NotebookNavigationLoadFixture.notebookID, in: index.rootBoardID))
    let page = try store.loadPage(XCTUnwrap(index.selectedPageID))
    try store.savePresence(.init(boardID: index.rootBoardID, mode: .page,
      camera: .init(center: center, scale: 1), viewport: .init(x: 834, y: 1194),
      focusedItemID: NotebookNavigationLoadFixture.notebookID, openProgress: 1,
      selectedItemID: NotebookNavigationLoadFixture.notebookID, notebookPageID: page.id))
    let sources = Dictionary(uniqueKeysWithValues: page.elements.filter { $0.kind == .web }
      .map { let source = agentElementSnapshotSource($0); return (source.id, SceneRasterSource.agent(source)) })
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let trace = NotebookSchedulingObservation(scene: scene)
    defer { trace.stop() }
    XCTAssertNil(NotebookNavigationObservation.onWebPreparation)
    XCTAssertNil(NotebookNavigationObservation.onSourceInstalled)
    let sourceClock = ContinuousClock.now, sourceUptime = CACurrentMediaTime()
    NotebookNavigationObservation.onWebPreparation = { stage, owner, source, at in
      let duration = sourceClock.duration(to: at).components
      trace.record(stage, at: sourceUptime + Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
        owner: owner.uuidString, source: source)
    }
    var installed = Set<String>(), first = false
    NotebookNavigationObservation.onSourceInstalled = { installation, at in
      guard let source = installation.source.agentElement, sources[source.id] == .agent(source),
        installation.requiresVisibility, installation.isInstalled else { return }
      let duration = sourceClock.duration(to: at).components
      let uptime = sourceUptime + Double(duration.seconds) + Double(duration.attoseconds) / 1e18
      if !first { first = true; trace.record("first_native_installed", at: uptime, source: source.id) }
      if programs && installation.runtimeToken == nil { return }
      if installed.insert(source.id).inserted { trace.record("source_native_installed", at: uptime, source: source.id) }
    }
    model.compositionTiles.onPreparationPhase = { owner, stage in
      trace.record("board_\(stage)", owner: owner.uuidString)
    }
    defer {
      NotebookNavigationObservation.onWebPreparation = nil
      NotebookNavigationObservation.onSourceInstalled = nil
      model.compositionTiles.onPreparationPhase = nil
    }
    trace.record("root_mount_requested")
    window.rootViewController = UIHostingController(rootView: NotebookRootView().environment(model))
    window.makeKeyAndVisible()
    let startup = Task { await model.start(pageSize: .init(width: 834, height: 1194)) }
    defer { startup.cancel() }
    let deadline = ContinuousClock.now + .seconds(5)
    while installed.count < sources.count, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    trace.record("measurement_completed")
    trace.stop()
    add(try trace.attachment(scenario: programs ? "cold24" : "coldSVG13"))
    XCTAssertEqual(trace.droppedEvents, 0)
    XCTAssertEqual(installed.count, sources.count)
    XCTAssertTrue(first)
    XCTAssertTrue(trace.events.contains { $0.stage == "ui_after_ca_commit" })
    if programs {
      var constructors = 0
      for event in trace.events.sorted(by: { $0.uptime < $1.uptime }) {
        if event.stage == "ui_complete" { constructors = 0 }
        if event.stage == "native_init_started" {
          constructors += 1
          XCTAssertLessThanOrEqual(constructors, 2, "A completed UI opportunity separates constructor batches")
        }
      }
    }
    await startup.value
  }

  func testFirstHeldDotAgainstUIAndOSBoundaries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduling-dot-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false,
      preferences: UserDefaults(suiteName: UUID().uuidString)!)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let workspace = try XCTUnwrap(model.workspace), viewport = SpatialPoint(x: 834, y: 1194)
    let center = model.boardHierarchy?.focusedCenter(of: workspace.selectedItemID, in: workspace.rootBoardID) ?? .zero
    model.updatePresence(.init(boardID: workspace.rootBoardID, mode: .page,
      camera: .init(center: center, scale: WorkspaceItemGeometry.notebook.fitScale(viewport: viewport)),
      viewport: viewport, focusedItemID: workspace.selectedItemID, openProgress: 1), settled: true)
    model.selectPenColor(.black); model.selectPenWidth(12)
    let window = try await mountNotebookScene(model)
    let scene = try NotebookInteractionUXTests.Scene(model: model, window: window)
    let canvas = try XCTUnwrap(scene.paper.superview as? PaperCanvasContainerView).inkView
    XCTAssertTrue(canvas.acceptedInkIsEmpty)
    XCTAssertTrue(canvas.frameReadiness?.isReady == true)
    let trace = NotebookSchedulingObservation(scene: try XCTUnwrap(window.windowScene))
    defer { trace.stop(); scene.endPencil() }
    var contact: InkCanvasView.ContactFrame?, shown = false
    canvas.onContactFrameResolved = { receipt in
      guard receipt.contact == contact else { return }
      let frame = receipt.frameID.uuidString
      trace.record(receipt.completion.isReady ? "ink_os_callback" : "ink_dropped_callback", owner: frame)
      if let time = receipt.completion.presentedTime { trace.record("ink_os_presented", at: time, owner: frame) }
      if let timing = receipt.timing {
        let phases: [(String, TimeInterval?)] = [
          ("ink_render", timing.renderBegan), ("ink_commit", timing.commitBegan),
          ("ink_commit_returned", timing.commitReturned), ("ink_scheduled", timing.scheduled),
          ("ink_transaction_present", timing.transactionPresented), ("ink_gpu_start", timing.gpuStarted),
          ("ink_gpu_end", timing.gpuEnded), ("ink_gpu_callback", timing.gpuCompletion),
          ("ink_low_latency_deferred", timing.lowLatencyDeferred),
          ("ink_low_latency_dispatched", timing.lowLatencyDispatched)
        ]
        for (stage, time) in phases {
          if let time { trace.record(stage, at: time, owner: frame, deadline: timing.targetDeadline, target: timing.targetPresentation) }
        }
        if let dispatched = timing.lowLatencyDispatched {
          trace.record("ink_low_latency_ui", at: dispatched, owner: frame,
            deadline: timing.lowLatencyUIDeadline, target: timing.lowLatencyUITarget, lowLatency: true)
        }
      }
      if receipt.completion.isReady { shown = true }
    }
    defer { canvas.onContactFrameResolved = nil }
    trace.record("contact_handler_enter")
    scene.beginPencil(.init(x: 180, y: 800))
    contact = try XCTUnwrap(canvas.activeContactFrame)
    trace.record("contact_handler_return")
    let deadline = ContinuousClock.now + .seconds(1)
    while !shown, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    trace.stop()
    add(try trace.attachment(scenario: "first-held-dot"))
    XCTAssertTrue(shown); XCTAssertEqual(trace.droppedEvents, 0)
    XCTAssertTrue(trace.events.contains { $0.stage == "ink_os_presented" })
    XCTAssertTrue(scene.paper.hasActiveAction)
    // Correctness of continued input is separate from the stopped first-frame
    // clock. A stationary contact must not keep encoding identical page pixels.
    let passes = canvas.pageActivePassCount
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(canvas.pageActivePassCount, passes)
    let initial = try XCTUnwrap(contact)
    shown = false
    scene.movePencil(.init(x: 220, y: 800))
    contact = try XCTUnwrap(canvas.activeContactFrame)
    XCTAssertEqual(contact?.sourceID, initial.sourceID)
    XCTAssertGreaterThan(try XCTUnwrap(contact).revision, initial.revision)
    let nextDeadline = ContinuousClock.now + .seconds(1)
    while !shown, ContinuousClock.now < nextDeadline { try await Task.sleep(for: .milliseconds(1)) }
    XCTAssertTrue(shown, "The next measured sample must resume the parked page clock")
  }

  func testFirstCurlAgainstUIAndOSBoundaries() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController(), commands = NotebookPageNavigation(), owner = UUID()
    var frames: [Int: PageTurnFrame] = [:]
    for index in 0..<2 {
      frames[index] = try await PageTurnFrameFixture.artwork(index: index, size: .init(width: 834, height: 1194))
    }
    var selected = 0
    func configure() {
      controller.update(ownerID: owner, sequenceRevision: "scheduling-curl", pageCount: 2, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, _, ready in
          ready.setFrameProvider { _ in try XCTUnwrap(frames[index]) }; ready(true)
          return AnyView(Color.white.overlay { (index == 0 ? Color.blue : Color.red).frame(width: 400, height: 400) })
        }, onCommit: { index, _ in selected = index; configure() },
        onTransitioningChange: { _ in }, notebookNavigation: commands)
    }
    configure(); window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer {
      controller.sheetController.cancelMotion()
      window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
    window.layoutIfNeeded()
    let curl = try XCTUnwrap(controller.sheetController.view.subviews.compactMap { $0 as? SheetCurlMetalView }.first)
    let trace = NotebookSchedulingObservation(scene: scene)
    defer { trace.stop() }
    let previousReadiness = curl.onPageFrameReady
    var shown = false
    curl.onPageUpdateMeasured = { timing in
      trace.record("curl_\(timing.phase.rawValue)", at: timing.recorded,
        owner: timing.operationID.uuidString, source: String(timing.nextSequence), modelTime: timing.modelTime,
        deadline: timing.completionDeadline, target: timing.estimatedPresentation,
        immediate: timing.immediatePresentationExpected, lowLatency: timing.performingLowLatencyPhases)
    }
    curl.onFrameMeasured = { timing in
      let phases: [(String, TimeInterval?)] = [
        ("curl_clock_request", timing.clockRequested), ("curl_update_received", timing.displayUpdateReceived),
        ("curl_encode", timing.encodingBegan), ("curl_submit", timing.submitted),
        ("curl_scheduled", timing.scheduled), ("curl_gpu_start", timing.gpuBegan), ("curl_gpu_end", timing.gpuEnded)
      ]
      for (stage, time) in phases {
        if let time { trace.record(stage, at: time, owner: timing.operationID?.uuidString, source: String(timing.sequence),
          deadline: timing.renderingDeadline, target: timing.targetPresentation) }
      }
    }
    curl.onPageFrameReady = { frame, progress, sequence, readiness in
      trace.record(readiness.isReady ? "curl_os_callback" : "curl_dropped_callback", source: String(sequence))
      if let time = readiness.presentedTime { trace.record("curl_os_presented", at: time, source: String(sequence)) }
      if readiness.isReady, progress > 0, progress < 1 { shown = true }
      previousReadiness?(frame, progress, sequence, readiness)
    }
    defer {
      curl.onPageFrameReady = previousReadiness
      curl.onPageUpdateMeasured = nil; curl.onFrameMeasured = nil
    }
    trace.record("curl_command_enter")
    XCTAssertTrue(commands.send(.step(1), ownerID: owner, source: "scheduling-curl"))
    trace.record("curl_command_return")
    let deadline = ContinuousClock.now + .seconds(2)
    while selected != 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    trace.record("curl_owner_landed")
    trace.stop()
    add(try trace.attachment(scenario: "first-curl"))
    XCTAssertEqual(selected, 1); XCTAssertTrue(shown); XCTAssertEqual(trace.droppedEvents, 0)
    XCTAssertTrue(trace.events.contains { $0.stage == "curl_os_presented" })
  }
}
