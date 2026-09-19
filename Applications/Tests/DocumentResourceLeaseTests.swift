import NotebookCore
import Observation
import UIKit
import SwiftUI
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentResourceLeaseTests: XCTestCase {
  func testOffscreenPaperDoesNotRefineUntilItsNativeProjectionIsVisible() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let fixture = fixture(resources: resources, interactive: true)
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    let geometry = WorkspaceItemGeometry.document(fixture.document.paperSize)
    fixture.host.frame = CGRect(x: -20_000, y: 0, width: geometry.width, height: geometry.height)
    fixture.host.layoutIfNeeded()
    await waitUntil(timeout: .seconds(8)) { fixture.coordinator.hasCanonicalPixels }
    func paper(in view: UIView) -> DocumentPaperView? {
      if let paper = view as? DocumentPaperView { return paper }
      return view.subviews.lazy.compactMap { paper(in: $0) }.first
    }
    let view = try XCTUnwrap(paper(in: fixture.host))
    let prepared = try XCTUnwrap(view.raster)
    XCTAssertFalse(SceneSourceVisibility.isVisible(view))
    XCTAssertEqual(prepared.image.width, 1024, "Hidden paper keeps its bounded preparation, not a display-size copy")
    let before = resources.reservedBytes
    view.refine()
    XCTAssertEqual(resources.reservedBytes, before, "Offscreen refinement cannot consume snapshot admission")
    let web = try XCTUnwrap(fixture.coordinator.webView)
    for width in [256, 1024] {
      fixture.coordinator.update(document: fixture.document, state: fixture.state, selectedPageIndex: 0,
        capturesSnapshot: false, onRenderReady: .init { _ in }, onPageLayout: { _ in },
        onStateChange: { _, _ in nil }, paperPreparationPixelWidth: width)
      await waitUntil(timeout: .seconds(3)) {
        fixture.coordinator.hasCanonicalPixels && view.raster?.image.width == width
      }
      XCTAssertTrue(fixture.coordinator.webView === web,
        "Thumbnail-to-paper promotion must honor resolution without replacing its browser")
    }
    fixture.host.frame.origin = .zero
    fixture.host.layoutIfNeeded()
    XCTAssertTrue(SceneSourceVisibility.isVisible(view))
    view.refine()
    await waitUntil(timeout: .seconds(3)) { (view.raster?.image.width ?? 0) > prepared.image.width }
    XCTAssertEqual(view.raster?.sourceKey, prepared.sourceKey)
    XCTAssertEqual(view.raster?.page.pageIndex, prepared.page.pageIndex)
    XCTAssertTrue(fixture.coordinator.hasCanonicalPixels, "Visible refinement preserves the installed page")
  }

  func testReusingRetiredPaperCannotDetachTheReplacementInItsPreviousHost() async throws {
    try await assertRetiredPaperLeavesReplacementMounted(reuse: true)
  }

  func testInvalidatingRetiredPaperCannotDetachTheReplacementInItsPreviousHost() async throws {
    try await assertRetiredPaperLeavesReplacementMounted(reuse: false)
  }

  private func assertRetiredPaperLeavesReplacementMounted(reuse: Bool) async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let outgoing = fixture(resources: resources, interactive: true)
    let incoming = fixture(resources: resources, interactive: true)
    let window = try show(outgoing.host)
    let container = try XCTUnwrap(window.rootViewController?.view)
    incoming.host.frame = outgoing.host.frame; container.addSubview(incoming.host)
    defer { outgoing.coordinator.invalidate(); incoming.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(6)) {
      outgoing.coordinator.hasCanonicalPixels && incoming.coordinator.hasCanonicalPixels
    }
    let oldWeb = try XCTUnwrap(outgoing.coordinator.webView)
    let newWeb = try XCTUnwrap(incoming.coordinator.webView)
    let size = newWeb.bounds.size
    // A live page landing replaces the physical host before the departed
    // coordinator is either reused for preparation or reclaimed by its pool.
    incoming.coordinator.mount(in: outgoing.host, physicalSize: size, isInteractive: true, priority: .currentPage)
    XCTAssertTrue(outgoing.host.ownsSurface(newWeb))
    XCTAssertFalse(oldWeb.isDescendant(of: outgoing.host))
    if reuse {
      let preparation = DocumentWebHost(); preparation.frame = incoming.host.frame
      container.addSubview(preparation)
      outgoing.coordinator.mount(in: preparation, physicalSize: size, isInteractive: false, priority: .neighbor)
      XCTAssertTrue(preparation.ownsSurface(oldWeb))
    } else { outgoing.coordinator.invalidate() }
    XCTAssertTrue(outgoing.host.ownsSurface(newWeb), "A retiring coordinator can remove only its own physical WebKit")
    XCTAssertTrue(newWeb.window === window, "The incoming live paper must remain in the native window")
    XCTAssertTrue(incoming.coordinator.hasCanonicalPixels)
    let rendered = try await newWeb.evaluateJavaScript("document.querySelector('#document').textContent.includes('A real document page')")
    XCTAssertEqual(rendered as? Bool, true)
  }

  func testLoadedPhysicalPaperCannotClaimNativeSourceScrolling() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      String(repeating: "A physical page belongs to the native curl.\n\n", count: 100))])
    let fixture = fixture(resources: resources, interactive: true, document: document)
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(6)) { fixture.coordinator.hasCanonicalPixels }
    XCTAssertTrue(fixture.coordinator.hasCanonicalPixels)
    let web = try XCTUnwrap(fixture.coordinator.webView)
    XCTAssertFalse(web.scrollView.isScrollEnabled, "The loaded browser must not take the native page's pan")
    let oldEditor = try await web.evaluateJavaScript("document.querySelector('textarea') === null") as? Bool
    XCTAssertEqual(oldEditor, true, "The native source editor is outside the paper's gesture owner")
    XCTAssertFalse(web.scrollView.isScrollEnabled)
  }

  func testProducerServesExactPageDemandWithoutExpandingTheSceneWindowAgain() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      (0..<40).map { "Paragraph \($0). " + String(repeating: "An exact page demand has one owner. ", count: 12) }.joined(separator: "\n\n"))])
    let fixture = fixture(resources: resources, interactive: true, document: document)
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(6)) { fixture.coordinator.hasCanonicalPixels || fixture.coordinator.acquisitionError != nil }
    let source = try XCTUnwrap(fixture.coordinator.payload?.source)
    XCTAssertTrue(fixture.coordinator.hasCanonicalPixels)
    XCTAssertGreaterThan(try XCTUnwrap(source.layout).pageCount, 3)
    XCTAssertEqual(source.retainedPageIndices, [0])
    XCTAssertEqual(source.compiledPageCount, 1, "Only the page controller may add neighbours")
    let first = UUID(), second = UUID()
    source.retainPage(2, hostID: first); source.retainPage(2, hostID: second)
    defer { source.releasePage(hostID: first, in: nil); source.releasePage(hostID: second, in: nil) }
    let firstPage = try await source.preparedPage(2, hostID: first, resources: resources)
    let secondPage = try await source.preparedPage(2, hostID: second, resources: resources)
    XCTAssertTrue(firstPage === secondPage)
    XCTAssertEqual(source.retainedPageIndices, [0, 2])
    XCTAssertEqual(source.compiledPageCount, 2, "Two consumers share one compiled fragment")
    source.releasePage(hostID: first, in: nil)
    XCTAssertEqual(source.retainedPageIndices, [0, 2])
    source.releasePage(hostID: second, in: nil)
    XCTAssertEqual(source.retainedPageIndices, [0], "The last consumer releases only its own demand")
    XCTAssertEqual(source.measurementCount, 1)
  }

  func testRequiredSourcePreparationRecoversOnTheSameWebKitWhenActualBytesAreReleased() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - 2_048, priority: .passive))
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      (0..<20).map { "Paragraph \($0). " + String(repeating: "Retained content survives admission pressure. ", count: 8) }.joined(separator: "\n\n"))])
    let fixture = fixture(resources: resources, interactive: true, document: document)
    let window = try show(fixture.host)
    defer { blocker.release(); fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(6)) { resources.lastRasterRefusal != nil }
    let source = try XCTUnwrap(fixture.coordinator.payload?.source)
    let web = try XCTUnwrap(fixture.coordinator.webView)
    let runtime = fixture.coordinator.payload?.runtimeID
    let refusal = try XCTUnwrap(resources.lastRasterRefusal).generation
    XCTAssertFalse(fixture.coordinator.renderIsReady)
    XCTAssertNil(fixture.coordinator.acquisitionError,
      "Temporary source admission is loading, not a poisoned source or a destroyed runtime")
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(resources.lastRasterRefusal?.generation, refusal)
    blocker.release()
    await waitUntil(timeout: .seconds(6)) { fixture.coordinator.renderIsReady || fixture.coordinator.acquisitionError != nil }
    XCTAssertTrue(fixture.coordinator.renderIsReady)
    XCTAssertNil(fixture.coordinator.acquisitionError)
    XCTAssertTrue(fixture.coordinator.webView === web)
    XCTAssertTrue(fixture.coordinator.payload?.source === source)
    XCTAssertEqual(fixture.coordinator.payload?.runtimeID, runtime)
    XCTAssertEqual(source.preparationCount, 1)
    XCTAssertEqual(source.measurementCount, 1)
    let receipt = try await web.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(receipt?["pageIndex"] as? Int, 0)
    XCTAssertEqual(receipt?["layoutCanonical"] as? Bool, true)
  }

  func testRetiringTheMeasurementHostPreservesAnAlreadyWaitingSecondReader() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "# Surviving reader\n\n" + String(repeating: "One source can serve another physical reader. ", count: 160))])
    let sourceBytes = try canonicalDocumentJSON(DocumentSourceSnapshot(document).message).utf8.count
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - sourceBytes * 2 - 4_096,
      priority: .passive))
    let first = fixture(resources: resources, interactive: true, document: document)
    let window = try show(first.host)
    defer { blocker.release(); first.coordinator.invalidate(); window.isHidden = true }
    let source = try XCTUnwrap(first.coordinator.payload?.source)
    await waitUntil(timeout: .seconds(6)) {
      resources.pendingDerivedRequestCount == 1 && source.pendingPreparationReaderCount == 1
    }
    // The first physical WebKit is definitely the retired measurement owner;
    // the second reader is introduced only after that owner's real refusal.
    let second = fixture(resources: resources, interactive: true, document: document)
    defer { second.coordinator.invalidate() }
    let container = try XCTUnwrap(window.rootViewController?.view)
    container.addSubview(second.host); second.host.frame = container.bounds
    XCTAssertTrue(second.coordinator.payload?.source === source)
    await waitUntil(timeout: .seconds(6)) {
      resources.pendingDerivedRequestCount == 1 && source.pendingPreparationReaderCount == 2
    }
    let survivingWeb = try XCTUnwrap(second.coordinator.webView)
    let survivingRuntime = second.coordinator.payload?.runtimeID
    first.coordinator.invalidate()
    await waitUntil(timeout: .seconds(6)) {
      source.pendingPreparationReaderCount == 1 && resources.pendingDerivedRequestCount == 1
        && resources.activeWebSurfaceCount == 1
    }
    XCTAssertNil(first.coordinator.webView)
    XCTAssertNil(second.coordinator.acquisitionError)
    blocker.release()
    await waitUntil(timeout: .seconds(6)) { second.coordinator.renderIsReady || second.coordinator.acquisitionError != nil }
    XCTAssertTrue(second.coordinator.renderIsReady)
    XCTAssertNil(second.coordinator.acquisitionError)
    XCTAssertTrue(second.coordinator.webView === survivingWeb)
    XCTAssertEqual(second.coordinator.payload?.runtimeID, survivingRuntime)
    XCTAssertTrue(second.coordinator.payload?.source === source)
    XCTAssertEqual(source.pendingPreparationReaderCount, 0)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
  }

  func testClosingADocumentDuringByteAdmissionCancelsItsActualPendingPreparation() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - 1, priority: .passive))
    let fixture = fixture(resources: resources, interactive: true)
    let window = try show(fixture.host)
    defer { blocker.release(); fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(6)) { resources.pendingDerivedRequestCount == 1 }
    fixture.coordinator.invalidate()
    await waitUntil { resources.pendingDerivedRequestCount == 0 && resources.activeWebSurfaceCount == 0 }
    let refusal = resources.lastRasterRefusal?.generation
    blocker.release()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertNil(fixture.coordinator.webView)
    XCTAssertNil(fixture.coordinator.payload)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.lastRasterRefusal?.generation, refusal)
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  func testDocumentAdmitsActualPacketsBesideSixtyMiBOfRetainedSceneWithoutBorrowingPencilReserve() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let sceneBytes = 60 * 1024 * 1024
    let scene = try XCTUnwrap(resources.reserveDerivedBytes(sceneBytes, priority: .passive))
    defer { scene.release() }
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      (0..<50).map { "Абзац \($0). " + String(repeating: "Содержание остаётся на своём физическом листе. ", count: 12) }.joined(separator: "\n\n"))])
    var pageCount = 0
    let fixture = fixture(resources: resources, interactive: true, document: document, layout: { pageCount = $0.pageCount })
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8), message: {
      "ready=\(fixture.coordinator.renderIsReady) error=\(String(describing: fixture.coordinator.acquisitionError)) peak=\(resources.peakAccountedBytes)"
    }) { fixture.coordinator.renderIsReady || fixture.coordinator.acquisitionError != nil }
    XCTAssertNil(fixture.coordinator.acquisitionError)
    XCTAssertTrue(fixture.coordinator.renderIsReady)
    XCTAssertGreaterThan(pageCount, 1)
    XCTAssertEqual(fixture.coordinator.payload?.source.preparationCount, 1)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertLessThan(resources.peakAccountedBytes, sceneBytes + 48 * 1024 * 1024,
      "Bounded PDF decode, paper pixels and hit regions stay within the passive scene allowance")
    XCTAssertEqual(scene.byteCount, sceneBytes)
    XCTAssertFalse(scene.isReleased, "Preparation cannot evict the shown scene")
  }

  func testASeventhDocumentWaitsWithoutCreatingWebKitAndCancellationReleasesItsRequest() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    var held: [WebSurfaceLease] = []
    for _ in 0..<6 { held.append(try await resources.acquireWebSurface(priority: .currentPage)) }
    defer { held.forEach { $0.release() } }
    let fixture = fixture(resources: resources, interactive: true)
    await waitUntil { resources.pendingWebRequestCount == 1 }
    XCTAssertNil(fixture.coordinator.webView)
    XCTAssertFalse(fixture.coordinator.renderIsReady)
    XCTAssertEqual(resources.activeWebSurfaceCount, 6)
    fixture.coordinator.invalidate()
    fixture.coordinator.invalidate()
    await waitUntil { resources.pendingWebRequestCount == 0 }
    held.removeLast().release()
    await Task.yield()
    XCTAssertEqual(resources.activeWebSurfaceCount, 5)
    XCTAssertNil(fixture.coordinator.webView, "An abandoned queue entry cannot create a late document surface")
  }

  func testCurrentPageReceivesTheReleasedSlotBeforeQueuedNeighbour() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let blocker = try await resources.acquireWebSurface(priority: .background)
    let neighbor = fixture(resources: resources, interactive: false)
    await waitUntil { resources.pendingWebRequestCount == 1 }
    let current = fixture(resources: resources, interactive: true)
    await waitUntil { resources.pendingWebRequestCount == 2 }
    blocker.release()
    await waitUntil { current.coordinator.webView != nil }
    XCTAssertNil(neighbor.coordinator.webView)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    current.coordinator.invalidate()
    await waitUntil { neighbor.coordinator.webView != nil }
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    neighbor.coordinator.invalidate()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testReadyDocumentKeepsItsLeasedWebKitWhenItBecomesTheNeighbourInTheCurl() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let fixture = fixture(resources: resources, interactive: true)
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8)) { fixture.coordinator.renderIsReady }
    let original = try XCTUnwrap(fixture.coordinator.webView)
    let paper = WorkspaceItemGeometry.document(fixture.document.paperSize)
    fixture.coordinator.mount(in: fixture.host, physicalSize: .init(width: paper.width, height: paper.height),
      isInteractive: false, priority: .neighbor)
    XCTAssertTrue(fixture.coordinator.webView === original)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertFalse(fixture.coordinator.acceptsInput)
    XCTAssertTrue(fixture.coordinator.renderIsReady)
  }

  func testLateMessagesCannotPublishOrWriteAfterDismantleAndOldProgramTokenIsRejected() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    var states: [JSONValue] = [], readies: [Bool] = []
    let document = DocumentDocument(actor: UUID(), blocks: [
      .interactive(id: "control", html: "<p>State owner</p>", height: 100)
    ])
    let fixture = fixture(resources: resources, interactive: true, document: document,
      ready: { readies.append($0) }, state: { _, value in states.append(value); return nil })
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8)) { fixture.coordinator.renderIsReady }
    let web = try XCTUnwrap(fixture.coordinator.webView)
    let payload = try XCTUnwrap(fixture.coordinator.payload)
    let token = try XCTUnwrap(payload.blockTokens["control"])
    func state(_ token: String, _ step: Int) -> [String: Any] {
      ["kind": "state", "documentID": document.id.uuidString, "runtimeID": payload.runtimeID.uuidString,
        "blockID": "control", "blockToken": token, "value": ["step": step]]
    }
    fixture.coordinator.receive(body: state("old-token", 1), from: web)
    XCTAssertTrue(states.isEmpty)
    fixture.coordinator.receive(body: state(token, 2), from: web)
    XCTAssertEqual(states, [.object(["step": .number(2)])], "The active program's real state route is connected")
    fixture.coordinator.invalidate()
    let readyCount = readies.count
    fixture.coordinator.receive(body: state(token, 3), from: web)
    fixture.coordinator.receive(body: ["kind": "rendered", "documentID": document.id.uuidString,
      "renderToken": payload.renderToken, "pageCount": 999], from: web)
    fixture.coordinator.webView(web, didFinish: nil)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertEqual(states, [.object(["step": .number(2)])])
    XCTAssertEqual(readies.count, readyCount)
    XCTAssertFalse(fixture.coordinator.renderIsReady)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertNil(fixture.coordinator.webView)
  }

  func testChangingDocumentOwnerWithEqualVersionStampsReplacesItsPayload() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let fixture = fixture(resources: resources, interactive: true)
    defer { fixture.coordinator.invalidate() }
    let other = DocumentDocument(actor: fixture.document.contentStamp.actor,
      blocks: [.markdown(id: "body", source: "A different physical owner")])
    let state = DocumentStateJournal(id: other.id, actor: fixture.state.stamp.actor)
    fixture.coordinator.update(document: other, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    XCTAssertEqual(fixture.coordinator.payload?.documentID, other.id)
    XCTAssertEqual(fixture.coordinator.payload?.blocks.first?.source, "A different physical owner")
  }

  func testRepeatedActualPageCurlLandingsDoNotExhaustTheDocumentPool() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    let paragraphs = (0..<160).map { "Paragraph \($0). " + String(repeating: "The physical page keeps its own content. ", count: 12) }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: paragraphs)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = IPadPageTurnController()
    window.rootViewController = controller
    var committed = 0
    func configure() {
      controller.update(ownerID: document.id, sequenceRevision: "fixture-order", pageCount: 8, selectedIndex: committed,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, current, readiness in
          AnyView(DocumentWebView(document: document, state: state, isInteractive: current,
            selectedPageIndex: index, capturesSnapshot: false, onRenderReady: readiness,
            onPageLayout: { _ in }, onLinkActivation: { _ in nil },  onStateChange: { _, _ in nil }, resources: resources, isCurrent: current))
        }, onCommit: { index, _ in committed = index }, onTransitioningChange: { _ in })
    }
    configure(); window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    // Keep old shells alive as UIKit is allowed to do; releasing their content
    // must not depend on the framework immediately deallocating a controller.
    var retainedShells: [Int: UIViewController] = [:]
    for expected in Array(1...7) + Array((0...6).reversed()) {
      let previous = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
      retainedShells[controller.displayedIndex] = previous
      let forward = expected > controller.displayedIndex
      var destination: UIViewController?
      await waitUntil(timeout: .seconds(10), message: {
        "Landing \(expected) from \(controller.displayedIndex); active WebKit \(resources.activeWebSurfaceCount), passive \(resources.activePassiveWebSurfaceCount), queued \(resources.pendingWebRequestCount), live pages \(controller.cachedPageIdentities.keys.sorted()); geometry=\(DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document).lastPreparationLayoutMismatch ?? "none"); owner=\(DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources))"
      }) {
        destination = forward
          ? controller.pageViewController(controller.pageViewController, viewControllerAfter: previous)
          : controller.pageViewController(controller.pageViewController, viewControllerBefore: previous)
        return destination != nil
      }
      let next = try XCTUnwrap(destination, "Landing \(expected) requires its prepared physical page")
      if let retained = retainedShells[expected] {
        XCTAssertTrue(next === retained, "A retained UIKit shell must be restored rather than replaced by another identity")
      }
      controller.pageViewController(controller.pageViewController, willTransitionTo: [next])
      controller.pageViewController.setViewControllers([next], direction: forward ? .forward : .reverse, animated: false)
      controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
        previousViewControllers: [previous], transitionCompleted: true)
      configure()
      XCTAssertEqual(controller.displayedIndex, expected)
      XCTAssertEqual(committed, expected)
      XCTAssertLessThanOrEqual(resources.activeWebSurfaceCount, 2,
        "The current paper and one non-executing preparation surface are the bounded physical window")
      XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4,
        "Settled live pages are the current page, its neighbours and one directional prewarm, not traversal history")
      let web = try await livePage(expected, in: next.view,
        diagnostics: { DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources) })
      let receipt = try await web.evaluateJavaScript("window.notebookRenderer.pageReceipt()") as? [String: Any]
      XCTAssertEqual(receipt?["pageIndex"] as? Int, expected,
        "The prepared next controller contains its own physical document page, not page zero")
    }
  }

  func testDistantSelectionsDuringARealDocumentCurlKeepTheSingleDocumentWebSurface() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    let peak = DocumentWebSurfacePeak(resources: resources)
    let paragraphs = (0..<160).map {
      "Paragraph \($0). " + String(repeating: "The physical page keeps its own content. ", count: 12)
    }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: paragraphs)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController()
    var commits: [Int] = []
    func configure(_ selected: Int) {
      controller.update(ownerID: document.id, sequenceRevision: "fixture-order", pageCount: 16, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, current, readiness in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          return AnyView(DocumentWebView(document: document, state: state, isInteractive: current,
            selectedPageIndex: index, capturesSnapshot: false, onRenderReady: readiness,
            onPageLayout: { _ in }, onLinkActivation: { _ in nil },  onStateChange: { _, _ in nil }, resources: resources, isCurrent: current))
        }, onCommit: { index, _ in commits.append(index) }, onTransitioningChange: { _ in })
    }
    configure(0); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let source = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    var destination: UIViewController?
    await waitUntil(timeout: .seconds(10), message: {
      "Initial full window: web \(resources.activeWebSurfaceCount), peak \(peak.maximum), contents \(controller.cachedPageIdentities.keys.sorted()), landing \(destination != nil)"
    }) {
      // One installed input surface and one reclaimable preparation executor
      // serve the whole bounded window; neighbours themselves remain pixels.
      guard resources.activeWebSurfaceCount - resources.activeBackgroundWebSurfaceCount == 1 else { return false }
      destination = controller.pageViewController(controller.pageViewController, viewControllerAfter: source)
      return destination != nil
    }
    let landing = try XCTUnwrap(destination)
    let preparedWeb = try XCTUnwrap(descendants(source.view).first { $0.isUserInteractionEnabled })
    XCTAssertTrue(descendants(landing.view).isEmpty, "A ready neighbouring physical sheet uses passive pixels from this runtime")
    controller.pageViewController(controller.pageViewController, willTransitionTo: [landing])
    let frozenWindow = controller.cachedPageIdentities
    for target in [7, 12, 9] {
      configure(target)
      await Task.yield()
      XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
      XCTAssertEqual(resources.activeWebSurfaceCount - resources.activeBackgroundWebSurfaceCount, 1)
      XCTAssertLessThanOrEqual(peak.maximum, 2)
    }
    controller.pageViewController.setViewControllers([landing], direction: .forward, animated: false)
    controller.pageViewController(controller.pageViewController, didFinishAnimating: true,
      previousViewControllers: [source], transitionCompleted: true)
    XCTAssertEqual(commits, [1])
    configure(1)
    await waitUntil(timeout: .seconds(10), message: {
      "Latest target 9, actual \(controller.displayedIndex); web \(resources.activeWebSurfaceCount), peak \(peak.maximum), contents \(controller.cachedPageIdentities.keys.sorted())"
    }) { controller.displayedIndex == 9 }
    XCTAssertEqual(commits, [1, 9])
    configure(9)
    let visible = try XCTUnwrap(controller.pageViewController.viewControllers?.first)
    let web = try await livePage(9, in: visible.view,
      diagnostics: { DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources) })
    XCTAssertTrue(web === preparedWeb)
    let receipt = try await web.evaluateJavaScript("window.notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(receipt?["pageIndex"] as? Int, 9)
    peak.sample()
    XCTAssertLessThanOrEqual(peak.maximum, 2,
      "Every physical handoff retains the same document runtime and at most one reusable preparation executor")
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  func testDetachedOverviewHostsReleaseTheirPageDemandWithoutWaitingForDeallocation() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      String(repeating: "A retained overview controller is not a visible reader.\n\n", count: 400))])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let root = UIViewController()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene); window.rootViewController = root; window.makeKeyAndVisible()
    let current = DocumentPhysicalPageCoordinator(), paper = DocumentWebHost()
    let coordinators = (0..<4).map { _ in DocumentPhysicalPageCoordinator() }
    let hosts = (0..<4).map { _ in DocumentWebHost() }
    var ready: Set<Int> = [], failures: [String] = []
    func present(_ coordinator: DocumentPhysicalPageCoordinator, host: DocumentWebHost, index: Int, thumbnail: Bool) {
      let key = thumbnail ? index : -1
      coordinator.update(.init(document: document, state: state, pageIndex: index,
        isCurrent: !thumbnail, isVisible: true, isInteractive: !thumbnail, pageTurnActive: false,
        onRenderReady: .init { if $0 { ready.insert(key) } else { ready.remove(key) } },
        onPageLayout: { _ in },  onStateChange: { _, _ in nil },
           onLinkActivation: { _ in },
        snapshotPixelWidth: thumbnail ? 256 : nil, onPreparationFailure: { failures.append(String(describing: $0)) }),
        in: host, resources: resources)
    }
    defer { current.invalidate(); coordinators.forEach { $0.invalidate() }; window.isHidden = true; window.rootViewController = nil }
    paper.frame = root.view.bounds; root.view.addSubview(paper)
    present(current, host: paper, index: 0, thumbnail: false)
    await waitUntil(timeout: .seconds(6), message: { "Current paper: \(failures)" }) { ready.contains(-1) }
    for index in hosts.indices {
      let host = hosts[index]; host.frame = .init(x: index * 140, y: 20, width: 130, height: 190)
      root.view.addSubview(host); present(coordinators[index], host: host, index: index, thumbnail: true)
    }
    await waitUntil(timeout: .seconds(8), message: { "Overview: \(ready), \(failures)" }) { ready.count == 5 }
    XCTAssertEqual(resources.rasterAdmission.pinnedCount, 4)
    // UIKit keeps both these hosts and their coordinators alive after closing
    // an overview. Native attachment, not deinit, ends their preparation demand.
    hosts.forEach { $0.removeFromSuperview() }
    current.invalidate(); ready.remove(-1); paper.removeFromSuperview()
    await waitUntil(timeout: .seconds(3), message: { "Detached overview retained \(resources.rasterAdmission.pinnedCount) rasters, \(resources.activeWebSurfaceCount) WebKit, ready \(ready), \(failures)" }) {
      ready.isEmpty && resources.rasterAdmission.pinnedCount == 0
        && resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0
    }
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    XCTAssertTrue(source.retainedPageIndices.isEmpty)
    XCTAssertEqual(source.pendingPreparationReaderCount, 0)
    // Reattaching the same native host is a real demand again; no new SwiftUI
    // identity or synthetic update is necessary to restore its exact page.
    root.view.addSubview(hosts[1])
    await waitUntil(timeout: .seconds(6), message: { "Reattached overview: \(ready), \(failures)" }) { ready == [1] }
    XCTAssertTrue(hosts[1].hasSnapshot)
    XCTAssertEqual(resources.rasterAdmission.pinnedCount, 1)
  }

  func testSixThumbnailsAndThreePhysicalPagesShareOneDocumentRuntime() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6, maximumBackgroundWebSurfaces: 2)
    let paragraphs = (0..<120).map { "Paragraph \($0). " + String(repeating: "A preview preserves the physical page. ", count: 12) }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: paragraphs)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    var liveReady: Set<Int> = [], previewReady: Set<Int> = []
    func content(previews: Bool) -> AnyView {
      AnyView(ZStack {
        ForEach(0..<3, id: \.self) { index in
          DocumentWebView(document: document, state: state, isInteractive: index == 0,
            selectedPageIndex: index, capturesSnapshot: false,
            onRenderReady: .init { if $0 { liveReady.insert(index) } else { liveReady.remove(index) } },
            onPageLayout: { _ in }, onLinkActivation: { _ in nil },  onStateChange: { _, _ in nil }, resources: resources, isCurrent: index == 0)
            .frame(width: geometry.width, height: geometry.height)
        }
        if previews {
          ForEach(0..<6, id: \.self) { index in
            DocumentThumbnailView(document: document, state: state, pageIndex: index,
              onRenderReady: .init { if $0 { previewReady.insert(index) } else { previewReady.remove(index) } }, resources: resources)
              .frame(width: geometry.width, height: geometry.height)
              .scaleEffect(0.1)
          }
        }
      })
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIHostingController(rootView: content(previews: false))
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await waitUntil(timeout: .seconds(10), message: { "Live pages \(liveReady.sorted()); \(DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources))" }) { liveReady.count == 3 }
    XCTAssertEqual(resources.activeWebSurfaceCount - resources.activeBackgroundWebSurfaceCount, 1)
    let sourceBytes = resources.reservedBytes
    XCTAssertGreaterThan(sourceBytes, 0)
    controller.rootView = content(previews: true)
    var peakWeb = 0, peakPreparation = 0
    await waitUntil(timeout: .seconds(20), message: {
      "Ready previews \(previewReady.sorted()), web \(resources.activeWebSurfaceCount), preparation \(resources.activeBackgroundWebSurfaceCount), queue \(resources.pendingWebRequestCount); \(DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources))"
    }) {
      peakWeb = max(peakWeb, resources.activeWebSurfaceCount)
      peakPreparation = max(peakPreparation, resources.activeBackgroundWebSurfaceCount)
      return previewReady.count == 6 && resources.activeWebSurfaceCount - resources.activeBackgroundWebSurfaceCount == 1 && resources.pendingWebRequestCount == 0
    }
    XCTAssertLessThanOrEqual(peakWeb, 3,
      "Current paper, one passive paper, and an inert measurement owner may overlap during preparation")
    XCTAssertLessThanOrEqual(peakPreparation, 2)
    XCTAssertEqual(descendants(controller.view).filter { web in
      guard let host = web.superview?.superview as? DocumentWebHost else { return false }
      return host.hasInteractiveSurface(web)
    }.count, 1, "Only the installed paper admits input; passive preparation and previews cannot")
    XCTAssertLessThanOrEqual(resources.activeWebSurfaceCount, 2)
    XCTAssertEqual(liveReady.count, 3)
    for index in 0..<6 {
      let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: index)
      let source = SceneRasterSource.document(id: document.id, token: token)
      let raster = try XCTUnwrap(resources.retainRaster(for: source))
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(raster.image.cgImage).width, 256)
      if index >= 3 {
        XCTAssertLessThanOrEqual(try XCTUnwrap(raster.image.cgImage).width, 256)
        XCTAssertNil(resources.retainRaster(for: source, minimumScale: 1), "A preview cannot certify exact paper-resolution export")
      }
      XCTAssertEqual(DocumentRenderRegistry.shared.entry(document: document, pageIndex: index)?.token, token)
      raster.release()
    }
    controller.rootView = content(previews: false)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    await waitUntil(message: { "Retained page packets after thumbnail removal: \(source.retainedPageIndices.sorted())" }) {
      resources.activeWebSurfaceCount - resources.activeBackgroundWebSurfaceCount == 1 && resources.pendingWebRequestCount == 0
        && source.retainedPageIndices.isSubset(of: Set(0...3))
    }
    XCTAssertTrue(source.retainedPageIndices.isSubset(of: Set(0...3)),
      "Removed thumbnail demand cannot retain far page packets")
    let whileMounted = resources.reservedBytes
    await source.discardIdlePreparation()
    XCTAssertEqual(resources.reservedBytes, whileMounted,
      "Mounted page demand protects the canonical source needed for native paper and navigation")
    XCTAssertEqual(liveReady, Set(0..<3), "Reclaiming inactive preparation leaves all installed physical pages usable")
    controller.rootView = AnyView(EmptyView())
    await waitUntil {
      resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0
        && source.retainedPageIndices.isEmpty
    }
    let beforeReclaim = resources.reservedBytes
    XCTAssertGreaterThan(beforeReclaim, 0, "The retained source still owns its canonical index")
    await source.discardIdlePreparation()
    XCTAssertLessThan(resources.reservedBytes, beforeReclaim,
      "The canonical index and unused page packets have a real memory lifecycle")
  }

  func testInitialInteractiveCommitBelongsToTheActiveRuntimeBeforeItsFirstFrame() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 2)
    let document = DocumentDocument(actor: UUID(), blocks: [
      .interactive(id: "initial", html: "<p>Initial state</p>", css: "",
        javaScript: "notebook.commit({ready:true});notebook.ready(Promise.resolve())", initialState: .null, height: 100)
    ])
    var activeStates: [JSONValue] = [], passiveStates: [JSONValue] = [], readyAtCommit: [Bool] = []
    var activeCoordinator: DocumentWebCoordinator?
    let active = fixture(resources: resources, interactive: true, document: document,
      state: { _, value in
        activeStates.append(value)
        readyAtCommit.append(activeCoordinator?.renderIsReady ?? true)
        return nil
      })
    activeCoordinator = active.coordinator
    let passive = fixture(resources: resources, interactive: false, document: document,
      state: { _, value in passiveStates.append(value); return nil })
    let window = try show(active.host)
    let container = try XCTUnwrap(window.rootViewController?.view)
    container.addSubview(passive.host); passive.host.frame = container.bounds
    defer { active.coordinator.invalidate(); passive.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8)) {
      active.coordinator.renderIsReady && passive.coordinator.renderIsReady && activeStates.count == 1
    }
    XCTAssertEqual(activeStates, [.object(["ready": .bool(true)])])
    XCTAssertEqual(readyAtCommit, [false], "Initial execution can commit before a finished frame exists")
    XCTAssertTrue(passiveStates.isEmpty, "A neighbour or preview cannot publish autonomous state into the document")
  }

  func testFailedThumbnailPreparationReleasesSlotsAndDoesNotRetryOnViewUpdates() async throws {
    let resources = SceneRenderResources(byteLimit: 0, maximumWebSurfaces: 6, maximumBackgroundWebSurfaces: 2)
    let documents = (0..<6).map { index in
      DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Preview \(index)")])
    }
    let states = documents.map { DocumentStateJournal(id: $0.id, actor: UUID()) }
    var failures: Set<Int> = [], ready: Set<Int> = []
    func content() -> AnyView {
      AnyView(ZStack {
        ForEach(0..<6, id: \.self) { index in
          let geometry = WorkspaceItemGeometry.document(documents[index].paperSize)
          DocumentThumbnailView(document: documents[index], state: states[index], pageIndex: 0,
            onRenderReady: .init { if $0 { ready.insert(index) } }, resources: resources,
            onFailure: { _ in failures.insert(index) })
            .frame(width: geometry.width, height: geometry.height).scaleEffect(0.1)
        }
      })
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIHostingController(rootView: content())
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await waitUntil(timeout: .seconds(12), message: {
      "Failed previews \(failures.sorted()), web \(resources.activeWebSurfaceCount), queue \(resources.pendingWebRequestCount)"
    }) {
      failures.count == 6 && resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0
    }
    XCTAssertTrue(ready.isEmpty)
    XCTAssertEqual(descendants(controller.view).count, 0)
    XCTAssertEqual(resources.reservedBytes, 0)
    controller.rootView = content()
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "A terminal failure cannot start a render loop when SwiftUI redraws the failure marker")
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  private func descendants(_ view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
  }

  private func livePage(_ index: Int, in view: UIView, diagnostics: () -> String = { "" }) async throws -> WKWebView {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      for web in descendants(view) {
        var ancestor: UIView? = web
        var acceptsInput = true
        while let next = ancestor { acceptsInput = acceptsInput && next.isUserInteractionEnabled; ancestor = next.superview }
        if acceptsInput,
          let receipt = try? await web.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any],
          receipt["pageIndex"] as? Int == index, receipt["layoutCanonical"] as? Bool == true { return web }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    var observed: [String] = []
    for web in descendants(view) {
      var path: [String] = [], ancestor: UIView? = web
      while let node = ancestor { path.append("\(type(of: node)):\(node.isUserInteractionEnabled)"); ancestor = node.superview }
      let receipt = try? await web.evaluateJavaScript("JSON.stringify(notebookRenderer.pageReceipt())")
      observed.append("\(path.joined(separator: "/")): \(String(describing: receipt))")
    }
    func hierarchy(_ node: UIView) -> String {
      "\(type(of: node))@\(ObjectIdentifier(node))[\(node.subviews.map(hierarchy).joined(separator: ","))]"
    }
    XCTFail("The selected physical page \(index) did not restore its exact live cut before admitting input: \(observed); tree=\(hierarchy(view)); owner=\(diagnostics())")
    throw DocumentSessionError.invalidLayout
  }

  private func fixture(resources: SceneRenderResources, interactive: Bool, document suppliedDocument: DocumentDocument? = nil,
    layout: @escaping (DocumentPageLayout) -> Void = { _ in },
    ready: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
    state stateChange: @escaping (String, JSONValue) -> ContentFieldVersion? = { _,_ in nil })
      -> (document: DocumentDocument, state: DocumentStateJournal, coordinator: DocumentWebCoordinator, host: DocumentWebHost) {
    let document = suppliedDocument ?? DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# A real document page\n\nA bounded WebKit owner.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init(ready),
      onPageLayout: layout,  onStateChange: stateChange)
    coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init(ready), onPageLayout: layout,  onStateChange: stateChange)
    let host = DocumentWebHost(), paper = WorkspaceItemGeometry.document(document.paperSize)
    coordinator.mount(in: host, physicalSize: .init(width: paper.width, height: paper.height),
      isInteractive: interactive, priority: interactive ? .currentPage : .neighbor)
    return (document, state, coordinator, host)
  }

  private func show(_ host: DocumentWebHost) throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(host); host.frame = controller.view.bounds
    host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.makeKeyAndVisible()
    return window
  }

  private func waitUntil(timeout: Duration = .seconds(2),
    message: () -> String = { "The bounded document resource transition did not complete" },
    _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), message())
  }
}

/// Observation reports before each assignment. Re-arm synchronously so the
/// following release also records a transient peak between two run-loop turns.
@MainActor
private final class DocumentWebSurfacePeak {
  private weak var resources: SceneRenderResources?
  private(set) var maximum = 0
  init(resources: SceneRenderResources) { self.resources = resources; observe() }
  func sample() {
    if let resources { maximum = max(maximum, resources.activeWebSurfaceCount) }
  }
  private func observe() {
    withObservationTracking { sample() } onChange: { [weak self] in
      MainActor.assumeIsolated { self?.observe() }
    }
  }
}
