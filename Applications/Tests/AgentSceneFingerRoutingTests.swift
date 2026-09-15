import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class AgentSceneFingerRoutingTests: XCTestCase {
  func testReadyMapRoutesControlsAndAuthoredHandlersAtTheActualContact() async throws {
    let resources = SceneRenderResources(), gate = NotebookInputGate()
    let lease = try await resources.acquireWebSurface(priority: .liveProgram)
    var ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onInteractionReady: { ready = $0 }, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let viewport = PhysicalWebViewport(webView: web, contentSize: .init(width: 240, height: 160), holdsFingerInput: true)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(viewport); viewport.frame = .init(x: 100, y: 200, width: 120, height: 80)
    viewport.layoutIfNeeded()
    let panOwner = BoardPanView.Coordinator(isEnabled: true, itemFrames: [viewport.frame], inputGate: gate,
      onTap: {}, onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
    panOwner.install(on: window, inside: host.view)
    defer {
      panOwner.uninstall(); coordinator.invalidate(); viewport.retire(); lease.release()
      window.isHidden = true; window.rootViewController = nil
    }
    let pan = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
    let svg = "<svg width='240' height='160'><path d='M10 140L120 10L230 140' stroke='navy' fill='none'/></svg>"
    let cases: [(String, String, AgentWebFingerInput)] = [
      (svg, "", .scene),
      (svg, "function fit(){document.querySelector('svg').style.width='240px'}fit();addEventListener('resize',fit)", .scene),
      ("<input type='range' style='width:200px;height:100px;margin:0'>", "", .input),
      ("<svg width='240' height='160' onclick='window.clicked=true'><rect width='200' height='100'/></svg>", "", .input),
      (svg, "document.querySelector('svg').addEventListener('pointermove',()=>{});", .input),
      (svg + "<script>document.body.addEventListener('click',()=>{});document.currentScript.remove()</script>", "", .input),
      ("<a href='#destination'>" + svg + "</a>", "", .link),
      ("<svg width='240' height='160' xmlns:xlink='http://www.w3.org/1999/xlink'><a xlink:href='#destination'><rect width='200' height='100'/></a></svg>", "", .link),
      ("<svg width='240' height='160'><animate attributeName='opacity' begin='click' to='0' dur='1s'/></svg>", "", .input),
      ("<body onclick='window.clicked=true'>" + svg + "</body>", "", .input),
      ("<video controls style='width:200px;height:100px'></video>", "", .input),
      ("<input style='position:absolute;left:170px;top:110px;width:60px;height:30px'>" + svg, "", .scene)
    ]
    for (html, script, expected) in cases {
      ready = false
      let element = AgentElement(id: UUID().uuidString, kind: .web,
        frame: .init(x: 0, y: 0, width: 240, height: 160), source: "Finger ownership", html: html, javaScript: script)
      coordinator.load(element, policy: .exact(scale: 1), in: web)
      XCTAssertEqual(coordinator.fingerInput(at: .init(x: 30, y: 30), in: web.bounds.size), .input,
        "A previous source cannot admit a new source's contact")
      let deadline = ContinuousClock.now + .seconds(5)
      while !ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertTrue(ready); if !ready { throw CocoaError(.featureUnsupported) }
      XCTAssertEqual(coordinator.fingerInput(at: .init(x: 30, y: 30), in: web.bounds.size), expected, html)
      let point = viewport.convert(CGPoint(x: 15, y: 15), to: window)
      let hit = try XCTUnwrap(window.hitTest(point, with: nil))
      XCTAssertTrue(hit.isDescendant(of: viewport))
      let finger = SVGInputTouch(window: window, view: hit, point: point)
      XCTAssertEqual(panOwner.gestureRecognizer(pan, shouldReceive: finger), expected != .input,
        "Canonical DOM regions must follow native scale, not child AX coordinates")
      let original = NotebookSceneFingerRouting.owner(of: finger, gate: gate)
      viewport.frame.origin.x += 30; viewport.layoutIfNeeded()
      XCTAssertEqual(NotebookSceneFingerRouting.owner(of: finger, gate: gate), original)
      gate.endFingerContacts([ObjectIdentifier(finger)])
    }
  }

  func testReadyMapTracksMovedControlsAndListenerRemovalWithoutRuntimeRestart() async throws {
    let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .liveProgram)
    var ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onInteractionReady: { ready = $0 }, onState: { _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    web.frame = .init(x: 0, y: 0, width: 240, height: 160)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible(); host.view.addSubview(web)
    defer {
      coordinator.invalidate(); lease.release(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
    coordinator.load(.init(id: "dynamic", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 160),
      source: "Dynamic controls", html: "<div id='target' style='position:absolute;left:0;top:0;width:100px;height:80px'>Area</div>"),
      policy: .exact(scale: 1), in: web)
    func wait(_ predicate: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertTrue(predicate())
    }
    try await wait { ready }
    let token = coordinator.loadToken
    func kind(_ x: CGFloat) -> AgentWebFingerInput { coordinator.fingerInput(at: .init(x: x, y: 30), in: web.bounds.size) }
    func evaluate(_ script: String) async throws {
      // Mutations may evaluate to a JavaScript function (onclick = handler).
      // The test observes the native region map, not that unbridgeable value.
      do { _ = try await web.evaluateJavaScript(script + "; true") }
      catch {
        XCTFail("Finger-region mutation failed: \(script): \(error)")
        throw error
      }
    }
    XCTAssertEqual(kind(30), .scene)
    try await evaluate("window.target=document.getElementById('target');window.handler=()=>{};target.addEventListener('pointermove',handler)")
    try await wait { kind(30) == .input }
    try await evaluate("target.removeEventListener('pointermove',handler)")
    try await wait { kind(30) == .scene }
    try await evaluate("target.onclick=handler")
    try await wait { kind(30) == .input }
    try await evaluate("target.onclick=null")
    try await wait { kind(30) == .scene }
    try await evaluate("target.innerHTML='<input style=\"width:90px;height:60px\" value=\"preserved\">'")
    try await wait { kind(30) == .input }
    try await evaluate("target.style.left='130px'")
    try await wait { kind(30) == .scene && kind(160) == .input }
    try await evaluate("target.innerHTML='Area';window.signalOwner=new AbortController();target.addEventListener('pointerdown',handler,{signal:signalOwner.signal});signalOwner.abort()")
    try await wait { kind(160) == .scene }
    try await evaluate("target.addEventListener('pointerdown',handler,{once:true});target.dispatchEvent(new Event('pointerdown'))")
    try await wait { kind(160) == .scene }
    XCTAssertEqual(coordinator.loadToken, token)
    coordinator.receive(["token": try XCTUnwrap(token), "kind": "fingerRegions", "value": [
      "revision": 0, "width": 240.0, "height": 160.0,
      "regions": [["kind": "input", "x": 0.0, "y": 0.0, "width": 240.0, "height": 160.0]]
    ]])
    XCTAssertEqual(kind(160), .scene, "A late older layout cannot replace the current input regions")
    XCTAssertEqual(coordinator.fingerInput(at: .init(x: 30, y: 30), in: .init(width: 300, height: 160)), .input,
      "A changed browser size cannot use stale regions")
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
