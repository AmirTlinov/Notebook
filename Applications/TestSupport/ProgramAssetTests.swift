import Foundation
import CryptoKit
import NotebookCore
import WebKit
import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Notebook

@MainActor
final class ProgramAssetTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let store: NotebookStore
    let package: NotebookProgramPackage
    let hash: String
    func close() { try? FileManager.default.removeItem(at: root) }
  }
  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let script = """
      import {answer} from './module.js';
      const result=(async()=>{
        const font=await new FontFace('PackageFixture',"url('./font.woff2')").load();document.fonts.add(font);
        const data=await (await fetch('./data.json')).json();
        const response=await fetch('./large.bin',{headers:{Range:'bytes=310378494-310378497'}});
        const bytes=[...new Uint8Array(await response.arrayBuffer())];
        const worker=await new Promise((resolve,reject)=>{const w=new Worker(new URL('./worker.js',import.meta.url));
          w.onmessage=e=>{w.terminate();resolve(e.data)};w.onerror=e=>reject(Error('worker: '+e.message));w.postMessage(answer)});
        await document.getElementById('picture').decode();
        const audio=document.getElementById('audio');
        if(!audio.readyState)await new Promise((resolve,reject)=>{audio.onloadedmetadata=resolve;audio.onerror=()=>reject(Error('audio: '+audio.error?.message));audio.load()});
        const externalDenied=await new Promise(resolve=>{
          const timer=setTimeout(()=>resolve(false),1000);
          addEventListener('securitypolicyviolation',event=>{if(event.effectiveDirective==='connect-src'&&event.blockedURI.startsWith('https://example.com')){
            clearTimeout(timer);resolve(true)}},{once:true});
          fetch('https://example.com/notebook-forbidden').catch(()=>{});
        });
        let parentIsolated=false;if(parent!==window){try{parent.document.body}catch{parentIsolated=true}}
        window.packageResult={answer,data:data.value,worker,bytes,status:response.status,parentIsolated,
          image:document.getElementById('picture').naturalWidth,css:getComputedStyle(document.getElementById('value')).color,
          duration:audio.duration,font:font.status,externalDenied,restored:notebook.state};
        document.getElementById('value').textContent='Ready '+answer;
        return window.packageResult;
      })();
      result.catch(error=>window.packageError=String(error));notebook.ready(result);
      notebook.lifecycle({checkpoint:()=>({...notebook.state,assetAnswer:window.packageResult.answer,parentIsolated:window.packageResult.parentIsolated})});
      """
    let files: [String: Data] = [
      "main.js": Data(("/*" + String(repeating: " ", count: 1_048_577) + "*/\n" + script).utf8),
      "view.html": Data(("<!--" + String(repeating: " ", count: 1_048_577) + "--><div id='value'>Loading</div><img id='picture' src='./image.svg'><audio id='audio' preload='metadata' src='./sound.wav'></audio>").utf8),
      "style.css": Data("#value{color:rgb(12,34,56)}".utf8),
      "module.js": Data("export const answer=42".utf8),
      "worker.js": Data("onmessage=async e=>{const events=[];addEventListener('securitypolicyviolation',event=>events.push(event.effectiveDirective));let denied=false,external;try{external=await(await fetch('data:text/plain,forbidden')).text()}catch(error){denied=true;external=String(error)};let local;try{local=await(await fetch(new URL('./data.json',location.href))).json()}catch(error){local=String(error)};postMessage({answer:denied?e.data+1:-1,external,local,events})}".utf8),
      "data.json": Data("{\"value\":44}".utf8),
      "image.svg": Data("<svg xmlns='http://www.w3.org/2000/svg' width='7' height='5'><rect width='7' height='5' fill='green'/></svg>".utf8),
      "sound.wav": wav(),
      "font.woff2": try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "mjx-ncm-zero", withExtension: "woff2")))
    ]
    func part(_ data: Data) throws -> NotebookProgramPackage.Part {
      let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      try store.stageBlob(data: data, expectedHash: hash)
      return .init(sha256: hash, byteCount: data.count)
    }
    var entries = try files.map { path, data in NotebookProgramPackage.File(path: path,
      mimeType: NotebookProgramPackage.mimeType(for: path), byteCount: Int64(data.count), parts: [try part(data)]) }
    // A 300 MiB logical asset; two unique 4 MiB parts, not a 300 MiB transfer benchmark.
    let a = try part(Data(repeating: 29, count: NotebookProgramPackage.partBytes))
    let b = try part(Data(repeating: 31, count: NotebookProgramPackage.partBytes))
    entries.append(.init(path: "large.bin", mimeType: "application/octet-stream", byteCount: 300 * 1_048_576,
      parts: Array(repeating: a, count: 74) + [b]))
    let package = NotebookProgramPackage(html: "view.html", css: "style.css", javaScript: "main.js", files: entries.sorted { $0.path < $1.path })
    return Fixture(root: root, store: store, package: package, hash: try store.stageProgramPackage(package))
  }
  func testSevenScientificRecipesCheckpointTheirExplicitModelThroughTheExistingOwner() async throws {
    let bundle = Bundle(for: Self.self)
    func source(_ name: String, _ ext: String) throws -> String {
      try String(contentsOf: XCTUnwrap(bundle.url(forResource: name, withExtension: ext, subdirectory: "science")), encoding: .utf8)
    }
    let shared = try source("models", "js") + "\n" + source("runtime", "js"), css = try source("common", "css")
    for name in ["sound", "gears", "linear", "gaussian", "astar", "tensor", "probability"] {
      let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .input)
      var ready = false, commits = 0
      let owner = AgentWebCoordinator(lease: lease, resources: resources, onInteractionReady: { ready = $0 }, onState: { _ in commits += 1; return true })
      let web = AgentWebCoordinator.makeWebView(coordinator: owner), close = try mount(web)
      defer { owner.invalidate(); lease.release(); close() }
      owner.load(.init(id: name, kind: .web, frame: .init(x: 0, y: 0, width: 760, height: 960), source: "",
        html: try source(name, "html"), css: css, javaScript: try shared + "\n" + source(name, "js"),
        state: .object(["phase": .number(0.25)])), policy: .exact(scale: 1), in: web)
      try await wait { ready || owner.snapshotFailure != nil }; XCTAssertTrue(ready, name + String(describing: owner.snapshotFailure))
      XCTAssertNil(owner.snapshotFailure, name)
      let hasPhase = try await web.evaluateJavaScript("Boolean(document.getElementById('phase'))") as? Bool ?? false
      var expectedPhase = 0.25
      if hasPhase {
        let accepted = try await web.evaluateJavaScript("document.getElementById('phase').value='0.625';document.getElementById('phase').dispatchEvent(new Event('input',{bubbles:true}));Number(document.getElementById('phase').value)")
        expectedPhase = try XCTUnwrap(accepted as? Double)
      }
      let before = commits
      let checkpoint = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
      XCTAssertEqual(checkpoint["phase"], .number(expectedPhase), name)
      XCTAssertEqual(commits, before, "The native checkpoint owns durable admission, not another optimistic commit: " + name)
      let repeated = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
      XCTAssertEqual(repeated, checkpoint, name)
      _ = try await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web)
      owner.invalidate(); lease.release(); try await wait { resources.activeWebSurfaceCount == 0 }
    }
  }

  private func compiledFixture(_ name: String = "compiled-program") throws -> Fixture {
    struct Compiled: Decodable { let package: NotebookProgramPackage; let files: [String: String]; let packageHash: String
      let binaryFiles: [String: String]?; let webResources: [String: String]? }
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
    let value = try JSONDecoder().decode(Compiled.self, from: Data(contentsOf: url))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    for file in value.package.files {
      XCTAssertEqual(file.parts.count, 1)
      let bytes: Data
      if let source = value.files[file.path] { bytes = Data(source.utf8) }
      else if let source = value.binaryFiles?[file.path] { bytes = try XCTUnwrap(Data(base64Encoded: source)) }
      else { bytes = try Data(contentsOf: XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("WebResources/" + XCTUnwrap(value.webResources?[file.path]))) }
      try store.stageBlob(data: bytes, expectedHash: file.parts[0].sha256)
    }
    let hash = try store.stageProgramPackage(value.package); XCTAssertEqual(hash, value.packageHash)
    return Fixture(root: root, store: store, package: value.package, hash: hash)
  }

  func testCompiledTypeScriptPackageRunsOfflineAndCheckpointsInBothExistingOwners() async throws {
    let f = try compiledFixture(); defer { f.close() }
    let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let agent = AgentWebCoordinator(lease: lease, resources: resources, onInteractionReady: { ready = $0 }, onState: { _ in true })
    agent.programStore = f.store
    let web = AgentWebCoordinator.makeWebView(coordinator: agent), close = try mount(web)
    defer { agent.invalidate(); lease.release(); close() }
    agent.load(.init(id: "compiled", kind: .web, frame: .init(x: 0, y: 0, width: 600, height: 600), source: "", html: "", programPackage: f.hash),
      policy: .exact(scale: 1), in: web)
    try await wait { ready || agent.snapshotFailure != nil }; XCTAssertTrue(ready); XCTAssertNil(agent.snapshotFailure)
    let initial = try await web.evaluateJavaScript("document.querySelector('#value').textContent") as? String
    XCTAssertEqual(initial, "2² = 4")
    _ = try await web.evaluateJavaScript("document.querySelector('button').click()")
    var result: String?
    let deadline = ContinuousClock.now + .seconds(5)
    repeat {
      result = try await web.evaluateJavaScript("document.querySelector('#value').textContent") as? String
      if result != "3² = 9" { try await Task.sleep(for: .milliseconds(10)) }
    } while result != "3² = 9" && .now < deadline
    XCTAssertEqual(result, "3² = 9")
    agent.invalidate(); lease.release()

    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "compiled", html: "", programPackage: f.hash, height: 600)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let owner = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    owner.programStore = f.store
    let host = DocumentWebHost(), closeHost = try mount(host)
    defer { owner.invalidate(); closeHost() }
    owner.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    owner.mount(in: host, physicalSize: .init(width: 595, height: 842), isInteractive: true, priority: .currentPage)
    try await wait { owner.hasCanonicalPixels || owner.acquisitionError != nil }; XCTAssertTrue(owner.hasCanonicalPixels); XCTAssertNil(owner.acquisitionError)
    var checkpoint: JSONValue?
    owner.onStateCheckpoint = { _, value, _, _ in checkpoint = value; return nil }
    let accepted = await owner.checkpointPrograms(resume: true)
    XCTAssertTrue(accepted); XCTAssertEqual(checkpoint?["x"], .number(2))
  }

  func testDenseSignalPackageUsesOfflinePlotMathJaxRangesAndLatestCheckpoint() async throws {
    var phase = "package import"
    do {
    let f = try compiledFixture("signal-program"); defer { f.close() }
    phase = "web acquisition"
    let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let owner = AgentWebCoordinator(lease: lease, resources: resources, onInteractionReady: { ready = $0 }, onState: { _ in true })
    owner.programStore = f.store
    let web = AgentWebCoordinator.makeWebView(coordinator: owner), close = try mount(web)
    defer { owner.invalidate(); lease.release(); close() }
    web.configuration.userContentController.addUserScript(WKUserScript(source: """
      (()=>{ const original=window.fetch;window.fixtureFetches=[];
        window.fetch=(url,options)=>{window.fixtureFetches.push({url:String(url),range:new Headers(options?.headers).get('Range')});return original(url,options)};
      })();
      """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    phase = "initial ready"
    owner.load(.init(id: "signal", kind: .web, frame: .init(x: 0, y: 0, width: 760, height: 1050), source: "", html: "", programPackage: f.hash),
      policy: .exact(scale: 1), in: web)
    try await wait { ready || owner.snapshotFailure != nil }; XCTAssertTrue(ready); XCTAssertNil(owner.snapshotFailure)
    phase = "first interaction"
    _ = try await web.evaluateJavaScript("document.getElementById('event').click()")
    let deadline = ContinuousClock.now + .seconds(8)
    var drawn = false
    repeat {
      drawn = try await web.evaluateJavaScript("document.querySelectorAll('#detail circle').length===50 && document.querySelector('#formula').textContent.includes('2.228')") as? Bool ?? false
      if !drawn { try await Task.sleep(for: .milliseconds(10)) }
    } while !drawn && .now < deadline
    XCTAssertTrue(drawn, "Plot and isolated MathJax must display the same original impulse samples")
    let selected = try await web.evaluateJavaScript("document.getElementById('span').value") as? String
    XCTAssertEqual(selected, "0.05")
    phase = "checkpoint and resume"
    let checkpoint = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
    XCTAssertEqual(checkpoint["center"], .number(61.337)); XCTAssertEqual(checkpoint["span"], .number(0.05))
    _ = try await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web)
    // A width change redraws the exact same samples, without fetching the source again.
    let before = try await web.evaluateJavaScript("window.fixtureFetches.filter(e=>e.url.endsWith('.bin')).length") as? Int
    web.frame.size.width = 420
    _ = try await web.evaluateJavaScript("dispatchEvent(new Event('resize'))")
    try await Task.sleep(for: .milliseconds(100))
    let after = try await web.evaluateJavaScript("window.fixtureFetches.filter(e=>e.url.endsWith('.bin')).length") as? Int
    XCTAssertGreaterThan(try XCTUnwrap(before), 1, "Observe real fetch calls: custom-scheme resources do not appear in WebKit Resource Timing")
    XCTAssertEqual(before, after)
    let exactRange = try await web.evaluateJavaScript("window.fixtureFetches.some(e=>e.range==='bytes=245248-245447')") as? Bool
    XCTAssertEqual(exactRange, true, "The impulse detail reads 200 bytes, not the entire 400 kB source")
    let marks = try await web.evaluateJavaScript("document.querySelectorAll('#detail circle').length") as? Int
    XCTAssertEqual(marks, 50)
    phase = "external state"
    _ = try await web.evaluateJavaScript("notebookProgram.apply({center:20,span:1}).catch(e=>{window.externalStateError=String(e)});null")
    var applied = false
    let externalDeadline = ContinuousClock.now + .seconds(5)
    repeat {
      applied = try await web.evaluateJavaScript("document.getElementById('center').value==='20' && document.getElementById('detail-caption').textContent.startsWith('19,500')") as? Bool ?? false
      if !applied { try await Task.sleep(for: .milliseconds(10)) }
    } while !applied && .now < externalDeadline
    XCTAssertTrue(applied, "External state uses the same selection/render path, without a local commit")
    let externalCheckpoint = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
    XCTAssertEqual(externalCheckpoint["center"], .number(20)); XCTAssertEqual(externalCheckpoint["span"], .number(1))
    _ = try await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web)
    phase = "dynamic MathJax font"
    // Non-base glyphs really load from the package, not the parent shell or a CDN.
    _ = try await web.evaluateJavaScript("window.extraFormulaDone=false;MathJax.tex2svgPromise('\\\\mathscr{F}',{display:false}).then(node=>{document.getElementById('formula').replaceChildren(node);window.extraFormulaDone=true},e=>{window.extraFormulaError=String(e)});null")
    var extra = false
    let fontDeadline = ContinuousClock.now + .seconds(5)
    repeat {
      extra = try await web.evaluateJavaScript("window.extraFormulaDone") as? Bool ?? false
      if !extra { try await Task.sleep(for: .milliseconds(10)) }
    } while !extra && .now < fontDeadline
    let error = try await web.evaluateJavaScript("window.extraFormulaError || ''") as? String
    XCTAssertTrue(extra, error ?? "MathJax dynamic glyph did not load")
    let local = try await web.evaluateJavaScript("[...document.scripts].filter(s=>s.src).every(s=>new URL(s.src).protocol===location.protocol && new URL(s.src).host===location.host)") as? Bool
    XCTAssertEqual(local, true)
    } catch { XCTFail("Dense signal at \(phase): \(error)") }
  }

  private func wav() -> Data {
    var result = Data()
    func string(_ s: String) { result.append(Data(s.utf8)) }
    func int(_ n: UInt32, _ bytes: Int) { for shift in 0..<bytes { result.append(UInt8(truncatingIfNeeded: n >> (8 * shift))) } }
    string("RIFF"); int(36 + 8000, 4); string("WAVEfmt "); int(16, 4); int(1, 2); int(1, 2)
    int(8000, 4); int(8000, 4); int(1, 2); int(8, 2); string("data"); int(8000, 4)
    result.append(Data(repeating: 128, count: 8000)); return result
  }
  private final class Request: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: HTTPURLResponse?
    var bytes = Data(), sizes: [Int] = [], error: Error?, finished = false
    var onData: () -> Void = { }
    init(_ url: URL, range: String? = nil, method: String = "GET") {
      var request = URLRequest(url: url); request.httpMethod = method
      request.setValue(range, forHTTPHeaderField: "Range"); self.request = request
    }
    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { bytes.append(data); sizes.append(data.count); onData() }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
  }
  private func wait(_ condition: () -> Bool, seconds: Int = 12) async throws {
    let end = ContinuousClock.now + .seconds(seconds)
    while !condition(), .now < end { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "Expected the native owner to finish within its existing bounded path")
  }
  private final class UnrestrictedWorkerProbe: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
      let url = task.request.url!, worker = url.path == "/probe.js"
      let source = worker
        ? "fetch('data:text/plain,allowed').then(r=>r.text()).then(postMessage).catch(e=>postMessage(String(e)))"
        : "<script>new Worker('probe.js').onmessage=e=>window.probe=e.data;</script>"
      task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": worker ? "text/javascript" : "text/html", "Access-Control-Allow-Origin": "*"])!)
      task.didReceive(Data(source.utf8)); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { }
  }
  func testUnrestrictedControlConfirmsWorkerDataFetchIsNotAFalsePositiveFromCORSOrNetwork() async throws {
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(UnrestrictedWorkerProbe(), forURLScheme: NotebookProgramAssets.scheme)
    let web = WKWebView(frame: .zero, configuration: config), close = try mount(web)
    defer { web.stopLoading(); close() }
    web.load(URLRequest(url: URL(string: "notebook-program://control/")!))
    var result: String?
    let end = ContinuousClock.now + .seconds(5)
    while result == nil, .now < end {
      result = try? await web.evaluateJavaScript("window.probe") as? String
      if result == nil { try await Task.sleep(for: .milliseconds(20)) }
    }
    XCTAssertEqual(result, "allowed", "Production worker data: denial must be CSP, not an unsupported Fetch scheme")
  }

  func testRangesNamespacesAndRevocationUseBoundedReads() async throws {
    let f = try fixture(); defer { f.close() }
    let assets = NotebookProgramAssets(), web = WKWebView()
    let url = assets.register(store: f.store, package: f.package) { _ in .init(before: "<head></head><body>", after: "</body>") }
    let file = url.appendingPathComponent("large.bin")
    let range = Request(file, range: "bytes=310378494-310378497")
    assets.webView(web, start: range); try await wait { range.finished || range.error != nil }
    XCTAssertNil(range.error); XCTAssertEqual(range.bytes, Data([29,29,31,31])); XCTAssertEqual(range.response?.statusCode, 206)
    XCTAssertEqual(range.response?.value(forHTTPHeaderField: "Content-Range"), "bytes 310378494-310378497/314572800")
    for (header, code) in [("bytes=314572800-",416), ("bytes=0-1,4-5",416), ("bytes=-2",206)] {
      let task = Request(file, range: header); assets.webView(web, start: task); try await wait { task.finished || task.error != nil }
      XCTAssertEqual(task.response?.statusCode, code); XCTAssertEqual(task.bytes.count, code == 206 ? 2 : 0)
    }
    let head = Request(file, method: "HEAD"); assets.webView(web, start: head); try await wait { head.finished }
    XCTAssertEqual(head.response?.value(forHTTPHeaderField: "Content-Length"), "314572800"); XCTAssertTrue(head.bytes.isEmpty)
    for denied in [URL(string: "notebook-program://foreign/large.bin")!, url.appendingPathComponent(f.hash),
      URL(string: url.absoluteString + "%6dain.js")!, URL(string: url.absoluteString + "main.js?x=1")!] {
      let task = Request(denied); assets.webView(web, start: task); XCTAssertNotNil(task.error)
    }
    let cancelled = Request(file)
    cancelled.onData = { [weak cancelled] in if let cancelled { assets.webView(web, stop: cancelled) } }
    assets.webView(web, start: cancelled); try await wait { !cancelled.sizes.isEmpty }
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(cancelled.sizes, [1_048_576]); XCTAssertFalse(cancelled.finished); XCTAssertEqual(assets.activeReadCount, 0)
    let revoked = Request(file); revoked.onData = { assets.revoke(url) }
    assets.webView(web, start: revoked); try await wait { !revoked.sizes.isEmpty }
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(revoked.sizes, [1_048_576]); XCTAssertFalse(revoked.finished); XCTAssertEqual(assets.scopeCount, 0)
    let after = Request(file); assets.webView(web, start: after); XCTAssertNotNil(after.error)
  }

  private func mount(_ view: PlatformView) throws -> () -> Void {
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first { $0.isKeyWindow }
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; window.makeKeyAndVisible(); controller.view.addSubview(view)
    view.frame = CGRect(x: 20, y: 20, width: 600, height: 800)
    return { view.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    #else
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 600, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
    return { window.orderOut(nil); window.close() }
    #endif
  }
  #if os(iOS)
  private typealias PlatformView = UIView
  #else
  private typealias PlatformView = NSView
  #endif

  private func assertProgram(_ web: WKWebView) async throws {
    let value = try await web.evaluateJavaScript("JSON.stringify(window.packageResult || {error:window.packageError})") as? String
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value).utf8)) as? [String: Any])
    XCTAssertEqual(object["answer"] as? Int, 42, value ?? ""); XCTAssertEqual((object["worker"] as? [String: Any])?["answer"] as? Int, 43, value ?? "")
    let worker = try XCTUnwrap(object["worker"] as? [String: Any])
    XCTAssertEqual((worker["local"] as? [String: Any])?["value"] as? Int, 44, value ?? "")
    XCTAssertEqual(object["data"] as? Int, 44); XCTAssertEqual(object["bytes"] as? [Int], [29,29,31,31])
    XCTAssertEqual(object["image"] as? Int, 7); XCTAssertEqual(object["status"] as? Int, 206)
    XCTAssertEqual(object["css"] as? String, "rgb(12, 34, 56)"); XCTAssertEqual(object["externalDenied"] as? Bool, true)
    XCTAssertEqual(object["duration"] as? Double, 1); XCTAssertEqual(object["font"] as? String, "loaded")
  }

  func testColdBoardPackageRunsModulesWorkerImagesMediaAndRangesOffline() async throws {
    let f = try fixture(); defer { f.close() }
    for _ in 0..<2 {
      let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .input)
      var ready = false
      let coordinator = AgentWebCoordinator(lease: lease, resources: resources, onInteractionReady: { ready = $0 }, onState: { _ in false })
      // Reopening SQLite, not reusing an in-memory namespace, models a cold owner.
      coordinator.programStore = NotebookStore(root: f.root)
      let web = AgentWebCoordinator.makeWebView(coordinator: coordinator), close = try mount(web)
      defer { coordinator.invalidate(); lease.release(); close() }
      let source = AgentElement(id: "packaged", kind: .web, frame: .init(x: 0, y: 0, width: 600, height: 800), source: "", html: "", programPackage: f.hash)
      coordinator.load(source, policy: .exact(scale: 1), in: web)
      try await wait { ready || coordinator.snapshotFailure != nil }
      let diagnostic = try? await web.evaluateJavaScript("JSON.stringify({url:location.href,error:window.packageError,result:window.packageResult})")
      XCTAssertTrue(ready, String(describing: diagnostic)); XCTAssertNil(coordinator.snapshotFailure)
      try await assertProgram(web)
      XCTAssertEqual(coordinator.programAssets.scopeCount, 1)
      coordinator.invalidate(); XCTAssertEqual(coordinator.programAssets.scopeCount, 0); XCTAssertEqual(coordinator.programAssets.activeReadCount, 0)
    }
  }

  func testPassiveRasterPreparationReadsTheSamePackageWithoutKeepingAnExecutor() async throws {
    let f = try fixture(); defer { f.close() }
    let resources = SceneRenderResources()
    let source = AgentElement(id: "passive-package", kind: .web, frame: .init(x: 0, y: 0, width: 600, height: 300),
      source: "", html: "", programPackage: f.hash)
    let raster = try await resources.prepareRaster(source, requestedScale: 1, programStore: f.store)
    defer { raster.release() }
    #if os(iOS)
    let pixels = try XCTUnwrap(raster.image.cgImage)
    #else
    let pixels = try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #endif
    XCTAssertEqual(pixels.width, 600); XCTAssertEqual(pixels.height, 300); XCTAssertEqual(raster.pixelScale, 1)
    try await wait { resources.activeWebSurfaceCount == 0 }
    XCTAssertNotNil(resources.image(for: source, minimumScale: 1))
  }

  #if os(iOS)
  func testIPadDocumentBlockPackageUsesItsNativeProgramOwner() async throws {
    let f = try fixture(); defer { f.close() }
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "asset", html: "", programPackage: f.hash, height: 180)])
    let block = try XCTUnwrap(document.blocks.first), resources = SceneRenderResources()
    let runtime = DocumentBlockRuntime(documentID: document.id, block: block, sourceVersion: document.sourceVersion(blockID: block.id),
      value: .object(["restored": .number(7)]), stateVersion: nil, width: 600, resources: resources, programStore: f.store)
    let container = UIView(), close = try mount(container)
    defer { runtime.stop(); close() }
    runtime.onMount = { web, size in container.addSubview(web); web.frame = .init(origin: .zero, size: size) }
    runtime.start(priority: .input)
    try await wait { runtime.ready || runtime.failure != nil }
    XCTAssertTrue(runtime.ready, String(describing: runtime.failure)); XCTAssertNil(runtime.failure)
    let web = try XCTUnwrap(runtime.webView); try await assertProgram(web)
    let restored = try await web.evaluateJavaScript("packageResult.restored.restored") as? Int
    XCTAssertEqual(restored, 7)
    runtime.stop(); XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }
  #endif

  func testDocumentIframePackageUsesExistingParentStateAndLifecycleOwner() async throws {
    let f = try fixture(); defer { f.close() }
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "asset", html: "", programPackage: f.hash, height: 180)])
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources()
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    coordinator.programStore = f.store
    let host = DocumentWebHost(), close = try mount(host)
    defer { coordinator.invalidate(); close() }
    coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    coordinator.mount(in: host, physicalSize: .init(width: 595, height: 842), isInteractive: true, priority: .currentPage)
    try await wait { coordinator.hasCanonicalPixels || coordinator.acquisitionError != nil }
    let web = try XCTUnwrap(coordinator.webView, String(describing: coordinator.acquisitionError))
    let receipt = try await web.evaluateJavaScript("JSON.stringify(notebookRenderer.pageReceipt())")
    XCTAssertTrue(coordinator.hasCanonicalPixels, String(describing: receipt)); XCTAssertNil(coordinator.acquisitionError)
    XCTAssertEqual(coordinator.programAssets.scopeCount, 1)
    // The sandbox prevents the parent from reading child DOM; readiness comes
    // from the authenticated existing iframe bridge, not a cross-origin bypass.
    let started = try await web.evaluateJavaScript("notebookRenderer.pageReceipt().programs[0].readiness") as? String
    XCTAssertEqual(started, "declared", String(describing: receipt))
    var checkpoint: JSONValue?
    coordinator.onStateCheckpoint = { _, value, _, _ in checkpoint = value; return nil }
    let accepted = await coordinator.checkpointPrograms(resume: true)
    XCTAssertTrue(accepted); XCTAssertEqual(checkpoint?["assetAnswer"], .number(42)); XCTAssertEqual(checkpoint?["parentIsolated"], .bool(true))
    let iframeURL = try await web.evaluateJavaScript("document.querySelector('iframe').src") as? String
    var changed = document
    _ = changed.replaceContent(blocks: [.markdown(id: "other", source: "Independent text")] + document.blocks, actor: UUID())
    coordinator.update(document: changed, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    try await wait { coordinator.hasCanonicalPixels || coordinator.acquisitionError != nil }
    XCTAssertTrue(coordinator.hasCanonicalPixels, String(describing: coordinator.acquisitionError))
    let afterURL = try await web.evaluateJavaScript("document.querySelector('iframe').src") as? String
    XCTAssertEqual(afterURL, iframeURL, "Independent text retains the same capability and running program")
    XCTAssertEqual(coordinator.programAssets.scopeCount, 1)
    _ = changed.replaceContent(blocks: [.interactive(id: "asset", html: "<strong>Inline replacement</strong>")], actor: UUID())
    coordinator.update(document: changed, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    XCTAssertEqual(coordinator.programAssets.scopeCount, 0, "Replacing package source revokes its namespace immediately")
    try await wait { coordinator.hasCanonicalPixels || coordinator.acquisitionError != nil }
    XCTAssertTrue(coordinator.hasCanonicalPixels, String(describing: coordinator.acquisitionError))
    let inline = try await web.evaluateJavaScript("document.querySelector('iframe').srcdoc.includes('Inline replacement')") as? Bool
    XCTAssertEqual(inline, true, "The same document adapter also owns the replacement inline program")
    coordinator.invalidate(); XCTAssertEqual(coordinator.programAssets.scopeCount, 0); XCTAssertEqual(coordinator.programAssets.activeReadCount, 0)
  }
}
