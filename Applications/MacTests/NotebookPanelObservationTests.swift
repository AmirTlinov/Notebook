import AppKit
import Foundation
import NotebookCore
import XCTest
@testable import Notebook

private final class PanelObservationReadGate: @unchecked Sendable {
  private let lock = NSLock()
  private let release = DispatchSemaphore(value: 0)
  private var started = false
  var entered: Bool { lock.lock(); defer { lock.unlock() }; return started }
  func hold() {
    lock.lock(); started = true; lock.unlock()
    _ = release.wait(timeout: .now() + 2)
  }
  func open() { release.signal() }
}

final class NotebookPanelObservationTests: XCTestCase {
  override func setUp() async throws { try await InkRasterRenderer.shared.prepareInk() }

  @MainActor
  private func fixture() async throws -> MacCommandFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-observation-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    return fixture
  }

  @MainActor
  private func prepare(_ fixture: MacCommandFixture) async throws -> (NotebookPanelPresentationCut, NotebookPanelPreparedScene) {
    let page = try XCTUnwrap(try fixture.store.loadIndex().selectedPageID)
    let cut = try await fixture.model.readCommandCut {
      try $0.requestPanelPresentation(.init(target: .init(kind: .page, id: page),
        appearance: .init(viewport: .init(x: 320, y: 460), pixelScale: 1)))
    }
    return (cut, try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model, knownAssets: []))
  }

  private func request(_ snapshot: JSONValue) throws -> NotebookPanelChangesRequest {
    try .init(workspaceID: XCTUnwrap(snapshot["workspaceID"]).decode(UUID.self),
      target: XCTUnwrap(snapshot["target"]).decode(CollaborationTarget.self),
      checkpoint: XCTUnwrap(snapshot["checkpoint"]).decode(NotebookPanelCheckpoint.self))
  }

  @MainActor
  func testInstalledCommandOwnerWakesPanelOnlyAfterHumanEditCommits() async throws {
    let fixture = try await fixture(), pageID = try XCTUnwrap(try fixture.store.loadIndex().selectedPageID)
    let header = try fixture.store.workspaceHeader(), target = CollaborationTarget(kind: .page, id: pageID)
    var presentation = NotebookCommand(command: .panelPresentation)
    presentation.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: .init(x: 320, y: 460), pixelScale: 1))
    let snapshot = try await fixture.send(presentation), waiting = try request(snapshot)
    XCTAssertEqual(waiting.checkpoint.readCursor, snapshot["cursor"]?.stringValue)
    var observe = NotebookCommand(command: .panelChanges); observe.panelChanges = waiting
    let waitingCommand = observe
    let response = Task { @MainActor in try await fixture.send(waitingCommand) }
    try await Task.sleep(for: .milliseconds(40))
    let actionID = UUID()
    var edit = NotebookCommand(command: .panelEdit)
    edit.panelEdit = .init(workspaceID: header.workspaceID, actionID: actionID, target: target, summary: "Write caption",
      operations: [.init(kind: .insertElement, target: target, id: "caption", values: ["kind": .string("nativeText"),
        "source": .string("Committed human text"), "frame": try .encode(PageRect(x: 20, y: 30, width: 180, height: 50))])],
      sources: [.init(id: "caption")])
    let commit = try await fixture.send(edit), changed = try await response.value
    XCTAssertNotNil(commit["actionID"])
    XCTAssertEqual(changed["changed"], .bool(true))
    XCTAssertEqual(try XCTUnwrap(changed["target"]).decode(CollaborationTarget.self), target)
    XCTAssertNil(changed["appearance"], "A change notification prepares no pixels")
    let next = try await fixture.send(presentation)
    XCTAssertEqual(next["history"]?["undoActionID"], try .encode(actionID))
    XCTAssertEqual(next["elements"]?.arrayValues.first?["source"]?["source"], .string("Committed human text"))
    XCTAssertNotEqual(next["checkpoint"]?["id"], snapshot["checkpoint"]?["id"])
  }

  @MainActor
  func testUnrelatedCommitUsesShortMetadataAndReturnsUnchangedWithoutPainting() async throws {
    let fixture = try await fixture(), (cut, prepared) = try await prepare(fixture)
    let observation = NotebookPanelObservation(model: fixture.model, waitDuration: .milliseconds(250))
    let snapshot = try observation.publish(prepared, requestID: cut.id), waiting = try request(snapshot)
    let response = Task { @MainActor in try await observation.changes(waiting) }
    try await fixture.waitUntil { observation.waitingCount == 1 }
    let board = CollaborationTarget(kind: .board, id: try fixture.store.workspaceHeader().rootBoardID)
    try await fixture.apply([.init(kind: .insertElement, target: board, id: "elsewhere",
      values: ["kind": .string("nativeText"), "source": .string("Different surface"),
        "worldOrigin": try .encode(WorldPoint.zero), "frame": try .encode(PageRect(x: 20, y: 30, width: 180, height: 50))])])
    let pixels = prepared.pixels, actor = fixture.model.actorID
    let (metadata, pixelsCurrent) = try await fixture.model.readCommandCut { reader in
      (try reader.readPanelMetadata(workspaceID: waiting.workspaceID, target: waiting.target, actor: actor),
        try pixels?.isCurrent(reader) != false)
    }
    XCTAssertGreaterThan(metadata.readCursor, prepared.metadata.readCursor)
    XCTAssertGreaterThan(metadata.changeCursor, prepared.metadata.changeCursor)
    XCTAssertNotEqual(metadata.navigation, prepared.metadata.navigation, "Raw navigation carries the newer WAL read clocks")
    XCTAssertEqual(metadata.sourceRevision, prepared.metadata.sourceRevision)
    XCTAssertEqual(metadata.basis, prepared.metadata.basis)
    XCTAssertEqual(metadata.history, prepared.metadata.history, "A different surface has its own Undo owner")
    XCTAssertTrue(metadata.hasSameScene(as: prepared.metadata))
    XCTAssertTrue(pixelsCurrent)
    XCTAssertTrue(SceneRenderResources.shared.leafRastersAreCurrent(prepared.leafRasterCollector.witnesses))
    observation.contentDidCommit()
    let result = try await response.value
    XCTAssertEqual(result["changed"], .bool(false))
    XCTAssertEqual(result["checkpoint"], snapshot["checkpoint"])
    XCTAssertNil(result["appearance"])
    await observation.stop()
  }

  @MainActor
  func testDeadlineDuringAnUnchangedReadDoesNotInventAnInvalidation() async throws {
    let fixture = try await fixture(), (cut, prepared) = try await prepare(fixture)
    let observation = NotebookPanelObservation(model: fixture.model, waitDuration: .milliseconds(25))
    let snapshot = try observation.publish(prepared, requestID: cut.id), waiting = try request(snapshot)
    let gate = PanelObservationReadGate()
    defer { gate.open() }
    let held = Task { @MainActor in
      try await fixture.model.readCommandCut { reader in gate.hold(); return try reader.storedWorkspaceID() }
    }
    try await fixture.waitUntil { gate.entered }
    let response = Task { @MainActor in try await observation.changes(waiting) }
    try await fixture.waitUntil { observation.waitingCount == 1 }
    try await Task.sleep(for: .milliseconds(40))
    gate.open()
    let result = try await response.value
    XCTAssertEqual(result["changed"], .bool(false), "An idle deadline is not a content event")
    XCTAssertEqual(result["checkpoint"], snapshot["checkpoint"])
    XCTAssertNil(result["appearance"])
    let heldWorkspaceID = try await held.value
    XCTAssertEqual(heldWorkspaceID, waiting.workspaceID)
    await observation.stop()
  }

  @MainActor
  func testCommitBeforeWaitRegistrationIsFoundByItsFirstFreshCut() async throws {
    let fixture = try await fixture(), (cut, prepared) = try await prepare(fixture)
    let observation = NotebookPanelObservation(model: fixture.model)
    let snapshot = try observation.publish(prepared, requestID: cut.id), waiting = try request(snapshot)
    try await fixture.apply([.init(kind: .insertElement, target: waiting.target, id: "before-wait",
      values: ["kind": .string("nativeText"), "source": .string("Already committed"),
        "frame": try .encode(PageRect(x: 20, y: 30, width: 180, height: 50))])])
    let result = try await observation.changes(waiting)
    XCTAssertEqual(result["changed"], .bool(true))
    await observation.stop()
  }

  @MainActor
  func testDeadlineEndsWithInvalidationWhenAnEventArrivesDuringItsRead() async throws {
    let fixture = try await fixture(), (cut, prepared) = try await prepare(fixture)
    let observation = NotebookPanelObservation(model: fixture.model, waitDuration: .milliseconds(25))
    let waiting = try request(observation.publish(prepared, requestID: cut.id))
    let gate = PanelObservationReadGate()
    defer { gate.open() }
    // The actual read owner holds a WAL cut. Writes and owner notifications
    // keep progressing while the observation's first read waits behind it.
    let held = Task { @MainActor in
      try await fixture.model.readCommandCut { reader in gate.hold(); return try reader.storedWorkspaceID() }
    }
    try await fixture.waitUntil { gate.entered }
    let response = Task { @MainActor in try await observation.changes(waiting) }
    try await fixture.waitUntil { observation.waitingCount == 1 }
    let boardID = try fixture.store.workspaceHeader().rootBoardID
    try await fixture.model.performStoreCommand(publishesChanges: true) { store in
      try store.savePresence(.init(boardID: boardID, mode: .board, camera: .init(center: .init(x: 17, y: 29), scale: 1),
        viewport: .init(x: 320, y: 460)))
    }
    observation.contentDidCommit()
    try await Task.sleep(for: .milliseconds(40))
    gate.open()
    let result = try await response.value
    XCTAssertEqual(result["changed"], .bool(true), "A deadline with an unvalidated event ends conservatively instead of starting another read loop")
    XCTAssertNil(result["appearance"])
    let heldWorkspaceID = try await held.value
    XCTAssertEqual(heldWorkspaceID, waiting.workspaceID)
    await observation.stop()
  }

  @MainActor
  func testDeletingTheObservedPageInvalidatesSceneWithoutReportingTransportFailure() async throws {
    let fixture = try await fixture()
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    // Deletion retains a working item and explicitly admits every lifecycle owner.
    try await fixture.apply([.init(kind: .createNotebook, target: board, id: UUID().uuidString,
      values: ["center": try .encode(WorldPoint.zero), "pageID": try .encode(UUID())])])
    let (cut, prepared) = try await prepare(fixture)
    let observation = NotebookPanelObservation(model: fixture.model)
    let waiting = try request(observation.publish(prepared, requestID: cut.id))
    let itemID = try XCTUnwrap(try fixture.store.ownerItemID(ofPage: waiting.target.id))
    let lifecycle = try await fixture.read(.init(kind: .itemLifecycle, id: itemID)).decode(NotebookItemLifecycle.self)
    let cover = try await fixture.expectation(lifecycle.target)
    let workspace = try await fixture.expectation(.init(kind: .workspace, id: header.rootBoardID))
    let parent = try await fixture.expectation(.init(kind: .board, id: XCTUnwrap(lifecycle.target.boardID)))
    let receipt = try await fixture.apply([.init(kind: .deleteItem, target: lifecycle.target)], expected: [workspace, parent,
      .init(target: cover.target, revision: cover.revision, lifecycleRevision: lifecycle.revision)])
    XCTAssertTrue(receipt.lifecycleChanges?.contains { $0.kind == .deleteItem && $0.target == lifecycle.target } == true)
    XCTAssertNil(try fixture.store.ownerItemID(ofPage: waiting.target.id), "The observation sees an actual committed page retirement")
    let result = try await observation.changes(waiting)
    XCTAssertEqual(result["changed"], .bool(true))
    XCTAssertNil(result["appearance"])
    XCTAssertNil(result["status"])
    await observation.stop()
  }

  @MainActor
  func testWarmPageRegionsDoNotInheritOtherRegionsProgramWitnesses() async throws {
    let fixture = try await fixture(), pageID = try XCTUnwrap(try fixture.store.loadIndex().selectedPageID)
    let target = CollaborationTarget(kind: .page, id: pageID), programID = "program-\(UUID())", shapeID = "shape-\(UUID())"
    let mask = NotebookGraphicMask().appending(.intersect,
      polygon: [.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
    try await fixture.apply([
      .init(kind: .insertElement, target: target, id: programID, values: ["kind": .string("web"),
        "source": .string("Program in the upper region"), "html": .string("<div style='width:100%;height:100%;background:blue'></div>"),
        "frame": try .encode(PageRect(x: 20, y: 20, width: 100, height: 100))]),
      .init(kind: .insertElement, target: target, id: shapeID, values: ["kind": .string("graphic"), "source": .string(""),
        "graphic": try .encode(NotebookGraphic(shape: .rectangle, mask: mask)),
        "frame": try .encode(PageRect(x: 20, y: 1070, width: 100, height: 100))])])
    let program = agentElementSnapshotSource(try XCTUnwrap(try fixture.store.readPageElement(pageID: pageID, elementID: programID)))
    let resources = SceneRenderResources.shared
    func image(_ color: NSColor) -> NSImage {
      let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
      return NSImage(cgImage: context.makeImage()!, size: .init(width: 100, height: 100))
    }
    XCTAssertTrue(resources.store(image(.blue), for: .agent(program)))
    let cut = try await fixture.model.readCommandCut {
      try $0.requestPanelPresentation(.init(target: target,
        appearance: .init(viewport: .init(x: 834, y: 1194), pixelScale: 1,
          camera: .init(center: .init(x: 417, y: 597), scale: 1))))
    }
    let first = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model, knownAssets: [])
    defer { first.leafRasterCollector.close() }
    let role = "page-elements:" + [programID, shapeID].sorted().joined(separator: ",")
    let layers = try XCTUnwrap(first.snapshot["appearance"]?["layers"]?.arrayValues)
    let region = try XCTUnwrap(layers.first { layer in
      guard layer["id"]?.stringValue?.hasPrefix(role + ":") == true,
        let frame = try? layer["frame"]?.decode(PageRect.self) else { return false }
      return frame.x <= 70 && frame.x + frame.width >= 70
        && frame.y <= 1120 && frame.y + frame.height >= 1120 && frame.y >= 120
    })
    let frame = try XCTUnwrap(region["frame"]).decode(PageRect.self)
    let level = try XCTUnwrap(first.snapshot["appearance"]?["coverage"]?["level"]).decode(Int.self)
    let tile = try XCTUnwrap(CompositionTile(containing: .init(x: frame.x, y: frame.y), level: level))
    let requestedDensity = cut.projection.camera.scale * cut.projection.pixelScale
    let density = max(requestedDensity,
      Double(SceneCompositionTileKey.requiredPixelSize(for: tile, density: requestedDensity)) / tile.worldSize)
    XCTAssertEqual(region["pixelWidth"], .number(ceil(frame.width * density)))
    XCTAssertEqual(region["pixelHeight"], .number(ceil(frame.height * density)))
    let key = try SceneMaterialKey(workspaceID: cut.projection.workspaceID, target: target,
      revision: cut.sourceRevision, role: role, frame: frame, density: density)
    let body = try XCTUnwrap(resources.retainMaterial(key))
    XCTAssertEqual(body.entryID, try XCTUnwrap(region["assetID"]).decode(UUID.self))
    let ownWitnesses = body.leafRasters
    XCTAssertTrue(ownWitnesses.isEmpty, "Only the masked native graphic is painted in this lower region")
    body.release()
    let warm = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model,
      knownAssets: Set(layers.compactMap { $0["assetID"]?.stringValue.flatMap(UUID.init(uuidString:)) }))
    defer { warm.leafRasterCollector.close() }
    let reused = try XCTUnwrap(warm.snapshot["appearance"]?["layers"]?.arrayValues.first { $0["id"] == region["id"] })
    XCTAssertEqual(reused["assetID"], region["assetID"])
    let regionCollector = SceneLeafRasterWitnessCollector(resources: resources)
    defer { regionCollector.close() }
    regionCollector.record(ownWitnesses)
    XCTAssertTrue(resources.store(image(.red), for: .agent(program)))
    XCTAssertTrue(regionCollector.isCurrent, "A new frame in the upper region cannot invalidate the delivered lower region")
  }

  @MainActor
  func testExpiredWitnessAndRuntimeEpochReturnReset() async throws {
    let fixture = try await fixture(), (cut, prepared) = try await prepare(fixture)
    let observation = NotebookPanelObservation(model: fixture.model)
    let original = try observation.publish(prepared, requestID: cut.id), waiting = try request(original)
    for _ in 0..<16 { _ = try observation.publish(prepared, requestID: cut.id) }
    let expired = try await observation.changes(waiting)
    XCTAssertEqual(expired["reset"], .bool(true))
    let checkpoint = NotebookPanelCheckpoint(id: waiting.checkpoint.id, epoch: UUID(),
      readCursor: waiting.checkpoint.readCursor, changeCursor: waiting.checkpoint.changeCursor)
    let restarted = NotebookPanelChangesRequest(workspaceID: waiting.workspaceID, target: waiting.target, checkpoint: checkpoint)
    let reset = try await observation.changes(restarted)
    XCTAssertEqual(reset["reset"], .bool(true))
    await observation.stop()
  }

  @MainActor
  func testCancellationAndStopDrainObserversWithoutStoppingTheWorkspaceReader() async throws {
    let fixture = try await fixture(), (cut, prepared) = try await prepare(fixture)
    let observation = NotebookPanelObservation(model: fixture.model)
    let waiting = try request(observation.publish(prepared, requestID: cut.id))
    let cancelled = Task { @MainActor in try await observation.changes(waiting) }
    try await fixture.waitUntil { observation.waitingCount == 1 }
    cancelled.cancel()
    do { _ = try await cancelled.value; XCTFail("A cancelled observer must complete") }
    catch is CancellationError {}
    XCTAssertEqual(observation.waitingCount, 0)
    let stopped = Task { @MainActor in try await observation.changes(waiting) }
    try await fixture.waitUntil { observation.waitingCount == 1 }
    await observation.stop()
    do { _ = try await stopped.value; XCTFail("Stopping drains each observer") }
    catch is CancellationError {}
    XCTAssertEqual(observation.waitingCount, 0)
    let metadata = try await fixture.model.readCommandCut {
      try $0.readPanelMetadata(workspaceID: waiting.workspaceID, target: waiting.target, actor: UUID())
    }
    XCTAssertEqual(metadata.workspaceID, waiting.workspaceID)
  }
}
