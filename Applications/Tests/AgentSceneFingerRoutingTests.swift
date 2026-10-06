import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class AgentSceneFingerRoutingTests: XCTestCase {
  func testWindowObserverRetiresControlAndPopupContactsBeforeTheNextPickup() throws {
    let gate=NotebookInputGate(),scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous=scene.windows.first(where:\.isKeyWindow)
    let window=UIWindow(windowScene:scene),host=UIViewController(),paper=UIViewController()
    window.rootViewController=host;window.makeKeyAndVisible()
    host.addChild(paper);host.view.addSubview(paper.view);paper.view.frame=host.view.bounds;paper.didMove(toParent:host)
    let grip=UIButton(frame:.init(x:100,y:200,width:44,height:44))
    paper.view.addSubview(grip)
    // A UIKit presentation is outside the scene controller's view subtree.
    let popup=UIButton(frame:.init(x:300,y:200,width:80,height:44))
    host.view.addSubview(popup)
    let region=UUID()
    gate.registerControlRegion(source:region) { point,_ in grip.bounds.contains(grip.convert(point,from:window)) }
    let owner=WorkspaceGestureLayer.Coordinator(defersHorizontalMotionToPageTurn:false,isEnabled:true,inputGate:gate,
      onCamera:{ _ in XCTFail("Native controls retain their gestures") },onUndo:{},onRedo:{})
    owner.install(on:window,inside:paper.view)
    defer {
      owner.uninstall();gate.unregisterControlRegion(source:region)
      window.isHidden=true;window.rootViewController=nil;previous?.makeKey()
    }
    let observer=try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? NotebookContactObserver }.first)
    let camera=try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? TwoFingerPaperGestureRecognizer }.first)
    for (control,cancelled) in [(grip,false),(popup,true)] {
      let point=control.convert(CGPoint(x:control.bounds.midX,y:control.bounds.midY),to:window)
      let finger=SVGInputTouch(window:window,view:control,point:point),event=UIEvent()
      if control === grip { XCTAssertFalse(gate.permitsSceneContact(at:point,kind:.finger)) }
      else { XCTAssertFalse(sceneReceives(finger,inside:paper.view)) }
      // A grip resolves its own input owner before the independent window
      // observer receives the same physical contact. Only that observer ends it.
      XCTAssertEqual(NotebookSceneFingerRouting.owner(of:finger,gate:gate),.nativeInput(ObjectIdentifier(control)))
      let admitted=owner.gestureRecognizer(observer,shouldReceive:finger)
      XCTAssertTrue(admitted,"A scene exclusion must not hide a physical contact's lifetime")
      XCTAssertFalse(owner.gestureRecognizer(camera,shouldReceive:finger))
      if admitted {
        let generation=gate.acceptedContactGeneration
        observer.touchesBegan([finger],with:event)
        XCTAssertEqual(gate.admittedFingerContactCount,1)
        XCTAssertEqual(gate.acceptedContactGeneration,generation+(control === grip ? 1 : 0),
          "A native scene control advances context; a presented control continues its existing intent")
        XCTAssertTrue(gate.isActive,"Both controls still own their physical contact barrier")
        if cancelled { observer.touchesCancelled([finger],with:event) }
        else { observer.touchesEnded([finger],with:event) }
      }
      XCTAssertEqual(gate.admittedFingerContactCount,0,"Released controls cannot poison the next scene pickup")
      XCTAssertTrue(gate.permitsObjectPickup)
      observer.reset() // UIKit resets between physical sequences; these callbacks are synthetic.
    }
    let next=SVGInputTouch(window:window,view:paper.view,point:paper.view.convert(.init(x:120,y:400),to:window))
    XCTAssertTrue(owner.gestureRecognizer(observer,shouldReceive:next))
    let generation=gate.acceptedContactGeneration
    observer.touchesBegan([next],with:UIEvent())
    XCTAssertEqual(gate.acceptedContactGeneration,generation+1)
    XCTAssertEqual(gate.admittedFingerContactCount,1)
    XCTAssertTrue(gate.permitsObjectPickup,"The next finger is a fresh sequence, not a leaked second contact")
    owner.uninstall()
    XCTAssertEqual(gate.admittedFingerContactCount,0,"Closing retires even a contact still physically down")
    XCTAssertTrue(gate.permitsObjectPickup)
  }

  func testReadyMapRoutesControlsAndAuthoredHandlersAtTheActualContact() async throws {
    let resources = SceneRenderResources(), gate = NotebookInputGate()
    let lease = try await resources.acquireWebSurface(priority: .liveProgram)
    var ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onInteractionReady: { ready = $0 }, onState: { _, _ in false })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let viewport = PhysicalWebViewport(webView: web, contentSize: .init(width: 240, height: 160), holdsFingerInput: true)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
    host.view.addSubview(viewport); viewport.frame = .init(x: 100, y: 200, width: 120, height: 80)
    viewport.layoutIfNeeded()
    let panOwner = WorkspacePanView.Coordinator(isEnabled: true, inputGate: gate,
      onBegan: {}, onChanged: { _ in }, onEnded: { _ in }, onCancelled: {})
    panOwner.install(on: window, inside: host.view)
    defer {
      panOwner.uninstall(); coordinator.invalidate(); viewport.retire(); lease.release()
      window.isHidden = true; window.rootViewController = nil
    }
    let pan = try XCTUnwrap(window.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
    let svg = "<svg width='240' height='160'><path d='M10 140L120 10L230 140' stroke='navy' fill='none'/></svg>"
    let cases: [(String, String, AgentWebFingerInput)] = [
      (svg, "", .scene),
      (svg, "function fit(){document.querySelector('svg').style.width='240px'}fit();addEventListener('resize',fit);notebook.ready(Promise.resolve())", .scene),
      ("<input type='range' style='width:200px;height:100px;margin:0'>", "", .input),
      ("<svg width='240' height='160' onclick='window.clicked=true'><rect width='200' height='100'/></svg>", "", .input),
      (svg, "document.querySelector('svg').addEventListener('pointermove',()=>{});notebook.ready(Promise.resolve());", .input),
      (svg + "<script>document.body.addEventListener('click',()=>{});notebook.ready(Promise.resolve());document.currentScript.remove()</script>", "", .input),
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
      onInteractionReady: { ready = $0 }, onState: { _, _ in false })
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
    var lastMutation = "runtime ready"
    func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
      if !predicate() {
        let state = try await web.evaluateJavaScript("JSON.stringify({active:document.activeElement?.id,documentFocused:document.hasFocus(),fieldFocused:document.getElementById('field')?.matches(':focus'),hash:location.hash,inlineStyle:document.getElementById('target').style.cssText,touchAction:getComputedStyle(document.getElementById('target')).touchAction,rect:document.getElementById('target').getBoundingClientRect().toJSON()})")
        XCTFail("Finger map after \(lastMutation): native=\(coordinator.fingerInput(at: .init(x: 160, y: 30), in: web.bounds.size)), DOM=\(state)", file: file, line: line)
      }
    }
    try await wait { ready }
    let token = coordinator.loadToken
    func kind(_ x: CGFloat) -> AgentWebFingerInput { coordinator.fingerInput(at: .init(x: x, y: 30), in: web.bounds.size) }
    func evaluate(_ script: String) async throws {
      lastMutation = script
      // Mutations may evaluate to a JavaScript function (onclick = handler).
      // The test observes the native region map, not that unbridgeable value.
      do { _ = try await web.evaluateJavaScript(script + "; true") }
      catch {
        XCTFail("Finger-region mutation failed: \(script): \(error)")
        throw error
      }
    }
    func expectCSSTouchAction(_ expected: String = "none", file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
      let actual = try await web.evaluateJavaScript("getComputedStyle(target).touchAction")
      guard actual as? String == expected else {
        let state = try await web.evaluateJavaScript("JSON.stringify({active:document.activeElement?.id,documentFocused:document.hasFocus(),fieldFocused:document.getElementById('field')?.matches(':focus'),focusRule:target.matches('body:has(#field:focus) #target'),targetRule:target.matches('#target:target'),hash:location.hash,inlineStyle:target.style.cssText})")
        XCTFail("Authored CSS after \(lastMutation): expected touchAction=\(expected), actual=\(actual), DOM=\(state)", file: file, line: line)
        return false
      }
      return true
    }
    func finishLayoutObservation() async throws {
      // Complete an existing layout/ResizeObserver turn before the next pure
      // CSSOM edit; a pending geometry event must not mask a missing CSS hook.
      _ = try await web.callAsyncJavaScript("await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));return true", arguments: [:], in: nil, contentWorld: .page)
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
    try await evaluate("window.inputSheet=document.styleSheets[0];window.initialRules=inputSheet.cssRules.length;inputSheet.insertRule('#target{color:#171714}',inputSheet.cssRules.length);window.inputRule=inputSheet.cssRules[inputSheet.cssRules.length-1]")
    try await wait { kind(160) == .scene }
    try await finishLayoutObservation()
    // A previously passive stylesheet gains ownership through its direct
    // property accessor, without a text/DOM/geometry event to refresh the map.
    try await evaluate("inputRule.style.touchAction='none'")
    if try await expectCSSTouchAction() { try await wait { kind(160) == .input } }
    try await finishLayoutObservation()
    try await evaluate("inputRule.style.all='initial'")
    if try await expectCSSTouchAction("auto") { try await wait { kind(160) == .scene } }
    try await evaluate("inputRule.style.cssText='color:#171714'")
    try await finishLayoutObservation()
    try await evaluate("inputRule.style['touch-action']='none'")
    if try await expectCSSTouchAction() { try await wait { kind(160) == .input } }
    try await finishLayoutObservation()
    try await evaluate("inputRule.selectorText='#unmounted'")
    try await wait { kind(160) == .scene }
    try await evaluate("inputRule.selectorText='#target'")
    try await wait { kind(160) == .input }
    try await evaluate("inputRule.style.touchAction='auto'")
    if try await expectCSSTouchAction("auto") { try await wait { kind(160) == .scene } }
    try await evaluate("inputRule.style.setProperty('--finger-owner','none');inputRule.style.setProperty('touch-action','var(--finger-owner)')")
    try await wait { kind(160) == .input }
    try await evaluate("inputRule.style.setProperty('--finger-owner','auto')")
    try await wait { kind(160) == .scene }
    try await evaluate(#"inputSheet.insertRule('body:has(#target[data-finger="owned"]) #target{touch-action:none}',inputSheet.cssRules.length);target.setAttribute('data-finger','owned')"#)
    try await wait { kind(160) == .input }
    try await evaluate("target.removeAttribute('data-finger')")
    try await wait { kind(160) == .scene }
    try await evaluate("inputSheet.insertRule('#target:dir(rtl){touch-action:none}',inputSheet.cssRules.length);target.setAttribute('dir','auto');target.firstChild.data='ltr'")
    try await wait { kind(160) == .scene }
    try await evaluate("target.firstChild.data='אבג'")
    try await wait { kind(160) == .input }
    try await evaluate("target.firstChild.data='ltr'")
    try await wait { kind(160) == .scene }
    try await evaluate("while(inputSheet.cssRules.length>initialRules)inputSheet.deleteRule(inputSheet.cssRules.length-1);target.style.cssText='position:absolute;left:130px;top:0;width:100px;height:80px';window.field=document.createElement('input');field.id='field';field.style.cssText='position:absolute;left:0;top:110px;width:60px;height:30px';document.body.append(field);inputSheet.insertRule('body:has(#field:focus) #target{touch-action:none}',inputSheet.cssRules.length)")
    try await wait { kind(160) == .scene }
    // WebKit's DOM activeElement can change in a browser that does not own
    // native focus. Give this mounted browser focus before exercising :focus.
    web.becomeFirstResponder()
    try await evaluate("field.focus()")
    if try await expectCSSTouchAction() { try await wait { kind(160) == .input } }
    try await evaluate("field.blur()")
    try await wait { kind(160) == .scene }
    try await evaluate("inputSheet.insertRule('#target:target{touch-action:none}',inputSheet.cssRules.length);location.hash='#target'")
    if try await expectCSSTouchAction() { try await wait { kind(160) == .input } }
    try await evaluate("location.hash='#other'")
    try await wait { kind(160) == .scene }
    try await evaluate("while(inputSheet.cssRules.length>initialRules)inputSheet.deleteRule(inputSheet.cssRules.length-1);inputSheet.insertRule('#target:dir(rtl){--owner:none}',inputSheet.cssRules.length);target.style.touchAction='var(--owner,auto)'")
    try await wait { kind(160) == .scene }
    try await evaluate("target.firstChild.data='אבג'")
    try await wait { kind(160) == .input }
    try await evaluate("target.firstChild.data='ltr'")
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

  func testDensePassiveDOMKeepsItsInputIndexAcrossAuthorFramePaintingAndReleasesItOnClose() async throws {
    let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .liveProgram)
    var ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources,
      onInteractionReady: { ready = $0 }, onState: { _, _ in false })
    coordinator.use(passiveSnapshot: false)
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    web.frame = .init(x: 0, y: 0, width: 400, height: 200)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), host = UIViewController()
    window.rootViewController = host; window.makeKeyAndVisible(); host.view.addSubview(web)
    defer {
      coordinator.invalidate(); lease.release(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
    }
    let passive = String(repeating: "<i>0</i>", count: 100_000)
    let script = #"""
      window.inputIndexProbe={visitedNodes:0,passiveStyleReads:0};
      window.installedCSSMutation=CSSStyleSheet.prototype.insertRule;
      for(const prototype of [Document.prototype,Element.prototype]) {
        const original=prototype.querySelectorAll;
        prototype.querySelectorAll=function(selector){
          const result=original.call(this,selector);
          if(selector==='*')inputIndexProbe.visitedNodes+=result.length;
          return result;
        };
      }
      const computed=window.getComputedStyle;
      window.getComputedStyle=function(node,...args){
        if(node.tagName==='I')inputIndexProbe.passiveStyleReads++;
        return computed.call(this,node,...args);
      };
      window.paintInputFrames=async()=>{
        const button=document.getElementById('control'), label=document.getElementById('count');
        for(let frame=0;frame<20;frame++)await new Promise(resolve=>requestAnimationFrame(()=>{
          for(let change=0;change<20;change++)label.firstChild.data=String(frame*20+change);
          button.style.background=frame%2?'navy':'blue';
          if(frame===10)document.getElementById('moving').style.left='130px';
          resolve();
        }));
        return {...inputIndexProbe};
      };
      document.getElementById('control').onclick=()=>{};
      notebook.ready(Promise.resolve());
      """#
    coordinator.load(.init(id: "dense-input-index", kind: .web,
      frame: .init(x: 0, y: 0, width: 400, height: 200), source: "Dense passive content around real controls",
      html: "<div hidden>" + passive + "</div><div id='moving' style='position:absolute;left:0;top:0'><button id='control' style='width:100px;height:80px'><output id='count'>0</output></button></div><a id='link' href='#destination' style='position:absolute;left:280px;top:0;width:80px;height:80px'><svg width='80' height='80'><rect width='80' height='80'/></svg></a>",
      javaScript: script), policy: .exact(scale: 1), in: web)
    let deadline = ContinuousClock.now + .seconds(10)
    while !ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(ready); guard ready else { return }
    let token = try XCTUnwrap(coordinator.loadToken)
    func kind(_ x: CGFloat) -> AgentWebFingerInput { coordinator.fingerInput(at: .init(x: x, y: 30), in: web.bounds.size) }
    XCTAssertEqual(kind(30), .input); XCTAssertEqual(kind(160), .scene); XCTAssertEqual(kind(300), .link)
    let beforeResult = try await web.evaluateJavaScript("({...inputIndexProbe})")
    let before = try XCTUnwrap(beforeResult as? [String: NSNumber])
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(before["passiveStyleReads"]).intValue, 100_000,
      "The first accepted DOM establishes input ownership for the entire real workload")
    let afterResult = try await web.callAsyncJavaScript("return await paintInputFrames()", arguments: [:], in: nil, contentWorld: .page)
    let after = try XCTUnwrap(afterResult as? [String: NSNumber])
    XCTAssertEqual(after["passiveStyleReads"], before["passiveStyleReads"],
      "Painting text and a control's colour must not read the styles of 100000 unrelated nodes again")
    XCTAssertLessThan(try XCTUnwrap(after["visitedNodes"]).intValue - XCTUnwrap(before["visitedNodes"]).intValue, 1_000,
      "Author frame painting measures the indexed controls, rather than walking the passive scene")
    XCTAssertEqual(kind(30), .scene); XCTAssertEqual(kind(160), .input); XCTAssertEqual(kind(300), .link)
    XCTAssertEqual(coordinator.loadToken, token, "Painting and moving the control retain its existing execution and focus owner")
    _ = try await web.evaluateJavaScript("document.getElementById('control').focus();true")
    let focused = try await web.evaluateJavaScript("document.activeElement.id")
    XCTAssertEqual(focused as? String, "control")
    // Detachment cancels this document's queued publication and releases its
    // strong node index even while WebKit retains the old JavaScript context.
    _ = try await web.evaluateJavaScript("document.getElementById('count').firstChild.data='final';notebookFingerInput.stop();true")
    let retired = try await web.evaluateJavaScript("(()=>{try{notebookFingerInput.start();return false}catch{return true}})()")
    XCTAssertEqual(retired as? Bool, true)
    let restored = try await web.evaluateJavaScript("CSSStyleSheet.prototype.insertRule!==installedCSSMutation")
    XCTAssertEqual(restored as? Bool, true, "Closing releases this document's CSS mutation subscriptions")
    coordinator.invalidate(); lease.release()
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
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
  override var window: UIWindow? { sourceWindow }
  override var view: UIView? { sourceView }
  override func location(in view: UIView?) -> CGPoint { view?.convert(point, from: sourceWindow) ?? point }
}
