@testable import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class PreparedAgentElementLifetimeTests: XCTestCase {
  func testViewportExitRetainsTheAcceptedHeapUntilAllocatorPressureAndReturnsToItWithoutBoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try model.store.loadPage(XCTUnwrap(model.activePage).id)
    let source = AgentElement(id: "resident-program", kind: .web,
      frame: .init(x: 20, y: 20, width: 220, height: 100), source: "Resident program",
      html: "<output></output>", css: "html,body{margin:0;width:100%;height:100%}", javaScript: """
        window.nonce=Math.random().toString(36);let phase=notebook.state.phase;
        function paint(){document.body.style.background=phase===7?'#ef2218':'#086fff'}
        window.advance=()=>{phase=7;paint()};paint();
        notebook.lifecycle({pause:()=>{},checkpoint:()=>({phase}),resume:()=>{}});
        notebook.ready(Promise.resolve());
        """, state: .object(["phase": .number(0)]))
    page.replaceElements([source], actor: model.actorID)
    try model.store.savePage(page); await model.reloadExternalChanges()?.value
    let resources = SceneRenderResources(maximumWebSurfaces: 1, reservedInteractiveSlots: 0)
    let focus = InteractiveElementReference.page(pageID: page.id, elementID: source.id)
    let owner = resources.programPreparation(focus: focus, model: model)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { resources.retireProgramPreparations(ownedBy: model); window.isHidden = true; window.rootViewController = nil }
    func accept(_ element: AgentElement, active: Bool, into destination: PreparedAgentElementPreparationOwner? = nil) {
      (destination ?? owner).accept(.init(model: model, demand: .init(source: element,
        basis: model.programStateBasis(focus: focus, rendered: element), active: active, inputEnabled: active,
        focused: false, permitsPreparation: true, policy: .exact(scale: 1), capture: nil,
        fallbackEntryID: nil, runtimeFailure: nil), focus: focus, pageTurnActivity: nil,
        rasterPreparation: nil, cohort: nil, onState: { _, completion in completion(nil); return false }))
    }
    accept(source, active: true)
    try await wait(owner: owner) { owner.session != nil }
    let session = try XCTUnwrap(owner.session), web = session.webView
    let viewport = UIView(frame: .init(x: 20, y: 20, width: 220, height: 100))
    controller.view.addSubview(viewport); viewport.addSubview(web); web.frame = viewport.bounds
    try await wait(owner: owner) { owner.liveProgram != nil }
    let initialNonce = try await web.evaluateJavaScript("window.nonce") as? String
    let nonce = try XCTUnwrap(initialNonce)
    _ = try await web.evaluateJavaScript("window.advance();true")
    // Native page retirement hides the ancestor before asynchronous checkpoint
    // completion. Its own frozen heap still supplies the passive return image.
    viewport.isHidden = true
    XCTAssertFalse(try XCTUnwrap(session.coordinator.installation(for: source)).isInstalled)
    resources.leaveProgramPreparation(owner, focus: focus, model: model)
    await owner.waitForPreparation()
    let accepted = try XCTUnwrap(try model.store.loadPage(page.id).element(id: source.id))
    XCTAssertEqual(accepted.state["phase"], .number(7))
    XCTAssertNotNil(owner.raster?.image(for: .agent(accepted), minimumScale: 1),
      "A hidden, accepted heap must retain its exact image before reclamation")
    XCTAssertTrue(owner.session === session)
    XCTAssertTrue(session.coordinator.isViewportPaused)
    XCTAssertTrue(resources.programPreparation(focus: focus, model: model) === owner)
    viewport.isHidden = false
    accept(accepted, active: true)
    await owner.waitForPreparation()
    XCTAssertTrue(owner.session === session)
    XCTAssertFalse(session.coordinator.isViewportPaused)
    let returnedNonce = try await web.evaluateJavaScript("window.nonce") as? String
    XCTAssertEqual(returnedNonce, nonce)
    viewport.isHidden = true
    resources.leaveProgramPreparation(owner, focus: focus, model: model)
    await owner.waitForPreparation()
    let replacement = try await resources.acquireWebSurface(priority: .input)
    defer { replacement.release() }
    XCTAssertNil(owner.session)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    let returning = resources.programPreparation(focus: focus, model: model)
    XCTAssertFalse(returning === owner)
    accept(accepted, active: false, into: returning)
    await returning.waitForPreparation()
    XCTAssertNil(returning.session, "The admitted return image does not construct another browser")
    let raster = try XCTUnwrap(returning.raster)
    XCTAssertNotNil(raster.image(for: .agent(accepted), minimumScale: 1))
    let imageView = AgentSnapshotRasterView()
    imageView.frame = viewport.frame; imageView.updateRaster(raster)
    controller.view.addSubview(imageView); imageView.layoutIfNeeded()
    XCTAssertTrue(imageView.installation(for: raster).isInstalled)
    let pixels = try await NotebookUXObservation.observe(since: .now, budget: .seconds(1)) {
      try NotebookUXObservation.Pixels(window: window).matches([(.init(x: 130, y: 70), .red)])
    }
    XCTAssertTrue(pixels.matched, "The reclaimed program returns its accepted pixels while its runtime is absent")
  }

  func testCommitAcceptedWhileFreezeStartsIsAcknowledgedBeforeTheFrozenModelCAS() async throws {
    var held: (JSONValue, NotebookProgramStateCompletion)?
    let f = try await residentProgram(javaScript: """
      notebook.lifecycle({checkpoint:()=>({phase:notebook.state.phase+1}),resume:()=>{}});
      """, onState: { value, completion in held = (value, completion); return true })
    defer { held?.1(nil); f.close() }
    let session = try XCTUnwrap(f.owner.session), web = session.webView
    let nonce = try await web.evaluateJavaScript("window.nonce") as? String
    // Deliver a real authored commit after native has selected its basis, just
    // as a posted WebKit message can arrive while checkpoint starts draining.
    _ = try await web.evaluateJavaScript("""
      window.fixtureProgram=window.notebookProgram;
      const wrapper=Object.create(window.fixtureProgram);
      Object.defineProperty(wrapper,'checkpoint',{value:options=>{
        window.fixtureCommitAccepted=fixtureProgram.api.commit({phase:5});
        return fixtureProgram.checkpoint(options);
      }});
      window.notebookProgram=wrapper;true;
      """)
    let boundary = Task { @MainActor in try await session.coordinator.pauseForViewport() }
    defer { boundary.cancel() }
    try await wait { held != nil }
    let accepted = try await web.evaluateJavaScript("window.fixtureCommitAccepted") as? Bool
    XCTAssertEqual(accepted, true)
    XCTAssertEqual(try f.model.store.readPageElement(pageID: f.pageID, elementID: f.source.id)?.state["phase"], .number(0))
    let pending = try XCTUnwrap(held); held = nil
    XCTAssertTrue(f.model.commitElementState(pageID: f.pageID, elementID: f.source.id,
      state: pending.0, onCommitted: pending.1))
    let checkpointResult = try await boundary.value
    let checkpoint = try XCTUnwrap(checkpointResult)
    XCTAssertEqual(checkpoint.source.state["phase"], .number(6))
    XCTAssertEqual(try f.model.store.readPageElement(pageID: f.pageID, elementID: f.source.id)?.state, checkpoint.source.state)
    let acknowledged = try await web.evaluateJavaScript("""
      (()=>{try{fixtureProgram.readSnapshot({revision:'1'});return false}catch{return true}})()
      """) as? Bool
    XCTAssertEqual(acknowledged, true, "The frozen CAS follows the durable writer and the original browser ACK")
    _ = try await web.evaluateJavaScript("window.notebookProgram=window.fixtureProgram;true")
    let resumed = await session.coordinator.resumeForViewport()
    XCTAssertTrue(resumed)
    XCTAssertTrue(f.owner.session === session)
    let returnedNonce = try await web.evaluateJavaScript("window.nonce") as? String
    XCTAssertEqual(returnedNonce, nonce)
  }

  func testExplicitRetryFinishesTheSameDiskBlockedCheckpointBeforeResumingItsHeap() async throws {
    // A no-op checkpoint reports a failed observation; a changed model remains
    // an accepted FIFO slot. Both return through the same explicit Retry action.
    for phase in [0, 7] {
      var marker: URL?
      let f = try await residentProgram(javaScript: """
        window.checkpoints=0;
        notebook.lifecycle({checkpoint:()=>{checkpoints++;return {phase:\(phase)}},resume:()=>{}});
        """, makeStore: { root in
          let path = root.appendingPathComponent("checkpoint-disk-failure"); marker = path
          return NotebookStore(root: root) {
            if $0 == .beforeCommit, FileManager.default.fileExists(atPath: path.path) { throw CocoaError(.fileWriteUnknown) }
          }
        })
      let path = try XCTUnwrap(marker), session = try XCTUnwrap(f.owner.session), web = session.webView
      defer { try? FileManager.default.removeItem(at: path); f.queue.retry(); f.close() }
      let nonce = try await web.evaluateJavaScript("window.nonce") as? String
      try Data().write(to: path)
      f.resources.leaveProgramPreparation(f.owner, focus: f.focus, model: f.model)
      try await wait { phase == 0 ? f.owner.failure != nil : f.queue.failure != nil }
      XCTAssertTrue(f.owner.session === session)
      XCTAssertTrue(session.coordinator.isViewportPaused)
      XCTAssertEqual(try f.model.store.readPageElement(pageID: f.pageID, elementID: f.source.id)?.state["phase"], .number(0))
      f.accept(f.source, active: true)
      if phase == 0 { await f.owner.waitForPreparation(); XCTAssertNotNil(f.owner.failure) }
      try FileManager.default.removeItem(at: path)
      f.owner.retryPreparation()
      await f.owner.waitForPreparation()
      XCTAssertNil(f.queue.failure); XCTAssertNil(f.owner.failure)
      XCTAssertTrue(f.owner.session === session)
      XCTAssertFalse(session.coordinator.isViewportPaused)
      XCTAssertEqual(try f.model.store.readPageElement(pageID: f.pageID, elementID: f.source.id)?.state["phase"], .number(Double(phase)))
      let checkpointCalls = try await web.evaluateJavaScript("window.checkpoints") as? Int
      XCTAssertEqual(checkpointCalls, 1, "Disk Retry reuses the frozen result instead of invoking the author again")
      let returnedNonce = try await web.evaluateJavaScript("window.nonce") as? String
      XCTAssertEqual(returnedNonce, nonce)
    }
  }

  @MainActor private struct ResidentProgram {
    let model: NotebookAppModel
    let queue: NotebookPersistenceQueue
    let pageID: UUID
    let source: AgentElement
    let resources: SceneRenderResources
    let owner: PreparedAgentElementPreparationOwner
    let window: UIWindow
    let writer: NotebookProgramStateWriter
    var focus: InteractiveElementReference { .page(pageID: pageID, elementID: source.id) }
    func accept(_ source: AgentElement, active: Bool) {
      owner.accept(.init(model: model, demand: .init(source: source,
        basis: model.programStateBasis(focus: focus, rendered: source), active: active, inputEnabled: active,
        focused: true, permitsPreparation: true, policy: .exact(scale: 1), capture: nil,
        fallbackEntryID: nil, runtimeFailure: nil), focus: focus, pageTurnActivity: nil,
        rasterPreparation: nil, cohort: nil, onState: writer))
    }
    func close() {
      resources.retireProgramPreparations(ownedBy: model)
      window.isHidden = true; window.rootViewController = nil
    }
  }

  private func residentProgram(javaScript: String, makeStore: ((URL) -> NotebookStore)? = nil,
    onState: NotebookProgramStateWriter? = nil) async throws -> ResidentProgram {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = makeStore?(root) ?? NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false, persistenceQueue: queue)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    var page = try store.loadPage(XCTUnwrap(model.activePage).id)
    let source = AgentElement(id: "checkpoint-resident", kind: .web,
      frame: .init(x: 20, y: 20, width: 220, height: 100), source: "Resident checkpoint",
      html: "<output>Checkpoint</output>", javaScript: """
        window.nonce=Math.random().toString(36);
        \(javaScript)
        notebook.ready(Promise.resolve());
        """, state: .object(["phase": .number(0)]))
    page.replaceElements([source], actor: model.actorID)
    try store.savePage(page); await model.reloadExternalChanges()?.value
    let finished = await model.finishPendingPersistence(); XCTAssertTrue(finished)
    let resources = SceneRenderResources(maximumWebSurfaces: 1, reservedInteractiveSlots: 0)
    let pageID = page.id, focus = InteractiveElementReference.page(pageID: pageID, elementID: source.id)
    let owner = resources.programPreparation(focus: focus, model: model)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    let f = ResidentProgram(model: model, queue: queue, pageID: pageID, source: source,
      resources: resources, owner: owner, window: window, writer: onState ?? { value, completion in
        model.commitElementState(pageID: pageID, elementID: source.id, state: value, onCommitted: completion)
      })
    f.accept(source, active: true)
    try await wait(owner: owner) { owner.session != nil }
    let web = try XCTUnwrap(owner.session).webView
    controller.view.addSubview(web); web.frame = .init(x: 20, y: 20, width: 220, height: 100)
    try await wait(owner: owner) { owner.liveProgram != nil }
    return f
  }

  private func wait(owner: PreparedAgentElementPreparationOwner? = nil,
    file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate(), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let detail = owner.map { "\($0.diagnostic()); runtime=\($0.session?.coordinator.preparationDiagnostic() ?? "absent")" } ?? ""
    _ = try XCTUnwrap(predicate() ? true : nil, detail, file: file, line: line)
  }

  func testLateMountCannotAcquireResourcesAfterTheModelHasStopped() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let stopped = await model.shutdown()
    XCTAssertTrue(stopped)
    let resources = SceneRenderResources.shared
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 64, height: 64), source: "Late mount", html: "red")
    let image = UIGraphicsImageRenderer(size: .init(width: 64, height: 64)).image { context in
      UIColor.red.setFill(); context.fill(.init(x: 0, y: 0, width: 64, height: 64))
    }
    XCTAssertTrue(resources.store(image, for: element))
    let before = resources.rasterAdmission.pinnedBytes
    let webBefore = resources.activeWebSurfaceCount
    var ready = false
    let host = UIHostingController(rootView: PreparedAgentElementView(element: element,
      allowsInteraction: false, focus: .board(boardID: UUID(), elementID: element.id),
      onRenderReady: { ready = ready || $0 }, onState: { _, _ in false }).environment(model))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, before)
    XCTAssertEqual(resources.activeWebSurfaceCount, webBefore)
    XCTAssertFalse(ready, "A stale SwiftUI mount cannot report a new ready presentation after shutdown")
  }

  func testUninstalledSwiftUIConfigurationsCannotPinThePreparedRaster() throws {
    let resources = SceneRenderResources.shared
    let element = AgentElement(id: UUID().uuidString, kind: .web,
      frame: .init(x: 0, y: 0, width: 64, height: 64), source: "Prepared red marker", html: "red")
    let image = UIGraphicsImageRenderer(size: .init(width: 64, height: 64)).image { context in
      UIColor.red.setFill(); context.fill(.init(x: 0, y: 0, width: 64, height: 64))
    }
    XCTAssertTrue(resources.store(image, for: element))
    let before = resources.rasterAdmission.pinnedBytes
    let configurations = (0..<100).map { _ in
      PreparedAgentElementView(element: element, allowsInteraction: false,
        focus: .board(boardID: UUID(), elementID: element.id), onRenderReady: { _ in }, onState: { _, _ in false })
    }
    withExtendedLifetime(configurations) {
      XCTAssertEqual(resources.rasterAdmission.pinnedBytes, before,
        "A cached SwiftUI value has not installed a presenter and cannot acquire its raster")
    }
  }
}
