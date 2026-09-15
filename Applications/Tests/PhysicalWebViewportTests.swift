import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class PhysicalWebViewportTests: XCTestCase {
  func testDocumentHostTransfersItsPhysicalSubtreeWithoutDetachingWebKit() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let source = DocumentWebHost(), target = DocumentWebHost(), web = WindowTrackingDocumentWebView()
    let size = CGSize(width: 240, height: 320)
    for (index, host) in [source, target].enumerated() {
      controller.view.addSubview(host)
      host.frame = .init(x: index * 250, y: 0, width: 240, height: 320)
    }
    source.install(web, size: size); source.configure(size: size, interactive: true); source.layoutIfNeeded()
    let projection = try XCTUnwrap(web.superview as? PhysicalWebViewport)
    web.windowDetachments = 0
    target.install(web, size: size); target.configure(size: size, interactive: false); target.layoutIfNeeded()
    XCTAssertTrue(web.superview === projection)
    XCTAssertTrue(projection.superview === target)
    XCTAssertTrue(web.window === window)
    XCTAssertEqual(web.windowDetachments, 0, "A same-window handoff must not suspend and rebuild WebKit's visible subtree")
    source.removeSurface()
    XCTAssertTrue(target.ownsSurface(web))
    target.install(web, size: size)
    XCTAssertTrue(web.superview === projection, "Repeated native mounting does not replace the projection")
    target.removeSurface()
    XCTAssertNil(web.superview); XCTAssertNil(projection.superview)
  }

  func testCanonicalWebLayoutPrecedesWindowInstallationAndSurvivesProjectionAndReparenting() async throws {
    let web = WKWebView()
    web.scrollView.contentInsetAdjustmentBehavior = .never
    let viewport = PhysicalWebViewport(webView: web, contentSize: .init(width: 240, height: 320))
    defer { viewport.retire() }
    let identity = UUID().uuidString
    web.loadHTMLString("""
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>html,body { margin:0; width:100%; height:100% }</style>
      <p id="retained">Actual canonical document</p>
      <script>window.runtimeIdentity='\(identity)';</script>
      """, baseURL: nil)
    try await waitForViewport(web, width: 240, height: 320)
    XCTAssertNil(viewport.window)
    XCTAssertEqual(viewport.bounds.size, .zero)
    XCTAssertEqual(web.bounds.size, CGSize(width: 240, height: 320))
    viewport.setContentSize(.init(width: 480, height: 640))
    try await waitForViewport(web, width: 480, height: 640)
    XCTAssertNil(viewport.window)

    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(viewport)
    viewport.frame = .init(x: 20, y: 40, width: 120, height: 160)
    window.makeKeyAndVisible(); viewport.layoutIfNeeded()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    XCTAssertEqual(web.bounds.size, CGSize(width: 480, height: 640))
    XCTAssertEqual(web.transform.a, 0.25, accuracy: 0.0001)
    XCTAssertEqual(web.transform.d, 0.25, accuracy: 0.0001)
    try await waitForViewport(web, width: 480, height: 640)

    let incoming = PhysicalWebViewport(webView: web, contentSize: .init(width: 480, height: 640))
    defer { incoming.retire() }
    controller.view.addSubview(incoming)
    incoming.frame = .init(x: 160, y: 40, width: 240, height: 320); incoming.layoutIfNeeded()
    viewport.setContentSize(.init(width: 700, height: 900)); viewport.layoutIfNeeded(); viewport.retire()
    XCTAssertTrue(web.superview === incoming)
    XCTAssertEqual(web.bounds.size, CGSize(width: 480, height: 640), "The retired projection cannot resize the incoming owner's WebKit")
    XCTAssertEqual(web.transform.a, 0.5, accuracy: 0.0001)
    let retained = try await web.evaluateJavaScript("window.runtimeIdentity + ':' + document.getElementById('retained').textContent") as? String
    XCTAssertEqual(retained, identity + ":Actual canonical document")
  }

  private func waitForViewport(_ web: WKWebView, width: Double, height: Double) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    var actual: [Double]?
    while ContinuousClock.now < deadline {
      if !web.isLoading {
        actual = try await web.evaluateJavaScript("[window.innerWidth, window.innerHeight]") as? [Double]
        if actual == [width, height] { return }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(actual, [width, height], "The real document viewport must follow canonical bounds before any screen projection")
  }
}

@MainActor
private final class WindowTrackingDocumentWebView: WKWebView {
  var windowDetachments = 0
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { windowDetachments += 1 }
  }
}
