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
  func testSixInlineScientificRecipesCheckpointTheirExplicitModelThroughTheExistingOwner() async throws {
    let bundle = Bundle(for: Self.self)
    func source(_ name: String, _ ext: String) throws -> String {
      try String(contentsOf: XCTUnwrap(bundle.url(forResource: name, withExtension: ext, subdirectory: "science")), encoding: .utf8)
    }
    let shared = try source("models", "js") + "\n" + source("runtime", "js"), css = try source("common", "css")
    for name in ["sound", "linear", "gaussian", "astar", "tensor", "probability"] {
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
      let binaryFiles: [String: String]?; let webResources: [String: String]?; let bundleResources: [String: String]? }
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
    let value = try JSONDecoder().decode(Compiled.self, from: Data(contentsOf: url))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    for file in value.package.files {
      let bytes: Data
      if let source = value.files[file.path] { bytes = Data(source.utf8) }
      else if let source = value.binaryFiles?[file.path] { bytes = try XCTUnwrap(Data(base64Encoded: source)) }
      else if let resource = value.bundleResources?[file.path] { bytes = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent(resource)) }
      else { bytes = try Data(contentsOf: XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("WebResources/" + XCTUnwrap(value.webResources?[file.path]))) }
      var offset = 0
      for part in file.parts {
        try store.stageBlob(data: bytes.subdata(in: offset..<(offset + part.byteCount)), expectedHash: part.sha256)
        offset += part.byteCount
      }
      XCTAssertEqual(offset, bytes.count)
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
    let owner = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    owner.programStore = f.store
    let host = DocumentWebHost(), closeHost = try mount(host)
    defer { owner.invalidate(); closeHost() }
    owner.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
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

  func testThreeDimensionalPackageOwnsOfflineResourcesContextRecoveryAndCheckpoint() async throws {
    let f = try compiledFixture("gears-program"); defer { f.close() }
    let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let owner = AgentWebCoordinator(lease: lease, resources: resources, onInteractionReady: { ready = $0 }, onState: { _ in true })
    owner.programStore = f.store
    let web = AgentWebCoordinator.makeWebView(coordinator: owner), close = try mount(web)
    defer { owner.invalidate(); lease.release(); close() }
    web.configuration.userContentController.addUserScript(WKUserScript(source: """
      (()=>{window.gearProbe={draws:0,buffers:0,textures:0,contexts:0,fetches:[]};
      const get=HTMLCanvasElement.prototype.getContext,seen=new WeakSet();
      HTMLCanvasElement.prototype.getContext=function(...args){const gl=get.apply(this,args);
        if(gl&&args[0]==='webgl2'&&!seen.has(gl)){seen.add(gl);gearProbe.contexts++;
          for(const kind of ['Buffer','Texture']){const created=new Set(),create=gl['create'+kind],remove=gl['delete'+kind],key=kind.toLowerCase()+'s';
            gl['create'+kind]=function(...args){const r=create.apply(this,args);if(r)created.add(r);gearProbe[key]=created.size;return r};
            gl['delete'+kind]=function(r){created.delete(r);gearProbe[key]=created.size;return remove.call(this,r)};}
          for(const name of ['drawElements','drawArrays']){const fn=gl[name];gl[name]=function(...args){gearProbe.draws++;return fn.apply(this,args)}}
        }return gl;};
      const fetch=window.fetch;window.fetch=(url,options)=>{gearProbe.fetches.push(String(url));return fetch(url,options)};
      })();
      """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    owner.load(.init(id: "gears", kind: .web, frame: .init(x: 0, y: 0, width: 760, height: 1050), source: "", html: "", programPackage: f.hash),
      policy: .exact(scale: 1), in: web)
    try await wait { ready || owner.snapshotFailure != nil }; XCTAssertTrue(ready); XCTAssertNil(owner.snapshotFailure)
    func js(_ source: String) async throws -> Any? { try await web.evaluateJavaScript(source) }
    func until(_ source: String) async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while .now < deadline {
        if try await js(source) as? Bool == true { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      let details = try await js("JSON.stringify({probe:gearProbe,hidden:document.hidden,status:document.getElementById('model-status').textContent,error:document.getElementById('model-error').textContent})")
      XCTFail("3D condition did not settle: " + source + " · " + String(describing: details))
    }
    try await until("gearProbe.draws>0 && document.getElementById('poster').hidden")
    let buffers = try await js("gearProbe.buffers") as? Int
    XCTAssertGreaterThan(buffers ?? 0, 100)
    let idle = try await js("gearProbe.draws") as? Int
    try await Task.sleep(for: .milliseconds(200))
    let idleAfter = try await js("gearProbe.draws") as? Int; XCTAssertEqual(idle, idleAfter, "The static scene owns no ongoing animation loop")
    _ = try await js("document.querySelector('[data-part=output]').click();document.getElementById('reveal').value='.8';document.getElementById('reveal').dispatchEvent(new Event('input'));document.getElementById('front').click();null")
    let checkpoint = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
    XCTAssertEqual(checkpoint["selected"], .string("output")); XCTAssertEqual(checkpoint["reveal"], .number(0.8))
    XCTAssertNotNil(checkpoint["camera"])
    _ = try await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web)
    _ = try await js("window.lose=document.getElementById('gear-canvas').getContext('webgl2').getExtension('WEBGL_lose_context');lose.loseContext();null")
    try await until("document.getElementById('model-error').textContent.includes('потерян')")
    _ = try await js("lose.restoreContext();null")
    try await until("document.getElementById('model-error').hidden && !document.getElementById('play').disabled")
    #if os(iOS)
    _ = try await js("document.getElementById('play').click();null")
    try await Task.sleep(for: .milliseconds(160))
    #else
    // The Mac unit host can remain occluded. Static render/checkpoint must work
    // there, but a hidden display clock is not evidence of animated FPS.
    _ = try await js("document.getElementById('phase').value='.42';document.getElementById('phase').dispatchEvent(new Event('input'));null")
    #endif
    let playing = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
    XCTAssertNotEqual(playing["phase"], checkpoint["phase"])
    XCTAssertEqual(playing["selected"], .string("output")); XCTAssertEqual(playing["camera"], checkpoint["camera"])
    _ = try await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web)
    let fetches = try await js("gearProbe.fetches.length") as? Int
    web.frame.size.width = 420
    try await Task.sleep(for: .milliseconds(150))
    let afterResize = try await js("gearProbe.fetches.length") as? Int; XCTAssertEqual(fetches, afterResize)
    let contexts = try await js("gearProbe.contexts") as? Int; XCTAssertEqual(contexts, 1, "Loss/recovery/resize retain one renderer context")
    _ = try await NotebookProgramBridge.lifecycle("dispose", controller: "notebookProgram", in: web)
    let disposedBuffers = try await js("gearProbe.buffers") as? Int; XCTAssertEqual(disposedBuffers, 0, "Every loaded geometry and field buffer is released")
    owner.invalidate(); lease.release()

    // The document owner loads the identical package, not a second 3D renderer implementation.
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "gears", html: "", programPackage: f.hash,
      initialState: checkpoint, height: 900)])
    let journal = DocumentStateJournal(id: document.id, actor: UUID())
    let docOwner = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    docOwner.programStore = f.store
    docOwner.update(document: document, state: journal, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    let host = DocumentWebHost(), closeHost = try mount(host); defer { docOwner.invalidate(); closeHost() }
    docOwner.mount(in: host, physicalSize: .init(width: 595, height: 842), isInteractive: true, priority: .currentPage)
    try await wait { docOwner.hasCanonicalPixels || docOwner.acquisitionError != nil }
    XCTAssertTrue(docOwner.hasCanonicalPixels); XCTAssertNil(docOwner.acquisitionError)
    var saved: JSONValue?
    docOwner.onStateCheckpoint = { _, value, _, _ in saved = value; return nil }
    let accepted = await docOwner.checkpointPrograms(resume: true)
    XCTAssertTrue(accepted); XCTAssertEqual(saved?["selected"], .string("output")); XCTAssertEqual(saved?["reveal"], .number(0.8))
  }

  func testThreeDimensionalFailuresRetryAndDisposalStayLocal() async throws {
    let f = try compiledFixture("gears-program"); defer { f.close() }
    for fault in ["model", "texture", "decode", "unavailable"] {
      let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .input)
      var ready = false
      let owner = AgentWebCoordinator(lease: lease, resources: resources, onInteractionReady: { ready = $0 }, onState: { _ in true })
      owner.programStore = f.store
      let web = AgentWebCoordinator.makeWebView(coordinator: owner), close = try mount(web)
      defer { owner.invalidate(); lease.release(); close() }
      let script = """
        (()=>{window.fixtureFault='FAULT';window.fixtureErrors=[];window.fixtureDecodes=[];window.fixtureClosed=0;
          addEventListener('error',e=>fixtureErrors.push(String(e.message)));
          addEventListener('unhandledrejection',e=>fixtureErrors.push(String(e.reason)));
          const fetch=window.fetch;let failed=false;
          window.fetch=(url,options)=>{
            const path=String(url);if(!failed&&((fixtureFault==='model'&&path.endsWith('.gltf'))||(fixtureFault==='texture'&&path.endsWith('.png')))){
              failed=true;return Promise.resolve(fixtureFault==='model'?new Response('{}'):new Response('missing',{status:404}));}
            return fetch(url,options);};
          const decode=window.createImageBitmap;
          window.createImageBitmap=(...args)=>decode(...args).then(bitmap=>{const close=bitmap.close.bind(bitmap);bitmap.close=()=>{fixtureClosed++;close()};
            return fixtureFault==='decode'?new Promise(resolve=>fixtureDecodes.push(()=>resolve(bitmap))):bitmap;});
          if(fixtureFault==='unavailable'){const get=HTMLCanvasElement.prototype.getContext;HTMLCanvasElement.prototype.getContext=function(type,...args){return type==='webgl2'?null:get.call(this,type,...args)};}
        })();
        """.replacingOccurrences(of: "FAULT", with: fault)
      web.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
      owner.load(.init(id: "failed-gears", kind: .web, frame: .init(x: 0, y: 0, width: 760, height: 1050), source: "", html: "", programPackage: f.hash),
        policy: .exact(scale: 1), in: web)
      func until(_ source: String) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        repeat {
          if (try? await web.evaluateJavaScript(source)) as? Bool == true { return }
          try await Task.sleep(for: .milliseconds(20))
        } while .now < deadline
        XCTFail(fault + ": " + source)
      }
      if fault == "decode" {
        try await until("window.fixtureDecodes?.length===2")
        _ = try await NotebookProgramBridge.lifecycle("dispose", controller: "notebookProgram", in: web)
        _ = try await web.evaluateJavaScript("fixtureDecodes.splice(0).forEach(release=>release());null")
        try await until("fixtureClosed===2")
        let status = try await web.evaluateJavaScript("document.getElementById('model-status').textContent") as? String
        XCTAssertEqual(status, "Загрузка локальной модели…", "Late decoded textures must not resurrect the deleted scene")
      } else {
        try await wait { ready || owner.snapshotFailure != nil }; XCTAssertTrue(ready, "The explicit local error UI, not a claimed 3D success, is ready")
        let failure = try await web.evaluateJavaScript("!document.getElementById('model-error').hidden && !document.getElementById('poster').hidden && document.getElementById('play').disabled") as? Bool
        XCTAssertEqual(failure, true, fault)
        if fault != "unavailable" {
          _ = try await web.evaluateJavaScript("document.getElementById('retry').click();null")
          try await until("document.getElementById('poster').hidden && !document.getElementById('play').disabled")
          let errors = try await web.evaluateJavaScript("JSON.stringify(fixtureErrors)") as? String
          XCTAssertEqual(errors, "[]", "Retry must not redeclare NotebookProgram.ready after startup")
        }
      }
      owner.invalidate(); lease.release()
    }
  }

  func testWaveWorkerBackpressureCancellationAndMediaCheckpointOffline() async throws {
    let f = try compiledFixture("wave-program"); defer { f.close() }
    let resources = SceneRenderResources(), lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let owner = AgentWebCoordinator(lease: lease, resources: resources, onInteractionReady: { ready = $0 }, onState: { _ in true })
    owner.programStore = f.store
    let web = AgentWebCoordinator.makeWebView(coordinator: owner), close = try mount(web)
    defer { owner.invalidate(); lease.release(); close() }
    web.configuration.userContentController.addUserScript(WKUserScript(source: """
      (()=>{const Native=Worker;window.waveProbe={alive:0,maxAlive:0,frames:0,recycled:0,detached:0,maxPending:0,fetches:[]};
      window.Worker=class extends Native {
        constructor(...args){super(...args);this.fixtureActive=true;this.pending=0;waveProbe.last=this;
          waveProbe.alive++;waveProbe.maxAlive=Math.max(waveProbe.maxAlive,waveProbe.alive);
          this.addEventListener('message',e=>{if(e.data.buffer){this.pending++;waveProbe.frames++;waveProbe.maxPending=Math.max(waveProbe.maxPending,this.pending);}});}
        postMessage(message,...args){if(message.kind==='start')this.fixtureID=message.id;
          super.postMessage(message,...args);if(message.kind==='recycle'){this.pending--;waveProbe.recycled++;if(message.buffer.byteLength===0)waveProbe.detached++;}}
        terminate(){if(this.fixtureActive){waveProbe.alive--;this.fixtureActive=false;}super.terminate();}
      };const fetch=window.fetch;window.fetch=(url,options)=>{waveProbe.fetches.push(String(url));return fetch(url,options)};
      })();
      """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    owner.load(.init(id: "wave", kind: .web, frame: .init(x: 0, y: 0, width: 760, height: 1050), source: "", html: "", programPackage: f.hash),
      policy: .exact(scale: 1), in: web)
    try await wait { ready || owner.snapshotFailure != nil }; XCTAssertTrue(ready); XCTAssertNil(owner.snapshotFailure)
    func js(_ source: String) async throws -> Any? { try await web.evaluateJavaScript(source) }
    func until(_ source: String) async throws {
      let deadline = ContinuousClock.now + .seconds(12)
      while .now < deadline {
        if try await js(source) as? Bool == true { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      let details = try await js("JSON.stringify({status:document.getElementById('status').textContent,error:document.getElementById('failure').textContent,media:document.getElementById('media-error').textContent,ready:document.getElementById('recording').readyState,probe:{alive:waveProbe.alive,frames:waveProbe.frames,recycled:waveProbe.recycled}})")
      XCTFail("Wave condition: " + source + " · " + String(describing: details))
    }
    try await until("document.getElementById('status').textContent==='Расчёт завершён.' && waveProbe.alive===0")
    let frames = try await js("waveProbe.frames") as? Int; XCTAssertGreaterThan(frames ?? 0, 0)
    _ = try await js("for(const t of ['.5','1.1','1.7']){const s=document.getElementById('time');s.value=t;s.dispatchEvent(new Event('input'));}null")
    try await until("document.getElementById('status').textContent==='Расчёт завершён.' && document.getElementById('result-caption').textContent.includes('1,700')")
    let maxAlive = try await js("waveProbe.maxAlive") as? Int; XCTAssertEqual(maxAlive, 1, "No job queue or simultaneous old/new worker")
    let recycled = try await js("waveProbe.recycled") as? Int, detached = try await js("waveProbe.detached") as? Int
    XCTAssertGreaterThan(recycled ?? 0, 0); XCTAssertEqual(recycled, detached, "ArrayBuffers really transfer, rather than clone")
    let pending = try await js("waveProbe.maxPending") as? Int; XCTAssertEqual(pending, 1, "One outstanding frame applies backpressure")
    _ = try await js("window.goodPixels=document.getElementById('wave-field').toDataURL();document.getElementById('time').value='4';document.getElementById('time').dispatchEvent(new Event('input'));document.getElementById('calculate').click();window.late=waveProbe.last.onmessage;window.lateID=waveProbe.last.fixtureID;document.getElementById('cancel').click();late({data:{id:lateID,step:1,total:1,done:true,buffer:new ArrayBuffer(256*256*4),report:{time:4,energy:1,error:null,amplitude:0}}});null")
    let cancel = try await js("waveProbe.alive===0 && document.getElementById('status').textContent.startsWith('Отменено') && document.getElementById('wave-field').toDataURL()===goodPixels") as? Bool
    XCTAssertEqual(cancel, true, "Cancellation and a queued old callback cannot replace the last correct field")
    _ = try await js("document.getElementById('calculate').click();waveProbe.last.dispatchEvent(new ErrorEvent('error',{message:'fixture worker failure',cancelable:true}));null")
    let localError = try await js("waveProbe.alive===0 && !document.getElementById('failure').hidden && document.getElementById('wave-field').toDataURL()===goodPixels") as? Bool
    XCTAssertEqual(localError, true)
    _ = try await js("document.getElementById('time').value='1.7';document.getElementById('time').dispatchEvent(new Event('input'));document.getElementById('calculate').click();null")
    try await until("document.getElementById('status').textContent==='Расчёт завершён.' && document.getElementById('failure').hidden")
    _ = try await js("document.getElementById('calculate').click();null")
    let checkpoint = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
    XCTAssertEqual(checkpoint["accepted"]?["time"], .number(1.7))
    let hiddenWorkers = try await js("waveProbe.alive") as? Int; XCTAssertEqual(hiddenWorkers, 0)
    _ = try await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web)
    let resumedWorkers = try await js("waveProbe.alive") as? Int; XCTAssertEqual(resumedWorkers, 0, "A completed field resumes without recomputing")
    _ = try await js("document.getElementById('recording-tab').click();null")
    try await until("document.getElementById('recording').readyState>=1 && document.getElementById('recording').duration===8")
    _ = try await js("document.getElementById('media-seek').value='2.5';document.getElementById('media-seek').dispatchEvent(new Event('input'));document.getElementById('rate').value='1.5';document.getElementById('rate').dispatchEvent(new Event('change'));null")
    try await until("Math.abs(document.getElementById('recording').currentTime-2.5)<.05 && document.getElementById('recording').readyState>=2")
    let media = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "notebookProgram", in: web)
    XCTAssertEqual(media["tab"], .string("recording")); XCTAssertEqual(media["rate"], .number(1.5))
    guard case let .number(playhead)? = media["playhead"] else { return XCTFail("Missing media playhead") }
    XCTAssertEqual(playhead, 2.5, accuracy: 0.05)
    let stopped = try await js("document.getElementById('recording').paused && !document.getElementById('recording').hasAttribute('src')") as? Bool
    XCTAssertEqual(stopped, true, "Hidden media stops decoding/buffering, not just sound")
    _ = try await NotebookProgramBridge.lifecycle("resume", controller: "notebookProgram", in: web)
    try await until("document.getElementById('recording').readyState>=2 && Math.abs(document.getElementById('recording').currentTime-2.5)<.05")
    let paused = try await js("document.getElementById('recording').paused") as? Bool; XCTAssertEqual(paused, true, "Resume never autoplays sound")
    _ = try await js("document.getElementById('recording').src=new URL('./missing.mp4',location.href).href;document.getElementById('recording').load();null")
    try await until("document.getElementById('recording').error!==null && !document.getElementById('media-play').disabled")
    _ = try await js("document.getElementById('media-play').click();null")
    try await until("document.getElementById('recording').readyState>=2 && document.getElementById('media-error').hidden && Math.abs(document.getElementById('recording').currentTime-2.5)<.05")
    let directMedia = try await js("!waveProbe.fetches.some(url=>url.endsWith('.mp4')) && document.getElementById('recording').currentSrc.startsWith(location.origin)") as? Bool
    XCTAssertEqual(directMedia, true, "Video uses the scoped URL/Range path, not a JS full-buffer Blob")
    _ = try await js("document.getElementById('model-tab').click();document.getElementById('calculate').click();null")
    _ = try await NotebookProgramBridge.lifecycle("dispose", controller: "notebookProgram", in: web)
    let disposed = try await js("waveProbe.alive===0 && document.getElementById('wave-field').width===0 && !document.getElementById('recording').hasAttribute('src')") as? Bool
    XCTAssertEqual(disposed, true)
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
    window.isReleasedWhenClosed = false; window.contentView = view
    view.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
    window.orderBack(nil)
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
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    coordinator.programStore = f.store
    let host = DocumentWebHost(), close = try mount(host)
    defer { coordinator.invalidate(); close() }
    coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
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
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    try await wait { coordinator.hasCanonicalPixels || coordinator.acquisitionError != nil }
    XCTAssertTrue(coordinator.hasCanonicalPixels, String(describing: coordinator.acquisitionError))
    let afterURL = try await web.evaluateJavaScript("document.querySelector('iframe').src") as? String
    XCTAssertEqual(afterURL, iframeURL, "Independent text retains the same capability and running program")
    XCTAssertEqual(coordinator.programAssets.scopeCount, 1)
    _ = changed.replaceContent(blocks: [.interactive(id: "asset", html: "<strong>Inline replacement</strong>")], actor: UUID())
    coordinator.update(document: changed, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    XCTAssertEqual(coordinator.programAssets.scopeCount, 0, "Replacing package source revokes its namespace immediately")
    try await wait { coordinator.hasCanonicalPixels || coordinator.acquisitionError != nil }
    XCTAssertTrue(coordinator.hasCanonicalPixels, String(describing: coordinator.acquisitionError))
    let inline = try await web.evaluateJavaScript("document.querySelector('iframe').srcdoc.includes('Inline replacement')") as? Bool
    XCTAssertEqual(inline, true, "The same document adapter also owns the replacement inline program")
    coordinator.invalidate(); XCTAssertEqual(coordinator.programAssets.scopeCount, 0); XCTAssertEqual(coordinator.programAssets.activeReadCount, 0)
  }
}
