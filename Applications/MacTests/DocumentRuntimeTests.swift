import AppKit
import NotebookCore
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentRuntimeTests: XCTestCase {
  @MainActor private struct Surface {
    let coordinator: DocumentWebCoordinator
    let host: DocumentWebHost
    let window: NSWindow
    func close() { coordinator.invalidate(); window.orderOut(nil); window.close() }
  }

  private func surface(document: DocumentDocument, state: DocumentStateJournal,
    resources suppliedResources: SceneRenderResources? = nil, snapshotPixelWidth: Int? = nil,
    interactive: Bool = true, pageIndex: Int = 0,
    failure: @escaping (Error) -> Void = { _ in },
    readinessFailure: @escaping @MainActor (PageTurnPreparationFailure) -> Void = { _ in },
    commit: @escaping (String, JSONValue) async throws -> ContentFieldVersion? = { _,_ in nil }) -> Surface {
    let resources = suppliedResources ?? SceneRenderResources(maximumWebSurfaces: 4)
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: commit)
    coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: snapshotPixelWidth != nil,
      onRenderReady: .init(onFailure: readinessFailure) { _ in }, onPageLayout: { _ in }, onStateChange: commit,
      snapshotPixelWidth: snapshotPixelWidth, onPreparationFailure: failure)
    let host = DocumentWebHost(), size = WorkspaceItemGeometry.document(document.paperSize)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: size.width, height: size.height),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
    coordinator.mount(in: host, physicalSize: .init(width: size.width, height: size.height),
      isInteractive: interactive && snapshotPixelWidth == nil,
      priority: snapshotPixelWidth == nil ? (interactive ? .currentPage : .neighbor) : .visible)
    return .init(coordinator: coordinator, host: host, window: window)
  }

  func testInteractionLayerLeavesTheNativePrintedPaperVisible() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Native paper must remain visible"),
      .interactive(id: "control", html: "<div style='height:80px;background:blue'>Live program</div>", height: 100)])
    let mounted = surface(document: document, state: .init(id: document.id, actor: UUID()))
    defer { mounted.close() }
    await waitUntil { mounted.coordinator.renderIsReady }
    let web = try XCTUnwrap(mounted.coordinator.webView)
    XCTAssertEqual(web.value(forKey: "drawsBackground") as? Bool, false)
    let config = WKSnapshotConfiguration(); config.snapshotWidth = 595
    let image = try await web.takeSnapshot(configuration: config)
    var rect = CGRect(origin: .zero, size: image.size)
    let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    let pixels = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
      bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    pixels.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    let bytes = try XCTUnwrap(pixels.data).assumingMemoryBound(to: UInt8.self)
    let clear = (0..<(cg.width * cg.height)).filter { bytes[$0 * 4 + 3] == 0 }.count
    XCTAssertGreaterThan(clear, cg.width * cg.height / 2,
      "The live interaction surface must not cover native text with opaque white pixels")
  }

  func testFittedDocumentKeepsWebKitInScreenPointsWithoutChangingItsCSSViewport() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "control",
      html: "<label>Parameter<input type='range' style='width:600px' aria-label='Parameter'></label>", height: 100)])
    let mounted = surface(document: document, state: .init(id: document.id, actor: UUID()))
    defer { mounted.close() }
    await waitUntil { mounted.coordinator.renderIsReady }
    let web = try XCTUnwrap(mounted.coordinator.webView)
    let canonical = web.bounds.size
    let originalWidth = try await web.evaluateJavaScript("innerWidth")
    let before = try XCTUnwrap(originalWidth as? NSNumber).doubleValue
    let plane = NSView(frame: .init(origin: .zero, size: canonical))
    let container = NSView(frame: plane.frame)
    mounted.window.contentView = container
    container.addSubview(plane)
    plane.addSubview(mounted.host)
    mounted.host.frame = .init(origin: .zero, size: canonical)
    for scale in [0.44, 1.0, 1.5] {
      mounted.window.setContentSize(.init(width: canonical.width * scale, height: canonical.height * scale))
      plane.frame = .init(origin: .zero, size: .init(width: canonical.width * scale, height: canonical.height * scale))
      mounted.host.frame = .init(origin: .zero, size: plane.bounds.size)
      mounted.host.setProjectionScale(scale)
      plane.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
      let displayed = web.convert(web.bounds, to: nil)
      XCTAssertEqual(displayed.width, web.bounds.width, accuracy: 0.01,
        "Remote AX rectangles must not inherit a scale unknown to WebKit")
      XCTAssertEqual(web.bounds.width, canonical.width * scale, accuracy: 0.01)
      XCTAssertEqual(Double(web.pageZoom), scale)
      let currentWidth = try await web.evaluateJavaScript("innerWidth")
      let width = try XCTUnwrap(currentWidth as? NSNumber).doubleValue
      XCTAssertEqual(width, before, accuracy: 2, "The author keeps the same CSS layout while native paper zooms")
      XCTAssertTrue(mounted.host.hasInteractiveSurface(web))
      let browserHit = try await web.evaluateJavaScript("""
        (() => { const frame = document.querySelector('iframe'), r = frame.getBoundingClientRect();
          const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
          return hit === frame ? 'iframe' : hit?.outerHTML.slice(0, 300); })()
        """)
      XCTAssertEqual(browserHit as? String, "iframe",
        "Canonical paper hit regions must not cover the live program")
    }
  }

  private struct MountedWebHost: NSViewRepresentable {
    let host: DocumentWebHost
    func makeNSView(context: Context) -> DocumentWebHost { host }
    func updateNSView(_ view: DocumentWebHost, context: Context) {}
  }

  func testReadingPanKeepsTheFullWebKitViewportAndContentOnThePaper() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "marker",
      html: "<button style='margin-top:100px'>Paper marker</button>", height: 500)])
    let mounted = surface(document: document, state: .init(id: document.id, actor: UUID()))
    defer { mounted.close() }
    await waitUntil { mounted.coordinator.renderIsReady }
    let web = try XCTUnwrap(mounted.coordinator.webView)
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let viewport = SpatialPoint(x: 1100, y: 728), scale = 1052 / geometry.width
    let plane = SceneCameraPlaneView<Int>()
    plane.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    // Unlike a borderless fixture, the real reader has titlebar geometry.
    mounted.window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
    mounted.window.setContentSize(plane.frame.size); mounted.window.contentView = plane
    defer { plane.uninstall() }
    mounted.host.setProjectionScale(scale)
    func update(_ offset: Double, active: Bool) {
      let presence = SessionPresence(mode: .document, camera: .init(center: .init(x: 0, y: offset), scale: scale),
        viewport: viewport, focusedItemID: document.id, openProgress: 1)
      plane.update(presence: presence, revision: 0, reanchorsOnRevision: false, isCameraActive: active) { anchor, _ in
        let top = 24 - anchor.camera.center.localY * scale
        return AnyView(MountedWebHost(host: mounted.host)
          .frame(width: geometry.width * scale, height: geometry.height * scale)
          .background(.white).clipShape(RoundedRectangle(cornerRadius: 4))
          .position(x: viewport.x / 2, y: top + geometry.height * scale / 2)
          .frame(width: viewport.x, height: viewport.y))
      }
      plane.layoutSubtreeIfNeeded()
    }
    update(0, active: false)
    try await Task.sleep(for: .milliseconds(50))
    let original = web.convert(web.bounds, to: nil)
    let originalViewport = try await web.evaluateJavaScript("[innerWidth,innerHeight]") as? [NSNumber]
    for offset in [200.0, 800.0, 0.0] {
      update(offset, active: true)
      try await Task.sleep(for: .milliseconds(50))
      update(offset, active: false)
      try await Task.sleep(for: .milliseconds(50))
      let projected = web.convert(web.bounds, to: nil)
      XCTAssertEqual(projected.size, original.size)
      XCTAssertEqual(projected.minY, original.minY + offset * scale, accuracy: 1)
      let currentViewport = try await web.evaluateJavaScript("[innerWidth,innerHeight]") as? [NSNumber]
      XCTAssertEqual(currentViewport, originalViewport, "Scrolling moves the paper, never resizes the browser viewport")
      XCTAssertEqual(web.obscuredContentInsets.top, 0,
        "The titlebar must not independently push live content down as paper leaves the window")
      XCTAssertEqual(plane.contentPublicationCount, 1)
    }
  }

  func testStatePublicationDuringCameraContactKeepsThePreparedWebKitScale() async throws {
    let actor = UUID(), resources = SceneRenderResources(maximumWebSurfaces: 1)
    let document = DocumentDocument(actor: actor, blocks: [.interactive(id: "control",
      html: "<input type='range'>", initialState: .number(0), height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let geometry = WorkspaceItemGeometry.document(document.paperSize), viewport = SpatialPoint(x: 1100, y: 780)
    let plane = SceneCameraPlaneView<Int>()
    plane.frame = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    let window = NSWindow(contentRect: plane.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = plane; window.orderBack(nil)
    defer { plane.uninstall(); window.orderOut(nil); window.close() }
    var ready = false
    func web(in view: NSView) -> WKWebView? {
      (view as? WKWebView) ?? view.subviews.lazy.compactMap { web(in: $0) }.first
    }
    func update(scale: Double, revision: Int, active: Bool) {
      let presence = SessionPresence(mode: .document, camera: .init(scale: scale), viewport: viewport,
        focusedItemID: document.id, openProgress: 1)
      plane.update(presence: presence, revision: revision, reanchorsOnRevision: false, isCameraActive: active) { anchor, projection in
        AnyView(DocumentWebView(document: document, state: state, isInteractive: true,
          selectedPageIndex: 0, capturesSnapshot: false, onRenderReady: .init { ready = $0 },
          onPageLayout: { _ in }, onLinkActivation: { _ in nil }, onStateChange: { _, _ in nil }, resources: resources)
          .environment(\.scenePlaneProjection, projection)
          .environment(\.macDocumentDisplayScale, anchor.camera.scale)
          .frame(width: geometry.width * anchor.camera.scale, height: geometry.height * anchor.camera.scale)
          .frame(width: viewport.x, height: viewport.y))
      }
      plane.layoutSubtreeIfNeeded()
    }
    update(scale: 0.44, revision: 0, active: false)
    await waitUntil { ready }
    let initial = try XCTUnwrap(web(in: plane))
    XCTAssertTrue(state.commit(blockID: "control", value: .number(1), actor: actor))
    update(scale: 0.5, revision: 1, active: true)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(web(in: plane) === initial)
    XCTAssertEqual(initial.pageZoom, 0.44, accuracy: 0.0001)
    XCTAssertEqual(initial.convert(initial.bounds, to: nil).width, geometry.width * 0.5, accuracy: 1,
      "A state echo during contact must not apply the current camera a second time")
    update(scale: 0.5, revision: 1, active: false)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(web(in: plane) === initial)
    XCTAssertEqual(initial.pageZoom, 0.5, accuracy: 0.0001)
    XCTAssertEqual(initial.convert(initial.bounds, to: nil).width, geometry.width * 0.5, accuracy: 1)
  }

  func testProjectedReadingCompositionKeepsWebKitOutOfScaledAncestors() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "control",
      html: "<label>Parameter<input type='range' aria-label='Parameter'></label>", height: 100)])
    let mounted = surface(document: document, state: .init(id: document.id, actor: UUID()))
    defer { mounted.close() }
    await waitUntil { mounted.coordinator.renderIsReady }
    let web = try XCTUnwrap(mounted.coordinator.webView), canonical = web.bounds.size, scale = 0.44
    mounted.host.setProjectionScale(scale)
    let root = NSHostingView(rootView: MountedWebHost(host: mounted.host)
      .frame(width: canonical.width * scale, height: canonical.height * scale)
      .background(.white).clipShape(RoundedRectangle(cornerRadius: 4))
      .frame(width: canonical.width * scale, height: canonical.height * scale))
    mounted.window.setContentSize(.init(width: canonical.width * scale, height: canonical.height * scale))
    mounted.window.contentView = root
    root.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(web.isRotatedOrScaledFromBase,
      "Native events must not cross a scaled ancestor before reaching WebKit")
    XCTAssertEqual(mounted.host.bounds.size, mounted.host.frame.size,
      "The representable must not fight SwiftUI's frame layout by rewriting its bounds")
    let point = web.convert(.init(x: web.bounds.midX, y: web.bounds.midY), to: root.superview)
    let hit = root.hitTest(point)
    XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true,
      "The native reading composition must hand the event to WebKit, not \(String(describing: hit))")
  }

  func testDocumentBoundarySavesTheAnimatedModelAndResumesTheSamePrograms() async throws {
    let actor = UUID()
    let document = DocumentDocument(actor: actor, blocks: [.interactive(id: "clock", html: "<output></output>", javaScript: """
      let phase=0,timer;const start=()=>{timer=setInterval(()=>{phase++;document.querySelector('output').textContent=phase},10)};
      notebook.lifecycle({pause(){clearInterval(timer)},checkpoint(){return {phase}},resume:start,dispose(){clearInterval(timer)}});
      notebook.ready(Promise.resolve().then(start));
      """, initialState: .object(["phase": .number(0)]), height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    surface.coordinator.onStateCheckpoint = { id, value, source, basis in
      guard source == document.programIdentity(blockID: id), state.records.first(where: { $0.id == id })?.valueVersion == basis else { return nil }
      _ = state.commit(blockID: id, value: value, actor: actor)
      return state.records.first { $0.id == id }?.valueVersion
    }
    await waitUntil { surface.coordinator.renderIsReady }
    try await Task.sleep(for: .milliseconds(120))
    let saved = await surface.coordinator.checkpointPrograms(resume: false)
    XCTAssertTrue(saved)
    let first = try XCTUnwrap(state.value(for: "clock"))
    guard case .number(let phase) = first["phase"] else { return XCTFail("The actual model must reach the writer") }
    XCTAssertGreaterThan(phase, 0)
    // Do not provide a SwiftUI echo: the durable receipt itself must advance
    // the iframe's basis and prevent resume from restoring its previous value.
    let frozen = await surface.coordinator.checkpointPrograms(resume: false)
    XCTAssertTrue(frozen)
    XCTAssertEqual(state.value(for: "clock"), first)
    let web = surface.coordinator.webView
    await surface.coordinator.resumePrograms()
    try await Task.sleep(for: .milliseconds(120))
    let next = await surface.coordinator.checkpointPrograms(resume: false)
    XCTAssertTrue(next)
    guard case .number(let later) = state.value(for: "clock")?["phase"] else { return XCTFail("Missing resumed checkpoint") }
    XCTAssertGreaterThan(later, phase)
    XCTAssertTrue(surface.coordinator.webView === web)
  }

  func testCodeModeStopsTheSameProgramUntilItsCheckpointIsDurable() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Before"),
      .interactive(id: "clock", html: "<output></output>", javaScript: """
      let phase=0,timer;const start=()=>{timer=setInterval(()=>{phase++;document.querySelector('output').textContent=phase},10)};
      notebook.lifecycle({pause(){clearInterval(timer)},checkpoint(){return {phase}},resume:start,dispose(){clearInterval(timer)}});
      notebook.ready(Promise.resolve().then(start));
      """, initialState: .object(["phase": .number(0)]), height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    surface.coordinator.ownsProgramState = true
    var entered = false, release = false, refuse = false
    surface.coordinator.onStateCheckpoint = { id, value, _, _ in
      if refuse { throw CocoaError(.fileWriteUnknown) }
      entered = true
      while !release { try await Task.sleep(for: .milliseconds(5)) }
      _ = state.commit(blockID: id, value: value, actor: actor)
      return state.records.first { $0.id == id }?.valueVersion
    }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    func phase() async throws -> Int {
      let value = try await web.callAsyncJavaScript("""
      const item=(await notebookRenderer.checkpointPrograms())[0];
      if(item.error)throw new Error(item.error);
      let json='';while(json.length<item.snapshot.units){
        json+=await notebookRenderer.transferProgramState(item.blockID,item.token,'notebook-snapshot',
          {revision:item.snapshot.revision,offset:json.length});
      }
      return JSON.parse(json).phase;
      """, arguments: [:], in: nil, contentWorld: .page)
      return try XCTUnwrap(value as? Int)
    }
    try await Task.sleep(for: .milliseconds(80))
    surface.coordinator.setProgramsVisible(false)
    await waitUntil { entered }
    surface.coordinator.setProgramsVisible(true) // return while disk is still busy
    let frozen = try await phase()
    try await Task.sleep(for: .milliseconds(100))
    let stillFrozen = try await phase()
    XCTAssertEqual(frozen, stillFrozen)
    release = true
    await waitUntil { state.value(for: "clock") != nil }
    try await Task.sleep(for: .milliseconds(120))
    let resumed = try await phase()
    XCTAssertGreaterThan(resumed, frozen)
    surface.coordinator.setProgramsVisible(false)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "After", actor: actor))
    surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    await waitUntil { surface.coordinator.renderIsReady }
    let after = try await phase()
    try await Task.sleep(for: .milliseconds(100))
    let unchanged = try await phase()
    XCTAssertEqual(after, unchanged, "An unrelated source edit cannot start hidden programs")
    refuse = true
    surface.coordinator.setProgramsVisible(true)
    try await Task.sleep(for: .milliseconds(120))
    let refused = try await phase()
    XCTAssertEqual(refused, unchanged, "Writer failure cannot resume or reset a frozen heap")
    refuse = false
    surface.coordinator.setProgramsVisible(false)
    surface.coordinator.setProgramsVisible(true)
    try await Task.sleep(for: .milliseconds(120))
    let retried = try await phase()
    XCTAssertGreaterThan(retried, refused)
    XCTAssertTrue(surface.coordinator.webView === web)
  }

  func testUnreadyProgramRetirementJoinsItsAcceptedStateWithoutCallingAuthorCheckpoint() async throws {
    let (store, document, actor) = try durableProgram(javaScript: """
      notebook.lifecycle({checkpoint(){throw new Error('must_not_checkpoint_unready_author')}});
      notebook.ready(new Promise(()=>{}));
      if(!notebook.commit({early:1}))throw new Error('early_commit_not_accepted');
      """)
    let resources = SceneRenderResources(maximumWebSurfaces: 2), queue = NotebookPersistenceQueue(store: store)
    var release: CheckedContinuation<Void, Never>?, entered = false
    defer { release?.resume() }
    let mounted = surface(document: document, state: try store.loadDocumentState(document.id), resources: resources,
      commit: { id, value in
        entered = true
        await withCheckedContinuation { release = $0 }
        return try await queue.submit { try $0.commitDocumentState(documentID: document.id, blockID: id,
          value: value, programIdentity: document.programIdentity(blockID: id), actor: actor) }
      })
    defer { mounted.close() }
    mounted.coordinator.onStateCheckpoint = { _, _, _, _ in
      XCTFail("A not-ready author only drains its accepted explicit state"); return nil
    }
    await waitUntil { entered }
    let web = try XCTUnwrap(mounted.coordinator.webView)
    mounted.coordinator.retireAfterProgramCheckpoint()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertFalse(mounted.coordinator.isInvalidated)
    XCTAssertTrue(mounted.coordinator.webView === web)
    XCTAssertGreaterThan(resources.activeWebSurfaceCount, 0)
    XCTAssertNil(try store.loadDocumentState(document.id).value(for: "early"))
    release?.resume(); release = nil
    await waitUntil { mounted.coordinator.isInvalidated }
    XCTAssertEqual(try store.loadDocumentState(document.id).value(for: "early"), .object(["early": .number(1)]))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testReadinessFailureKeepsAcceptedStateUntilDurableWithoutRestartingAuthor() async throws {
    let (store, document, actor) = try durableProgram(javaScript: """
      notebook.lifecycle({pause(){throw new Error('broken_author_pause')}});
      notebook.ready(Promise.reject(new Error('author_readiness_failed')));
      if(!notebook.commit({early:2}))throw new Error('early_commit_not_accepted');
      """)
    let resources = SceneRenderResources(maximumWebSurfaces: 2), queue = NotebookPersistenceQueue(store: store)
    var release: CheckedContinuation<Void, Never>?, failures = 0, accepted = 0
    defer { release?.resume() }
    let mounted = surface(document: document, state: try store.loadDocumentState(document.id), resources: resources,
      failure: { _ in failures += 1 }, commit: { id, value in
        accepted += 1
        await withCheckedContinuation { release = $0 }
        return try await queue.submit { try $0.commitDocumentState(documentID: document.id, blockID: id,
          value: value, programIdentity: document.programIdentity(blockID: id), actor: actor) }
      })
    defer { mounted.close() }
    await waitUntil { release != nil && failures > 0 }
    let web = try XCTUnwrap(mounted.coordinator.webView)
    XCTAssertFalse(mounted.coordinator.renderIsReady)
    XCTAssertFalse(mounted.coordinator.isInvalidated)
    XCTAssertGreaterThan(resources.activeWebSurfaceCount, 0)
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertTrue(mounted.coordinator.webView === web, "A failed frame still owns its accepted writer")
    release?.resume(); release = nil
    await waitUntil { mounted.coordinator.webView == nil }
    XCTAssertEqual(try store.loadDocumentState(document.id).value(for: "early"), .object(["early": .number(2)]))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertFalse(mounted.coordinator.isInvalidated, "The failed presentation remains available for explicit Retry")
    XCTAssertEqual(accepted, 1, "Finishing transport does not restart a broken author")
    XCTAssertTrue(mounted.host.subviews.contains { $0 is NSStackView }, "The readiness error stays visible after durable release")
  }

  func testFailedDrainDeadlineKeepsItsHeapUntilExplicitRetry() async throws {
    let (store, document, actor) = try durableProgram(javaScript: """
      notebook.ready(Promise.reject(new Error('author_readiness_failed')));
      if(!notebook.commit({early:3}))throw new Error('early_commit_not_accepted');
      """)
    let resources = SceneRenderResources(maximumWebSurfaces: 2), queue = NotebookPersistenceQueue(store: store)
    var release: CheckedContinuation<Void, Never>?, failures = 0, accepted = 0
    defer { release?.resume() }
    let mounted = surface(document: document, state: try store.loadDocumentState(document.id), resources: resources,
      failure: { _ in failures += 1 }, commit: { id, value in
        accepted += 1
        if accepted == 1 { await withCheckedContinuation { release = $0 } }
        return try await queue.submit { try $0.commitDocumentState(documentID: document.id, blockID: id,
          value: value, programIdentity: document.programIdentity(blockID: id), actor: actor) }
      })
    defer { mounted.close() }
    await waitUntil { release != nil && failures > 0 }
    let web = try XCTUnwrap(mounted.coordinator.webView), firstFailure = failures
    await waitUntil { failures > firstFailure }
    XCTAssertTrue(mounted.coordinator.webView === web, "A failed drain cannot dispose its accepted state")
    release?.resume(); release = nil
    let flushed = await queue.flush()
    XCTAssertTrue(flushed)
    await waitUntil { (try? store.loadDocumentState(document.id).value(for: "early")) == .object(["early": .number(3)]) }
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(mounted.coordinator.webView === web, "Late durability cannot silently restart or dismiss the failed boundary")
    XCTAssertEqual(accepted, 1)
    mounted.coordinator.retryPreparation()
    await waitUntil { accepted == 2 }
    XCTAssertFalse(mounted.coordinator.webView === web, "Explicit Retry releases the old admitted heap before a fresh author")
  }

  func testCheckpointWriterRetryRetainsItsFrozenSnapshotAndDoesNotRepeatTransfer() async throws {
    let (store, document, actor) = try durableProgram(javaScript: """
      notebook.lifecycle({checkpoint:()=>({payload:'x'.repeat(524288)})});
      notebook.ready(Promise.resolve());
      """)
    let resources = SceneRenderResources(maximumWebSurfaces: 2), queue = NotebookPersistenceQueue(store: store)
    let mounted = surface(document: document, state: try store.loadDocumentState(document.id), resources: resources)
    defer { mounted.close() }
    var writes = 0
    mounted.coordinator.onStateCheckpoint = { id, value, source, basis in
      writes += 1
      if writes == 1 { throw CocoaError(.fileWriteUnknown) }
      return try await queue.submit { try $0.checkpointDocumentState(documentID: document.id, blockID: id,
        value: value, programIdentity: source, stateVersion: basis, actor: actor) }
    }
    await waitUntil { mounted.coordinator.renderIsReady }
    let web = try XCTUnwrap(mounted.coordinator.webView)
    _ = try await web.evaluateJavaScript("""
      window.fixtureSnapshotReads=0;
      const originalTransfer=notebookRenderer.transferProgramState;
      notebookRenderer.transferProgramState=(...args)=>{
        if(args[2]==='notebook-snapshot')fixtureSnapshotReads++;
        return originalTransfer(...args);
      };true;
      """)
    let first = await mounted.coordinator.checkpointPrograms(resume: false)
    XCTAssertFalse(first)
    let reads = try await web.evaluateJavaScript("fixtureSnapshotReads") as? Int
    XCTAssertGreaterThan(try XCTUnwrap(reads), 1)
    let held = resources.rasterAdmission.heldBytes
    let prematureResume = await mounted.coordinator.resumePrograms()
    XCTAssertFalse(prematureResume, "A frozen checkpoint with a failed writer cannot resume or accept more state")
    let retried = await mounted.coordinator.checkpointPrograms(resume: false)
    XCTAssertTrue(retried)
    XCTAssertEqual(writes, 2)
    let afterReads = try await web.evaluateJavaScript("fixtureSnapshotReads") as? Int
    XCTAssertEqual(afterReads, reads, "Retry writes the same admitted immutable snapshot, without another pull")
    XCTAssertLessThan(resources.rasterAdmission.heldBytes, held, "Durable ACK releases the frozen snapshot's extra admission")
    XCTAssertEqual(try store.loadDocumentState(document.id).value(for: "early")?["payload"],
      .string(String(repeating: "x", count: 524288)))
    let resumed = await mounted.coordinator.resumePrograms()
    XCTAssertTrue(resumed)
  }

  func testTransportRetryKeepsBothAcceptedCommitsAndTheSameAuthorHeap() async throws {
    let (store, document, actor) = try durableProgram(javaScript: """
      const boot=crypto.randomUUID();
      addEventListener('message',event=>{if(event.data.fixtureCommit){
        notebook.commit({boot,sequence:1});notebook.commit({boot,sequence:2});
      }});
      notebook.ready(Promise.resolve());
      """)
    let resources = SceneRenderResources(maximumWebSurfaces: 2), queue = NotebookPersistenceQueue(store: store)
    var failure: PageTurnPreparationFailure?, values: [JSONValue] = [], checkpointed = false, checkpointWrites = 0
    let mounted = surface(document: document, state: try store.loadDocumentState(document.id), resources: resources,
      readinessFailure: { failure = $0 }, commit: { id, value in
        let receipt = try await queue.submit { try $0.commitDocumentState(documentID: document.id, blockID: id,
          value: value, programIdentity: document.programIdentity(blockID: id), actor: actor) }
        values.append(value); return receipt
      })
    defer { mounted.close() }
    mounted.coordinator.onStateCheckpoint = { id, value, source, basis in
      let receipt = try await queue.submit { try $0.checkpointDocumentState(documentID: document.id, blockID: id,
        value: value, programIdentity: source, stateVersion: basis, actor: actor) }
      checkpointed = receipt != nil; checkpointWrites += 1; return receipt
    }
    await waitUntil { mounted.coordinator.renderIsReady }
    let web = try XCTUnwrap(mounted.coordinator.webView)
    _ = try await web.evaluateJavaScript("""
      const originalTransfer=notebookRenderer.transferProgramState;let holdFirst=true;
      notebookRenderer.transferProgramState=(...args)=>{
        if(args[2]==='notebook-snapshot' && holdFirst){
          holdFirst=false;return new Promise(resolve=>{window.fixtureReleaseRead=()=>resolve('stale')});
        }
        return originalTransfer(...args);
      };
      document.querySelector('iframe').contentWindow.postMessage({fixtureCommit:true},'*');true;
      """)
    await waitUntil { failure != nil }
    XCTAssertTrue(values.isEmpty, "A timed-out first read cannot drop its accepted revision and advance the second")
    XCTAssertTrue(mounted.coordinator.webView === web)
    try XCTUnwrap(failure).retry()
    await waitUntil { values.count == 2 && checkpointed }
    XCTAssertEqual(values.map { $0["sequence"] }, [.number(1), .number(2)])
    XCTAssertEqual(values.first?["boot"], values.last?["boot"])
    XCTAssertTrue(mounted.coordinator.webView === web, "Transport Retry cannot replace the author or rerun its startup")
    _ = try await web.evaluateJavaScript("fixtureReleaseRead();true")
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(values.count, 2, "A late transport response has no remaining publication rights")
    XCTAssertEqual(try store.loadDocumentState(document.id).value(for: "early"), values.last)
    let previousFailure = failure?.id, previousWrites = checkpointWrites
    _ = try await web.evaluateJavaScript("""
      const originalVisibility=notebookRenderer.setProgramsVisible;let holdVisibility=true;
      notebookRenderer.setProgramsVisible=visible=>{
        if(!visible && holdVisibility){holdVisibility=false;
          return new Promise(resolve=>{window.fixtureReleaseVisibility=()=>resolve(true)});
        }
        return originalVisibility(visible);
      };true;
      """)
    mounted.coordinator.setProgramsVisible(false)
    await waitUntil { failure?.id != previousFailure }
    XCTAssertEqual(checkpointWrites, previousWrites,
      "A timed-out visibility barrier cannot silently proceed to checkpoint")
    XCTAssertTrue(mounted.coordinator.webView === web)
    try XCTUnwrap(failure).retry()
    await waitUntil { checkpointWrites > previousWrites }
    XCTAssertTrue(mounted.coordinator.webView === web, "Visibility Retry also keeps the accepted author heap")
    _ = try await web.evaluateJavaScript("fixtureReleaseVisibility();true")
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(values.count, 2)
    XCTAssertEqual(try store.loadDocumentState(document.id).value(for: "early"), values.last)
  }

  private func durableProgram(javaScript: String) throws -> (NotebookStore, DocumentDocument, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let item = try XCTUnwrap(index.createDocument(title: "Early program", actor: actor))
    XCTAssertTrue(board.addItem(item.id, to: header.rootBoardID, near: .zero, actor: actor))
    let document = DocumentDocument(id: item.id, actor: actor, blocks: [.interactive(id: "early", html: "<output>Early state</output>",
      javaScript: javaScript, initialState: .null, height: 100)])
    try store.saveDocumentWorkspaceBundle(index: index, document: document,
      state: .init(id: item.id, actor: actor), board: board)
    return (store, document, actor)
  }

  func testDocumentDismantleKeepsItsBrowserUntilTheWriterAcceptsCheckpoint() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "clock", html: "<output>0.75</output>",
      javaScript: "notebook.lifecycle({checkpoint:()=>({phase:0.75})});notebook.ready(Promise.resolve());",
      initialState: .object(["phase": .number(0)]), height: 100)])
    let resources = SceneRenderResources(maximumWebSurfaces: 2), actor = UUID()
    var state = DocumentStateJournal(id: document.id, actor: actor), entered = false, release = false
    let surface = surface(document: document, state: state, resources: resources)
    defer { surface.close() }
    surface.coordinator.onStateCheckpoint = { id, value, _, _ in
      entered = true
      while !release { try await Task.sleep(for: .milliseconds(5)) }
      _ = state.commit(blockID: id, value: value, actor: actor)
      return state.records.first { $0.id == id }?.valueVersion
    }
    await waitUntil { surface.coordinator.renderIsReady }
    surface.coordinator.retireAfterProgramCheckpoint()
    await waitUntil { entered }
    XCTAssertFalse(surface.coordinator.isInvalidated)
    XCTAssertGreaterThan(resources.activeWebSurfaceCount, 0)
    release = true
    await waitUntil { surface.coordinator.isInvalidated }
    XCTAssertEqual(state.value(for: "clock"), .object(["phase": .number(0.75)]))
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
  }

  func testHeadlessDocumentCompletesActualLayoutWithoutAnimationFrameSubstitution() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Настоящий WebKit\n\nТекст без таймера готовности.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let actual1 = try await js("String(window.notebookRenderer.pageReceipt().pageIndex)", web)
    XCTAssertEqual(actual1, "0")
    let actual2 = try await js("String(requestAnimationFrame).includes('[native code]') ? 'native' : 'replaced'", web)
    XCTAssertEqual(actual2, "native")
    XCTAssertNotNil(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0))
    XCTAssertFalse(DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: 0),
      "An offscreen layout is not a human-visible frame")
  }

  func testRegistryBorrowsLayoutFromLiveSourceThenItsRasterAndReleasesAfterEviction() async throws {
    let resources = SceneRenderResources(byteLimit: 64 * 1024 * 1024, profile: .headless)
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Measured source\n\nIts raster retains the same addresses.")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state, resources: resources)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    weak let layout = surface.coordinator.payload?.source.layout
    let raster = try await surface.coordinator.retainPreparedSnapshot(pixelWidth: 320)
    surface.close()
    XCTAssertNotNil(layout)
    XCTAssertTrue(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0)?.layout === layout)
    XCTAssertGreaterThan(resources.reservedBytes, 0)
    raster.release()
    await waitUntil { resources.activeWebSurfaceCount == 0 }
    let replacement = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit, priority: .passive))
    XCTAssertNil(layout)
    XCTAssertNil(DocumentRenderRegistry.shared.entry(document: document, pageIndex: 0))
    XCTAssertEqual(DocumentRenderRegistry.shared.layoutReferenceCount(documentID: document.id), 0,
      "Expired addresses and diagnostics must leave with their measured owner")
    XCTAssertEqual(resources.reservedBytes, resources.passiveByteLimit)
    replacement.release()
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  func testStateEchoAndUnrelatedSourceKeepTheSameInteractiveBrowsingContext() async throws {
    var document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "До"),
      .interactive(id: "counter", html: "<button>Счётчик</button>", javaScript: "notebook.commit({boot:crypto.randomUUID(),count:notebook.state.count||0});notebook.ready(Promise.resolve());", initialState: .object(["count": .number(0)]), height: 100)])
    var state = DocumentStateJournal(id: document.id, actor: UUID())
    var commits: [JSONValue] = []
    let surface = surface(document: document, state: state, commit: { _, value in commits.append(value); return nil })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady && commits.count == 1 }
    let web = try XCTUnwrap(surface.coordinator.webView), token = surface.coordinator.payload?.blockTokens["counter"]
    _ = try await js("window.originalFrame=document.querySelector('iframe'); 'stored'", web)
    XCTAssertTrue(state.commit(blockID: "counter", value: .object(["count": .number(42)]), actor: UUID()))
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "После", actor: UUID()))
    surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onStateChange: { _, value in commits.append(value); return nil })
    await waitUntil { surface.coordinator.renderIsReady }
    let actual3 = try await js("window.originalFrame===document.querySelector('iframe')?'same':'replaced'", web)
    XCTAssertEqual(actual3, "same")
    XCTAssertEqual(surface.coordinator.payload?.blockTokens["counter"], token)
    XCTAssertEqual(commits.count, 1, "Keeping an iframe node is insufficient: its boot must not execute a second time")
  }

  func testCoalescedSourceReplacementCannotReuseThePreviousProgramContext() async throws {
    let html = "<button>Original source</button>"
    var document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program", html: html,
      javaScript: "notebook.commit({boot:crypto.randomUUID()});notebook.ready(Promise.resolve());", height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var boots: [JSONValue] = []
    let mounted = surface(document: document, state: state, commit: { _, value in boots.append(value); return nil })
    defer { mounted.close() }
    await waitUntil { mounted.coordinator.renderIsReady && boots.count == 1 }
    let web = try XCTUnwrap(mounted.coordinator.webView), previousVersion = document.sourceVersion(blockID: "program")
    _ = try await js("window.previousProgram=document.querySelector('iframe');'stored'", web)
    XCTAssertTrue(document.replaceBlockSource(id: "program", source: "<button>Replaced source</button>", actor: UUID()))
    XCTAssertTrue(document.replaceBlockSource(id: "program", source: html, actor: UUID()))
    XCTAssertNotEqual(document.sourceVersion(blockID: "program"), previousVersion)
    mounted.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onStateChange: { _, value in boots.append(value); return nil })
    await waitUntil { mounted.coordinator.renderIsReady && boots.count == 2 }
    let replaced = try await js("previousProgram!==document.querySelector('iframe')?'replaced':'same'", web)
    XCTAssertEqual(replaced, "replaced", "Byte equality after coalesced edits cannot revive an obsolete source identity")
    XCTAssertNotEqual(boots.first, boots.last)
  }



  func testPrewarmExecutesOnlyProgramsOnItsPhysicalPage() async throws {
    let blocks = (0..<16).map { index in DocumentBlock.interactive(id: "block-\(index)", html: "<p>\(index)</p>",
      javaScript: "notebook.commit({boot:\(index)});notebook.ready(Promise.resolve());", initialState: .null, height: 280) }
    let document = DocumentDocument(actor: UUID(), blocks: blocks), state = DocumentStateJournal(id: document.id, actor: UUID())
    var booted = Set<String>(), acceptedState = state
    let surface = surface(document: document, state: state, commit: { block, value in
      booted.insert(block)
      _ = acceptedState.commit(blockID: block, value: value, actor: acceptedState.stamp.actor)
      return acceptedState.records.first { $0.id == block }?.valueVersion
    })
    defer { surface.close() }
    let deadline = ContinuousClock.now + .seconds(8)
    while !surface.coordinator.renderIsReady && surface.coordinator.acquisitionError == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if !surface.coordinator.renderIsReady {
      let detail = XCTAttachment(string: "error=\(String(describing: surface.coordinator.acquisitionError)) booted=\(booted.sorted())")
      detail.name = "Program-only source readiness"; detail.lifetime = .keepAlways; add(detail)
      throw surface.coordinator.acquisitionError ?? DocumentSessionError.invalidLayout
    }
    let expected = Set(DocumentRenderRegistry.shared.regions(document: document).filter { $0.pageIndex == 0 }.map(\.id))
    XCTAssertFalse(expected.isEmpty)
    XCTAssertLessThan(expected.count, blocks.count)
    // Pixel readiness is not a durable state receipt. Startup commits now pull
    // their admitted JSON asynchronously through the same bounded FIFO as input.
    while booted.count < expected.count, surface.coordinator.acquisitionError == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(surface.coordinator.acquisitionError)
    XCTAssertEqual(booted, expected, "A page host must not run the rest of the document's programs")
    let web = try XCTUnwrap(surface.coordinator.webView)
    let actual7 = try await js("String(document.querySelectorAll('iframe').length)", web)
    XCTAssertEqual(actual7, String(expected.count))
  }

  func testTallProgramContinuesWithExactPixelsAndOneBrowsingContext() async throws {
    let html = "<div style='height:700px;background:#ff0000'>Beginning</div>"
      + "<div style='height:700px;background:#00ff00'>Middle</div>"
      + "<div style='height:648px;background:#0000ff'>End</div>"
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "tall", html: html,
      javaScript: "notebook.commit({boot:crypto.randomUUID()});notebook.ready(Promise.resolve());", initialState: .null, height: 2048)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var boots = 0
    let surface = surface(document: document, state: state, commit: { _,_ in boots += 1; return nil })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let receipt = try await js("JSON.stringify(window.notebookRenderer.pageReceipt())", web)
    let evidence = XCTAttachment(string: receipt); evidence.name = "Tall program browser geometry"; evidence.lifetime = .keepAlways; add(evidence)
    let count = try await js("String(window.notebookRenderer.pageReceipt().pageCount)", web)
    let paper = WorkspaceItemGeometry.document(document.paperSize)
    let contentHeight = paper.height - 2 * document.paperSize.marginPoints * paper.width / document.paperSize.widthPoints
    let pageCount = Int(ceil(2048 / contentHeight))
    XCTAssertGreaterThan(pageCount, 1)
    XCTAssertEqual(count, String(pageCount), "Program height uses the document's physical content region")
    _ = try await js("window.tallFrame=document.querySelector('iframe');'retained'", web)
    for page in 0..<pageCount {
      if page > 0 {
        surface.coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
          onRenderReady: .init { _ in }, onPageLayout: { _ in },
          onStateChange: { _,_ in boots += 1; return nil })
        await waitUntil { surface.coordinator.renderIsReady || surface.coordinator.acquisitionError != nil }
        XCTAssertNil(surface.coordinator.acquisitionError)
      }
      let raster = try await surface.coordinator.retainPreparedSnapshot(pixelWidth: 640)
      defer { raster.release() }
      let picture = XCTAttachment(image: raster.image); picture.name = "Tall program page \(page + 1)"; picture.lifetime = .keepAlways; add(picture)
      let cg = try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
      let color = try centerPixel(cg)
      let expectedChannel = min(2, Int((Double(page) + 0.5) * contentHeight / 700))
      for channel in 0..<3 {
        if channel == expectedChannel { XCTAssertGreaterThan(color[channel], 230, "Page \(page + 1) must show its own part of the program") }
        else { XCTAssertLessThan(color[channel], 25, "A clipped overflow or repeated first frame is not the next page") }
      }
      let identity = try await js("String(document.querySelector('iframe')===window.tallFrame)", web)
      XCTAssertEqual(identity, "true")
    }
    XCTAssertEqual(boots, 1, "Turning through one program cannot recreate its browsing context")
  }

  func testQueuedPreparationKeepsItsSourceBeyondTheExecutionDeadline() async throws {
    let actor = UUID()
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Before")])
    let state = DocumentStateJournal(id: document.id, actor: actor), resources = SceneRenderResources(maximumWebSurfaces: 1)
    let live = surface(document: document, state: state, resources: resources)
    defer { live.close() }
    await waitUntil { live.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(live.coordinator.webView)
    let prior = try XCTUnwrap(live.coordinator.payload?.source), priorLayout = try XCTUnwrap(prior.layout)
    await prior.discardIdlePreparation()
    let sourceBytes = resources.reservedBytes
    let blocker = try XCTUnwrap(resources.reserveDerivedBytes(resources.passiveByteLimit - sourceBytes, priority: .passive))
    defer { blocker.release() }
    XCTAssertTrue(document.replaceBlockSource(id: "body", source: "After $y^3$", actor: actor))
    live.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    await waitUntil { resources.pendingDerivedRequestCount == 1 }
    try await Task.sleep(for: .milliseconds(8_250))
    XCTAssertNil(live.coordinator.acquisitionError, "Waiting for actual bytes is not failed WebKit execution")
    XCTAssertFalse(live.coordinator.renderIsReady)
    XCTAssertNil(live.coordinator.payload?.source.layout)
    XCTAssertTrue(prior.layout === priorLayout)
    XCTAssertTrue(live.coordinator.webView === web)
    blocker.release()
    await waitUntil { live.coordinator.hasCanonicalPixels || live.coordinator.acquisitionError != nil }
    XCTAssertTrue(live.coordinator.hasCanonicalPixels); XCTAssertNil(live.coordinator.acquisitionError)
    XCTAssertTrue(live.coordinator.webView === web, "Admission resumes the same request without a hidden retry")
    XCTAssertEqual(live.coordinator.payload?.source.preparationCount, 1)
    XCTAssertEqual(live.coordinator.payload?.source.measurementCount, 1)
    let text = try await js("document.getElementById('document').textContent", web)
    XCTAssertTrue(text.contains("After"))
  }

  private func centerPixel(_ image: CGImage) throws -> [UInt8] {
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let index = ((image.height / 2) * image.width + image.width / 2) * 4
    return (0..<3).map { bytes[index + $0] }
  }

  func testTallProgramUsesMeasuredContinuationAfterTextWithoutResizingItsViewport() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "before", source: "# Перед программой\n\nЕё начало не совпадает с началом физического листа."),
      .interactive(id: "tall", html: "<input aria-label='Retained input'><div style='height:1900px'>Continuation</div>",
        javaScript: "notebook.commit({boot:crypto.randomUUID(),width:innerWidth,height:innerHeight});notebook.ready(Promise.resolve());", height: 2048)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var boots: [JSONValue] = []
    let surface = surface(document: document, state: state, commit: { _, value in boots.append(value); return nil })
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady && !boots.isEmpty }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let geometry = WorkspaceItemGeometry.document(document.paperSize)
    let margin = document.paperSize.marginPoints * geometry.width / document.paperSize.widthPoints
    let boot = try XCTUnwrap(boots.first)
    XCTAssertEqual(try XCTUnwrap(boot["width"]).decode(Double.self), geometry.width - 2 * margin, accuracy: 1)
    XCTAssertEqual(boot["height"], .number(2048))
    let source = try XCTUnwrap(surface.coordinator.payload?.source)
    let count = try XCTUnwrap(source.layout).pageCount
    var regions: [[String: Any]] = []
    for page in 0..<count {
      surface.coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in },
        onStateChange: { _, value in boots.append(value); return nil })
      await waitUntil { surface.coordinator.renderIsReady }
      let raw = try await js("JSON.stringify(window.notebookRenderer.pageReceipt().regions.filter(region=>region.id==='tall'))", web)
      regions += try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
    }
    XCTAssertGreaterThan(regions.count, 1)
    XCTAssertGreaterThan(try XCTUnwrap(regions.first?["y"] as? Double), margin)
    var offset = 0.0
    for region in regions {
      XCTAssertEqual(try XCTUnwrap(region["sourceOffset"] as? Double), offset, accuracy: 1.0 / 32)
      offset += try XCTUnwrap(region["height"] as? Double)
    }
    XCTAssertEqual(offset, 2048, accuracy: 1.0 / 32, "The measured fragments partition the full program, including a partial first page")
    _ = try await js("window.retainedTall=document.querySelector('iframe'); 'retained'", web)
    let before = try await js("JSON.stringify(window.notebookRenderer.pageReceipt().work)", web)
    for region in regions + Array(regions.reversed()) {
      let page = try XCTUnwrap(region["pageIndex"] as? Int)
      surface.coordinator.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in },
        onStateChange: { _, value in boots.append(value); return nil })
      await waitUntil { surface.coordinator.renderIsReady || surface.coordinator.acquisitionError != nil }
      XCTAssertNil(surface.coordinator.acquisitionError)
      let rawFrame = try await js("""
        JSON.stringify({same:retainedTall===document.querySelector('iframe'),
          offset:-parseFloat(retainedTall.style.top),height:parseFloat(retainedTall.style.height),
          cutHeight:parseFloat(retainedTall.parentElement.style.height),
          cutWidth:parseFloat(retainedTall.parentElement.style.width)})
        """, web)
      let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawFrame.utf8)) as? [String: Any])
      XCTAssertEqual(frame["same"] as? Bool, true)
      XCTAssertEqual(frame["height"] as? Double, 2048)
      XCTAssertEqual(try XCTUnwrap(frame["offset"] as? Double), try XCTUnwrap(region["sourceOffset"] as? Double), accuracy: 0.000001)
      XCTAssertEqual(try XCTUnwrap(frame["cutHeight"] as? Double), try XCTUnwrap(region["height"] as? Double), accuracy: 0.000001)
      XCTAssertEqual(try XCTUnwrap(frame["cutWidth"] as? Double), try XCTUnwrap(region["width"] as? Double), accuracy: 0.000001)
    }
    let after = try await js("JSON.stringify(window.notebookRenderer.pageReceipt().work)", web)
    let firstWork = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Int])
    let lastWork = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Int])
    for key in ["sourceInstalls", "layoutPasses", "regionMeasurements", "typesetPasses"] {
      XCTAssertEqual(firstWork[key], lastWork[key], "Turning a continuation does not repeat \(key)")
    }
    XCTAssertEqual(boots.count, 1)
  }


  func testLayoutHistoryCannotSurviveAsAVisibleReceipt() async throws {
    let registry = DocumentRenderRegistry(), document = DocumentDocument(actor: UUID())
    let state = DocumentStateJournal(id: document.id, actor: UUID()), hostID = UUID()
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)
    registry.publishLive(documentID: document.id, token: token, pageIndex: 0, hostID: hostID, generation: 2, isAttached: { _ in true })
    registry.revokeLive(hostID: hostID, through: 1)
    XCTAssertTrue(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
    registry.revokeLive(hostID: hostID, through: 2)
    XCTAssertFalse(registry.hasLiveSurface(document: document, state: state, pageIndex: 0))
  }

  func testThumbnailBorrowsTheLivePagePixelsWithoutStartingAnotherProgram() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let document = DocumentDocument(actor: UUID(), blocks: [.interactive(id: "program", html: "<p>Живой источник</p>",
      javaScript: "notebook.commit({boot:crypto.randomUUID()});notebook.ready(Promise.resolve());", initialState: .null, height: 100)])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    var bootCount = 0
    let live = surface(document: document, state: state, resources: resources, commit: { _,_ in bootCount += 1; return nil })
    defer { live.close() }
    await waitUntil { live.coordinator.renderIsReady && bootCount == 1 }
    let originalWeb = try XCTUnwrap(live.coordinator.webView)
    let paper = WorkspaceItemGeometry.document(document.paperSize)
    XCTAssertEqual(originalWeb.bounds.size, CGSize(width: paper.width, height: paper.height),
      "The helper window rounds its bounds; the physical WebKit viewport must not inherit that rounding")
    let thumbnail = surface(document: document, state: state, resources: resources, snapshotPixelWidth: 256)
    defer { thumbnail.close() }
    await waitUntil { thumbnail.host.hasSnapshot }
    XCTAssertNil(thumbnail.coordinator.acquisitionError)
    XCTAssertNil(thumbnail.coordinator.webView)
    XCTAssertTrue(live.coordinator.webView === originalWeb)
    XCTAssertTrue(live.coordinator.acceptsInput)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(bootCount, 1)
    let source = SceneRasterSource.document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0))
    let raster = try XCTUnwrap(resources.retainRaster(for: source))
    defer { raster.release() }
    XCTAssertLessThanOrEqual(try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil)).width, 256)
    XCTAssertLessThan(raster.pixelScale, 1)
    XCTAssertNil(resources.retainRaster(for: source, minimumScale: 2), "A borrowed thumbnail is not an exact export")
  }

  func testMacDocumentHostKeepsCanonicalPaperWhenTheHelperWindowChangesSize() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Один физический лист")])
    let state = DocumentStateJournal(id: document.id, actor: UUID())
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let paper = WorkspaceItemGeometry.document(document.paperSize), canonical = CGSize(width: paper.width, height: paper.height)
    XCTAssertEqual(web.bounds.size, canonical)
    surface.window.setContentSize(.init(width: canonical.width + 17, height: canonical.height + 29))
    surface.host.layoutSubtreeIfNeeded()
    XCTAssertEqual(web.bounds.size, canonical)
    let raster = try await surface.coordinator.retainPreparedSnapshot(pixelWidth: 256)
    defer { raster.release() }
    let bitmap = try XCTUnwrap(raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertLessThanOrEqual(bitmap.width, 256)
    XCTAssertGreaterThanOrEqual(bitmap.height, Int(floor(Double(bitmap.width) * canonical.height / canonical.width)))
    XCTAssertEqual(raster.image.size, canonical)
  }

  func testCausalSourceABAReplacesTheRuntimeEvenWhenBytesReturnToOriginal() async throws {
    let actor = UUID(), resources = SceneRenderResources(maximumWebSurfaces: 1)
    let lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: .display(scale: 1),
      onRenderReady: { ready = $0 }, onState: { _, completion in completion(nil); return true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 240, height: 120),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { coordinator.invalidate(); lease.release(); window.orderOut(nil); window.close() }
    let original = AgentElement(id: "program", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 120),
      source: "program", html: "<output>same bytes</output>",
      javaScript: "window.boot=Math.random().toString();notebook.ready(Promise.resolve());")
    var page = PageDocument(size: .init(width: 400, height: 400), actor: actor, elements: [original])
    coordinator.load(original, basis: page.programStateBasis(original.id), in: web)
    await waitUntil { ready && coordinator.hasLiveSource(original) }
    let first = try await js("window.boot", web)
    let other = AgentElement(id: original.id, kind: .web, frame: original.frame, source: "other", html: original.html,
      javaScript: original.javaScript)
    XCTAssertTrue(page.replaceElements([other], actor: actor))
    XCTAssertTrue(page.replaceElements([original], actor: actor))
    coordinator.load(original, basis: page.programStateBasis(original.id), in: web)
    await waitUntil { ready && coordinator.hasLiveSource(original) }
    let second = try await js("window.boot", web)
    XCTAssertNotEqual(first, second, "Source equality must not give an obsolete heap new write authority")
  }

  func testSpatialCheckpointKeepsItsOwnerOnWriterRefusalAndCapturesTheAcceptedState() async throws {
    let resources = SceneRenderResources(), focus = InteractiveElementReference.page(pageID: UUID(), elementID: "phase")
    let lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: .display(scale: 1),
      onRenderReady: { ready = $0 }, onState: { _, completion in completion(nil); return true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 240, height: 120),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { coordinator.invalidate(); lease.release(); window.orderOut(nil); window.close() }
    let source = AgentElement(id: "phase", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 120),
      source: "phase", html: "<output>0.5</output>", javaScript: """
      window.boot=Math.random().toString();window.lifecycleCalls={pause:0,checkpoint:0,resume:0};
      notebook.lifecycle({pause(){lifecycleCalls.pause++},
        checkpoint(){lifecycleCalls.checkpoint++;return {phase:0.5}},resume(){lifecycleCalls.resume++}});
      notebook.semantic(()=>({objectID:'gear-a',label:'Gear',anchor:{x:.5,y:.5},values:[],model:{phase:.5}}));
      notebook.ready(Promise.resolve());
      """, state: .object(["phase": .number(0)]))
    let actor = UUID()
    var page = PageDocument(size: .init(width: 240, height: 120), actor: actor, elements: [source])
    let originalBasis = try XCTUnwrap(page.programStateBasis(source.id))
    coordinator.bindPresentation(to: focus); coordinator.load(source, basis: originalBasis, in: web)
    await waitUntil { ready }
    let boot = try await js("window.boot", web)
    do {
      _ = try await AgentWebCoordinator.checkpointCurrent(focus: focus, element: source, persist: { _, basis, _ in
        XCTAssertEqual(basis, originalBasis); return nil
      }, resources: resources)
      XCTFail("Writer refusal is not saved")
    } catch { XCTAssertTrue(String(describing:error).contains("checkpoint_not_accepted")) }
    XCTAssertTrue(coordinator.hasLiveSource(source))
    let suspended = try await js("String(notebookProgram.suspended)", web)
    XCTAssertEqual(suspended, "true", "Writer refusal retains the frozen author until its exact value is durable")
    let failedCalls = try await js("JSON.stringify(lifecycleCalls)", web)
    XCTAssertEqual(failedCalls, "{\"pause\":1,\"checkpoint\":1,\"resume\":0}")
    let furtherCommit = try await js("String(notebook.commit({phase:9}))", web)
    XCTAssertEqual(furtherCommit, "false", "A refused checkpoint cannot silently resume state admission")
    var persisted: JSONValue?
    let (accepted, picture) = try await AgentWebCoordinator.checkpointCurrent(focus: focus, element: source, persist: { value, basis, _ in
      XCTAssertEqual(basis, originalBasis)
      persisted = value
      page.replaceElements([source.updating(state: value)], actor: actor)
      return page.programStateBasis(source.id)
    }, resources: resources)
    defer { picture.release() }
    XCTAssertEqual(persisted, .object(["phase": .number(0.5)]))
    XCTAssertEqual(accepted.state, persisted)
    let retriedCalls = try await js("JSON.stringify(lifecycleCalls)", web)
    XCTAssertEqual(retriedCalls, failedCalls, "Writer Retry cannot repeat pause/checkpoint or resume the same frozen heap")
    let currentBoot = try await js("window.boot", web)
    XCTAssertEqual(currentBoot, boot, "Retry must not rerun author startup")
    XCTAssertEqual(picture.semanticSelection?.objectID, "gear-a")
    XCTAssertEqual(picture.semanticSelection?.model["phase"], .number(0.5))
    let retained = try XCTUnwrap(picture.retainedCopy()); defer { retained.release() }
    XCTAssertEqual(retained.semanticSelection, picture.semanticSelection)
    XCTAssertTrue(coordinator.hasLiveSource(accepted))
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
    coordinator.load(source, basis: originalBasis, in: web)
    XCTAssertTrue(coordinator.hasLiveSource(accepted), "A stale SwiftUI echo cannot roll back the checkpoint receipt")
    let savedModel = try await js("JSON.stringify(notebook.state)", web)
    XCTAssertEqual(savedModel, "{\"phase\":0.5}")
  }

  func testAgentStateAndPlacementKeepProgramFocusAndUncommittedInput() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1)
    let lease = try await resources.acquireWebSurface(priority: .input)
    var ready = false, commits: [JSONValue] = []
    let coordinator = AgentWebCoordinator(lease: lease, resources: resources, snapshotPolicy: .display(scale: 1),
      onRenderReady: { ready = $0 }, onState: { value, completion in commits.append(value); completion(nil); return true })
    let web = AgentWebCoordinator.makeWebView(coordinator: coordinator)
    let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: 240, height: 120),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { coordinator.invalidate(); lease.release(); window.orderOut(nil); window.close() }
    let original = AgentElement(id: "program", kind: .web, frame: .init(x: 0, y: 0, width: 240, height: 120),
      source: "counter", html: "<input><button>Next</button>", javaScript: """
      window.boot=Math.random().toString();
      document.querySelector('button').onclick=()=>notebook.commit({count:(notebook.state.count||0)+1});
      notebook.ready(Promise.resolve());
      """, state: .object(["count": .number(0)]))
    coordinator.load(original, in: web)
    await waitUntil { ready }
    let token = coordinator.loadToken, boot = try await js("window.boot", web)
    _ = try await js("document.querySelector('input').value='UNCOMMITTED INPUT'; document.querySelector('button').click(); 'clicked'", web)
    await waitUntil { commits.count == 1 }
    let echoed = original.updating(state: try XCTUnwrap(commits.last))
    coordinator.load(echoed, in: web)
    await waitUntil { ready && resources.image(for: echoed) != nil }
    let moved = echoed.updating(frame: .init(x: 100, y: 200, width: 240, height: 120))
    coordinator.load(moved, in: web)
    let sameBoot = try await js("window.boot", web)
    let input = try await js("document.querySelector('input').value", web)
    XCTAssertEqual(sameBoot, boot)
    XCTAssertEqual(input, "UNCOMMITTED INPUT")
    XCTAssertEqual(coordinator.loadToken, token)
    _ = try await js("document.querySelector('button').click(); 'clicked again'", web)
    await waitUntil { commits.count == 2 }
    XCTAssertEqual(commits.last, .object(["count": .number(2)]))
    XCTAssertNotNil(resources.image(for: moved))
  }

  func testRepeatedRendererMountDoesNotInvalidateObservation() async throws {
    let registry = DocumentRenderRegistry(), resources = SceneRenderResources()
    let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    defer { coordinator.invalidate() }
    let hostID = UUID(), documentID = UUID()
    let invalidation = expectation(description: "Transient renderer bookkeeping is not SwiftUI content")
    invalidation.isInverted = true
    withObservationTracking {
      registry.mountRenderer(coordinator, hostID: hostID)
      _ = registry.rasterProducer(documentID: documentID, token: "source", resources: resources, excluding: UUID())
    } onChange: { invalidation.fulfill() }
    for _ in 0..<100 {
      registry.mountRenderer(coordinator, hostID: hostID)
      registry.publishLive(documentID: documentID, token: "source", pageIndex: 0, hostID: hostID, generation: 1, isAttached: { _ in false })
    }
    registry.unmountRenderer(hostID: hostID)
    await fulfillment(of: [invalidation], timeout: 0.05)
  }




  func testAnOffPageStateChangeKeepsTheActualPaperFrameAndItsCompositeKey() async throws {
    let document = DocumentDocument(actor: UUID(), blocks: [
      .markdown(id: "body", source: String(repeating: "Independent paper and formulas $x^2$.\n\n", count: 160)),
      .interactive(id: "far", html: "<button>Far</button>", height: 100)])
    let actor = UUID()
    var state = DocumentStateJournal(id: document.id, actor: actor)
    XCTAssertTrue(state.commit(blockID: "far", value: .number(1), actor: actor))
    let surface = surface(document: document, state: state)
    defer { surface.close() }
    await waitUntil { surface.coordinator.hasCanonicalPixels }
    let web = try XCTUnwrap(surface.coordinator.webView)
    let before = try await js("JSON.stringify(notebookRenderer.pageReceipt().work)", web)
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0)
    let packet = try XCTUnwrap(surface.coordinator.payload?.state)
    XCTAssertFalse(surface.coordinator.payload?.source.layout?.blockIDs(on: [0]).contains("far") ?? true)
    XCTAssertTrue(state.commit(blockID: "far", value: .number(2), actor: actor))
    surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _,_ in nil })
    XCTAssertTrue(surface.coordinator.hasCanonicalPixels)
    XCTAssertTrue(surface.coordinator.payload?.state === packet)
    XCTAssertEqual(DocumentSnapshotCache.token(document: document, state: state, pageIndex: 0), token)
    XCTAssertEqual(surface.coordinator.payload?.rasterToken, token)
    let after = try await js("JSON.stringify(notebookRenderer.pageReceipt().work)", web)
    XCTAssertEqual(after, before)
  }

  func testFourRealPageWebKitsShareInputsAndOneAcceptedLayoutWithoutAnotherWebSurface() async throws {
    let prose = (0..<80).map { "Абзац \($0). " + String(repeating: "Одна геометрия исходника и четыре физических листа. ", count: 4) }.joined(separator: "\n\n")
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Общая сессия $x^2$\n\n" + prose)])
    let state = DocumentStateJournal(id: document.id, actor: UUID()), resources = SceneRenderResources(maximumWebSurfaces: 6)
    let pages = (0..<4).map { surface(document: document, state: state, resources: resources, interactive: $0 == 0, pageIndex: $0) }
    defer { pages.forEach { $0.close() } }
    await waitUntil { pages.allSatisfy { $0.coordinator.renderIsReady } || pages.contains { $0.coordinator.acquisitionError != nil } }
    let source = try XCTUnwrap(pages[0].coordinator.payload?.source), layout = try XCTUnwrap(source.layout)
    XCTAssertGreaterThanOrEqual(layout.pageCount, 4)
    var layoutPasses = 0, typesetPasses = 0, preparationRoots = 0
    for (index, page) in pages.enumerated() {
      XCTAssertNil(page.coordinator.acquisitionError)
      XCTAssertTrue(page.coordinator.renderIsReady)
      XCTAssertTrue(page.coordinator.payload?.source === source)
      XCTAssertTrue(page.coordinator.payload?.state === pages[0].coordinator.payload?.state)
      XCTAssertTrue(DocumentRenderRegistry.shared.entry(document: document, pageIndex: index)?.layout === layout)
      let web = try XCTUnwrap(page.coordinator.webView)
      let pageNumber = try await js("String(window.notebookRenderer.pageReceipt().pageIndex)", web)
      XCTAssertEqual(pageNumber, String(index))
      let raw = try await js("JSON.stringify({work:notebookRenderer.pageReceipt().work,scope:notebookRenderer.pageReceipt().layoutScope,regions:notebookRenderer.pageReceipt().regions,domText:document.getElementById('document').textContent,preparations:document.querySelectorAll('.document-layout-preparation').length,sheets:document.querySelectorAll('.paper-sheet').length})", web)
      let measured = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
      let work = try XCTUnwrap(measured["work"] as? [String: Int])
      layoutPasses += work["layoutPasses"] ?? -100; typesetPasses += work["typesetPasses"] ?? -100
      XCTAssertEqual(measured["scope"] as? String, "page")
      preparationRoots += try XCTUnwrap(measured["preparations"] as? Int)
      XCTAssertEqual(measured["sheets"] as? Int, 1)
      XCTAssertLessThan(try XCTUnwrap(measured["domText"] as? String).count, prose.count / 2)
      let regions = try XCTUnwrap(measured["regions"] as? [[String: Any]])
      XCTAssertTrue(regions.allSatisfy { $0["pageIndex"] as? Int == index })
    }
    XCTAssertEqual(preparationRoots, 0, "Canonical PDF/SyncTeX owns source layout; no physical WebKit owns an alternate DOM source index")
    XCTAssertEqual(layoutPasses, 0); XCTAssertEqual(typesetPasses, 0)
    XCTAssertEqual(source.preparationCount, 1)
    XCTAssertEqual(source.measurementCount, 1)
    XCTAssertEqual(pages[0].coordinator.payload?.state.encodingCount, 1)
    XCTAssertEqual(resources.activeWebSurfaceCount, 4); XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  func testTwoSynchronousGenerationsKeepTheLatestUnfinishedProgramBounded() async throws {
    let actor = UUID(), resources = SceneRenderResources(maximumWebSurfaces: 1)
    var document = DocumentDocument(actor: actor, blocks: [.markdown(id: "body", source: "Готовая страница")])
    var state = DocumentStateJournal(id: document.id, actor: actor)
    let surface = surface(document: document, state: state, resources: resources)
    defer { surface.close() }
    await waitUntil { surface.coordinator.renderIsReady }
    XCTAssertTrue(document.replaceContent(blocks: document.blocks + [.interactive(id: "never-ready", html: "<p>Ожидание программы</p>",
      javaScript: "notebook.ready(new Promise(()=>{}));", height: 100)], actor: actor))
    func update() {
      surface.coordinator.update(document: document, state: state, selectedPageIndex: 0, capturesSnapshot: false,
        onRenderReady: .init { _ in }, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    }
    // Both accepted generations precede the sender Task's first opportunity to
    // execute. Its first deadline cannot be left naming the superseded one.
    update()
    XCTAssertTrue(state.commit(blockID: "never-ready", value: .number(1), actor: actor))
    update()
    let web = try XCTUnwrap(surface.coordinator.webView)
    XCTAssertEqual(surface.coordinator.payload?.states["never-ready"], .number(1))
    var started = false
    for _ in 0..<200 {
      if try await js("String(document.querySelectorAll('iframe').length)", web) == "1" { started = true; break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(started, "The bounded failure must come from the real pending program, not a missing shell")
    // Both the native preparation and author readiness deadlines remain eight
    // seconds. Their first real failure wins; neither may wait indefinitely on
    // a superseded generation or be replaced by this observation window.
    await waitUntil(timeout: .seconds(10)) { surface.coordinator.acquisitionError != nil }
    let error = try XCTUnwrap(surface.coordinator.acquisitionError as? SceneRenderError)
    XCTAssertTrue(error == .snapshotPending("document_preparation_timeout")
      || error == .snapshotPending("Error: program_ready_timeout"), "Unexpected first deadline: \(error)")
    XCTAssertEqual(surface.coordinator.payload?.states["never-ready"], .number(1),
      "The failure belongs to the newest admitted state generation")
    XCTAssertEqual(surface.coordinator.payload?.programIdentities["never-ready"], document.programIdentity(blockID: "never-ready"))
    XCTAssertFalse(surface.coordinator.renderIsReady)
    // Failure is visible before asynchronous accepted-state teardown finishes.
    // Even this empty heap leaves through the same boundary as authored commits.
    await waitUntil { surface.coordinator.webView == nil && resources.activeWebSurfaceCount == 0 }
    XCTAssertNil(surface.coordinator.webView)
    XCTAssertEqual(resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
  }

  private func execute(_ script: String, arguments: [String: Any], in web: WKWebView) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
        switch result {
        case .success(let value):
          if value as? Bool == true { continuation.resume() }
          else { continuation.resume(throwing: DocumentSessionError.invalidLayout) }
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
    }
  }

  private func js(_ source: String, _ web: WKWebView) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      web.evaluateJavaScript(source) { value, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: value as? String ?? String(describing: value)) }
      }
    }
  }

  private func waitUntil(timeout: Duration = .seconds(8), file: StaticString = #filePath, line: UInt = #line,
    _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The real WebKit surface did not complete its bounded preparation at \(file):\(line)", file: file, line: line)
  }
}
