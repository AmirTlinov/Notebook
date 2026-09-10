import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

final class InstalledInkAttentionTests: XCTestCase {
  @MainActor
  func testFinishedPenAndEraserCaptureInstalledGeometryBeforeSQLOrCohortReplay() async throws {
    let fixture = try await fixture(), driver = try Driver(model: fixture.model, presence: fixture.presence, cohort: fixture.cohort)
    defer { driver.close() }
    let blocker = try NotebookSQLWriteBlocker(store: fixture.model.store)
    defer { try? blocker.release() }
    let pen = try driver.stroke(.pen), eraser = try driver.stroke(.eraser)
    let ink = try XCTUnwrap(driver.canvas.inkView)
    XCTAssertGreaterThan(ink.committedVertexCount, 0)
    XCTAssertGreaterThan(ink.committedEraserVertexCount, 0)
    let meshInstalls = ink.spatialMeshInstallCount
    let start = ContinuousClock.now
    let selection = try capture(fixture, driver: driver)
    fixture.model.publishHumanContext(selection)
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(50))
    XCTAssertTrue(driver.canvas.inkView === ink)
    XCTAssertEqual(ink.spatialMeshInstallCount, meshInstalls,
      "Capturing installed source must not replay geometry or wait for a new cohort")
    let records = try await Task.detached { try selection.sourceFiles()["spatial-ink.json"]?.decode(SpatialInkJournal.self) }.value
    XCTAssertEqual(records?.actions.map(\.id), [pen.id, eraser.id])
    try blocker.release()
    let saved = await fixture.model.finishPendingPersistence()
    XCTAssertTrue(saved, fixture.model.persistenceFailure ?? "")
    try await waitUntil { fixture.model.agentQuestion != nil }
    let reference = try XCTUnwrap(fixture.model.agentQuestion?.references.first)
    XCTAssertEqual(reference.revision, try fixture.model.store.referenceRevision(target: reference.target))
    XCTAssertEqual(fixture.model.compositionTiles.published?.id, fixture.cohort.id)
  }

  @MainActor
  func testCommandFenceKeepsTheFirstContactAndQuestionWhileNextInkAndCameraProceed() async throws {
    let fixture = try await fixture(), driver = try Driver(model: fixture.model, presence: fixture.presence, cohort: fixture.cohort)
    defer { driver.close() }
    let blocker = try NotebookSQLWriteBlocker(store: fixture.model.store)
    defer { try? blocker.release() }
    let first = try driver.stroke(.pen), selection = try capture(fixture, driver: driver)
    fixture.model.publishHumanContext(selection)
    let second = try driver.stroke(.pen)
    let moved = SessionPresence(boardID: fixture.presence.boardID, mode: .board,
      camera: .init(center: .init(x: 40, y: 60), scale: 1), viewport: fixture.presence.viewport)
    fixture.model.updatePresence(moved, settled: true)
    XCTAssertFalse(fixture.model.inputGate.hasActivePencil)
    try blocker.release()
    let saved = await fixture.model.finishPendingPersistence()
    XCTAssertTrue(saved, fixture.model.persistenceFailure ?? "")
    try await waitUntil { fixture.model.agentQuestion != nil }
    let question = try XCTUnwrap(fixture.model.agentQuestion), reference = try XCTUnwrap(question.references.first)
    XCTAssertNotEqual(reference.revision, try fixture.model.store.referenceRevision(target: reference.target))
    let frozen = try await Task.detached { try selection.sourceFiles()["spatial-ink.json"]?.decode(SpatialInkJournal.self) }.value
    XCTAssertEqual(frozen?.actions.map(\.id), [first.id])
    XCTAssertEqual(try fixture.model.store.readSpatialInk(surfaces: [.board(fixture.presence.boardID)]).actions.map(\.id), [first.id, second.id])
    let sent = await fixture.model.sendAgentQuestion("Что я указал?", mode: .question, question: question)
    XCTAssertTrue(sent, fixture.model.agentRequestError ?? "")
    let request = try XCTUnwrap(fixture.model.currentAgentRequest)
    XCTAssertEqual(request.request.grant.references, question.references)
    XCTAssertEqual(fixture.model.presence?.camera, moved.camera)
  }

  @MainActor
  func testUndoMustInstallItsOwnSourceAndDomainRejectionDoesNotPoisonNativeWrites() async throws {
    let fixture = try await fixture(), driver = try Driver(model: fixture.model, presence: fixture.presence, cohort: fixture.cohort)
    defer { driver.close() }
    _ = try driver.stroke(.pen)
    try await flush(fixture.model)
    fixture.model.undoLastSurfaceAction()
    let stale = try capture(fixture, driver: driver)
    fixture.model.publishHumanContext(stale)
    try await flush(fixture.model)
    try await waitUntil { fixture.model.agentRequestError != nil }
    XCTAssertNil(fixture.model.persistenceFailure)
    XCTAssertTrue(try fixture.model.store.sharedContexts(contextID: nil).contexts.isEmpty)
    try await driver.publishCurrentComposition()
    try await waitUntil {
      (try? driver.registry.installedSource(on: .board(fixture.presence.boardID))?.referenceInk().actions.first?.isActive) == false
    }
    let selection = try capture(fixture, driver: driver)
    fixture.model.publishHumanContext(selection)
    _ = try driver.stroke(.pen)
    try await flush(fixture.model)
    try await waitUntil { fixture.model.agentQuestion != nil }
    XCTAssertNil(fixture.model.persistenceFailure)
    XCTAssertEqual(try fixture.model.store.readSpatialInk(surfaces: [.board(fixture.presence.boardID)]).actions.filter(\.isActive).count, 1)
  }

  @MainActor
  func testPreparedParentHandsOffTheSameNonemptyChildOwnerAndExactSource() async throws {
    let fixture = try await fixture(withChild: true)
    let child = try XCTUnwrap(fixture.child)
    XCTAssertNotNil(fixture.cohort.plan.presentations[.board(child)])
    let prepared = try XCTUnwrap(fixture.cohort.nativeInk.owners[.board(child)]?.canvas)
    let preparedSource = try XCTUnwrap(prepared.installedSpatialSource?.referenceInk())
    XCTAssertEqual(preparedSource.actions, fixture.cohort.liveData.ink.actions.filter {
      $0.spans.contains { $0.surface == .board(child) }
    })
    XCTAssertGreaterThan(prepared.committedVertexCount, 0)
    let meshInstallations = prepared.spatialMeshInstallCount
    let presence = SessionPresence(boardID: child, mode: .board, camera: .init(scale: 1), viewport: .init(x: 512, y: 512))
    fixture.model.updatePresence(presence, settled: true)
    try await flush(fixture.model)
    try await waitUntil { !fixture.model.scenePreparationPending }
    let driver = try Driver(model: fixture.model, presence: presence, cohort: fixture.cohort)
    defer { driver.close() }
    try await waitUntil { driver.registry.installedSource(on: .board(child)) != nil }
    XCTAssertTrue(driver.canvas.inkView === prepared)
    XCTAssertEqual(prepared.spatialMeshInstallCount, meshInstallations)
    XCTAssertEqual(try driver.registry.installedSource(on: .board(child))?.referenceInk(), preparedSource)
    let selection = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 100, y: 100),
      end: .init(x: 180, y: 160), model: fixture.model, presence: presence, cohort: fixture.cohort,
      installedInk: driver.registry.installedSources()))
    fixture.model.publishHumanContext(selection)
    try await flush(fixture.model)
    try await waitUntil { fixture.model.agentQuestion != nil }
    let reference = try XCTUnwrap(fixture.model.agentQuestion?.references.first)
    XCTAssertEqual(reference.target, .init(kind: .board, id: child))
    XCTAssertEqual(reference.revision, try fixture.model.store.referenceRevision(target: reference.target))
    let ink = try await Task.detached { try selection.sourceFiles()["spatial-ink.json"]?.decode(SpatialInkJournal.self) }.value
    XCTAssertEqual(ink?.actions.count, 1)
    XCTAssertEqual(fixture.model.compositionTiles.published?.id, fixture.cohort.id)
  }

  @MainActor
  func testPointerWaitsForTheAcceptedPencilTailAndChangedStaticSourceCannotMintAContext() async throws {
    let fixture = try await fixture(), driver = try Driver(model: fixture.model, presence: fixture.presence, cohort: fixture.cohort)
    defer { driver.close() }
    driver.begin(.pen)
    fixture.model.afterPageInput { fixture.model.isPointing = true }
    XCTAssertFalse(fixture.model.isPointing)
    XCTAssertNil(driver.registry.installedSource(on: .board(fixture.presence.boardID)))
    driver.moveAndEnd()
    try await waitUntil { fixture.model.isPointing }
    XCTAssertGreaterThan(try XCTUnwrap(driver.canvas.inkView).committedVertexCount, 0)
    let selection = try capture(fixture, driver: driver)
    let item = try XCTUnwrap(fixture.model.store.readItemHeaders(limit: 1).first?.id)
    fixture.model.moveItem(item, to: .init(x: 15_000, y: 15_000))
    fixture.model.publishHumanContext(selection)
    try await flush(fixture.model)
    try await waitUntil { fixture.model.agentRequestError != nil && !fixture.model.scenePreparationPending }
    _ = try driver.stroke(.pen)
    try await flush(fixture.model)
    try await waitUntil { fixture.model.agentRequestError != nil }
    XCTAssertNil(fixture.model.persistenceFailure)
    XCTAssertTrue(try fixture.model.store.sharedContexts(contextID: nil).contexts.isEmpty)
    XCTAssertEqual(try fixture.model.store.readSpatialInk(surfaces: [.board(fixture.presence.boardID)]).actions.count, 2)
  }

  @MainActor
  func testCardRejectsANewPencilContactWithoutTruncatingAnAcceptedContactWhenItMoves() async throws {
    let fixture = try await fixture(), driver = try Driver(model: fixture.model, presence: fixture.presence, cohort: fixture.cohort)
    let card = NotebookControlRegionView(gate: fixture.model.inputGate)
    card.frame = .init(x: 100, y: 100, width: 100, height: 100)
    driver.attach(card)
    defer { card.unregister(); driver.close() }
    let previousActions = fixture.model.spatialInk?.actions.count ?? 0
    let previousGeneration = fixture.model.inputGate.pencilGeneration
    let ink = try XCTUnwrap(driver.canvas.inkView)
    let previousVertices = ink.committedVertexCount

    XCTAssertFalse(fixture.model.inputGate.permitsSceneContact(at: .init(x: 120, y: 120)))
    driver.begin(.pen)
    // UIKit may reset a rejected attached recognizer to .possible immediately.
    // The contract is that no began event reaches the physical ink owner.
    XCTAssertFalse(driver.didBeginContact)
    XCTAssertFalse(fixture.model.inputGate.hasActivePencil)
    XCTAssertEqual(fixture.model.inputGate.pencilGeneration, previousGeneration)
    driver.moveAndEnd()
    XCTAssertEqual(fixture.model.spatialInk?.actions.count ?? 0, previousActions)
    XCTAssertTrue(driver.canvas.inkView === ink)
    XCTAssertEqual(ink.committedVertexCount, previousVertices)

    card.frame.origin = .init(x: 320, y: 320)
    driver.begin(.pen)
    XCTAssertTrue(driver.didBeginContact)
    XCTAssertEqual(driver.recognizerState, .began)
    XCTAssertTrue(fixture.model.inputGate.hasActivePencil)
    let acceptedGeneration = fixture.model.inputGate.pencilGeneration
    XCTAssertNil(driver.registry.installedSource(on: .board(fixture.presence.boardID)))
    card.frame.origin = .init(x: 100, y: 100)
    driver.update(.pen)
    XCTAssertFalse(fixture.model.inputGate.permitsSceneContact(at: .init(x: 160, y: 120)))
    XCTAssertTrue(fixture.model.inputGate.hasActivePencil)
    XCTAssertEqual(fixture.model.inputGate.pencilGeneration, acceptedGeneration)
    driver.moveAndEnd()
    XCTAssertEqual(driver.recognizerState, .ended)
    XCTAssertFalse(fixture.model.inputGate.hasActivePencil)
    XCTAssertEqual(fixture.model.spatialInk?.actions.count, previousActions + 1)
    let action = try XCTUnwrap(fixture.model.spatialInk?.actions.last)
    let span = try XCTUnwrap(action.spans.first)
    XCTAssertEqual(action.spans.count, 1)
    XCTAssertEqual(span.surface, .board(fixture.presence.boardID))
    XCTAssertEqual(span.samples.count, 2, "Moving the card must not split or truncate the accepted Pencil tail")
    XCTAssertEqual(span.samples.last?.timeOffset ?? -1, 0.1, accuracy: 0.000_001)
    XCTAssertEqual(try driver.registry.installedSource(on: span.surface)?.referenceInk().actions.map(\.id), [action.id])
    try await flush(fixture.model)
    XCTAssertEqual(try fixture.model.store.readSpatialInk(surfaces: [span.surface]).actions, [action])
  }

  @MainActor
  func testNestedLiveCoverUsesTheSceneReceiptAndOldUnregisterCannotRemoveItsReplacement() async throws {
    let fixture = try await fixture(withChild: true, withNestedCover: true)
    let child = try XCTUnwrap(fixture.child), nested = try XCTUnwrap(fixture.nestedCover)
    XCTAssertTrue(fixture.cohort.plan.allowsLive(.item(nested), in: .board(child)))
    let driver = try Driver(model: fixture.model, presence: fixture.presence, cohort: fixture.cohort)
    defer { driver.close() }
    let item = try XCTUnwrap(fixture.cohort.frame.workset(boardID: fixture.presence.boardID).items.first { $0.id == child })
    let portal = WorkspaceItemCoverView(item: item.item, geometry: item.geometry, spatialInkSurfaces: driver.registry,
      elements: [], editingTextID: nil, isElementEditingEnabled: false, portalOpenProgress: 0,
      portalViewport: fixture.presence.viewport, onTap: { _, _ in },
        onTextEditingEnded: { _ in }, onElementSelected: {})
    let host = UIHostingController(rootView: AnyView(portal
      .frame(width: item.geometry.width, height: item.geometry.height).scaleEffect(0.3)
      .environment(\.sceneComposition, .init(fixture.cohort)).environment(fixture.model)))
    driver.attach(host)
    try await waitUntil {
      driver.registry.installedSource(on: .board(fixture.presence.boardID)) != nil
        && driver.registry.installedSource(on: .cover(child)) != nil
        && driver.registry.installedSource(on: .cover(nested)) != nil
    }
    XCTAssertTrue(driver.registry.canvas(for: .board(child)) === fixture.cohort.nativeInk.owners[.board(child)]?.canvas,
      "The child portal mounts the same admitted physical ink owner")
    let nestedSource = try XCTUnwrap(driver.registry.installedSource(on: .cover(nested)))
    XCTAssertEqual(try nestedSource.referenceInk().actions.count, 1)
    let selection = try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 40, y: 40),
      end: .init(x: 70, y: 70), model: fixture.model, presence: fixture.presence, cohort: fixture.cohort,
      installedInk: driver.registry.installedSources()))
    fixture.model.publishHumanContext(selection)
    try await flush(fixture.model)
    try await waitUntil { fixture.model.agentQuestion != nil || fixture.model.agentRequestError != nil }
    XCTAssertNil(fixture.model.agentRequestError)
    let reference = try XCTUnwrap(fixture.model.agentQuestion?.references.first)
    XCTAssertEqual(reference.target, .init(kind: .board, id: fixture.presence.boardID))
    XCTAssertEqual(reference.revision, try fixture.model.store.referenceRevision(target: reference.target))

    let oldCanvas = try XCTUnwrap(driver.registry.canvas(for: .cover(nested)))
    // End the former projection's real SwiftUI lifetime. Keeping that owner
    // mounted would allow its next update to legitimately register it again.
    driver.detach(host)
    let replacement = InkCanvasView(frame: oldCanvas.frame)
    replacement.applySpatial(try .prepare(surface: .cover(nested), journal: fixture.cohort.liveData.ink))
    replacement.installSpatialSource(fixture.cohort.liveData.ink, on: .cover(nested))
    driver.registry.register(replacement, for: .cover(nested))
    defer { driver.registry.unregister(replacement, for: .cover(nested)) }
    try await waitUntil { driver.registry.installedSource(on: .cover(nested)) != nil }
    driver.registry.unregister(oldCanvas, for: .cover(nested))
    XCTAssertTrue(driver.registry.canvas(for: .cover(nested)) === replacement)
    XCTAssertEqual(try driver.registry.installedSource(on: .cover(nested))?.referenceInk(), try nestedSource.referenceInk(),
      "The old physical projection's teardown must not erase its new registration or installed receipt")
  }

  private struct Fixture {
    let model: NotebookAppModel
    let cohort: SceneCompositionCohort
    let presence: SessionPresence
    let child: UUID?
    let nestedCover: UUID?
  }

  @MainActor
  private func fixture(withChild: Bool = false, withNestedCover: Bool = false) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
    let before = try store.loadIndex(), boardBefore = try store.loadBoard(items: before.items)
    var index = before, hierarchy = boardBefore
    XCTAssertTrue(hierarchy.moveItem(before.selectedItemID, in: header.rootBoardID,
      to: .init(x: 20_000, y: 20_000), actor: actor))
    let child: UUID? = withChild ? UUID() : nil
    if let child {
      XCTAssertNotNil(index.createBoard(title: "", actor: actor, boardID: child))
      XCTAssertTrue(hierarchy.createBoard(child, in: header.rootBoardID, near: .zero, actor: actor))
    }
    var nestedCover: UUID?
    if withNestedCover {
      let created = try XCTUnwrap(index.createNotebook(title: "Nested ink", actor: actor, pageSize: NotebookAppModel.defaultPageSize))
      nestedCover = created.item.id
      XCTAssertTrue(hierarchy.addItem(created.item.id, to: try XCTUnwrap(child), near: .zero, actor: actor))
      try store.saveWorkspaceBundle(index: index, page: created.page, board: hierarchy)
    } else {
      _ = try store.saveWorkspaceEdits(before: before, after: index, boardBefore: boardBefore, boardAfter: hierarchy)
    }
    if let child {
      var journal = try store.readSpatialInk(surfaces: [.board(child)])
      journal.append(tool: .pen, spans: [.init(surface: .board(child), samples: [.init(point: .zero,
        worldPoint: .zero, timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])], actor: actor)
      if let nestedCover {
        journal.append(tool: .pen, spans: [.init(surface: .cover(nestedCover), samples: [.init(point: .init(x: 40, y: 40),
          timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])], actor: actor)
      }
      try store.saveSpatialInk(journal)
    }
    let model = NotebookAppModel(store: store, startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board,
      camera: .init(scale: withChild ? 0.3 : 1), viewport: .init(x: 512, y: 512))
    model.updatePresence(presence, settled: true)
    try await flush(model)
    try await waitUntil { !model.scenePreparationPending }
    // This fixture asks to capture these physical ink owners, not an optional
    // overview image of a nested cover that the byte planner may flatten.
    let requestedOwners = Set([child, nestedCover].compactMap { $0 }.map(WorkspaceSpatialID.item))
    let frame = WorkspaceSceneFrame(index: try XCTUnwrap(model.sceneIndex), presence: presence,
      portalCamera: model.scenePortalCamera, pinned: requestedOwners)
    model.prepareComposition(presence: presence, frame: frame, pinned: requestedOwners, displayScale: 1)
    try await waitUntil { model.compositionTiles.published != nil || model.compositionTiles.failure != nil }
    let cohort = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "")
    return .init(model: model, cohort: cohort, presence: presence, child: child, nestedCover: nestedCover)
  }

  @MainActor
  private func capture(_ fixture: Fixture, driver: Driver) throws -> NotebookAttentionSelection {
    try XCTUnwrap(NotebookAttentionProjection.capture(start: .init(x: 100, y: 100), end: .init(x: 180, y: 160),
      model: fixture.model, presence: fixture.presence, cohort: driver.cohort, installedInk: driver.registry.installedSources()))
  }

  @MainActor
  private func flush(_ model: NotebookAppModel) async throws {
    let saved = await model.finishPendingPersistence()
    XCTAssertTrue(saved, model.persistenceFailure ?? "")
  }

  @MainActor
  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate(), "The exact source publication did not complete")
  }

  @MainActor
  private final class Driver {
    let registry: SpatialInkSurfaceRegistry
    let canvas = SpatialInkContainerView(frame: .init(x: 0, y: 0, width: 512, height: 512))
    private let model: NotebookAppModel, presence: SessionPresence, window: UIWindow
    private let coordinator: SpatialInkCanvas.Coordinator
    private(set) var cohort: SceneCompositionCohort
    private var physical: WorkspaceInkFixture
    private let touch = CaptureTouch(), event = UIEvent()
    private var recognizer: SpatialPencilGestureRecognizer { window.gestureRecognizers!.compactMap { $0 as? SpatialPencilGestureRecognizer }.first! }
    var recognizerState: UIGestureRecognizer.State { recognizer.state }
    private(set) var didBeginContact = false

    init(model: NotebookAppModel, presence: SessionPresence, cohort: SceneCompositionCohort) throws {
      self.model = model; self.presence = presence; self.cohort = cohort; registry = cohort.nativeInk.registry
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      coordinator = .init(surfaceRegistry: registry, inputGate: model.inputGate, onCommit: model.appendSpatialInk)
      let host = UIViewController(); window.rootViewController = host
      host.view.addSubview(canvas); window.makeKeyAndVisible()
      physical = try .init(cohort: cohort, presence: presence, canvas: canvas, parent: host,
        registry: registry, gate: model.inputGate, journal: model.spatialInk)
      update(.pen)
    }

    func update(_ tool: DrawingTool) {
      coordinator.update(view: canvas, cohort: cohort, boardID: presence.boardID, camera: presence.camera, viewport: presence.viewport,
        items: physical.surfaces, journal: model.spatialInk, penStyle: .standard, eraserStyle: .standard, drawingTool: tool,
        surfaceRegistry: registry, inputGate: model.inputGate, isItemBeingDeleted: { _ in false },
        admitsNewContact: { true }, isEnabled: true, onCommit: model.appendSpatialInk)
    }

    func publishCurrentComposition() async throws {
      XCTAssertFalse(model.inputGate.hasActivePencil)
      let deadline = ContinuousClock.now + .seconds(5)
      while model.scenePreparationPending, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertFalse(model.scenePreparationPending)
      let cursor = try XCTUnwrap(model.workspaceHeader).cursor
      let previous = cohort
      let installedCanvas = try XCTUnwrap(canvas.inkView)
      let frame = WorkspaceSceneFrame(index: try XCTUnwrap(model.sceneIndex), presence: presence,
        portalCamera: model.scenePortalCamera)
      model.prepareComposition(presence: presence, frame: frame, pinned: [], displayScale: 1)
      while model.compositionTiles.published?.plan.revision != cursor,
        model.compositionTiles.failure == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      let prepared = try XCTUnwrap(model.compositionTiles.published, model.compositionTiles.failure ?? "")
      XCTAssertEqual(prepared.plan.revision, cursor, model.compositionTiles.failure ?? "")
      XCTAssertNotEqual(prepared.id, previous.id)
      physical.close()
      cohort = prepared
      physical = try .init(cohort: prepared, presence: presence, canvas: canvas,
        parent: try XCTUnwrap(window.rootViewController), registry: registry,
        gate: model.inputGate, journal: model.spatialInk)
      update(.pen)
      XCTAssertTrue(canvas.inkView === installedCanvas, "The new canonical source uses the same physical ink owner")
    }

    func begin(_ tool: DrawingTool) {
      update(tool); recognizer.reset(); touch.point = .init(x: 120, y: 120)
      touch.sampleTime += 1; didBeginContact = false
      let downstream = recognizer.onEvent
      recognizer.onEvent = { [weak self] event in
        if case .began = event { self?.didBeginContact = true }
        downstream?(event)
      }
      recognizer.touchesBegan([touch], with: event)
      recognizer.onEvent = downstream
    }
    func attach(_ view: UIView) { window.rootViewController!.view.addSubview(view) }
    func attach<Content: View>(_ host: UIHostingController<Content>) {
      let parent = window.rootViewController!
      parent.addChild(host); parent.view.addSubview(host.view)
      host.view.frame = canvas.frame; host.didMove(toParent: parent); host.view.layoutIfNeeded()
    }
    func detach(_ host: UIHostingController<AnyView>) {
      host.rootView = AnyView(EmptyView())
      host.view.layoutIfNeeded()
      host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
    }
    func moveAndEnd() {
      touch.point.x += 40; touch.sampleTime += 0.1
      recognizer.touchesMoved([touch], with: event); recognizer.touchesEnded([touch], with: event)
    }
    func stroke(_ tool: DrawingTool) throws -> SpatialInkAction {
      let previous = model.spatialInk?.actions.count ?? 0
      begin(tool); moveAndEnd()
      XCTAssertEqual(model.spatialInk?.actions.count, previous + 1)
      return try XCTUnwrap(model.spatialInk?.actions.last)
    }
    func close() { coordinator.uninstall(); physical.close(); window.isHidden = true; window.rootViewController = nil }
  }
}

@MainActor
private final class CaptureTouch: UITouch {
  var point = CGPoint(x: 120, y: 120)
  var sampleTime: TimeInterval = 1
  override var type: UITouch.TouchType { .pencil }
  override var timestamp: TimeInterval { sampleTime }
  override var force: CGFloat { 1 }
  override var maximumPossibleForce: CGFloat { 1 }
  override var altitudeAngle: CGFloat { .pi / 2 }
  override func location(in view: UIView?) -> CGPoint { point }
  override func preciseLocation(in view: UIView?) -> CGPoint { point }
  override func azimuthAngle(in view: UIView?) -> CGFloat { 0 }
}
