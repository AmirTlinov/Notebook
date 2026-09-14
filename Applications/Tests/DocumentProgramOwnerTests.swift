import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentProgramOwnerTests: XCTestCase {
  func testDistantLivePaperTransfersWithoutSnapshotOrASecondRender() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "[Far](#far)\n\n" + String(repeating: "Physical paper keeps its canonical geometry and links.\n\n", count: 160)
      + "\n\n# Far\n\n[Return](#body)")])
    let measurements = DocumentPresentationRecorder(enabled: true)
    let fixture = try ProgramFixture(document: document, measurements: measurements, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let original = try XCTUnwrap(fixture.paper(in: 0))
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let target = try XCTUnwrap(source.layout?.anchorPages["far"])
    XCTAssertGreaterThan(target, 1)
    let measurementCount = source.measurementCount
    let request = measurements.request(documentID: document.id, pageIndex: target, cause: .page)
    fixture.activity.prepare(target, presentation: .live)
    let demand = try XCTUnwrap(fixture.activity.preparationDemand)
    fixture.showPages(current: 0, neighbour: target); fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    let incoming = try XCTUnwrap(fixture.paper(in: 1))
    let before = try await incoming.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertFalse(incoming === original)
    XCTAssertFalse(fixture.hosts[1].hasSnapshot)
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedCount, 0, "Live landing must not allocate a full-page bridge image")
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertFalse(fixture.hosts[1].isUserInteractionEnabled)
    let attempt = try XCTUnwrap(measurements.records.first { $0.id == request }?.landingAttempts.last)
    XCTAssertEqual(attempt.stage, .completed); XCTAssertNil(attempt.captureStartedAt)

    fixture.activity.update(true)
    fixture.activity.didInstall(demand); fixture.activity.prepare(nil); fixture.activity.update(false)
    fixture.retirePresentation(0)
    let owner = DocumentProgramOwner.shared(documentID: document.id, resources: fixture.resources)
    await owner.observePendingPresentationWork()
    XCTAssertTrue(fixture.paper(in: 1) === incoming, "Native completion retains the target while SwiftUI current input is delayed")
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 1) && (incoming.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[1]) == true
    }
    XCTAssertTrue(fixture.paper(in: 1) === incoming)
    let after = try await incoming.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(after?["generation"] as? String, before?["generation"] as? String)
    XCTAssertEqual(after?["runtimeID"] as? String, before?["runtimeID"] as? String)
    XCTAssertEqual(after?["renderToken"] as? String, fixture.currentToken)
    XCTAssertEqual(source.measurementCount, measurementCount)
    XCTAssertFalse(fixture.hosts[1].hasSnapshot)
    let image = XCTAttachment(image: try fixture.windowImage())
    image.name = "live-distant-paper-without-snapshot"; image.lifetime = .keepAlways; add(image)

    fixture.activity.prepare(0, presentation: .live); fixture.restorePresentation(0)
    let returning = try XCTUnwrap(fixture.activity.preparationDemand)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    XCTAssertTrue(fixture.paper(in: 0) === original, "Return reuses the other existing paper shell")
    fixture.activity.update(true); fixture.activity.didInstall(returning)
    fixture.select(0); fixture.activity.prepare(nil); fixture.activity.update(false)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 0) && (original.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[0]) == true
    }
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    fixture.close()
    try await wait(message: { fixture.diagnostics }) {
      fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.rasterAdmission.pinnedCount == 0
    }
  }

  func testLiveTargetSupersessionAndCloseCancelItsQueuedAdmission() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "# Current\n\n" + String(repeating: "An accepted target does not retire the visible page.\n\n", count: 180)
      + "\n\n# Far")])
    let resources = SceneRenderResources(maximumWebSurfaces: 1, reservedInteractiveSlots: 0)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let current = try XCTUnwrap(fixture.paper(in: 0))
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    let target = try XCTUnwrap(source.layout?.anchorPages["far"])
    XCTAssertGreaterThan(target, 2)
    let owner = DocumentProgramOwner.shared(documentID: document.id, resources: resources)
    fixture.activity.prepare(target, presentation: .live)
    fixture.showPages(current: 0, neighbour: target); fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == target && resources.pendingWebRequestCount == 1 }
    fixture.activity.prepare(target - 1, presentation: .live)
    fixture.showPages(current: 0, neighbour: target - 1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == target - 1 && resources.pendingWebRequestCount == 1 }
    XCTAssertTrue(fixture.paper(in: 0) === current)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertFalse(fixture.ready[1] == true)
    fixture.close()
    try await wait(message: { fixture.diagnostics }) { resources.pendingWebRequestCount == 0 && resources.activeWebSurfaceCount == 0 }
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testSnapshotDensityUsesTheNativeCameraProjectionAndKeepsPhysicalBounds() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let camera = UIView(frame: .init(x: 0, y: 0, width: 1_600, height: 2_000))
    let host = DocumentWebHost()
    host.frame = .init(x: 0, y: 0, width: 800, height: 1_000)
    controller.view.addSubview(camera); camera.addSubview(host)
    let physical = CGSize(width: 400, height: 500)
    let bounds = host.bounds
    XCTAssertEqual(host.projectedPixelScale(for: physical), 2 * window.screen.scale, accuracy: 0.001)
    camera.transform = .init(scaleX: 0.25, y: 0.25)
    XCTAssertEqual(host.projectedPixelScale(for: physical), 0.5 * window.screen.scale, accuracy: 0.001)
    camera.transform = camera.transform.rotated(by: .pi / 3)
    XCTAssertEqual(host.projectedPixelScale(for: physical), 0.5 * window.screen.scale, accuracy: 0.001)
    XCTAssertEqual(host.bounds, bounds, "Pixel density must not relayout the canonical paper")
  }

  func testPressureReclaimsAnInvisibleNeighbourWithoutRevokingCurrentInput() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      (0..<50).map { "Paragraph \($0). " + String(repeating: "A neighbouring page is disposable until a real turn accepts it. ", count: 10) }.joined(separator: "\n\n"))])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.ready[1] == true && fixture.hosts[1].hasSnapshot
        && fixture.canonicalPaper(in: 0)
    }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let renderer = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    let snapshotID = try XCTUnwrap(fixture.hosts[1].snapshotEntryID)
    XCTAssertTrue(fixture.hosts[1].hasVisibleSnapshot)
    fixture.hosts[1].isHidden = true
    fixture.activity.update(true)
    let protected = fixture.resources.rasterAdmission
    let protectedRequest = fixture.resources.reserveDerivedBytes(
      max(1, protected.passiveByteLimit - protected.pinnedBytes - protected.passiveReservedBytes + 1), priority: .passive)
    XCTAssertEqual(fixture.hosts[1].snapshotEntryID, snapshotID,
      "An accepted turn protects even its currently hidden neighbour")
    protectedRequest?.release()
    try await wait(message: { fixture.diagnostics }) { fixture.resources.pendingReclamationCount == 0 }
    fixture.activity.update(false)
    let before = fixture.resources.rasterAdmission
    let admitted = try XCTUnwrap(fixture.resources.reserveDerivedBytes(
      max(1, before.passiveByteLimit - before.pinnedBytes - before.passiveReservedBytes + 1), priority: .passive))
    defer { admitted.release() }
    XCTAssertNil(fixture.hosts[1].snapshotEntryID)
    XCTAssertEqual(fixture.ready[1], false)
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertTrue(renderer.nativeInputIsReady(in: fixture.hosts[0]))
    XCTAssertEqual(fixture.ready[0], true)
  }

  func testFallbackPixelsDenyNewNativeHitsUntilCanonicalPaperIsInstalled() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Installed paper\n\n[Target](#target)\n\n# Target")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    let raster = try await coordinator.retainPreparedSnapshot(pixelWidth: 128)
    defer { raster.release(); coordinator.releasePreparedSnapshot() }
    let host = fixture.hosts[0]
    host.installSnapshot(raster)
    coordinator.updateInputAdmission(in: host, isInteractive: true)
    XCTAssertTrue(host.hasSnapshot)
    XCTAssertTrue(coordinator.hasCanonicalPixels, "Prepared DOM alone does not admit a gesture")
    XCTAssertFalse(coordinator.acceptsInput)
    XCTAssertFalse(coordinator.nativeInputIsReady(in: host))
    let hit = fixture.window.hitTest(host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: fixture.window), with: nil)
    XCTAssertFalse(hit === web || hit?.isDescendant(of: web) == true,
      "A visible snapshot must never route the first native hit into its hidden DOM")
    host.removeFallback()
    coordinator.updateInputAdmission(in: host, isInteractive: true)
    XCTAssertTrue(coordinator.acceptsInput)
    XCTAssertTrue(coordinator.nativeInputIsReady(in: host))
    XCTAssertTrue(fixture.paper(in: 0) === web)
    try await fixture.assertPaperReceivesNativeHit(web)
  }

  func testFailureOfPreviousSourceDoesNotPoisonTheSamePageAfterEditing() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# First source")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    coordinator.webView(web, didFail: nil, withError: NSError(domain: "SourceFailureContract", code: 1))
    try await wait(message: { fixture.diagnostics }) { !fixture.preparationErrors.isEmpty }
    let owner = DocumentProgramOwner.shared(documentID: document.id, resources: fixture.resources)
    await owner.observePendingPresentationWork()
    fixture.replaceSource(blockID: "body", source: "# Repaired source\n\nThe same page number now has a different version.")
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    try await wait(message: { fixture.diagnostics }) {
      guard let web = fixture.paper(in: 0), let renderer = web.navigationDelegate as? DocumentWebCoordinator else { return false }
      return renderer.nativeInputIsReady(in: fixture.hosts[0])
    }
    let replacement = try XCTUnwrap(fixture.paper(in: 0))
    let text = try await replacement.evaluateJavaScript("document.body.innerText") as? String
    XCTAssertTrue(text?.contains("Repaired source") == true)
    XCTAssertTrue((replacement.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[0]) == true)
  }

  func testProsePagePreparationReusesItsIdleExecutorAcrossDifferentTargets() async throws {
    let text = (0..<70).map { "Paragraph \($0). " + String(repeating: "A measured page keeps reusable preparation. ", count: 12) }.joined(separator: "\n\n")
    let fixture = try ProgramFixture(document: .init(actor: UUID(), blocks: [.markdown(id: "body", source: text)]))
    defer { fixture.close() }
    let owner = DocumentProgramOwner.shared(documentID: fixture.document.id, resources: fixture.resources)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true }
    func allWeb(_ view: UIView) -> [WKWebView] {
      (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(allWeb)
    }
    let current = try XCTUnwrap(fixture.paper(in: 0))
    try await wait(message: { fixture.diagnostics }) { allWeb(fixture.hosts[0]).contains { $0 !== current } }
    let preparer = try XCTUnwrap(allWeb(fixture.hosts[0]).first { $0 !== current })
    XCTAssertFalse((preparer.navigationDelegate as? DocumentWebCoordinator)?.hasCanonicalPixels == true)
    let identity = ObjectIdentifier(preparer)
    fixture.showPages(current: 0, neighbour: 3)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true }
    await owner.observePendingPresentationWork()
    XCTAssertTrue(allWeb(fixture.hosts[0]).contains { ObjectIdentifier($0) == identity })
    XCTAssertEqual((preparer.navigationDelegate as? DocumentWebCoordinator)?.payload?.pageIndex, 3)
    fixture.showPages(current: 0, neighbour: 2)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true }
    await owner.observePendingPresentationWork()
    XCTAssertTrue(allWeb(fixture.hosts[0]).contains { ObjectIdentifier($0) == identity })
    XCTAssertEqual((preparer.navigationDelegate as? DocumentWebCoordinator)?.payload?.pageIndex, 2)
    let renderer = try XCTUnwrap(preparer.navigationDelegate as? DocumentWebCoordinator)
    renderer.webViewWebContentProcessDidTerminate(preparer)
    try await wait(message: { fixture.diagnostics }) { fixture.resources.activeWebSurfaceCount == 1 }
    XCTAssertTrue(renderer.isInvalidated, "A dead idle executor does not restart without an unsatisfied page demand")
    XCTAssertTrue(fixture.paper(in: 0) === current)
    XCTAssertTrue((current.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[0]) == true)
  }

  func testSourceReplacementReleasesUnusablePicturesBeforePreparingNewSource() async throws {
    let text = (0..<32).map { "Paragraph \($0). " + String(repeating: "The document keeps its physical page through an edit. ", count: 12) }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Before\n\n" + text)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true }
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 1) && !fixture.hosts[1].hasSnapshot }
    fixture.retirePresentation(0)
    let owner = DocumentProgramOwner.shared(documentID: document.id, resources: fixture.resources)
    await owner.observePendingPresentationWork()
    let web = try XCTUnwrap(fixture.paper(in: 1))
    let oldPinnedBytes = fixture.resources.rasterAdmission.pinnedBytes
    XCTAssertGreaterThan(oldPinnedBytes, 0, "A real previously passive picture remains pinned by the document owner")

    fixture.replaceSource(blockID: "body", source: "# After!\n\n" + text)
    XCTAssertLessThan(fixture.resources.rasterAdmission.pinnedBytes, oldPinnedBytes,
      "Obsolete preparation pins must end synchronously at version replacement, before new source admission")
    XCTAssertTrue(fixture.paper(in: 1) === web, "Releasing preparation ownership cannot retire the installed native paper")
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 1) }
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testAcceptedDistantTargetPreemptsARealQueuedNeighbourWithoutRetiringCurrentPaper() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "# Current\n\n" + (0..<32).map { "Paragraph \($0). " + String(repeating: "A requested physical page precedes speculative work. ", count: 8) }.joined(separator: "\n\n")
      + "\n\n# Destination")])
    let resources = SceneRenderResources(maximumWebSurfaces: 2, reservedInteractiveSlots: 0)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let owner = DocumentProgramOwner.shared(documentID: document.id, resources: resources)
    let layout = try XCTUnwrap(DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document).layout)
    let target = try XCTUnwrap(layout.anchorPages["destination"])
    XCTAssertGreaterThan(target, 2)
    let current = WeakDocumentPaper(fixture.paper(in: 0))
    let identity = ObjectIdentifier(try XCTUnwrap(current.value))
    _ = try await XCTUnwrap(current.value).evaluateJavaScript("window.priorityDocument=document;window.priorityValue=47;true")
    // Hold a real second admitted WebKit. The passive owner must queue through
    // SceneRenderResources, rather than a manufactured renderer-ready callback.
    let blocker = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    let blockerHost = DocumentWebHost()
    fixture.window.rootViewController?.view.addSubview(blockerHost)
    blockerHost.frame = .init(x: 720, y: 0, width: 240, height: 340)
    let blockerDocument = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "blocker", source: "# Another active paper")])
    blocker.update(document: blockerDocument, state: .init(id: blockerDocument.id, actor: UUID()),
      selectedPageIndex: 0, capturesSnapshot: false, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    let geometry = WorkspaceItemGeometry.document(blockerDocument.paperSize)
    blocker.mount(in: blockerHost, physicalSize: .init(width: geometry.width, height: geometry.height),
      isInteractive: true, priority: .currentPage)
    defer { blocker.invalidate(); blockerHost.removeFromSuperview() }
    try await wait(message: { fixture.diagnostics }) { blocker.hasCanonicalPixels && resources.activeWebSurfaceCount == 2 }
    XCTAssertNotNil(blocker.webView)

    fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == 1 && resources.pendingWebRequestCount == 1 }
    fixture.activity.prepare(target)
    let acceptedID = try XCTUnwrap(fixture.activity.preparationDemand?.id)
    fixture.showPages(current: 0, neighbour: target)
    fixture.activity.prepare(target)
    XCTAssertEqual(fixture.activity.preparationDemand?.id, acceptedID)
    // This assertion runs before releasing the real blocker. The old owner
    // stays on page 1 until its deadline, exposing the causal scheduling defect.
    let priorityDeadline = ContinuousClock.now + .seconds(2)
    while owner.pendingPassivePageIndex != target, ContinuousClock.now < priorityDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(owner.pendingPassivePageIndex, target, "Accepted navigation must replace the queued neighbour before admission becomes available")
    guard owner.pendingPassivePageIndex == target else { return }
    XCTAssertEqual(resources.pendingWebRequestCount, 1, "Supersession removes the obsolete physical request")
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(current.value)), identity)
    XCTAssertTrue(fixture.canonicalPaper(in: 0))
    XCTAssertTrue((current.value?.navigationDelegate as? DocumentWebCoordinator)?.acceptsInput == true)

    fixture.activity.prepare(target - 1)
    fixture.showPages(current: 0, neighbour: target - 1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == target - 1 && resources.pendingWebRequestCount == 1 }
    XCTAssertNotEqual(fixture.activity.preparationDemand?.id, acceptedID)
    fixture.activity.prepare(nil)
    fixture.retirePresentation(1)
    try await wait(message: { fixture.diagnostics }) { resources.pendingWebRequestCount == 0 }
    XCTAssertEqual(resources.activeWebSurfaceCount, 2, "Cancelling a queued landing cannot evict either active paper")
    fixture.activity.prepare(target)
    fixture.showPages(current: 0, neighbour: target)
    fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == target && resources.pendingWebRequestCount == 1 }

    blocker.invalidate(); blockerHost.removeFromSuperview()
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.snapshot(in: 1) != nil }
    fixture.select(1); fixture.activity.prepare(nil)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 1))), identity)
    let retained = try await XCTUnwrap(current.value).evaluateJavaScript("priorityDocument===document && priorityValue===47")
    XCTAssertEqual(retained as? Bool, true)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    fixture.close()
    try await wait(message: { fixture.diagnostics }) { resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
  }

  func testCurrentCanonicalPaperAdmitsInputWithoutChangingItsRuntimeOrMeasurement() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "[Go to target](#target)\n\n# Target\n\nA current paper is prepared before its opening settles.")])
    let recorder = DocumentPresentationRecorder(enabled: true)
    _ = recorder.request(documentID: document.id, pageIndex: 0, cause: .open)
    let fixture = try ProgramFixture(document: document, measurements: recorder, interactive: false)
    defer { fixture.close() }
    var navigations = 0
    fixture.replaceLinkNavigation { _ in navigations += 1 }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && recorder.records.last?.contentReadyAt != nil }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let measurement = source.measurementCount
    let canonical = try await web.evaluateJavaScript("window.inputOwnerDocument=document; window.inputOwnerState={value:17}; JSON.stringify(notebookRenderer.pageReceipt())") as? String
    XCTAssertTrue(coordinator.hasCanonicalPixels)
    XCTAssertFalse(coordinator.acceptsInput)
    XCTAssertFalse(fixture.hosts[0].hasInteractiveSurface(web))
    XCTAssertTrue(try XCTUnwrap(web.superview).accessibilityElementsHidden)
    XCTAssertNil(recorder.records.last?.installedAt, "Canonical pixels alone cannot certify a first working page")
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    // A JS click is only a bridge-admission probe. Native hit routing below and
    // the separately required Simulator touch scenario prove different things.
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(navigations, 0)

    fixture.setInteractive(true)
    XCTAssertTrue(coordinator.acceptsInput)
    XCTAssertTrue(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    XCTAssertFalse(try XCTUnwrap(web.superview).accessibilityElementsHidden)
    try await fixture.assertPaperReceivesNativeHit(web)
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    try await wait(message: { fixture.diagnostics }) { navigations == 1 && recorder.records.last?.installedAt != nil }

    fixture.setInteractive(false)
    XCTAssertFalse(coordinator.acceptsInput)
    XCTAssertFalse(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    XCTAssertTrue(try XCTUnwrap(web.superview).accessibilityElementsHidden)
    fixture.setInteractive(true)
    XCTAssertTrue(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    try await wait(message: { fixture.diagnostics }) { navigations == 2 }
    XCTAssertTrue(fixture.paper(in: 0) === web)
    let retained = try await web.evaluateJavaScript("inputOwnerDocument===document && inputOwnerState.value===17")
    XCTAssertEqual(retained as? Bool, true)
    let after = try await web.evaluateJavaScript("JSON.stringify(notebookRenderer.pageReceipt())") as? String
    XCTAssertEqual(after, canonical)
    XCTAssertEqual(source.measurementCount, measurement)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testInputPolicyChangedDuringSourcePreparationReachesTheSamePaper() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Early opening\n\n[Target](#target)\n\n# Target")])
    let fixture = try ProgramFixture(document: document, interactive: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.paper(in: 0) != nil }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    XCTAssertFalse(coordinator.hasCanonicalPixels, "The policy changes during real initial preparation")
    let runtimeID = coordinator.payload?.runtimeID
    fixture.setInteractive(true)
    XCTAssertFalse(coordinator.acceptsInput, "The input request survives preparation but cannot admit a hit before installation")
    try await wait(message: { fixture.diagnostics }) { coordinator.nativeInputIsReady(in: fixture.hosts[0]) && fixture.ready[0] == true }
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertEqual(coordinator.payload?.runtimeID, runtimeID)
    XCTAssertEqual(coordinator.payload?.renderToken, fixture.currentToken)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    XCTAssertEqual(source.measurementCount, 1)
    try await fixture.assertPaperReceivesNativeHit(web)
  }

  func testDisablingNewNativeInputRejectsProgrammaticClickDuringAContact() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "[Target](#target)\n\n# Target")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var admittedCalls = 0, laterCalls = 0
    fixture.replaceLinkNavigation { _ in admittedCalls += 1 }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.paper(in: 0) != nil }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    // This is the native contact-observer delivery seam against a real loaded
    // paper; it does not synthesize a UITouch or claim a physical gesture test.
    fixture.hosts[0].onContactChange(true)
    fixture.setInteractive(false)
    fixture.replaceLinkNavigation { _ in laterCalls += 1 }
    XCTAssertFalse(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    try await fixture.assertPaperRejectsNativeHit(web)
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(admittedCalls, 0, "A programmatic click cannot spend an earlier user contact")
    XCTAssertEqual(laterCalls, 0)
    fixture.hosts[0].onContactChange(false)
    XCTAssertFalse(coordinator.acceptsInput)
    XCTAssertFalse(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    fixture.setInteractive(true)
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    try await wait(message: { fixture.diagnostics }) { laterCalls == 1 }
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertEqual(admittedCalls, 0)
  }

  func testAcceptedProgramStateDoesNotRevokeTheSameSourceInputWhilePaperEchoWaits() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "heading", source: "# A stable input owner"),
      .interactive(id: "counter", html: "<button>Increment</button><output>0</output>",
        javaScript: """
        document.querySelector('button').onclick=()=>{
          notebook.commit({count:(notebook.state.count||0)+1});
          document.querySelector('output').textContent=String(notebook.state.count);
        };
        """, initialState: .object(["count": .number(0)]), height: 90)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(block: "counter") != nil }
    let web = try XCTUnwrap(fixture.web(block: "counter")), paper = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(paper.navigationDelegate as? DocumentWebCoordinator)
    let oldToken = try XCTUnwrap(coordinator.payload?.renderToken)
    // Hold the existing page owner, so the real JS state receipt reaches the
    // input projection before the asynchronous paper echo can catch up.
    fixture.activity.update(true)
    defer { fixture.activity.update(false) }
    _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("counter", field: "count") == 1 }
    XCTAssertNotEqual(fixture.currentToken, oldToken)
    XCTAssertEqual(coordinator.payload?.renderToken, oldToken)
    XCTAssertTrue(coordinator.acceptsInput)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    let rawRect = try await web.evaluateJavaScript("(()=>{const r=document.querySelector('button').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
    let rect = try XCTUnwrap(rawRect as? [Double])
    XCTAssertEqual(rect.count, 2)
    let hit = fixture.window.hitTest(web.convert(.init(x: rect[0], y: rect[1]), to: fixture.window), with: nil)
    XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true,
      "The actual retained program must keep native hit admission after its own state commit")
    _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("counter", field: "count") == 2 }
    XCTAssertTrue(fixture.web(block: "counter") === web)
  }

  func testRetiredOutgoingPageTransfersItsActualPaperToThePreparedDistantPage() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "[Far chapter](#far)\n\n" + (0..<35).map { "Paragraph \($0). " + String(repeating: "A physical page transfer preserves the installed WebKit. ", count: 8) }.joined(separator: "\n\n")
      + "\n\n# Far\n\n[Return](#body)")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var phase = "initial"
    defer {
      let attachment = XCTAttachment(string: "phase=\(phase) \(fixture.diagnostics)\n" + DocumentProgramOwner.presentationDiagnostic(documentID: document.id, resources: fixture.resources))
      attachment.name = "paper-transfer-final-owner"; attachment.lifetime = .keepAlways; add(attachment)
    }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled }
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let destination = try XCTUnwrap(source.layout?.anchorPages["far"])
    XCTAssertGreaterThan(destination, 1)
    fixture.showPages(current: 0, neighbour: destination)
    phase = "distant-preparation"
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.snapshot(in: 1) != nil }
    let originalPaper = WeakDocumentPaper(fixture.paper(in: 0))
    let originalIdentity = ObjectIdentifier(try XCTUnwrap(originalPaper.value))
    phase = "mark-original-runtime"
    let originalReceipt = try await XCTUnwrap(originalPaper.value).evaluateJavaScript("window.handoffDocument=document; window.handoffState={value:17}; notebookRenderer.pageReceipt()") as? [String: Any]
    // UIKit can dismantle a distant outgoing page before the replacement
    // current-page input reaches its surviving, already prepared controller.
    fixture.retirePresentation(0)
    fixture.select(1)
    phase = "retired-outgoing-awaiting-distant"
    XCTAssertNotNil(originalPaper.value, "The owner must retain the actual runtime between native hosts; the test keeps only a weak reference")
    // A passive snapshot's ready flag survives the mount. Read this retained
    // runtime only after its own canonical frame is installed above the fallback.
    try await wait(message: { fixture.diagnostics }) {
      guard let web = fixture.paper(in: 1), let renderer = web.navigationDelegate as? DocumentWebCoordinator else { return false }
      return fixture.ready[1] == true && fixture.canonicalPaper(in: 1)
        && !fixture.hosts[1].hasSnapshot && renderer.nativeInputIsReady(in: fixture.hosts[1])
    }
    let incoming = try XCTUnwrap(fixture.paper(in: 1))
    phase = "reading-installed-distant"
    XCTAssertEqual(ObjectIdentifier(incoming), originalIdentity)
    let retained = try await incoming.evaluateJavaScript("handoffDocument===document && handoffState.value===17")
    XCTAssertEqual(retained as? Bool, true)
    let receipt = try await incoming.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(receipt?["pageIndex"] as? Int, destination)
    XCTAssertEqual(receipt?["presentationKind"] as? String, "canonical")
    XCTAssertEqual(receipt?["renderToken"] as? String, fixture.currentToken)
    XCTAssertEqual(receipt?["runtimeID"] as? String, originalReceipt?["runtimeID"] as? String)
    XCTAssertEqual(receipt?["sourceKey"] as? String, originalReceipt?["sourceKey"] as? String)
    XCTAssertEqual(receipt?["stateKey"] as? String, originalReceipt?["stateKey"] as? String)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    let distantImage = XCTAttachment(image: try fixture.windowImage())
    distantImage.name = "paper-transfer-distant-same-runtime"; distantImage.lifetime = .keepAlways; add(distantImage)
    fixture.restorePresentation(0)
    fixture.select(0)
    phase = "returning-to-first"
    try await wait(message: { fixture.diagnostics }) {
      guard let web = fixture.paper(in: 0), let renderer = web.navigationDelegate as? DocumentWebCoordinator else { return false }
      return fixture.ready[0] == true && fixture.canonicalPaper(in: 0)
        && !fixture.hosts[0].hasSnapshot && renderer.nativeInputIsReady(in: fixture.hosts[0])
    }
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 0))), originalIdentity)
    let returned = try await incoming.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(returned?["pageIndex"] as? Int, 0)
    XCTAssertEqual(returned?["renderToken"] as? String, fixture.currentToken)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    let returnImage = XCTAttachment(image: try fixture.windowImage())
    returnImage.name = "paper-transfer-return-same-runtime"; returnImage.lifetime = .keepAlways; add(returnImage)
    phase = "completed"
  }

  func testDelayedIncomingCurrentPageKeepsOpenDocumentRuntimeUntilExplicitClose() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "[Far](#far)\n\n" + (0..<24).map { "Paragraph \($0). " + String(repeating: "The open document owns this runtime through a delayed physical handoff. ", count: 6) }.joined(separator: "\n\n")
      + "\n\n# Far\n\n[Return](#body)")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var phase = "initial_ready", caughtError = "none"
    defer {
      let proof = XCTAttachment(string: "phase=\(phase) error=\(caughtError)\n\(fixture.diagnostics)\n" +
        DocumentProgramOwner.presentationDiagnostic(documentID: document.id, resources: fixture.resources))
      proof.name = "delayed-current-gap-boundary"; proof.lifetime = .keepAlways; add(proof)
    }
    do {
      try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled }
      phase = "resolve_measured_target"
      let destination = try XCTUnwrap(DocumentRenderRegistry.shared.session(documentID: document.id,
        resources: fixture.resources).source(document).layout?.anchorPages["far"])
      XCTAssertGreaterThan(destination, 1)
      phase = "prepare_passive_target"
      fixture.showPages(current: 0, neighbour: destination)
      try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.snapshot(in: 1) != nil }
      let original = WeakDocumentPaper(fixture.paper(in: 0))
      let identity = ObjectIdentifier(try XCTUnwrap(original.value))
      phase = "read_original_javascript_receipt"
      let originalRaw = try await XCTUnwrap(original.value).evaluateJavaScript(
        "window.delayedHandoffDocument=document; window.delayedHandoffValue=29; notebookRenderer.pageReceipt()")
      let receipt = try XCTUnwrap(originalRaw as? [String: Any])
      let runtimeID = try XCTUnwrap(receipt["runtimeID"] as? String)
      let sourceKey = try XCTUnwrap(receipt["sourceKey"] as? String)
      XCTAssertFalse(runtimeID.isEmpty); XCTAssertFalse(sourceKey.isEmpty)
      let owner = DocumentProgramOwner.shared(documentID: document.id, resources: fixture.resources)

      phase = "retire_original_presentation"
      fixture.retirePresentation(0)
      // The incoming native host is real and already has its passive pixels.
      // Let the existing owner task actually finish before SwiftUI supplies its
      // new isCurrent input. No ready callback or elapsed-time substitute is used.
      phase = "yield_before_existing_work_drain"
      await Task.yield()
      phase = "drain_existing_presentation_work"
      await owner.observePendingPresentationWork()
      phase = "assert_original_after_drain"
      XCTAssertNotNil(original.value, "A gap in physical current-page publication must not close the open document runtime")
      phase = "select_prepared_target"
      fixture.select(1)
      try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.hosts[1].isUserInteractionEnabled && fixture.paper(in: 1) != nil }
      XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 1))), identity)
      // The earlier passive picture may still have a true readiness callback.
      // Keep the identity assertion above; only read JavaScript after the actual
      // installed paper has accepted this page's canonical frame.
      phase = "await_actual_canonical_target"
      try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 1) }
      XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 1))), identity)
      phase = "read_returned_javascript_receipt"
      let returnedRaw = try await XCTUnwrap(fixture.paper(in: 1)).evaluateJavaScript("notebookRenderer.pageReceipt()")
      let returned = try XCTUnwrap(returnedRaw as? [String: Any])
      XCTAssertEqual(try XCTUnwrap(returned["runtimeID"] as? String), runtimeID)
      XCTAssertEqual(try XCTUnwrap(returned["sourceKey"] as? String), sourceKey)
      phase = "read_preserved_javascript_marker"
      let preserved = try await XCTUnwrap(fixture.paper(in: 1)).evaluateJavaScript(
        "window.delayedHandoffDocument===document && window.delayedHandoffValue===29")
      XCTAssertEqual(preserved as? Bool, true)
      XCTAssertEqual(DocumentRenderRegistry.shared.session(documentID: document.id,
        resources: fixture.resources).source(document).measurementCount, 1)

      phase = "explicit_close"
      fixture.close()
      try await wait(message: { fixture.diagnostics }) {
        original.value == nil && fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.pendingWebRequestCount == 0
      }
      XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
      phase = "complete"
    } catch {
      let native = error as NSError
      caughtError = "type=\(String(reflecting: type(of: error))) domain=\(native.domain) code=\(native.code) description=\(String(describing: error))"
      throw error
    }
  }

  func testClosingFullPresentationRetiresPaperWhileThumbnailKeepsItsPicture() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "# One open document\n\nA remaining thumbnail owns its picture, not the closed document runtime.")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    fixture.showPages(current: 0, neighbour: 0)
    fixture.setThumbnail(1)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 0) && fixture.ready[1] == true && fixture.snapshot(in: 1) != nil
    }
    let original = WeakDocumentPaper(fixture.paper(in: 0))
    XCTAssertNotNil(original.value)
    let owner = DocumentProgramOwner.shared(documentID: document.id, resources: fixture.resources)
    fixture.retirePresentation(0)
    await Task.yield()
    await owner.observePendingPresentationWork()
    try await wait(message: { fixture.diagnostics }) {
      original.value == nil && fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.pendingWebRequestCount == 0
    }
    XCTAssertNotNil(fixture.snapshot(in: 1), "Closing the document must preserve the separately owned thumbnail picture")
    fixture.close()
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
  }

  func testClosingDuringPaperTransferRetiresTheRuntimeAndItsAdmission() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# A current paper\n\nIts owner may close before the next host is selected.")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.paper(in: 0) != nil }
    let runtime = WeakDocumentPaper(fixture.paper(in: 0))
    fixture.retirePresentation(0)
    XCTAssertNotNil(runtime.value, "The current runtime is parked until the owner resolves its handoff")
    fixture.close()
    try await wait(message: { fixture.diagnostics }) {
      runtime.value == nil && fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.pendingWebRequestCount == 0
    }
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
  }

  func testNativeFailureDuringPaperTransferRetiresOnlyItsParkedRuntimeAndAdmission() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# A ready paper\n\nA terminal event can arrive before its replacement host is current.")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.paper(in: 0) != nil }
    let runtime = WeakDocumentPaper(fixture.paper(in: 0))
    fixture.activity.update(true)
    fixture.retirePresentation(0)
    XCTAssertNotNil(runtime.value)
    try await wait(message: { fixture.diagnostics }) {
      runtime.value != nil && fixture.resources.activeWebSurfaceCount == 1 && fixture.resources.pendingWebRequestCount == 0
    }
    // Public navigation-delegate failure against the real prepared WK. This
    // deterministic lifecycle seam does not claim an actual OS process crash.
    if let web = runtime.value {
      let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
      coordinator.webView(web, didFail: nil,
        withError: NSError(domain: "DocumentPaperTransferContract", code: 1))
    }
    try await wait(message: { fixture.diagnostics }) {
      runtime.value == nil && fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.pendingWebRequestCount == 0
    }
  }

  func testMeasuredLayoutUpdatesLinkCallbackWithoutReloadingTheCanonicalPaper() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      "[Far chapter](#far)\n\n" + (0..<45).map { "Paragraph \($0). " + String(repeating: "A stable physical page keeps its current navigation callback. ", count: 8) }.joined(separator: "\n\n")
      + "\n\n# Far\n\nDestination")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var initialCalls = 0, acceptedPage: Int?
    let initialPageCount = 1
    fixture.replaceLinkNavigation { destination in
      initialCalls += 1
      if case .page(let page) = destination, page >= 0, page < initialPageCount { acceptedPage = page }
    }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled }
    let paper = try XCTUnwrap(fixture.paper(in: 0))
    let before = try await paper.evaluateJavaScript("window.callbackTestDocument=document; JSON.stringify(notebookRenderer.pageReceipt())")
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let measuredCount = try XCTUnwrap(source.layout?.pageCount)
    XCTAssertGreaterThan(measuredCount, 1)
    _ = try await paper.evaluateJavaScript("document.querySelector('a[href=\"#far\"]').click(); true")
    try await wait(message: { fixture.diagnostics }) { initialCalls == 1 }
    XCTAssertNil(acceptedPage, "The initial one-page closure rejects the later measured destination")
    fixture.replaceLinkNavigation { destination in
      if case .page(let page) = destination, page >= 0, page < measuredCount { acceptedPage = page }
    }
    _ = try await paper.evaluateJavaScript("document.querySelector('a[href=\"#far\"]').click(); true")
    try await wait(message: { fixture.diagnostics }) { acceptedPage != nil }
    XCTAssertEqual(initialCalls, 1, "The old captured layout callback is retired by the same-entry update")
    XCTAssertGreaterThan(try XCTUnwrap(acceptedPage), 0)
    XCTAssertTrue(fixture.paper(in: 0) === paper)
    let sameDocument = try await paper.evaluateJavaScript("callbackTestDocument===document")
    XCTAssertEqual(sameDocument as? Bool, true)
    let after = try await paper.evaluateJavaScript("JSON.stringify(notebookRenderer.pageReceipt())")
    XCTAssertEqual(after as? String, before as? String, "Callback refresh cannot change the frame generation, source or canonical receipt")
  }

  func testLoadingCaptionUsesItsTextWidthAndWrapsWithinThePhysicalPage() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController(), host = DocumentWebHost()
    window.rootViewController = controller; controller.view.backgroundColor = .systemGray6
    controller.view.addSubview(host); window.makeKeyAndVisible()
    defer { host.removeLoading(); window.isHidden = true; window.rootViewController = nil }
    host.showLoading()
    let stack = try XCTUnwrap(host.subviews.compactMap { $0 as? UIStackView }.first)
    let label = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? UILabel }.first)
    let spinner = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? UIActivityIndicatorView }.first)
    for width in [CGFloat(320), CGFloat(120)] {
      host.frame = .init(x: 24, y: 24, width: width, height: 300)
      controller.view.layoutIfNeeded(); host.layoutIfNeeded()
      let textSize = label.sizeThatFits(.init(width: width - 24, height: .greatestFiniteMagnitude))
      XCTAssertEqual(label.text, "Подготовка страницы…")
      XCTAssertGreaterThan(label.bounds.width, spinner.bounds.width,
        "The spinner's intrinsic width cannot constrain the full caption")
      XCTAssertGreaterThanOrEqual(label.bounds.width + 1, textSize.width)
      XCTAssertGreaterThanOrEqual(label.bounds.height + 1, textSize.height)
      let labelFrame = label.convert(label.bounds, to: host)
      XCTAssertGreaterThanOrEqual(labelFrame.minX, 12 - 1)
      XCTAssertLessThanOrEqual(labelFrame.maxX, host.bounds.width - 12 + 1)
      XCTAssertFalse(stack.hasAmbiguousLayout)
      if width == 120 { XCTAssertGreaterThan(label.bounds.height, label.font.lineHeight) }
      var drawn = false
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      XCTAssertTrue(drawn)
      let attachment = XCTAttachment(image: image)
      attachment.name = "loading-caption-physical-width-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
    }
  }

  func testCurrentPagePreparationMetadataComesFromItsActualWebKitGeneration() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Observed document\n\nA real canonical page.")])
    let recorder = DocumentPresentationRecorder(enabled: true)
    let request = try XCTUnwrap(recorder.request(documentID: document.id, pageIndex: 0, cause: .open))
    let fixture = try ProgramFixture(document: document, measurements: recorder)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { recorder.records.last?.installedAt != nil }
    let record = try XCTUnwrap(recorder.records.last), identity = try XCTUnwrap(record.pagePreparationIdentity)
    XCTAssertEqual(identity.requestID, request)
    XCTAssertEqual(identity.token, fixture.currentToken)
    XCTAssertEqual(identity.documentID, document.id)
    let phases = try XCTUnwrap(record.pagePreparationPhasesMS)
    for stage in ["payloadConfiguredAt", "mountAt", "admissionRequestedAt", "admittedAt", "frameTaskAt",
      "preparedPageStartAt", "preparedPageReadyAt", "pageSourceEncodedAt", "stateEncodedAt", "frameEncodedAt",
      "frameEvaluationStartAt", "renderStartedAt", "renderedAt", "pageReceiptRequestedAt", "pageReceiptReturnedAt", "layoutReceiptAcceptedAt", "canonicalReadyAt"] {
      XCTAssertNotNil(phases[stage], stage)
    }
    XCTAssertTrue(phases["shellNavigationFinishedAt"] != nil || phases["shellReadyMessageAt"] != nil)
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["admittedAt"]), try XCTUnwrap(phases["preparedPageStartAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["preparedPageReadyAt"]), try XCTUnwrap(phases["frameEvaluationStartAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["pageReceiptRequestedAt"]), try XCTUnwrap(phases["pageReceiptReturnedAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["pageReceiptReturnedAt"]), try XCTUnwrap(phases["layoutReceiptAcceptedAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["layoutReceiptAcceptedAt"]), try XCTUnwrap(phases["canonicalReadyAt"]))
    XCTAssertLessThanOrEqual(identity.configuredAt + (try XCTUnwrap(phases["canonicalReadyAt"])) / 1_000,
      try XCTUnwrap(record.contentReadyAt))
    let receipt = try await XCTUnwrap(fixture.paper(in: 0)).evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(receipt?["generation"] as? String, identity.generation)
    XCTAssertEqual(receipt?["renderToken"] as? String, identity.token)
  }

  func testTallProgramHasOneContextAcrossPassivePagesCurlAndIndexReclamation() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program",
      html: "<button id='increment'>Add one</button><output id='value'></output><div style='height:1550px;background:linear-gradient(#cdeeff,#ffe1d5)'></div><button id='increment-last'>Add one</button>",
      css: "button{font-size:24px}output{display:block;font-size:24px}", javaScript: """
      const nonce=crypto.randomUUID();let count=notebook.state.count||0,ticks=0;
      const report=()=>{document.querySelector('#value').textContent=String(count);notebook.commit({...notebook.state,nonce,count,ticks});};
      document.querySelectorAll('button').forEach(button=>button.onclick=()=>{count++;report();});
      addEventListener('message',event=>{if(event.data==='increment'){count++;report();}if(event.data==='probe')report();});
      setInterval(()=>{ticks++;},40);
      notebook.commit({...notebook.state,nonce,count,mounts:(notebook.state.mounts||0)+1});
      """, initialState: .object(["count": .number(0)]), height: 2048)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.web(in: 0) != nil }
    let web = try XCTUnwrap(fixture.web(in: 0))
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
    let nonce = try XCTUnwrap(fixture.value("program")?["nonce"])
    XCTAssertEqual(fixture.value("program")?["mounts"], .number(1))
    _ = try await web.evaluateJavaScript("window.originalProgram=document;true")
    try await fixture.message("increment", in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["count"] == .number(1) }
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) { fixture.web(in: 1) === web && fixture.ready[1] == true && fixture.hosts[1].isUserInteractionEnabled }
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
    let same = try await web.evaluateJavaScript("originalProgram===document")
    XCTAssertEqual(same as? Bool, true)
    XCTAssertEqual(fixture.value("program")?["nonce"], nonce)
    XCTAssertEqual(fixture.value("program")?["mounts"], .number(1))
    try await fixture.message("probe", in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.number("program", field: "ticks") > 0 }
    let physicalPage = UIGraphicsImageRenderer(bounds: fixture.hosts[1].bounds).image { _ in
      fixture.hosts[1].drawHierarchy(in: fixture.hosts[1].bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: physicalPage)
    attachment.name = "single-program-second-physical-cut"; attachment.lifetime = .keepAlways; add(attachment)

    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    await source.discardIdlePreparation()
    try await wait(message: { fixture.diagnostics }) { fixture.hosts[1].isUserInteractionEnabled && fixture.ready[1] == true }
    fixture.activity.update(true)
    fixture.select(0)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(fixture.web(in: 1) === web, "An accepted native curl keeps the exact runtime at its previous host until completion")
    let lockedPage = try await XCTUnwrap(fixture.paper(in: 1)).evaluateJavaScript("notebookRenderer.pageReceipt().pageIndex")
    XCTAssertEqual(lockedPage as? Int, 1)
    fixture.activity.update(false)
    try await wait(message: { fixture.diagnostics }) { fixture.web(in: 0) === web && fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.web(in: 0) != nil }
    try await fixture.message("increment", in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["count"] == .number(2) }
    let survived = try await web.evaluateJavaScript("originalProgram===document")
    XCTAssertEqual(survived as? Bool, true, "Reclaiming the inert index cannot recreate a program")
    XCTAssertEqual(fixture.value("program")?["mounts"], .number(1))
    XCTAssertEqual(fixture.value("program")?["nonce"], nonce)
  }

  func testNeverReadyNeighborDoesNotSwitchOrDisableTheCurrentProgram() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .interactive(id: "current", html: "<button>Ready control</button>", css: "", javaScript: "notebook.commit({started:true})", initialState: .null, height: 1400),
      .interactive(id: "delayed", html: "<button>Waiting control</button>", css: "", javaScript: "notebook.ready(new Promise(()=>{}))", initialState: .null, height: 200)
    ])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(in: 0) != nil }
    let web = try XCTUnwrap(fixture.web(in: 0))
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(fixture.ready[0], true)
    XCTAssertNotEqual(fixture.ready[1], true)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertTrue(fixture.web(in: 0) === web)
    let page = try await XCTUnwrap(fixture.paper(in: 0)).evaluateJavaScript("notebookRenderer.pageReceipt().pageIndex")
    XCTAssertEqual(page as? Int, 0)
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
  }

  func testLeavingTheProgramWindowCheckpointsStateBeforeRetirementAndRestoresItsIdentity() async throws {
    let program: (String) -> DocumentBlock = { id in
      .interactive(id: id, html: "<button>Count</button>", css: "", javaScript: """
      let count=notebook.state.count||0;const nonce=crypto.randomUUID();
      notebook.commit({...notebook.state,count,nonce,mounts:(notebook.state.mounts||0)+1});
      addEventListener('message',event=>{if(event.data==='increment')notebook.commit({...notebook.state,count:++count});});
      """, initialState: .object(["count": .number(0)]), height: 2000)
    }
    let document = DocumentDocument(actor: UUID(), blocks: [program("program"), program("middle"), program("last")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.web(in: 0) != nil }
    let web = try XCTUnwrap(fixture.web(in: 0))
    let firstNonce = try XCTUnwrap(fixture.value("program")?["nonce"])
    try await fixture.message("increment", in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["count"] == .number(1) }
    fixture.showPages(current: 4, neighbour: 3)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.checkpoints.contains("program") }
    let retirementDeadline = ContinuousClock.now + .seconds(5)
    var exists = true
    repeat {
      exists = web.superview != nil
      if exists { try await Task.sleep(for: .milliseconds(10)) }
    } while exists && ContinuousClock.now < retirementDeadline
    XCTAssertFalse(exists, "A program outside the physical working window retires only after its accepted explicit state is checkpointed")
    fixture.showPages(current: 0, neighbour: 1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.value("program")?["mounts"] == .number(2) }
    XCTAssertTrue(fixture.web(in: 0) !== web, "Retired explicit state creates one replacement context on return")
    XCTAssertEqual(fixture.value("program")?["count"], .number(1))
    XCTAssertNotEqual(fixture.value("program")?["nonce"], firstNonce)
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
  }

  func testAnOpenSourceEditorKeepsItsDOMWhilePassiveWorkAndCameraSizeChange() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      (0..<60).map { "Paragraph \($0). " + String(repeating: "The editor owns this accepted draft. ", count: 10) }.joined(separator: "\n\n"))])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.hosts[0].isUserInteractionEnabled }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    _ = try await web.evaluateJavaScript("""
      document.querySelector('#document .editable').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
      window.originalEditor=document.querySelector('textarea');originalEditor.value='An accepted unfinished draft';
      originalEditor.dispatchEvent(new Event('input',{bubbles:true}));true
      """)
    fixture.hosts[0].frame.size.width += 0.15
    fixture.hosts[0].setNeedsLayout(); fixture.hosts[0].layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    let survived = try await web.evaluateJavaScript("originalEditor===document.querySelector('textarea')&&originalEditor.value==='An accepted unfinished draft'")
    XCTAssertEqual(survived as? Bool, true)
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
  }

  func testAttentionCapturesLivePixelsEvenWhenProgramChangesWithoutAStateCommit() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program",
      html: "<div id='swatch' style='height:200px;background:#ff0000'></div>", css: "",
      javaScript: "addEventListener('message',event=>{if(event.data==='blue'){document.querySelector('#swatch').style.background='#0000ff';requestAnimationFrame(()=>window.postMessage('blue-ready','*'));}});",
      initialState: .null, height: 200)])
    let fixture = try ProgramFixture(document: document)
    fixture.showPages(current: 0, neighbour: 0)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.web(in: 0) != nil }
    let web = try XCTUnwrap(fixture.web(in: 0))
    let before = try await fixture.captureCurrent()
    defer { before.release() }
    let token = before.source
    _ = try await web.callAsyncJavaScript("""
      await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(new Error('Program did not repaint')),2000);
        const painted=event=>{if(event.data==='blue-ready'){removeEventListener('message',painted);clearTimeout(timer);resolve();}};
        addEventListener('message',painted);window.postMessage('blue','*');
      });await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));return true;
      """,
      arguments: [:], in: nil, contentWorld: .page)
    fixture.hosts[0].frame.size.width /= 2; fixture.hosts[0].frame.size.height /= 2
    fixture.hosts[0].setNeedsLayout(); fixture.hosts[0].layoutIfNeeded()
    let after = try await fixture.captureCurrent()
    defer { after.release() }
    XCTAssertEqual(after.source, token, "Source and explicit state remain identical while the program changes its pixels")
    XCTAssertNotEqual(after.entryID, before.entryID)
    XCTAssertNotEqual(after.image.pngData(), before.image.pngData(), "Attention cannot return the previous cache entry for a live frame")
    XCTAssertLessThan(try XCTUnwrap(after.image.cgImage).width, try XCTUnwrap(before.image.cgImage).width,
      "An older higher-density cache entry cannot replace the lower-density frame just captured")
    XCTAssertGreaterThan(try bluePixels(after.image), 100)
    XCTAssertEqual(try bluePixels(before.image), 0)
    let attachment = XCTAttachment(image: after.image)
    attachment.name = "document-attention-current-blue-program"; attachment.lifetime = .keepAlways; add(attachment)
    let physical = WorkspaceItemGeometry.document(document.paperSize)
    let frozen = try XCTUnwrap(DocumentProgramOwner.capturePresented(documentID: document.id, pageIndex: 0,
      token: fixture.currentToken, region: .init(x: 0, y: 0, width: physical.width, height: physical.height), resources: fixture.resources))
    _ = try await web.evaluateJavaScript("document.querySelector('#swatch').style.background='#ff0000';true")
    let encodedLater = try await frozen.png()
    XCTAssertGreaterThan(try bluePixels(try XCTUnwrap(UIImage(data: encodedLater))), 100,
      "Encoding after a later DOM change retains the blue native frame frozen synchronously before that change")
    let wrongPage = try await DocumentProgramOwner.captureCurrent(documentID: document.id, pageIndex: 1,
      token: fixture.currentToken, resources: fixture.resources)
    XCTAssertNil(wrongPage)
    let wrongVersion = try await DocumentProgramOwner.captureCurrent(documentID: document.id, pageIndex: 0,
      token: "previous-source", resources: fixture.resources)
    XCTAssertNil(wrongVersion)
    fixture.hosts[0].removeFromSuperview()
    let detached = try await DocumentProgramOwner.captureCurrent(documentID: document.id, pageIndex: 0,
      token: fixture.currentToken, resources: fixture.resources)
    XCTAssertNil(detached)
  }

  func testRuntimeRecoveryUsesAcceptedStateWhileInputWasHoldingBackTheEcho() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program",
      html: "<input aria-label='Value'><button>Increment</button>", css: "", javaScript: """
      notebook.commit({...notebook.state,mounts:(notebook.state.mounts||0)+1});
      addEventListener('message',event=>{
        if(event.data==='focus'){document.querySelector('input').focus();notebook.commit({...notebook.state,focused:true});}
        if(event.data==='increment')notebook.commit({...notebook.state,count:(notebook.state.count||0)+1});
      });
      """, initialState: .object(["count": .number(0)]), height: 2000)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.hosts[0].isUserInteractionEnabled }
    let original = try XCTUnwrap(fixture.web(in: 0))
    try await fixture.message("focus", in: original)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["focused"] == .bool(true) }
    try await fixture.message("increment", in: original)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["count"] == .number(1) }
    original.navigationDelegate?.webViewWebContentProcessDidTerminate?(original)
    try await wait(message: { fixture.diagnostics }) { fixture.web(in: 0) != nil && fixture.web(in: 0) !== original
      && fixture.value("program")?["mounts"] == .number(2) && fixture.hosts[0].isUserInteractionEnabled }
    XCTAssertEqual(fixture.value("program")?["count"], .number(1))
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
  }

  func testStationaryPassivePageRefinesAfterSharedPressureIsReleased() async throws {
    let resources = SceneRenderResources(byteLimit: 24 * 1024 * 1024)
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(8 * 1024 * 1024, priority: .passive))
    defer { pressure.release() }
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source:
      (0..<50).map { "Paragraph \($0). " + String(repeating: "The stationary physical page remains readable. ", count: 8) }.joined(separator: "\n\n"))])
    let fixture = try ProgramFixture(document: document, resources: resources)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true }
    let lowWidth = try XCTUnwrap(fixture.snapshot(in: 1)?.cgImage).width
    let wanted = Int(ceil(fixture.hosts[1].bounds.width * (fixture.hosts[1].window?.screen.scale ?? 2)))
    XCTAssertLessThan(lowWidth, wanted, "The initial image is admitted at the quality available beside real shared pressure")
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    pressure.release()
    try await wait(message: { fixture.diagnostics }) { (fixture.snapshot(in: 1)?.cgImage?.width ?? 0) >= wanted }
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    let attachment = XCTAttachment(image: try XCTUnwrap(fixture.snapshot(in: 1)))
    attachment.name = "stationary-document-refined-after-admission"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testNineProgramsHaveFiniteAdmissionAndExplicitActivationPreservesAcceptedState() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: (0..<9).map { index in
      .interactive(id: "program-\(index)", html: "<button id='increment'>Increment \(index)</button><output id='value'></output>",
        css: "button{font-size:20px}output{padding:8px}", javaScript: """
        const render=()=>document.querySelector('#value').textContent=String(notebook.state.count||0);
        document.querySelector('button').onclick=()=>{notebook.commit({...notebook.state,count:(notebook.state.count||0)+1});render()};
        notebook.commit({...notebook.state,mounts:(notebook.state.mounts||0)+1});render();
        """, initialState: .object(["count": .number(0)]), height: 90)
    })
    let fixture = try ProgramFixture(document: document)
    fixture.showPages(current: 0, neighbour: 0)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) {
      (0..<9).allSatisfy { fixture.value("program-\($0)") != nil }
        && fixture.checkpoints.count >= 6 && fixture.resources.pendingWebRequestCount == 0
        && fixture.resources.activeWebSurfaceCount <= 4 && fixture.resources.activeBackgroundWebSurfaceCount == 0
    }
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4,
      "Three automatic controls and paper leave room for source preparation and deliberate input")
    let first = try XCTUnwrap(fixture.web(block: "program-0"))
    XCTAssertTrue(first.isUserInteractionEnabled)
    XCTAssertNil(fixture.web(block: "program-8"), "The ninth program has exact passive pixels, not a hidden live runtime")
    fixture.start(block: "program-8")
    try await wait(message: { fixture.diagnostics }) { fixture.web(block: "program-8")?.isUserInteractionEnabled == true }
    let eighth = try XCTUnwrap(fixture.web(block: "program-8"))
    _ = try await eighth.evaluateJavaScript("document.querySelector('button').click();document.body.style.background='rgb(0,0,255)';true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("program-8", field: "count") == 1 }
    fixture.start(block: "program-7")
    try await wait(message: { fixture.diagnostics }) {
      fixture.web(block: "program-7")?.isUserInteractionEnabled == true && eighth.superview == nil
        && fixture.checkpointValues["program-8"]?["count"] == .number(1)
    }
    XCTAssertTrue(fixture.web(block: "program-0") === first, "Activating one paused source cannot restart neighboring ready controls")
    XCTAssertEqual(fixture.number("program-8", field: "count"), 1)
    XCTAssertTrue(fixture.checkpoints.contains("program-8"))
    let paused = UIGraphicsImageRenderer(bounds: fixture.hosts[0].bounds).image { _ in
      fixture.hosts[0].drawHierarchy(in: fixture.hosts[0].bounds, afterScreenUpdates: true)
    }
    XCTAssertGreaterThan(try bluePixels(paused), 100,
      "Demotion freezes the program's current DOM pixels, including changes with no state commit")
    let pausedAttachment = XCTAttachment(image: paused)
    pausedAttachment.name = "nine-programs-current-dom-preserved-in-paused-block"
    pausedAttachment.lifetime = .keepAlways; add(pausedAttachment)
    fixture.start(block: "program-8")
    try await wait(message: { fixture.diagnostics }) { fixture.web(block: "program-8")?.isUserInteractionEnabled == true }
    XCTAssertEqual(fixture.number("program-8", field: "count"), 1)
    XCTAssertTrue(fixture.web(block: "program-8") !== eighth, "A deliberate restart restores the checkpointed explicit state")
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, fixture.resources.maximumWebSurfaces)
    let image = UIGraphicsImageRenderer(bounds: fixture.hosts[0].bounds).image { _ in
      fixture.hosts[0].drawHierarchy(in: fixture.hosts[0].bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "nine-programs-live-and-paused-after-activation"; attachment.lifetime = .keepAlways; add(attachment)
    func images(_ view: UIView) -> [UIImageView] {
      (view as? UIImageView).map { [$0] } ?? view.subviews.flatMap(images)
    }
    let retainedNativeImages = fixture.hosts.flatMap(images)
    XCTAssertFalse(retainedNativeImages.isEmpty)
    let originalImageOwners = Dictionary(uniqueKeysWithValues: retainedNativeImages.map { image in
      var view: UIView? = image
      var ancestry: [String] = []
      while let current = view { ancestry.append(String(describing: type(of: current))); view = current.superview }
      return (ObjectIdentifier(image), ancestry.joined(separator: " → "))
    })
    // The native hierarchy also contains UIKit's cached 20x20 spinner glyphs.
    // Those are not document/source rasters and do not own a raster lease.
    // Identify the actual UIKit owner before detachment, not by image size.
    let indicatorImages = Set(retainedNativeImages.compactMap { image -> ObjectIdentifier? in
      var ancestor = image.superview
      while let view = ancestor {
        if view is UIActivityIndicatorView { return ObjectIdentifier(image) }
        ancestor = view.superview
      }
      return nil
    })
    let documentImages = retainedNativeImages.filter { !indicatorImages.contains(ObjectIdentifier($0)) }
    XCTAssertTrue(documentImages.contains { $0.image != nil },
      "The test must retain actual installed document pictures through native retirement")
    fixture.close()
    try await wait(message: { fixture.diagnostics }) {
      fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.rasterAdmission.pinnedBytes == 0
    }
    let remaining = documentImages.filter { $0.image != nil }.map {
      "\(type(of: $0)) frame=\($0.frame) pixels=\(String(describing: $0.image?.size)) parent=\(String(describing: $0.superview)) original=\(originalImageOwners[ObjectIdentifier($0)] ?? "unknown")"
    }
    XCTAssertTrue(remaining.isEmpty,
      "Departed hosts and image views may outlive the document; native retirement must still release their pixels: \(remaining)")
  }

  private func wait(message: () -> String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The exact physical presentation did not become ready: \(message())", file: file, line: line)
    if !condition() { throw DocumentSessionError.invalidLayout }
  }

  private func bluePixels(_ image: UIImage) throws -> Int {
    let image = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    }
    return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 40 && bytes[$0 + 1] < 40 && bytes[$0 + 2] > 200 }.count
  }
}

@MainActor
private final class ProgramFixture {
  private(set) var document: DocumentDocument
  let resources: SceneRenderResources
  let activity = PageTurnActivity()
  let hosts = [DocumentWebHost(), DocumentWebHost()]
  private let coordinators = [DocumentPhysicalPageCoordinator(), DocumentPhysicalPageCoordinator()]
  private let actor = UUID()
  let window: UIWindow
  private var state: DocumentStateJournal
  private let measurements: DocumentPresentationRecorder?
  private var linkNavigation: (DocumentLinkDestination) -> Void = { _ in }
  private var selected = 0
  private var interactive: Bool
  private var retiredPresentations: Set<Int> = []
  private var thumbnailPresentations: Set<Int> = []
  private var pageIndices = [0, 1]
  var ready: [Int: Bool] = [:]
  var checkpoints: Set<String> = []
  var checkpointValues: [String: JSONValue] = [:]
  var preparationErrors: [String] = []
  var diagnostics: String { "ready=\(ready) errors=\(preparationErrors) web=\(resources.activeWebSurfaceCount) queued=\(resources.pendingWebRequestCount) held=\(resources.rasterAdmission.heldBytes) state=\(state.records.map { ($0.id, $0.value) })" }
  var currentToken: String { DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndices[selected]) }

  init(document: DocumentDocument, resources: SceneRenderResources = SceneRenderResources(),
    measurements: DocumentPresentationRecorder? = nil, interactive: Bool = true, showsNeighbour: Bool = true) throws {
    self.document = document; self.resources = resources; self.measurements = measurements
    self.interactive = interactive
    if !showsNeighbour { retiredPresentations.insert(1) }
    state = .init(id: document.id, actor: UUID())
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    window = UIWindow(windowScene: scene)
    let container = UIViewController(); window.rootViewController = container
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    for (index, host) in hosts.enumerated() {
      host.frame = .init(x: CGFloat(index) * 360, y: 0, width: 340, height: 340 * geometry.height / geometry.width)
      container.view.addSubview(host)
    }
    window.makeKeyAndVisible(); refresh()
  }

  func replaceLinkNavigation(_ callback: @escaping (DocumentLinkDestination) -> Void) {
    linkNavigation = callback; refresh()
  }
  func replaceSource(blockID: String, source: String) {
    XCTAssertTrue(document.replaceBlockSource(id: blockID, source: source, actor: actor))
    refresh()
  }
  func canonicalPaper(in index: Int) -> Bool {
    guard let web = paper(in: index), let coordinator = web.navigationDelegate as? DocumentWebCoordinator else { return false }
    return coordinator.hasCanonicalPixels && coordinator.payload?.pageIndex == pageIndices[index]
      && coordinator.payload?.renderToken == DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndices[index])
  }
  func select(_ index: Int) { selected = index; refresh() }
  func setInteractive(_ value: Bool) { interactive = value; refresh() }
  func setThumbnail(_ index: Int) { thumbnailPresentations.insert(index); refresh() }
  func retirePresentation(_ index: Int) {
    retiredPresentations.insert(index); coordinators[index].invalidate()
  }
  func restorePresentation(_ index: Int) { retiredPresentations.remove(index); refresh() }
  func showPages(current: Int, neighbour: Int) {
    pageIndices = [current, neighbour]; selected = 0; ready = [:]; refresh()
  }
  private func refresh() {
    for (index, coordinator) in coordinators.enumerated() {
      guard !retiredPresentations.contains(index) else { continue }
      coordinator.update(.init(document: document, state: state, pageIndex: pageIndices[index], isCurrent: selected == index && !thumbnailPresentations.contains(index),
        isVisible: true, isInteractive: selected == index && interactive && !thumbnailPresentations.contains(index), pageTurnActive: false,
        onRenderReady: .init(activity: activity) { [weak self] in self?.ready[index] = $0 },
        onPageLayout: { _ in }, onSourceChange: { _ in .committed },
        onStateChange: { [weak self] block, value in
          guard let self else { return nil }
          _ = state.commit(blockID: block, value: value, actor: actor)
          let accepted = state.records.first { $0.id == block }?.valueVersion
          refresh(); return accepted
        }, drafts: [], onDraftChange: { _ in }, onDraftDiscard: { _ in }, onLinkActivation: { [weak self] in self?.linkNavigation($0.destination) },
        snapshotPixelWidth: thumbnailPresentations.contains(index) ? 256 : nil, onPreparationFailure: { [weak self] error in
          self?.preparationErrors.append("page \(index): \(error)")
        },
        onStateCheckpoint: { [weak self] block, value, version in
          guard let self, document.sourceVersion(blockID: block) == version, self.value(block) == value else { return false }
          checkpoints.insert(block); checkpointValues[block] = value; return true
        }, measurements: measurements), in: hosts[index], resources: resources)
    }
  }

  func value(_ block: String) -> JSONValue? { state.records.first { $0.id == block }?.value }
  func number(_ block: String, field: String) -> Double {
    if case .number(let number) = value(block)?[field] { return number }
    return 0
  }
  func snapshot(in index: Int) -> UIImage? { hosts[index].subviews.compactMap { ($0 as? UIImageView)?.image }.first }
  func windowImage(file: StaticString = #filePath, line: UInt = #line) throws -> UIImage {
    XCTAssertNotNil(window.windowScene, file: file, line: line)
    var drawn = false
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    XCTAssertTrue(drawn, "The attachment must contain the actual native window", file: file, line: line)
    return image
  }
  func web(in index: Int) -> WKWebView? { descendants(hosts[index]).first { $0.accessibilityIdentifier?.hasPrefix("document-program-") == true && $0.isUserInteractionEnabled } }
  func web(block: String) -> WKWebView? {
    descendants(hosts[0]).first { $0.accessibilityIdentifier == "document-program-" + block && $0.isUserInteractionEnabled }
  }
  func start(block: String) {
    func buttons(_ view: UIView) -> [UIButton] {
      (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let button = buttons(hosts[0]).first { $0.accessibilityIdentifier == "document-program-retry-" + block }
    XCTAssertNotNil(button, "A paused or waiting program exposes its native activation action")
    button?.sendActions(for: .touchUpInside)
  }
  func paper(in index: Int) -> WKWebView? { descendants(hosts[index]).first { hosts[index].ownsSurface($0) } }
  func assertPaperReceivesNativeHit(_ web: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
    let point = try await web.evaluateJavaScript("(()=>{const r=document.querySelector('a').getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2]})()") as? [Double]
    let location = try XCTUnwrap(point, file: file, line: line)
    XCTAssertEqual(location.count, 2, file: file, line: line)
    window.layoutIfNeeded()
    let hit = window.hitTest(web.convert(.init(x: location[0], y: location[1]), to: window), with: nil)
    XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true,
      "The actual native route at the visible link must reach this WebKit subtree, got \(String(describing: hit))", file: file, line: line)
  }
  func assertPaperRejectsNativeHit(_ web: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
    let point = try await web.evaluateJavaScript("(()=>{const r=document.querySelector('a').getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2]})()") as? [Double]
    let location = try XCTUnwrap(point, file: file, line: line)
    let hit = window.hitTest(web.convert(.init(x: location[0], y: location[1]), to: window), with: nil)
    XCTAssertFalse(hit === web || hit?.isDescendant(of: web) == true,
      "Disabling new input must close the real native hit-test route", file: file, line: line)
  }
  private func descendants(_ view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
  }
  func message(_ name: String, in web: WKWebView) async throws {
    _ = try await web.callAsyncJavaScript("window.postMessage(name,'*');return true;",
      arguments: ["name": name], in: nil, contentWorld: .page)
  }
  func captureCurrent(file: StaticString = #filePath, line: UInt = #line) async throws -> RasterLease {
    let page = pageIndices[selected]
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: page)
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if let raster = try await DocumentProgramOwner.captureCurrent(documentID: document.id, pageIndex: page,
        token: token, resources: resources) { return raster }
      try await Task.sleep(for: .milliseconds(10))
    }
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let host = hosts[selected]
    let layout = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document).layout
    let placements: [DocumentProgramPlacement] = (layout?.regions(on: page).compactMap { region in
      guard let web = descendants(host).first(where: { $0.accessibilityIdentifier == "document-program-" + region.id }) else { return nil }
      return DocumentProgramPlacement(blockID: region.id, webView: web,
        rect: .init(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height),
        sourceOffset: region.sourceOffset, fullSize: web.bounds.size)
    }) ?? []
    let present = host.programOverlay.presentationFailure(placements, paperSize: .init(width: geometry.width, height: geometry.height))
    XCTFail("Forced current capture unavailable: \(diagnostics), overlay=\(String(describing: present)), snapshot=\(host.hasSnapshot), window=\(host.window != nil)", file: file, line: line)
    throw SceneRenderError.snapshotPending("test_current_document_capture")
  }
  func close() {
    coordinators.forEach { $0.invalidate() }; window.isHidden = true; window.rootViewController = nil
  }
}

@MainActor
private final class WeakDocumentPaper {
  weak var value: WKWebView?
  init(_ value: WKWebView?) { self.value = value }
}
