import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPanelPresentationTests: XCTestCase {
  override func setUp() async throws { try await InkRasterRenderer.shared.prepareInk() }

  @MainActor
  func testCanonicalBoardMaterialsSplitSubjectsBeforeFirstDragAndJoinCachedRequests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-materials-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let item = try XCTUnwrap(fixture.store.readItemHeaders(limit: 1).first)
    try await fixture.move(item.id, boardID: target.id, to: .init(x: -550, y: 0))
    try await fixture.apply([
      .init(kind: .insertElement, target: target, id: "plain-caption", values: ["kind": .string("nativeText"),
        "source": .string("Existing native material"), "worldOrigin": try .encode(WorldPoint.zero),
        "frame": try .encode(PageRect(x: 0, y: 80, width: 280, height: 80))]),
      .init(kind: .appendInkStroke, target: target, id: UUID().uuidString, values: ["width": .number(8),
        "worldOrigin": try .encode(WorldPoint.zero), "points": .array([
          .object(["x": .number(0), "y": .number(300)]),
          .object(["x": .number(500), "y": .number(350)])])])])
    let physicalPresence = fixture.model.presence
    let projection = NotebookPanelAppearanceProjection(viewport: .init(x: 1000, y: 700), pixelScale: 1,
      camera: .init(center: .zero, scale: 0.5))
    var command = NotebookCommand(command: .panelPresentation)
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target, appearance: projection)
    let accepted = command
    async let first = fixture.send(accepted)
    async let simultaneous = fixture.send(accepted)
    let (reply, joined) = try await (first, simultaneous)
    let appearance = try XCTUnwrap(reply["appearance"])
    XCTAssertEqual(appearance["status"], .string("ready"))
    XCTAssertEqual(joined["appearance"], appearance, "Concurrent readers join one immutable source cut")
    let layers = try XCTUnwrap(appearance["layers"]?.arrayValues)
    XCTAssertTrue(layers.contains { $0["id"] == .string("board-grid") })
    XCTAssertTrue(layers.contains { $0["id"] == .string("covers") })
    let subject = try XCTUnwrap(layers.first { $0["elementID"] == .string("plain-caption") })
    let authored = try XCTUnwrap(fixture.store.readSpatialElement(boardID: target.id, elementID: "plain-caption"))
    let placement = try XCTUnwrap(fixture.store.readElementPlacement(target: target, elementID: authored.id))
    let body = NotebookElementPresentation(authored, placement: placement).frame
    let layerOrigin = try XCTUnwrap(subject["worldOrigin"]).decode(WorldPoint.self)
    let delta = layerOrigin.delta(to: placement.origin)
    let nativeFrame = PageRect(x: delta.x + body.x, y: delta.y + body.y, width: body.width, height: body.height)
    XCTAssertEqual(try XCTUnwrap(subject["frame"]).decode(PageRect.self), nativeFrame)
    XCTAssertEqual(authored.frame.width, 280, "Native fitting preserves the authored layout constraint")
    XCTAssertEqual(reply["elements"]?.arrayValues.first { $0["source"]?["id"] == .string("plain-caption") }?["editable"], .bool(true))
    let card = try XCTUnwrap(reply["cards"]?.arrayValues.first { $0["item"]?["id"]?.stringValue?.lowercased() == item.id.uuidString.lowercased() })
    XCTAssertEqual(card["geometry"]?["width"], .number(834))
    XCTAssertEqual(card["geometry"]?["height"], .number(1194))
    let ink = try bitmap(layers.first { $0["id"] == .string("board-ink") })
    XCTAssertGreaterThan(try XCTUnwrap(ink.colorAt(x: 625, y: 512)).alphaComponent, 0.1,
      "The ordered native stroke must reach real pixels, not just metadata")
    let cover = try bitmap(layers.first { $0["id"] == .string("covers") })
    XCTAssertGreaterThan(try XCTUnwrap(cover.colorAt(x: 225, y: 350)).alphaComponent, 0.9)
    let cached = try await fixture.send(accepted)
    XCTAssertEqual(cached["appearance"], appearance, "Already-ready completion cannot race waiter registration")
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target, appearance: projection,
      knownCursor: cached["cursor"]?.stringValue, knownRequestID: appearance["requestID"]?.stringValue.flatMap(UUID.init(uuidString:)))
    let unchanged = try await fixture.send(command)
    XCTAssertEqual(unchanged["unchanged"], .bool(true))
    XCTAssertNil(unchanged["appearance"], "Idle polling performs no image or graph serialization")
    command.panelPresentation = .init(workspaceID: UUID(), target: target, appearance: projection)
    do { _ = try await fixture.send(command); XCTFail("A panel cannot cross its pinned workspace") }
    catch let error as CollaborationError { XCTAssertEqual(error.code, "basis_workspace_mismatch") }
    XCTAssertEqual(fixture.model.presence, physicalPresence, "An addressed projection never moves the native camera")
  }

  @MainActor
  func testStoppingTheOwnerCompletesQueuedPanelReadBeforeCapacityReturns() async throws {
    let resources = SceneRenderResources.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-stop-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.waitUntil(seconds: 5) { resources.activeBackgroundWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
    var blockers: [WebSurfaceLease] = []
    for _ in 0..<resources.maximumBackgroundWebSurfaces {
      blockers.append(try await resources.acquireWebSurface(priority: .background))
    }
    defer { blockers.forEach { $0.release() } }
    try await fixture.start(showingPage: true)
    let header = try await fixture.read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
    let page = try XCTUnwrap(fixture.model.activePage)
    let target = CollaborationTarget(kind: .page, id: page.id)
    try await fixture.apply([.init(kind: .insertElement, target: target, id: "awaiting-native-web-\(UUID())",
      values: ["kind": .string("web"), "source": .string("Accepted material waits for physical admission"),
        "html": .string("<div style='width:180px;height:120px;background:blue'>Native source</div>"),
        "frame": try .encode(PageRect(x: 20, y: 30, width: 180, height: 120))])])
    var command = NotebookCommand(command: .panelPresentation)
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: .init(x: 600, y: 800), pixelScale: 1))
    let accepted = command
    let replyCompleted = expectation(description: "The accepted IPC request completes before admission returns")
    let ownerStopped = expectation(description: "The owner drains despite unavailable renderer capacity")
    var completions = 0
    let reader = Task { @MainActor in
      do { _ = try await fixture.send(accepted); XCTFail("Cancelled queued presentation returned pixels") }
      catch { }
      completions += 1; replyCompleted.fulfill()
    }
    defer { reader.cancel() }
    try await fixture.waitUntil(seconds: 5) {
      resources.pendingWebRequestCount > 0 && (try? fixture.store.targetRenderRequests().contains { $0.panelProjection != nil }) == true
    }
    XCTAssertEqual(completions, 0)
    let stopping = Task { @MainActor in
      let stopped = await fixture.model.shutdown()
      XCTAssertTrue(stopped); ownerStopped.fulfill()
    }
    await fulfillment(of: [replyCompleted, ownerStopped], timeout: 5)
    XCTAssertEqual(completions, 1)
    XCTAssertEqual(resources.activeBackgroundWebSurfaceCount, blockers.count,
      "Cancellation completes without consuming or releasing someone else's admission")
    blockers.forEach { $0.release() }
    await reader.value; await stopping.value
    let stoppedAgain = await fixture.model.shutdown()
    XCTAssertTrue(stoppedAgain)
    let requests = try fixture.store.targetRenderRequests().filter { $0.panelProjection != nil }
    for request in requests { XCTAssertNotEqual(try fixture.store.loadTargetRenderReceipt(request.id)?.status, "ready") }
  }

  @MainActor
  private func bitmap(_ layer: JSONValue?) throws -> NSBitmapImageRep {
    let base64 = try XCTUnwrap(layer?["pngBase64"]?.stringValue)
    return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(Data(base64Encoded: base64))))
  }
}
