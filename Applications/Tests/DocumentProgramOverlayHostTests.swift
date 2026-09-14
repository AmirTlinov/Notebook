import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class DocumentProgramOverlayHostTests: XCTestCase {
  @MainActor
  func testPassiveCutKeepsItsOwnAccountedPixelsAndReceiptObservesTheInstalledVersion() throws {
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let host = DocumentProgramOverlayHost(); host.frame = root.view.bounds; root.view.addSubview(host)
    let web = WKWebView()
    let ready = DocumentProgramPlacement(blockID: "ready", webView: web,
      rect: .init(x: 40, y: 40, width: 300, height: 120), sourceOffset: 0, fullSize: .init(width: 300, height: 120))
    let raster = try passiveRaster(resources, color: .blue)
    let paused = DocumentProgramPassivePlacement(blockID: "paused", raster: raster,
      rect: .init(x: 40, y: 200, width: 300, height: 240), sourceOffset: 760, fullSize: .init(width: 300, height: 1600))
    XCTAssertTrue(host.present([ready], paperSize: host.bounds.size, interactive: true, passive: [paused]))
    host.layoutIfNeeded()
    let receipt = host.installation(for: [ready], paperSize: host.bounds.size, passive: [paused])
    raster.release()
    XCTAssertTrue(receipt.isInstalled, "Producer release cannot revoke pixels already owned by a native host")
    XCTAssertGreaterThan(resources.rasterAdmission.pinnedBytes, 0)
    let image = try XCTUnwrap(host.subviews.flatMap(\.subviews).flatMap(\.subviews).compactMap { $0 as? UIImageView }.first)
    let retainedNativeClip = try XCTUnwrap(image.superview)
    let point = image.convert(CGPoint(x: 12, y: 780), to: host)
    XCTAssertEqual(point.x, 52, accuracy: 0.0001); XCTAssertEqual(point.y, 220, accuracy: 0.0001)
    XCTAssertTrue(web.isUserInteractionEnabled)
    let hit = host.hitTest(.init(x: 52, y: 52), with: nil)
    XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true)
    image.frame.origin.y += 1
    XCTAssertFalse(receipt.isInstalled, "The actual native cut, not a cached frame, proves display")
    image.frame.origin.y -= 1
    XCTAssertTrue(receipt.isInstalled)
    let replacement = try passiveRaster(resources, color: .red)
    let newer = DocumentProgramPassivePlacement(blockID: "paused", raster: replacement,
      rect: paused.rect, sourceOffset: paused.sourceOffset, fullSize: paused.fullSize)
    XCTAssertTrue(host.present([ready], paperSize: host.bounds.size, interactive: true, passive: [newer]))
    XCTAssertFalse(receipt.isInstalled, "Same geometry and source address do not prove the previous raster entry")
    replacement.release()
    host.removePrograms()
    XCTAssertNil(retainedNativeClip.superview, "UIKit may keep a departed shell alive after removing its physical content")
    XCTAssertNil(image.image, "A retired view must not keep an unaccounted image after releasing its native raster pin")
    XCTAssertEqual(resources.rasterAdmission.pinnedBytes, 0, "Receipts must not retain pixels after native retirement")
  }

  @MainActor
  func testSuspendingOneProgramShowsItsActionWithoutDisablingAReadyNeighbor() throws {
    let host = DocumentProgramOverlayHost(); host.frame = .init(x: 0, y: 0, width: 600, height: 800)
    let first = WKWebView(), second = WKWebView()
    let ready = DocumentProgramPlacement(blockID: "ready", webView: first,
      rect: .init(x: 40, y: 40, width: 300, height: 120), sourceOffset: 0, fullSize: .init(width: 300, height: 120))
    let suspending = DocumentProgramPlacement(blockID: "suspending", webView: second,
      rect: .init(x: 40, y: 200, width: 300, height: 240), sourceOffset: 0,
      fullSize: .init(width: 300, height: 240), allowsInteraction: false)
    XCTAssertTrue(host.present([ready, suspending], paperSize: host.bounds.size, interactive: true))
    var activations = 0
    host.presentPending([.init(blockID: "suspending", rect: suspending.rect,
      message: "Программа приостановлена", retry: { activations += 1 }, actionTitle: "Запустить")])
    host.layoutIfNeeded()
    XCTAssertTrue(first.isUserInteractionEnabled); XCTAssertFalse(second.isUserInteractionEnabled)
    let hit = host.hitTest(.init(x: 52, y: 52), with: nil)
    XCTAssertTrue(hit === first || hit?.isDescendant(of: first) == true)
    func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    let button = try XCTUnwrap(descendants(host).compactMap { $0 as? UIButton }.first)
    XCTAssertEqual(button.title(for: .normal), "Запустить")
    XCTAssertFalse(button.isHidden)
    button.sendActions(for: .touchUpInside)
    XCTAssertEqual(activations, 1, "This verifies the native action route; actual finger delivery is a separate UI test")
  }

  @MainActor
  private func passiveRaster(_ resources: SceneRenderResources, color: UIColor) throws -> RasterLease {
    let size = CGSize(width: 300, height: 1600)
    let reservation = try XCTUnwrap(resources.reserveRaster(pixelWidth: 300, pixelHeight: 1600))
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      color.setFill(); UIRectFill(.init(origin: .zero, size: size))
    }
    let source = AgentElement(id: "paused", kind: .web, frame: .init(x: 0, y: 0, width: 300, height: 1600),
      source: "program", html: "<body/>")
    return try XCTUnwrap(resources.storeAndRetain(image, for: .agent(source), reservation: reservation))
  }

  @MainActor
  func testPageCutsKeepTheProgramViewportAndPhysicalCoordinates() throws {
    let host = DocumentProgramOverlayHost()
    let web = WKWebView()
    let paper = CGSize(width: 600, height: 800)
    for scale in [0.375, 1.0, 2.125] {
      host.frame = CGRect(x: 0, y: 0, width: 600 * scale, height: 800 * scale)
      XCTAssertTrue(host.present([.init(blockID: "program", webView: web,
        rect: CGRect(x: 40, y: 70, width: 300, height: 240), sourceOffset: 760,
        fullSize: CGSize(width: 300, height: 1600))], paperSize: paper, interactive: true))
      host.layoutIfNeeded()
      XCTAssertEqual(web.bounds.size, CGSize(width: 300, height: 1600),
        "Changing a paper cut must not reflow responsive program content")
      let actual = web.convert(CGPoint(x: 12, y: 780), to: host)
      XCTAssertEqual(actual.x, 52 * scale, accuracy: 0.001)
      XCTAssertEqual(actual.y, 90 * scale, accuracy: 0.001)
    }
  }

  @MainActor
  func testFractionalCanonicalCutSurvivesUIKitFrameRoundTripButRejectsRealMovement() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let host = DocumentProgramOverlayHost(); host.frame = root.view.bounds; root.view.addSubview(host)
    let web = WKWebView()
    let paper = CGSize(width: 595.2755905511812, height: 841.8897637795277)
    let placement = DocumentProgramPlacement(blockID: "fractional", webView: web,
      rect: CGRect(x: 0.1, y: 77.3, width: 513.6378173828125, height: 201.25),
      sourceOffset: 924.6, fullSize: CGSize(width: 513.6378173828125, height: 1600.2))
    XCTAssertTrue(host.present([placement], paperSize: paper, interactive: true))
    host.layoutIfNeeded()
    XCTAssertNil(host.presentationFailure([placement], paperSize: paper))
    web.frame.origin.y += 0.0000001
    XCTAssertFalse(host.isPresenting([placement], paperSize: paper),
      "Machine-rounding tolerance must not admit an actual change, even far below one pixel")
  }

  @MainActor
  func testEmptyPaperPassesInputThroughAndOnlyTheClippedProgramAcceptsIt() {
    let parent = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    let text = UIButton(frame: parent.bounds); parent.addSubview(text)
    let host = DocumentProgramOverlayHost(); host.frame = parent.bounds; parent.addSubview(host)
    let web = WKWebView()
    XCTAssertTrue(host.present([.init(blockID: "program", webView: web,
      rect: CGRect(x: 40, y: 70, width: 300, height: 240), sourceOffset: 760,
      fullSize: CGSize(width: 300, height: 1600))], paperSize: parent.bounds.size, interactive: true))
    host.layoutIfNeeded()
    XCTAssertTrue(parent.hitTest(CGPoint(x: 20, y: 20), with: nil) === text)
    XCTAssertTrue(parent.hitTest(CGPoint(x: 50, y: 60), with: nil) === text,
      "The clipped beginning of the tall program must not steal a text tap")
    let hit = parent.hitTest(CGPoint(x: 52, y: 90), with: nil)
    XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true)
    XCTAssertTrue(parent.hitTest(CGPoint(x: 52, y: 311), with: nil) === text)
  }

  @MainActor
  func testSlowNeighborDoesNotCoverOrDisableTheReadyControl() {
    let host = DocumentProgramOverlayHost()
    host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
    let web = WKWebView()
    XCTAssertTrue(host.present([.init(blockID: "ready", webView: web,
      rect: CGRect(x: 40, y: 70, width: 300, height: 240), sourceOffset: 0,
      fullSize: CGSize(width: 300, height: 240))], paperSize: host.bounds.size, interactive: true))
    let owner = web.superview
    host.presentPending([.init(blockID: "slow", rect: CGRect(x: 40, y: 350, width: 300, height: 200),
      message: "Загрузка интерактивного элемента…")])
    host.layoutIfNeeded()
    XCTAssertTrue(web.superview === owner); XCTAssertTrue(web.isUserInteractionEnabled)
    let hit = host.hitTest(CGPoint(x: 52, y: 90), with: nil)
    XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true)
    XCTAssertNotNil(host.hitTest(CGPoint(x: 52, y: 360), with: nil))
    host.presentPending([.init(blockID: "slow", rect: CGRect(x: 40, y: 350, width: 300, height: 200),
      message: "Не удалось загрузить элемент", retry: {})])
    XCTAssertTrue(web.superview === owner); XCTAssertTrue(web.isUserInteractionEnabled)
  }

  @MainActor
  func testTransferredRuntimeIsNotRetainedByItsFormerHostAfterRetirement() async throws {
    let first = DocumentProgramOverlayHost(), second = DocumentProgramOverlayHost()
    let size = CGSize(width: 600, height: 800)
    weak var released: WKWebView?
    var installation: DocumentProgramInstallation?
    var retainedNativeShells: [UIView] = []
    try autoreleasepool {
      let web = WKWebView(); released = web
      let placement = DocumentProgramPlacement(blockID: "program", webView: web,
        rect: CGRect(x: 40, y: 70, width: 300, height: 240), sourceOffset: 0,
        fullSize: CGSize(width: 300, height: 240))
      XCTAssertTrue(first.present([placement], paperSize: size, interactive: true))
      retainedNativeShells.append(try XCTUnwrap(web.superview))
      XCTAssertTrue(second.present([placement], paperSize: size, interactive: true))
      retainedNativeShells.append(try XCTUnwrap(web.superview))
      installation = second.installation(for: [placement], paperSize: size)
      XCTAssertTrue(second.removeProgram(web))
    }
    for _ in 0..<100 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNil(released, "A detached clip in the previous host must not retain an unaccounted WebKit runtime")
    XCTAssertTrue(retainedNativeShells.allSatisfy { $0.superview == nil && $0.subviews.isEmpty },
      "Native retirement releases the child even if UIKit retains the empty transition shell")
    XCTAssertFalse(installation?.isInstalled ?? true)
    withExtendedLifetime((first, second, installation, retainedNativeShells)) { }
  }

  @MainActor
  func testParkingAndTransferPreserveOneWindowAttachedRuntimeAndReleaseIt() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
    let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let first = DocumentProgramOverlayHost(), second = DocumentProgramOverlayHost()
    for host in [first, second] { host.frame = root.view.bounds; root.view.addSubview(host) }
    let web = WKWebView()
    XCTAssertTrue(first.park(web, fullSize: CGSize(width: 300, height: 1600)))
    XCTAssertTrue(web.window === window); XCTAssertFalse(web.isHidden); XCTAssertEqual(web.alpha, 1)
    XCTAssertNil(first.hitTest(CGPoint(x: 50, y: 90), with: nil))
    let placement = DocumentProgramPlacement(blockID: "program", webView: web,
      rect: CGRect(x: 40, y: 70, width: 300, height: 240), sourceOffset: 760,
      fullSize: CGSize(width: 300, height: 1600))
    let paper = CGSize(width: 600, height: 800)
    XCTAssertTrue(second.present([placement], paperSize: paper, interactive: true))
    second.layoutIfNeeded()
    XCTAssertTrue(web.window === window); XCTAssertTrue(web.isDescendant(of: second))
    XCTAssertTrue(second.isPresenting([placement], paperSize: paper))
    web.isHidden = true
    XCTAssertFalse(second.isPresenting([placement], paperSize: paper))
    web.isHidden = false
    web.frame.origin.y += 1
    XCTAssertFalse(second.isPresenting([placement], paperSize: paper), "A different native cut cannot acknowledge the old pixels")
    web.frame.origin.y -= 1
    first.removePrograms()
    XCTAssertTrue(web.isDescendant(of: second), "The previous host cannot unmount the transferred runtime")
    XCTAssertTrue(second.removeProgram(web))
    XCTAssertNil(web.window); XCTAssertNil(web.superview)
    XCTAssertFalse(second.isPresenting([placement], paperSize: paper))
  }
}
