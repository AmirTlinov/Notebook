import NotebookCore
import PDFKit
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
    let geometry = WorkspaceItemGeometry.uncompiledDocument
    fixture.host.frame = CGRect(x: -20_000, y: 0, width: geometry.width, height: geometry.height)
    fixture.host.layoutIfNeeded()
    await waitUntil(timeout: .seconds(8)) { fixture.coordinator.hasCanonicalPixels }
    func paper(in view: UIView) -> DocumentPaperView? {
      if let paper = view as? DocumentPaperView { return paper }
      for child in view.subviews {
        if let found = paper(in: child) { return found }
      }
      return nil
    }
    let view = try XCTUnwrap(paper(in: fixture.host))
    let prepared = try XCTUnwrap(view.raster)
    XCTAssertFalse(SceneSourceVisibility.isVisible(view))
    XCTAssertEqual(prepared.image.width, 1024, "Hidden paper keeps its bounded preparation, not a display-size copy")
    let before = resources.reservedBytes
    view.refine()
    XCTAssertEqual(resources.reservedBytes, before, "Offscreen refinement cannot consume snapshot admission")
    let web = try XCTUnwrap(fixture.coordinator.view)
    for width in [256, 1024] {
      fixture.coordinator.update(document: fixture.document, state: fixture.state, selectedPageIndex: 0,
        onPageLayout: { _ in }, paperPreparationPixelWidth: width,
        onPreparationFailure: { _ in }, onLinkActivation: { _ in }, preparationRequestID: nil)
      await waitUntil(timeout: .seconds(3)) {
        fixture.coordinator.hasCanonicalPixels && view.raster?.image.width == width
      }
      XCTAssertTrue(fixture.coordinator.view === web,
        "Thumbnail-to-paper promotion must honor resolution without replacing its native view")
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
    let oldWeb = try XCTUnwrap(outgoing.coordinator.view)
    let newWeb = try XCTUnwrap(incoming.coordinator.view)
    let size = newWeb.bounds.size
    // A live page landing replaces the physical host before the departed
    // coordinator is either reused for preparation or reclaimed by its pool.
    incoming.coordinator.mount(in: outgoing.host, physicalSize: size, isInteractive: true, priority: .currentPage)
    XCTAssertTrue(outgoing.host.ownsPaper(newWeb))
    XCTAssertFalse(oldWeb.isDescendant(of: outgoing.host))
    if reuse {
      let preparation = DocumentPageHost(); preparation.frame = incoming.host.frame
      container.addSubview(preparation)
      outgoing.coordinator.mount(in: preparation, physicalSize: size, isInteractive: false, priority: .neighbor)
      XCTAssertTrue(preparation.ownsPaper(oldWeb))
    } else { outgoing.coordinator.invalidate() }
    XCTAssertTrue(outgoing.host.ownsPaper(newWeb), "A retiring coordinator can remove only its own native paper")
    XCTAssertTrue(newWeb.window === window, "The incoming live paper must remain in the native window")
    XCTAssertTrue(incoming.coordinator.hasCanonicalPixels)
    let installed = try XCTUnwrap(incoming.coordinator.installedPaper)
    XCTAssertTrue(PDFDocument(data: installed.page.artifact.pdf)?.page(at: installed.page.pageIndex)?.string?.contains("A real document page") == true)
  }

  func testLoadedPhysicalPaperCannotClaimNativeSourceScrolling() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      String(repeating: "A physical page belongs to the native curl.\n\n", count: 100))])
    let fixture = fixture(resources: resources, interactive: true, document: document)
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(6)) { fixture.coordinator.hasCanonicalPixels }
    XCTAssertTrue(fixture.coordinator.hasCanonicalPixels)
    XCTAssertTrue(descendants(fixture.host).isEmpty)
    XCTAssertFalse(fixture.coordinator.view.isUserInteractionEnabled)
    XCTAssertTrue(fixture.host.hasCanonicalPaper(fixture.coordinator.view))
  }

  func testProducerServesExactPageDemandWithoutExpandingTheSceneWindowAgain() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
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
    // Simultaneous physical consumers share the in-flight extraction, not
    // only a fragment that happened to finish before the second request.
    async let firstResult = source.preparedPage(2, hostID: first, resources: resources)
    async let secondResult = source.preparedPage(2, hostID: second, resources: resources)
    let (firstPage, secondPage) = try await (firstResult, secondResult)
    XCTAssertTrue(firstPage === secondPage)
    XCTAssertEqual(source.retainedPageIndices, [0, 2])
    XCTAssertEqual(source.compiledPageCount, 2, "Two consumers share one compiled fragment")
    source.releasePage(hostID: first, in: nil)
    XCTAssertEqual(source.retainedPageIndices, [0, 2])
    source.releasePage(hostID: second, in: nil)
    XCTAssertEqual(source.retainedPageIndices, [0], "The last consumer releases only its own demand")
    XCTAssertEqual(source.measurementCount, 1)
  }

  func testRequiredSourcePreparationRecoversOnTheSamePaperWhenActualBytesAreReleased() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - 2_048, priority: .passive))
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      (0..<20).map { "Paragraph \($0). " + String(repeating: "Retained content survives admission pressure. ", count: 8) }.joined(separator: "\n\n"))])
    let fixture = fixture(resources: resources, interactive: true, document: document)
    let window = try show(fixture.host)
    defer { blocker.release(); fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(6)) { resources.lastRasterRefusal != nil }
    let source = try XCTUnwrap(fixture.coordinator.payload?.source)
    let web = try XCTUnwrap(fixture.coordinator.view)
    let runtime = fixture.coordinator.payload?.runtimeID
    let refusal = try XCTUnwrap(resources.lastRasterRefusal).generation
    XCTAssertFalse(fixture.coordinator.hasCanonicalPixels)
    XCTAssertNil(fixture.coordinator.acquisitionError,
      "Temporary source admission is loading, not a poisoned source or a destroyed runtime")
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(resources.lastRasterRefusal?.generation, refusal)
    blocker.release()
    await waitUntil(timeout: .seconds(6)) { fixture.coordinator.hasCanonicalPixels || fixture.coordinator.acquisitionError != nil }
    XCTAssertTrue(fixture.coordinator.hasCanonicalPixels)
    XCTAssertNil(fixture.coordinator.acquisitionError)
    XCTAssertTrue(fixture.coordinator.view === web)
    XCTAssertTrue(fixture.coordinator.payload?.source === source)
    XCTAssertEqual(fixture.coordinator.payload?.runtimeID, runtime)
    XCTAssertEqual(source.preparationCount, 1)
    XCTAssertEqual(source.measurementCount, 1)
    XCTAssertEqual(web.raster?.page.pageIndex, 0)
    XCTAssertTrue(fixture.coordinator.hasCanonicalPixels)
  }

  func testRetiringTheMeasurementHostPreservesAnAlreadyWaitingSecondReader() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\section{Surviving reader}\\hypertarget{surviving-reader}{}\n\n" + String(repeating: "One source can serve another physical reader. ", count: 160))])
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - 1, priority: .passive))
    let first = fixture(resources: resources, interactive: true, document: document)
    let window = try show(first.host)
    defer { blocker.release(); first.coordinator.invalidate(); window.isHidden = true }
    let source = try XCTUnwrap(first.coordinator.payload?.source)
    await waitUntil(timeout: .seconds(6)) {
      resources.pendingDerivedRequestCount == 1 && source.pendingPreparationReaderCount == 1
    }
    // The second paper reader joins the same pending native print allocation
    // only after the first reader's real admission refusal.
    let second = fixture(resources: resources, interactive: true, document: document,
      store: first.coordinator.programStore)
    defer { second.coordinator.invalidate() }
    let container = try XCTUnwrap(window.rootViewController?.view)
    container.addSubview(second.host); second.host.frame = container.bounds
    XCTAssertTrue(second.coordinator.payload?.source === source)
    await waitUntil(timeout: .seconds(6)) {
      resources.pendingDerivedRequestCount == 1 && source.pendingPreparationReaderCount == 2
    }
    let survivingWeb = try XCTUnwrap(second.coordinator.view)
    let survivingRuntime = second.coordinator.payload?.runtimeID
    first.coordinator.invalidate()
    await waitUntil(timeout: .seconds(6)) {
      source.pendingPreparationReaderCount == 1 && resources.pendingDerivedRequestCount == 1
        && resources.activeWebSurfaceCount == 0
    }
    XCTAssertNil(first.coordinator.view.raster)
    XCTAssertNil(second.coordinator.acquisitionError)
    blocker.release()
    await waitUntil(timeout: .seconds(6)) { second.coordinator.hasCanonicalPixels || second.coordinator.acquisitionError != nil }
    XCTAssertTrue(second.coordinator.hasCanonicalPixels)
    XCTAssertNil(second.coordinator.acquisitionError)
    XCTAssertTrue(second.coordinator.view === survivingWeb)
    XCTAssertEqual(second.coordinator.payload?.runtimeID, survivingRuntime)
    XCTAssertTrue(second.coordinator.payload?.source === source)
    XCTAssertEqual(source.pendingPreparationReaderCount, 0)
    XCTAssertEqual(resources.pendingDerivedRequestCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
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
    XCTAssertNil(fixture.coordinator.view.raster)
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
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      (0..<50).map { "Абзац \($0). " + String(repeating: "Содержание остаётся на своём физическом листе. ", count: 12) }.joined(separator: "\n\n"))])
    var pageCount = 0
    let fixture = fixture(resources: resources, interactive: true, document: document, layout: { pageCount = $0.pageCount })
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8), message: {
      "ready=\(fixture.coordinator.hasCanonicalPixels) error=\(String(describing: fixture.coordinator.acquisitionError)) peak=\(resources.peakAccountedBytes)"
    }) { fixture.coordinator.hasCanonicalPixels || fixture.coordinator.acquisitionError != nil }
    XCTAssertNil(fixture.coordinator.acquisitionError)
    XCTAssertTrue(fixture.coordinator.hasCanonicalPixels)
    XCTAssertGreaterThan(pageCount, 1)
    XCTAssertEqual(fixture.coordinator.payload?.source.preparationCount, 1)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertLessThan(resources.peakAccountedBytes, sceneBytes + 48 * 1024 * 1024,
      "Bounded PDF decode, paper pixels and hit regions stay within the passive scene allowance")
    XCTAssertEqual(scene.byteCount, sceneBytes)
    XCTAssertFalse(scene.isReleased, "Preparation cannot evict the shown scene")
  }

  func testReadyDocumentKeepsItsNativePaperWhenItBecomesTheNeighbourInTheCurl() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let fixture = fixture(resources: resources, interactive: true)
    let window = try show(fixture.host)
    defer { fixture.coordinator.invalidate(); window.isHidden = true }
    await waitUntil(timeout: .seconds(8)) { fixture.coordinator.hasCanonicalPixels }
    let original = try XCTUnwrap(fixture.coordinator.view)
    let paper = WorkspaceItemGeometry.uncompiledDocument
    fixture.coordinator.mount(in: fixture.host, physicalSize: .init(width: paper.width, height: paper.height),
      isInteractive: false, priority: .neighbor)
    XCTAssertTrue(fixture.coordinator.view === original)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertFalse(fixture.coordinator.nativeInputIsReady(in: fixture.host))
    XCTAssertTrue(fixture.coordinator.hasCanonicalPixels)
  }

  func testChangingDocumentOwnerWithEqualVersionStampsReplacesItsPayload() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let fixture = fixture(resources: resources, interactive: true)
    defer { fixture.coordinator.invalidate() }
    let other = DocumentTestFiles.document(actor: fixture.document.contentStamp.actor,
      contents: [.tex(id: "body", source: "A different physical owner")])
    let state = DocumentStateJournal(id: other.id, actor: fixture.state.stamp.actor)
    fixture.coordinator.update(document: other, state: state, selectedPageIndex: 0, onPageLayout: { _ in },
      onPreparationFailure: { _ in }, onLinkActivation: { _ in }, preparationRequestID: nil)
    XCTAssertEqual(fixture.coordinator.payload?.documentID, other.id)
    XCTAssertEqual(fixture.coordinator.payload?.source.document.files.first { $0.id == "body" }?.source, "A different physical owner")
  }

  func testRepeatedActualPageCurlLandingsDoNotExhaustTheDocumentPool() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    let paragraphs = (0..<160).map { "Paragraph \($0). " + String(repeating: "The physical page keeps its own content. ", count: 12) }.joined(separator: "\n\n")
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: paragraphs)])
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
          AnyView(DocumentPageView(document: document, state: state, isInteractive: current,
            selectedPageIndex: index, capturesSnapshot: false, onRenderReady: readiness,
            onPageLayout: { _ in }, onLinkActivation: { _ in nil },  onStateChange: { _, _ in nil }, resources: resources, isCurrent: current))
        }, onCommit: { index, _ in committed = index }, onTransitioningChange: { _ in })
    }
    configure(); window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    // Keep old shells alive as UIKit is allowed to do; releasing their content
    // must not depend on the framework immediately deallocating a controller.
    for expected in Array(1...7) + Array((0...6).reversed()) {
      let previous = try XCTUnwrap(controller.sheetController.page)
      let forward = expected > controller.displayedIndex
      var destination: UIViewController?
      await waitUntil(timeout: .seconds(10), message: {
        "Landing \(expected) from \(controller.displayedIndex); active WebKit \(resources.activeWebSurfaceCount), passive \(resources.activePassiveWebSurfaceCount), queued \(resources.pendingWebRequestCount), live pages \(controller.cachedPageIdentities.keys.sorted()); geometry=\(DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document).lastPreparationLayoutMismatch ?? "none"); owner=\(DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources))"
      }) {
        destination = forward
          ? controller.sheetController(controller.sheetController, after: previous)
          : controller.sheetController(controller.sheetController, before: previous)
        return destination != nil
      }
      let next = try XCTUnwrap(destination, "Landing \(expected) requires its prepared physical page")
      let operation = try PageTurnFrameFixture.begin(on: controller, target: next, direction: forward ? .forward : .reverse)
      PageTurnFrameFixture.finish(on: controller, operation: operation, completed: true)
      configure()
      XCTAssertEqual(controller.displayedIndex, expected)
      XCTAssertEqual(committed, expected)
      XCTAssertEqual(resources.activeWebSurfaceCount, 0,
        "Plain document navigation consumes no program executor")
      XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4,
        "Settled live pages are the current page, its neighbours and one directional prewarm, not traversal history")
      let web = try await livePage(expected, in: next.view,
        diagnostics: { DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources) })
      XCTAssertEqual(web.raster?.page.pageIndex, expected,
        "The prepared next controller contains its own physical document page, not page zero")
    }
  }

  func testDistantSelectionsDuringARealDocumentCurlKeepTheBoundedPaperOwners() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    let peak = DocumentWebSurfacePeak(resources: resources)
    let pages = (0..<16).map {
      "\\section*{Physical page \($0 + 1)}\n" + String(repeating: "The physical page keeps its own content. ", count: 12)
    }.joined(separator: "\n\\newpage\n")
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: pages)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let revision = "\(document.contentStamp.actor):\(document.contentStamp.counter)"
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = IPadPageTurnController()
    var commits: [Int] = [], selected = 0
    var layout: DocumentPageLayout?, request: DocumentPageNavigationRequest?, fulfilledRequest: UUID?
    var preparedTarget: DocumentPaperView?
    func configure() {
      controller.update(ownerID: document.id, sequenceRevision: revision, pageCount: layout?.pageCount ?? 16, selectedIndex: selected,
        navigationIsEnabled: true, pageIsInteractive: true, canBeginNavigation: { true },
        page: { index, current, readiness in
          XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
          let observedReadiness = PageTurnReadiness(activity: readiness.activity, pageIndex: index,
            isInActiveTurn: readiness.isInActiveTurn, onFailure: { readiness.failed($0) }) { ready in
            if ready, index == 9, preparedTarget == nil, controller.displayedIndex != 9 {
              // Observe the actual live destination before readiness lets the
              // native controller land it; do not substitute the outgoing shell.
              preparedTarget = self.papers(controller.view).first { $0.raster?.page.pageIndex == index }
              XCTAssertNotNil(preparedTarget)
            }
            readiness(ready)
          }
          return AnyView(DocumentPageView(document: document, state: state, isInteractive: current,
            selectedPageIndex: index, capturesSnapshot: false, onRenderReady: observedReadiness,
            onPageLayout: { layout = $0 }, onLinkActivation: { _ in nil }, onStateChange: { _, _ in nil }, resources: resources, isCurrent: current))
        }, onCommit: { _, _ in XCTFail("A document landing uses its source-bound receipt") }, onTransitioningChange: { _ in },
        canonicalDocumentLayout: layout, documentSelection: request,
        documentNavigation: .init(bind: { _, _, _ in }, unbind: { _ in }, landed: { receipt in
          XCTAssertEqual(receipt.sourceRevision, revision)
          if selected != receipt.pageIndex { commits.append(receipt.pageIndex) }
          selected = receipt.pageIndex
          if request?.id == receipt.requestID { fulfilledRequest = receipt.requestID; request = nil }
        }, status: { _ in }))
    }
    configure(); window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let source = try XCTUnwrap(controller.sheetController.page)
    var destination: UIViewController?
    await waitUntil(timeout: .seconds(10), message: {
      "Initial full window: web \(resources.activeWebSurfaceCount), peak \(peak.maximum), contents \(controller.cachedPageIdentities.keys.sorted()), landing \(destination != nil)"
    }) {
      // One installed input surface and one reclaimable preparation executor
      // serve the whole bounded window; neighbours themselves remain pixels.
      guard resources.activeWebSurfaceCount == 0 else { return false }
      destination = controller.sheetController(controller.sheetController, after: source)
      return destination != nil
    }
    XCTAssertEqual(try XCTUnwrap(layout).pageCount, 16)
    let landing = try XCTUnwrap(destination)
    let preparedWeb = try await livePage(0, in: source.view)
    let sharedSource = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    XCTAssertTrue(descendants(landing.view).isEmpty, "A ready neighbouring physical sheet uses passive pixels from this runtime")
    let operation = try PageTurnFrameFixture.begin(on: controller, target: landing)
    let frozenWindow = controller.cachedPageIdentities
    for target in [7, 12, 9] {
      request = .init(id: UUID(), documentID: document.id, sourceRevision: revision, pageIndex: target)
      configure()
      await Task.yield()
      XCTAssertEqual(controller.cachedPageIdentities, frozenWindow)
      XCTAssertEqual(resources.activeWebSurfaceCount, 0)
      XCTAssertEqual(peak.maximum, 0)
    }
    let latestRequest = try XCTUnwrap(request).id
    PageTurnFrameFixture.finish(on: controller, operation: operation, completed: true)
    XCTAssertEqual(commits, [1])
    configure()
    await waitUntil(timeout: .seconds(10), message: {
      "Latest target 9, actual \(controller.displayedIndex); web \(resources.activeWebSurfaceCount), peak \(peak.maximum), contents \(controller.cachedPageIdentities.keys.sorted())"
    }) { controller.displayedIndex == 9 }
    XCTAssertEqual(commits, [1, 9])
    XCTAssertEqual(fulfilledRequest, latestRequest)
    configure()
    let visible = try XCTUnwrap(controller.sheetController.page)
    let web = try await livePage(9, in: visible.view,
      diagnostics: { DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources) })
    XCTAssertFalse(try XCTUnwrap(preparedTarget) === preparedWeb,
      "A distant live target prepares without replacing the current paper before its native handoff")
    XCTAssertTrue(web === preparedTarget, "The landing adopts the exact prepared native paper")
    XCTAssertEqual(web.raster?.sourceKey, sharedSource.message.key)
    XCTAssertEqual(web.raster?.page.pageIndex, 9)
    peak.sample()
    XCTAssertEqual(peak.maximum, 0,
      "Every physical handoff uses the shared native PDF")
    XCTAssertLessThanOrEqual(controller.cachedPageIdentities.count, 4)
  }

  func testDetachedOverviewHostsReleaseTheirPageDemandWithoutWaitingForDeallocation() async throws {
    let resources = SceneRenderResources(profile: .interactive)
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      String(repeating: "A retained overview controller is not a visible reader.\n\n", count: 400))])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let root = UIViewController()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene); window.rootViewController = root; window.makeKeyAndVisible()
    let current = DocumentPhysicalPageCoordinator(), paper = DocumentPageHost()
    let coordinators = (0..<4).map { _ in DocumentPhysicalPageCoordinator() }
    let hosts = (0..<4).map { _ in DocumentPageHost() }
    var ready: Set<Int> = [], failures: [String] = []
    func present(_ coordinator: DocumentPhysicalPageCoordinator, host: DocumentPageHost, index: Int, thumbnail: Bool) {
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

  func testSixThumbnailsAndThreePhysicalPagesShareOneCanonicalSourceWithoutWebKit() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 6, maximumBackgroundWebSurfaces: 2)
    let paragraphs = (0..<120).map { "Paragraph \($0). " + String(repeating: "A preview preserves the physical page. ", count: 12) }.joined(separator: "\n\n")
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: paragraphs)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let geometry = WorkspaceItemGeometry.uncompiledDocument
    var liveReady: Set<Int> = [], previewReady: Set<Int> = []
    func content(previews: Bool) -> AnyView {
      AnyView(ZStack {
        ForEach(0..<3, id: \.self) { index in
          DocumentPageView(document: document, state: state, isInteractive: index == 0,
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
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    let sourceBytes = resources.reservedBytes
    XCTAssertGreaterThan(sourceBytes, 0)
    controller.rootView = content(previews: true)
    var peakWeb = 0, peakPreparation = 0
    await waitUntil(timeout: .seconds(20), message: {
      "Ready previews \(previewReady.sorted()), web \(resources.activeWebSurfaceCount), preparation \(resources.activeBackgroundWebSurfaceCount), queue \(resources.pendingWebRequestCount); \(DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: resources))"
    }) {
      peakWeb = max(peakWeb, resources.activeWebSurfaceCount)
      peakPreparation = max(peakPreparation, resources.activeBackgroundWebSurfaceCount)
      return previewReady.count == 6 && resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0
    }
    XCTAssertEqual(peakWeb, 0,
      "Native PDF preparation is independent of program execution slots")
    XCTAssertLessThanOrEqual(peakPreparation, 2)
    XCTAssertTrue(descendants(controller.view).isEmpty, "Plain paper and previews require no WebKit")
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
      XCTAssertEqual(DocumentRenderRegistry.shared.entry(document: document, pageIndex: index)?.pageIndex, index)
      raster.release()
    }
    controller.rootView = content(previews: false)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    await waitUntil(message: { "Retained page packets after thumbnail removal: \(source.retainedPageIndices.sorted())" }) {
      resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0
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

  func testFailedThumbnailPreparationReleasesSlotsAndDoesNotRetryOnViewUpdates() async throws {
    let resources = SceneRenderResources(byteLimit: 0, maximumWebSurfaces: 6, maximumBackgroundWebSurfaces: 2)
    let documents = (0..<6).map { index in
      DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{Preview }\\hypertarget{preview}{}\(index)")])
    }
    let states = documents.map { DocumentStateJournal(id: $0.id, actor: UUID()) }
    var failures: Set<Int> = [], ready: Set<Int> = []
    func content() -> AnyView {
      AnyView(ZStack {
        ForEach(0..<6, id: \.self) { index in
          let geometry = WorkspaceItemGeometry.uncompiledDocument
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

  private func papers(_ view: UIView) -> [DocumentPaperView] {
    (view as? DocumentPaperView).map { [$0] } ?? view.subviews.flatMap(papers)
  }

  private func livePage(_ index: Int, in view: UIView, diagnostics: () -> String = { "" }) async throws -> DocumentPaperView {
    let deadline = ContinuousClock.now + .seconds(8)
    while .now < deadline {
      if let paper = papers(view).first(where: { paper in
        guard paper.raster?.page.pageIndex == index else { return false }
        var ancestor = paper.superview
        while let next = ancestor {
          if let host = next as? DocumentPageHost { return host.hasCanonicalPaper(paper) && host.isUserInteractionEnabled }
          ancestor = next.superview
        }
        return false
      }) { return paper }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Physical page \(index) has no native canonical input cut: \(diagnostics())")
    throw DocumentSessionError.invalidLayout
  }

  private func fixture(resources: SceneRenderResources, interactive: Bool, document suppliedDocument: DocumentDocument? = nil,
    store suppliedStore: NotebookStore? = nil,
    layout: @escaping (DocumentPageLayout) -> Void = { _ in },
    ready: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
    state stateChange: @escaping (DocumentProgramSource, JSONValue) -> ContentFieldVersion? = { _,_ in nil })
      -> (document: DocumentDocument, state: DocumentStateJournal, coordinator: DocumentPaperCoordinator, host: DocumentPageHost) {
    let document = suppliedDocument ?? DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{A real document page}\\hypertarget{a-real-document-page}{}\n\nA bounded WebKit owner.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let store: NotebookStore
    if let suppliedStore { store = suppliedStore }
    else {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
      try! store.prepare()
      addTeardownBlock { try? FileManager.default.removeItem(at: store.root) }
    }
    let session = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources)
    let coordinator = DocumentPaperCoordinator(resources: resources, renderSession: session)
    coordinator.programStore = store
    coordinator.onPaperReady = { ready(true) }
    coordinator.update(document: document, state: state, selectedPageIndex: 0, onPageLayout: layout,
      onPreparationFailure: { _ in }, onLinkActivation: { _ in }, preparationRequestID: nil)
    let host = DocumentPageHost(), paper = WorkspaceItemGeometry.uncompiledDocument
    coordinator.mount(in: host, physicalSize: .init(width: paper.width, height: paper.height),
      isInteractive: interactive, priority: interactive ? .currentPage : .neighbor)
    return (document, state, coordinator, host)
  }

  private func show(_ host: DocumentPageHost) throws -> UIWindow {
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
