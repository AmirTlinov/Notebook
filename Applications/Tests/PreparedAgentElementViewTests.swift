import NotebookCore
import SwiftUI
import UIKit
import Vision
import WebKit
import XCTest

@testable import Notebook

final class PreparedAgentElementViewTests: XCTestCase {
  @MainActor
  func testQueuedStateAndDensityChangeCannotRewindAcceptedProgramInput() async throws {
    let resources = SceneRenderResources()
    let lease = try await resources.acquireWebSurface(priority: .liveProgram)
    var states: [JSONValue] = [], ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onRenderReady: { ready = $0 }, onState: { states.append($0); return true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(web); web.frame = .init(x: 100, y: 100, width: 240, height: 120)
    defer {
      coordinator.invalidate(); lease.release(); web.removeFromSuperview()
      window.isHidden = true; window.rootViewController = nil
    }
    let original = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 240, height: 120), source: "Input reconciliation",
      html: "<input id='text'>", javaScript: """
        const input=document.getElementById('text');
        addEventListener('notebookstate',()=>{if(input.value!==notebook.state)input.value=notebook.state});
        window.enter=value=>{input.value=value;notebook.commit(value)};
        notebook.ready(Promise.resolve());
        """, state: .string(""))
    coordinator.load(original, policy: .exact(scale: 1), in: web)
    try await waitUntil("The real program is installed") { ready }
    let token = coordinator.loadToken
    _ = try await web.evaluateJavaScript("document.getElementById('text').focus();enter('accepted');document.getElementById('text').setSelectionRange(2,5);true")
    try await waitUntil("The first input is accepted natively") { states.count == 1 }
    XCTAssertFalse(coordinator.hasLiveSource(original), "The old source cannot certify the new pixels")
    coordinator.load(original, policy: .exact(scale: 2), in: web)
    let unchanged = try await web.evaluateJavaScript("document.getElementById('text').value") as? String
    XCTAssertEqual(unchanged, "accepted", "Density is not authority to restore the old persisted state")
    let echoed = original.updating(state: .string("accepted"))
    coordinator.load(echoed, in: web)
    try await waitUntil("The current persisted echo obtains its own raster") { ready && coordinator.hasLiveSource(echoed) }
    let selection = try await web.evaluateJavaScript("[document.activeElement.id,document.activeElement.selectionStart,document.activeElement.selectionEnd].join(':')") as? String
    XCTAssertEqual(selection, "text:2:5", "A local echo must not rewrite a focused field")

    _ = try await web.evaluateJavaScript("""
      window.actualProgram=window.notebookProgram;
      window.notebookProgram={...window.actualProgram,apply:async(value,revision)=>{
        await new Promise(resolve=>window.releaseApply=resolve);
        return window.actualProgram.apply(value,revision);
      }};true;
      """)
    let obsolete = echoed.updating(state: .string("obsolete native application"))
    coordinator.load(obsolete, in: web)
    var isWaiting = false
    let deadline = ContinuousClock.now + .seconds(5)
    while !isWaiting, ContinuousClock.now < deadline {
      isWaiting = try await web.evaluateJavaScript("typeof window.releaseApply==='function'") as? Bool == true
      if !isWaiting { await Task.yield() }
    }
    XCTAssertTrue(isWaiting)
    _ = try await web.evaluateJavaScript("enter('accepted newest');window.releaseApply();true")
    try await waitUntil("The later input crosses the native bridge") { states.count == 2 }
    let newest = try await web.evaluateJavaScript("document.getElementById('text').value") as? String
    XCTAssertEqual(newest, "accepted newest")
    XCTAssertFalse(coordinator.hasLiveSource(obsolete), "The old JS callback must not publish an installed-state proof")
    let current = original.updating(state: .string("accepted newest"))
    coordinator.load(current, in: web)
    try await waitUntil("The latest accepted value is installed without replay") { ready && coordinator.hasLiveSource(current) }
    _ = try await web.evaluateJavaScript("window.notebookProgram=window.actualProgram;true")
    let remote = current.updating(state: .string("new independent state"))
    coordinator.load(remote, in: web)
    try await waitUntil("A genuinely later external state still applies") { ready && coordinator.hasLiveSource(remote) }
    let remoteValue = try await web.evaluateJavaScript("document.getElementById('text').value") as? String
    XCTAssertEqual(remoteValue, "new independent state")
    XCTAssertEqual(states, [.string("accepted"), .string("accepted newest")])
    XCTAssertEqual(coordinator.loadToken, token)
  }

  @MainActor
  func testUpdatingAnInstalledRuntimeDoesNotRepublishItsReadiness() async throws {
    let resources = SceneRenderResources(), source = element(id: UUID().uuidString, source: "Stable readiness")
    let lease = try await resources.acquireWebSurface(priority: .liveProgram)
    var reports: [Bool] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onRenderReady: { reports.append($0) }, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(web); web.frame = .init(x: 100, y: 100, width: 160, height: 120)
    defer {
      coordinator.invalidate(); lease.release(); web.removeFromSuperview()
      window.isHidden = true; window.rootViewController = nil
    }
    coordinator.load(source, policy: .exact(scale: 2), in: web)
    try await waitUntil("The real capture and input installation finish") {
      reports.last == true && coordinator.installation(for: source)?.isInstalled == true
        && coordinator.pendingSnapshotCaptures.isEmpty
    }
    let count = reports.count, token = coordinator.loadToken
    for _ in 0..<40 {
      // updateUIView replaces closures, not the physical preparation request.
      coordinator.use(onRenderReady: { reports.append($0) })
      coordinator.load(source, policy: .exact(scale: 2), in: web)
    }
    let moved = source.updating(frame: .init(x: 400, y: 200, width: 160, height: 120))
    coordinator.load(moved, policy: .exact(scale: 2), in: web)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(reports.count, count, "Representable refresh must not turn readiness into a self-sustaining render loop")
    let changed = moved.updating(state: .number(1))
    coordinator.load(changed, policy: .exact(scale: 2), in: web)
    try await waitUntil("A genuine state transition still captures and publishes readiness") {
      reports.count > count && reports.last == true && coordinator.installation(for: changed)?.isInstalled == true
        && coordinator.pendingSnapshotCaptures.isEmpty
    }
    XCTAssertTrue(reports.dropFirst(count).contains(false))
    XCTAssertEqual(coordinator.loadToken, token, "Neither placement nor state restarts the program")
  }

  func testSourceFailureScopeSurvivesPlacementButRejectsNewCapturePolicyAndState() {
    let source = element(id: "failure-scope", source: "Failure scope")
    let demand = SceneSourceDemand(source: source, minimumScale: 2, region: .init(x: 0, y: 0, width: 80, height: 60))
    let capture = SceneSourceFailure(demand: demand, message: "preparation_timeout", captureSpecific: true)
    let moved = source.updating(frame: .init(x: 300, y: 0, width: source.frame.width, height: source.frame.height))
    let placement = SceneSourceDemand(source: moved, minimumScale: 2, region: demand.region,
      worldOrigin: .zero.offsetBy(x: 1000, y: 2000))
    XCTAssertTrue(capture.matches(placement), "World placement is not a different capture attempt")
    let newDensity = SceneSourceDemand(source: source, minimumScale: 3, region: demand.region)
    let newCrop = SceneSourceDemand(source: source, minimumScale: 2, region: .init(x: 40, y: 30, width: 80, height: 60))
    XCTAssertFalse(capture.matches(newDensity))
    XCTAssertFalse(capture.matches(newCrop))
    let changed = source.updating(state: .number(1))
    XCTAssertFalse(capture.matches(.init(source: changed, minimumScale: 2, region: demand.region)))
    let program = SceneSourceFailure(demand: demand, message: "render_error", captureSpecific: false)
    XCTAssertTrue(program.matches(newDensity), "Changing density cannot retry an unchanged failed program")
    XCTAssertTrue(program.matches(newCrop))
  }

  func testCaptureReadmissionRequiresWholeRequestAndRecognizesCountOnlyRecovery() {
    let source = element(id: "capture-admission", source: "Capture admission")
    func admission(bytes: Int, count: Int) -> SceneRasterAdmission {
      .init(pinnedBytes: 0, reservedBytes: 1_000_000 - bytes, pinnedCount: 0,
        reservedCount: 10 - count, byteLimit: 1_000_000, countLimit: 10,
        passiveReservedBytes: 1_000_000 - bytes, passiveByteLimit: 1_000_000)
    }
    let policy = AgentSnapshotPolicy.exact(scale: 2)
    XCTAssertFalse(AgentWebSourceFailure.captureFitsAfterImprovement(source: source, policy: policy,
      previous: admission(bytes: 65_536, count: 1), current: admission(bytes: 65_537, count: 1)))
    XCTAssertFalse(AgentWebSourceFailure.captureFitsAfterImprovement(source: source, policy: policy,
      previous: admission(bytes: 65_536, count: 0), current: admission(bytes: 1_000_000, count: 0)))
    XCTAssertTrue(AgentWebSourceFailure.captureFitsAfterImprovement(source: source, policy: policy,
      previous: admission(bytes: 1_000_000, count: 0), current: admission(bytes: 1_000_000, count: 1)))
  }

  @MainActor
  func testReadyRuntimeRetriesItsCaptureOnlyAfterWholeRasterAdmissionRecovers() async throws {
    let model = makeModel(), resources = SceneRenderResources.shared
    let source = element(id: UUID().uuidString, source: "A running control survives snapshot pressure")
    let focus = InteractiveElementReference.page(pageID: UUID(), elementID: source.id)
    var ready = false
    func content(scale: Double) -> AnyView {
      AnyView(PreparedAgentElementView(element: source, allowsInteraction: true, capturePolicy: .exact(scale: scale),
        focus: focus, onRenderReady: { ready = $0 }, onState: { _ in false })
        .frame(width: 160, height: 120).environment(model))
    }
    let host = try SurfaceHost(content: content(scale: 2)); defer { host.close() }
    try await waitUntil("The actual control is ready before raster pressure") {
      ready && self.webViews(in: host.controller.view).count == 1
    }
    let web = try XCTUnwrap(webViews(in: host.controller.view).first)
    let coordinator = try XCTUnwrap(web.navigationDelegate as? AgentWebCoordinator)
    let navigation = try XCTUnwrap(coordinator.loadToken)
    let admission = resources.rasterAdmission
    let available = min(admission.byteLimit - admission.heldBytes,
      admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(available - 72 * 1024, priority: .passive))
    let insufficientRelease = try XCTUnwrap(resources.reserveDerivedBytes(8 * 1024, priority: .passive))
    defer { pressure.release(); insufficientRelease.release() }
    host.controller.rootView = content(scale: 3)
    try await waitUntil("A real higher-density capture reaches resource_limit while its control stays installed") {
      resources.diagnostics(for: [source]).contains { $0.kind == "resource_limit" }
        && coordinator.installation(for: source)?.isInstalled == true
    }
    let refusal = resources.lastRasterRefusal?.generation
    insufficientRelease.release()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(resources.lastRasterRefusal?.generation, refusal,
      "A small unrelated release cannot trigger another impossible capture")
    XCTAssertTrue(webViews(in: host.controller.view).first === web)
    XCTAssertEqual(coordinator.loadToken, navigation)
    XCTAssertTrue(coordinator.installation(for: source)?.isInstalled == true)
    pressure.release()
    try await waitUntil("Full recovered admission recaptures the same running program at its latest density") {
      ready && resources.image(for: source, minimumScale: 3) != nil
    }
    XCTAssertTrue(webViews(in: host.controller.view).first === web)
    XCTAssertEqual(coordinator.loadToken, navigation, "Capture refinement cannot restart JavaScript")
  }

  @MainActor
  func testRetiredBoardCaptureRemountKeepsItsAdmissionBaselineAndResumesStationary() async throws {
    let model = makeModel(), resources = SceneRenderResources.shared
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID), id = UUID().uuidString
    let address = SceneSourceAddress(plane: .board(boardID), elementID: id)
    let focus = InteractiveElementReference.board(boardID: boardID, elementID: id)
    func saveState(_ state: JSONValue) async throws -> AgentElement {
      let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
      var after = before
      let value = SpatialElement(id: id, surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 160, height: 120), worldOrigin: .zero,
        source: "Capture debt survives a native consumer remount",
        html: "<svg width='160' height='120'><rect x='20' y='20' width='120' height='80' fill='red'/></svg>",
        javaScript: "const paint=()=>document.querySelector('rect').setAttribute('fill',notebook.state===1?'blue':'red');paint();window.addEventListener('notebookstate',paint);notebook.ready(Promise.resolve());",
        state: state, stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(after.upsertElement(value, in: boardID,
        expected: before.board(boardID)?.elements.first(where: { $0.id == id })?.stamp, actor: model.actorID))
      _ = try model.store.saveBoardEdits(before: before, after: after)
      await model.reloadExternalChanges()?.value
      return agentElementSnapshotSource(try XCTUnwrap(after.board(boardID)?.elements.first(where: { $0.id == id })))
    }
    _ = try await saveState(.number(0))
    model.updatePresence(.init(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 80, y: 60), scale: 1), viewport: .init(x: 512, y: 512)), settled: true)
    let firstWindow = try await mountNotebookScene(model)
    try await waitUntil("The real source is prepared before pressure and native remount") {
      model.compositionTiles.published?.hasInstalledPixels(for: address) == true && self.webViews(in: firstWindow).count == 1
    }
    let admission = resources.rasterAdmission
    let available = min(admission.byteLimit - admission.heldBytes,
      admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(available - 64 * 1024, priority: .passive))
    defer { pressure.release() }
    let changed = try await saveState(.number(1))
    func captureFailure() -> AgentWebSourceFailure? {
      guard let policy = model.compositionTiles.published?.sourceReceipts[address]?.demand.policy else { return nil }
      return model.compositionTiles.runtimeFailure(at: address, source: changed, policy: policy)
    }
    try await waitUntil("The mounted real runtime reports its failed capture and admission to composition") {
      captureFailure()?.diagnostic.kind == "resource_limit"
    }
    let failure = try XCTUnwrap(captureFailure())
    XCTAssertNotNil(failure.rasterAdmission)
    let failedAdmission = try XCTUnwrap(resources.webActivity(for: focus).lastAdmission)
    firstWindow.isHidden = true; firstWindow.rootViewController = nil
    try await waitUntil("The original consumer and its final physical borrow are retired") {
      resources.webActivity(for: focus).activeLeaseCount == 0
    }
    let secondWindow = try await mountNotebookScene(model)
    XCTAssertEqual(captureFailure(), failure, "Remount cannot discard or invent a failed attempt's baseline")
    XCTAssertTrue(webViews(in: secondWindow).isEmpty)
    XCTAssertEqual(resources.webActivity(for: focus).lastAdmission, failedAdmission)
    pressure.release()
    try await waitUntil("Released capacity refines the stationary remounted source through its physical owner") {
      captureFailure() == nil && model.compositionTiles.published?.sourceReceipts[address]?.demand.source == changed
        && model.compositionTiles.published?.hasInstalledPixels(for: address) == true && self.webViews(in: secondWindow).count == 1
    }
    XCTAssertNotEqual(resources.webActivity(for: focus).lastAdmission, failedAdmission)
  }

  @MainActor
  func testQueuedReadyCannotPublishAfterItsCurrentCaptureHasFailed() async throws {
    let resources = SceneRenderResources(), source = element(id: UUID().uuidString, source: "Queued native readiness")
    let policy = AgentSnapshotPolicy.exact(scale: 2)
    let lease = try await resources.acquireWebSurface(priority: .visible)
    var becameReady = false, failureIssued = false
    var afterFailureReadiness: [Bool] = [], failures: [AgentWebSourceFailure] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: policy,
      onRenderReady: { value in
        if value { becameReady = true }
        if failureIssued { afterFailureReadiness.append(value) }
      }, onFailure: { failures.append($0) }, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(web); web.frame = .init(x: 100, y: 100, width: 160, height: 120)
    defer {
      coordinator.invalidate(); lease.release(); web.removeFromSuperview()
      window.isHidden = true; window.rootViewController = nil
    }
    coordinator.load(source, policy: policy, in: web)
    try await waitUntil("The real native program has finished its first capture and is live") {
      becameReady && coordinator.installation(for: source)?.isInstalled == true
        && coordinator.pendingSnapshotCaptures.isEmpty
    }
    let prior = try XCTUnwrap(resources.retainRaster(for: .agent(source), minimumScale: 2))
    defer { prior.release() }
    let token = try XCTUnwrap(coordinator.loadToken)
    // A lower-density demand can use the real pixels already captured from
    // this unchanged DOM. Follow pixel completion immediately with failure;
    // a queued readiness callback must not outlive that failure.
    let currentPolicy = AgentSnapshotPolicy.exact(scale: 1)
    coordinator.load(source, policy: currentPolicy, in: web)
    await coordinator.completeSnapshot(prior.image, error: nil, token: token, element: source,
      reservation: try XCTUnwrap(resources.reserveWebSnapshot(pixelSize: .init(width: 320, height: 240))), policy: currentPolicy)
    let queued = try XCTUnwrap(resources.retainRaster(for: .agent(source), minimumScale: 2))
    defer { queued.release() }
    await coordinator.completeSnapshot(nil, error: NSError(domain: "CurrentNativeCapture", code: 1),
      token: token, element: source,
      reservation: try XCTUnwrap(resources.reserveWebSnapshot(pixelSize: .init(width: 320, height: 240))), policy: currentPolicy)
    failureIssued = true
    try await waitUntil("The current failed capture delivers failure and false readiness") {
      failures.count == 1 && afterFailureReadiness.contains(false)
    }
    XCTAssertFalse(afterFailureReadiness.contains(true),
      "A ready event queued before the current failure cannot acknowledge readiness after it")
    XCTAssertEqual(failures.first?.policy, currentPolicy)
    XCTAssertEqual(failures.first?.loadToken, token)
    XCTAssertTrue(coordinator.installation(for: source)?.isInstalled == true,
      "A capture failure cannot revoke the healthy live control")
    let current = try XCTUnwrap(resources.retainRaster(for: .agent(source), minimumScale: 2))
    defer { current.release() }
    XCTAssertEqual(current.entryID, queued.entryID,
      "Rejecting stale readiness does not discard legitimate pixels captured before the failure")
    let attachment = XCTAttachment(string: "afterFailureReadiness=\(afterFailureReadiness), queuedEntry=\(queued.entryID), retainedEntry=\(current.entryID), navigation=\(token)")
    attachment.name = "Actual ready runtime with deterministic capture-failure callback ordering"
    attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testSnapshotFailureKeepsSubmittedPolicyAndCannotFailRetargetedDemand() async throws {
    let resources = SceneRenderResources(), source = element(id: UUID().uuidString, source: "Retargeted capture")
    let lease = try await resources.acquireWebSurface(priority: .visible)
    var failures: [AgentWebSourceFailure] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onFailure: { failures.append($0) }, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    defer { coordinator.invalidate(); lease.release() }
    let first = AgentSnapshotPolicy.region(.init(x: 0, y: 0, width: 80, height: 60), scale: 1)
    let latest = AgentSnapshotPolicy.region(.init(x: 40, y: 30, width: 80, height: 60), scale: 2)
    coordinator.load(source, policy: first, in: web)
    let token = try XCTUnwrap(coordinator.loadToken)
    coordinator.load(source, policy: latest, in: web)
    XCTAssertEqual(coordinator.loadToken, token, "A crop change must retain the same JS navigation")
    let error = NSError(domain: "NativeSubmittedSnapshot", code: 1)
    await coordinator.completeSnapshot(nil, error: error, token: token, element: source,
      reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 80, pixelHeight: 60)), policy: first)
    XCTAssertNil(coordinator.snapshotFailure, "The old capture cannot mark the newest demand failed")
    XCTAssertTrue(resources.diagnostics(for: [source]).isEmpty)
    await coordinator.completeSnapshot(nil, error: error, token: token, element: source,
      reservation: try XCTUnwrap(resources.reserveRaster(pixelWidth: 160, pixelHeight: 120)), policy: latest)
    try await waitUntil("The current failed capture delivers its original typed identity") { failures.count == 1 }
    XCTAssertEqual(failures.first?.source, source)
    XCTAssertEqual(failures.first?.leaseID, lease.id)
    XCTAssertEqual(failures.first?.loadToken, token)
    XCTAssertEqual(failures.first?.policy, latest)
    XCTAssertEqual(resources.diagnostics(for: [source]).map(\.kind), ["snapshot_error"])
  }

  @MainActor
  func testRejectedNativeProgramPublishesItsSourceFailureWhileRetainingPriorPixels() async throws {
    let model = makeModel(), resources = SceneRenderResources.shared
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID), id = UUID().uuidString
    let address = SceneSourceAddress(plane: .board(boardID), elementID: id)
    func saveProgram(rejects: Bool) async throws -> AgentElement {
      let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
      var after = before
      let value = SpatialElement(id: id, surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 160, height: 120), worldOrigin: .zero,
        source: rejects ? "Rejected source" : "Working source",
        html: "<svg width='160' height='120'><rect x='20' y='20' width='120' height='80' fill='red'/></svg>",
        javaScript: rejects ? "window.notebook.ready(Promise.reject(new Error('Native acceptance readiness failure')));" : "window.notebook.ready(Promise.resolve());",
        stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(after.upsertElement(value, in: boardID,
        expected: before.board(boardID)?.elements.first(where: { $0.id == id })?.stamp, actor: model.actorID))
      _ = try model.store.saveBoardEdits(before: before, after: after)
      await model.reloadExternalChanges()?.value
      return agentElementSnapshotSource(try XCTUnwrap(after.board(boardID)?.elements.first(where: { $0.id == id })))
    }
    let healthy = try await saveProgram(rejects: false)
    model.updatePresence(.init(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 80, y: 60), scale: 1), viewport: .init(x: 512, y: 512)), settled: true)
    let activityReference = InteractiveElementReference.board(boardID: boardID, elementID: id)
    let window = try await mountNotebookScene(model)
    try await waitUntil("The sole admitted native program publishes and physically installs its ordinary snapshot") {
      model.compositionTiles.published?.runtimeOwners == [address]
        && model.compositionTiles.published?.hasInstalledPixels(for: address) == true
        && self.webViews(in: window).count == 1
    }
    let original = try XCTUnwrap(model.compositionTiles.published?.sourceRasters[address]?.retainedCopy())
    defer { original.release() }
    XCTAssertEqual(original.source.agentElement, healthy)
    let rejected = try await saveProgram(rejects: true)
    try await waitUntil("The actual public readiness Promise rejects and its hidden WK retires", diagnostic: {
      "diagnostics=\(resources.diagnostics(for: [rejected])), active=\(resources.webActivity(for: activityReference)), mounted=\(self.webViews(in: window).count), basis=\(String(describing: model.programStateBasis(focus: activityReference, rendered: rejected)))"
    }) {
      resources.diagnostics(for: [rejected]).contains { $0.kind == "program_ready_error" }
        && self.webViews(in: window).isEmpty && resources.webActivity(for: activityReference).activeLeaseCount == 0
    }
    try await waitUntil("The composition owner publishes the exact source's terminal failure instead of pending forever") {
      guard let receipt = model.compositionTiles.published?.sourceReceipts[address],
        receipt.demand.source == rejected else { return false }
      if case .failed(let diagnostic) = receipt.status { return diagnostic.contains("program_ready_error") }
      return false
    }
    XCTAssertFalse(model.compositionTiles.published?.sourceReceipts[address]?.hasCurrentPixels == true)
    XCTAssertTrue(rasterViews(in: window).contains { $0.installation(for: original).isInstalled },
      "A source failure keeps the actual predecessor pixels behind its local error")
    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    })
    attachment.name = "Rejected native program retains previous red SVG and shows its local error"
    attachment.lifetime = .keepAlways; add(attachment)
    let admission = try XCTUnwrap(resources.webActivity(for: activityReference).lastAdmission)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(resources.webActivity(for: activityReference).lastAdmission, admission, "A terminal failure cannot retry merely because its own WK retired")
    let policy = try XCTUnwrap(model.compositionTiles.published?.sourceReceipts[address]?.demand.policy)
    let firstFailure = try XCTUnwrap(model.compositionTiles.runtimeFailure(at: address, source: rejected, policy: policy))
    model.compositionTiles.retrySource(address)
    try await waitUntil("An explicit owner retry runs the actual rejecting Promise in exactly one new native attempt") {
      guard let failure = model.compositionTiles.runtimeFailure(at: address, source: rejected, policy: policy) else { return false }
      return failure.leaseID != firstFailure.leaseID && self.webViews(in: window).isEmpty
        && resources.webActivity(for: activityReference).activeLeaseCount == 0
    }
    _ = try await saveProgram(rejects: false)
    try await waitUntil("Accepted new source replaces the failure and mounts its functioning native program") {
      model.compositionTiles.published?.sourceReceipts[address]?.demand.source == healthy
        && model.compositionTiles.published?.hasInstalledPixels(for: address) == true
        && self.webViews(in: window).count == 1
    }
    XCTAssertFalse(model.compositionTiles.failRuntimeSource(address, failure: firstFailure),
      "Replaying the real old completion after a newer native source cannot restore its terminal failure")
    XCTAssertTrue(model.compositionTiles.published?.sourceReceipts[address]?.hasCurrentPixels == true)
  }

  @MainActor
  func testReadyProgramTerminationDelegateRevokesItsLiveSurfaceAndKeepsRetryVisible() async throws {
    let model = makeModel(), resources = SceneRenderResources.shared
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID), id = UUID().uuidString
    let address = SceneSourceAddress(plane: .board(boardID), elementID: id)
    let focus = InteractiveElementReference.board(boardID: boardID, elementID: id)
    func saveProgram() async throws -> AgentElement {
      let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
      var after = before
      let value = SpatialElement(id: id, surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 160, height: 120), worldOrigin: .zero,
        source: "A ready program can terminate",
        html: "<button id='control'>Working control</button><svg width='160' height='80'><rect width='160' height='80' fill='red'/></svg>",
        stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(after.upsertElement(value, in: boardID,
        expected: before.board(boardID)?.elements.first(where: { $0.id == id })?.stamp, actor: model.actorID))
      _ = try model.store.saveBoardEdits(before: before, after: after)
      await model.reloadExternalChanges()?.value
      return agentElementSnapshotSource(try XCTUnwrap(after.board(boardID)?.elements.first(where: { $0.id == id })))
    }
    let healthy = try await saveProgram()
    model.updatePresence(.init(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 80, y: 60), scale: 1), viewport: .init(x: 512, y: 512)), settled: true)
    let window = try await mountNotebookScene(model)
    try await waitUntil("The real native control has a ready live installation") {
      model.compositionTiles.published?.hasInstalledPixels(for: address) == true && self.webViews(in: window).count == 1
    }
    let web = try XCTUnwrap(webViews(in: window).first)
    weak let coordinator: AgentWebCoordinator? = try XCTUnwrap(web.navigationDelegate as? AgentWebCoordinator)
    let timelineStart = ContinuousClock.now
    var timeline: [String] = [], lastObservation: String?
    func observe(_ phase: String) {
      let current = self.webViews(in: window).first?.navigationDelegate as? AgentWebCoordinator
      let cached = resources.retainRaster(for: .agent(healthy))
      defer { cached?.release() }
      let cohort = model.compositionTiles.published?.sourceRasters[address]
      let receipt = model.compositionTiles.published?.sourceReceipts[address]
      let value = "phase=\(phase), token=\(String(describing: current?.loadToken)), liveInstalled=\(current?.installation(for: healthy)?.isInstalled == true), "
        + "cacheEntry=\(String(describing: cached?.entryID)), cohortEntry=\(String(describing: cohort?.entryID)), "
        + "pendingCaptures=\(current?.pendingSnapshotCaptures.map(\.id) ?? []), "
        + "cohortRasterVisible=\(cohort.map { raster in self.rasterViews(in: window).contains { $0.installation(for: raster).isInstalled } } == true), "
        + "status=\(String(describing: receipt?.status)), installedState=\(String(describing: receipt?.installedSource?.state))"
      if value != lastObservation, timeline.count < 96 {
        timeline.append("\(timelineStart.duration(to: .now)): " + value); lastObservation = value
      }
    }
    defer {
      let attachment = XCTAttachment(string: timeline.joined(separator: "\n"))
      attachment.name = "Observed native capture and cohort timeline around recovered runtime termination"
      attachment.lifetime = .keepAlways; add(attachment)
    }
    observe("initial-live")
    // Exercise the public process-death delegate against a real loaded WK.
    // This is a delegate lifecycle contract, not an actual OS process kill.
    for _ in 0..<2 {
      let previousNavigation = coordinator?.loadToken
      let precedingCapture = SceneRenderResources.shared.retainRaster(for: .agent(healthy))
      let precedingCaptureID = precedingCapture?.entryID
      precedingCapture?.release()
      observe("before-recoverable-termination")
      coordinator?.webViewWebContentProcessDidTerminate(web)
      observe("after-recoverable-termination")
      try await waitUntil("A recovered real WK becomes installed and completes its own new capture") {
        observe("await-recovered-live-and-capture")
        let completed = resources.retainRaster(for: .agent(healthy), minimumScale: 2)
        defer { completed?.release() }
        return coordinator?.loadToken != previousNavigation
          && coordinator?.installation(for: healthy)?.isInstalled == true
          && coordinator?.pendingSnapshotCaptures.isEmpty == true
          && completed != nil && completed?.entryID != precedingCaptureID
      }
      XCTAssertTrue(webViews(in: window).first === web)
    }
    let installation = try XCTUnwrap(coordinator?.installation(for: healthy))
    let navigation = try XCTUnwrap(coordinator?.loadToken)
    XCTAssertTrue(installation.isInstalled)
    observe("before-current-installed-frame-capture")
    // The live owner can have completed a newer frame than the passive cohort.
    // Capture the physically installed current runtime through its normal API;
    // this exact immutable entry, not cache existence, is the failure baseline.
    let captured = try await AgentWebCoordinator.captureCurrent(focus: focus, element: healthy, resources: resources)
    let original = try XCTUnwrap(captured)
    defer { original.release() }
    XCTAssertTrue(installation.isInstalled)
    XCTAssertEqual(coordinator?.loadToken, navigation, "Reading the installed frame cannot reload its program")
    XCTAssertEqual(original.source, .agent(healthy))
    observe("before-terminal-failure")
    coordinator?.webViewWebContentProcessDidTerminate(web)
    observe("after-terminal-failure-synchronously")
    try await waitUntil("Terminal process-death callback retires the previously ready WK") {
      observe("await-terminal-retirement")
      return resources.diagnostics(for: [healthy]).contains { $0.kind == "web_process_terminated" }
        && self.webViews(in: window).isEmpty && resources.webActivity(for: focus).activeLeaseCount == 0
    }
    XCTAssertFalse(installation.isInstalled, "A terminal source failure revokes the old live presentation proof")
    XCTAssertFalse(coordinator?.hasLiveSource(healthy) == true, "A failed program cannot keep accepting input")
    let policy = try XCTUnwrap(model.compositionTiles.published?.sourceReceipts[address]?.demand.policy)
    let failure = try XCTUnwrap(model.compositionTiles.runtimeFailure(at: address, source: healthy, policy: policy))
    XCTAssertNil(failure.policy, "This is a terminal runtime error, not snapshot pressure")
    XCTAssertEqual(failure.loadToken, navigation, "The terminal callback belongs to the last successfully recovered navigation")
    try await waitUntil("The failed recovered runtime publishes a failed source receipt while retaining installed history") {
      guard let receipt = model.compositionTiles.published?.sourceReceipts[address], receipt.demand.source == healthy else { return false }
      if case .failed(let message) = receipt.status { return message.contains("web_process_terminated") }
      return false
    }
    try await waitUntil("Its exact preceding raster is physically shown", diagnostic: {
      self.retainedFailureDiagnostic(window: window, original: original,
        cohort: model.compositionTiles.published?.sourceRasters[address],
        receipt: model.compositionTiles.published?.sourceReceipts[address])
    }) {
      observe("await-exact-fallback")
      return self.rasterViews(in: window).contains { $0.installation(for: original).isInstalled }
    }
    let pixels = try assertVisibleFailureAndRetry(in: window)
    let attachment = XCTAttachment(image: pixels)
    attachment.name = "Terminal process-death delegate after real readiness exposes retained pixels and Retry"
    attachment.lifetime = .keepAlways; add(attachment)
  }

  @MainActor
  func testStateReplacementReportsRealProgramFailureWithoutRestartingReadyRuntime() async throws {
    let model = makeModel(), resources = SceneRenderResources.shared
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    model.moveItem(try XCTUnwrap(model.workspace?.selectedItemID), to: .init(x: 100_000, y: 100_000))
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let boardID = try XCTUnwrap(model.workspace?.rootBoardID), id = UUID().uuidString
    let address = SceneSourceAddress(plane: .board(boardID), elementID: id)
    let focus = InteractiveElementReference.board(boardID: boardID, elementID: id)
    func saveState(fails: Bool) async throws -> AgentElement {
      let before = try model.store.loadBoard(items: try XCTUnwrap(model.workspace).items)
      var after = before
      let value = SpatialElement(id: id, surface: .board(boardID), kind: .web,
        frame: .init(x: 0, y: 0, width: 160, height: 120), worldOrigin: .zero,
        source: "State application can fail after the program is live",
        html: "<button id='control'>Working control</button><svg width='160' height='80'><rect width='160' height='80' fill='red'/></svg>",
        javaScript: """
          const original = window.notebookProgram;
          window.notebookProgram = {...original, apply: (value, revision) => {
            if (value.fail) throw new Error('Native state application failed after readiness');
            return original.apply(value, revision);
          }};
          notebook.ready(Promise.resolve());
          """, state: .object(["fail": .bool(fails)]), stamp: .init(counter: 0, actor: model.actorID))
      XCTAssertTrue(after.upsertElement(value, in: boardID,
        expected: before.board(boardID)?.elements.first(where: { $0.id == id })?.stamp, actor: model.actorID))
      _ = try model.store.saveBoardEdits(before: before, after: after)
      await model.reloadExternalChanges()?.value
      return agentElementSnapshotSource(try XCTUnwrap(after.board(boardID)?.elements.first(where: { $0.id == id })))
    }
    let healthy = try await saveState(fails: false)
    model.updatePresence(.init(boardID: boardID, mode: .board,
      camera: .init(center: .init(x: 80, y: 60), scale: 1), viewport: .init(x: 512, y: 512)), settled: true)
    let window = try await mountNotebookScene(model)
    try await waitUntil("The real native control has a ready live installation") {
      model.compositionTiles.published?.hasInstalledPixels(for: address) == true && self.webViews(in: window).count == 1
    }
    let web = try XCTUnwrap(webViews(in: window).first)
    weak let coordinator: AgentWebCoordinator? = try XCTUnwrap(web.navigationDelegate as? AgentWebCoordinator)
    let installation = try XCTUnwrap(coordinator?.installation(for: healthy))
    XCTAssertTrue(installation.isInstalled)
    let navigation = try XCTUnwrap(coordinator?.loadToken)
    let original = try XCTUnwrap(model.compositionTiles.published?.sourceRasters[address]?.retainedCopy())
    defer { original.release() }
    let failed = try await saveState(fails: true)
    let beforeFailureDOM = try? await web.evaluateJavaScript("JSON.stringify({state:window.notebook.state,apply:String(window.notebookProgram.apply)})")
    try await waitUntil("The real JS state application fails in the previously ready runtime and retires it", diagnostic: {
      let current = self.webViews(in: window).first?.navigationDelegate as? AgentWebCoordinator
      return "before=\(navigation), current=\(String(describing: current?.loadToken)), old-live-healthy=\(coordinator?.hasLiveSource(healthy) == true), old-live-failed=\(coordinator?.hasLiveSource(failed) == true), new-live-failed=\(current?.hasLiveSource(failed) == true), "
        + "WK=\(self.webViews(in: window).count), activity=\(resources.webActivity(for: focus)), receipt=\(String(describing: model.compositionTiles.published?.sourceReceipts[address])), "
        + "diagnostics=\(resources.diagnostics(for: [healthy, failed])), initialDOM=\(String(describing: beforeFailureDOM))"
    }) {
      resources.diagnostics(for: [failed]).contains { $0.kind == "render_error" }
        && self.webViews(in: window).isEmpty && resources.webActivity(for: focus).activeLeaseCount == 0
    }
    XCTAssertFalse(installation.isInstalled, "A terminal source failure revokes the old live presentation proof")
    XCTAssertFalse(coordinator?.hasLiveSource(failed) == true, "A failed program cannot keep accepting input")
    let policy = try XCTUnwrap(model.compositionTiles.published?.sourceReceipts[address]?.demand.policy)
    let failure = try XCTUnwrap(model.compositionTiles.runtimeFailure(at: address, source: failed, policy: policy))
    XCTAssertNil(failure.policy, "This is a terminal runtime error, not snapshot pressure")
    XCTAssertEqual(failure.loadToken, navigation, "The real failure happens after readiness without a replacement navigation")
    try await waitUntil("Its exact preceding raster is physically shown", diagnostic: {
      self.retainedFailureDiagnostic(window: window, original: original,
        cohort: model.compositionTiles.published?.sourceRasters[address],
        receipt: model.compositionTiles.published?.sourceReceipts[address])
    }) {
      self.rasterViews(in: window).contains { $0.installation(for: original).isInstalled }
    }
    let pixels = try assertVisibleFailureAndRetry(in: window)
    let attachment = XCTAttachment(image: pixels)
    attachment.name = "Already ready program failure retains pixels and exposes Retry"
    attachment.lifetime = .keepAlways; add(attachment)
  }


  @MainActor
  func testRemountedBoardAndCoverKeepCohortPixelsWhileTheirDensityAndSourceRemainPending() async throws {
    let model = makeModel()
    for changedSource in [false, true] {
      let boardID = UUID(), id = UUID().uuidString
      let previous = element(id: id, source: "Prior mounted pixels")
      let current = changedSource ? element(id: id, source: "Accepted replacement") : previous
      let plane: SceneCompositionPlane = changedSource ? .cover(boardID: boardID, itemID: UUID()) : .board(boardID)
      let address = SceneSourceAddress(plane: plane, elementID: id)
      let oldCrop = PageRect(x: 40, y: 30, width: 80, height: 60)
      let newCrop = PageRect(x: 32, y: 16, width: 96, height: 80)
      let image = fallbackImage(size: .init(width: oldCrop.width, height: oldCrop.height), scale: 1, color: .red)
      let retained = try XCTUnwrap(storeFallbackImage(image, for: .agentRegion(previous, oldCrop)))
      defer { retained.release() }
      let demand = SceneSourceDemand(source: current, minimumScale: 4, region: newCrop)
      let receipt = SceneSourceReceipt(demand: demand, installedSource: previous,
        installedScale: retained.pixelScale, status: .pending, installedRegion: oldCrop)
      let cohort = fallbackCohort(boardID: boardID, receipts: [address: receipt], rasters: [address: retained])
      var readiness: [Bool] = []
      func content(_ identity: UUID) -> AnyView {
        AnyView(PreparedAgentElementView(element: current, allowsInteraction: false,
          focus: .board(boardID: boardID, elementID: id), onRenderReady: { readiness.append($0) }, onState: { _ in XCTFail("A portal is read-only"); return false })
          .frame(width: 160, height: 120).id(identity).environment(model).environment(\.sceneComposition, .init(cohort)))
      }
      let host = try SurfaceHost(content: content(UUID()))
      defer { host.close() }
      var previousView: AgentSnapshotRasterView?
      for remount in 0..<2 {
        if remount > 0 { host.controller.rootView = content(UUID()) }
        try await waitUntil("A new physical projection installs the retained prior crop before replacement pixels exist") {
          self.rasterViews(in: host.controller.view).contains { $0 !== previousView && $0.installation(for: retained).isInstalled }
        }
        XCTAssertFalse(readiness.contains(true), "Old content, crop and density cannot acknowledge the new source demand")
        XCTAssertFalse(cohort.sourceReceipts[address]?.hasCurrentPixels == true)
        XCTAssertTrue(webViews(in: host.controller.view).isEmpty, "The static source producer must not be duplicated by its consumer")
        let view = try XCTUnwrap(rasterViews(in: host.controller.view).first)
        previousView = view
        view.layoutIfNeeded()
        let cropLayer = try XCTUnwrap(view.layer.sublayers?.first(where: { $0.contents != nil }))
        XCTAssertEqual(cropLayer.frame, CGRect(x: 40, y: 30, width: 80, height: 60),
          "The old crop stays at its own local coordinates instead of stretching into the new crop")
        let shown = UIGraphicsImageRenderer(size: view.bounds.size).image { context in
          view.layer.render(in: context.cgContext)
        }
        XCTAssertEqual(try redBounds(in: shown), CGRect(x: 40, y: 30, width: 80, height: 60),
          "The mounted raster's actual red pixels retain their source crop, including after remount")
        let attachment = XCTAttachment(image: shown)
        attachment.name = "Retained \(changedSource ? "cover source" : "board density") crop, remount \(remount)"
        attachment.lifetime = .keepAlways; add(attachment)
      }
      let updated = fallbackImage(size: .init(width: newCrop.width, height: newCrop.height), scale: 4, color: .green)
      let currentRaster = try XCTUnwrap(storeFallbackImage(updated, for: demand.rasterSource))
      defer { currentRaster.release() }
      // This is the existing source completion notification, without a camera
      // gesture, rootView replacement, focus or a synthetic readiness callback.
      try await waitUntil("The stationary consumer installs the completed exact source and becomes ready") {
        readiness.last == true && self.rasterViews(in: host.controller.view).contains { $0.installation(for: currentRaster).isInstalled }
      }
      XCTAssertFalse(rasterViews(in: host.controller.view).contains { $0.installation(for: retained).isInstalled })
      XCTAssertTrue(webViews(in: host.controller.view).isEmpty)
      host.close()
    }
  }

  @MainActor
  func testCohortFallbackRejectsForeignAddressesInvalidGeometryAndUnrecordedHistory() throws {
    let boardID = UUID(), current = element(id: UUID().uuidString, source: "current")
    let focus = InteractiveElementReference.board(boardID: boardID, elementID: current.id)
    let address = SceneSourceAddress(plane: .board(boardID), elementID: current.id)
    let previous = element(id: current.id, source: "published predecessor")
    let crop = PageRect(x: 0, y: 0, width: 160, height: 120)
    let retained = try XCTUnwrap(storeFallbackImage(fallbackImage(size: .init(width: 160, height: 120), scale: 1, color: .red),
      for: .agentRegion(previous, crop)))
    defer { retained.release() }
    let demand = SceneSourceDemand(source: current, minimumScale: 4)
    let receipt = SceneSourceReceipt(demand: demand, installedSource: previous,
      installedScale: retained.pixelScale, status: .pending, installedRegion: crop)
    let valid = fallbackCohort(boardID: boardID, receipts: [address: receipt], rasters: [address: retained])
    let borrowed = try XCTUnwrap(ScenePreparedRasterFallback.retain(from: valid, focus: focus, for: current))
    XCTAssertEqual(borrowed.entryID, retained.entryID); borrowed.release()
    XCTAssertNil(ScenePreparedRasterFallback.retain(from: valid,
      focus: .board(boardID: UUID(), elementID: current.id), for: current))
    XCTAssertNil(ScenePreparedRasterFallback.retain(from: valid,
      focus: .page(pageID: boardID, elementID: current.id), for: current))
    let resized = AgentElement(id: current.id, kind: .web,
      frame: .init(x: 0, y: 0, width: 320, height: 120), source: current.source, html: current.html)
    XCTAssertNil(ScenePreparedRasterFallback.retain(from: valid, focus: focus, for: resized))
    let unrecorded = SceneSourceReceipt(demand: demand, installedSource: current,
      installedScale: retained.pixelScale, status: .pending, installedRegion: crop)
    XCTAssertNil(ScenePreparedRasterFallback.retain(from: fallbackCohort(boardID: boardID,
      receipts: [address: unrecorded], rasters: [address: retained]), focus: focus, for: current))
    let alias = SceneSourceAddress(plane: .cover(boardID: boardID, itemID: UUID()), elementID: current.id)
    XCTAssertNil(ScenePreparedRasterFallback.retain(from: fallbackCohort(boardID: boardID,
      receipts: [address: receipt, alias: receipt], rasters: [address: retained, alias: retained]), focus: focus, for: current),
      "An ambiguous physical address cannot borrow another owner's history")
    for invalid in [PageRect(x: -1, y: 0, width: 160, height: 120), PageRect(x: 0, y: 0, width: 161, height: 120)] {
      let raster = try XCTUnwrap(storeFallbackImage(fallbackImage(size: .init(width: invalid.width, height: invalid.height), scale: 1, color: .red),
        for: .agentRegion(previous, invalid)))
      defer { raster.release() }
      let bad = SceneSourceReceipt(demand: demand, installedSource: previous,
        installedScale: raster.pixelScale, status: .pending, installedRegion: invalid)
      XCTAssertNil(ScenePreparedRasterFallback.retain(from: fallbackCohort(boardID: boardID,
        receipts: [address: bad], rasters: [address: raster]), focus: focus, for: current))
    }
  }

  @MainActor
  func testPassiveCaptureResumesAfterRealRasterAdmissionWithoutAnotherViewUpdate() async throws {
    let model = makeModel(), resources = SceneRenderResources.shared
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertTrue(model.permitsBackgroundPreparation, "Passive preparation requires the real workspace startup")
    try await waitUntil("Earlier mounted owners must release their asynchronous backing before measuring this pressure") {
      resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0
        && resources.rasterAdmission.pinnedBytes == 0 && resources.rasterAdmission.passiveReservedBytes == 0
    }
    let source = element(id: UUID().uuidString, source: "Stationary passive page")
    let activityReference = InteractiveElementReference.page(pageID: UUID(), elementID: source.id)
    let admission = resources.rasterAdmission
    let available = min(admission.byteLimit - admission.heldBytes,
      admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes)
    XCTAssertGreaterThan(available, 1024 * 1024)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(available - 64 * 1024, priority: .passive))
    defer { pressure.release() }
    var ready = false
    let host = try SurfaceHost(content: AnyView(PreparedAgentElementView(element: source,
      allowsInteraction: false, capturePolicy: .exact(scale: 2),
      focus: activityReference,
      onRenderReady: { ready = $0 }, onState: { _ in XCTFail("A passive capture cannot commit"); return false })
      .frame(width: 160, height: 120).environment(model)))
    defer { host.close() }
    try await waitUntil("The actual WebKit capture reaches the local resource limit and retires", diagnostic: {
      "source=\(source.id), diagnostics=\(resources.diagnostics(for: [source])), activity=\(resources.webActivity(for: activityReference)), "
        + "mountedWK=\(self.webViews(in: host.controller.view).count), activeWK=\(resources.activeWebSurfaceCount), "
        + "pendingWK=\(resources.pendingWebRequestCount), admission=\(resources.rasterAdmission), ready=\(ready)"
    }) {
      resources.diagnostics(for: [source]).contains { $0.kind == "resource_limit" }
        && self.webViews(in: host.controller.view).isEmpty && resources.webActivity(for: activityReference).activeLeaseCount == 0
    }
    XCTAssertFalse(ready)
    let refusal = resources.lastRasterRefusal?.generation
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(resources.lastRasterRefusal?.generation, refusal,
      "Releasing the failed executor cannot create a repeated capture/admission loop")
    pressure.release()
    // No rootView replacement, camera change, source edit or synthetic ready.
    try await waitUntil("Released external pressure wakes the stationary source and installs its actual pixels") {
      guard ready, self.webViews(in: host.controller.view).isEmpty,
        let raster = resources.retainRaster(for: .agent(source), minimumScale: 2) else { return false }
      defer { raster.release() }
      return self.rasterViews(in: host.controller.view).contains { $0.installation(for: raster).isInstalled }
    }
    let raster = try XCTUnwrap(resources.retainRaster(for: .agent(source), minimumScale: 2))
    defer { raster.release() }
    XCTAssertTrue(rasterViews(in: host.controller.view).contains { $0.installation(for: raster).isInstalled })
    XCTAssertLessThanOrEqual(resources.residentBytes + resources.reservedBytes, resources.byteLimit)
  }

  @MainActor
  func testInteractivePageSVGKeepsActualScreenDensityAndCanonicalViewportWhenItBecomesPassive() async throws {
    let model = makeModel()
    let pageSize = PageSize(width: 834, height: 1194)
    await model.start(pageSize: pageSize)
    var page = try XCTUnwrap(model.activePage)
    let source = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: pageSize.width, height: pageSize.height),
      source: "Large vector coordinates on a physical notebook page", html: """
        <svg id="drawing" width="100%" height="100%" viewBox="0 0 20000 30000" preserveAspectRatio="none">
          <rect x="9970" y="0" width="60" height="30000" fill="#e52222"/>
          <rect x="0" y="14970" width="20000" height="60" fill="#e52222"/>
        </svg>
        <button style="position:absolute;left:12px;top:12px" onclick="notebook.commit({clicked:true})">Inspect drawing</button>
        """)
    page.replaceElements([source], actor: model.actorID)
    try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    let viewport = CGSize(width: 780, height: 1116)
    let paperProjection = min(viewport.width / pageSize.width, viewport.height / pageSize.height)
    var ready = false
    func content(current: Bool) -> AnyView {
      AnyView(PageSurface(page: page, isCurrent: current, isInteractive: false,
        isVisible: true, onRenderReady: .init { ready = $0 }, displayProjection: paperProjection)
        .frame(width: pageSize.width, height: pageSize.height)
        .scaleEffect(paperProjection)
        .frame(width: viewport.width, height: viewport.height).environment(model))
    }
    let host = try SurfaceHost(content: content(current: true))
    defer { host.close() }
    try await waitUntil("The real page and its single canonical SVG runtime are ready") {
      ready && self.webViews(in: host.controller.view).count == 1
    }
    let web = try XCTUnwrap(webViews(in: host.controller.view).first)
    let geometry = try await web.evaluateJavaScript("""
      (() => { const r = document.getElementById('drawing').getBoundingClientRect();
        return [innerWidth, innerHeight, r.width, r.height]; })()
      """) as? [Double]
    XCTAssertEqual(geometry, [pageSize.width, pageSize.height, pageSize.width, pageSize.height],
      "Large SVG coordinates do not change the program's physical CSS viewport")
    let density = paperProjection * host.window.traitCollection.displayScale
    XCTAssertGreaterThan(pageSize.height * density, 2048,
      "The physical visible page requires more pixels than the retired display-policy cap")
    let transitionStarted = ContinuousClock.now
    var firstPreparedAt: ContinuousClock.Instant?
    var firstPreparedStatus: String?
    var installedRaster: RasterLease?
    host.controller.rootView = content(current: false)
    try await waitUntil("The neighboring page installs its density-qualified capture and retires the runtime") {
      guard ready, self.webViews(in: host.controller.view).isEmpty,
        let raster = SceneRenderResources.shared.retainRaster(for: .agent(source), minimumScale: density) else { return false }
      let views = self.rasterViews(in: host.controller.view)
      let installed = views.contains { $0.installation(for: raster).isInstalled }
      if firstPreparedAt == nil {
        firstPreparedAt = .now
        firstPreparedStatus = "entry=\(raster.entryID), views=\(views.count), mounted=\(views.contains { $0.installation(for: raster, requiresVisibility: false).isInstalled }), visible=\(installed)"
      }
      if installed { installedRaster = raster } else { raster.release() }
      return installed
    }
    let raster = try XCTUnwrap(installedRaster)
    defer { raster.release() }
    let handoff = XCTAttachment(string: "first-prepared: \(firstPreparedStatus ?? "none")\nmutation-to-install=\(transitionStarted.duration(to: .now)); prepared-to-install=\(firstPreparedAt?.duration(to: .now).description ?? "none")")
    handoff.name = "SVG demotion capture versus native installation"
    handoff.lifetime = .keepAlways; add(handoff)
    XCTAssertTrue(rasterViews(in: host.controller.view).contains { $0.installation(for: raster).isInstalled },
      "The exact density-qualified entry is physically installed in the passive page")
    let cg = try XCTUnwrap(raster.image.cgImage)
    XCTAssertGreaterThan(cg.height, 2048)
    XCTAssertGreaterThanOrEqual(Double(cg.width), source.frame.width * density)
    XCTAssertGreaterThanOrEqual(Double(cg.height), source.frame.height * density)
    XCTAssertLessThan(cg.width * cg.height, 8_388_608,
      "The viewport-sized capture remains bounded even for large SVG coordinates")
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
      bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let center = ((cg.height / 2) * cg.width + cg.width / 2) * 4
    XCTAssertGreaterThan(pixels[center], 220)
    XCTAssertLessThan(pixels[center + 1], 45)
    XCTAssertEqual(pixels[3], 0, "The native scroll viewport cannot add an opaque strip to transparent SVG")
    let attachment = XCTAttachment(image: raster.image)
    attachment.name = "Physical notebook SVG source at actual fitted screen density"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertLessThanOrEqual(SceneRenderResources.shared.residentBytes + SceneRenderResources.shared.reservedBytes,
      SceneRenderResources.shared.byteLimit)
  }

  @MainActor
  func testFourVisiblePageProgramsAreReadyWithoutViewportActivation() async throws {
    let model = makeModel(), pageID = UUID()
    let elements = (0..<4).map { index in
      AgentElement(id: "program-\(index)-" + pageID.uuidString, kind: .web,
        frame: .init(x: Double(index % 2) * 200, y: Double(index / 2) * 160, width: 180, height: 140),
        source: "Program \(index)", html: """
          <button id="control" onclick="window.notebook.commit({click:++window.clicks})">Ready control \(index)</button>
          <textarea aria-label="Editor \(index)"></textarea>
          <script>window.clicks=0; window.runtimeIdentity=String(Math.random());notebook.ready(Promise.resolve());</script>
          """)
    }
    let viewport = PageProgramViewport()
    var commits: [String: JSONValue] = [:]
    let host = try SurfaceHost(content: AnyView(PageProgramViewportFixture(viewport: viewport,
      page:.init(id:pageID,size:.init(width:400,height:320),actor:UUID(),elements:elements),onState: { commits[$0] = $1; return true }).environment(model)))
    defer { host.close() }
    try await waitUntil("All four visible programs are ready without an activation tap", timeout: .seconds(12)) {
      let views = self.webViews(in: host.controller.view)
      return views.count == elements.count && SceneRenderResources.shared.pendingWebRequestCount == 0
        && elements.allSatisfy { source in
          views.contains { ($0.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource(source) == true }
        }
    }
    let original = webViews(in: host.controller.view)
    let waiting = 3
    let originalFourth = try XCTUnwrap(original.first {
      ($0.navigationDelegate as? AgentWebCoordinator)?.hasLiveSource(elements[waiting]) == true
    })
    let target = elements[waiting]
    viewport.region = CGRect(x: target.frame.x, y: target.frame.y, width: target.frame.width, height: target.frame.height)
    var current: WKWebView?
    let deadline = ContinuousClock.now + .seconds(8)
    while current == nil, ContinuousClock.now < deadline {
      for view in webViews(in: host.controller.view) {
        if (try? await view.evaluateJavaScript("document.getElementById('control')?.textContent")) as? String == "Ready control \(waiting)" {
          current = view
        }
      }
      if current == nil { try await Task.sleep(for: .milliseconds(20)) }
    }
    let web = try XCTUnwrap(current)
    try await waitUntil("The newly visible control is physically ready") { SceneSourceVisibility.isVisible(web) }
    XCTAssertTrue(web === originalFourth, "Revealing the fourth viewport retains its already ready runtime")
    XCTAssertNil(model.interactiveElementFocus, "Visibility alone, not a hidden activating tap, starts this control")
    XCTAssertTrue(commits.isEmpty, "Preparation never invents input")
    // Native unit tests set the accepted contact intent; the UI test supplies
    // the trusted first gesture. Visibility and startup above needed no focus.
    model.interactiveElementFocus = .page(pageID: pageID, elementID: target.id)
    await Task.yield()
    _ = try await web.evaluateJavaScript("document.getElementById('control').click()")
    try await waitUntil("The first ready event executes once") { commits[target.id] == .object(["click": .number(1)]) }
    XCTAssertLessThanOrEqual(SceneRenderResources.shared.activeWebSurfaceCount, 6)
  }

  @MainActor
  func testMarkupOnlyWebKeepsItsInlineControlsAndTextareaLive() async throws {
    let model = makeModel()
    let source = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 240, height: 180), source: "Markup-only controls",
      html: """
        <button id="control" onclick="window.notebook.commit({click:1})">Inline control</button>
        <textarea aria-label="Inline editor" oninput="window.notebook.commit({text:this.value})"></textarea>
        <script>window.inlineContext = 42;notebook.ready(Promise.resolve());</script>
        """, javaScript: "")
    let focus = InteractiveElementReference.board(boardID: UUID(), elementID: source.id)
    var ready = false, values: [JSONValue] = []
    let host = try SurfaceHost(content: AnyView(PreparedAgentElementView(element: source,
      allowsInteraction: true, focus: focus, onRenderReady: { ready = $0 }, onState: { values.append($0); return true })
      .frame(width: 240, height: 180).environment(model)))
    defer { host.close() }
    try await waitUntil("Web markup without a separate JS field still mounts its actual program") {
      ready && self.webViews(in: host.controller.view).count == 1
    }
    let web = try XCTUnwrap(webViews(in: host.controller.view).first)
    XCTAssertTrue(SceneSourceVisibility.isVisible(web))
    let context = try await web.evaluateJavaScript("window.inlineContext") as? Int
    XCTAssertEqual(context, 42)
    XCTAssertNil(model.interactiveElementFocus, "Preparation cannot steal the human's focus")
    model.interactiveElementFocus = focus
    _ = try await web.evaluateJavaScript("document.getElementById('control').click()")
    try await waitUntil("Inline control uses the normal state bridge") { values.contains(.object(["click": .number(1)])) }
    _ = try await web.evaluateJavaScript("const t=document.querySelector('textarea');t.value='kept';t.dispatchEvent(new Event('input',{bubbles:true}))")
    try await waitUntil("Inline editor uses the same runtime") { values.contains(.object(["text": .string("kept")])) }
    XCTAssertTrue(webViews(in: host.controller.view).first === web)
  }

  @MainActor
  func testCachedStaticSourceReportsReadyWithoutMountingWebKit() async throws {
    let model = makeModel()
    let source = element(id: UUID().uuidString, source: "cached")
    XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: source))
    var ready = false
    let host = try SurfaceHost(content: AnyView(
      PreparedAgentElementView(element: source, allowsInteraction: false,
        focus: .board(boardID: UUID(), elementID: source.id),
        onRenderReady: { ready = $0 }, onState: { _ in XCTFail("Static content cannot commit state"); return false })
        .frame(width: 160, height: 120).environment(model)))
    defer { host.close() }
    try await waitUntil("Cached raster must confirm its first mounted frame") { ready }
    XCTAssertTrue(webViews(in: host.controller.view).isEmpty)
  }

  @MainActor
  func testStaticSourceEditPreparesItsReplacementInsteadOfKeepingTheOldRaster() async throws {
    let model = makeModel()
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertTrue(model.permitsBackgroundPreparation, "Passive preparation requires the real workspace startup")
    let id = UUID().uuidString
    let first = element(id: id, source: "first")
    let second = element(id: id, source: "second")
    XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: first))
    XCTAssertNil(SceneRenderResources.shared.image(for: second))
    var readiness: [String: Bool] = [:]
    func content(_ source: AgentElement) -> AnyView {
      AnyView(PreparedAgentElementView(element: source, allowsInteraction: false,
        focus: .board(boardID: WorkspaceRoot.boardID, elementID: source.id),
        onRenderReady: { readiness[source.source] = $0 }, onState: { _ in false })
        .frame(width: 160, height: 120).environment(model))
    }
    let host = try SurfaceHost(content: content(first))
    defer { host.close() }
    try await waitUntil("First source ready") { readiness[first.source] == true }
    host.controller.rootView = content(second)
    try await waitUntil("Changed source must acquire its own completed raster") {
      readiness[second.source] == true && SceneRenderResources.shared.image(for: second) != nil
        && self.webViews(in: host.controller.view).isEmpty
    }
    XCTAssertNotNil(SceneRenderResources.shared.image(for: second))
  }

  @MainActor
  func testVisibleControlsPrepareBeforeFocusAndTransferOnlyTheirWriteOwnership() async throws {
    let model = makeModel()
    let boardID = UUID()
    let first = element(id: UUID().uuidString, source: "first", interactive: true)
    let second = element(id: UUID().uuidString, source: "second", interactive: true)
    for source in [first, second] { XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: source)) }
    var commits: [String: Int] = [:]
    var ticks: [String: [Int]] = [:]
    let host = try SurfaceHost(content: AnyView(HStack {
      ForEach([first, second]) { source in
        PreparedAgentElementView(element: source, allowsInteraction: true,
          focus: .board(boardID: boardID, elementID: source.id), onRenderReady: { _ in },
          onState: { value in
            commits[source.id, default: 0] += 1
            if case .object(let fields) = value, case .number(let tick) = fields["tick"] {
              ticks[source.id, default: []].append(Int(tick))
            }
            return true
          })
          .frame(width: 160, height: 120)
      }
    }.environment(model)))
    defer { host.close() }
    try await waitUntil("Both visible controls prepare before their first tap") {
      self.webViews(in: host.controller.view).count == 2
    }
    XCTAssertTrue(commits.isEmpty, "Unfocused preparation cannot write program timer state")
    model.interactiveElementFocus = .board(boardID: boardID, elementID: first.id)
    try await waitUntil("First interactive owner mounted") {
      self.webViews(in: host.controller.view).count == 2 && commits[first.id, default: 0] > 0
    }
    model.interactiveElementFocus = .board(boardID: boardID, elementID: second.id)
    try await waitUntil("Focus transfers state writes without dismantling the other ready control") {
      self.webViews(in: host.controller.view).count == 2 && commits[second.id, default: 0] > 0
    }
    let firstCommitCount = commits[first.id, default: 0]
    let secondCommitCount = commits[second.id, default: 0]
    try await waitUntil("Current owner's timer remains live") { commits[second.id, default: 0] > secondCommitCount }
    XCTAssertEqual(commits[first.id, default: 0], firstCommitCount,
      "A timer from the previous owner must not write after focus changes.")
    for values in ticks.values {
      XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { pair in pair.0 < pair.1 },
        "The same runtime's timer advances; a reload must not reset its local counter")
    }
    var owners: Set<String> = []
    for web in webViews(in: host.controller.view) {
      if let owner = try await web.evaluateJavaScript("document.body.dataset.owner") as? String { owners.insert(owner) }
    }
    XCTAssertEqual(owners, [first.id, second.id])
  }

  @MainActor
  func testPreparationFailureUnmountsHiddenWebKitWithoutAutomaticRetryStorm() async throws {
    let model = makeModel()
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertTrue(model.permitsBackgroundPreparation, "Passive preparation requires the real workspace startup")
    let id = UUID().uuidString
    let activityReference = InteractiveElementReference.board(boardID: UUID(), elementID: id)
    let source = AgentElement(id: id, kind: .web,
      frame: .init(x: 0, y: 0, width: 160, height: 120), source: "native readiness failure",
      html: "<p>Visible source</p>", javaScript: """
        Object.defineProperty(document, 'fonts', {
          get() { throw new Error('Expected test preparation failure'); }
        });
        """)
    var ready = false
    let host = try SurfaceHost(content: AnyView(
      PreparedAgentElementView(element: source, allowsInteraction: false,
        focus: activityReference, onRenderReady: { ready = $0 }, onState: { _ in false })
        .frame(width: 160, height: 120).environment(model)))
    defer { host.close() }
    try await waitUntil("A failed snapshot must finish its lease, not remain hidden indefinitely") {
      SceneRenderResources.shared.diagnostics(for: [source]).contains { $0.kind == "render_error" }
        && self.webViews(in: host.controller.view).isEmpty
        && SceneRenderResources.shared.webActivity(for: activityReference).activeLeaseCount == 0
    }
    let admission = try XCTUnwrap(SceneRenderResources.shared.webActivity(for: activityReference).lastAdmission)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(SceneRenderResources.shared.webActivity(for: activityReference).lastAdmission, admission,
      "Releasing the failed view is not a reason to immediately retry the same failed source.")
    XCTAssertTrue(webViews(in: host.controller.view).isEmpty)
    XCTAssertFalse(ready)
  }

  @MainActor
  func testCurrentPageTemporarilyDisablesInputWithoutRestartingItsProgram() async throws {
    let model = makeModel()
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let source = element(id: UUID().uuidString, source: "current page timer", interactive: true)
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements([source], actor: model.actorID)
    try model.store.savePage(page)
    await model.reloadExternalChanges()?.value
    XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: source))
    model.interactiveElementFocus = .page(pageID: page.id, elementID: source.id)
    func tick() -> Double {
      guard let element = model.pages[page.id]?.elements.first,
        case .object(let state) = element.state,
        case .number(let value) = state["tick"] else { return -1 }
      return value
    }
    func content(current: Bool = true, input: Bool) -> AnyView {
      AnyView(LivePageFixture(pageID: page.id, current: current, input: input).environment(model))
    }
    let host = try SurfaceHost(content: content(input: true))
    defer { host.close() }
    try await waitUntil("The current page starts its actual program") {
      self.webViews(in: host.controller.view).count == 1 && tick() > 0
    }
    let running = try XCTUnwrap(webViews(in: host.controller.view).first)
    _ = try await running.evaluateJavaScript("window.pageLifetimeWitness = 42")
    let before = tick()
    host.controller.rootView = content(input: false)
    try await waitUntil("Camera/curl pauses input while the same timer continues to commit") { tick() > before + 2 }
    XCTAssertTrue(webViews(in: host.controller.view).first === running)
    let witnessDuringGesture = try await running.evaluateJavaScript("window.pageLifetimeWitness") as? Int
    XCTAssertEqual(witnessDuringGesture, 42)
    host.controller.rootView = content(input: true)
    try await waitUntil("The same mounted owner accepts input again") { tick() > before + 4 }
    XCTAssertTrue(webViews(in: host.controller.view).first === running)
    let witnessAfterGesture = try await running.evaluateJavaScript("window.pageLifetimeWitness") as? Int
    XCTAssertEqual(witnessAfterGesture, 42)
    host.controller.rootView = content(current: false, input: false)
    try await waitUntil("A neighboring page releases its runtime and keeps only prepared pixels") {
      self.webViews(in: host.controller.view).isEmpty
    }
  }

  @MainActor
  func testBackgroundCheckpointsIndependentProgramsWithoutRestartingFailedHiddenModels() async throws {
    let model = makeModel()
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let sources = ["hung-a", "healthy", "hung-b"].map { id in
      AgentElement(id: id, kind: .web, frame: .init(x: 0, y: 0, width: 200, height: 100),
        source: id, html: "<output>7</output>", javaScript: """
          window.resumes=0;
          notebook.lifecycle({pause:()=>{},checkpoint:()=>\(id == "healthy" ? "({phase:7})" : "new Promise(()=>{})"),
            resume:()=>{window.resumes++}});
          notebook.ready(Promise.resolve());
          """, state: .object(["phase": .number(0)]))
    }
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements(sources, actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let resources = SceneRenderResources(maximumWebSurfaces: 4)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    var surfaces: [(AgentWebCoordinator, WKWebView, WebSurfaceLease)] = []
    defer {
      for (owner, web, lease) in surfaces { owner.invalidate(); lease.release(); web.removeFromSuperview() }
      window.isHidden = true; window.rootViewController = nil
    }
    for (index, source) in sources.enumerated() {
      let lease = try await resources.acquireWebSurface(priority: .liveProgram)
      let owner = AgentWebCoordinator(lease: lease, resources: resources, onRenderReady: { _ in }, onState: { _ in true })
      owner.programOwner = model
      let web = AgentWebCoordinator.makeWebView(coordinator: owner)
      host.view.addSubview(web); web.frame = .init(x: 30, y: 100 + index * 130, width: 200, height: 100)
      surfaces.append((owner, web, lease))
      owner.bindPresentation(to: .page(pageID: page.id, elementID: source.id))
      owner.load(source, basis: page.programStateBasis(source.id), in: web)
    }
    try await waitUntil("All three actual programs are ready") {
      zip(surfaces, sources).allSatisfy { $0.0.0.hasLiveSource($0.1) }
    }
    let started = ContinuousClock.now
    let boundary = Task { @MainActor in await AgentWebCoordinator.checkpointPrograms(ownedBy: model, resume: false) }
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertEqual(try model.store.loadPage(page.id).elements.first { $0.id == "healthy" }?.state,
      .object(["phase": .number(7)]), "A healthy model is written without waiting for a hung neighbour")
    let saved = await boundary.value
    XCTAssertFalse(saved, "Hung authors cannot be certified as saved")
    XCTAssertLessThan(started.duration(to: .now), .seconds(7), "Two independent deadlines do not add together")
    for (_, web, _) in surfaces {
      let resumes = try await web.evaluateJavaScript("window.resumes") as? Int
      XCTAssertEqual(resumes, 0, "A failed hidden checkpoint cannot restart its model")
    }
  }

  @MainActor
  func testRetiringPageProgramWritesItsFrozenModelAndRestoresThatMoment() async throws {
    let model = makeModel()
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let source = AgentElement(id: "checkpoint-model", kind: .web,
      frame: .init(x: 20, y: 20, width: 240, height: 120), source: "Checkpoint model",
      html: "<button onclick='play()'>Play</button><output></output>", javaScript: """
        let phase=notebook.state.phase, frame=0;
        const draw=()=>document.querySelector('output').textContent=String(phase);
        const tick=()=>{phase++;draw();frame=requestAnimationFrame(tick)};
        window.play=()=>{cancelAnimationFrame(frame);frame=requestAnimationFrame(tick)};
        notebook.lifecycle({pause:()=>{cancelAnimationFrame(frame);draw()},
          checkpoint:()=>({phase}),resume:draw,dispose:()=>cancelAnimationFrame(frame)});
        addEventListener('notebookstate',()=>{phase=notebook.state.phase;draw()});
        notebook.ready(Promise.resolve().then(draw));
        """, state: .object(["phase": .number(0)]))
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements([source], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let initialStamp = try XCTUnwrap(model.pages[page.id]).agentStamp
    model.interactiveElementFocus = .page(pageID: page.id, elementID: source.id)
    func content(current: Bool) -> AnyView {
      AnyView(LivePageFixture(pageID: page.id, current: current, input: current).environment(model))
    }
    let host = try SurfaceHost(content: content(current: true))
    defer { host.close() }
    try await waitUntil("The same physical program is ready") {
      guard let web = self.webViews(in: host.controller.view).first,
        let owner = web.navigationDelegate as? AgentWebCoordinator else { return false }
      return owner.hasLiveSource(source)
    }
    let running = try XCTUnwrap(webViews(in: host.controller.view).first)
    _ = try await running.evaluateJavaScript("document.querySelector('button').click();true")
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(model.pages[page.id]?.agentStamp, initialStamp, "rAF never becomes a writer loop")
    // The foreground notification can arrive before the background task gets
    // its first turn. It still drains pause/save before resuming this heap.
    model.setPreparationForeground(false); model.setPreparationForeground(true)
    let backgroundSaved = await model.finishProgramBoundary()
    XCTAssertTrue(backgroundSaved)
    let background = try XCTUnwrap(try model.store.loadPage(page.id).elements.first { $0.id == source.id })
    guard case .number(let stoppedPhase) = background.state["phase"] else { return XCTFail("Missing stopped phase") }
    XCTAssertGreaterThan(stoppedPhase, 0)
    let shownAfterForeground = try await running.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertEqual(shownAfterForeground, stoppedPhase)
    _ = try await running.evaluateJavaScript("document.querySelector('button').click();true")
    try await Task.sleep(for: .milliseconds(100))
    host.controller.rootView = content(current: false)
    try await waitUntil("A durable checkpoint precedes release of this actual program") {
      self.webViews(in: host.controller.view).isEmpty
    }
    let saved = try XCTUnwrap(try model.store.loadPage(page.id).elements.first { $0.id == source.id })
    guard case .number(let phase) = saved.state["phase"] else { return XCTFail("The model phase must be explicit") }
    XCTAssertGreaterThan(phase, 0)
    host.controller.rootView = content(current: true)
    try await waitUntil("Return installs the saved model without inventing a newer moment", diagnostic: {
      let webs = self.webViews(in: host.controller.view)
      return "webs=\(webs.count) delegates=\(webs.map { String(describing: $0.navigationDelegate) }) oldDelegate=\(String(describing: running.navigationDelegate)) active=\(SceneRenderResources.shared.activeWebSurfaceCount) pending=\(SceneRenderResources.shared.pendingWebRequestCount) model=\(String(describing: model.pages[page.id]?.elements.first { $0.id == source.id }?.state)) saved=\(saved.state)"
    }) {
      guard let web = self.webViews(in: host.controller.view).first,
        let owner = web.navigationDelegate as? AgentWebCoordinator else { return false }
      return owner.hasLiveSource(saved)
    }
    let returned = try XCTUnwrap(webViews(in: host.controller.view).first)
    XCTAssertFalse(returned === running)
    let shown = try await returned.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertEqual(shown, phase)
  }

  @MainActor
  func testPassivePageWithMatchingFocusDoesNotExecuteInteractiveContent() async throws {
    let model = makeModel()
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let source = element(id: UUID().uuidString, source: "passive", interactive: true)
    var page = try XCTUnwrap(model.activePage)
    page.replaceElements([source], actor: model.actorID)
    try model.store.savePage(page)
    model.reloadExternalChanges()
    await model.finishPendingPersistence()
    page = try XCTUnwrap(model.pages[page.id])
    XCTAssertEqual(page.elements, [source])
    let originalStamp = page.agentStamp
    XCTAssertTrue(SceneRenderResources.shared.store(raster(), for: source))
    model.interactiveElementFocus = .page(pageID: page.id, elementID: source.id)
    var ready = false
    let host = try SurfaceHost(content: AnyView(PageSurface(page: page, isCurrent: false, isInteractive: false,
      isVisible: true, onRenderReady: .init { ready = $0 })
      .environment(model)))
    defer { host.close() }
    try await waitUntil("A passive page renders its cached overlay") { ready }
    XCTAssertTrue(webViews(in: host.controller.view).isEmpty,
      "Page thumbnails and neighboring sheets do not activate the focused element.")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(model.pages[page.id]?.agentStamp, originalStamp)
    XCTAssertEqual(model.pages[page.id]?.elements, [source])
    await model.finishPendingPersistence()
  }

  @MainActor
  private func fallbackCohort(boardID: UUID, receipts: [SceneSourceAddress: SceneSourceReceipt],
    rasters: [SceneSourceAddress: RasterLease]) -> SceneCompositionCohort {
    let stamp = VersionStamp(counter: 1, actor: UUID())
    let item = WorkspaceItem.notebook(title: "Consumer contract", pageIDs: [UUID()])
    let workspace = WorkspaceIndex(items: [item], selectedItemID: item.id, selectedPageID: item.pageIDs.first,
      stamp: stamp, rootBoardID: boardID)
    let hierarchy = BoardHierarchy(rootBoardID: boardID,
      boards: [.init(id: boardID, board: .init(freeItems: [], stamp: stamp))], stamp: stamp)
    let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy, paperSizes: [:])
    let presence = SessionPresence(boardID: boardID, mode: .board, camera: .init(), viewport: .init(x: 160, y: 120))
    let frame = WorkspaceSceneFrame(index: index, presence: presence, portalCamera: { _ in nil })
    let plan = SceneCompositionPlan(revision: 1, workspaceID: index.generationID, rootBoardID: boardID,
      inkBoardIDs: [], liveOwners: [], protectedOwners: [], bands: [], coverage: [:],
      presentations: [.board(boardID): presence], tiles: [])
    return SceneCompositionCohort(plan: plan, frame: frame, requestedSources: frame.sourceIdentity,
      liveData: .init(documents: [:], states: [:], pages: [:], ink: .init(stamp: stamp)), rasters: [:], liveRasters: [:],
      nativeInk: .init(registry: .init(), rootBoardID: boardID, focusedCoverID: nil, owners: [:], updates: []),
      sourceReceipts: receipts, sourceRasters: rasters.compactMapValues { $0.retainedCopy() })
  }

  @MainActor
  private func redBounds(in image: UIImage) throws -> CGRect {
    let cg = try XCTUnwrap(image.cgImage)
    let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
      bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
    for y in 0..<cg.height {
      for x in 0..<cg.width {
        let offset = (y * cg.width + x) * 4
        if data[offset] > 220 && data[offset + 1] < 30 && data[offset + 2] < 30 && data[offset + 3] > 220 {
          minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
      }
    }
    guard maxX >= minX, maxY >= minY else { return .null }
    return .init(x: Double(minX) / image.scale, y: Double(minY) / image.scale,
      width: Double(maxX - minX + 1) / image.scale, height: Double(maxY - minY + 1) / image.scale)
  }

  @MainActor
  private func storeFallbackImage(_ image: UIImage, for source: SceneRasterSource) -> RasterLease? {
    let resources = SceneRenderResources.shared
    guard let pixels = image.cgImage,
      let reservation = resources.reserveRaster(pixelWidth: pixels.width, pixelHeight: pixels.height) else { return nil }
    defer { reservation.release() }
    return resources.storeAndRetain(image, for: source, reservation: reservation)
  }

  @MainActor
  private func fallbackImage(size: CGSize, scale: CGFloat, color: UIColor) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = scale
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      color.setFill(); context.fill(CGRect(origin: .zero, size: size))
    }
  }

  @MainActor
  private func makeModel() -> NotebookAppModel {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    return model
  }

  private func element(id: String, source: String, interactive: Bool = false) -> AgentElement {
    AgentElement(id: id, kind: .web, frame: .init(x: 0, y: 0, width: 160, height: 120), source: source,
      html: "<div style='width:100%;height:100%;background:#67aade'>\(source)</div>",
      javaScript: interactive ? """
        document.body.dataset.owner = '\(id)';
        let tick = 0;
        window.notebook.commit({owner: '\(id)', tick});
        setInterval(() => window.notebook.commit({owner: '\(id)', tick: ++tick}), 30);
        notebook.ready(Promise.resolve());
        """ : "")
  }

  @MainActor
  private func raster() -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 2
    return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: format).image { context in
      UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
    }
  }

  @MainActor
  private func webViews(in view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
  }

  @MainActor
  private func rasterViews(in view: UIView) -> [AgentSnapshotRasterView] {
    (view as? AgentSnapshotRasterView).map { [$0] } ?? view.subviews.flatMap { rasterViews(in: $0) }
  }

  @MainActor
  private func retainedFailureDiagnostic(window: UIWindow, original: RasterLease,
    cohort: RasterLease?, receipt: SceneSourceReceipt?) -> String {
    let views = rasterViews(in: window)
    var drawn = false
    let pixels = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
      drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: pixels)
    attachment.name = "Actual terminal failure surface at failed observation"
    attachment.lifetime = .keepAlways; add(attachment)
    let originalShown = views.map { $0.installation(for: original).isInstalled }
    let originalMounted = views.map { $0.installation(for: original, requiresVisibility: false).isInstalled }
    let cohortShown = cohort.map { current in views.map { $0.installation(for: current).isInstalled } }
    return "drawHierarchy=\(drawn), original=\(original.entryID), originalShown=\(originalShown), originalMounted=\(originalMounted), "
      + "cohort=\(String(describing: cohort?.entryID)), cohortShown=\(String(describing: cohortShown)), "
      + "receipt=\(String(describing: receipt))"
  }

  @MainActor
  private func assertVisibleFailureAndRetry(in window: UIWindow) throws -> UIImage {
    // SwiftUI exposes its virtual accessibility tree through the system AX
    // service, not UIView.accessibilityElementCount in an app unit test. This
    // visual contract reads the actual rendered text; XCUITest owns AX/gestures.
    var drawn = false
    let pixels = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
      drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let screenshot = XCTAttachment(image: pixels)
    screenshot.name = "Actual failure pixels inspected by native text recognition"
    screenshot.lifetime = .keepAlways; add(screenshot)
    XCTAssertTrue(drawn, "The actual mounted window must finish its image capture")
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ru-RU", "en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: XCTUnwrap(pixels.cgImage)).perform([request])
    let words = (request.results ?? []).compactMap { $0.topCandidates(1).first }
    let recognized = words.map(\.string).joined(separator: " ")
    let evidence = XCTAttachment(string: "drawHierarchy=\(drawn)\n" + words.map {
      "\($0.confidence): \($0.string)"
    }.joined(separator: "\n"))
    evidence.name = "Actual rendered error and Retry text"
    evidence.lifetime = .keepAlways; add(evidence)
    XCTAssertTrue(words.contains { $0.string.caseInsensitiveCompare("Повторить") == .orderedSame && $0.confidence >= 0.5 },
      "The actual window pixels must show readable Retry: \(recognized)")
    XCTAssertTrue(recognized.contains("Не удалось подготовить") && recognized.contains("изображение"),
      "The same visible surface must explain its source-local failure: \(recognized)")
    return pixels
  }

  @MainActor
  private func waitUntil(_ message: String, timeout: Duration = .seconds(8), diagnostic: (() -> String)? = nil,
    condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard condition() else {
      if let diagnostic {
        let attachment = XCTAttachment(string: diagnostic())
        attachment.name = message + " — physical owner diagnostic"
        attachment.lifetime = .keepAlways; add(attachment)
      }
      XCTFail(message)
      throw NSError(domain: "PreparedAgentElementViewTests", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
}

// Like the actual page host, this fixture observes the current model projection
// instead of keeping an initial PageDocument after its program writes state.
private struct LivePageFixture: View {
  @Environment(NotebookAppModel.self) private var model
  let pageID: UUID
  let current: Bool
  let input: Bool
  var body: some View {
    if let page = model.pages[pageID] {
      PageSurface(page: page, isCurrent: current, isInteractive: input,
        isVisible: true, onRenderReady: .init { _ in })
    }
  }
}

@MainActor
private final class SurfaceHost {
  let window: UIWindow
  let controller: UIHostingController<AnyView>

  init(content: AnyView) throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    window = UIWindow(windowScene: scene)
    controller = UIHostingController(rootView: content)
    window.rootViewController = controller
    window.makeKeyAndVisible()
  }

  func close() {
    controller.rootView = AnyView(EmptyView())
    window.isHidden = true
    window.rootViewController = nil
  }
}

@MainActor
@Observable
private final class PageProgramViewport { var region: CGRect? }

private struct PageProgramViewportFixture: View {
  let viewport: PageProgramViewport
  let page:PageDocument
  let onState: (String, JSONValue) -> Bool
  var body: some View {
    AgentOverlayView(page:page,renderingScale:1,
      allowsInteraction: true, inputEnabled: true, onRenderReady: { _ in },
      onState: onState, visibleRegion: viewport.region)
      .frame(width: 400, height: 320)
  }
}
