import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class PageTurnMaterialOwnerTests: XCTestCase {
  func testNativeDetachRemountPublishesAvailabilityWithoutRevokingANewerRuntime() throws {
    let fixture = try Fixture()
    defer { fixture.owner.retire() }
    let provider = try fixture.install(.red, content: .raster)
    fixture.activity.retireElementFrames(at: 0)
    var changes: [Bool] = []
    let observer = fixture.activity.observePreparation { change in
      if case .elementFrames(pageIndex: 0, materialChanged: let changed) = change { changes.append(changed) }
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

  func testUnchangedProviderLayoutDoesNotWakeThePageButPixelsAndAvailabilityDo() throws {
    let fixture = try Fixture()
    defer { fixture.owner.retire() }
    var changes: [Bool] = []
    let observer = fixture.activity.observePreparation { change in
      if case .elementFrames(pageIndex: 0, materialChanged: let changed) = change { changes.append(changed) }
    }
    defer { fixture.activity.removePreparationObserver(observer) }
    let provider = try fixture.install(.red, content: .raster)
    let version = try XCTUnwrap(fixture.activity.elementFrameVersion(page: 0, source: fixture.source))
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
    fixture.installedOwner.visible = true; layout(); layout()
    XCTAssertEqual(changes, [true, false, false])
    XCTAssertEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), version)
    _ = try fixture.install(.blue, content: .raster)
    XCTAssertEqual(changes, [true, false, false, true])
    XCTAssertNotEqual(fixture.activity.elementFrameVersion(page: 0, source: fixture.source), version)
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

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(predicate())
  }

  @MainActor private final class InstalledOwner: SceneSourceInstallationOwner {
    var visible = true
    func isShowing(_ installation: SceneSourceInstallation) -> Bool { visible }
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
    init() throws {
      source = .init(id: UUID().uuidString, kind: .web,
        frame: .init(x: 0, y: 0, width: 32, height: 32), source: "Program",
        html: "<canvas/>", javaScript: "window.value = 1")
      page = .init(size: .init(width: 32, height: 32), actor: UUID(), elements: [source])
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
