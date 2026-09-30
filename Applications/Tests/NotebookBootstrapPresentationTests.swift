import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor final class NotebookBootstrapPresentationTests: XCTestCase {
  private enum Outcome: CaseIterable, Sendable { case ready, failure, shutdown }
  private enum Failure: Error { case bootstrap, deadline(String) }
  private struct Receipt: Sendable { let basis: NotebookProgramStateBasis? }

  func testAcceptedRootPreparesWhileProgramWritesAndContactsWaitForBootstrapOutcome() async throws {
    let cancelledAdmission = NotebookBootstrapAdmission()
    let cancelledWait = Task { await cancelledAdmission.waitForProgramWrites() }
    await Task.yield()
    cancelledWait.cancel()
    let acceptedCancelledWait = await cancelledWait.value
    XCTAssertFalse(acceptedCancelledWait, "An async document withdrawal resolves its bootstrap continuation")
    for outcome in Outcome.allCases { try await heldBootstrap(outcome) }
  }

  func testSupersededForegroundProgramReplacesItsSessionBeforeFurtherInput() async throws {
    try await heldBootstrap(.ready, checksForegroundRevocation: true)
  }

  private func heldBootstrap(_ outcome: Outcome, checksForegroundRevocation: Bool = false) async throws {
    let resources = SceneRenderResources.shared
    let webBaseline = resources.activeWebSurfaceCount
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-presentation-\(UUID())")
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
    let index = try store.loadIndex(), hierarchy = try store.loadBoard(items: index.items)
    var page = try store.loadPage(XCTUnwrap(index.selectedPageID))
    let element = AgentElement(id: "early", kind: .web,
      frame: .init(x: 45, y: 190, width: 170, height: 110), source: "Early program",
      html: "<button>Ready</button>", javaScript: outcome == .ready
        ? "notebook.ready(Promise.resolve())"
        : "if(!notebook.commit({count:1}))throw new Error('bootstrap_commit_not_admitted');notebook.ready(Promise.resolve())",
      state: .object(["count": .number(0)]))
    XCTAssertTrue(page.replaceElements([element], actor: actor))
    try store.savePage(page)
    let center = try XCTUnwrap(hierarchy.focusedCenter(of: index.selectedItemID, in: header.rootBoardID))
    try store.savePresence(.init(boardID: header.rootBoardID, mode: .page,
      camera: .init(center: center, scale: 1), viewport: .init(x: 834, y: 1194),
      focusedItemID: index.selectedItemID, openProgress: 1,
      selectedItemID: index.selectedItemID, notebookPageID: page.id))
    let queue = NotebookPersistenceQueue(store: store)
    let model = NotebookAppModel(store: store, startsNearbySync: false, persistenceQueue: queue)
    let blocker = NotebookPersistenceFenceContract.Blocker()
    let recovery = NotebookPersistenceFenceContract.Signal<Bool>()
    defer { recovery.set(true); blocker.release(); model.retryPendingPersistence() }
    var beganPreparation = false, runtimeReady = false, authoredWriteAdmitted = false, held = false
    var preparationEvents: [String] = []
    let stage = NotebookPersistenceFenceContract.Signal<String>()
    func mark(_ value: String) {
      stage.set(value)
      print("BOOTSTRAP_FIXTURE \(outcome) \(value)")
    }
    func diagnostic() -> String {
      "\(outcome): stage=\(stage.value ?? "none"), load=\(model.loadState), closing=\(model.shutdownPhase), queue=\(queue.pendingCount), persistence=\(model.persistenceFailure ?? "none"), events=\(preparationEvents), owners=\(AgentWebCoordinator.checkpointDiagnostics(ownedBy: model))"
    }
    func wait(_ value: String, _ predicate: () -> Bool) async throws {
      mark(value)
      do { try await NotebookPersistenceFenceContract.until(predicate) }
      catch { throw Failure.deadline(diagnostic()) }
    }
    func joined<Value: Sendable>(_ task: Task<Value, Never>, _ value: String) async throws -> Value {
      let result = NotebookPersistenceFenceContract.Signal<Value>()
      let watcher = Task { result.set(await task.value) }
      defer { watcher.cancel() }
      try await wait(value) { result.value != nil }
      return result.value!
    }
    mark("created")
    addTeardownBlock { @MainActor in
      let stopped = NotebookPersistenceFenceContract.Signal<Bool>()
      let task = Task { stopped.set(await model.shutdown()) }
      do { try await NotebookPersistenceFenceContract.until { stopped.value != nil } }
      catch {
        task.cancel()
        XCTFail("Bootstrap teardown deadline: \(outcome), phase=\(model.shutdownPhase), persistence=\(model.persistenceFailure ?? "none"), owners=\(AgentWebCoordinator.checkpointDiagnostics(ownedBy: model))")
        return
      }
      XCTAssertEqual(stopped.value, true, "The bootstrap writer must acknowledge teardown")
      if stopped.value == true { try FileManager.default.removeItem(at: root) }
    }
    XCTAssertNil(NotebookNavigationObservation.onWebPreparation)
    NotebookNavigationObservation.onWebPreparation = { stage, ownerID, source, _ in
      if source == element.id || stage.hasPrefix("startup_") || stage.hasPrefix("shutdown_") {
        mark("owner:" + stage)
        preparationEvents.append(stage)
        if preparationEvents.count > 24 { preparationEvents.removeFirst() }
      }
      if stage == "startup_state_installed", ownerID == model.actorID, !held {
        // This owner is already accepted, before root preparation can construct
        // its executor. A focused author may commit; physical contacts remain
        // blocked by the unresolved bootstrap gate.
        if outcome != .ready {
          model.interactiveElementFocus = .page(pageID: page.id, elementID: element.id)
        }
        held = true
        queue.enqueueFence(owner: .presence) { _ in
          if blocker.entered.value != true { try blocker.hold() }
          if outcome == .failure, recovery.value != true { throw Failure.bootstrap }
          return false
        }
      }
      if stage == "source_accepted", source == element.id { beganPreparation = true }
      if stage == "runtime_ready", source == element.id { runtimeReady = true }
      if stage == "state_write_admitted", source == element.id { authoredWriteAdmitted = true }
    }
    defer { NotebookNavigationObservation.onWebPreparation = nil }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194)
    let host = UIHostingController(rootView: NotebookRootView().environment(model))
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let startup = Task { await model.start(pageSize: NotebookAppModel.defaultPageSize) }
    defer { startup.cancel() }
    try await wait("source-and-held-presence") { blocker.entered.value == true && beganPreparation }
    if outcome != .ready {
      try await wait("runtime-and-authored-write") { runtimeReady && authoredWriteAdmitted }
      XCTAssertGreaterThan(resources.activeWebSurfaceCount, webBaseline,
        "The failed/closing bootstrap exercises an actual prepared executor with a real bridge commit")
    }
    XCTAssertEqual(model.loadState, .loading)
    XCTAssertFalse(model.inputGate.permitsNewContact)
    let contact = NSObject(), source = UUID()
    XCTAssertFalse(model.inputGate.claimNavigation(source: source, kind: .pageTurn,
      contacts: [ObjectIdentifier(contact)], cancel: {}))
    let basis = try XCTUnwrap(model.pages[page.id]?.programStateBasis(element.id))
    let receipt = NotebookPersistenceFenceContract.Signal<Receipt>()
    let updated: JSONValue = .object(["count": .number(7)])
    XCTAssertTrue(model.commitElementState(pageID: page.id, elementID: element.id, state: updated,
      onCommitted: .init(sourceBasis: basis) { receipt.set(.init(basis: $0)) }))
    XCTAssertNil(receipt.value)
    XCTAssertEqual(model.pages[page.id]?.element(id: element.id)?.state, element.state)

    var stopping: Task<Bool, Never>?
    if outcome == .shutdown {
      stopping = Task { await model.shutdown() }
      try await wait("shutdown-admission") { model.shutdownPhase != .running }
      XCTAssertNotNil(receipt.value, "Closing resolves the accepted bootstrap message without waiting for its held disk operation")
      XCTAssertNil(receipt.value?.basis)
    }
    mark("release-presence")
    blocker.release()
    _ = try await joined(startup, "startup-joined")
    try await wait("manual-write-receipt") { receipt.value != nil }
    if outcome == .ready {
      XCTAssertEqual(model.loadState, .ready)
      XCTAssertTrue(model.inputGate.permitsNewContact)
      XCTAssertNotNil(receipt.value?.basis)
      XCTAssertEqual(try store.readPageElement(pageID: page.id, elementID: element.id)?.state, updated)
      if checksForegroundRevocation {
        let order = try XCTUnwrap(model.notebookPageRoot(index.selectedItemID))
        let entry = try XCTUnwrap(model.notebookPagePreparation.entry(at: 0, in: index.selectedItemID, root: order))
        let owner = entry.preparations.owner(for: element.id)
        try await NotebookPersistenceFenceContract.until { owner.session != nil && owner.showsLiveProgram }
        let previousSession = try XCTUnwrap(owner.session)
        let currentSource = try XCTUnwrap(model.pages[page.id]?.element(id: element.id))
        try await NotebookPersistenceFenceContract.until { previousSession.coordinator.hasLiveSource(currentSource) }
        previousSession.coordinator.use(onState: { _, completion in completion(nil); return true })
        let accepted = try await previousSession.webView.evaluateJavaScript("notebook.commit({count:2})") as? Bool
        XCTAssertEqual(accepted, true)
        try await NotebookPersistenceFenceContract.until { authoredWriteAdmitted }
        let checkpoint = Task { await AgentWebCoordinator.checkpointPrograms(ownedBy: model, resume: false) }
        let withdrawn = try await joined(checkpoint, "foreground-checkpoint")
        XCTAssertTrue(withdrawn, "An obsolete source outcome finishes the foreground checkpoint")
        XCTAssertTrue(previousSession.isRetired)
        XCTAssertTrue(previousSession.lease.isReleased)
        try await NotebookPersistenceFenceContract.until {
          owner.session != nil && owner.session !== previousSession && owner.showsLiveProgram
            && owner.session?.coordinator.hasLiveSource(currentSource) == true
        }
        XCTAssertEqual(try store.readPageElement(pageID: page.id, elementID: element.id)?.state, updated)
      }
    } else {
      XCTAssertFalse(model.inputGate.permitsNewContact)
      XCTAssertNil(receipt.value?.basis)
      XCTAssertEqual(try store.readPageElement(pageID: page.id, elementID: element.id)?.state, element.state)
      if outcome == .failure {
        guard case .failed = model.loadState else { XCTFail("A failed bootstrap must withdraw its accepted presentation"); return }
        XCTAssertNil(model.notebookPagePreparation.presentation(itemID: index.selectedItemID, boardID: header.rootBoardID))
        XCTAssertNil(model.compositionTiles.published)
        try await wait("failed-executors-released") { resources.activeWebSurfaceCount == webBaseline }
        XCTAssertEqual(resources.activeWebSurfaceCount, webBaseline,
          "Rejected bootstrap releases both live and retiring WebKit leases")
        XCTAssertEqual(try store.readPageElement(pageID: page.id, elementID: element.id)?.state, element.state,
          "Retirement cannot checkpoint an author whose workspace never became writable")
        mark("recover-presence")
        recovery.set(true); model.retryPendingPersistence()
      }
    }
    let stopped: Bool
    if let stopping { stopped = try await joined(stopping, "shutdown-joined") }
    else { stopped = try await joined(Task { await model.shutdown() }, "shutdown-joined") }
    let currentSource = model.pages[page.id]?.element(id: element.id) ?? element
    let checkpointErrors = resources.diagnostics(for: [element, currentSource]).map { "\($0.kind):\($0.message)" }
    XCTAssertTrue(stopped, "\(outcome): load=\(model.loadState), persistence=\(model.persistenceFailure ?? "none"), cue=\(model.actionCue ?? "none"), events=\(preparationEvents), owners=\(AgentWebCoordinator.checkpointDiagnostics(ownedBy: model)), errors=\(checkpointErrors)")
    XCTAssertEqual(try store.readPageElement(pageID: page.id, elementID: element.id)?.state,
      outcome == .ready ? updated : element.state, "\(outcome): closing preserves the already accepted model cut")
    try await wait("all-executors-released") { resources.activeWebSurfaceCount == webBaseline }
    mark("complete")
  }
}
