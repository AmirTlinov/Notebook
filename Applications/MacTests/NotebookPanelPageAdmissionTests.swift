import AppKit
import NotebookCore
import XCTest
@testable import Notebook

final class NotebookPanelPageAdmissionTests: XCTestCase {
  @MainActor
  func testHeadlessPanelRetainsWarmSourceWithoutAdmittingANativePage() async throws {
    let (fixture, header, _) = try await fixture(), itemID = UUID(), pageID = UUID()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID), target = CollaborationTarget(kind: .page, id: pageID)
    try await fixture.apply([.init(kind: .createNotebook, target: board, id: itemID.uuidString,
      values: ["center": try .encode(WorldPoint(x: 50_000, y: 50_000)), "pageID": try .encode(pageID)])])
    try await fixture.apply([try graphic("panel-only", frame: .init(x: 400, y: 580, width: 24, height: 24), color: .black, target: target)])
    XCTAssertNil(fixture.model.pages[pageID]); XCTAssertNil(fixture.model.notebookPagePreparation.nativeSources[pageID])
    let presence = fixture.model.presence
    var command = NotebookCommand(command: .panelPresentation)
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: .init(x: 200, y: 150), pixelScale: 1,
        camera: .init(center: .init(x: 417, y: 597), scale: 4)))
    var phases: [UUID: [String: TimeInterval]] = [:]
    XCTAssertNil(NotebookNavigationObservation.onPageMaterialPreparation)
    NotebookNavigationObservation.onPageMaterialPreparation = { stage, request, page, _, _, time in
      guard page == pageID else { return }; phases[request, default: [:]][stage] = time
    }
    defer { NotebookNavigationObservation.onPageMaterialPreparation = nil }
    let cold = try await fixture.send(command), coldLayers = try XCTUnwrap(cold["appearance"]?["layers"]?.arrayValues)
    let coldBody = try XCTUnwrap(coldLayers.first { $0["elementID"] == .string("panel-only") })
    command.panelPresentation = .init(workspaceID: header.workspaceID, target: target,
      appearance: .init(viewport: .init(x: 200, y: 150), pixelScale: 1,
        camera: .init(center: .init(x: 422, y: 597), scale: 4)),
      knownAssets: coldLayers.compactMap { $0["assetID"]?.stringValue.flatMap(UUID.init(uuidString:)) })
    let warm = try await fixture.send(command), warmLayers = try XCTUnwrap(warm["appearance"]?["layers"]?.arrayValues)
    let warmBody = try XCTUnwrap(warmLayers.first { $0["elementID"] == .string("panel-only") })
    XCTAssertEqual(warm["elements"], cold["elements"]); XCTAssertEqual(warmBody["assetID"], coldBody["assetID"])
    XCTAssertNil(warmBody["pngBase64"]); XCTAssertEqual(warm["appearance"]?["status"], .string("ready"))
    XCTAssertNil(fixture.model.pages[pageID]); XCTAssertNil(fixture.model.notebookPagePreparation.nativeSources[pageID])
    XCTAssertEqual(fixture.model.presence, presence, "Panel source retention never admits a native mount, program or durable selection")
    let held = SceneRenderResources.shared.reservedBytes
    fixture.model.notebookPagePreparation.releaseOptionalPanelSource()
    XCTAssertLessThan(SceneRenderResources.shared.reservedBytes, held, "The actual headless publisher retained one reclaimable source credit")
    for response in [cold, warm] {
      let request = try XCTUnwrap(response["appearance"]?["requestID"]).decode(UUID.self), sample = try XCTUnwrap(phases[request])
      let started = try XCTUnwrap(sample["panel_prepare_started"]), captured = try XCTUnwrap(sample["panel_content_captured"])
      print("PANEL_SOURCE_ROUTE request=\(request) capture_ms=\((captured-started)*1000) retained_native=false")
    }
  }

  @MainActor
  func testPanelSourceWindowSharesExactNativeAliasAndDrainsCancelledOrReplacedBorrow() async throws {
    let (fixture, header, target) = try await fixture()
    let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: .init(x: 417, y: 597), scale: 4), viewport: .init(x: 200, y: 150), pixelScale: 1)
    let cut = try await cut(fixture, target: target, projection: projection)
    let prepared = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model, knownAssets: [])
    defer { prepared.leafRasterCollector.close() }
    let source = try XCTUnwrap(prepared.pageSource), bytes = try XCTUnwrap(source.admissionEstimateBytes), owner = UUID()
    let resources = SceneRenderResources(byteLimit: bytes * 2, profile: .headless)
    let window = NotebookPagePreparationWindow(resources: resources)
    defer { _ = window.stop() }
    var demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    window.finishPanelSource(demand, source: source)
    XCTAssertEqual(resources.reservedBytes, bytes)
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    let borrowed = try XCTUnwrap(window.panelSource(for: demand))
    XCTAssertEqual(borrowed.captureIdentity, source.captureIdentity)
    window.withdrawPanelSource(owner: owner)
    XCTAssertNil(window.panelSource(for: demand)); XCTAssertEqual(resources.reservedBytes, bytes, "An active borrow still owns its credit")
    window.finishPanelSource(demand, source: borrowed)
    XCTAssertEqual(resources.reservedBytes, 0, "Late completion cannot restore a withdrawn slot")

    window.acceptNativeSources([target.id: source])
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    XCTAssertEqual(window.panelSource(for: demand)?.captureIdentity, source.captureIdentity)
    XCTAssertEqual(resources.reservedBytes, 0, "An exact native capability alias receives no second credit")
    window.retainNativeSources([])
    XCTAssertEqual(resources.reservedBytes, 0)
    window.finishPanelSource(demand, source: source)
    XCTAssertEqual(resources.reservedBytes, bytes, "A retired native alias may become the one optional panel-only source")
    window.acceptNativeSources([target.id: source])
    XCTAssertEqual(resources.reservedBytes, 0)
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    let replacement = try await fixture.model.readCommandCut { try $0.capturePanelPageContent(cut) }.source
    XCTAssertNotEqual(replacement.captureIdentity, source.captureIdentity)
    window.acceptNativeSources([target.id: replacement])
    window.finishPanelSource(demand, source: source)
    XCTAssertEqual(window.nativeSources[target.id]?.captureIdentity, replacement.captureIdentity,
      "A late panel cut cannot overwrite a replacement native capability which merely shares its page UUID")
    XCTAssertEqual(resources.reservedBytes, 0)

    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    XCTAssertEqual(window.panelSource(for: demand)?.captureIdentity, replacement.captureIdentity)
    window.finishPanelSource(demand, source: replacement)
    window.retainNativeSources([])
    XCTAssertEqual(resources.reservedBytes, 0, "Unknown optional estimate declines retention without affecting native/required admission")
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    XCTAssertNil(window.panelSource(for: demand)); window.finishPanelSource(demand, source: source)
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    let pending = try XCTUnwrap(window.panelSource(for: demand))
    _ = window.stop()
    XCTAssertEqual(resources.reservedBytes, bytes, "Shutdown withdraws retention but drains the accepted borrow before credit release")
    window.finishPanelSource(demand, source: pending)
    XCTAssertEqual(resources.reservedBytes, 0); XCTAssertNil(window.beginPanelSource(owner: owner, target: target))
  }

  @MainActor
  func testPanelSourceWindowReclaimsIdleCreditAndRefusesOptionalRetentionWithoutLosingReadyPixels() async throws {
    let (fixture, header, target) = try await fixture()
    let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: .init(x: 417, y: 597), scale: 4), viewport: .init(x: 200, y: 150), pixelScale: 1)
    let cut = try await cut(fixture, target: target, projection: projection)
    let prepared = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model, knownAssets: [])
    defer { prepared.leafRasterCollector.close() }
    let source = try XCTUnwrap(prepared.pageSource), bytes = try XCTUnwrap(source.admissionEstimateBytes), owner = UUID()
    let resources = SceneRenderResources(byteLimit: bytes * 2, profile: .headless), window = NotebookPagePreparationWindow(resources: resources)
    defer { _ = window.stop() }
    var demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    window.finishPanelSource(demand, source: source)
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    let borrowed = try XCTUnwrap(window.panelSource(for: demand))
    XCTAssertNil(resources.reserveDerivedBytes(bytes * 2, priority: .passive), "Required borrow cannot be offered as idle backing")
    XCTAssertEqual(resources.reservedBytes, bytes)
    window.finishPanelSource(demand, source: borrowed)
    let occupying = try XCTUnwrap(resources.reserveDerivedBytes(bytes * 2, priority: .passive))
    XCTAssertEqual(resources.reservedBytes, bytes * 2)
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    XCTAssertNil(window.panelSource(for: demand), "The existing resource planner retired its idle source offer")
    window.finishPanelSource(demand, source: source)
    XCTAssertEqual(resources.reservedBytes, bytes * 2, "Failed optional credit never queues behind required work")
    XCTAssertEqual(prepared.snapshot["appearance"]?["status"], .string("ready"))
    XCTAssertFalse(prepared.snapshot["appearance"]?["layers"]?.arrayValues.isEmpty ?? true)
    occupying.release()
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: target))
    XCTAssertNil(window.panelSource(for: demand)); window.finishPanelSource(demand, source: source)
    let otherTarget = CollaborationTarget(kind: .page, id: UUID())
    demand = try XCTUnwrap(window.beginPanelSource(owner: owner, target: otherTarget))
    XCTAssertNil(window.panelSource(for: demand)); XCTAssertEqual(resources.reservedBytes, 0, "Target replacement frees the prior panel-only source")
    window.finishPanelSource(demand, source: nil)
  }

  @MainActor
  func testPageSkipsDistantBodiesAndPrioritizesVisibleSeventeenthOverPrefetch() async throws {
    for prefetched in [false, true] {
      let (fixture, header, target) = try await fixture()
      let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
        camera: .init(center: .init(x: 417, y: 597), scale: 4), viewport: .init(x: 200, y: 150), pixelScale: 1)
      let geometry = try geometry(projection)
      let farFrame = PageRect(x: prefetched ? geometry.window.minX + 4 : geometry.window.maxX + 30,
        y: geometry.viewport.midY - 6, width: 12, height: 12)
      let far = CGRect(x: farFrame.x, y: farFrame.y, width: farFrame.width, height: farFrame.height)
      XCTAssertEqual(!far.intersection(geometry.window).isEmpty, prefetched)
      XCTAssertTrue(far.intersection(geometry.viewport).isEmpty)
      let visibleFrame = PageRect(x: geometry.viewport.midX - 12, y: geometry.viewport.midY - 12, width: 24, height: 24)
      let farIDs = (0..<16).map { "far-\($0)" }, visibleID = "visible-17", topID = "passive-top"
      var operations = try farIDs.map { try graphic($0, frame: farFrame, color: .black, target: target) }
      operations.append(try graphic(visibleID, frame: visibleFrame, color: .init(red: 1, green: 0, blue: 0), target: target))
      operations.append(try graphic(topID, frame: visibleFrame, color: .init(red: 0, green: 0, blue: 1), target: target, passive: true))
      try await fixture.apply(operations)
      let cut = try await cut(fixture, target: target, projection: projection)
      let content = try await fixture.model.readCommandCut { try $0.capturePanelPageContent(cut) }
      let prepared = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model, knownAssets: [])
      defer { prepared.leafRasterCollector.close() }
      let snapshot = prepared.snapshot, layers = try XCTUnwrap(snapshot["appearance"]?["layers"]?.arrayValues)
      let subjects = Set(layers.compactMap { $0["elementID"]?.stringValue })
      let expected = prefetched ? Set(farIDs.prefix(15)).union([visibleID]) : [visibleID]
      XCTAssertEqual(subjects, expected, "The quota is applied after geometry and gives the current viewport its first grant")
      let projected = try content.projection(in: .init(anchor: geometry.coverage.tiles[0].origin,
        region: .init(x: 0, y: 0, width: geometry.window.width, height: geometry.window.height))).elements
      let sourceIDs = try XCTUnwrap(snapshot["elements"]?.arrayValues).compactMap { $0["source"]?["id"]?.stringValue }
      XCTAssertEqual(sourceIDs, (prefetched ? farIDs : []) + [visibleID, topID],
        "Disclosure preserves passive-band hit sources and whole prefetched neighbors, while excluding distant sources")
      XCTAssertEqual(snapshot["elements"]?.arrayValues.map { $0["source"] }, projected.map { $0["source"] })
      XCTAssertTrue(subjects.isSubset(of: Set(sourceIDs)), "Every prepared body retains its JSON hit/source")
      XCTAssertEqual(snapshot["elements"]?.arrayValues.first { $0["source"]?["id"] == .string(visibleID) }?["editable"], .bool(true))
      let body = try XCTUnwrap(layers.first { $0["elementID"] == .string(visibleID) })
      XCTAssertEqual(try XCTUnwrap(body["subjectFrame"]).decode(PageRect.self), visibleFrame)
      let pixel = try sourceOver(layers, at: .init(x: visibleFrame.x + 12, y: visibleFrame.y + 12))
      XCTAssertGreaterThan(pixel.blue, 0.95); XCTAssertLessThan(pixel.red, 0.05)
      XCTAssertGreaterThan(pixel.alpha, 0.95, "The later passive painter band remains above the separated red body")
      let density = max(projection.camera.scale * projection.pixelScale,
        Double(SceneCompositionTileKey.requiredPixelSize(for: geometry.coverage.tiles[0],
          density: projection.camera.scale * projection.pixelScale)) / geometry.coverage.tiles[0].worldSize)
      for id in Set(farIDs).subtracting(subjects) {
        let key = try SceneMaterialKey(workspaceID: header.workspaceID, target: target, revision: cut.sourceRevision,
          role: "element:" + id, frame: farFrame, density: density)
        let unused = SceneRenderResources.shared.retainMaterial(key)
        XCTAssertNil(unused, "An excluded body never begins independent raster/PNG preparation")
        unused?.release()
      }
      let bounds = try XCTUnwrap(snapshot["appearance"]?["coverage"])
      XCTAssertEqual(try XCTUnwrap(bounds["anchor"]).decode(WorldPoint.self), geometry.coverage.tiles[0].origin)
      XCTAssertEqual(try XCTUnwrap(bounds["region"]).decode(PageRect.self),
        .init(x: 0, y: 0, width: geometry.window.width, height: geometry.window.height))
      let warm = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model,
        knownAssets: Set(layers.compactMap { $0["assetID"]?.stringValue.flatMap(UUID.init(uuidString:)) }),
        reusing: prepared.pageSource)
      defer { warm.leafRasterCollector.close() }
      XCTAssertEqual(warm.pageSource?.document.elementSourceIdentity, prepared.pageSource?.document.elementSourceIdentity)
      XCTAssertEqual(warm.pageSource?.document.inkSource.identity, prepared.pageSource?.document.inkSource.identity)
      let reused = try XCTUnwrap(warm.snapshot["appearance"]?["layers"]?.arrayValues.first { $0["elementID"] == .string(visibleID) })
      XCTAssertEqual(reused["assetID"], body["assetID"]); XCTAssertNil(reused["pngBase64"])
    }
  }

  @MainActor
  func testPageWindowDisclosesOverflowTextAndNewlyExposedBodies() async throws {
    let (fixture, header, target) = try await fixture()
    let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: .init(x: 417, y: 597), scale: 4), viewport: .init(x: 200, y: 150), pixelScale: 1)
    let geometry = try geometry(projection)
    let textFrame = PageRect(x: geometry.viewport.midX - 30, y: geometry.window.minY - 20, width: 100, height: 10)
    let text = Array(repeating: "Body", count: 8).joined(separator: "\n")
    XCTAssertGreaterThan(textFrame.y, 0)
    XCTAssertTrue(geometry.window.intersection(.init(x: textFrame.x, y: textFrame.y,
      width: textFrame.width, height: textFrame.height)).isEmpty)
    let nextFrame = PageRect(x: 690, y: 900, width: 24, height: 24)
    try await fixture.apply([
      .init(kind: .insertElement, target: target, id: "overflow", values: ["kind": .string("nativeText"),
        "source": .string(text), "frame": try .encode(textFrame)]),
      try graphic("newly-exposed", frame: nextFrame, color: .black, target: target)])
    let cut = try await cut(fixture, target: target, projection: projection)
    let content = try await fixture.model.readCommandCut { try $0.capturePanelPageContent(cut) }
    let presentation = try XCTUnwrap(content.page.graphicGraph().elementPresentation("overflow"))
    XCTAssertFalse(geometry.viewport.intersection(presentation.bounds).isEmpty)
    let prepared = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model, knownAssets: [])
    defer { prepared.leafRasterCollector.close() }
    let snapshot = prepared.snapshot, entries = try XCTUnwrap(snapshot["elements"]?.arrayValues)
    XCTAssertEqual(entries.compactMap { $0["source"]?["id"]?.stringValue }, ["overflow"])
    XCTAssertEqual(entries.first?["source"], try .encode(XCTUnwrap(content.page.element(id: "overflow"))))
    let body = try XCTUnwrap(snapshot["appearance"]?["layers"]?.arrayValues.first { $0["elementID"] == .string("overflow") })
    XCTAssertEqual(try XCTUnwrap(body["subjectFrame"]).decode(PageRect.self), presentation.frame,
      "The real prepared TextKit body retains its full hit frame and authored source across the window boundary")
    XCTAssertGreaterThan(try XCTUnwrap(body["pixelHeight"]).decode(Int.self), 0)
    XCTAssertNotNil(body["pngBase64"]?.stringValue)
    XCTAssertEqual(snapshot["worldOrigin"], try .encode(WorldPoint.zero))
    XCTAssertEqual(try XCTUnwrap(snapshot["size"]).decode(PageSize.self), content.page.size)
    let nextProjection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: .init(x: 702, y: 912), scale: 4), viewport: projection.viewport, pixelScale: 1)
    let nextCut = try await self.cut(fixture, target: target, projection: nextProjection)
    XCTAssertEqual(nextCut.sourceRevision, cut.sourceRevision)
    let next = try await CurrentViewPreviewWriter.panelMaterial(nextCut, model: fixture.model, knownAssets: [], reusing: prepared.pageSource)
    defer { next.leafRasterCollector.close() }
    XCTAssertEqual(next.pageSource?.document.elementSourceIdentity, prepared.pageSource?.document.elementSourceIdentity,
      "A new camera window borrows the same full source, without preserving the old disclosure")
    XCTAssertEqual(next.snapshot["elements"]?.arrayValues.compactMap { $0["source"]?["id"]?.stringValue }, ["newly-exposed"])
    XCTAssertEqual(next.snapshot["elements"]?.arrayValues.first?["source"]?["frame"], try .encode(nextFrame))
    XCTAssertEqual(Set(next.snapshot["appearance"]?["layers"]?.arrayValues.compactMap { $0["elementID"]?.stringValue } ?? []), ["newly-exposed"])
  }

  @MainActor
  func testPrefetchBoundaryKeepsWholeBodiesAndExistingSemanticExclusions() {
    let physical = CGRect(x: 0, y: 0, width: 500, height: 500)
    let window = CGRect(x: 100, y: 100, width: 300, height: 300), viewport = CGRect(x: 150, y: 150, width: 100, height: 100)
    let visible = CGRect(x: 160, y: 160, width: 20, height: 20), crossing = CGRect(x: 90, y: 190, width: 20, height: 20)
    let ids = ["crossing", "tangent", "outside", "visible", "basis", "partial", "contact"]
    var entries = ids.map(nativeEntry)
    entries[4] = entries[4].setting("source", entries[4]["source"]!.setting("basis", .object([:])))
    entries[5] = entries[5].setting("appearance", .object(["state": .string("partial")]))
    let frames = Dictionary(uniqueKeysWithValues: ids.map { id in
      (id, id == "crossing" ? crossing : id == "tangent" ? CGRect(x: 400, y: 190, width: 20, height: 20)
        : id == "outside" ? CGRect(x: 410, y: 190, width: 20, height: 20) : visible)
    })
    let admitted = CurrentViewPreviewWriter.pagePanelSubjects(entries, frames: frames, physical: physical,
      materialWindow: window, viewport: viewport, density: 1, inkOwnedIDs: ["contact"])
    XCTAssertEqual(Set(admitted.keys), ["visible", "crossing"])
    XCTAssertEqual(admitted["crossing"], .init(x: 90, y: 190, width: 20, height: 20), "The preview retains the full partially exposed body")
    let clipped = CurrentViewPreviewWriter.pagePanelSubjects(entries, frames: frames, physical: physical,
      materialWindow: viewport, viewport: viewport, density: 1, inkOwnedIDs: ["contact"])
    XCTAssertEqual(Set(clipped.keys), ["visible"], "Clipping revokes subjects which leave the admitted regions")
    XCTAssertEqual(CurrentViewPreviewWriter.pagePanelOptionalSubject(admitted,
      ranks: ["crossing": 0, "visible": 17], viewport: viewport), "crossing",
      "Budget demotion cannot remove the later visible body while a prefetched body remains")
  }

  @MainActor
  func testClippedPageBudgetPreservesVisibleSubjectPainterBandsAndRequestedDensity() async throws {
    let (fixture, header, target) = try await fixture()
    let projection = NotebookPanelRenderProjection(workspaceID: header.workspaceID,
      camera: .init(center: .init(x: 417, y: 597), scale: 2), viewport: .init(x: 2048, y: 1400), pixelScale: 2)
    let geometry = try geometry(projection), fullPage = PageRect(x: 0, y: 0, width: 834, height: 1194)
    let farFrame = PageRect(x: 220, y: 1000, width: 20, height: 20), visibleFrame = PageRect(x: 400, y: 580, width: 24, height: 24)
    let far = CGRect(x: farFrame.x, y: farFrame.y, width: farFrame.width, height: farFrame.height)
    XCTAssertFalse(far.intersection(geometry.window).isEmpty); XCTAssertTrue(far.intersection(geometry.viewport).isEmpty)
    var operations: [CollaborationOperation] = []
    for index in 0..<16 {
      operations.append(try graphic("passive-\(index)", frame: fullPage, color: .black, target: target, passive: true))
      operations.append(try graphic("prefetched-\(index)", frame: farFrame, color: .black, target: target))
    }
    operations.append(try graphic("visible-17", frame: visibleFrame, color: .init(red: 1, green: 0, blue: 0), target: target))
    operations.append(try graphic("passive-top", frame: fullPage, color: .init(red: 0, green: 0, blue: 1), target: target, passive: true))
    try await fixture.apply(operations)
    let cut = try await cut(fixture, target: target, projection: projection)
    let content = try await fixture.model.readCommandCut { try $0.capturePanelPageContent(cut) }
    let density = max(projection.camera.scale * projection.pixelScale,
      Double(SceneCompositionTileKey.requiredPixelSize(for: geometry.coverage.tiles[0],
        density: projection.camera.scale * projection.pixelScale)) / geometry.coverage.tiles[0].worldSize)
    let graph = content.page.graphicGraph()
    let frames = Dictionary(uniqueKeysWithValues: content.page.elements.compactMap { element -> (String, CGRect)? in
      graph.resolve(element.id).layout.map { (element.id, CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height)) }
    })
    let projected = try content.projection(in: .init(anchor: geometry.coverage.tiles[0].origin,
      region: .init(x: 0, y: 0, width: geometry.window.width, height: geometry.window.height))).elements
    let initialSubjects = CurrentViewPreviewWriter.pagePanelSubjects(projected, frames: frames,
      physical: .init(x: 0, y: 0, width: 834, height: 1194), materialWindow: geometry.window,
      viewport: geometry.viewport, density: density)
    XCTAssertEqual(initialSubjects.count, 16); XCTAssertNotNil(initialSubjects["visible-17"])
    let ranks = Dictionary(uniqueKeysWithValues: content.page.elements.enumerated().map { ($0.element.id, $0.offset) })
    XCTAssertNotEqual(CurrentViewPreviewWriter.pagePanelOptionalSubject(initialSubjects, ranks: ranks, viewport: geometry.viewport), "visible-17",
      "The real budget fixture protects its visible body while optional overscan remains")
    let prepared = try await CurrentViewPreviewWriter.panelMaterial(cut, model: fixture.model, knownAssets: [])
    defer { prepared.leafRasterCollector.close() }
    let snapshot = prepared.snapshot, appearance = try XCTUnwrap(snapshot["appearance"])
    let bounds = try XCTUnwrap(appearance["coverage"]), layers = try XCTUnwrap(appearance["layers"]?.arrayValues)
    XCTAssertEqual(try XCTUnwrap(bounds["anchor"]).decode(WorldPoint.self), projection.worldOrigin)
    XCTAssertEqual(try XCTUnwrap(bounds["region"]).decode(PageRect.self),
      .init(x: 0, y: 0, width: geometry.viewport.width, height: geometry.viewport.height), "The actual budget narrows the initial overscan once")
    XCTAssertEqual(Set(layers.compactMap { $0["elementID"]?.stringValue }), ["visible-17"])
    let finalSources = try XCTUnwrap(snapshot["elements"]?.arrayValues)
    XCTAssertEqual(finalSources.compactMap { $0["source"]?["id"]?.stringValue },
      (0..<16).map { "passive-\($0)" } + ["visible-17", "passive-top"],
      "The final projection follows the clipped window, retaining whole painter-band sources without excluded prefetch hits")
    let clipped = try content.projection(in: .init(anchor: projection.worldOrigin,
      region: .init(x: 0, y: 0, width: geometry.viewport.width, height: geometry.viewport.height))).elements
    XCTAssertEqual(finalSources.map { $0["source"] }, clipped.map { $0["source"] })
    XCTAssertEqual(finalSources.last?["source"]?["frame"], try .encode(fullPage), "Whole sources are never clipped to their raster region")
    var pixels = 0
    for layer in layers {
      let frame = try XCTUnwrap(layer["frame"]).decode(PageRect.self)
      let width = try XCTUnwrap(layer["pixelWidth"]).decode(Int.self), height = try XCTUnwrap(layer["pixelHeight"]).decode(Int.self)
      pixels += width * height
      XCTAssertGreaterThanOrEqual(min(Double(width) / frame.width, Double(height) / frame.height) + 0.000001,
        projection.camera.scale * projection.pixelScale)
    }
    XCTAssertLessThanOrEqual(pixels, NotebookPanelRenderProjection.maximumDecodedPixels); XCTAssertLessThanOrEqual(layers.count, 96)
    let pixel = try sourceOver(layers, at: .init(x: 412, y: 592))
    XCTAssertGreaterThan(pixel.blue, 0.95); XCTAssertLessThan(pixel.red, 0.05)
    for index in 0..<16 {
      let key = try SceneMaterialKey(workspaceID: header.workspaceID, target: target, revision: cut.sourceRevision,
        role: "element:prefetched-\(index)", frame: farFrame, density: density)
      let unused = SceneRenderResources.shared.retainMaterial(key)
      XCTAssertNil(unused, "Budget-clipped prefetch cannot begin pixel preparation"); unused?.release()
    }
  }

  @MainActor
  func testHundredThousandPagePaintCandidatesKeepResolvedCrossingsAndGlobalClaims() throws {
    let actor = UUID(), count = 100_000, region = PageRect(x: 480, y: 480, width: 40, height: 40)
    let bounds = CGRect(x: region.x, y: region.y, width: region.width, height: region.height), claimedID = UUID()
    func shape(_ id: String, frame: PageRect, graphic: NotebookGraphic = .init(shape: .rectangle), parent: String? = nil) -> AgentElement {
      .init(id: id, kind: .graphic, frame: frame, source: "", html: "", graphic: graphic, parentID: parent)
    }
    let group = AgentElement(id: "group", kind: .group, frame: .init(x: 100, y: 100, width: 100, height: 100),
      source: "", html: "", basis: .init(size: .init(x: 100, y: 100),
        transform: .init(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)))
    let erasedFrame = PageRect(x: 490, y: 490, width: 20, height: 20)
    let textFrame = PageRect(x: 480, y: 430, width: 100, height: 10)
    let collisionID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    var elements = (0..<count).map { shape("distant-\($0)",
      frame: .init(x: 600 + Double($0 % 100), y: 890 + Double($0 % 100), width: 5, height: 5)) }
    elements += [group, shape("escaped", frame: .init(x: 380, y: -310, width: 30, height: 30), parent: group.id),
      shape("left", frame: .init(x: 80, y: 490, width: 20, height: 20)),
      shape("right", frame: .init(x: 850, y: 490, width: 20, height: 20)),
      shape("edge", frame: .init(x: 800, y: 800, width: 50, height: 50), graphic: .init(shape: .connector,
        connection: .init(start: .init(point: .zero, binding: .init(elementID: "left")),
          end: .init(point: .zero, binding: .init(elementID: "right"))))),
      .init(id: "overflow", kind: .nativeText, frame: textFrame, source: Array(repeating: "Body", count: 8).joined(separator: "\n"), html: ""),
      .init(id: "erased", kind: .nativeText, frame: erasedFrame, source: "Erased source", html: ""),
      shape("losing-claim", frame: erasedFrame, graphic: .init(shape: .rectangle, sourceInkIDs: [claimedID])),
      shape("winning-offscreen-claim", frame: .init(x: 900, y: 900, width: 20, height: 20),
        graphic: .init(shape: .rectangle, sourceInkIDs: [claimedID])),
      .init(id: collisionID, kind: .nativeText, frame: erasedFrame, source: "First exact owner", html: ""),
      .init(id: collisionID.lowercased(), kind: .nativeText, frame: erasedFrame, source: "Second exact owner", html: "")]
    let drawing = PageInkDrawing(actions: [
      .init(id: claimedID, tool: .pen, samples: [.init(point: .init(x: 500, y: 500), timeOffset: 0,
        width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)]),
      .init(tool: .eraser, samples: [.init(point: .init(x: 500, y: 500), timeOffset: 0,
        width: 200, opacity: 1, force: 1, azimuth: 0, altitude: 1)], sequence: 1,
        elementTargets: [.init(elementID: "erased", frame: erasedFrame, wholeElement: true)])])
    // The production sparse causal format admits this full source without
    // manufacturing one field frontier per workload object in the fixture.
    let base = PageDocument(size: .init(width: 1000, height: 1000), actor: actor, drawingData: try drawing.dataRepresentation())
    let page = try JSONValue.encode(base).setting("elements", .encode(elements)).setting("collaboration", .null).decode(PageDocument.self)
    let graphStarted = ContinuousClock.now, graph = page.graphicGraph()
    graph.prepareVisibility(on: .page(page.id))
    let graphElapsed = graphStarted.duration(to: .now), queryStarted = ContinuousClock.now
    let selected = PageCompositionRenderer.elements(in: page, region: region, elementID: nil)
    let queryElapsed = queryStarted.duration(to: .now)
    let expected = page.elements.filter { element in
      let presentation = element.graphic == nil ? graph.placement(element.id).map { NotebookElementPresentation(element, placement: $0) } : nil
      guard let frame = graph.resolve(element.id).layout?.frame ?? presentation?.frame else { return false }
      return element.kind != .group && (element.graphic == nil || page.graphicPresentation.geometryIDs.contains(element.id))
        && (element.graphic == nil || graph.resolve(element.id).layout != nil)
        && bounds.intersects(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
    }
    XCTAssertEqual(selected, expected, "Visibility narrows preparation while the existing exact painter predicate and source order remain authoritative")
    XCTAssertEqual(selected.map(\.id), ["escaped", "edge", "overflow", "erased", collisionID, collisionID.lowercased()])
    XCTAssertTrue(page.graphicPresentation.suppressedInkIDs.contains(claimedID), "Off-window claim arbitration still suppresses the raw contact")
    XCTAssertFalse(selected.contains { $0.id == "losing-claim" })
    XCTAssertEqual(PageCompositionRenderer.elements(in: page, region: region, elementID: collisionID.lowercased()).map(\.id),
      [collisionID.lowercased()], "Exact selected-element export keeps the second owner of a canonical UUID collision")
    XCTAssertTrue(try XCTUnwrap(page.inkDrawing().elementErasures["erased"]).contains { $0.target.wholeElement })
    let nextRegion = PageRect(x: 850, y: 490, width: 20, height: 20)
    XCTAssertTrue(PageCompositionRenderer.elements(in: page, region: nextRegion, elementID: nil).contains { $0.id == "right" })
    XCTAssertEqual(page.elements.count, count + 11)
    print("PANEL_PAGE_PAINT_SCALE source_elements=\(page.elements.count) selected=\(selected.count) graph=\(graphElapsed) warm_query=\(queryElapsed)")
  }

  @MainActor
  func testHundredThousandDistantPageSubjectsUseTheSameBoundedAdmission() {
    let count = 100_000, far = CGRect(x: 400, y: 400, width: 10, height: 10), visible = CGRect(x: 180, y: 180, width: 10, height: 10)
    let physical = CGRect(x: 0, y: 0, width: 500, height: 500), window = CGRect(x: 100, y: 100, width: 200, height: 200)
    var entries: [JSONValue] = [], frames: [String: CGRect] = [:]
    entries.reserveCapacity(count + 1); frames.reserveCapacity(count + 1)
    for index in 0..<count { let id = "far-\(index)"; entries.append(nativeEntry(id)); frames[id] = far }
    entries.append(nativeEntry("visible")); frames["visible"] = visible
    let started = ContinuousClock.now
    let admitted = CurrentViewPreviewWriter.pagePanelSubjects(entries, frames: frames, physical: physical,
      materialWindow: window, viewport: .init(x: 150, y: 150, width: 100, height: 100), density: 1)
    let elapsed = started.duration(to: .now)
    XCTAssertEqual(Set(admitted.keys), ["visible"]); XCTAssertEqual(entries.count, count + 1)
    XCTAssertEqual(admitted["visible"], .init(x: 180, y: 180, width: 10, height: 10))
    print("PANEL_PAGE_ADMISSION distant=\(count) subjects=\(admitted.count) geometry=\(elapsed)")
  }

  private func nativeEntry(_ id: String) -> JSONValue {
    .object(["source": .object(["id": .string(id), "kind": .string("nativeText")])])
  }

  private func geometry(_ projection: NotebookPanelRenderProjection) throws -> (coverage: CompositionTileCoverage, window: CGRect, viewport: CGRect) {
    let requested = WorkspaceSpatialBounds(origin: projection.worldOrigin,
      width: projection.viewport.x / projection.camera.scale, height: projection.viewport.y / projection.camera.scale)
    let coverage = try CompositionTileCoverage(bounds: requested,
      pixelsPerWorldPoint: projection.camera.scale * projection.pixelScale, maximumTiles: 8)
    let bounds = WorkspaceSpatialBounds(origin: coverage.tiles[0].origin, maximum: coverage.tiles.last!.bounds.maximum)
    let start = WorldPoint.zero.delta(to: bounds.origin), visible = WorldPoint.zero.delta(to: requested.origin)
    return (coverage, .init(x: start.x, y: start.y, width: bounds.width, height: bounds.height),
      .init(x: visible.x, y: visible.y, width: requested.width, height: requested.height))
  }

  private func graphic(_ id: String, frame: PageRect, color: SpatialInkColor, target: CollaborationTarget, passive: Bool = false) throws -> CollaborationOperation {
    let mask = passive ? NotebookGraphicMask().appending(.intersect,
      polygon: [.zero, .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]) : nil
    return .init(kind: .insertElement, target: target, id: id, values: ["kind": .string("graphic"), "source": .string(""),
      "graphic": try .encode(NotebookGraphic(shape: .rectangle, style: .init(stroke: color, strokeWidth: 1, fill: color), mask: mask)),
      "frame": try .encode(frame)])
  }

  @MainActor
  private func cut(_ fixture: MacCommandFixture, target: CollaborationTarget, projection: NotebookPanelRenderProjection) async throws -> NotebookPanelPresentationCut {
    try await fixture.model.readCommandCut { try $0.requestPanelPresentation(.init(workspaceID: projection.workspaceID, target: target,
      appearance: .init(viewport: projection.viewport, pixelScale: projection.pixelScale, camera: projection.camera))) }
  }

  @MainActor
  private func fixture() async throws -> (MacCommandFixture, NotebookWorkspaceHeader, CollaborationTarget) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-page-admission-\(UUID())")
    let fixture = MacCommandFixture(root: root)
    retainNotebookUntilTeardown(fixture.model, removing: root)
    try await fixture.start()
    let header = try fixture.store.workspaceHeader(), pageID = try XCTUnwrap(try fixture.store.loadIndex().selectedPageID)
    return (fixture, header, .init(kind: .page, id: pageID))
  }

  @MainActor
  private func sourceOver(_ layers: [JSONValue], at point: CGPoint) throws -> (red: CGFloat, blue: CGFloat, alpha: CGFloat) {
    func rank(_ layer: JSONValue) -> Double { if case .number(let value) = layer["order"] { return value }; return 0 }
    var result = (red: CGFloat(0), blue: CGFloat(0), alpha: CGFloat(0))
    for layer in layers.sorted(by: { rank($0) < rank($1) }) {
      let origin = try XCTUnwrap(layer["worldOrigin"]).decode(WorldPoint.self), frame = try XCTUnwrap(layer["frame"]).decode(PageRect.self)
      let local = origin.delta(to: .init(x: point.x, y: point.y))
      guard local.x >= frame.x, local.y >= frame.y, local.x < frame.x + frame.width, local.y < frame.y + frame.height else { continue }
      let image = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(Data(base64Encoded: XCTUnwrap(layer["pngBase64"]?.stringValue)))))
      let color = try XCTUnwrap(image.colorAt(x: Int((local.x - frame.x) * Double(image.pixelsWide) / frame.width),
        y: Int((local.y - frame.y) * Double(image.pixelsHigh) / frame.height))?.usingColorSpace(.deviceRGB))
      let alpha = color.alphaComponent
      result = (color.redComponent * alpha + result.red * (1 - alpha), color.blueComponent * alpha + result.blue * (1 - alpha),
        alpha + result.alpha * (1 - alpha))
    }
    return result
  }
}
