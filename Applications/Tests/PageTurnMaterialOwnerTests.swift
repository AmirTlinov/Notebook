import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class PageTurnMaterialOwnerTests: XCTestCase {
  func testBlankGridBorrowsResidentPaperWhenPassiveAdmissionIsExhausted() async throws {
    let resources = SceneRenderResources(byteLimit: 1024 * 1024)
    let size = CGSize(width: 32, height: 48)
    let paper = try await PageTurnMaterialOwner.preparedPaper(size: size, scale: 2, resources: resources)
    let admission = resources.rasterAdmission
    let occupied = try XCTUnwrap(resources.reserveDerivedBytes(
      admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes, priority: .passive))
    defer { occupied.release() }
    XCTAssertNil(resources.reserveRaster(pixelWidth: 64, pixelHeight: 96, priority: .passive),
      "The control must refuse a duplicate blank raster")
    let held = resources.rasterAdmission.heldBytes
    let blank = try await PageTurnMaterialOwner.preparedPaper(size: size, scale: 2,
      resources: resources, priority: .input)
    XCTAssertTrue(blank === paper, "The creation slot borrows grid pixels, never its neighbour's composed content")
    XCTAssertEqual(resources.rasterAdmission.heldBytes, held, "Borrowing needs no CPU raster or GPU upload")

    let changedSize = CGSize(width: 40, height: 48)
    do {
      _ = try await PageTurnMaterialOwner.preparedPaper(size: changedSize, scale: 2, resources: resources)
      XCTFail("Speculation must respect exhausted passive admission")
    } catch SceneRenderError.resourceLimit { }
    let demanded = try await PageTurnMaterialOwner.preparedPaper(size: changedSize, scale: 2,
      resources: resources, priority: .input)
    XCTAssertEqual(demanded.logicalSize, changedSize)
    XCTAssertEqual(demanded.allocationPriority, .input,
      "An accepted demand can prepare its own size after speculative refusal")
  }

  func testNativeDetachRemountPublishesAvailabilityWithoutRevokingANewerRuntime() throws {
    let fixture = try Fixture()
    defer { fixture.owner.retire() }
    let provider = try fixture.install(.red, content: .raster)
    fixture.activity.retireElementFrames(at: 0)
    var changes: [Bool] = []
    let observer = fixture.activity.observePreparation { change in
      if case .elementFrames(pageIndex: 0, elementID: _, materialChanged: let changed) = change { changes.append(changed) }
    }
    defer { fixture.activity.removePreparationObserver(observer) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
    let host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible(); window.layoutIfNeeded()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

    let rasterView = AgentSnapshotRasterView()
    rasterView.frame = .init(x: 16, y: 16, width: 32, height: 32)
    rasterView.onRasterInstalled = { [weak rasterView] raster in
      guard let rasterView else { return }
      fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
        source: fixture.source, installation: rasterView.installation(for: raster), acquisition: .raster(raster))
    }
    rasterView.updateRaster(provider.raster)
    host.view.addSubview(rasterView); rasterView.layoutIfNeeded()
    let rasterVersion = try XCTUnwrap(fixture.activity.elementFrameVersion(page: 0, source: fixture.source))
    XCTAssertNotNil(try fixture.activity.borrowRasterElementFrame(page: 0, source: fixture.source),
      "A program's installed passive pixels are synchronously borrowable")
    XCTAssertEqual(changes, [true])
    rasterView.removeFromSuperview()
    XCTAssertFalse(fixture.activity.hasElementFrame(page: 0, source: fixture.source))
    XCTAssertThrowsError(try fixture.activity.borrowRasterElementFrame(page: 0, source: fixture.source))
    XCTAssertEqual(changes, [true, false], "The native loss must be published before the same view returns")
    host.view.addSubview(rasterView); rasterView.layoutIfNeeded()
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), rasterVersion)
    XCTAssertEqual(changes, [true, false, false])

    let webView = WKWebView()
    let viewport = PhysicalWebViewport(webView: webView, contentSize: .init(width: 32, height: 32))
    viewport.frame = .init(x: 64, y: 16, width: 32, height: 32)
    viewport.layoutIfNeeded()
    let runtimeOwner = NativeInstalledOwner(webView)
    viewport.onInstalled = {
      let installation = SceneSourceInstallation(source: .agent(fixture.source), runtimeToken: "accepted-runtime", owner: runtimeOwner)
      fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
        source: fixture.source, installation: installation, acquisition: .runtime { _ in try await provider.acquire() })
    }
    defer { viewport.retire(); rasterView.uninstall() }
    host.view.addSubview(viewport); viewport.layoutIfNeeded()
    let runtimeVersion = try XCTUnwrap(fixture.activity.elementFrameVersion(page: 0, source: fixture.source))
    XCTAssertEqual(runtimeVersion.content, .runtime)
    XCTAssertNil(try fixture.activity.borrowRasterElementFrame(page: 0, source: fixture.source),
      "An installed runtime must take a fresh cut even while its raster bridge remains")
    XCTAssertEqual(changes, [true, false, false, true])
    // The fallback is still mounted while the running view earns first paint.
    // Its late layout must not replace the live capture owner with a raster
    // which disappears as soon as that paint is acknowledged.
    rasterView.updateRaster(provider.raster)
    rasterView.setNeedsLayout(); rasterView.layoutIfNeeded()
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), runtimeVersion)
    XCTAssertEqual(changes, [true, false, false, true])
    rasterView.removeFromSuperview()
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), runtimeVersion)
    XCTAssertEqual(changes, [true, false, false, true], "A late raster loss cannot revoke the installed runtime")
    viewport.removeFromSuperview()
    XCTAssertFalse(fixture.activity.hasElementFrame(page: 0, source: fixture.source))
    XCTAssertEqual(changes, [true, false, false, true, false])
    host.view.addSubview(viewport); viewport.layoutIfNeeded()
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), runtimeVersion)
    XCTAssertEqual(changes, [true, false, false, true, false, false])
    // A checkpoint raster can install before the old browser dismantles.
    // Its callback must remain owned until that retirement edge; requiring
    // another raster layout here would leave a retained page waiting forever.
    host.view.addSubview(rasterView); rasterView.layoutIfNeeded()
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), runtimeVersion)
    XCTAssertEqual(changes, [true, false, false, true, false, false])
    viewport.retire()
    let retiredRuntimeReplacement = try XCTUnwrap(fixture.activity.elementFrameVersion(page: 0, source: fixture.source))
    XCTAssertEqual(retiredRuntimeReplacement.content, .raster)
    XCTAssertNotNil(try fixture.activity.borrowRasterElementFrame(page: 0, source: fixture.source))
    XCTAssertNotEqual(retiredRuntimeReplacement, runtimeVersion)
    XCTAssertEqual(changes, [true, false, false, true, false, false, true])
  }

  func testUnchangedProviderLayoutDoesNotWakeThePageButPixelsAndAvailabilityDo() async throws {
    let siblings = (0..<24).map { index in
      AgentElement(id: "sibling-\(index)", kind: .web,
        frame: .init(x: 0, y: 0, width: 32, height: 32), source: "Sibling", html: "<canvas/>")
    }
    let fixture = try Fixture(additionalElements: siblings)
    defer { fixture.owner.retire() }
    try await fixture.prepare()
    let siblingOwner = InstalledOwner()
    for source in siblings {
      let installation = SceneSourceInstallation(source: .agent(source), runtimeToken: source.id,
        requiresVisibility: false, owner: siblingOwner)
      fixture.activity.installElementFrame(page: 0, element: source.id, owner: UUID(), source: source,
        installation: installation, acquisition: .runtime { _ in throw PageTurnMaterialUnavailable.changed })
    }
    var changes: [Bool] = []
    let observer = fixture.activity.observePreparation { change in
      if case .elementFrames(pageIndex: 0, elementID: _, materialChanged: let changed) = change { changes.append(changed) }
    }
    defer { fixture.activity.removePreparationObserver(observer) }
    let provider = try fixture.install(.red, content: .raster)
    let version = try XCTUnwrap(fixture.activity.elementFrameVersion(page: 0, source: fixture.source))
    XCTAssertTrue(fixture.owner.isCaptureReady(readiness: fixture.readiness))
    let siblingChecks = siblingOwner.visibilityChecks
    func layout() {
      let installation = SceneSourceInstallation(source: .agent(fixture.source), entryID: provider.raster.entryID,
        requiresVisibility: false, owner: fixture.installedOwner)
      fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
        source: fixture.source, installation: installation, acquisition: .raster(provider.raster))
    }
    for _ in 0..<24 { layout() }
    XCTAssertEqual(changes, [true], "Layout wrappers do not ask the page to revalidate every sibling")
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), version)
    fixture.installedOwner.visible = false; layout(); layout()
    XCTAssertFalse(fixture.activity.hasElementFrame(page: 0, source: fixture.source))
    XCTAssertEqual(changes, [true, false], "Loss of availability is a real edge, not a material replacement")
    XCTAssertFalse(fixture.owner.isCaptureReady(readiness: fixture.readiness))
    fixture.installedOwner.visible = true; layout(); layout()
    XCTAssertEqual(changes, [true, false, false])
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), version)
    XCTAssertTrue(fixture.owner.isCaptureReady(readiness: fixture.readiness))
    _ = try fixture.install(.blue, content: .raster)
    XCTAssertEqual(changes, [true, false, false, true])
    XCTAssertNotEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), version)
    XCTAssertEqual(siblingOwner.visibilityChecks, siblingChecks,
      "An addressed material/availability edge never rechecks every native sibling")
    // An ancestor can change before its child reports another layout. The hint
    // is unchanged, while the fresh borrow boundary must reject the lost source.
    siblingOwner.visible = false
    XCTAssertTrue(fixture.owner.isCaptureReady(readiness: fixture.readiness))
    XCTAssertFalse(fixture.activity.hasElementFrame(page: 0, source: siblings[0]))
    do {
      _ = try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
      XCTFail("Accepted turn must validate native availability even without a provider callback")
    } catch is PageTurnMaterialUnavailable { }
    fixture.activity.removeElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID)
    XCTAssertFalse(fixture.owner.isCaptureReady(readiness: fixture.readiness), "Removing the exact owner revokes its hint")
  }

  func testPassiveProgramFrameSurvivesNativeDetachmentAndReusesItsExactMaterial() async throws {
    let fixture = try Fixture()
    defer { fixture.owner.retire() }
    try await fixture.prepare()
    let provider = try fixture.install(.red, content: .raster)
    func publishRasterInstallation() {
      let installation = SceneSourceInstallation(source: .agent(fixture.source), entryID: provider.raster.entryID,
        requiresVisibility: false, owner: fixture.installedOwner)
      fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
        source: fixture.source, installation: installation, acquisition: .raster(provider.raster))
    }
    var compositions = 0, completedFrame: UUID?
    precondition(NotebookNavigationObservation.onPageMaterialPreparation == nil)
    NotebookNavigationObservation.onPageMaterialPreparation = { stage, _, page, frame, _, _ in
      guard page == fixture.page.id else { return }
      if stage == "composition_started" {
        compositions += 1
        if compositions == 1 {
          // The page has borrowed its immutable inputs. Native reparenting
          // must revoke new borrows without cancelling this GPU composition.
          fixture.installedOwner.visible = false
          publishRasterInstallation()
        }
      }
      if stage == "passive_completed" { completedFrame = frame }
    }
    defer { NotebookNavigationObservation.onPageMaterialPreparation = nil }
    fixture.owner.preparePassiveFrame(readiness: fixture.readiness, enabled: true)
    try await waitUntil { completedFrame != nil }
    do {
      _ = try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
      XCTFail("A prepared cut cannot replace the unavailable native installation")
    } catch is PageTurnMaterialUnavailable { }
    fixture.installedOwner.visible = true
    publishRasterInstallation()
    fixture.activeTurn = true
    let turn = Task { @MainActor in
      try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
    }
    let first = try await turn.value
    let repeated = try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
    XCTAssertEqual(compositions, 1, "Restoring the same installation must reuse its already prepared pixels")
    XCTAssertEqual(first.id, completedFrame)
    XCTAssertTrue(first === repeated)

    _ = try fixture.install(.blue, content: .raster)
    let changed = try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
    XCTAssertFalse(first === changed, "A new installed raster replaces the old complete page")
    XCTAssertEqual(compositions, 2)
    let image = try XCTUnwrap(PageTurnFrameFixture.image(changed))
    let pixel = try XCTUnwrap(image.cropping(to: .init(x: 16, y: 16, width: 1, height: 1)))
    var rgba = [UInt8](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { bytes in
      let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(pixel, in: .init(x: 0, y: 0, width: 1, height: 1))
    }
    XCTAssertGreaterThan(rgba[2], 240); XCTAssertLessThan(rgba[0], 15)
  }

  func testAvailabilityOnlyWakePreservesSuspendedCaptureButReplacementRejectsIt() async throws {
    let fixture = try Fixture()
    defer { fixture.owner.retire(); fixture.readiness.retire() }
    try await fixture.prepare()
    let provider = try fixture.install(.red, content: .runtime, suspended: true)
    defer { provider.resume() }
    let installation = SceneSourceInstallation(source: .agent(fixture.source), entryID: provider.raster.entryID,
      runtimeToken: "same-runtime", requiresVisibility: false, owner: fixture.installedOwner)
    func publishAvailability() {
      fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
        source: fixture.source, installation: installation, acquisition: .runtime { _ in try await provider.acquire() })
    }
    func publishReadiness() {
      fixture.readiness(true, capturable: fixture.owner.isCaptureReady(readiness: fixture.readiness))
    }
    publishAvailability(); publishReadiness()
    fixture.owner.prepareStaticSlots(readiness: fixture.readiness, onReady: publishReadiness, onFailure: { _ in })
    fixture.readiness.setFrameProvider { priority in
      try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: priority)
    }
    fixture.activeTurn = true
    let revision = fixture.readiness.materialRevision
    let version = fixture.activity.elementFrameVersion(page: 0, source: fixture.source)
    let accepted = Task { @MainActor in try await fixture.readiness.acquireFrame(priority: .input) }
    try await waitUntil { provider.waiter != nil }
    fixture.installedOwner.visible = false; publishAvailability()
    fixture.installedOwner.visible = true; publishAvailability()
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), version)
    XCTAssertEqual(fixture.readiness.materialRevision, revision,
      "Native availability wakes the owner without revoking unchanged source/pixels")
    provider.resume()
    let frame = try await accepted.value
    XCTAssertEqual(frame.logicalSize, CGSize(width: 32, height: 32))
    XCTAssertEqual(provider.calls, 1, "A transient installation edge must not recapture the same accepted runtime")

    provider.suspended = true
    let replaced = Task { @MainActor in try await fixture.readiness.acquireFrame(priority: .input) }
    try await waitUntil { provider.waiter != nil }
    _ = try fixture.install(.blue, content: .runtime)
    provider.resume()
    do { _ = try await replaced.value; XCTFail("A different installed source still revokes suspended pixels") }
    catch is PageTurnMaterialUnavailable { }
  }

  func testRestoredExactProviderSurvivesHistoricalMaterialChangesButReplacementDoesNot() async throws {
    let fixture = try Fixture()
    defer { fixture.owner.retire(); fixture.readiness.retire() }
    try await fixture.prepare()
    let provider = try fixture.install(.red, content: .runtime, suspended: true)
    defer { provider.resume() }
    let runtime = SceneSourceInstallation(source: .agent(fixture.source), entryID: provider.raster.entryID,
      runtimeToken: "accepted-runtime", requiresVisibility: false, owner: fixture.installedOwner)
    func publishRuntime() {
      fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
        source: fixture.source, installation: runtime, acquisition: .runtime { _ in try await provider.acquire() })
    }
    publishRuntime()
    let bridgeOwner = InstalledOwner()
    let bridge = SceneSourceInstallation(source: .agent(fixture.source), entryID: provider.raster.entryID,
      requiresVisibility: false, owner: bridgeOwner)
    fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
      source: fixture.source, installation: bridge, acquisition: .raster(provider.raster))
    fixture.readiness(true)
    fixture.readiness.setFrameProvider { priority in
      try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: priority)
    }
    fixture.activeTurn = true
    let revision = fixture.readiness.materialRevision
    let version = fixture.activity.elementFrameVersion(page: 0, source: fixture.source)
    let accepted = Task { @MainActor in try await fixture.readiness.acquireFrame(priority: .input) }
    try await waitUntil { provider.waiter != nil }
    fixture.installedOwner.visible = false; publishRuntime()
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source)?.content, .raster)
    fixture.installedOwner.visible = true; publishRuntime()
    XCTAssertGreaterThan(fixture.readiness.materialRevision, revision,
      "A native bridge can replace the selected presentation and then restore the same runtime")
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), version)
    provider.resume()
    let frame = try await accepted.value
    XCTAssertEqual(frame.logicalSize, CGSize(width: 32, height: 32))
    XCTAssertEqual(provider.calls, 1, "The exact material owner accepted this cut; an outer history counter cannot demand another capture")

    provider.suspended = true
    let replaced = Task { @MainActor in try await fixture.readiness.acquireFrame(priority: .input) }
    try await waitUntil { provider.waiter != nil }
    _ = try fixture.install(.blue, content: .runtime)
    provider.resume()
    do { _ = try await replaced.value; XCTFail("Replacing the final exact provider must still revoke the capture") }
    catch is PageTurnMaterialUnavailable { }
  }

  func testRuntimeNeverWarmsOrReusesAPreviousTurnAndRetirementRejectsPendingPixels() async throws {
    let fixture = try Fixture()
    defer { fixture.owner.retire() }
    try await fixture.prepare()
    let runtime = try fixture.install(.red, content: .runtime)
    fixture.owner.preparePassiveFrame(readiness: fixture.readiness, enabled: true)
    await Task.yield()
    XCTAssertEqual(runtime.calls, 0, "A live DOM has no immutable background page cut")
    fixture.activeTurn = true
    let first = try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
    let second = try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
    XCTAssertFalse(first === second)
    XCTAssertEqual(runtime.calls, 2, "Each accepted live turn asks its installed runtime for current pixels")

    fixture.activity.removeElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID)
    let pending = try fixture.install(.blue, content: .runtime, suspended: true)
    let turn = Task { @MainActor in
      try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
    }
    try await waitUntil { pending.waiter != nil }
    fixture.activeTurn = false
    fixture.owner.retire()
    pending.resume()
    do { _ = try await turn.value; XCTFail("Retired preparation cannot return or cache its late pixels") }
    catch is CancellationError { }
    catch is PageTurnMaterialUnavailable { }
  }

  func testLocalNativeEditAndMoveReuseEveryUnaffectedMaterial() async throws {
    let actor = UUID(), owner = PageTurnMaterialOwner()
    defer { owner.retire() }
    var elements = (0..<3).map { index in
      AgentElement(id: "text-\(index)", kind: .nativeText,
        frame: .init(x: 8, y: 8 + Double(index) * 35, width: 100, height: 24),
        source: "Initial \(index)", html: "", textStyle: .init(fontSize: 16))
    }
    var page = PageDocument(size: .init(width: 160, height: 160), actor: actor, elements: elements)
    func prepare() async throws {
      var ready = false, failure: String?
      owner.prepare(page: page, erasures: [:], ordered: [], scale: 1,
        onReady: { ready = true }, onFailure: { failure = $0.message })
      try await waitUntil { ready || failure != nil }
      XCTAssertNil(failure); XCTAssertTrue(ready)
    }
    try await prepare()
    let original = owner.preparedMaterialIDs
    XCTAssertEqual(original.count, 3)
    elements[1] = AgentElement(id: elements[1].id, kind: .nativeText, frame: elements[1].frame,
      source: "Changed text", html: "", textStyle: elements[1].textStyle)
    XCTAssertTrue(page.replaceElements(elements, actor: actor)); try await prepare()
    let edited = owner.preparedMaterialIDs
    XCTAssertEqual(edited["text-0"], original["text-0"])
    XCTAssertNotEqual(edited["text-1"], original["text-1"])
    XCTAssertEqual(edited["text-2"], original["text-2"])
    let moved = elements[1].frame
    elements[1] = elements[1].updating(frame: .init(x: moved.x + 12, y: moved.y, width: moved.width, height: moved.height))
    XCTAssertTrue(page.replaceElements(elements, actor: actor)); try await prepare()
    XCTAssertEqual(owner.preparedMaterialIDs, edited, "Placement changes retain unchanged local pixels")
  }

  func testInstalledPendingCutCanTurnAndRetryHandsOffToExactRuntimePixels() async throws {
    let fixture = try Fixture()
    defer { fixture.owner.retire() }
    try await fixture.prepare()
    let runtime = try fixture.install(.red, content: .runtime)
    let status = try await PageElementStatusPresentation.prepare(.init(source: fixture.source,
      rasterSource: .agent(fixture.source), message: "Не удалось запустить программу", canRetry: true,
      scale: 1, previousRaster: nil), raster: nil, resources: fixture.resources)
    let statusOwner = InstalledOwner()
    let installed = SceneSourceInstallation(source: .agent(fixture.source), entryID: status.id,
      requiresVisibility: false, owner: statusOwner)
    fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
      source: fixture.source, installation: installed, acquisition: .status(status.cut))
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source)?.content, .status)
    XCTAssertTrue(fixture.owner.isCaptureReady(readiness: fixture.readiness))
    fixture.activeTurn = true
    _ = try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
    XCTAssertEqual(runtime.calls, 0, "A displayed error is the accepted cut; the failed program cannot block navigation")
    statusOwner.visible = false
    fixture.activity.installElementFrame(page: 0, element: fixture.source.id, owner: fixture.providerID,
      source: fixture.source, installation: installed, acquisition: .status(status.cut))
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source)?.content, .runtime)
    _ = try await fixture.owner.acquire(page: fixture.page, readiness: fixture.readiness, priority: .input)
    XCTAssertEqual(runtime.calls, 1, "An installed retry replaces the status cut with its own current pixels")
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(predicate())
  }

  @MainActor private final class InstalledOwner: SceneSourceInstallationOwner {
    var visible = true
    var visibilityChecks = 0
    func isShowing(_ installation: SceneSourceInstallation) -> Bool { visibilityChecks += 1; return visible }
  }

  @MainActor private final class NativeInstalledOwner: SceneSourceInstallationOwner {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
    func isShowing(_ installation: SceneSourceInstallation) -> Bool {
      view.map { SceneSourceVisibility.isVisible($0) } ?? false
    }
  }

  @MainActor private final class Provider {
    let raster: RasterLease
    var calls = 0
    var suspended: Bool
    var waiter: CheckedContinuation<Void, Never>?
    init(raster: RasterLease, suspended: Bool) { self.raster = raster; self.suspended = suspended }
    func acquire() async throws -> PageTurnElementFrame {
      calls += 1
      if suspended { await withCheckedContinuation { waiter = $0 } }
      try Task.checkCancellation()
      return PageTurnElementFrame(raster: try XCTUnwrap(raster.retainedCopy()))
    }
    func resume() { suspended = false; let next = waiter; waiter = nil; next?.resume() }
  }

  @MainActor private final class Fixture {
    let owner = PageTurnMaterialOwner(), activity = PageTurnActivity()
    let resources = SceneRenderResources(byteLimit: 2 * 1024 * 1024)
    let installedOwner = InstalledOwner(), providerID = UUID()
    let page: PageDocument
    let source: AgentElement
    var activeTurn = false
    lazy var readiness = PageTurnReadiness(activity: activity, isInActiveTurn: { [weak self] in self?.activeTurn == true }) { _ in }
    var prepared = false
    var failures: [String] = []
    init(additionalElements: [AgentElement] = []) throws {
      source = .init(id: UUID().uuidString, kind: .web,
        frame: .init(x: 0, y: 0, width: 32, height: 32), source: "Program",
        html: "<canvas/>", javaScript: "window.value = 1")
      page = .init(size: .init(width: 32, height: 32), actor: UUID(), elements: [source] + additionalElements)
      readiness.inkFrameIsReady = { true }; readiness.inkFrameIsEmpty = { true }
    }
    func prepare() async throws {
      owner.prepare(page: page, erasures: [:], ordered: [], scale: 1,
        onReady: { [weak self] in self?.prepared = true },
        onFailure: { [weak self] in self?.failures.append($0.message) })
      let deadline = ContinuousClock.now + .seconds(3)
      while !prepared, failures.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertTrue(prepared, failures.description)
      owner.prepareStaticSlots(readiness: readiness, onReady: {}, onFailure: { [weak self] in self?.failures.append($0.message) })
    }
    func install(_ color: UIColor, content: PageTurnActivity.ElementFrameContent, suspended: Bool = false) throws -> Provider {
      let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
      let image = UIGraphicsImageRenderer(size: .init(width: 32, height: 32), format: format).image {
        color.setFill(); $0.fill(.init(x: 0, y: 0, width: 32, height: 32))
      }
      XCTAssertTrue(resources.store(image, for: source))
      let provider = Provider(raster: try XCTUnwrap(resources.retainRaster(for: source)), suspended: suspended)
      let installation = SceneSourceInstallation(source: .agent(source), entryID: provider.raster.entryID,
        runtimeToken: content == .runtime ? UUID().uuidString : nil, requiresVisibility: false, owner: installedOwner)
      activity.installElementFrame(page: 0, element: source.id, owner: providerID, source: source,
        installation: installation, acquisition: content == .raster ? .raster(provider.raster)
          : .runtime { _ in try await provider.acquire() })
      return provider
    }
  }
}
