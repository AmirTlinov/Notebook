import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class AgentSceneFingerRoutingTests: XCTestCase {
  func testPassiveWebContentYieldsMotionButControlsAndAuthoredHandlersRetainInput() async throws {
    let resources = SceneRenderResources(), gate = NotebookInputGate()
    let lease = try await resources.acquireWebSurface(priority: .liveProgram)
    var ready = false, interactions = 0
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onInteractionReady: { ready = $0 }, onState: { _ in false })
    coordinator.use(onInteraction: { interactions += 1 })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let viewport = PhysicalWebViewport(webView: web, contentSize: .init(width: 240, height: 160), holdsFingerInput: true)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(viewport); viewport.frame = .init(x: 100, y: 200, width: 240, height: 160)
    viewport.layoutIfNeeded()
    let panOwner = BoardPanView.Coordinator(isEnabled: true, itemFrames: [viewport.frame], inputGate: gate,
      onTap: {}, onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
    panOwner.install(on: window, inside: host.view)
    defer {
      panOwner.uninstall(); coordinator.invalidate(); viewport.retire(); lease.release()
      window.isHidden = true; window.rootViewController = nil
    }
    let pan = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
    let svg = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 240 160'><path d='M10 140L120 10L230 140' stroke='navy' fill='none'/></svg>"
    let cases: [(String, String, Bool)] = [
      (svg, "", false),
      ("<div>Diagram</div>" + svg, "", false),
      ("<button>Go</button><input type='range'><input type='text'>", "", true),
      ("<svg onclick='window.clicked=true'><rect width='200' height='100'/></svg>", "", true),
      (svg, "document.querySelector('svg').addEventListener('pointermove',()=>{});", true),
      (svg + "<script>document.body.addEventListener('click',()=>{});document.currentScript.remove()</script>", "", true),
      ("<a href='#destination'>Go</a>" + svg, "", true),
      ("<svg xmlns:xlink='http://www.w3.org/1999/xlink'><a xlink:href='#destination'><text>Go</text></a></svg>", "", true),
      ("<svg><animate attributeName='opacity' begin='click' to='0' dur='1s'/></svg>", "", true),
      ("<body onclick='window.clicked=true'>" + svg + "</body>", "", true),
      ("<video controls></video>", "", true),
      (svg, "", false)
    ]
    for (html, script, requiresInput) in cases {
      ready = false
      let element = AgentElement(id: UUID().uuidString, kind: .web,
        frame: .init(x: 0, y: 0, width: 240, height: 160), source: "Finger ownership", html: html, javaScript: script)
      coordinator.load(element, policy: .exact(scale: 1), in: web)
      XCTAssertFalse(coordinator.yieldsFingerMotionToScene, "A previous passive source cannot admit a new source's contact")
      let deadline = ContinuousClock.now + .seconds(5)
      while !ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertTrue(ready); if !ready { throw CocoaError(.featureUnsupported) }
      XCTAssertEqual(viewport.ownsSceneFingerInput, requiresInput, html)
      let point = viewport.convert(CGPoint(x: 120, y: 80), to: window)
      let hit = try XCTUnwrap(window.hitTest(point, with: nil))
      XCTAssertTrue(hit.isDescendant(of: viewport))
      let finger = SVGInputTouch(window: window, view: hit, point: point)
      XCTAssertEqual(panOwner.gestureRecognizer(pan, shouldReceive: finger), !requiresInput,
        "Only actual input ownership, not the element rectangle, can veto camera motion")
      let before = interactions
      coordinator.receive(["token": try XCTUnwrap(coordinator.loadToken), "kind": "interaction"])
      XCTAssertEqual(interactions, before + (requiresInput ? 1 : 0), "Passive drawing contact must not acquire program focus")
      gate.endFingerContacts([ObjectIdentifier(finger)])
    }
  }
}

@MainActor
private final class SVGInputTouch: UITouch {
  let sourceWindow: UIWindow
  let sourceView: UIView
  let point: CGPoint
  init(window: UIWindow, view: UIView, point: CGPoint) {
    sourceWindow = window; sourceView = view; self.point = point; super.init()
  }
  override var type: UITouch.TouchType { .direct }
  override var view: UIView? { sourceView }
  override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
}
