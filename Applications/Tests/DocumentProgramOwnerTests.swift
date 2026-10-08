import NotebookCore
import PDFKit
import SwiftUI
import UIKit
import Vision
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentProgramOwnerTests: XCTestCase {
  func testSameSourceResizeKeepsTheHeapAndItsAcceptedSnapshotThroughTheWriterBoundary() async throws {
    let actor = UUID(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    let workspace = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), board = try store.loadBoard(items: index.items)
    let item = try XCTUnwrap(index.createDocument(title: "Geometry lifecycle", actor: actor))
    XCTAssertTrue(board.addItem(item.id, to: workspace.rootBoardID, near: .zero, actor: actor))
    var document = try DocumentTestFiles.document(id: item.id, actor: actor, contents: [.program(id: "geometry", html: "<output>State</output>",
      javaScript: "window.boots=(window.boots||0)+1;notebook.ready(Promise.resolve());", initialState: .number(0), height: 120)]).materializingCausalVersions()
    let program = try store.documentProgramSource(document: document, instanceID: "geometry", path: "programs/geometry")
    var state = DocumentStateJournal(id: document.id, actor: actor), width = 360.0, height = 120.0
    XCTAssertTrue(state.commit(instanceID: "geometry", value: .number(0), actor: actor))
    try store.saveDocumentWorkspaceBundle(index: index, document: document, state: state, board: board)
    let initial = state
    var acceptedWrites: [JSONValue] = [], refusesCheckpoint = true, checkpointAttempts = 0
    let resources = SceneRenderResources(), owner = DocumentProgramOwner(documentID: document.id, resources: resources)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
    defer { owner.stop(); window.isHidden = true; window.rootViewController = nil }
    owner.onMount = { web, size in web.frame = .init(origin: .zero, size: size); container.view.addSubview(web) }
    let paper = DocumentPaperLayout(widthPoints: 720, heightPoints: 400), activity = PageTurnActivity()
    func refresh() throws {
      let layout = try DocumentLayoutRecord(receipt: ["sourceKey": "geometry", "layoutScope": "source", "layoutCanonical": true,
        "pageCount": 1, "width": paper.surfaceWidth, "height": paper.surfaceHeight,
        "pages": [["widthPoints": paper.widthPoints, "heightPoints": paper.heightPoints]],
        "regions": [["kind": "program", "id": "geometry", "pageIndex": 0, "x": 0.0, "y": 0.0, "width": width,
          "height": height, "sourceOffset": 0.0]], "anchors": [], "reading": []] as NSDictionary,
        sourceKey: "geometry", blockIDs: ["geometry"], geometry: paper.geometry)
      let input = DocumentPagePresentation(document: document, state: state, pageIndex: 0, isCurrent: true,
        isVisible: true, isInteractive: true, pageTurnActive: false, onRenderReady: .init(activity: activity) { _ in },
        onPageLayout: { _ in }, onStateChange: { source, value in
          XCTAssertEqual(source.sourceBasis, program.sourceBasis)
          acceptedWrites.append(value); _ = state.commit(instanceID: source.id, value: value, actor: actor)
          try store.saveDocumentState(state)
          return state.records.first { $0.id == source.id }?.valueVersion
        }, onLinkActivation: { _ in }, snapshotPixelWidth: nil, onPreparationFailure: { _ in },
        onStateCheckpoint: { id, value, source, basis in
          checkpointAttempts += 1
          if refusesCheckpoint { throw SceneRenderError.snapshotPending("geometry_writer_unavailable") }
          guard source.sourceBasis == program.sourceBasis, state.records.first(where: { $0.id == id })?.valueVersion == basis else { return nil }
          _ = state.commit(instanceID: id, value: value, actor: actor); try store.saveDocumentState(state)
          return state.records.first { $0.id == id }?.valueVersion
        }, programStore: store)
      owner.update(input: input, layout: layout, programs: [program], pages: [0], currentPage: 0,
        visibleIDs: ["geometry"], preparationPage: nil, blocked: false, contacts: [], densities: [:])
    }
    try refresh()
    try await wait(message: { "geometry runtime readiness" }) { owner.runtime(for: "geometry")?.ready == true }
    let runtime = try XCTUnwrap(owner.runtime(for: "geometry")), web = try XCTUnwrap(runtime.webView)
    let accepted = try await web.evaluateJavaScript("""
      const original=documentProgram;
      window.documentProgram=Object.create(original,{readSnapshot:{value:argument=>{
        if(window.allowPull)return original.readSnapshot(argument);
        window.pullStarted=true;
        return new Promise(resolve=>{window.releasePull=()=>{window.allowPull=true;resolve(original.readSnapshot(argument))}});
      }}});
      [notebook.commit({acceptedBeforeGeometry:1}),notebook.commit({acceptedBeforeGeometry:2})];
      """) as? [Bool]
    XCTAssertEqual(accepted, [true, true])
    let deadline = ContinuousClock.now + .seconds(3)
    var pulling = false
    while !pulling, ContinuousClock.now < deadline {
      pulling = try await web.evaluateJavaScript("window.pullStarted===true") as? Bool == true
      if !pulling { try await Task.sleep(for: .milliseconds(10)) }
    }
    XCTAssertTrue(pulling)
    width = 400; height = 160
    let main = try XCTUnwrap(document.files.first { $0.path == "main.tex" })
    XCTAssertTrue(document.replaceFileSource(id: main.id, source: "% Relayout only\n" + main.source, actor: actor))
    XCTAssertEqual(try DocumentProgramSource(document: document, instanceID: program.id, path: program.path).sourceBasis, program.sourceBasis)
    try refresh()
    XCTAssertTrue(owner.runtime(for: program.id) === runtime && runtime.webView === web)
    XCTAssertEqual(runtime.viewportSize, CGSize(width: width, height: height))
    XCTAssertEqual(checkpointAttempts, 0, "Layout does not freeze or restart an unchanged program")
    XCTAssertEqual(try store.loadDocumentState(document.id).records, initial.records)
    _ = try await web.evaluateJavaScript("window.releasePull();true")
    try await wait(message: { "Both accepted snapshots reach the existing writer in order" }) { acceptedWrites.count == 2 }
    XCTAssertEqual(acceptedWrites, [1, 2].map { .object(["acceptedBeforeGeometry": .number(Double($0))]) })
    let saved = await owner.checkpointAll(resume: false)
    XCTAssertFalse(saved); XCTAssertEqual(checkpointAttempts, 1)
    XCTAssertTrue(owner.runtime(for: program.id) === runtime && runtime.webView === web)
    width += 32; try refresh()
    XCTAssertEqual(checkpointAttempts, 1, "A resize is not a retry of a failed durable boundary")
    refusesCheckpoint = false; owner.retry(program.id)
    try await wait(message: { "The same frozen writer stage retries" }) { checkpointAttempts == 2 && owner.pauseFailure(for: program.id) == nil }
    let resumed = await owner.resumeAll(); XCTAssertTrue(resumed)
    try refresh()
    XCTAssertTrue(owner.runtime(for: program.id) === runtime && runtime.webView === web)
    XCTAssertEqual(runtime.viewportSize, CGSize(width: width, height: height))
    let boots = try await web.evaluateJavaScript("window.boots") as? Int
    XCTAssertEqual(boots, 1)
    XCTAssertEqual(try store.loadDocumentState(document.id).records.first?.value, .object(["acceptedBeforeGeometry": .number(2)]))
  }

  func testSameIdentityGeometryDoesNotRetryAnAlreadyFailedAuthor() async throws {
    let actor = UUID(), resources = SceneRenderResources()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let document = DocumentTestFiles.document(actor: actor, contents: [.program(id: "failed", html: "<output>Failed author</output>",
      javaScript: "throw Error('author needs explicit Retry')", height: 120)])
    let program = try store.documentProgramSource(document: document, instanceID: "failed", path: "programs/failed")
    let state = DocumentStateJournal(id: document.id, actor: actor)
    let owner = DocumentProgramOwner(documentID: document.id, resources: resources)
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let container = UIViewController(); window.rootViewController = container; window.makeKeyAndVisible()
    defer { owner.stop(); window.isHidden = true; window.rootViewController = nil }
    var mounts = 0, height = 120.0
    owner.onMount = { web, size in mounts += 1; web.frame = .init(origin: .zero, size: size); container.view.addSubview(web) }
    let paper = DocumentPaperLayout(widthPoints: 720, heightPoints: 400), activity = PageTurnActivity()
    func refresh() throws {
      let layout = try DocumentLayoutRecord(receipt: ["sourceKey": "failed", "layoutScope": "source", "layoutCanonical": true,
        "pageCount": 1, "width": paper.surfaceWidth, "height": paper.surfaceHeight,
        "pages": [["widthPoints": paper.widthPoints, "heightPoints": paper.heightPoints]],
        "regions": [["kind": "program", "id": "failed", "pageIndex": 0, "x": 0.0, "y": 0.0, "width": 360.0,
          "height": height, "sourceOffset": 0.0]], "anchors": [], "reading": []] as NSDictionary,
        sourceKey: "failed", blockIDs: ["failed"], geometry: paper.geometry)
      let input = DocumentPagePresentation(document: document, state: state, pageIndex: 0, isCurrent: true,
        isVisible: true, isInteractive: true, pageTurnActive: false, onRenderReady: .init(activity: activity) { _ in },
        onPageLayout: { _ in }, onStateChange: { _, _ in nil }, onLinkActivation: { _ in }, snapshotPixelWidth: nil,
        onPreparationFailure: { _ in }, programStore: store)
      owner.update(input: input, layout: layout, programs: [program], pages: [0], currentPage: 0, visibleIDs: ["failed"],
        preparationPage: nil, blocked: false, contacts: [], densities: [:])
    }
    try refresh()
    try await wait(message: { "Author failure completed its accepted-state boundary" }) {
      owner.runtime(for: "failed")?.failure != nil && owner.runtime(for: "failed")?.webView == nil
    }
    let failed = try XCTUnwrap(owner.runtime(for: "failed"))
    height = 160; try refresh()
    _ = await owner.checkpointAll(resume: true)
    XCTAssertTrue(owner.runtime(for: "failed") === failed)
    XCTAssertNotNil(failed.failure); XCTAssertNil(failed.webView); XCTAssertEqual(mounts, 1)
    owner.retry("failed")
    try await wait(message: { "Only explicit Retry admits another author" }) { mounts > 1 }
  }

  func testAttentionReleaseCannotResumeAClosedProgramBoundary() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program", html: "<output>Model</output>",
      javaScript: """
        window.resumes=0;notebook.lifecycle({checkpoint(){return {phase:.5}},resume(){resumes++}});
        notebook.ready(Promise.resolve());
      """, height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "program") != nil }
    let web = try XCTUnwrap(fixture.web(block: "program"))
    let paused = try await DocumentPagePresentationOwner.pauseForAttention(documentID: document.id, blockID: "program", resources: fixture.resources)
    defer { paused.release() }
    let saved = await DocumentPagePresentationOwner.checkpointPrograms(documentID: document.id, resources: fixture.resources, resume: false)
    XCTAssertTrue(saved)
    paused.release()
    // Join the real lifecycle queue after release's asynchronous callback;
    // a release cannot become a foreground command between these cuts.
    let stillSaved = await DocumentPagePresentationOwner.checkpointPrograms(documentID: document.id, resources: fixture.resources, resume: false)
    XCTAssertTrue(stillSaved)
    let beforeForeground = try await web.evaluateJavaScript("resumes") as? Int
    XCTAssertEqual(beforeForeground, 0); XCTAssertFalse(web.isUserInteractionEnabled)
    await DocumentPagePresentationOwner.resumePrograms(resources: fixture.resources)
    let afterForeground = try await web.evaluateJavaScript("resumes") as? Int
    XCTAssertEqual(afterForeground, 1); XCTAssertTrue(web.isUserInteractionEnabled)
  }

  func testLateCheckpointFailureCannotPoisonTheReplacementProgram() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program", html: "<input aria-label='Value'>",
      javaScript: "notebook.lifecycle({checkpoint:()=>({value:1})});notebook.ready(Promise.resolve());", height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    var held: CheckedContinuation<Void, Never>?
    defer {
      fixture.acceptsCheckpoints = true; fixture.onCheckpoint = { _ in }
      held?.resume(); fixture.close()
    }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "program") != nil }
    let original = try XCTUnwrap(fixture.web(block: "program"))
    let runtime = try XCTUnwrap(original.navigationDelegate as? DocumentBlockRuntime)
    _ = try await original.evaluateJavaScript("document.querySelector('input').focus();true")
    try await wait(message: { fixture.diagnostics }) { runtime.focused }

    fixture.onCheckpoint = { _ in await withCheckedContinuation { held = $0 } }
    let checkpoint = Task { @MainActor in
      await DocumentPagePresentationOwner.checkpointFocusedProgram(documentID: document.id,
        resources: fixture.resources, resume: true)
    }
    defer { checkpoint.cancel() }
    try await wait(message: { fixture.diagnostics }) { held != nil }
    fixture.replaceSource(fileID: "program-js", source:
      "window.replacement=true;notebook.lifecycle({checkpoint:()=>({value:2})});notebook.ready(Promise.resolve());")
    // The successor slot can replace the old owner immediately. Its WebKit
    // admission waits for the old writer's physical borrow of this source.
    try await wait(message: { fixture.diagnostics }) { runtime.webView == nil }
    fixture.acceptsCheckpoints = false
    held?.resume(); held = nil
    let completed = await checkpoint.value
    XCTAssertTrue(completed, "The departed runtime's writer failure does not fail its successor's navigation")
    fixture.acceptsCheckpoints = true
    try await wait(message: { fixture.diagnostics }) {
      fixture.isPresented && fixture.web(block: "program") != nil && fixture.web(block: "program") !== original
    }
    let replacement = try XCTUnwrap(fixture.web(block: "program"))
    XCTAssertFalse(fixture.hasProgramAction("program"), "An old heap cannot publish Retry over its replacement")
    XCTAssertTrue(replacement.isUserInteractionEnabled)
  }

  func testShippedSoundOpeningReportsPaperNavigationAndProgramReadinessSeparately() async throws {
    func source(_ name: String, _ ext: String) throws -> String {
      try String(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "science")), encoding: .utf8)
    }
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "sound", html: try source("sound", "html"),
      css: try source("common", "css"), javaScript: try ["models", "runtime", "sound"].map { try source($0, "js") }.joined(separator: "\n"), height: 800)])
    // The second open reuses canonical print artifacts, not a program or heap.
    for attempt in 0..<2 {
      let recorder = DocumentPresentationRecorder(enabled: true)
      recorder.request(documentID: document.id, pageIndex: 0, cause: .open)
      let start = ProcessInfo.processInfo.systemUptime
      let fixture = try ProgramFixture(document: document, measurements: recorder, showsNeighbour: false)
      defer { fixture.close() }
      func program(_ view: UIView) -> WKWebView? {
        if let web = view as? WKWebView, web.accessibilityIdentifier == "document-program-sound" { return web }
        for child in view.subviews {
          if let found = program(child) { return found }
        }
        return nil
      }
      var phases: [String: Double] = [:]
      let deadline = ContinuousClock.now + .seconds(15)
      while ContinuousClock.now < deadline {
        let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
        if fixture.installedPaper != nil, phases["paper"] == nil { phases["paper"] = elapsed }
        if let web = program(fixture.hosts[0]) {
          if phases["programAttached"] == nil { phases["programAttached"] = elapsed }
          if web.url != nil, !web.isLoading, phases["navigationFinished"] == nil { phases["navigationFinished"] = elapsed }
          if (web.navigationDelegate as? DocumentBlockRuntime)?.ready == true, phases["programReady"] == nil { phases["programReady"] = elapsed }
        }
        if fixture.isPresented { phases["installed"] = elapsed; break }
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertTrue(fixture.isPresented, fixture.diagnostics)
      let web = try XCTUnwrap(fixture.web(block: "sound"))
      let proof: [String: Any] = ["attempt": attempt, "observationIntervalMS": 5, "nativeMS": phases,
        "scope": "native window; second open has cached paper, not a cold app process"]
      let data = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
      let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
      attachment.name = "sound-opening-stages-\(attempt)"; attachment.lifetime = .keepAlways; add(attachment)
      let paper = XCTAttachment(data: try JSONEncoder().encode(recorder.records), uniformTypeIdentifier: "public.json")
      paper.name = "sound-opening-paper-\(attempt)"; paper.lifetime = .keepAlways; add(paper)
      let preparation = try XCTUnwrap(recorder.records.last?.pagePreparationPhasesMS)
      let shellReady = try XCTUnwrap([preparation["shellReadyMessageAt"], preparation["shellNavigationFinishedAt"]].compactMap { $0 }.min())
      XCTAssertLessThan(try XCTUnwrap(preparation["preparedPageStartAt"]), shellReady,
        "Canonical print must not wait for the independent browser shell")
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(preparation["frameEvaluationStartAt"]), shellReady,
        "Submitting JS still requires the current shell")
      XCTAssertTrue(web.isUserInteractionEnabled)
      fixture.close()
      try await wait(message: { fixture.diagnostics }) { fixture.resources.activeWebSurfaceCount == 0 }
    }
  }

  func testFrozenObjectIsBoundToPresentedDocumentPixelsAndNotTheResumedPage() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .tex(id: "heading", source: "\\section{Exact selected frame}\\hypertarget{exact-selected-frame}{}"),
      .program(id: "probe", html: "<canvas width='600' height='180' style='display:block;width:100%;height:180px'></canvas>", javaScript: """
        let phase=0;const ctx=document.querySelector('canvas').getContext('2d');
        const draw=c=>{ctx.fillStyle=c;ctx.fillRect(0,0,600,180)};draw('green');
        notebook.lifecycle({pause:()=>{phase=.5;draw('blue')},checkpoint:()=>({phase}),resume:()=>{phase=.75;draw('red')}});
        notebook.semantic(()=>({objectID:'probe',label:'Selected node',anchor:{x:.5,y:.5},values:[],model:{phase}}));
        notebook.ready(Promise.resolve());
      """, height: 180)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "probe") != nil }
    let web = try XCTUnwrap(fixture.web(block: "probe"))
    let paused = try await DocumentPagePresentationOwner.pauseForAttention(documentID: document.id, blockID: "probe", resources: fixture.resources)
    defer { paused.release() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented }
    XCTAssertTrue(paused.isCurrent()); XCTAssertFalse(web.isUserInteractionEnabled)
    let region = try XCTUnwrap(DocumentRenderRegistry.shared.regions(document: document).first { $0.id == "probe" }?.frame)
    let geometry = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: 0)
    let page = PageRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
    let pixels = try XCTUnwrap(DocumentPagePresentationOwner.capturePresented(documentID: document.id, pageIndex: 0,
      token: fixture.currentToken, region: page, resources: fixture.resources, blockID: "probe"))
    let model = try XCTUnwrap(pixels.presentation?.program)
    XCTAssertEqual(model.instanceID, "probe")
    XCTAssertEqual(model.sourceBasis, try DocumentProgramSource(document: document, instanceID: "probe", path: "programs/probe").sourceBasis)
    XCTAssertEqual(model.state, .object(["phase": .number(0.5)]))
    let selected = try XCTUnwrap(pixels.semanticSelection)
    XCTAssertEqual(selected.model["phase"], .number(0.5))
    XCTAssertEqual(selected.anchor.x, (region.x + region.width / 2) / page.width, accuracy: 0.001)
    XCTAssertEqual(selected.anchor.y, (region.y + region.height / 2) / page.height, accuracy: 0.001)
    paused.release()
    try await wait(message: { fixture.diagnostics }) { web.isUserInteractionEnabled }
    let current = try await web.evaluateJavaScript("Array.from(document.querySelector('canvas').getContext('2d').getImageData(20,20,1,1).data)") as? [Int]
    XCTAssertEqual(current, [255, 0, 0, 255])
    XCTAssertEqual(pixels.presentation?.program, model, "Resuming the live heap cannot change the captured model")
    let png = try await pixels.png(), image = try XCTUnwrap(UIImage(data: png))
    XCTAssertGreaterThan(try bluePixels(image), 100, "Send copied the blue native page before the same heap resumed red")
    let shot = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    shot.name = "document-frozen-semantic-blue-frame"; shot.lifetime = .keepAlways; add(shot)
  }

  func testAgentFeedbackBorrowsInstalledPaperInkWithoutRecreatingAProgram() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents:[.tex(id:"words",source:"\\section{Видимый результат}\n\nТекст остаётся текстом."),
      .program(id:"program",html:"<button onclick='this.dataset.clicked=1'>Не прерывать</button>",height:100)])
    let fixture = try ProgramFixture(document:document,showsNeighbour:false)
    defer { fixture.close() }
    try await wait(message:{ fixture.diagnostics }) { fixture.isPresented && fixture.web(block:"program") != nil }
    let web = try XCTUnwrap(fixture.paper(in:0)), program = try XCTUnwrap(fixture.web(block:"program"))
    let paper = try XCTUnwrap(fixture.installedPaper,
      "The installed paper owner, not the distinct WebKit coordinator ID, supplies the mask")
    let region = try XCTUnwrap(DocumentRenderRegistry.shared.regions(document:document).first { $0.id == "words" })
    let geometry = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: 0)
    let host = fixture.hosts[0], scale = host.bounds.width/geometry.width
    let target = CollaborationTarget(kind:.document,id:document.id)
    let subject = NotebookAgentFeedbackChange.Subject(reference:.init(target:target,elementID:"words",revision:"fixture"),
      expected:.init(target:target,revision:"fixture"))
    let rect = CGRect(x:region.frame.x*scale,y:region.frame.y*scale,width:region.frame.width*scale,height:region.frame.height*scale)
    let surface = NotebookAgentFeedbackSurface(rect:rect,scale:scale,paper:paper,
      paperOrigin:.init(x:-region.frame.x,y:-region.frame.y),clipRect:rect)
    let start = Date(), episode = NotebookAgentFeedback.Episode(subject:subject,startedAt:start,
      endsAt:start.addingTimeInterval(2.4),isAttention:false)
    let overlay = UIHostingController(rootView:AnyView(EmptyView()))
    let container = try XCTUnwrap(fixture.window.rootViewController)
    container.addChild(overlay); container.view.addSubview(overlay.view); overlay.didMove(toParent:container)
    overlay.view.backgroundColor = .clear; overlay.view.isUserInteractionEnabled = false
    overlay.view.frame = host.frame
    defer { overlay.willMove(toParent:nil); overlay.view.removeFromSuperview(); overlay.removeFromParent() }
    func screen(_ age: Double, reduced: Bool = false) async throws -> UIImage {
      overlay.rootView = AnyView(NotebookAgentFeedbackMaterial(surface:surface,episode:episode,
        date:start.addingTimeInterval(age),reduceMotion:reduced)
        .frame(width:host.bounds.width,height:host.bounds.height,alignment:.topLeading).ignoresSafeArea())
      try await Task.sleep(for:.milliseconds(80)); overlay.view.layoutIfNeeded()
      return UIGraphicsImageRenderer(bounds:host.frame).image { _ in
        container.view.drawHierarchy(in:container.view.bounds,afterScreenUpdates:true)
      }
    }
    let dimensions = XCTAttachment(string:"paper=\(paper.page.width)x\(paper.page.height) mask=\(paper.image.width)x\(paper.image.height) region=\(region.frame) host=\(host.frame) overlay=\(overlay.view.frame) scale=\(scale)")
    dimensions.name="paper-feedback-geometry"; dimensions.lifetime = .keepAlways; add(dimensions)
    let before = try await screen(-1)
    let plain = try await fixture.captureCurrent(); defer { plain.release() }
    let lit = try await screen(0.6)
    XCTAssertNotEqual(before.pngData(),lit.pngData(),"Shimmer must alter the actual printed ink, not an empty DOM")
    XCTAssertTrue(fixture.installedPaper === paper)
    XCTAssertTrue(fixture.paper(in:0) === web && fixture.web(block:"program") === program)
    let canonical = try await fixture.captureCurrent(); defer { canonical.release() }
    XCTAssertEqual(plain.image.pngData(),canonical.image.pngData(),"The sibling material cannot enter canonical paper pixels")
    let expired = try await screen(3)
    XCTAssertEqual(before.pngData(),expired.pngData())
    let stillA = try await screen(0.4,reduced:true), stillB = try await screen(1.4,reduced:true)
    XCTAssertEqual(stillA.pngData(),stillB.pngData())
    XCTAssertNotEqual(before.pngData(),stillA.pngData(),"Reduce Motion must still accent the printed text")
    for (name,image) in [("paper-feedback-before",before),("paper-feedback-ink",lit),("paper-feedback-expired",expired)] {
      let attachment = XCTAttachment(image:image); attachment.name=name; attachment.lifetime = .keepAlways; add(attachment)
    }
    _ = try await program.evaluateJavaScript("document.querySelector('button').click()")
    let clicked = try await program.evaluateJavaScript("document.querySelector('button').dataset.clicked") as? String
    XCTAssertEqual(clicked,"1")
    fixture.retirePresentation(0)
    XCTAssertNil(fixture.installedPaper,"A detached page cannot lend a feedback mask")
  }

  func testSavingIndependentTextKeepsTheProgramContextAndItsUnsavedDOM() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .tex(id: "text", source: "\\section{Original heading}\\hypertarget{original-heading}{}"),
      .program(id: "counter", html: "<button>Increment</button><input value='draft'><output>3</output>", javaScript: """
        window.contextNonce=crypto.randomUUID();
        document.querySelector('button').onclick=()=>{
          notebook.commit({count:notebook.state.count+1});
          document.querySelector('output').textContent=String(notebook.state.count);
        };
      notebook.ready(Promise.resolve());
      """, initialState: .object(["count": .number(3)]), height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "counter") != nil }
    let paper = try XCTUnwrap(fixture.paper(in: 0)), program = try XCTUnwrap(fixture.web(block: "counter"))
    let nonce = try await program.evaluateJavaScript("""
      document.querySelector('input').value='Uncommitted DOM survives';
      document.querySelector('button').click();window.contextNonce
      """) as? String
    try await wait(message: { fixture.diagnostics }) { fixture.number("counter", field: "count") == 4 && fixture.isPresented }
    fixture.replaceSource(fileID: "text", source: "\\section{Corrected independent heading}\\hypertarget{corrected-independent-heading}{}\n\nA locally saved paragraph.")
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented }
    XCTAssertTrue(fixture.paper(in: 0) === paper)
    XCTAssertTrue(fixture.web(block: "counter") === program)
    XCTAssertEqual(fixture.number("counter", field: "count"), 4)
    let retainedNonce = try await program.evaluateJavaScript("window.contextNonce") as? String
    let retainedInput = try await program.evaluateJavaScript("document.querySelector('input').value") as? String
    let installed = try XCTUnwrap(fixture.installedPaper)
    let savedText = PDFDocument(data: installed.page.artifact.pdf)?.page(at: installed.page.pageIndex)?.string
    XCTAssertEqual(retainedNonce, nonce)
    XCTAssertEqual(retainedInput, "Uncommitted DOM survives")
    XCTAssertTrue(savedText?.contains("Corrected independent heading") == true)
  }

  func testInvalidTeXKeepsLastGoodPaperUntilTheRepairedSourceIsInstalled() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "\\Huge Last good paper\\par\\normalsize")], width: 720, height: 400)
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    let original = try XCTUnwrap(fixture.retainedPaper), web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    // Code hides the current paper without closing it or handing its pixels
    // to a thumbnail. Physical invisibility must not erase its last good page.
    fixture.hosts[0].alpha = 0; fixture.setVisible(false)
    XCTAssertFalse(SceneSourceVisibility.isVisible(fixture.hosts[0]))
    fixture.replaceSource(fileID: "body", source: "\\NotebookUndefinedCommand")
    try await wait(message: { fixture.diagnostics }) { !fixture.preparationErrors.isEmpty }
    XCTAssertTrue(fixture.retainedPaper === original)
    fixture.hosts[0].alpha = 1; fixture.setVisible(true)
    await DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources).observePendingPresentationWork()
    fixture.window.layoutIfNeeded()
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertFalse(fixture.canonicalPaper(in: 0), "Old pixels cannot acknowledge a failed source as current")
    XCTAssertTrue(coordinator.retainsPreviousPrint)
    XCTAssertEqual(coordinator.retainedGeometry(on: 0), .document(widthPoints: 720, heightPoints: 400))
    XCTAssertEqual(web.bounds.width / web.bounds.height, 720.0 / 400, accuracy: 0.0001)
    XCTAssertEqual(fixture.document.files.first { $0.id == "body" }?.source, "\\NotebookUndefinedCommand")
    func labels(_ view: UIView) -> [UILabel] { (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels) }
    let warning = try XCTUnwrap(labels(fixture.hosts[0]).first { $0.text?.contains("предыдущая сборка") == true })
    XCTAssertTrue(SceneSourceVisibility.isVisible(warning))
    let screen = try fixture.windowImage()
    let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate; text.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: try XCTUnwrap(screen.cgImage), options: [:]).perform([text])
    XCTAssertTrue((text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").contains("Last good paper"),
      "Returning from Code must show the previous PDF pixels beneath the explicit source error")
    let attachment = XCTAttachment(image: screen); attachment.name = "last-good-custom-paper-after-code-error"; attachment.lifetime = .keepAlways; add(attachment)
    fixture.replaceSource(fileID: "body", source: "A repaired and saved printed page.")
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertFalse(coordinator.retainsPreviousPrint)
    XCTAssertNotEqual(fixture.retainedPaper?.page.artifact.pdf, original.page.artifact.pdf)
    XCTAssertFalse(labels(fixture.hosts[0]).contains { $0.text?.contains("предыдущая сборка") == true })
  }

  func testProgramStateChangesOnlyItsCompositeAndNeverReframesIndependentPaper() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .program(id: "counter", html: "<button>Increment</button><output>0</output>", javaScript: """
        const render=()=>document.querySelector('output').textContent=String(notebook.state.count);
        document.querySelector('button').onclick=()=>{notebook.commit({count:notebook.state.count+1});render()};
        addEventListener('notebookstate',render);
      notebook.ready(Promise.resolve());
      """, initialState: .object(["count": .number(0)]), height: 100),
      .tex(id: "text", source: String(repeating: "Independent physical paper stays measured and installed.\n\n", count: 160)),
      .program(id: "far", html: "<button>Far control</button>", height: 100)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    // The paper's DOM receipt has its own completion boundary beside the program.
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.ready[1] == true && fixture.web(block: "counter") != nil
        && fixture.canonicalPaper(in: 0)
    }
    let paper = try XCTUnwrap(fixture.paper(in: 0)), program = try XCTUnwrap(fixture.web(block: "counter"))
    let coordinator = try XCTUnwrap(paper.navigationDelegate as? DocumentWebCoordinator)
    let old = try await paper.evaluateJavaScript("notebookRenderer.pageReceipt().generation") as? String
    let neighbour = try XCTUnwrap(fixture.hosts[1].snapshotEntryID)
    let token = fixture.token(page: 1)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    _ = try await program.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("counter", field: "count") == 1 && fixture.isPresented }
    await owner.observePendingPresentationWork()
    XCTAssertEqual(fixture.hosts[1].snapshotEntryID, neighbour)
    XCTAssertEqual(fixture.token(page: 1), token)
    XCTAssertTrue(coordinator.payload?.state.records.isEmpty == true)
    fixture.replaceState(blockID: "counter", value: .object(["count": .number(9)]))
    XCTAssertFalse(fixture.isPresented, "Admission to a block's state application is not its painted frame")
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented }
    let shown = try await program.evaluateJavaScript("document.querySelector('output').textContent") as? String
    XCTAssertEqual(shown, "9")
    fixture.replaceState(blockID: "far", value: .object(["checked": .bool(true)]))
    await owner.observePendingPresentationWork()
    let generation = try await paper.evaluateJavaScript("notebookRenderer.pageReceipt().generation") as? String
    XCTAssertEqual(generation, old)
    XCTAssertTrue(fixture.paper(in: 0) === paper && fixture.web(block: "counter") === program)
    XCTAssertEqual(fixture.hosts[1].snapshotEntryID, neighbour)
    XCTAssertEqual(fixture.token(page: 1), token)
    XCTAssertTrue(fixture.isPresented)
  }

  func testBrokenVisibleProgramReleasesItsSlotWithoutBlockingTextOrAnotherControl() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .tex(id: "text", source: "\\section{Independent saved text}\\hypertarget{independent-saved-text}{}"),
      .program(id: "good", html: "<button onclick='notebook.commit({count:1})'>First tap</button>", height: 100),
      .program(id: "bad", html: "<button>Broken</button>", javaScript: "throw new Error('broken fixture')", height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) {
      fixture.web(block: "good") != nil && fixture.hasProgramAction("bad") && fixture.presents(.paper)
    }
    XCTAssertTrue(fixture.presents(.block("text")))
    XCTAssertTrue(fixture.presents(.block("good")))
    XCTAssertFalse(fixture.presents(.block("bad")))
    XCTAssertFalse(fixture.presents(.page))
    let good = try XCTUnwrap(DocumentRenderRegistry.shared.regions(document: document).first { $0.id == "good" }?.frame)
    XCTAssertTrue(fixture.presents(.region(good)))
    let selected = try XCTUnwrap(DocumentPagePresentationOwner.capturePresented(documentID: document.id, pageIndex: 0,
      token: fixture.currentToken, region: good, resources: fixture.resources))
    let png = try await selected.png()
    XCTAssertGreaterThan(png.count, 100)
    let bad = try XCTUnwrap(DocumentRenderRegistry.shared.regions(document: document).first { $0.id == "bad" }?.frame)
    XCTAssertNil(try DocumentPagePresentationOwner.capturePresented(documentID: document.id, pageIndex: 0,
      token: fixture.currentToken, region: bad, resources: fixture.resources), "Unavailable selected pixels cannot be invented")
    XCTAssertFalse(fixture.presents(.region(.init(x: -1, y: 0, width: 100, height: 100))))
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 2, "A failed program cannot retain the slot needed by its neighbour")
    XCTAssertTrue(fixture.preparationErrors.isEmpty, "A program failure is local, not a failure of independent paper")
    let web = try XCTUnwrap(fixture.web(block: "good"))
    _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("good", field: "count") == 1 && fixture.presents(.block("good")) }
  }

  func testFailedProgramAllowsSnapshotAndLiveLandingsWithAnExplicitStatus() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .tex(id: "body", source: String(repeating: "Paper and programs have independent readiness.\n\n", count: 160)),
      .program(id: "bad", html: "<button>Broken neighbour</button>", javaScript: "throw new Error('broken far fixture')", height: 150)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    // Canonical layout is demand-driven. A far link asks its existing source
    // owner for the remaining index; waiting alone does not schedule that work.
    let paper = try XCTUnwrap(fixture.paper(in: 0))
    let renderer = try XCTUnwrap(paper.navigationDelegate as? DocumentWebCoordinator)
    // The native paper may be mounted before its source receipt authorizes links.
    try await wait(message: { fixture.diagnostics }) { renderer.currentLinkOrigin != nil }
    renderer.resolveLink("#bad", origin: try XCTUnwrap(renderer.currentLinkOrigin)) { _ in }
    try await wait(message: { fixture.diagnostics }) { source.layout != nil }
    let layout = try XCTUnwrap(source.layout)
    let target = try XCTUnwrap(layout.regions.first { $0.id == "bad" }?.pageIndex)
    XCTAssertGreaterThan(target, 1)
    fixture.showPages(current: 0, neighbour: target); fixture.restorePresentation(1)
    try await wait(message: {
      "target=\(target) \(fixture.diagnostics)\n" +
        DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: fixture.resources)
    }) { fixture.ready[1] == true }
    XCTAssertTrue(fixture.hosts[1].hasSnapshot, "Canonical paper and the explicit program status form a complete navigation frame")
    XCTAssertTrue(fixture.preparationErrors.isEmpty, "A program failure belongs to its slot, not the physical page")
    fixture.activity.prepare(target, presentation: .live)
    let demand = try XCTUnwrap(fixture.activity.preparationDemand)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    let incoming = try XCTUnwrap(fixture.paper(in: 1))
    XCTAssertFalse(fixture.hosts[1].hasSnapshot)
    fixture.activity.update(true); fixture.activity.didInstall(demand)
    fixture.select(1); fixture.activity.prepare(nil); fixture.activity.update(false)
    try await wait(message: { fixture.diagnostics }) { fixture.presents(.paper) && fixture.hasProgramAction("bad") }
    XCTAssertTrue(fixture.paper(in: 1) === incoming)
    XCTAssertFalse(fixture.hosts[1].hasSnapshot)
    XCTAssertFalse(fixture.presents(.block("bad")))
    XCTAssertTrue(fixture.hosts[1].isUserInteractionEnabled)
  }

  func testIndependentLandingDoesNotJoinAnInvisibleProgramsCheckpoint() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .program(id: "program", html: "<button>Count</button>", css: "",
        javaScript: "notebook.commit({count:7});notebook.ready(Promise.resolve());", initialState: .null, height: 200),
      .tex(id: "body", source: (1...3).map { "\\newpage\\section{Independent page \($0)}An independent paper does not wait for an invisible program's disk acknowledgement." }.joined()
        + "\\newpage\\section{Far}\\hypertarget{far}{}The accepted target is beyond the visible paper and its neighbour.")
    ])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    var held: CheckedContinuation<Void, Never>?
    defer { held?.resume(); fixture.close() }
    fixture.onCheckpoint = { block in
      if block == "program" { await withCheckedContinuation { held = $0 } }
    }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(in: 0) != nil }
    let runtime = try XCTUnwrap(fixture.web(in: 0))
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let target = try XCTUnwrap(source.layout).pageCount - 1
    XCTAssertGreaterThan(target, 3)
    fixture.activity.prepare(target, presentation: .live)
    fixture.showPages(current: 2, neighbour: target); fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { held != nil }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.ready[1] == true && fixture.canonicalPaper(in: 1)
    }
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertNotNil(runtime.superview, "Unconfirmed program state still owns its native surface")
    XCTAssertFalse(fixture.checkpoints.contains("program"))
    held?.resume(); held = nil
    try await wait(message: { fixture.diagnostics }) { fixture.checkpoints.contains("program") && runtime.superview == nil }
    XCTAssertEqual(fixture.checkpointValues["program"]?["count"], .number(7))
  }

  func testDistantLivePaperTransfersWithoutSnapshotOrASecondRender() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\hyperlink{far}{Far}\n\n" + String(repeating: "Physical paper keeps its canonical geometry and links.\n\n", count: 160)
      + "\n\n\\section{Far}\\hypertarget{far}{}\n\n\\hyperlink{body}{Return}")])
    let measurements = DocumentPresentationRecorder(enabled: true)
    let fixture = try ProgramFixture(document: document, measurements: measurements, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let original = try XCTUnwrap(fixture.paper(in: 0))
    let originalProjection = ObjectIdentifier(try XCTUnwrap(original.superview))
    let originalWindow = try XCTUnwrap(original.window)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let target = try XCTUnwrap(source.layout.map { $0.pageCount - 1 })
    XCTAssertGreaterThan(target, 1)
    let measurementCount = source.measurementCount
    let request = measurements.request(documentID: document.id, pageIndex: target, cause: .page)
    fixture.activity.prepare(target, presentation: .live)
    let demand = try XCTUnwrap(fixture.activity.preparationDemand)
    fixture.showPages(current: 0, neighbour: target); fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    let incoming = try XCTUnwrap(fixture.paper(in: 1))
    let before = try await incoming.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertFalse(incoming === original)
    XCTAssertFalse(fixture.hosts[1].hasSnapshot)
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedCount, 0, "Live landing must not allocate a full-page bridge image")
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertFalse(fixture.hosts[1].isUserInteractionEnabled)
    let attempt = try XCTUnwrap(measurements.records.first { $0.id == request }?.landingAttempts.last)
    XCTAssertEqual(attempt.stage, .completed); XCTAssertNil(attempt.captureStartedAt)

    fixture.activity.update(true)
    fixture.activity.didInstall(demand); fixture.activity.prepare(nil); fixture.activity.update(false)
    fixture.retirePresentation(0)
    XCTAssertEqual(original.superview.map(ObjectIdentifier.init), originalProjection,
      "Retiring the old page shell transfers its existing projection, not just a detached WebKit reference")
    XCTAssertTrue(original.window === originalWindow,
      "The installed distant target keeps the reusable source shell in the same native window")
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    await owner.observePendingPresentationWork()
    XCTAssertTrue(fixture.paper(in: 1) === incoming, "Native completion retains the target while SwiftUI current input is delayed")
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 1) && (incoming.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[1]) == true
    }
    XCTAssertTrue(fixture.paper(in: 1) === incoming)
    let after = try await incoming.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(after?["generation"] as? String, before?["generation"] as? String)
    XCTAssertEqual(after?["runtimeID"] as? String, before?["runtimeID"] as? String)
    XCTAssertEqual(after?["renderToken"] as? String, fixture.currentToken)
    XCTAssertEqual(source.measurementCount, measurementCount)
    XCTAssertFalse(fixture.hosts[1].hasSnapshot)
    let image = XCTAttachment(image: try fixture.windowImage())
    image.name = "live-distant-paper-without-snapshot"; image.lifetime = .keepAlways; add(image)

    fixture.activity.prepare(0, presentation: .live); fixture.restorePresentation(0)
    let returning = try XCTUnwrap(fixture.activity.preparationDemand)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    XCTAssertTrue(fixture.paper(in: 0) === original, "Return reuses the other existing paper shell")
    fixture.activity.update(true); fixture.activity.didInstall(returning)
    fixture.select(0); fixture.activity.prepare(nil); fixture.activity.update(false)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 0) && (original.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[0]) == true
    }
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    fixture.close()
    try await wait(message: { fixture.diagnostics }) {
      fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.rasterAdmission.pinnedCount == 0
    }
  }

  func testRetainedOverviewThumbnailCannotConsumeTheLivePageLanding() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\section{Current}\\hypertarget{current}{}\n\n" + String(repeating: "A thumbnail cannot own the destination of physical navigation.\n\n", count: 180)
      + "\n\n\\section{Far}\\hypertarget{far}{}")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let current = try XCTUnwrap(fixture.paper(in: 0))
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let target = try XCTUnwrap(source.layout.map { $0.pageCount - 1 })
    XCTAssertGreaterThan(target, 1)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    let thumbnail = DocumentWebHost(), thumbnailCoordinator = DocumentPhysicalPageCoordinator()
    defer { thumbnailCoordinator.invalidate(); thumbnail.removeFromSuperview() }
    thumbnail.frame = .init(x: 0, y: 700, width: 120, height: 170)
    fixture.window.rootViewController!.view.addSubview(thumbnail)
    thumbnailCoordinator.update(.init(document: document, state: .init(id: document.id, actor: UUID()),
      pageIndex: target, isCurrent: false, isVisible: true, isInteractive: false, pageTurnActive: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onStateChange: { _, _ in nil },
      onLinkActivation: { _ in }, snapshotPixelWidth: 256,
      onPreparationFailure: { error in XCTFail("Thumbnail preparation: \(error)") }), in: thumbnail, resources: fixture.resources)
    try await wait(message: { fixture.diagnostics }) { thumbnail.hasSnapshot }
    await owner.observePendingPresentationWork()
    let thumbnailRaster = thumbnail.snapshotEntryID
    // Dismissed SwiftUI popovers can retain their thumbnail hosts. Demand may
    // arrive before the physical target host: only that host may fulfil it.
    fixture.activity.prepare(target, presentation: .live)
    await owner.observePendingPresentationWork()
    XCTAssertTrue(thumbnail.hasSnapshot, "A live-page request cannot replace a thumbnail with WebKit")
    XCTAssertEqual(thumbnail.snapshotEntryID, thumbnailRaster)
    XCTAssertTrue(fixture.paper(in: 0) === current)
    fixture.showPages(current: 0, neighbour: target); fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    let incoming = try XCTUnwrap(fixture.paper(in: 1))
    let demand = try XCTUnwrap(fixture.activity.preparationDemand)
    fixture.activity.update(true); fixture.activity.didInstall(demand)
    fixture.select(1); fixture.activity.prepare(nil); fixture.activity.update(false)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 1) && (incoming.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[1]) == true
    }
    XCTAssertTrue(thumbnail.hasSnapshot)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testLiveTargetSupersessionAndCloseCancelItsQueuedAdmission() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\section{Current}\\hypertarget{current}{}\n\n" + String(repeating: "An accepted target does not retire the visible page.\n\n", count: 180)
      + "\n\n\\section{Far}\\hypertarget{far}{}")])
    let resources = SceneRenderResources(maximumWebSurfaces: 1, reservedInteractiveSlots: 0)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let current = try XCTUnwrap(fixture.paper(in: 0))
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    let target = try XCTUnwrap(source.layout.map { $0.pageCount - 1 })
    XCTAssertGreaterThan(target, 2)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: resources)
    fixture.activity.prepare(target, presentation: .live)
    fixture.showPages(current: 0, neighbour: target); fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == target && resources.pendingWebRequestCount == 1 }
    fixture.activity.prepare(target - 1, presentation: .live)
    fixture.showPages(current: 0, neighbour: target - 1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == target - 1 && resources.pendingWebRequestCount == 1 }
    XCTAssertTrue(fixture.paper(in: 0) === current)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertFalse(fixture.ready[1] == true)
    fixture.close()
    try await wait(message: { fixture.diagnostics }) { resources.pendingWebRequestCount == 0 && resources.activeWebSurfaceCount == 0 }
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testPlainNeighbourUsesItsSingleGrantedRasterSlot() async throws {
    let resources = SceneRenderResources(maximumRasterCount: 1)
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      String(repeating: "A plain page has no program or composition output to reserve.\n\n", count: 150))])
    let fixture = try ProgramFixture(document: document, resources: resources)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true }
    XCTAssertTrue(fixture.hosts[1].hasSnapshot)
    XCTAssertEqual(resources.rasterAdmission.pinnedCount, 1)
    XCTAssertLessThanOrEqual(resources.rasterCount, 1)
  }

  func testColdLetterPaperWaitsForItsNativeGeometryWithoutBlockingPreparedMaterial() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body",
      source: "Cold Letter paper keeps the source and installed geometry in the same version.")],
      width: 612, height: 792)
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    let host = fixture.hosts[0]
    let placeholder = host.bounds.size
    XCTAssertEqual(placeholder.height / placeholder.width,
      WorkspaceItemGeometry.uncompiledDocument.height / WorkspaceItemGeometry.uncompiledDocument.width,
      accuracy: 0.00001)
    // Deliberately retain the old scene rectangle after the real compiler and
    // native paper finish. A source receipt is not a geometry installation.
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    await DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
      .observePendingPresentationWork()
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let renderer = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    let source = try XCTUnwrap(renderer.payload?.source)
    let paper = try XCTUnwrap(source.layout).paper(on: 0)
    XCTAssertEqual(paper.widthPoints, 612, accuracy: 0.001)
    XCTAssertEqual(paper.heightPoints, 792, accuracy: 0.001)
    XCTAssertFalse(host.hasCanonicalPaperProjection)
    XCTAssertFalse(fixture.ready[0] == true)
    XCTAssertFalse(fixture.presents(.paper))
    XCTAssertFalse(renderer.nativeInputIsReady(in: host))
    XCTAssertNotNil(renderer.installedPaper, "Native source preparation does not wait for its host rectangle")
    do {
      _ = try await fixture.turnFrame(in: 0, priority: .input)
      XCTFail("An actual turn must not capture paper projected into a different physical rectangle")
    } catch {
      XCTAssertEqual(error as? SceneRenderError, .snapshotPending("document_installed_slots"))
    }
    host.frame.size.height = host.bounds.width * paper.surfaceHeight / paper.surfaceWidth
    host.setNeedsLayout(); host.layoutIfNeeded()
    try await wait(message: { fixture.diagnostics }) {
      host.hasCanonicalPaperProjection && fixture.ready[0] == true && fixture.presents(.paper)
        && renderer.nativeInputIsReady(in: host)
    }
    XCTAssertTrue(fixture.paper(in: 0) === web, "Geometry installation preserves the accepted native runtime")
    XCTAssertTrue(renderer.payload?.source === source)
    let prepared = try await fixture.turnFrame(in: 0, priority: .input)
    XCTAssertGreaterThan(prepared.logicalSize.width, 0)
    XCTAssertEqual(source.measurementCount, 1)
    XCTAssertEqual(source.compiledPageCount, 1)
  }

  func testAcceptedOpeningPreparesTheSameSourceBeforeAnyNativeHostExists() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root); try store.prepare()
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "Accepted opening source before native mount.")])
    let resources = SceneRenderResources()
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: resources)
    let opening = owner.prepareOpening(document: document, pageIndex: 0, store: store)
    defer { opening.close() }
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document, store: store)
    try await wait(message: { "accepted source has no preparation reader or layout" }) {
      source.pendingPreparationReaderCount > 0 || source.layout != nil
    }
    XCTAssertEqual(resources.activeWebSurfaceCount, 0, "Accepted immutable print work has no native mount dependency")
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false, programStore: store)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let renderer = try XCTUnwrap(fixture.paper(in: 0)?.navigationDelegate as? DocumentWebCoordinator)
    XCTAssertTrue(renderer.payload?.source === source, "Mounting borrows the accepted source instead of starting another preparation")
    XCTAssertEqual(source.measurementCount, 1)
    XCTAssertEqual(opening.outcome, .completed, "The exact native source demand ends the temporary opening reader")
    opening.close()
    XCTAssertTrue(fixture.canonicalPaper(in: 0), "Handing off the opening lease preserves the mounted source")
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
  }

  func testStaticTurnFramesReuseTheirExactPixelsAcrossLandingAndReplaceEditedSource() async throws {
    let original = "First immutable page.\\newpage Second immutable page."
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: original)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    var materialEvents: [String] = []
    XCTAssertNil(NotebookNavigationObservation.onPageMaterialPreparation)
    NotebookNavigationObservation.onPageMaterialPreparation = { stage, entry, _, frame, operation, time in
      guard materialEvents.count < 40 else { return }
      materialEvents.append("\(time) \(stage) entry=\(entry) frame=\(String(describing: frame)) operation=\(String(describing: operation))")
    }
    defer {
      NotebookNavigationObservation.onPageMaterialPreparation = nil
      let attachment = XCTAttachment(string: materialEvents.joined(separator: "\n"))
      attachment.name = "Document static turn material identity"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.ready[1] == true && fixture.canonicalPaper(in: 0)
    }
    let first = try await fixture.turnFrame(in: 0), neighbour = try await fixture.turnFrame(in: 1)
    let picture = try XCTUnwrap(fixture.resources.image(for: .document(id: document.id, token: fixture.token(page: 1)))?.cgImage)
    let density = fixture.hosts[1].projectedPixelScale(for: neighbour.logicalSize)
    XCTAssertGreaterThanOrEqual(picture.width, Int(ceil(neighbour.logicalSize.width * density)))
    XCTAssertGreaterThanOrEqual(picture.height, Int(ceil(neighbour.logicalSize.height * density)),
      "The passive picture must cover the same integral extent required after its native landing")
    let sameFirst = try await fixture.turnFrame(in: 0), sameNeighbour = try await fixture.turnFrame(in: 1)
    XCTAssertTrue(first === sameFirst)
    XCTAssertTrue(neighbour === sameNeighbour)
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let renderer = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    // Hold the real transparent-shell publication, never its native flags.
    // Native landing and a subsequent source edit must still produce exact
    // physical cuts while the previous JS evaluation owns its pending reply.
    _ = try await web.evaluateJavaScript("""
      window.savedTurnPresentPage=window.notebookRenderer.presentPage;
      window.heldTurnPage=new Promise(resolve=>{window.releaseTurnPage=resolve;});
      window.turnPageEntered=new Promise(resolve=>{window.didEnterTurnPage=resolve;});
      window.notebookRenderer.presentPage=async frame=>{
        window.didEnterTurnPage();await window.heldTurnPage;
        return window.savedTurnPresentPage(frame);
      };true
      """)
    defer {
      web.evaluateJavaScript("window.notebookRenderer.presentPage=window.savedTurnPresentPage;window.releaseTurnPage?.();true")
    }
    var shellIsHeld = false
    web.callAsyncJavaScript("await window.turnPageEntered;return true;", arguments: [:], in: nil, in: .page) { result in
      shellIsHeld = (try? result.get()) as? Bool == true
    }
    materialEvents.append("before landing \(owner.turnFrameDiagnostic(page: 1))")
    fixture.select(1)
    materialEvents.append("selected \(owner.turnFrameDiagnostic(page: 1))")
    try await wait(message: { fixture.diagnostics }) {
      shellIsHeld && renderer.paperIsReady && renderer.payload?.pageIndex == 1
        && fixture.ready[1] == true && !fixture.hosts[1].hasSnapshot
    }
    XCTAssertFalse(renderer.hasCanonicalPixels)
    XCTAssertFalse(renderer.nativeInputIsReady(in: fixture.hosts[1]))
    XCTAssertFalse(fixture.presents(.paper), "A native turn cut cannot acknowledge transparent DOM links")
    materialEvents.append("native landing before DOM \(owner.turnFrameDiagnostic(page: 1))")
    let landed = try await fixture.turnFrame(in: 1)
    materialEvents.append("acquired landing \(owner.turnFrameDiagnostic(page: 1))")
    XCTAssertTrue(landed === neighbour, "Landing on unchanged plain paper keeps its resident GPU material")
    fixture.setInteractive(false); fixture.setInteractive(true)
    let afterInputPolicy = try await fixture.turnFrame(in: 1)
    XCTAssertTrue(afterInputPolicy === landed)
    let oldSource = try XCTUnwrap(renderer.payload?.source)
    fixture.replaceSource(fileID: "body", source: original + " A changed printed sentence.")
    do {
      _ = try await fixture.turnFrame(in: 1, priority: .input)
      XCTFail("A previous native paper cannot supply a cut for the replacement source")
    } catch {
      XCTAssertEqual(error as? SceneRenderError, .snapshotPending("document_installed_slots"))
    }
    try await wait(message: { fixture.diagnostics }) {
      renderer.paperIsReady && renderer.payload?.source !== oldSource && fixture.ready[1] == true
        && renderer.payload?.source.matches(fixture.document) == true && !fixture.hosts[1].hasSnapshot
    }
    XCTAssertFalse(renderer.hasCanonicalPixels, "The earlier real shell call is still held")
    let edited = try await fixture.turnFrame(in: 1), sameEdited = try await fixture.turnFrame(in: 1)
    XCTAssertFalse(edited === landed, "A source binding cannot reuse the preceding page frame")
    XCTAssertTrue(edited === sameEdited)
    let currentPaper = try XCTUnwrap(renderer.installedPaper)
    let printedText = PDFDocument(data: currentPaper.page.artifact.pdf)?.page(at: currentPaper.page.pageIndex)?.string
    XCTAssertTrue(printedText?.contains("changed printed sentence") == true)
    _ = try await web.evaluateJavaScript("window.notebookRenderer.presentPage=window.savedTurnPresentPage;window.releaseTurnPage();true")
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 1) && renderer.nativeInputIsReady(in: fixture.hosts[1])
    }
    XCTAssertTrue(renderer.installedPaper === currentPaper, "The later DOM receipt must not replace accepted native paper")
  }

  func testLiveProgramTurnTakesANewLocalCutWithoutCheckpointOrRuntimeReplacement() async throws {
    let document = DocumentTestFiles.document(contents: [.program(id: "live",
      html: "<div id='color' style='height:120px;background:red'>Live pixels</div>", css: "",
      javaScript: "notebook.ready(Promise.resolve());", height: 140)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(block: "live") != nil }
    let web = try XCTUnwrap(fixture.web(block: "live"))
    let first = try await fixture.turnFrame(in: 0, priority: .input)
    _ = try await web.evaluateJavaScript("document.querySelector('#color').style.background='blue';true")
    let changed = try await fixture.turnFrame(in: 0, priority: .input)
    XCTAssertFalse(first === changed, "Unsaved live pixels never hit the immutable page cache")
    XCTAssertTrue(fixture.web(block: "live") === web)
    XCTAssertTrue(fixture.checkpoints.isEmpty, "A visual cut must not add an authored-state writer dependency")
    XCTAssertEqual(fixture.ready[0], true)
  }

  func testSnapshotDensityUsesTheNativeCameraProjectionAndKeepsPhysicalBounds() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true }
    let camera = UIView(frame: .init(x: 0, y: 0, width: 1_600, height: 2_000))
    let host = DocumentWebHost()
    host.frame = .init(x: 0, y: 0, width: 800, height: 1_000)
    controller.view.addSubview(camera); camera.addSubview(host)
    let physical = CGSize(width: 400, height: 500)
    let bounds = host.bounds
    XCTAssertEqual(host.projectedPixelScale(for: physical), 2 * window.screen.scale, accuracy: 0.001)
    camera.transform = .init(scaleX: 0.25, y: 0.25)
    XCTAssertEqual(host.projectedPixelScale(for: physical), 0.5 * window.screen.scale, accuracy: 0.001)
    camera.transform = camera.transform.rotated(by: .pi / 3)
    XCTAssertEqual(host.projectedPixelScale(for: physical), 0.5 * window.screen.scale, accuracy: 0.001)
    XCTAssertEqual(host.bounds, bounds, "Pixel density must not relayout the canonical paper")
  }

  func testPressureReclaimsAnUnselectedMountedNeighbourWithoutRevokingCurrentInput() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      (0..<50).map { "Paragraph \($0). " + String(repeating: "A neighbouring page is disposable until a real turn accepts it. ", count: 10) }.joined(separator: "\n\n"))])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.ready[1] == true && fixture.hosts[1].hasSnapshot
        && fixture.canonicalPaper(in: 0)
    }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let renderer = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    let snapshotID = try XCTUnwrap(fixture.hosts[1].snapshotEntryID)
    XCTAssertTrue(fixture.hosts[1].hasVisibleSnapshot)
    // The same screen rectangle is not proof that UIKit displays this page:
    // ordinary prewarm children remain mounted behind the selected page.
    fixture.hosts[1].frame = fixture.hosts[0].frame
    fixture.hosts[0].superview?.bringSubviewToFront(fixture.hosts[0])
    fixture.activity.update(true)
    let protected = fixture.resources.rasterAdmission
    let protectedRequest = fixture.resources.reserveDerivedBytes(
      max(1, protected.passiveByteLimit - protected.pinnedBytes - protected.passiveReservedBytes + 1), priority: .passive)
    XCTAssertEqual(fixture.hosts[1].snapshotEntryID, snapshotID,
      "An accepted turn protects even its currently hidden neighbour")
    protectedRequest?.release()
    try await wait(message: { fixture.diagnostics }) { fixture.resources.pendingReclamationCount == 0 }
    fixture.activity.update(false)
    // GPU copies are cheaper to restore and yield before the installed picture.
    let currentFrameBytes = try await fixture.turnFrame(in: 0).byteCount
    let neighbourFrameBytes = try await fixture.turnFrame(in: 1).byteCount
    let frameBytes = currentFrameBytes + neighbourFrameBytes
    let before = fixture.resources.rasterAdmission
    let admitted = try XCTUnwrap(fixture.resources.reserveDerivedBytes(
      max(1, before.passiveByteLimit - before.pinnedBytes - before.passiveReservedBytes + frameBytes + 1), priority: .passive))
    defer { admitted.release() }
    XCTAssertNil(fixture.hosts[1].snapshotEntryID)
    XCTAssertEqual(fixture.ready[1], false)
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertTrue(renderer.nativeInputIsReady(in: fixture.hosts[0]))
    XCTAssertEqual(fixture.ready[0], true)
  }

  func testFallbackPixelsDenyNewNativeHitsUntilCanonicalPaperIsInstalled() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{Installed paper}\\hypertarget{installed-paper}{}\n\n\\hyperlink{target}{Target}\n\n\\section{Target}\\hypertarget{target}{}")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    let raster = try await coordinator.retainPreparedSnapshot(pixelWidth: 128)
    defer { raster.release(); coordinator.releasePreparedSnapshot() }
    let host = fixture.hosts[0]
    host.installSnapshot(raster)
    coordinator.updateInputAdmission(in: host, isInteractive: true)
    XCTAssertTrue(host.hasSnapshot)
    XCTAssertTrue(coordinator.hasCanonicalPixels, "Prepared DOM alone does not admit a gesture")
    XCTAssertFalse(coordinator.acceptsInput)
    XCTAssertFalse(coordinator.nativeInputIsReady(in: host))
    let hit = fixture.window.hitTest(host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: fixture.window), with: nil)
    XCTAssertFalse(hit === web || hit?.isDescendant(of: web) == true,
      "A visible snapshot must never route the first native hit into its hidden DOM")
    host.removeFallback()
    coordinator.updateInputAdmission(in: host, isInteractive: true)
    XCTAssertTrue(coordinator.acceptsInput)
    XCTAssertTrue(coordinator.nativeInputIsReady(in: host))
    XCTAssertTrue(fixture.paper(in: 0) === web)
    try await fixture.assertPaperReceivesNativeHit(web)
  }

  func testFailureOfPreviousSourceDoesNotPoisonTheSamePageAfterEditing() async throws {
    func hasRetry(_ view: UIView) -> Bool {
      if let button = view as? UIButton,
        (button.title(for: .normal) ?? button.configuration?.title) == "Повторить" { return !button.isHidden }
      return view.subviews.contains(where: hasRetry)
    }
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{First source}\\hypertarget{first-source}{}")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    let originalPaper = try XCTUnwrap(fixture.retainedPaper)
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    coordinator.webView(web, didFail: nil, withError: NSError(domain: "SourceFailureContract", code: 1))
    try await wait(message: { fixture.diagnostics }) { !fixture.preparationErrors.isEmpty }
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    await owner.observePendingPresentationWork()
    XCTAssertEqual(fixture.preparationErrors.count, 1)
    XCTAssertTrue(fixture.retainedPaper === originalPaper, "Interaction failure must retain the readable native paper")
    XCTAssertTrue(hasRetry(fixture.hosts[0]))
    XCTAssertFalse(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    fixture.replaceSource(fileID: "body", source: "\\section{Repaired source}\\hypertarget{repaired-source}{}\n\nThe same page number now has a different version.")
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) }
    try await wait(message: { fixture.diagnostics }) {
      guard let web = fixture.paper(in: 0), let renderer = web.navigationDelegate as? DocumentWebCoordinator else { return false }
      return renderer.nativeInputIsReady(in: fixture.hosts[0])
    }
    let replacement = try XCTUnwrap(fixture.paper(in: 0))
    let installed = try XCTUnwrap(fixture.installedPaper)
    let text = PDFDocument(data: installed.page.artifact.pdf)?.page(at: installed.page.pageIndex)?.string
    XCTAssertTrue(text?.contains("Repaired source") == true)
    XCTAssertTrue((replacement.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[0]) == true)
    XCTAssertFalse(hasRetry(fixture.hosts[0]))
    XCTAssertEqual(fixture.preparationErrors.count, 1, "The repaired source must not inherit its predecessor's failure")
  }

  func testProsePagePreparationReusesItsIdleExecutorAcrossDifferentTargets() async throws {
    let text = (0..<70).map { "Paragraph \($0). " + String(repeating: "A measured page keeps reusable preparation. ", count: 12) }.joined(separator: "\n\n")
    let fixture = try ProgramFixture(document: DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: text)]))
    defer { fixture.close() }
    let owner = DocumentPagePresentationOwner.shared(documentID: fixture.document.id, resources: fixture.resources)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.paper(in: 0) != nil }
    func allWeb(_ view: UIView) -> [WKWebView] {
      (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(allWeb)
    }
    let current = try XCTUnwrap(fixture.paper(in: 0))
    try await wait(message: { fixture.diagnostics }) { allWeb(fixture.hosts[0]).contains { $0 !== current } }
    let preparer = try XCTUnwrap(allWeb(fixture.hosts[0]).first { $0 !== current })
    XCTAssertFalse((preparer.navigationDelegate as? DocumentWebCoordinator)?.hasCanonicalPixels == true)
    let identity = ObjectIdentifier(preparer)
    fixture.showPages(current: 0, neighbour: 3)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true }
    await owner.observePendingPresentationWork()
    XCTAssertTrue(allWeb(fixture.hosts[0]).contains { ObjectIdentifier($0) == identity })
    XCTAssertEqual((preparer.navigationDelegate as? DocumentWebCoordinator)?.payload?.pageIndex, 3)
    fixture.showPages(current: 0, neighbour: 2)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true }
    await owner.observePendingPresentationWork()
    XCTAssertTrue(allWeb(fixture.hosts[0]).contains { ObjectIdentifier($0) == identity })
    XCTAssertEqual((preparer.navigationDelegate as? DocumentWebCoordinator)?.payload?.pageIndex, 2)
    let renderer = try XCTUnwrap(preparer.navigationDelegate as? DocumentWebCoordinator)
    // Reclaiming the preparer must preserve an already admitted input owner.
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 0)
        && (current.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[0]) == true
    }
    renderer.webViewWebContentProcessDidTerminate(preparer)
    try await wait(message: { fixture.diagnostics }) { fixture.resources.activeWebSurfaceCount == 1 }
    XCTAssertTrue(renderer.isInvalidated, "A dead idle executor does not restart without an unsatisfied page demand")
    XCTAssertTrue(fixture.paper(in: 0) === current)
    XCTAssertTrue((current.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[0]) == true)
  }

  func testSourceReplacementReleasesUnusablePicturesBeforePreparingNewSource() async throws {
    let text = (0..<32).map { "Paragraph \($0). " + String(repeating: "The document keeps its physical page through an edit. ", count: 12) }.joined(separator: "\n\n")
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{Before}\\hypertarget{before}{}\n\n" + text)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true }
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 1) && !fixture.hosts[1].hasSnapshot }
    fixture.retirePresentation(0)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    await owner.observePendingPresentationWork()
    let web = try XCTUnwrap(fixture.paper(in: 1))
    let oldPinnedBytes = fixture.resources.rasterAdmission.pinnedBytes
    XCTAssertGreaterThan(oldPinnedBytes, 0, "A real previously passive picture remains pinned by the document owner")

    fixture.replaceSource(fileID: "body", source: "\\section{After!}\\hypertarget{after}{}\n\n" + text)
    XCTAssertLessThan(fixture.resources.rasterAdmission.pinnedBytes, oldPinnedBytes,
      "Obsolete preparation pins must end synchronously at version replacement, before new source admission")
    XCTAssertTrue(fixture.paper(in: 1) === web, "Releasing preparation ownership cannot retire the installed native paper")
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 1) }
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testPressureParksNeighbourAndPromotesItsSameAdmissionToAnAcceptedTarget() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\section{Current}\\hypertarget{current}{}Current paper remains interactive."
      + "\\newpage\\section{Neighbour}\\hypertarget{neighbour}{}The accepted target keeps its original queue place.")])
    let resources = SceneRenderResources(maximumWebSurfaces: 2, reservedInteractiveSlots: 0)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let current = WeakDocumentPaper(fixture.paper(in: 0))
    let currentID = ObjectIdentifier(try XCTUnwrap(current.value))
    _ = try await XCTUnwrap(current.value).evaluateJavaScript("window.pressureDocument=document;window.pressureValue=47;true")
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: resources)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    XCTAssertEqual(source.layout?.pageCount, 2)
    let blocker = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    let blockerHost = DocumentWebHost()
    fixture.window.rootViewController?.view.addSubview(blockerHost)
    blockerHost.frame = .init(x: 720, y: 0, width: 240, height: 340)
    let blockerDocument = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "blocker", source: "An independently admitted paper holds the second slot.")])
    blocker.update(document: blockerDocument, state: .init(id: blockerDocument.id, actor: UUID()),
      selectedPageIndex: 0, capturesSnapshot: false, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    let geometry = DocumentRenderRegistry.shared.geometry(document: blockerDocument, pageIndex: 0)
    blocker.mount(in: blockerHost, physicalSize: .init(width: geometry.width, height: geometry.height),
      isInteractive: true, priority: .currentPage)
    defer { blocker.invalidate(); blockerHost.removeFromSuperview() }
    try await wait(message: { fixture.diagnostics }) { blocker.hasCanonicalPixels && resources.activeWebSurfaceCount == 2 }
    fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == 1 && resources.pendingWebRequestCount == 1 }
    let optionalID = try XCTUnwrap(owner.pendingPassiveSurfaceRequestID)

    resources.handleMemoryPressure(.warning)
    try await wait(message: { fixture.diagnostics }) { resources.pendingWebRequestCount == 0 }
    await owner.observePendingPresentationWork()
    XCTAssertNil(owner.pendingPassiveSurfaceRequestID)
    XCTAssertTrue(fixture.canonicalPaper(in: 0))
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(current.value)), currentID)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    resources.handleMemoryPressure(.critical)
    await owner.observePendingPresentationWork()
    try await wait(message: { fixture.diagnostics }) {
      fixture.snapshot(in: 1) == nil && resources.pendingReclamationCount == 0 && resources.pendingWebRequestCount == 0
    }
    XCTAssertEqual(resources.pendingWebRequestCount, 0, "A latched pressure event cannot resume optional admission")

    resources.handleMemoryPressure(.normal)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == 1 && resources.pendingWebRequestCount == 1 }
    let resumedID = try XCTUnwrap(owner.pendingPassiveSurfaceRequestID)
    XCTAssertNotEqual(resumedID, optionalID)
    XCTAssertTrue(DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document) === source,
      "Normal pressure resumes the same source without a terminal preparation failure")
    fixture.activity.prepare(1, presentation: .live)
    XCTAssertEqual(owner.pendingPassiveSurfaceRequestID, resumedID,
      "Accepting this exact neighbour promotes its original admission")
    resources.handleMemoryPressure(.warning)
    XCTAssertEqual(resources.pendingWebRequestCount, 1, "The offscreen accepted target is required under pressure")
    XCTAssertEqual(owner.pendingPassiveSurfaceRequestID, resumedID)
    XCTAssertTrue(fixture.canonicalPaper(in: 0))
    let heap = try await XCTUnwrap(current.value).evaluateJavaScript("pressureDocument===document && pressureValue===47")
    XCTAssertEqual(heap as? Bool, true)
    XCTAssertTrue(blocker.hasCanonicalPixels, "Pressure keeps independently admitted physical owners")

    blocker.invalidate(); blockerHost.removeFromSuperview()
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    let incoming = WeakDocumentPaper(fixture.paper(in: 1))
    let incomingID = ObjectIdentifier(try XCTUnwrap(incoming.value))
    let demand = try XCTUnwrap(fixture.activity.preparationDemand)
    fixture.activity.update(true); fixture.activity.didInstall(demand)
    fixture.select(1); fixture.activity.prepare(nil); fixture.activity.update(false)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 1) && (incoming.value?.navigationDelegate as? DocumentWebCoordinator)?.nativeInputIsReady(in: fixture.hosts[1]) == true
    }
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 1))), incomingID,
      "Native landing uses the admitted target without rebuilding its WebKit")
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    fixture.close()
    try await wait(message: { fixture.diagnostics }) { resources.pendingWebRequestCount == 0 && resources.activeWebSurfaceCount == 0 }
  }

  func testRequiredRemountOutlivesItsWithdrawnNativeSubscriber() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\section{Current}The admitted current page retains the canonical PDF."
      + "\\newpage\\section{Target}An optional native subscriber can become the required paper.")])
    let resources = SceneRenderResources(maximumWebSurfaces: 2, reservedInteractiveSlots: 0)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let session = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources)
    let source = session.source(document)
    XCTAssertEqual(source.layout?.pageCount, 2)
    let admission = resources.rasterAdmission
    let held = try XCTUnwrap(resources.reserveDerivedBytes(min(admission.byteLimit - admission.heldBytes,
      admission.passiveByteLimit - admission.pinnedBytes - admission.passiveReservedBytes), priority: .passive))
    defer { held.release() }
    let renderer = DocumentWebCoordinator(resources: resources, renderSession: session, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onStateChange: { _, _ in nil })
    let targetHost = DocumentWebHost()
    fixture.window.rootViewController?.view.addSubview(targetHost)
    targetHost.frame = .init(x: 720, y: 0, width: 240, height: 340)
    defer { renderer.onPresentationChange = {}; renderer.invalidate(); targetHost.removeFromSuperview() }
    var failures: [String] = [], withdrawals = 0
    let geometry = try XCTUnwrap(source.layout).paper(on: 1).geometry
    let size = CGSize(width: geometry.width, height: geometry.height)
    renderer.update(document: document, state: .init(id: document.id, actor: UUID()),
      selectedPageIndex: 1, capturesSnapshot: false, onRenderReady: .init { _ in },
      onPageLayout: { _ in }, onStateChange: { _, _ in nil },
      onPreparationFailure: { failures.append(String(describing: $0)) }, preparationRequestID: UUID())
    renderer.onPresentationChange = { [weak renderer] in
      guard let renderer, withdrawals == 0, renderer.acquisitionError is CancellationError else { return }
      withdrawals += 1
      // Promotion occurs synchronously before the withdrawn native task throws
      // to the sender already waiting on that task, in the same source generation.
      renderer.mount(in: targetHost, physicalSize: size, isInteractive: true, priority: .currentPage)
    }
    renderer.mount(in: targetHost, physicalSize: size, isInteractive: false, priority: .visible, purpose: { .optional })
    try await wait(message: { fixture.diagnostics }) {
      renderer.webView != nil && renderer.installedPaper == nil && resources.pendingDerivedRequestCount > 0
        && renderer.pagePreparationTrace?.phasesMS["frameTaskAt"] != nil
    }
    let admitted = WeakDocumentPaper(renderer.webView)
    let admittedID = ObjectIdentifier(try XCTUnwrap(admitted.value))
    let token = try XCTUnwrap(renderer.payload?.renderToken)
    resources.handleMemoryPressure(.warning)
    held.release()
    try await wait(message: { fixture.diagnostics + " targetErrors=\(failures)" }) { renderer.hasCanonicalPixels }
    try await renderer.awaitPresentation(token: token)
    XCTAssertEqual(withdrawals, 1)
    XCTAssertTrue(failures.isEmpty, "The retired optional subscriber cannot fail the required remount: \(failures)")
    XCTAssertNil(renderer.acquisitionError)
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(renderer.webView)), admittedID)
    XCTAssertTrue(renderer.nativeInputIsReady(in: targetHost))
    XCTAssertTrue(fixture.canonicalPaper(in: 0))
    XCTAssertTrue(session.source(document) === source)
    renderer.invalidate(); targetHost.removeFromSuperview(); fixture.close()
    try await wait(message: { fixture.diagnostics }) { resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
  }

  func testAcceptedDistantTargetPreemptsARealQueuedNeighbourWithoutRetiringCurrentPaper() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\section{Current}\\hypertarget{current}{}Current paper remains interactive."
      + "\\newpage\\section{Speculative neighbour}The existing passive request targets this page."
      + "\\newpage\\section{Alternate target}A later accepted navigation can replace the distant target."
      + "\\newpage\\section{Destination}\\hypertarget{destination}{}The selected distant target owns admission.")])
    let resources = SceneRenderResources(maximumWebSurfaces: 2, reservedInteractiveSlots: 0)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: resources)
    let layout = try XCTUnwrap(DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document).layout)
    let target = layout.pageCount - 1
    XCTAssertGreaterThan(target, 2)
    let current = WeakDocumentPaper(fixture.paper(in: 0))
    let identity = ObjectIdentifier(try XCTUnwrap(current.value))
    _ = try await XCTUnwrap(current.value).evaluateJavaScript("window.priorityDocument=document;window.priorityValue=47;true")
    // Hold a real second admitted WebKit. The passive owner must queue through
    // SceneRenderResources, rather than a manufactured renderer-ready callback.
    let blocker = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    let blockerHost = DocumentWebHost()
    fixture.window.rootViewController?.view.addSubview(blockerHost)
    blockerHost.frame = .init(x: 720, y: 0, width: 240, height: 340)
    let blockerDocument = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "blocker", source: "\\section{Another active paper}\\hypertarget{another-active-paper}{}")])
    blocker.update(document: blockerDocument, state: .init(id: blockerDocument.id, actor: UUID()),
      selectedPageIndex: 0, capturesSnapshot: false, onRenderReady: .init { _ in },
      onPageLayout: { _ in },  onStateChange: { _, _ in nil })
    let geometry = DocumentRenderRegistry.shared.geometry(document: blockerDocument, pageIndex: 0)
    blocker.mount(in: blockerHost, physicalSize: .init(width: geometry.width, height: geometry.height),
      isInteractive: true, priority: .currentPage)
    defer { blocker.invalidate(); blockerHost.removeFromSuperview() }
    try await wait(message: { fixture.diagnostics }) { blocker.hasCanonicalPixels && resources.activeWebSurfaceCount == 2 }
    XCTAssertNotNil(blocker.webView)

    fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == 1 && resources.pendingWebRequestCount == 1 }
    fixture.activity.prepare(target)
    let acceptedID = try XCTUnwrap(fixture.activity.preparationDemand?.id)
    fixture.showPages(current: 0, neighbour: target)
    fixture.activity.prepare(target)
    XCTAssertEqual(fixture.activity.preparationDemand?.id, acceptedID)
    // This assertion runs before releasing the real blocker. The old owner
    // stays on page 1 until its deadline, exposing the causal scheduling defect.
    let priorityDeadline = ContinuousClock.now + .seconds(2)
    while owner.pendingPassivePageIndex != target, ContinuousClock.now < priorityDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(owner.pendingPassivePageIndex, target, "Accepted navigation must replace the queued neighbour before admission becomes available")
    guard owner.pendingPassivePageIndex == target else { return }
    XCTAssertEqual(resources.pendingWebRequestCount, 1, "Supersession removes the obsolete physical request")
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(current.value)), identity)
    XCTAssertTrue(fixture.canonicalPaper(in: 0))
    XCTAssertTrue((current.value?.navigationDelegate as? DocumentWebCoordinator)?.acceptsInput == true)

    fixture.activity.prepare(target - 1)
    fixture.showPages(current: 0, neighbour: target - 1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == target - 1 && resources.pendingWebRequestCount == 1 }
    XCTAssertNotEqual(fixture.activity.preparationDemand?.id, acceptedID)
    fixture.activity.prepare(nil)
    fixture.retirePresentation(1)
    try await wait(message: { fixture.diagnostics }) { resources.pendingWebRequestCount == 0 }
    XCTAssertEqual(resources.activeWebSurfaceCount, 2, "Cancelling a queued landing cannot evict either active paper")
    fixture.activity.prepare(target)
    fixture.showPages(current: 0, neighbour: target)
    fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { owner.pendingPassivePageIndex == target && resources.pendingWebRequestCount == 1 }

    blocker.invalidate(); blockerHost.removeFromSuperview()
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.snapshot(in: 1) != nil }
    fixture.select(1); fixture.activity.prepare(nil)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 1))), identity)
    let retained = try await XCTUnwrap(current.value).evaluateJavaScript("priorityDocument===document && priorityValue===47")
    XCTAssertEqual(retained as? Bool, true)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    fixture.close()
    try await wait(message: { fixture.diagnostics }) { resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
  }

  func testCurrentCanonicalPaperAdmitsInputWithoutChangingItsRuntimeOrMeasurement() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\hyperlink{target}{Go to target}\n\n\\section{Target}\\hypertarget{target}{}\n\nA current paper is prepared before its opening settles.")])
    let recorder = DocumentPresentationRecorder(enabled: true)
    _ = recorder.request(documentID: document.id, pageIndex: 0, cause: .open)
    let fixture = try ProgramFixture(document: document, measurements: recorder, interactive: false)
    defer { fixture.close() }
    var navigations = 0
    fixture.replaceLinkNavigation { _ in navigations += 1 }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && recorder.records.last?.contentReadyAt != nil }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let measurement = source.measurementCount
    let canonical = try await web.evaluateJavaScript("window.inputOwnerDocument=document; window.inputOwnerState={value:17}; JSON.stringify(notebookRenderer.pageReceipt())") as? String
    XCTAssertTrue(coordinator.hasCanonicalPixels)
    XCTAssertFalse(coordinator.acceptsInput)
    XCTAssertFalse(fixture.hosts[0].hasInteractiveSurface(web))
    XCTAssertTrue(try XCTUnwrap(web.superview).accessibilityElementsHidden)
    XCTAssertNil(recorder.records.last?.installedAt, "Canonical pixels alone cannot certify a first working page")
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    // A JS click is only a bridge-admission probe. Native hit routing below and
    // the separately required Simulator touch scenario prove different things.
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(navigations, 0)

    fixture.setInteractive(true)
    XCTAssertTrue(coordinator.acceptsInput)
    XCTAssertTrue(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    XCTAssertNotNil(recorder.records.last?.installedAt,
      "The input owner's event records installation before any polling task can run")
    XCTAssertFalse(try XCTUnwrap(web.superview).accessibilityElementsHidden)
    try await fixture.assertPaperReceivesNativeHit(web)
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    try await wait(message: { fixture.diagnostics }) { navigations == 1 && recorder.records.last?.installedAt != nil }

    fixture.setInteractive(false)
    XCTAssertFalse(coordinator.acceptsInput)
    XCTAssertFalse(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    XCTAssertTrue(try XCTUnwrap(web.superview).accessibilityElementsHidden)
    fixture.setInteractive(true)
    XCTAssertTrue(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    try await wait(message: { fixture.diagnostics }) { navigations == 2 }
    XCTAssertTrue(fixture.paper(in: 0) === web)
    let retained = try await web.evaluateJavaScript("inputOwnerDocument===document && inputOwnerState.value===17")
    XCTAssertEqual(retained as? Bool, true)
    let after = try await web.evaluateJavaScript("JSON.stringify(notebookRenderer.pageReceipt())") as? String
    XCTAssertEqual(after, canonical)
    XCTAssertEqual(source.measurementCount, measurement)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testInputPolicyChangedDuringSourcePreparationReachesTheSamePaper() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{Early opening}\\hypertarget{early-opening}{}\n\n\\hyperlink{target}{Target}\n\n\\section{Target}\\hypertarget{target}{}")])
    let fixture = try ProgramFixture(document: document, interactive: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.paper(in: 0) != nil }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    XCTAssertFalse(coordinator.hasCanonicalPixels, "The policy changes during real initial preparation")
    let runtimeID = coordinator.payload?.runtimeID
    fixture.setInteractive(true)
    XCTAssertFalse(coordinator.acceptsInput, "The input request survives preparation but cannot admit a hit before installation")
    try await wait(message: { fixture.diagnostics }) { coordinator.nativeInputIsReady(in: fixture.hosts[0]) && fixture.ready[0] == true }
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertEqual(coordinator.payload?.runtimeID, runtimeID)
    XCTAssertEqual(coordinator.payload?.renderToken, fixture.currentToken)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    XCTAssertEqual(source.measurementCount, 1)
    try await fixture.assertPaperReceivesNativeHit(web)
  }

  func testDisablingNewNativeInputRejectsProgrammaticClickDuringAContact() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\hyperlink{target}{Target}\n\n\\section{Target}\\hypertarget{target}{}")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var admittedCalls = 0, laterCalls = 0
    fixture.replaceLinkNavigation { _ in admittedCalls += 1 }
    // The contact starts only after this paper owns native hit admission.
    try await wait(message: { fixture.diagnostics }) {
      guard let renderer = fixture.paper(in: 0)?.navigationDelegate as? DocumentWebCoordinator else { return false }
      return fixture.ready[0] == true && fixture.canonicalPaper(in: 0)
        && renderer.nativeInputIsReady(in: fixture.hosts[0])
    }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
    // This is the native contact-observer delivery seam against a real loaded
    // paper; it does not synthesize a UITouch or claim a physical gesture test.
    fixture.hosts[0].onContactChange(true)
    fixture.setInteractive(false)
    fixture.replaceLinkNavigation { _ in laterCalls += 1 }
    XCTAssertFalse(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    try await fixture.assertPaperRejectsNativeHit(web)
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(admittedCalls, 0, "A programmatic click cannot spend an earlier user contact")
    XCTAssertEqual(laterCalls, 0)
    fixture.hosts[0].onContactChange(false)
    XCTAssertFalse(coordinator.acceptsInput)
    XCTAssertFalse(coordinator.nativeInputIsReady(in: fixture.hosts[0]))
    fixture.setInteractive(true)
    _ = try await web.evaluateJavaScript("document.querySelector('a').click(); true")
    try await wait(message: { fixture.diagnostics }) { laterCalls == 1 }
    XCTAssertTrue(fixture.paper(in: 0) === web)
    XCTAssertEqual(admittedCalls, 0)
  }

  func testAcceptedProgramStateDoesNotRevokeTheSameSourceInputWhilePaperEchoWaits() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .tex(id: "heading", source: "\\section{A stable input owner}\\hypertarget{a-stable-input-owner}{}"),
      .program(id: "counter", html: "<button>Increment</button><output>0</output>",
        javaScript: """
        document.querySelector('button').onclick=()=>{
          notebook.commit({count:(notebook.state.count||0)+1});
          document.querySelector('output').textContent=String(notebook.state.count);
        };
      notebook.ready(Promise.resolve());
      """, initialState: .object(["count": .number(0)]), height: 90)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.web(block: "counter") != nil && fixture.canonicalPaper(in: 0)
    }
    let web = try XCTUnwrap(fixture.web(block: "counter")), paper = try XCTUnwrap(fixture.paper(in: 0))
    let coordinator = try XCTUnwrap(paper.navigationDelegate as? DocumentWebCoordinator)
    let oldToken = try XCTUnwrap(coordinator.payload?.renderToken)
    // Hold the existing page owner, so the real JS state receipt reaches the
    // input projection before the asynchronous paper echo can catch up.
    fixture.activity.update(true)
    defer { fixture.activity.update(false) }
    _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("counter", field: "count") == 1 }
    XCTAssertNotEqual(fixture.currentToken, oldToken)
    XCTAssertEqual(coordinator.payload?.renderToken, oldToken)
    XCTAssertTrue(coordinator.acceptsInput)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    let rawRect = try await web.evaluateJavaScript("(()=>{const r=document.querySelector('button').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
    let rect = try XCTUnwrap(rawRect as? [Double])
    XCTAssertEqual(rect.count, 2)
    let hit = fixture.window.hitTest(web.convert(.init(x: rect[0], y: rect[1]), to: fixture.window), with: nil)
    XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true,
      "The actual retained program must keep native hit admission after its own state commit")
    _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("counter", field: "count") == 2 }
    XCTAssertTrue(fixture.web(block: "counter") === web)
  }

  func testRetiredOutgoingPageTransfersItsActualPaperToThePreparedDistantPage() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\hyperlink{far}{Far chapter}\n\n" + (0..<35).map { "Paragraph \($0). " + String(repeating: "A physical page transfer preserves the installed WebKit. ", count: 8) }.joined(separator: "\n\n")
      + "\n\n\\section{Far}\\hypertarget{far}{}\n\n\\hyperlink{body}{Return}")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var phase = "initial"
    defer {
      let attachment = XCTAttachment(string: "phase=\(phase) \(fixture.diagnostics)\n" + DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: fixture.resources))
      attachment.name = "paper-transfer-final-owner"; attachment.lifetime = .keepAlways; add(attachment)
    }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.canonicalPaper(in: 0)
    }
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let destination = try XCTUnwrap(source.layout.map { $0.pageCount - 1 })
    XCTAssertGreaterThan(destination, 1)
    fixture.showPages(current: 0, neighbour: destination)
    phase = "distant-preparation"
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.snapshot(in: 1) != nil }
    let originalPaper = WeakDocumentPaper(fixture.paper(in: 0))
    let originalIdentity = ObjectIdentifier(try XCTUnwrap(originalPaper.value))
    phase = "mark-original-runtime"
    let originalReceipt = try await XCTUnwrap(originalPaper.value).evaluateJavaScript("window.handoffDocument=document; window.handoffState={value:17}; notebookRenderer.pageReceipt()") as? [String: Any]
    // UIKit can dismantle a distant outgoing page before the replacement
    // current-page input reaches its surviving, already prepared controller.
    fixture.retirePresentation(0)
    fixture.select(1)
    phase = "retired-outgoing-awaiting-distant"
    XCTAssertNotNil(originalPaper.value, "The owner must retain the actual runtime between native hosts; the test keeps only a weak reference")
    // A passive snapshot's ready flag survives the mount. Read this retained
    // runtime only after its own canonical frame is installed above the fallback.
    try await wait(message: { fixture.diagnostics }) {
      guard let web = fixture.paper(in: 1), let renderer = web.navigationDelegate as? DocumentWebCoordinator else { return false }
      return fixture.ready[1] == true && fixture.canonicalPaper(in: 1)
        && !fixture.hosts[1].hasSnapshot && renderer.nativeInputIsReady(in: fixture.hosts[1])
    }
    let incoming = try XCTUnwrap(fixture.paper(in: 1))
    phase = "reading-installed-distant"
    XCTAssertEqual(ObjectIdentifier(incoming), originalIdentity)
    let retained = try await incoming.evaluateJavaScript("handoffDocument===document && handoffState.value===17")
    XCTAssertEqual(retained as? Bool, true)
    let receipt = try await incoming.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(receipt?["pageIndex"] as? Int, destination)
    XCTAssertEqual(receipt?["presentationKind"] as? String, "canonical")
    XCTAssertEqual(receipt?["renderToken"] as? String, fixture.currentToken)
    XCTAssertEqual(receipt?["runtimeID"] as? String, originalReceipt?["runtimeID"] as? String)
    XCTAssertEqual(receipt?["sourceKey"] as? String, originalReceipt?["sourceKey"] as? String)
    XCTAssertEqual(receipt?["stateKey"] as? String, originalReceipt?["stateKey"] as? String)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    let distantImage = XCTAttachment(image: try fixture.windowImage())
    distantImage.name = "paper-transfer-distant-same-runtime"; distantImage.lifetime = .keepAlways; add(distantImage)
    fixture.restorePresentation(0)
    fixture.select(0)
    phase = "returning-to-first"
    try await wait(message: { fixture.diagnostics }) {
      guard let web = fixture.paper(in: 0), let renderer = web.navigationDelegate as? DocumentWebCoordinator else { return false }
      return fixture.ready[0] == true && fixture.canonicalPaper(in: 0)
        && !fixture.hosts[0].hasSnapshot && renderer.nativeInputIsReady(in: fixture.hosts[0])
    }
    XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 0))), originalIdentity)
    let returned = try await incoming.evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(returned?["pageIndex"] as? Int, 0)
    XCTAssertEqual(returned?["renderToken"] as? String, fixture.currentToken)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
    let returnImage = XCTAttachment(image: try fixture.windowImage())
    returnImage.name = "paper-transfer-return-same-runtime"; returnImage.lifetime = .keepAlways; add(returnImage)
    phase = "completed"
  }

  func testDelayedIncomingCurrentPageKeepsOpenDocumentRuntimeUntilExplicitClose() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\hyperlink{far}{Far}The current page owns its runtime."
      + "\\newpage\\section{Intermediate}The far destination is not the adjacent page."
      + "\\newpage\\section{Far}\\hypertarget{far}{}The native handoff retains the current heap.\\hyperlink{body}{Return}")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var phase = "initial_ready", caughtError = "none"
    defer {
      let proof = XCTAttachment(string: "phase=\(phase) error=\(caughtError)\n\(fixture.diagnostics)\n" +
        DocumentPagePresentationOwner.presentationDiagnostic(documentID: document.id, resources: fixture.resources))
      proof.name = "delayed-current-gap-boundary"; proof.lifetime = .keepAlways; add(proof)
    }
    do {
      try await wait(message: { fixture.diagnostics }) {
        fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.canonicalPaper(in: 0)
      }
      phase = "resolve_measured_target"
      let destination = try XCTUnwrap(DocumentRenderRegistry.shared.session(documentID: document.id,
        resources: fixture.resources).source(document).layout.map { $0.pageCount - 1 })
      XCTAssertGreaterThan(destination, 1)
      phase = "prepare_passive_target"
      fixture.showPages(current: 0, neighbour: destination)
      try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.snapshot(in: 1) != nil }
      let original = WeakDocumentPaper(fixture.paper(in: 0))
      let identity = ObjectIdentifier(try XCTUnwrap(original.value))
      phase = "read_original_javascript_receipt"
      let originalRaw = try await XCTUnwrap(original.value).evaluateJavaScript(
        "window.delayedHandoffDocument=document; window.delayedHandoffValue=29; notebookRenderer.pageReceipt()")
      let receipt = try XCTUnwrap(originalRaw as? [String: Any])
      let runtimeID = try XCTUnwrap(receipt["runtimeID"] as? String)
      let sourceKey = try XCTUnwrap(receipt["sourceKey"] as? String)
      XCTAssertFalse(runtimeID.isEmpty); XCTAssertFalse(sourceKey.isEmpty)
      let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)

      phase = "retire_original_presentation"
      fixture.retirePresentation(0)
      // The incoming native host is real and already has its passive pixels.
      // Let the existing owner task actually finish before SwiftUI supplies its
      // new isCurrent input. No ready callback or elapsed-time substitute is used.
      phase = "yield_before_existing_work_drain"
      await Task.yield()
      phase = "drain_existing_presentation_work"
      await owner.observePendingPresentationWork()
      phase = "assert_original_after_drain"
      XCTAssertNotNil(original.value, "A gap in physical current-page publication must not close the open document runtime")
      phase = "select_prepared_target"
      fixture.select(1)
      try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.hosts[1].isUserInteractionEnabled && fixture.paper(in: 1) != nil }
      XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 1))), identity)
      // The earlier passive picture may still have a true readiness callback.
      // Keep the identity assertion above; only read JavaScript after the actual
      // installed paper has accepted this page's canonical frame.
      phase = "await_actual_canonical_target"
      try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 1) }
      XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(fixture.paper(in: 1))), identity)
      phase = "read_returned_javascript_receipt"
      let returnedRaw = try await XCTUnwrap(fixture.paper(in: 1)).evaluateJavaScript("notebookRenderer.pageReceipt()")
      let returned = try XCTUnwrap(returnedRaw as? [String: Any])
      XCTAssertEqual(try XCTUnwrap(returned["runtimeID"] as? String), runtimeID)
      XCTAssertEqual(try XCTUnwrap(returned["sourceKey"] as? String), sourceKey)
      phase = "read_preserved_javascript_marker"
      let preserved = try await XCTUnwrap(fixture.paper(in: 1)).evaluateJavaScript(
        "window.delayedHandoffDocument===document && window.delayedHandoffValue===29")
      XCTAssertEqual(preserved as? Bool, true)
      XCTAssertEqual(DocumentRenderRegistry.shared.session(documentID: document.id,
        resources: fixture.resources).source(document).measurementCount, 1)

      phase = "explicit_close"
      fixture.close()
      try await wait(message: { fixture.diagnostics }) {
        original.value == nil && fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.pendingWebRequestCount == 0
      }
      XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
      phase = "complete"
    } catch {
      let native = error as NSError
      caughtError = "type=\(String(reflecting: type(of: error))) domain=\(native.domain) code=\(native.code) description=\(String(describing: error))"
      throw error
    }
  }

  func testReturnToDocumentReattachesPreparedWorkingPaperWithoutRebuildingIt() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\section{Return here}\\hypertarget{return-here}{}\n\nA prepared formula \\(x^2 + y^2\\) and editable source.")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    let lifetime = owner.retainOpenDocument()
    defer { fixture.close(); lifetime.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) && fixture.hosts[0].isUserInteractionEnabled }
    let web = try XCTUnwrap(fixture.paper(in: 0))
    let original = try await web.evaluateJavaScript("JSON.stringify(notebookRenderer.pageReceipt().work)") as? String
    let source = try XCTUnwrap((web.navigationDelegate as? DocumentWebCoordinator)?.payload?.source)
    let measurements = source.measurementCount, fragments = source.compiledPageCount
    lifetime.parkForReturn()
    fixture.retirePresentation(0)
    await owner.observePendingPresentationWork()
    XCTAssertFalse(web.isDescendant(of: fixture.hosts[0]))
    lifetime.resume()
    fixture.restorePresentation(0)
    try await wait(message: { fixture.diagnostics }) { fixture.paper(in: 0) === web && fixture.hosts[0].isUserInteractionEnabled }
    let returned = try await web.evaluateJavaScript("JSON.stringify(notebookRenderer.pageReceipt().work)") as? String
    XCTAssertEqual(returned, original, "Return attaches the existing DOM; parsing, math, layout and page installation do not run again")
    XCTAssertEqual(source.measurementCount, measurements)
    XCTAssertEqual(source.compiledPageCount, fragments)
    let requested = expectation(description: "Native source is addressed by returned paper")
    let observer = NotificationCenter.default.addObserver(forName: DocumentSourceRequest.notification, object: nil, queue: .main) { note in
      guard let request = note.object as? DocumentSourceRequest, request.documentID == document.id else { return }
      XCTAssertEqual(request.source, document.files.first { $0.id == "body" }?.source)
      requested.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    _ = try await web.evaluateJavaScript("""
      const block=document.querySelector('[data-block-id=body]'), rect=block.getBoundingClientRect();
      block.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,clientX:rect.left+5,clientY:rect.top+5}));true;
      """)
    await fulfillment(of: [requested], timeout: 3)

  }

  func testCodeModeKeepsTheSameFrozenHeapThroughSourceChangesAndDelayedPersistence() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .tex(id: "body", source: "\\section{Before}\\hypertarget{before}{}"),
      .program(id: "clock", html: "<output></output>", javaScript: """
        let phase=0,timer;
        const start=()=>{timer=setInterval(()=>{phase++;document.querySelector('output').textContent=phase},10)};
        notebook.lifecycle({pause(){clearInterval(timer)},checkpoint(){return {phase}},resume:start,dispose(){clearInterval(timer)}});
        notebook.ready(Promise.resolve().then(start));
        """, initialState: .object(["phase": .number(0)]), height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    var held: CheckedContinuation<Void, Never>?
    defer { held?.resume(); fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "clock") != nil }
    let web = try XCTUnwrap(fixture.web(block: "clock"))
    try await Task.sleep(for: .milliseconds(100))
    fixture.onCheckpoint = { _ in await withCheckedContinuation { held = $0 } }
    fixture.setVisible(false)
    try await wait(message: { fixture.diagnostics }) { held != nil }
    let phase = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    fixture.replaceSource(fileID: "body", source: "\\section{After}\\hypertarget{after}{}")
    fixture.setVisible(true)
    try await Task.sleep(for: .milliseconds(150))
    let waiting = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertEqual(waiting, phase, "Returning must await durable persistence, not cancel it")
    fixture.onCheckpoint = { _ in }; held?.resume(); held = nil
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "clock") === web }
    try await Task.sleep(for: .milliseconds(100))
    let resumed = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertGreaterThan(resumed ?? 0, phase ?? 0)

    var attempts = 0
    fixture.onCheckpoint = { _ in attempts += 1 }; fixture.acceptsCheckpoints = false
    fixture.setVisible(false)
    try await wait(message: { fixture.diagnostics }) { attempts > 0 }
    fixture.setVisible(true)
    try await wait(message: { fixture.diagnostics }) { fixture.hasProgramAction("clock") }
    let failed = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    try await Task.sleep(for: .milliseconds(150))
    let stillFrozen = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertEqual(stillFrozen, failed, "An I/O failure cannot restart an unconfirmed hidden model")
    fixture.acceptsCheckpoints = true
    fixture.setVisible(false); fixture.setVisible(true)
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && !fixture.hasProgramAction("clock") }
    XCTAssertTrue(fixture.web(block: "clock") === web)
  }

  func testBackgroundCheckpointFreezesTheModelAndForegroundResumesTheSameHeap() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "clock",
      html: "<output></output>", javaScript: """
        let phase=0,timer;
        const tick=()=>{phase++;document.querySelector('output').textContent=phase};
        const start=()=>{timer=setInterval(tick,10)};
        notebook.lifecycle({pause(){clearInterval(timer)},checkpoint(){return {phase}},resume:start,dispose(){clearInterval(timer)}});
        notebook.ready(Promise.resolve().then(start));
        """, initialState: .object(["phase": .number(0)]), height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "clock") != nil }
    let web = try XCTUnwrap(fixture.web(block: "clock"))
    try await Task.sleep(for: .milliseconds(100))
    let saved = await DocumentPagePresentationOwner.checkpointPrograms(documentID: document.id, resources: fixture.resources, resume: false)
    XCTAssertTrue(saved)
    let phase = fixture.number("clock", field: "phase")
    XCTAssertGreaterThan(phase, 0)
    try await Task.sleep(for: .milliseconds(100))
    let frozen = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertEqual(frozen, phase)
    await DocumentPagePresentationOwner.resumePrograms(resources: fixture.resources)
    try await Task.sleep(for: .milliseconds(100))
    let resumed = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertGreaterThan(resumed ?? 0, phase)
    XCTAssertTrue(fixture.web(block: "clock") === web)
  }

  func testClosingAnObsoleteProgramDoesNotPinItsSupersededHeap() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "clock", html: "<output>old</output>",
      javaScript: "notebook.lifecycle({checkpoint:()=>({phase:0.25})});notebook.ready(Promise.resolve());",
      initialState: .object(["phase": .number(0)]), height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "clock") != nil }
    fixture.onCheckpoint = { [weak fixture] _ in fixture?.replaceState(blockID: "clock", value: .object(["phase": .number(0.75)])) }
    fixture.close()
    try await wait(message: { fixture.diagnostics }) { fixture.resources.activeWebSurfaceCount == 0 }
    XCTAssertEqual(fixture.number("clock", field: "phase"), 0.75)
    XCTAssertNil(fixture.checkpointValues["clock"], "The superseded heap must not overwrite its successor")
  }

  func testResumeFailureShowsRetryAndResumesTheSameFrozenHeap() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program", html: "<output>model</output>",
      javaScript: """
        window.pauses=0;window.checkpoints=0;window.resumes=0;window.nonce=crypto.randomUUID();
        notebook.lifecycle({pause(){pauses++},checkpoint(){checkpoints++;return {phase:.5}},
          resume(){if(++resumes===1)throw Error('resume once')}});notebook.ready(Promise.resolve());
      """, height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "program") != nil }
    let web = try XCTUnwrap(fixture.web(block: "program"))
    let nonce = try await web.evaluateJavaScript("nonce") as? String
    let accepted = await DocumentPagePresentationOwner.checkpointPrograms(documentID: document.id, resources: fixture.resources, resume: true)
    XCTAssertFalse(accepted)
    try await wait(message: { fixture.diagnostics }) { fixture.hasProgramAction("program") }
    XCTAssertFalse(web.isUserInteractionEnabled)
    try fixture.retryProgram("program")
    try await wait(message: { fixture.diagnostics }) { fixture.web(block: "program") === web && web.isUserInteractionEnabled && fixture.isPresented }
    let finalNonce = try await web.evaluateJavaScript("nonce") as? String
    let stages = try await web.evaluateJavaScript("[pauses,checkpoints,resumes]") as? [Int]
    XCTAssertEqual(finalNonce, nonce); XCTAssertEqual(stages, [1, 1, 2])
  }

  func testFailedPauseAndCheckpointRetryOnlyTheirUnfinishedStage() async throws {
    for failedStage in ["pause", "checkpoint"] {
      let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program", html: "<output>model</output>",
        javaScript: """
          window.pauses=0;window.checkpoints=0;window.resumes=0;
          notebook.lifecycle({pause(){if(++pauses===1 && '\(failedStage)'==='pause')throw Error('pause once')},
            checkpoint(){if(++checkpoints===1 && '\(failedStage)'==='checkpoint')throw Error('checkpoint once');return {phase:.5}},
            resume(){resumes++}});notebook.ready(Promise.resolve());
        """, height: 100)])
      let fixture = try ProgramFixture(document: document, showsNeighbour: false)
      defer { fixture.close() }
      try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "program") != nil }
      let web = try XCTUnwrap(fixture.web(block: "program"))
      let accepted = await DocumentPagePresentationOwner.checkpointPrograms(documentID: document.id, resources: fixture.resources, resume: false)
      XCTAssertFalse(accepted)
      try await wait(message: { fixture.diagnostics }) { fixture.hasProgramAction("program") }
      try fixture.retryProgram("program")
      try await wait(message: { fixture.diagnostics }) { fixture.web(block: "program") === web && fixture.isPresented }
      let frozenStages = try await web.evaluateJavaScript("[pauses,checkpoints,resumes]") as? [Int]
      XCTAssertEqual(frozenStages, failedStage == "pause" ? [2, 1, 0] : [1, 2, 0], "Retry repairs the failed stage without releasing a closed owner boundary")
      await DocumentPagePresentationOwner.resumePrograms(resources: fixture.resources)
      let stages = try await web.evaluateJavaScript("[pauses,checkpoints,resumes]") as? [Int]
      XCTAssertEqual(stages, failedStage == "pause" ? [2, 1, 1] : [1, 2, 1])
    }
  }

  func testClosingDocumentRetainsAnUnacceptedModelUntilExplicitRetry() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "clock",
      html: "<output>0.625</output>", javaScript: """
        notebook.lifecycle({checkpoint:()=>({phase:0.625})});notebook.ready(Promise.resolve());
        """, initialState: .object(["phase": .number(0)]), height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "clock") != nil }
    var attempts = 0
    fixture.onCheckpoint = { _ in attempts += 1 }
    fixture.acceptsCheckpoints = false
    fixture.close()
    try await wait(message: { fixture.diagnostics }) { attempts == 1 }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertGreaterThan(fixture.resources.activeWebSurfaceCount, 0, "Dismantling is not permission to discard unsaved author state")
    XCTAssertNil(fixture.checkpointValues["clock"])
    fixture.acceptsCheckpoints = true
    DocumentPagePresentationOwner.retryRetiringPrograms(resources: fixture.resources)
    try await wait(message: { fixture.diagnostics }) { fixture.resources.activeWebSurfaceCount == 0 }
    XCTAssertEqual(fixture.checkpointValues["clock"], .object(["phase": .number(0.625)]))
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
  }

  func testReturnProgramFreezesItsModelWithoutWaitingForPoolPressure() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program",
      html: "<output>0</output>", javaScript: """
        let phase=0,timer=setInterval(()=>{phase++;document.querySelector('output').textContent=phase},10);
        notebook.lifecycle({pause(){clearInterval(timer)},checkpoint(){return {phase}},resume(){},dispose(){clearInterval(timer)}});
        notebook.ready(Promise.resolve());
        """, initialState: .object(["phase": .number(0)]), height: 100)])
    let resources = SceneRenderResources(maximumWebSurfaces: 6)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: resources)
    let lifetime = owner.retainOpenDocument()
    defer { fixture.close(); lifetime.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "program") != nil }
    let original = try XCTUnwrap(fixture.web(block: "program"))
    try await Task.sleep(for: .milliseconds(100))
    lifetime.parkForReturn(); fixture.retirePresentation(0)
    try await wait(message: { fixture.diagnostics }) { fixture.checkpoints.contains("program") }
    let frozen = try await original.evaluateJavaScript("document.querySelector('output').textContent") as? String
    try await Task.sleep(for: .milliseconds(200))
    let later = try await original.evaluateJavaScript("document.querySelector('output').textContent") as? String
    XCTAssertEqual(later, frozen)
    XCTAssertEqual(fixture.number("program", field: "phase"), Double(frozen ?? ""))
    lifetime.resume(); fixture.restorePresentation(0)
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "program") === original }
  }

  func testSupersededReturnRetryDoesNotCarryItsOldFailureIntoTheGlobalBoundary() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program", html: "<output>Model</output>",
      javaScript: "notebook.lifecycle({checkpoint:()=>({value:1})});notebook.ready(Promise.resolve());",
      initialState: .object(["value": .number(0)]), height: 100)])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    var held: CheckedContinuation<Void, Never>?
    defer {
      fixture.acceptsCheckpoints = true; fixture.onCheckpoint = { _ in }
      held?.resume(); fixture.close()
    }
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented && fixture.web(block: "program") != nil }
    let original = try XCTUnwrap(fixture.web(block: "program"))
    let runtime = try XCTUnwrap(original.navigationDelegate as? DocumentBlockRuntime)
    fixture.acceptsCheckpoints = false
    fixture.setVisible(false)
    let refused = await DocumentPagePresentationOwner.checkpointPrograms(documentID: document.id,
      resources: fixture.resources, resume: false)
    XCTAssertFalse(refused)
    await DocumentPagePresentationOwner.resumePrograms(resources: fixture.resources)

    fixture.acceptsCheckpoints = true
    fixture.onCheckpoint = { _ in await withCheckedContinuation { held = $0 } }
    fixture.setVisible(true)
    try await wait(message: { fixture.diagnostics }) { held != nil }
    var result: Bool?
    let boundary = Task { @MainActor in
      result = await DocumentPagePresentationOwner.checkpointPrograms(documentID: document.id,
        resources: fixture.resources, resume: false)
    }
    defer { boundary.cancel() }
    // The global boundary joins the held return writer; it cannot finish from
    // the failure retained by that same heap's previous attempt.
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(result)
    let successor: JSONValue = .object(["value": .number(2)])
    fixture.replaceState(blockID: "program", value: successor)
    held?.resume(); held = nil
    await boundary.value
    XCTAssertEqual(result, true, "A superseded heap has left the boundary, including its earlier writer failure")
    XCTAssertNil(runtime.webView, "The stale retry must retire after the newer accepted state supersedes it")
    XCTAssertEqual(fixture.value("program"), successor)

    fixture.onCheckpoint = { _ in }
    await DocumentPagePresentationOwner.resumePrograms(resources: fixture.resources)
    try await wait(message: { fixture.diagnostics }) {
      fixture.isPresented && fixture.web(block: "program") != nil && fixture.web(block: "program") !== original
    }
    XCTAssertFalse(fixture.hasProgramAction("program"))
    XCTAssertEqual(fixture.value("program"), successor)
  }

  func testReturnProgramsYieldTheirExistingPoolSlotsAfterCheckpointWhenForegroundNeedsThem() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program",
      html: "<button>Retained return program</button>", javaScript: "notebook.commit({count:1});notebook.ready(Promise.resolve());",
      initialState: .object(["count": .number(0)]), height: 100)])
    let resources = SceneRenderResources(maximumWebSurfaces: 3)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: resources)
    let lifetime = owner.retainOpenDocument()
    defer { fixture.close(); lifetime.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(in: 0) != nil }
    let original = try XCTUnwrap(fixture.web(in: 0))
    lifetime.parkForReturn(); fixture.retirePresentation(0)
    await owner.observePendingPresentationWork()
    let first = try await resources.acquireWebSurface(priority: .input)
    defer { first.release() }
    let second = try await resources.acquireWebSurface(priority: .input)
    defer { second.release() }
    let third = try await resources.acquireWebSurface(priority: .input)
    defer { third.release() }
    XCTAssertTrue(fixture.checkpoints.contains("program"), "Only an accepted state checkpoint can retire a running return program")
    XCTAssertEqual(fixture.checkpointValues["program"], .object(["count": .number(1)]))
    first.release(); second.release(); third.release()
    lifetime.resume(); fixture.restorePresentation(0)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(in: 0) != nil && fixture.web(in: 0) !== original }
    XCTAssertEqual(fixture.value("program"), .object(["count": .number(1)]))
  }

  func testRefusedReturnCheckpointDoesNotBlockReclaimingAnotherIdleSurface() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program",
      html: "<button>Unsaved return program</button>", javaScript: "notebook.commit({count:1});notebook.ready(Promise.resolve());",
      initialState: .object(["count": .number(0)]), height: 100)])
    let resources = SceneRenderResources(maximumWebSurfaces: 3)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: resources)
    let lifetime = owner.retainOpenDocument()
    defer { fixture.close(); lifetime.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(in: 0) != nil }
    let original = try XCTUnwrap(fixture.web(in: 0))
    var attempted = false
    fixture.acceptsCheckpoints = false
    fixture.onCheckpoint = { _ in attempted = true }
    lifetime.parkForReturn(); fixture.retirePresentation(0)
    await owner.observePendingPresentationWork()
    let first = try await resources.acquireWebSurface(priority: .input)
    defer { first.release() }
    var admitted: WebSurfaceLease?
    let request = Task { @MainActor in admitted = try await resources.acquireWebSurface(priority: .input) }
    defer { request.cancel(); admitted?.release() }
    try await wait(message: { "attempted=\(attempted) " + fixture.diagnostics }) { attempted && admitted != nil }
    XCTAssertFalse(fixture.checkpoints.contains("program"), "Rejected state is not permission to destroy the running program")
    first.release(); admitted?.release()
    lifetime.resume(); fixture.restorePresentation(0)
    try await wait(message: { fixture.diagnostics }) { fixture.hasProgramAction("program") }
    XCTAssertNotNil(original.superview, "A failed writer retains the frozen heap, not a falsely interactive surface")
    XCTAssertFalse(original.isUserInteractionEnabled)
    fixture.acceptsCheckpoints = true
    try fixture.retryProgram("program")
    try await wait(message: { fixture.diagnostics }) { fixture.web(in: 0) === original && fixture.ready[0] == true }
  }

  func testClosingFullPresentationRetiresPaperWhileThumbnailKeepsItsPicture() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\section{One open document}\\hypertarget{one-open-document}{}\n\nA remaining thumbnail owns its picture, not the closed document runtime.")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    fixture.showPages(current: 0, neighbour: 0)
    fixture.setThumbnail(1)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 0) && fixture.ready[1] == true && fixture.snapshot(in: 1) != nil
    }
    let original = WeakDocumentPaper(fixture.paper(in: 0))
    XCTAssertNotNil(original.value)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    fixture.retirePresentation(0)
    await Task.yield()
    await owner.observePendingPresentationWork()
    try await wait(message: { fixture.diagnostics }) {
      original.value == nil && fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.pendingWebRequestCount == 0
    }
    XCTAssertNotNil(fixture.snapshot(in: 1), "Closing the document must preserve the separately owned thumbnail picture")
    fixture.close()
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
  }

  func testClosingDuringPaperTransferRetiresTheRuntimeAndItsAdmission() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{A current paper}\\hypertarget{a-current-paper}{}\n\nIts owner may close before the next host is selected.")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.paper(in: 0) != nil }
    let runtime = WeakDocumentPaper(fixture.paper(in: 0))
    fixture.retirePresentation(0)
    XCTAssertNotNil(runtime.value, "The current runtime is parked until the owner resolves its handoff")
    fixture.close()
    try await wait(message: { fixture.diagnostics }) {
      runtime.value == nil && fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.pendingWebRequestCount == 0
    }
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
  }

  func testNativeFailureDuringPaperTransferRetiresOnlyItsParkedRuntimeAndAdmission() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{A ready paper}\\hypertarget{a-ready-paper}{}\n\nA terminal event can arrive before its replacement host is current.")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.paper(in: 0) != nil }
    let runtime = WeakDocumentPaper(fixture.paper(in: 0))
    fixture.activity.update(true)
    fixture.retirePresentation(0)
    XCTAssertNotNil(runtime.value)
    try await wait(message: { fixture.diagnostics }) {
      runtime.value != nil && fixture.resources.activeWebSurfaceCount == 1 && fixture.resources.pendingWebRequestCount == 0
    }
    // Public navigation-delegate failure against the real prepared WK. This
    // deterministic lifecycle seam does not claim an actual OS process crash.
    if let web = runtime.value {
      let coordinator = try XCTUnwrap(web.navigationDelegate as? DocumentWebCoordinator)
      coordinator.webView(web, didFail: nil,
        withError: NSError(domain: "DocumentPaperTransferContract", code: 1))
    }
    try await wait(message: { fixture.diagnostics }) {
      runtime.value == nil && fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.pendingWebRequestCount == 0
    }
  }

  func testMeasuredLayoutUpdatesLinkCallbackWithoutReloadingTheCanonicalPaper() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      "\\hyperlink{far}{Far chapter}\n\n" + (0..<45).map { "Paragraph \($0). " + String(repeating: "A stable physical page keeps its current navigation callback. ", count: 8) }.joined(separator: "\n\n")
      + "\n\n\\section{Far}\\hypertarget{far}{}\n\nDestination")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var initialCalls = 0, acceptedPage: Int?
    let initialPageCount = 1
    fixture.replaceLinkNavigation { destination in
      initialCalls += 1
      if case .page(let page) = destination, page >= 0, page < initialPageCount { acceptedPage = page }
    }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.canonicalPaper(in: 0)
    }
    let paper = try XCTUnwrap(fixture.paper(in: 0))
    let before = try await paper.evaluateJavaScript("window.callbackTestDocument=document; JSON.stringify(notebookRenderer.pageReceipt())")
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let measuredCount = try XCTUnwrap(source.layout?.pageCount)
    XCTAssertGreaterThan(measuredCount, 1)
    _ = try await paper.evaluateJavaScript("document.querySelector('a[href^=\"#notebook-print-page-\"]').click(); true")
    try await wait(message: { fixture.diagnostics }) { initialCalls == 1 }
    XCTAssertNil(acceptedPage, "The initial one-page closure rejects the later measured destination")
    fixture.replaceLinkNavigation { destination in
      if case .page(let page) = destination, page >= 0, page < measuredCount { acceptedPage = page }
    }
    _ = try await paper.evaluateJavaScript("document.querySelector('a[href^=\"#notebook-print-page-\"]').click(); true")
    try await wait(message: { fixture.diagnostics }) { acceptedPage != nil }
    XCTAssertEqual(initialCalls, 1, "The old captured layout callback is retired by the same-entry update")
    XCTAssertGreaterThan(try XCTUnwrap(acceptedPage), 0)
    XCTAssertTrue(fixture.paper(in: 0) === paper)
    let sameDocument = try await paper.evaluateJavaScript("callbackTestDocument===document")
    XCTAssertEqual(sameDocument as? Bool, true)
    let after = try await paper.evaluateJavaScript("JSON.stringify(notebookRenderer.pageReceipt())")
    XCTAssertEqual(after as? String, before as? String, "Callback refresh cannot change the frame generation, source or canonical receipt")
  }

  func testLoadingCaptionUsesItsTextWidthAndWrapsWithinThePhysicalPage() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController(), host = DocumentWebHost()
    window.rootViewController = controller; controller.view.backgroundColor = .systemGray6
    controller.view.addSubview(host); window.makeKeyAndVisible()
    defer { host.removeLoading(); window.isHidden = true; window.rootViewController = nil }
    host.showLoading()
    let stack = try XCTUnwrap(host.subviews.compactMap { $0 as? UIStackView }.first)
    let label = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? UILabel }.first)
    let spinner = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? UIActivityIndicatorView }.first)
    for width in [CGFloat(320), CGFloat(120)] {
      host.frame = .init(x: 24, y: 24, width: width, height: 300)
      controller.view.layoutIfNeeded(); host.layoutIfNeeded()
      let textSize = label.sizeThatFits(.init(width: width - 24, height: .greatestFiniteMagnitude))
      XCTAssertEqual(label.text, "Подготовка страницы…")
      XCTAssertGreaterThan(label.bounds.width, spinner.bounds.width,
        "The spinner's intrinsic width cannot constrain the full caption")
      XCTAssertGreaterThanOrEqual(label.bounds.width + 1, textSize.width)
      XCTAssertGreaterThanOrEqual(label.bounds.height + 1, textSize.height)
      let labelFrame = label.convert(label.bounds, to: host)
      XCTAssertGreaterThanOrEqual(labelFrame.minX, 12 - 1)
      XCTAssertLessThanOrEqual(labelFrame.maxX, host.bounds.width - 12 + 1)
      XCTAssertFalse(stack.hasAmbiguousLayout)
      if width == 120 { XCTAssertGreaterThan(label.bounds.height, label.font.lineHeight) }
      var drawn = false
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      XCTAssertTrue(drawn)
      let attachment = XCTAttachment(image: image)
      attachment.name = "loading-caption-physical-width-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
    }
  }

  func testCurrentPagePreparationMetadataComesFromItsActualWebKitGeneration() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source: "\\section{Observed document}\\hypertarget{observed-document}{}\n\nA real canonical page.")])
    let recorder = DocumentPresentationRecorder(enabled: true)
    let request = try XCTUnwrap(recorder.request(documentID: document.id, pageIndex: 0, cause: .open))
    let fixture = try ProgramFixture(document: document, measurements: recorder)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { recorder.records.last?.installedAt != nil }
    let record = try XCTUnwrap(recorder.records.last), identity = try XCTUnwrap(record.pagePreparationIdentity)
    XCTAssertEqual(identity.requestID, request)
    XCTAssertEqual(identity.token, fixture.currentToken)
    XCTAssertEqual(identity.documentID, document.id)
    let phases = try XCTUnwrap(record.pagePreparationPhasesMS)
    for stage in ["payloadConfiguredAt", "mountAt", "admissionRequestedAt", "admittedAt", "frameTaskAt",
      "preparedPageStartAt", "preparedPageReadyAt", "pageSourceEncodedAt", "stateEncodedAt", "frameEncodedAt",
      "frameEvaluationStartAt", "renderStartedAt", "renderedAt", "pageReceiptRequestedAt", "pageReceiptReturnedAt", "layoutReceiptAcceptedAt", "canonicalReadyAt"] {
      XCTAssertNotNil(phases[stage], stage)
    }
    XCTAssertTrue(phases["shellNavigationFinishedAt"] != nil || phases["shellReadyMessageAt"] != nil)
    // Native PDF preparation starts independently of interaction admission.
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["payloadConfiguredAt"]), try XCTUnwrap(phases["preparedPageStartAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["admittedAt"]), try XCTUnwrap(phases["frameEvaluationStartAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["preparedPageReadyAt"]), try XCTUnwrap(phases["frameEvaluationStartAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["pageReceiptRequestedAt"]), try XCTUnwrap(phases["pageReceiptReturnedAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["pageReceiptReturnedAt"]), try XCTUnwrap(phases["layoutReceiptAcceptedAt"]))
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["layoutReceiptAcceptedAt"]), try XCTUnwrap(phases["canonicalReadyAt"]))
    XCTAssertLessThanOrEqual(identity.configuredAt + (try XCTUnwrap(phases["canonicalReadyAt"])) / 1_000,
      try XCTUnwrap(record.contentReadyAt))
    let receipt = try await XCTUnwrap(fixture.paper(in: 0)).evaluateJavaScript("notebookRenderer.pageReceipt()") as? [String: Any]
    XCTAssertEqual(receipt?["generation"] as? String, identity.generation)
    XCTAssertEqual(receipt?["renderToken"] as? String, identity.token)
  }

  func testTallProgramHasOneContextAcrossPassivePagesCurlAndIndexReclamation() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program",
      html: "<button id='increment'>Add one</button><output id='value'></output><div style='height:1550px;background:linear-gradient(#cdeeff,#ffe1d5)'></div><button id='increment-last'>Add one</button>",
      css: "button{font-size:24px}output{display:block;font-size:24px}", javaScript: """
      const nonce=crypto.randomUUID();let count=notebook.state.count||0,ticks=0;
      const report=()=>{document.querySelector('#value').textContent=String(count);notebook.commit({...notebook.state,nonce,count,ticks});};
      document.querySelectorAll('button').forEach(button=>button.onclick=()=>{count++;report();});
      addEventListener('message',event=>{if(event.data==='increment'){count++;report();}if(event.data==='probe')report();});
      setInterval(()=>{ticks++;},40);
      notebook.commit({...notebook.state,nonce,count,mounts:(notebook.state.mounts||0)+1});
      notebook.ready(Promise.resolve());
      """, initialState: .object(["count": .number(0)]), height: 2048)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.web(in: 0) != nil }
    let web = try XCTUnwrap(fixture.web(in: 0))
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
    let nonce = try XCTUnwrap(fixture.value("program")?["nonce"])
    XCTAssertEqual(fixture.value("program")?["mounts"], .number(1))
    _ = try await web.evaluateJavaScript("window.originalProgram=document;true")
    try await fixture.message("increment", in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["count"] == .number(1) }
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) { fixture.web(in: 1) === web && fixture.ready[1] == true && fixture.hosts[1].isUserInteractionEnabled }
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
    let same = try await web.evaluateJavaScript("originalProgram===document")
    XCTAssertEqual(same as? Bool, true)
    XCTAssertEqual(fixture.value("program")?["nonce"], nonce)
    XCTAssertEqual(fixture.value("program")?["mounts"], .number(1))
    try await fixture.message("probe", in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.number("program", field: "ticks") > 0 }
    let physicalPage = UIGraphicsImageRenderer(bounds: fixture.hosts[1].bounds).image { _ in
      fixture.hosts[1].drawHierarchy(in: fixture.hosts[1].bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: physicalPage)
    attachment.name = "single-program-second-physical-cut"; attachment.lifetime = .keepAlways; add(attachment)

    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    await source.discardIdlePreparation()
    try await wait(message: { fixture.diagnostics }) { fixture.hosts[1].isUserInteractionEnabled && fixture.ready[1] == true }
    fixture.activity.update(true)
    fixture.select(0)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(fixture.web(in: 1) === web, "An accepted native curl keeps the exact runtime at its previous host until completion")
    let lockedPage = try await XCTUnwrap(fixture.paper(in: 1)).evaluateJavaScript("notebookRenderer.pageReceipt().pageIndex")
    XCTAssertEqual(lockedPage as? Int, 1)
    fixture.activity.update(false)
    try await wait(message: { fixture.diagnostics }) { fixture.web(in: 0) === web && fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.web(in: 0) != nil }
    try await fixture.message("increment", in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["count"] == .number(2) }
    let survived = try await web.evaluateJavaScript("originalProgram===document")
    XCTAssertEqual(survived as? Bool, true, "Reclaiming the inert index cannot recreate a program")
    XCTAssertEqual(fixture.value("program")?["mounts"], .number(1))
    XCTAssertEqual(fixture.value("program")?["nonce"], nonce)
  }

  func testNeverReadyNeighborDoesNotSwitchOrDisableTheCurrentProgram() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [
      .program(id: "current", html: "<button>Ready control</button>", css: "", javaScript: "notebook.commit({started:true});notebook.ready(Promise.resolve());", initialState: .null, height: 1400),
      .program(id: "delayed", html: "<button>Waiting control</button>", css: "", javaScript: "notebook.ready(new Promise(()=>{}))", initialState: .null, height: 200)
    ])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(in: 0) != nil }
    let web = try XCTUnwrap(fixture.web(in: 0))
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true }
    XCTAssertEqual(fixture.ready[0], true)
    XCTAssertTrue(fixture.hosts[1].hasSnapshot, "An unresolved author ready promise leaves an explicit status in the turn frame")
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertTrue(fixture.web(in: 0) === web)
    let page = try await XCTUnwrap(fixture.paper(in: 0)).evaluateJavaScript("notebookRenderer.pageReceipt().pageIndex")
    XCTAssertEqual(page as? Int, 0)
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
  }

  func testLeavingTheProgramWindowCheckpointsStateBeforeRetirementAndRestoresItsIdentity() async throws {
    let program: (String) -> DocumentTestFiles = { id in
      .program(id: id, html: "<button>Count</button>", css: "", javaScript: """
      let count=notebook.state.count||0;const nonce=crypto.randomUUID();
      notebook.commit({...notebook.state,count,nonce,mounts:(notebook.state.mounts||0)+1});
      addEventListener('message',event=>{if(event.data==='increment')notebook.commit({...notebook.state,count:++count});});
      notebook.ready(Promise.resolve());
      """, initialState: .object(["count": .number(0)]), height: 2000)
    }
    let document = DocumentTestFiles.document(actor: UUID(), contents: [program("program"), program("middle"), program("last")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.web(in: 0) != nil }
    let web = try XCTUnwrap(fixture.web(in: 0))
    let firstNonce = try XCTUnwrap(fixture.value("program")?["nonce"])
    try await fixture.message("increment", in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["count"] == .number(1) }
    fixture.showPages(current: 4, neighbour: 3)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.checkpoints.contains("program") }
    let retirementDeadline = ContinuousClock.now + .seconds(5)
    var exists = true
    repeat {
      exists = web.superview != nil
      if exists { try await Task.sleep(for: .milliseconds(10)) }
    } while exists && ContinuousClock.now < retirementDeadline
    XCTAssertFalse(exists, "A program outside the physical working window retires only after its accepted explicit state is checkpointed")
    fixture.showPages(current: 0, neighbour: 1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.value("program")?["mounts"] == .number(2) }
    XCTAssertTrue(fixture.web(in: 0) !== web, "Retired explicit state creates one replacement context on return")
    XCTAssertEqual(fixture.value("program")?["count"], .number(1))
    XCTAssertNotEqual(fixture.value("program")?["nonce"], firstNonce)
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
  }

  func testAttentionCapturesLivePixelsEvenWhenProgramChangesWithoutAStateCommit() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program",
      html: "<div id='swatch' style='height:200px;background:#ff0000'></div>", css: "",
      javaScript: "addEventListener('message',event=>{if(event.data==='blue'){document.querySelector('#swatch').style.background='#0000ff';requestAnimationFrame(()=>window.postMessage('blue-ready','*'));}});;notebook.ready(Promise.resolve());",
      initialState: .null, height: 200)])
    let fixture = try ProgramFixture(document: document)
    fixture.showPages(current: 0, neighbour: 0)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.web(in: 0) != nil }
    let web = try XCTUnwrap(fixture.web(in: 0))
    let before = try await fixture.captureCurrent()
    defer { before.release() }
    let token = before.source
    _ = try await web.callAsyncJavaScript("""
      await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(new Error('Program did not repaint')),2000);
        const painted=event=>{if(event.data==='blue-ready'){removeEventListener('message',painted);clearTimeout(timer);resolve();}};
        addEventListener('message',painted);window.postMessage('blue','*');
      });await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));return true;
      """,
      arguments: [:], in: nil, contentWorld: .page)
    fixture.hosts[0].frame.size.width /= 2; fixture.hosts[0].frame.size.height /= 2
    fixture.hosts[0].setNeedsLayout(); fixture.hosts[0].layoutIfNeeded()
    let after = try await fixture.captureCurrent()
    defer { after.release() }
    XCTAssertEqual(after.source, token, "Source and explicit state remain identical while the program changes its pixels")
    XCTAssertNotEqual(after.entryID, before.entryID)
    XCTAssertNotEqual(after.image.pngData(), before.image.pngData(), "Attention cannot return the previous cache entry for a live frame")
    XCTAssertLessThan(try XCTUnwrap(after.image.cgImage).width, try XCTUnwrap(before.image.cgImage).width,
      "An older higher-density cache entry cannot replace the lower-density frame just captured")
    XCTAssertGreaterThan(try bluePixels(after.image), 100)
    XCTAssertEqual(try bluePixels(before.image), 0)
    let attachment = XCTAttachment(image: after.image)
    attachment.name = "document-attention-current-blue-program"; attachment.lifetime = .keepAlways; add(attachment)
    let physical = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: 0)
    let frozen = try XCTUnwrap(DocumentPagePresentationOwner.capturePresented(documentID: document.id, pageIndex: 0,
      token: fixture.currentToken, region: .init(x: 0, y: 0, width: physical.width, height: physical.height), resources: fixture.resources, blockID: "program"))
    let provenance = try XCTUnwrap(frozen.presentation)
    #if targetEnvironment(simulator)
      XCTAssertEqual(provenance.device, .iOSSimulator)
    #else
      XCTAssertEqual(provenance.device, .iPad)
    #endif
    XCTAssertLessThan(abs(provenance.capturedAt - Date().timeIntervalSince1970), 2)
    XCTAssertNil(provenance.program, "A running uncommitted frame cannot certify a reproducible checkpoint")
    _ = try await web.evaluateJavaScript("document.querySelector('#swatch').style.background='#ff0000';true")
    let encodedLater = try await frozen.png()
    XCTAssertEqual(frozen.presentation, provenance)
    XCTAssertGreaterThan(try bluePixels(try XCTUnwrap(UIImage(data: encodedLater))), 100,
      "Encoding after a later DOM change retains the blue native frame frozen synchronously before that change")
    let wrongPage = try await DocumentPagePresentationOwner.captureCurrent(documentID: document.id, pageIndex: 1,
      token: fixture.currentToken, resources: fixture.resources)
    XCTAssertNil(wrongPage)
    let wrongVersion = try await DocumentPagePresentationOwner.captureCurrent(documentID: document.id, pageIndex: 0,
      token: "previous-source", resources: fixture.resources)
    XCTAssertNil(wrongVersion)
    fixture.hosts[0].removeFromSuperview()
    let detached = try await DocumentPagePresentationOwner.captureCurrent(documentID: document.id, pageIndex: 0,
      token: fixture.currentToken, resources: fixture.resources)
    XCTAssertNil(detached)
  }

  func testRuntimeRecoveryUsesAcceptedStateWhileInputWasHoldingBackTheEcho() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program",
      html: "<input aria-label='Value'><button>Increment</button>", css: "", javaScript: """
      notebook.commit({...notebook.state,mounts:(notebook.state.mounts||0)+1});
      addEventListener('message',event=>{
        if(event.data==='focus'){document.querySelector('input').focus();notebook.commit({...notebook.state,focused:true});}
        if(event.data==='increment')notebook.commit({...notebook.state,count:(notebook.state.count||0)+1});
      });
      notebook.ready(Promise.resolve());
      """, initialState: .object(["count": .number(0)]), height: 2000)])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.ready[1] == true && fixture.hosts[0].isUserInteractionEnabled
        && fixture.web(in: 0) != nil
    }
    let original = try XCTUnwrap(fixture.web(in: 0))
    try await fixture.message("focus", in: original)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["focused"] == .bool(true) }
    try await fixture.message("increment", in: original)
    try await wait(message: { fixture.diagnostics }) { fixture.value("program")?["count"] == .number(1) }
    original.navigationDelegate?.webViewWebContentProcessDidTerminate?(original)
    try await wait(message: { fixture.diagnostics }) { fixture.web(in: 0) != nil && fixture.web(in: 0) !== original
      && fixture.value("program")?["mounts"] == .number(2) && fixture.hosts[0].isUserInteractionEnabled }
    XCTAssertEqual(fixture.value("program")?["count"], .number(1))
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
  }

  func testStationaryPassivePageRefinesAfterSharedPressureIsReleased() async throws {
    let resources = SceneRenderResources()
    let document = DocumentTestFiles.document(actor: UUID(), contents: [.tex(id: "body", source:
      (0..<50).map { "Paragraph \($0). " + String(repeating: "The stationary physical page remains readable. ", count: 8) }.joined(separator: "\n\n"))])
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true }
    let wanted = Int(ceil(fixture.hosts[1].bounds.width * (fixture.hosts[1].window?.screen.scale ?? 2)))
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    let geometry = try XCTUnwrap(source.layout).paper(on: 1).geometry
    let fullRaster = try XCTUnwrap(SceneRenderResources.estimatedRasterBytes(pixelWidth: wanted,
      pixelHeight: Int(ceil(Double(wanted) * geometry.height / geometry.width))))
    let available = resources.rasterAdmission
    // Pressure begins after the canonical PDF/SyncTeX preparation. Retain only
    // half one requested raster beside the existing live paper; no invented
    // tiny scene budget may prevent typesetting before this scenario starts.
    let bytes = min(available.byteLimit - available.heldBytes,
      available.passiveByteLimit - available.pinnedBytes - available.passiveReservedBytes) - fullRaster / 2
    let pressure = try XCTUnwrap(resources.reserveDerivedBytes(bytes, priority: .passive))
    defer { pressure.release() }
    fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true }
    let lowWidth = try XCTUnwrap(fixture.snapshot(in: 1)?.cgImage).width
    XCTAssertLessThan(lowWidth, wanted, "The initial image is admitted at the quality available beside real shared pressure")
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    pressure.release()
    try await wait(message: { fixture.diagnostics }) { (fixture.snapshot(in: 1)?.cgImage?.width ?? 0) >= wanted }
    XCTAssertLessThanOrEqual(resources.peakAccountedBytes, resources.byteLimit)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    let attachment = XCTAttachment(image: try XCTUnwrap(fixture.snapshot(in: 1)))
    attachment.name = "stationary-document-refined-after-admission"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testAnOffscreenProgramReleasesItsExecutorAfterWritingEvenWhenNoRasterCanBeAdmitted() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: (0..<4).map { index in
      .program(id: "program-\(index)", html: "<button>Control \(index)</button>",
        javaScript: "notebook.commit({accepted:1});notebook.ready(Promise.resolve());", height: 100)
    })
    let resources = SceneRenderResources(maximumRasterCount: 0)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { (0..<3).allSatisfy { fixture.web(block: "program-\($0)") != nil } }
    fixture.reveal(block: "program-3")
    // The fourth control is no longer held behind the removed three-program
    // quota. Its presence cannot stand in for completion of the others' writes.
    try await wait(message: { fixture.diagnostics }) {
      fixture.web(block: "program-3") != nil && resources.activeWebSurfaceCount <= 2
        && (0..<3).allSatisfy { fixture.checkpointValues["program-\($0)"]?["accepted"] == .number(1) }
    }
    XCTAssertTrue((0..<3).allSatisfy { fixture.checkpointValues["program-\($0)"]?["accepted"] == .number(1) })
    XCTAssertEqual(resources.rasterAdmission.pinnedCount, 0)
    XCTAssertLessThanOrEqual(resources.activeWebSurfaceCount, 2)
    XCTAssertTrue(fixture.presents(.paper))
  }

  func testNineVisibleProgramsQueueAutomaticallyAndViewportChangesPreserveAcceptedState() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: (0..<9).map { index in
      .program(id: "program-\(index)", html: "<button id='increment'>Increment \(index)</button><output id='value'></output>",
        css: "button{font-size:20px}output{padding:8px}", javaScript: """
        const render=()=>document.querySelector('#value').textContent=String(notebook.state.count||0);
        document.querySelector('button').onclick=()=>{notebook.commit({...notebook.state,count:(notebook.state.count||0)+1});render()};
        notebook.commit({...notebook.state,mounts:(notebook.state.mounts||0)+1});render();
      notebook.ready(Promise.resolve());
      """, initialState: .object(["count": .number(0)]), height: 90)
    })
    let fixture = try ProgramFixture(document: document, resources: SceneRenderResources(maximumWebSurfaces: 10), showsNeighbour: false)
    defer { fixture.close() }
    // One physical paper and one transient-preparation reserve leave the
    // remaining ordinary scene slots to already visible input owners.
    let liveCapacity = fixture.resources.maximumWebSurfaces - 2
    XCTAssertGreaterThanOrEqual(liveCapacity, 4)
    try await wait(message: { fixture.diagnostics }) {
      (0..<9).filter { fixture.web(block: "program-\($0)") != nil }.count == liveCapacity
        && fixture.resources.pendingWebRequestCount == 9 - liveCapacity
    }
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, liveCapacity + 1)
    // Admission preserves arrival order after each program's state encoding.
    let pendingID = try XCTUnwrap((0..<9).map { "program-\($0)" }.first { fixture.web(block: $0) == nil })
    XCTAssertFalse(fixture.hasProgramAction(pendingID), "Waiting is not a fake control or an activation button")
    fixture.reveal(block: "program-8")
    try await wait(message: { fixture.diagnostics }) { fixture.web(block: "program-8")?.isUserInteractionEnabled == true }
    let eighth = try XCTUnwrap(fixture.web(block: "program-8"))
    _ = try await eighth.evaluateJavaScript("document.querySelector('button').click();document.body.style.background='rgb(0,0,255)';true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("program-8", field: "count") == 1 }
    fixture.reveal(block: "program-7", through: "program-8")
    try await wait(message: { fixture.diagnostics }) { fixture.web(block: "program-7") != nil }
    XCTAssertTrue(fixture.web(block: "program-8") === eighth, "An overlapping visible control retains its context")
    fixture.reveal(block: "program-0")
    try await wait(message: { fixture.diagnostics }) {
      fixture.web(block: "program-0") != nil && eighth.superview == nil
        && fixture.checkpointValues["program-8"]?["count"] == .number(1)
    }
    // Occupy the ordinary slots before the saved eighth program asks again;
    // its waiting picture cannot depend on asynchronous encoding order.
    fixture.reveal(block: "program-0", through: "program-7")
    try await wait(message: { fixture.diagnostics }) {
      (0..<liveCapacity).allSatisfy { fixture.web(block: "program-\($0)") != nil }
        && fixture.resources.pendingWebRequestCount == 0
    }
    fixture.revealAll()
    try await wait(message: { fixture.diagnostics }) {
      (0..<9).filter { fixture.web(block: "program-\($0)") != nil }.count == liveCapacity
        && fixture.resources.pendingWebRequestCount == 9 - liveCapacity
    }
    XCTAssertNil(fixture.web(block: "program-8"))
    let paused = UIGraphicsImageRenderer(bounds: fixture.hosts[0].bounds).image { _ in
      fixture.hosts[0].drawHierarchy(in: fixture.hosts[0].bounds, afterScreenUpdates: true)
    }
    XCTAssertGreaterThan(try bluePixels(paused), 100, "The waiting region retains actual checkpoint pixels, not a ready-control claim")
    let pausedAttachment = XCTAttachment(image: paused)
    pausedAttachment.name = "nine-programs-waiting-retains-current-dom-pixels"; pausedAttachment.lifetime = .keepAlways; add(pausedAttachment)
    fixture.reveal(block: "program-8")
    try await wait(message: { fixture.diagnostics }) { fixture.web(block: "program-8")?.isUserInteractionEnabled == true }
    XCTAssertEqual(fixture.number("program-8", field: "count"), 1)
    XCTAssertTrue(fixture.web(block: "program-8") !== eighth, "Returning to visibility restores the accepted explicit state")
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, fixture.resources.maximumWebSurfaces)
    func images(_ view: UIView) -> [UIImageView] {
      (view as? UIImageView).map { [$0] } ?? view.subviews.flatMap(images)
    }
    let retainedNativeImages = fixture.hosts.flatMap(images)
    XCTAssertFalse(retainedNativeImages.isEmpty)
    let originalImageOwners = Dictionary(uniqueKeysWithValues: retainedNativeImages.map { image in
      var view: UIView? = image
      var ancestry: [String] = []
      while let current = view { ancestry.append(String(describing: type(of: current))); view = current.superview }
      return (ObjectIdentifier(image), ancestry.joined(separator: " → "))
    })
    // The native hierarchy also contains UIKit's cached 20x20 spinner glyphs.
    // Those are not document/source rasters and do not own a raster lease.
    // Identify the actual UIKit owner before detachment, not by image size.
    let indicatorImages = Set(retainedNativeImages.compactMap { image -> ObjectIdentifier? in
      var ancestor = image.superview
      while let view = ancestor {
        if view is UIActivityIndicatorView { return ObjectIdentifier(image) }
        ancestor = view.superview
      }
      return nil
    })
    let documentImages = retainedNativeImages.filter { !indicatorImages.contains(ObjectIdentifier($0)) }
    XCTAssertTrue(documentImages.contains { $0.image != nil },
      "The test must retain actual installed document pictures through native retirement")
    fixture.close()
    try await wait(message: { fixture.diagnostics }) {
      fixture.resources.activeWebSurfaceCount == 0 && fixture.resources.rasterAdmission.pinnedBytes == 0
    }
    let remaining = documentImages.filter { $0.image != nil }.map {
      "\(type(of: $0)) frame=\($0.frame) pixels=\(String(describing: $0.image?.size)) parent=\(String(describing: $0.superview)) original=\(originalImageOwners[ObjectIdentifier($0)] ?? "unknown")"
    }
    XCTAssertTrue(remaining.isEmpty,
      "Departed hosts and image views may outlive the document; native retirement must still release their pixels: \(remaining)")
  }

  private func wait(message: () -> String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "The exact physical presentation did not become ready: \(message())", file: file, line: line)
    if !condition() { throw DocumentSessionError.invalidLayout }
  }

  private func bluePixels(_ image: UIImage) throws -> Int {
    let image = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    }
    return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 40 && bytes[$0 + 1] < 40 && bytes[$0 + 2] > 200 }.count
  }
}

@MainActor
final class ProgramFixture {
  private(set) var document: DocumentDocument
  let resources: SceneRenderResources
  let activity = PageTurnActivity()
  let hosts = [DocumentWebHost(), DocumentWebHost()]
  private let coordinators = [DocumentPhysicalPageCoordinator(), DocumentPhysicalPageCoordinator()]
  private let actor = UUID()
  let window: UIWindow
  private var state: DocumentStateJournal
  private let measurements: DocumentPresentationRecorder?
  private let programStore: NotebookStore
  private let ownedStoreDirectory: URL?
  private var linkNavigation: (DocumentLinkDestination) -> Void = { _ in }
  private var selected = 0
  private var interactive: Bool
  private var visible = true
  private var retiredPresentations: Set<Int> = []
  private var thumbnailPresentations: Set<Int> = []
  private var pageIndices = [0, 1]
  var ready: [Int: Bool] = [:]
  private var frameReadiness: [Int: PageTurnReadiness] = [:]
  var checkpoints: Set<String> = []
  var checkpointValues: [String: JSONValue] = [:]
  var onCheckpoint: (String) async -> Void = { _ in }
  var acceptsCheckpoints = true
  var preparationErrors: [String] = []
  var diagnostics: String {
    let programs = hosts.flatMap(descendants).compactMap { web -> String? in
      guard let runtime = web.navigationDelegate as? DocumentBlockRuntime else { return nil }
      return "\(runtime.program.id):ready=\(runtime.ready),input=\(web.isUserInteractionEnabled),bounds=\(web.bounds),failure=\(String(describing: runtime.failure))"
    }
    return "ready=\(ready) errors=\(preparationErrors) web=\(resources.activeWebSurfaceCount) queued=\(resources.pendingWebRequestCount) held=\(resources.rasterAdmission.heldBytes) state=\(state.records.map { ($0.id, $0.value) }) programs=\(programs) regions=\(DocumentRenderRegistry.shared.regions(document: document).map { ($0.id, $0.pageIndex, $0.frame, $0.sourceOffset) })"
  }
  var currentToken: String { DocumentSnapshotCache.token(document: document, state: state, pageIndex: pageIndices[selected]) }
  var isPresented: Bool { presents(.page) }
  var retainedPaper: DocumentPaperRaster? {
    func paper(_ view: UIView) -> DocumentPaperRaster? {
      if let value = view as? DocumentPaperView { return value.raster }
      for child in view.subviews {
        if let found = paper(child) { return found }
      }
      return nil
    }
    return paper(hosts[selected])
  }
  var installedPaper: DocumentPaperRaster? {
    DocumentRenderRegistry.shared.installedPaper(document:document,state:state,pageIndex:pageIndices[selected])
  }
  func presents(_ scope: DocumentPresentationScope) -> Bool {
    DocumentRenderRegistry.shared.hasLiveSurface(document: document, state: state, pageIndex: pageIndices[selected], scope: scope)
  }
  func token(page: Int) -> String { DocumentSnapshotCache.token(document: document, state: state, pageIndex: page) }
  func replaceState(blockID: String, value: JSONValue) {
    XCTAssertTrue(state.commit(instanceID: blockID, value: value, actor: actor)); refresh()
  }

  init(document: DocumentDocument, resources: SceneRenderResources = SceneRenderResources(),
    measurements: DocumentPresentationRecorder? = nil, interactive: Bool = true, showsNeighbour: Bool = true,
    programStore: NotebookStore? = nil) throws {
    self.document = document; self.resources = resources; self.measurements = measurements
    if let programStore { self.programStore = programStore; ownedStoreDirectory = nil }
    else {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      ownedStoreDirectory = root; self.programStore = NotebookStore(root: root)
      try self.programStore.prepare()
    }
    self.interactive = interactive
    if !showsNeighbour { retiredPresentations.insert(1) }
    state = .init(id: document.id, actor: UUID())
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    window = UIWindow(windowScene: scene)
    let container = UIViewController(); window.rootViewController = container
    let geometry = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: 0)
    for (index, host) in hosts.enumerated() {
      host.frame = .init(x: CGFloat(index) * 360, y: 0, width: 340, height: 340 * geometry.height / geometry.width)
      container.view.addSubview(host)
    }
    window.makeKeyAndVisible(); refresh()
  }

  func replaceLinkNavigation(_ callback: @escaping (DocumentLinkDestination) -> Void) {
    linkNavigation = callback; refresh()
  }
  func replaceSource(fileID: String, source: String) {
    XCTAssertTrue(document.replaceFileSource(id: fileID, source: source, actor: actor))
    refresh()
  }
  func turnFrame(in index: Int, priority: SceneAllocationPriority = .passive) async throws -> PageTurnFrame {
    try await XCTUnwrap(frameReadiness[index]).acquireFrame(priority: priority)
  }
  func canonicalPaper(in index: Int) -> Bool {
    guard let web = paper(in: index), let coordinator = web.navigationDelegate as? DocumentWebCoordinator else { return false }
    return coordinator.hasCanonicalPixels && coordinator.payload?.pageIndex == pageIndices[index]
      && coordinator.payload?.renderToken == DocumentSnapshotCache.paperToken(sourceRevision: document.contentStamp.revision, pageIndex: pageIndices[index])
  }
  func select(_ index: Int) { selected = index; refresh() }
  func setVisible(_ value: Bool) { visible = value; refresh() }
  func setInteractive(_ value: Bool) { interactive = value; refresh() }
  func setThumbnail(_ index: Int) { thumbnailPresentations.insert(index); refresh() }
  func retirePresentation(_ index: Int) {
    retiredPresentations.insert(index); coordinators[index].invalidate(); frameReadiness[index] = nil
  }
  func restorePresentation(_ index: Int) { retiredPresentations.remove(index); refresh() }
  func showPages(current: Int, neighbour: Int) {
    pageIndices = [current, neighbour]; selected = 0; ready = [:]; refresh()
  }
  private func refresh() {
    for (index, coordinator) in coordinators.enumerated() {
      guard !retiredPresentations.contains(index) else { continue }
      let readiness = PageTurnReadiness(activity: activity, pageIndex: pageIndices[index]) { [weak self] in self?.ready[index] = $0 }
      frameReadiness[index] = readiness
      coordinator.update(.init(document: document, state: state, pageIndex: pageIndices[index], isCurrent: selected == index && !thumbnailPresentations.contains(index),
        isVisible: visible, isInteractive: visible && selected == index && interactive && !thumbnailPresentations.contains(index), pageTurnActive: false,
        onRenderReady: readiness,
        onPageLayout: { _ in },
        onStateChange: { [weak self] program, value in
          guard let self else { return nil }
          _ = state.commit(instanceID: program.id, value: value, actor: actor)
          let accepted = state.records.first { $0.id == program.id }?.valueVersion
          refresh(); return accepted
        },    onLinkActivation: { [weak self] in self?.linkNavigation($0.destination) },
        snapshotPixelWidth: thumbnailPresentations.contains(index) ? 256 : nil, onPreparationFailure: { [weak self] error in
          self?.preparationErrors.append("page \(index): \(error)")
        },
        onStateCheckpoint: { [weak self] block, value, program, stateVersion in
          guard let self else { return nil }
          await onCheckpoint(block)
          guard acceptsCheckpoints else { throw SceneRenderError.snapshotPending("test_writer_unavailable") }
          guard (try? DocumentProgramSource(document: document, instanceID: block, path: program.path).sourceBasis) == program.sourceBasis,
            state.records.first(where: { $0.id == block })?.valueVersion == stateVersion else { return nil }
          _ = state.commit(instanceID: block, value: value, actor: actor)
          checkpoints.insert(block); checkpointValues[block] = value
          let accepted = state.records.first { $0.id == block }?.valueVersion
          refresh(); return accepted
        }, measurements: measurements, programStore: programStore), in: hosts[index], resources: resources)
    }
  }

  func value(_ block: String) -> JSONValue? { state.records.first { $0.id == block }?.value }
  func number(_ block: String, field: String) -> Double {
    if case .number(let number) = value(block)?[field] { return number }
    return 0
  }
  func snapshot(in index: Int) -> UIImage? { hosts[index].subviews.compactMap { ($0 as? UIImageView)?.image }.first }
  func windowImage(file: StaticString = #filePath, line: UInt = #line) throws -> UIImage {
    XCTAssertNotNil(window.windowScene, file: file, line: line)
    var drawn = false
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    XCTAssertTrue(drawn, "The attachment must contain the actual native window", file: file, line: line)
    return image
  }
  func web(in index: Int) -> WKWebView? { descendants(hosts[index]).first { $0.accessibilityIdentifier?.hasPrefix("document-program-") == true && $0.isUserInteractionEnabled } }
  func web(block: String) -> WKWebView? {
    descendants(hosts[selected]).first { $0.accessibilityIdentifier == "document-program-" + block && $0.isUserInteractionEnabled }
  }
  func retryProgram(_ block: String) throws {
    func buttons(_ view: UIView) -> [UIButton] { (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    let button = try XCTUnwrap(buttons(hosts[selected]).first { $0.accessibilityIdentifier == "document-program-retry-" + block && !$0.isHidden })
    button.sendActions(for: .touchUpInside)
  }
  func hasProgramAction(_ block: String) -> Bool {
    func buttons(_ view: UIView) -> [UIButton] { (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    return buttons(hosts[selected]).contains { $0.accessibilityIdentifier == "document-program-retry-" + block && !$0.isHidden }
  }
  private var visibleClip: UIView?
  func reveal(block: String, through last: String? = nil) {
    let layout = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document).layout!
    let first = layout.regions.first { $0.id == block }!, end = layout.regions.first { $0.id == (last ?? block) }!
    let geometry = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: 0), scale = 340 / geometry.width
    let clip = visibleClip ?? UIView()
    clip.clipsToBounds = true
    // Reveal the interior, not a floating-point sliver of the adjacent control
    // at a PDF-to-native clipping boundary. This is one physical screen pixel.
    let inset = 1 / window.screen.scale
    clip.frame = .init(x: 0, y: 0, width: 340, height: max(inset, (end.frame.y + end.frame.height - first.frame.y) * scale - 2 * inset))
    if clip.superview == nil { window.rootViewController!.view.addSubview(clip) }
    clip.addSubview(hosts[0]); visibleClip = clip
    hosts[0].frame = .init(x: 0, y: -first.frame.y * scale - inset, width: 340, height: 340 * geometry.height / geometry.width)
    window.layoutIfNeeded(); refresh()
  }
  func revealAll() {
    window.rootViewController!.view.addSubview(hosts[0]); visibleClip?.removeFromSuperview(); visibleClip = nil
    hosts[0].frame.origin = .zero; window.layoutIfNeeded(); refresh()
  }
  func paper(in index: Int) -> WKWebView? { descendants(hosts[index]).first { hosts[index].ownsSurface($0) } }
  func assertPaperReceivesNativeHit(_ web: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
    let point = try await web.evaluateJavaScript("(()=>{const r=document.querySelector('a').getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2]})()") as? [Double]
    let location = try XCTUnwrap(point, file: file, line: line)
    XCTAssertEqual(location.count, 2, file: file, line: line)
    window.layoutIfNeeded()
    let hit = window.hitTest(web.convert(.init(x: location[0], y: location[1]), to: window), with: nil)
    XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true,
      "The actual native route at the visible link must reach this WebKit subtree, got \(String(describing: hit))", file: file, line: line)
  }
  func assertPaperRejectsNativeHit(_ web: WKWebView, file: StaticString = #filePath, line: UInt = #line) async throws {
    let point = try await web.evaluateJavaScript("(()=>{const r=document.querySelector('a').getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2]})()") as? [Double]
    let location = try XCTUnwrap(point, file: file, line: line)
    let hit = window.hitTest(web.convert(.init(x: location[0], y: location[1]), to: window), with: nil)
    XCTAssertFalse(hit === web || hit?.isDescendant(of: web) == true,
      "Disabling new input must close the real native hit-test route", file: file, line: line)
  }
  private func descendants(_ view: UIView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(descendants)
  }
  func message(_ name: String, in web: WKWebView) async throws {
    _ = try await web.callAsyncJavaScript("window.postMessage(name,'*');return true;",
      arguments: ["name": name], in: nil, contentWorld: .page)
  }
  func captureCurrent(file: StaticString = #filePath, line: UInt = #line) async throws -> RasterLease {
    let page = pageIndices[selected]
    let token = DocumentSnapshotCache.token(document: document, state: state, pageIndex: page)
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if let raster = try await DocumentPagePresentationOwner.captureCurrent(documentID: document.id, pageIndex: page,
        token: token, resources: resources) { return raster }
      try await Task.sleep(for: .milliseconds(10))
    }
    let geometry = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: 0)
    let host = hosts[selected]
    let layout = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document).layout
    let placements: [DocumentProgramPlacement] = (layout?.regions(on: page).compactMap { region in
      guard let web = descendants(host).first(where: { $0.accessibilityIdentifier == "document-program-" + region.id }) else { return nil }
      return DocumentProgramPlacement(blockID: region.id, webView: web,
        rect: .init(x: region.frame.x, y: region.frame.y, width: region.frame.width, height: region.frame.height),
        sourceOffset: region.sourceOffset, fullSize: web.bounds.size)
    }) ?? []
    let present = host.programOverlay.presentationFailure(placements, paperSize: .init(width: geometry.width, height: geometry.height))
    XCTFail("Forced current capture unavailable: \(diagnostics), overlay=\(String(describing: present)), snapshot=\(host.hasSnapshot), window=\(host.window != nil)", file: file, line: line)
    throw SceneRenderError.snapshotPending("test_current_document_capture")
  }
  deinit { if let ownedStoreDirectory { try? FileManager.default.removeItem(at: ownedStoreDirectory) } }
  func close() {
    retiredPresentations = Set(coordinators.indices)
    coordinators.forEach { $0.invalidate() }; frameReadiness.removeAll(); window.isHidden = true; window.rootViewController = nil
  }
}

@MainActor
private final class WeakDocumentPaper {
  weak var value: WKWebView?
  init(_ value: WKWebView?) { self.value = value }
}
