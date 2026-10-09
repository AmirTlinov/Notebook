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
  func testAuthorWorldCannotForgeExternalProgramLinkAuthority() async throws {
    let document = DocumentTestFiles.document(contents: [
      .program(id: "links", html: "<a id='outside' href='https://example.com/original'>Outside</a> <a id='inside' href='#target'>Inside</a>", height: 90),
      .tex(id: "target", source: "\\section{Target}\\hypertarget{target}{}")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.canonicalPaper(in: 0) && fixture.web(block: "links") != nil
    }
    let web = try XCTUnwrap(fixture.web(block: "links"))
    let runtime = try XCTUnwrap(web.navigationDelegate as? DocumentBlockRuntime)
    let initialURL = web.url
    let initialFragment = try await web.evaluateJavaScript("location.hash") as? String
    XCTAssertNotNil(runtime.onLinkAdmission(false), "Forgery must reach a genuinely admitted installation")
    let probe = try await web.callAsyncJavaScript("""
      const external=document.getElementById('outside');
      let targetDefault=null,windowDefault=null;
      external.addEventListener('click',event=>{targetDefault=event.defaultPrevented;external.href='https://example.com/swapped';});
      addEventListener('click',event=>{windowDefault=event.defaultPrevented;});
      const forge=href=>webkit.messageHandlers.documentProgram.postMessage({runtimeID,kind:'link',href,userActivated:true,sequence:1});
      forge(external.getAttribute('href'));
      external.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,pointerId:1,isPrimary:true,button:0}));
      external.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,pointerId:1,isPrimary:true,button:0}));
      external.dispatchEvent(new KeyboardEvent('keydown',{bubbles:true,key:'Enter'}));
      external.click();
      const frame=document.createElement('iframe');document.body.appendChild(frame);
      const frameBridge=!!frame.contentWindow?.webkit?.messageHandlers.documentProgram;
      if(frameBridge)frame.contentWindow.webkit.messageHandlers.documentProgram.postMessage({runtimeID,kind:'link',href:'#target',userActivated:true});
      const isolated=!!webkit.messageHandlers.documentLinkActivation;
      const installationVisible=typeof window.notebookInstallLinkOrigin!=='undefined';
      await new Promise(resolve=>setTimeout(resolve,30));
      forge('https://example.com/replayed');
      return {isolated,installationVisible,frameBridge,targetDefault,windowDefault};
      """, arguments: ["runtimeID": runtime.id.uuidString], in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(probe?["isolated"] as? Bool, false, "The author world cannot enter the trusted handler")
    XCTAssertEqual(probe?["installationVisible"] as? Bool, false, "Native correlation stays outside the author world")
    XCTAssertEqual(probe?["frameBridge"] as? Bool, true, "The negative frame probe must actually post from a child frame")
    XCTAssertEqual(probe?["targetDefault"] as? Bool, false, "Capture must not suppress an author's guarded click handler")
    XCTAssertEqual(probe?["windowDefault"] as? Bool, false, "An author's window handler must keep the event's default state too")
    _ = try await web.evaluateJavaScript("document.getElementById('inside').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.linkActivations.count == 1 }
    guard case .page = fixture.linkActivations[0].destination else { return XCTFail("Only the current internal scripted route may be delivered") }
    XCTAssertFalse(fixture.linkActivations[0].consumeExternalAuthority())
    let resultingFragment = try await web.evaluateJavaScript("location.hash") as? String
    XCTAssertEqual(resultingFragment, initialFragment, "The native navigation delegate must refuse the program's own fragment navigation")
    XCTAssertEqual(web.url, initialURL)

    // Exercise the real native contact callback against the loaded subtree;
    // this is an admission oracle, not a synthesized UITouch or human proof.
    fixture.hosts[0].programOverlay.onContactChange("links", true)
    fixture.setInteractive(false)
    XCTAssertNotNil(runtime.onLinkAdmission(true))
    XCTAssertNil(runtime.onLinkAdmission(false))
    _ = try await web.evaluateJavaScript("document.getElementById('inside').click();true")
    fixture.hosts[0].programOverlay.onContactChange("other", true)
    XCTAssertNil(runtime.onLinkAdmission(true), "A different native contact cannot admit this program")
    fixture.hosts[0].programOverlay.onContactChange("other", false)
    fixture.hosts[0].programOverlay.onContactChange("links", false)
    fixture.setInteractive(true)
    _ = try await web.evaluateJavaScript("document.getElementById('inside').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.linkActivations.count == 2 }
    XCTAssertTrue(fixture.linkActivations.allSatisfy { if case .page = $0.destination { true } else { false } })
  }

  func testIsolatedProgramReceiptSurvivesDelayedIPCAndDrainsStateBeforeItsOneShotDestination() async throws {
    let document = DocumentTestFiles.document(contents: [
      .program(id: "links", html: "<a id='outside' href='https://example.com/original'>Outside</a> <a id='inside' href='#target'>Inside</a>",
        initialState: .object(["count": .number(0)]), height: 90),
      .tex(id: "target", source: "\\section{Target}\\hypertarget{target}{}")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(block: "links") != nil }
    let web = try XCTUnwrap(fixture.web(block: "links"))
    let installation = try await isolatedLinkInstallation(in: web)
    let runtime = try XCTUnwrap(web.navigationDelegate as? DocumentBlockRuntime)
    let admitted = try XCTUnwrap(runtime.onLinkAdmission(false))
    var observedAcceptance = false
    fixture.onStateAccepted = { block in
      guard block == "links" else { return }
      observedAcceptance = true
      XCTAssertTrue(admitted.isCurrent(), "The accepted writer cannot retire its installed origin while its ACK closes new input")
      let token = try? await web.callAsyncJavaScript("return window.notebookInstallLinkOrigin();",
        arguments: [:], in: nil, contentWorld: .world(name: "Notebook.DocumentLinkActivation"))
      XCTAssertEqual(token as? String, installation, "The writer's publication keeps the same physical installation")
    }
    fixture.hosts[0].programOverlay.onContactChange("links", true)
    fixture.setInteractive(false)
    fixture.hosts[0].programOverlay.onContactChange("links", false)
    // Native test code enters the isolated world to exercise delayed IPC and
    // its transport lifetime. Author JS cannot do this; actual trusted event
    // capture still requires the separate finger/key/VoiceOver scenario.
    try await postIsolatedLinkMessages([
      ["kind": "begin", "sequence": "1", "contact": "accessibility", "installation": installation, "href": "https://example.com/closed"],
      ["kind": "activate", "sequence": "1"],
      ["kind": "begin", "sequence": "2", "contact": "pointer", "installation": installation, "href": "https://example.com/original"]], in: web)
    let committed = try await web.evaluateJavaScript("""
      const original=documentProgram;
      window.documentProgram=Object.create(original,{readSnapshot:{value:argument=>{
        if(window.allowPull)return original.readSnapshot(argument);
        window.pullStarted=true;
        return new Promise(resolve=>{window.releasePull=()=>{window.allowPull=true;resolve(original.readSnapshot(argument))}});
      }}});
      document.getElementById('outside').href='https://example.com/swapped';
      notebook.commit({count:1});
      """) as? Bool
    XCTAssertEqual(committed, true)
    try await postIsolatedLinkMessages([["kind": "activate", "sequence": "2"]], in: web)
    let pullDeadline = ContinuousClock.now + .seconds(5)
    var pullStarted = false
    while .now < pullDeadline {
      pullStarted = try await web.evaluateJavaScript("window.pullStarted===true") as? Bool == true
      if pullStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(pullStarted, fixture.diagnostics)
    guard pullStarted else { throw DocumentSessionError.invalidLayout }
    XCTAssertTrue(fixture.linkActivations.isEmpty, "The same accepted state writer must finish before terminal delivery")
    _ = try await web.evaluateJavaScript("window.releasePull();true")
    try await wait(message: { fixture.diagnostics }) { fixture.linkActivations.count == 1 && fixture.number("links", field: "count") == 1 }
    XCTAssertTrue(observedAcceptance)
    let activation = fixture.linkActivations[0]
    XCTAssertEqual(activation.destination, .external(URL(string: "https://example.com/original")!))
    XCTAssertTrue(activation.consumeExternalAuthority())
    XCTAssertFalse(activation.consumeExternalAuthority())
    let stableInstallation = try await isolatedLinkInstallation(in: web)
    XCTAssertEqual(stableInstallation, installation, "State acceptance and input-policy changes keep the exact installed origin")
    try await postIsolatedLinkMessages([
      ["kind": "activate", "sequence": "2"],
      ["kind": "begin", "sequence": "3", "contact": "pointer", "installation": installation, "href": "https://example.com/replayed"],
      ["kind": "activate", "sequence": "3"]], in: web)
    fixture.setInteractive(true)
    fixture.hosts[0].programOverlay.onContactChange("links", true)
    try await postIsolatedLinkMessages([["kind": "begin", "sequence": "4", "contact": "pointer", "installation": installation, "href": "https://example.com/retired"]], in: web)
    fixture.hosts[0].programOverlay.onContactChange("links", false)
    fixture.replaceSource(fileID: "links-html", source: "<a id='inside' href='#target'>Replacement source</a>")
    _ = try await web.callAsyncJavaScript("""
      try{webkit.messageHandlers.documentLinkActivation.postMessage({kind:'activate',sequence:'4'});}catch{}
      return true;
      """, arguments: [:], in: nil, contentWorld: .world(name: "Notebook.DocumentLinkActivation"))
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.web(block: "links") != nil && fixture.web(block: "links") !== web
    }
    let replacement = try XCTUnwrap(fixture.web(block: "links"))
    _ = try await replacement.evaluateJavaScript("document.getElementById('inside').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.linkActivations.count == 2 }
    guard case .page = fixture.linkActivations[1].destination else { return XCTFail("A retired executor must not publish another external destination") }
  }

  func testIsolatedInstallationCorrelationRejectsOldPaperAndRetiredNativeEntry() async throws {
    let document = try DocumentTestFiles.document(contents: [
      .program(id: "links", html: "<a href='https://example.com/current'>Outside</a>", height: 90),
      .tex(id: "target", source: "An original paper source around the unchanged program.")]).materializingCausalVersions()
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    let lifetime = owner.retainOpenDocument()
    defer { fixture.close(); lifetime.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(block: "links") != nil }
    let web = try XCTUnwrap(fixture.web(block: "links")), first = try await isolatedLinkInstallation(in: web)
    let basis = try XCTUnwrap((web.navigationDelegate as? DocumentBlockRuntime)?.sourceBasis)
    fixture.replaceSource(fileID: "target", source: "A new paper source keeps the same accepted program files and viewport.")
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) && fixture.web(block: "links") === web }
    XCTAssertEqual((web.navigationDelegate as? DocumentBlockRuntime)?.sourceBasis, basis)
    let second = try await isolatedLinkInstallation(in: web, after: first)
    try await postIsolatedLinkMessages([
      ["kind": "begin", "sequence": "1", "contact": "key", "installation": second,
        "capturedAt": Date().timeIntervalSince1970 * 1_000 - 11_000, "href": "https://example.com/expired"],
      ["kind": "activate", "sequence": "1"],
      ["kind": "begin", "sequence": "2", "contact": "key", "installation": first, "href": "https://example.com/old-paper"],
      ["kind": "activate", "sequence": "2"],
      ["kind": "begin", "sequence": "3", "contact": "accessibility", "installation": second, "href": "https://example.com/current"],
      ["kind": "activate", "sequence": "3"]], in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.linkActivations.count == 1 }
    XCTAssertEqual(fixture.linkActivations[0].destination, .external(URL(string: "https://example.com/current")!))
    XCTAssertTrue(fixture.linkActivations[0].origin.source.matches(fixture.document))
    XCTAssertTrue(fixture.linkActivations[0].consumeExternalAuthority())

    fixture.hosts[0].programOverlay.onContactChange("links", true)
    fixture.hosts[0].programOverlay.onContactChange("links", false)
    try await postIsolatedLinkMessages([
      ["kind": "begin", "sequence": "4", "contact": "pointer", "installation": first, "href": "https://example.com/old-pointer"],
      ["kind": "activate", "sequence": "4"],
      ["kind": "begin", "sequence": "5", "contact": "pointer", "installation": second, "href": "https://example.com/current-pointer"],
      ["kind": "activate", "sequence": "5"]], in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.linkActivations.count == 2 }
    XCTAssertEqual(fixture.linkActivations[1].destination, .external(URL(string: "https://example.com/current-pointer")!),
      "An old installation message cannot consume a newer native contact receipt")
    let retiredGrant = fixture.linkActivations[1]
    let retiredAdmission = try XCTUnwrap((web.navigationDelegate as? DocumentBlockRuntime)?.onLinkAdmission(false))
    XCTAssertTrue(retiredAdmission.isCurrent())

    // The model's real open-document lifetime keeps the existing executor;
    // ending its native Entry still irreversibly revokes the previous token.
    lifetime.parkForReturn(); fixture.retirePresentation(0)
    await owner.observePendingPresentationWork()
    lifetime.resume(); fixture.restorePresentation(0)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.web(block: "links") === web }
    let returned = try await isolatedLinkInstallation(in: web, after: second)
    XCTAssertFalse(retiredAdmission.isCurrent(), "A retired native Entry cannot revive through its reused coordinator ID")
    XCTAssertFalse(retiredGrant.consumeExternalAuthority(), "A delivered grant remains revoked after the same heap and paper return")
    try await postIsolatedLinkMessages([
      ["kind": "begin", "sequence": "6", "contact": "key", "installation": second, "href": "https://example.com/retired-entry"],
      ["kind": "activate", "sequence": "6"],
      ["kind": "begin", "sequence": "7", "contact": "key", "installation": returned, "href": "https://example.com/returned"],
      ["kind": "activate", "sequence": "7"]], in: web)
    try await wait(message: { fixture.diagnostics }) { fixture.linkActivations.count == 3 }
    XCTAssertEqual(fixture.linkActivations[2].destination, .external(URL(string: "https://example.com/returned")!))
  }

  private func isolatedLinkInstallation(in web: WKWebView, after previous: String? = nil) async throws -> String {
    let deadline = ContinuousClock.now + .seconds(5)
    while .now < deadline {
      let raw = try await web.callAsyncJavaScript("return window.notebookInstallLinkOrigin();",
        arguments: [:], in: nil, contentWorld: .world(name: "Notebook.DocumentLinkActivation"))
      if let token = raw as? String, token != previous { return token }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The actual installed program did not publish its native origin correlation")
    throw DocumentSessionError.invalidLayout
  }

  private func postIsolatedLinkMessages(_ messages: [[String: Any]], in web: WKWebView) async throws {
    _ = try await web.callAsyncJavaScript("""
      for(const source of messages){
        const message={...source};
        if(message.kind==='begin'&&message.capturedAt===undefined)message.capturedAt=Date.now();
        webkit.messageHandlers.documentLinkActivation.postMessage(message);
      }
      return true;
      """, arguments: ["messages": messages], in: nil, contentWorld: .world(name: "Notebook.DocumentLinkActivation"))
  }

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
      let layout = try DocumentLayoutFixture.make(pages: [paper], regions: [
        .init(kind: .program, id: "geometry", pageIndex: 0,
          frame: .init(x: 0, y: 0, width: width, height: height), sourceOffset: 0)
      ])
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
      let layout = try DocumentLayoutFixture.make(pages: [paper], regions: [
        .init(kind: .program, id: "failed", pageIndex: 0,
          frame: .init(x: 0, y: 0, width: 360, height: height), sourceOffset: 0)
      ])
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

  func testHistoryAdmissionStopsForegroundResumeBeforeTheNextDocumentOwner() async throws {
    let resources = SceneRenderResources(), readiness = NotebookHistoryReadiness()
    func document() -> DocumentDocument {
      DocumentTestFiles.document(actor: UUID(), contents: [.program(id: "program", html: "<output>Model</output>",
        javaScript: """
          window.resumes=0;window.resumePending=false;window.holdResume=true;window.nonce=crypto.randomUUID();
          notebook.lifecycle({checkpoint(){return {phase:.5}},resume({signal}){
            resumes++;if(!holdResume)return;
            resumePending=true;
            return new Promise(resolve=>{window.releaseResume=()=>{resumePending=false;resolve()};
              signal.addEventListener('abort',window.releaseResume,{once:true});});
          },dispose(){window.releaseResume?.()}});notebook.ready(Promise.resolve());
        """, height: 100)])
    }
    let first = try ProgramFixture(document: document(), resources: resources, showsNeighbour: false)
    defer { first.close() }
    try await wait(message: { first.diagnostics }) { first.isPresented && first.web(block: "program") != nil }
    let firstWeb = try XCTUnwrap(first.web(block: "program"))
    let firstPause = try await DocumentPagePresentationOwner.pauseForAttention(documentID: first.document.id,
      blockID: "program", resources: resources)
    defer { firstPause.release() }
    let second = try ProgramFixture(document: document(), resources: resources, showsNeighbour: false)
    defer { second.close() }
    try await wait(message: { second.diagnostics }) { second.isPresented && second.web(block: "program") != nil }
    let webs = [firstWeb, try XCTUnwrap(second.web(block: "program"))]
    let secondPause = try await DocumentPagePresentationOwner.pauseForAttention(documentID: second.document.id,
      blockID: "program", resources: resources)
    defer { secondPause.release() }
    var nonces: [String?] = []
    for web in webs {
      let nonce = try await web.evaluateJavaScript("window.nonce") as? String
      XCTAssertNotNil(nonce); nonces.append(nonce)
    }
    let saved = await DocumentPagePresentationOwner.checkpointPrograms(resources: resources, resume: false)
    // The direct fixtures use the real native attention boundary, while the
    // workspace's history boundary prevents release from becoming a resume.
    firstPause.release(); secondPause.release()
    XCTAssertTrue(saved); XCTAssertTrue(webs.allSatisfy { !$0.isUserInteractionEnabled })
    let stillSaved = await DocumentPagePresentationOwner.checkpointPrograms(resources: resources, resume: false)
    XCTAssertTrue(stillSaved)

    let foreground = Task { @MainActor in
      await DocumentPagePresentationOwner.resumePrograms(resources: resources, continuing: { readiness.permitsAuthorship })
    }
    defer { foreground.cancel() }
    // The real owner registry chooses the first document; dictionary order is
    // immaterial. Its authored lifecycle remains suspended at this await.
    var heldIndex: Int?
    let deadline = ContinuousClock.now + .seconds(3)
    while heldIndex == nil, ContinuousClock.now < deadline {
      for (index, web) in webs.enumerated() {
        if try await web.evaluateJavaScript("window.resumePending") as? Bool == true { heldIndex = index; break }
      }
      if heldIndex == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let held = try XCTUnwrap(heldIndex, "The existing foreground owner must enter the held JS lifecycle")
    let next = 1 - held
    let request = NotebookHistoryReadiness.Request(id: UUID(), workspaceID: UUID(), devices: [UUID(), UUID()], acceptedGeneration: 0)
    try readiness.begin(request)
    _ = try await webs[held].evaluateJavaScript("window.releaseResume();true")
    await foreground.value
    let heldResumes = try await webs[held].evaluateJavaScript("window.resumes") as? Int
    let nextResumes = try await webs[next].evaluateJavaScript("window.resumes") as? Int
    XCTAssertEqual(heldResumes, 1); XCTAssertEqual(nextResumes, 0)
    XCTAssertFalse(webs[next].isUserInteractionEnabled)
    XCTAssertFalse(readiness.permitsAuthorship)

    try readiness.finish(request, releaseWriter: { _ in XCTFail("The draining request has no sealed writer") })
    for web in webs { _ = try await web.evaluateJavaScript("window.holdResume=false;true") }
    await DocumentPagePresentationOwner.resumePrograms(resources: resources, continuing: { readiness.permitsAuthorship })
    for (index, web) in webs.enumerated() {
      let resumes = try await web.evaluateJavaScript("window.resumes") as? Int
      let nonce = try await web.evaluateJavaScript("window.nonce") as? String
      XCTAssertEqual(resumes, 1); XCTAssertEqual(nonce, nonces[index])
      XCTAssertTrue(web.isUserInteractionEnabled)
    }
    XCTAssertTrue(first.web(block: "program") === firstWeb)
    XCTAssertTrue(second.web(block: "program") === webs[1])
    XCTAssertTrue(first.preparationErrors.isEmpty && second.preparationErrors.isEmpty)
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
    XCTAssertEqual(original.page.width, 720, accuracy: 0.001)
    XCTAssertEqual(original.page.height, 400, accuracy: 0.001)
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
    try await wait(message: { fixture.diagnostics }) {
      fixture.ready[0] == true && fixture.ready[1] == true && fixture.web(block: "counter") != nil
        && fixture.canonicalPaper(in: 0)
    }
    let paper = try XCTUnwrap(fixture.paper(in: 0)), program = try XCTUnwrap(fixture.web(block: "counter"))
    let old = try XCTUnwrap(paper.raster)
    let neighbour = try XCTUnwrap(fixture.hosts[1].snapshotEntryID)
    let token = fixture.token(page: 1)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    _ = try await program.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("counter", field: "count") == 1 && fixture.isPresented }
    await owner.observePendingPresentationWork()
    XCTAssertEqual(fixture.hosts[1].snapshotEntryID, neighbour)
    XCTAssertEqual(fixture.token(page: 1), token)
    XCTAssertTrue(fixture.presents(.paper))
    fixture.replaceState(blockID: "counter", value: .object(["count": .number(9)]))
    XCTAssertFalse(fixture.isPresented, "Admission to a block's state application is not its painted frame")
    try await wait(message: { fixture.diagnostics }) { fixture.isPresented }
    let shown = try await program.evaluateJavaScript("document.querySelector('output').textContent") as? String
    XCTAssertEqual(shown, "9")
    fixture.replaceState(blockID: "far", value: .object(["checked": .bool(true)]))
    await owner.observePendingPresentationWork()
    XCTAssertTrue(paper.raster === old)
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
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 1, "A failed program cannot retain the slot needed by its neighbour")
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
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "\\hyperlink{far}{Far}\n\n" + String(repeating: "Physical paper preserves native links.\n\n", count: 160)
      + "\\section{Far}\\hypertarget{far}{}")])
    let measurements = DocumentPresentationRecorder(enabled: true)
    let fixture = try ProgramFixture(document: document, measurements: measurements, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) && fixture.ready[0] == true }
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let target = try XCTUnwrap(source.layout).pageCount - 1
    let count = source.measurementCount
    let request = measurements.request(documentID: document.id, pageIndex: target, cause: .page)
    fixture.activity.prepare(target, presentation: .live)
    let demand = try XCTUnwrap(fixture.activity.preparationDemand)
    fixture.showPages(current: 0, neighbour: target); fixture.restorePresentation(1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    let incoming = try XCTUnwrap(fixture.paper(in: 1)), raster = try XCTUnwrap(incoming.raster)
    XCTAssertFalse(fixture.hosts[1].hasSnapshot)
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedCount, 0)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
    let attempt = try XCTUnwrap(measurements.records.first { $0.id == request }?.landingAttempts.last)
    XCTAssertEqual(attempt.stage, .completed); XCTAssertNil(attempt.captureStartedAt)
    fixture.activity.update(true); fixture.activity.didInstall(demand)
    fixture.activity.prepare(nil); fixture.activity.update(false); fixture.retirePresentation(0)
    await DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources).observePendingPresentationWork()
    XCTAssertTrue(fixture.paper(in: 1) === incoming)
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) { fixture.presents(.paper) && fixture.hosts[1].isUserInteractionEnabled }
    XCTAssertTrue(fixture.paper(in: 1) === incoming && incoming.raster === raster)
    XCTAssertEqual(source.measurementCount, count)
    XCTAssertEqual(raster.page.pageIndex, target)
    XCTAssertTrue(fixture.preparationErrors.isEmpty)
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
    let thumbnail = DocumentPageHost(), thumbnailCoordinator = DocumentPhysicalPageCoordinator()
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
      fixture.canonicalPaper(in: 1) && fixture.hosts[1].isUserInteractionEnabled && fixture.hosts[1].hasCanonicalPaper(incoming)
    }
    XCTAssertTrue(thumbnail.hasSnapshot)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testLiveTargetSupersessionKeepsCurrentPaperWithoutWebAdmission() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      String(repeating: "An accepted native target preserves the visible page.\n\n", count: 180))])
    let resources = SceneRenderResources(maximumWebSurfaces: 1, reservedInteractiveSlots: 0)
    let blocker = try await resources.acquireWebSurface(priority: .input)
    defer { blocker.release() }
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let current = try XCTUnwrap(fixture.paper(in: 0))
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources).source(document)
    let target = try XCTUnwrap(source.layout).pageCount - 1
    XCTAssertGreaterThan(target, 2)
    fixture.activity.prepare(target, presentation: .live)
    fixture.showPages(current: 0, neighbour: target); fixture.restorePresentation(1)
    fixture.activity.prepare(target - 1, presentation: .live)
    fixture.showPages(current: 0, neighbour: target - 1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.canonicalPaper(in: 1) }
    XCTAssertEqual(fixture.paper(in: 1)?.raster?.page.pageIndex, target - 1)
    XCTAssertTrue(fixture.paper(in: 0) === current)
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 1, "Only the independent blocker occupies WebKit")
    fixture.close(); blocker.release()
    try await wait(message: { fixture.diagnostics }) { resources.activeWebSurfaceCount == 0 }
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
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let paper = try XCTUnwrap(source.layout).paper(on: 0)
    XCTAssertEqual(paper.widthPoints, 612, accuracy: 0.001)
    XCTAssertEqual(paper.heightPoints, 792, accuracy: 0.001)
    XCTAssertFalse(host.hasCanonicalPaperProjection)
    XCTAssertFalse(fixture.ready[0] == true)
    XCTAssertFalse(fixture.presents(.paper))
    XCTAssertFalse(host.isUserInteractionEnabled)
    XCTAssertNotNil(web.raster, "Native source preparation does not wait for its host rectangle")
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
        && host.isUserInteractionEnabled
    }
    XCTAssertTrue(fixture.paper(in: 0) === web, "Geometry installation preserves the accepted native runtime")
    XCTAssertEqual(web.raster?.sourceKey, source.message.key)
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
    XCTAssertEqual(fixture.paper(in: 0)?.raster?.sourceKey, source.message.key, "Mounting borrows the accepted source")
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
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.ready[1] == true && fixture.canonicalPaper(in: 0) }
    let first = try await fixture.turnFrame(in: 0), neighbour = try await fixture.turnFrame(in: 1)
    let sameFirst = try await fixture.turnFrame(in: 0), sameNeighbour = try await fixture.turnFrame(in: 1)
    XCTAssertTrue(first === sameFirst); XCTAssertTrue(neighbour === sameNeighbour)
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) { fixture.presents(.paper) && !fixture.hosts[1].hasSnapshot }
    let landed = try await fixture.turnFrame(in: 1)
    XCTAssertTrue(landed === neighbour, "Unchanged native landing keeps resident GPU material")
    fixture.setInteractive(false); fixture.setInteractive(true)
    let policy = try await fixture.turnFrame(in: 1); XCTAssertTrue(policy === landed)
    fixture.replaceSource(fileID: "body", source: original + " A changed printed sentence.")
    do {
      _ = try await fixture.turnFrame(in: 1, priority: .input)
      XCTFail("The preceding source cannot supply the replacement's turn cut")
    } catch { XCTAssertEqual(error as? SceneRenderError, .snapshotPending("document_installed_slots")) }
    try await wait(message: { fixture.diagnostics }) { fixture.presents(.paper) && fixture.canonicalPaper(in: 1) }
    let edited = try await fixture.turnFrame(in: 1), sameEdited = try await fixture.turnFrame(in: 1)
    XCTAssertFalse(edited === landed); XCTAssertTrue(edited === sameEdited)
    let current = try XCTUnwrap(fixture.installedPaper)
    let text = PDFDocument(data: current.page.artifact.pdf)?.page(at: current.page.pageIndex)?.string
    XCTAssertTrue(text?.contains("changed printed sentence") == true)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
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
    let host = DocumentPageHost()
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
    XCTAssertTrue(fixture.hosts[0].isUserInteractionEnabled)
    XCTAssertEqual(fixture.ready[0], true)
  }

  func testFallbackPixelsDenyNewNativeHitsUntilCanonicalPaperIsInstalled() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "\\hyperlink{target}{Target}\\section{Target}\\hypertarget{target}{}")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.presents(.paper) }
    let paper = try XCTUnwrap(fixture.paper(in: 0)), host = fixture.hosts[0]
    let raster = try await fixture.captureCurrent(); defer { raster.release() }
    host.installSnapshot(raster); fixture.setInteractive(true)
    XCTAssertTrue(host.hasSnapshot)
    XCTAssertNotNil(paper.raster)
    XCTAssertFalse(fixture.presents(.paper))
    try await fixture.assertPaperRejectsNativeHit(paper)
    XCTAssertFalse(try XCTUnwrap(fixture.link(in: paper)).accessibilityActivate())
    host.removeFallback(); fixture.setInteractive(true)
    try await wait(message: { fixture.diagnostics }) { fixture.presents(.paper) && host.isUserInteractionEnabled }
    XCTAssertTrue(fixture.paper(in: 0) === paper)
    try await fixture.assertPaperReceivesNativeHit(paper)
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
    let renderer = DocumentPaperCoordinator(resources: resources, renderSession: session)
    let targetHost = DocumentPageHost()
    fixture.window.rootViewController?.view.addSubview(targetHost)
    targetHost.frame = .init(x: 720, y: 0, width: 240, height: 340)
    defer { renderer.onPresentationChange = {}; renderer.invalidate(); targetHost.removeFromSuperview() }
    var failures: [String] = [], withdrawals = 0
    let geometry = try XCTUnwrap(source.layout).paper(on: 1).geometry
    let size = CGSize(width: geometry.width, height: geometry.height)
    targetHost.frame.size.height = targetHost.bounds.width * size.height / size.width
    targetHost.setNeedsLayout(); targetHost.layoutIfNeeded()
    renderer.update(document: document, state: .init(id: document.id, actor: UUID()),
      selectedPageIndex: 1, onPageLayout: { _ in },
      onPreparationFailure: { failures.append(String(describing: $0)) }, onLinkActivation: { _ in }, preparationRequestID: UUID())
    renderer.onPresentationChange = { [weak renderer] in
      guard let renderer, withdrawals == 0, renderer.acquisitionError is CancellationError else { return }
      withdrawals += 1
      // Promotion occurs synchronously before the withdrawn native task throws
      // to the sender already waiting on that task, in the same source generation.
      renderer.mount(in: targetHost, physicalSize: size, isInteractive: true, priority: .currentPage)
    }
    renderer.mount(in: targetHost, physicalSize: size, isInteractive: false, priority: .visible, purpose: { .optional })
    try await wait(message: { fixture.diagnostics }) {
      renderer.installedPaper == nil && resources.pendingDerivedRequestCount > 0
        && renderer.pagePreparationTrace?.phasesMS["preparedPageStartAt"] != nil
    }
    let admitted = WeakDocumentPaper(renderer.view)
    let admittedID = ObjectIdentifier(try XCTUnwrap(admitted.value))
    let token = try XCTUnwrap(renderer.payload?.renderToken)
    resources.handleMemoryPressure(.warning)
    held.release()
    try await wait(message: {
      fixture.diagnostics + " targetErrors=\(failures) canonical=\(renderer.hasCanonicalPixels)"
        + " projection=\(targetHost.hasCanonicalPaperProjection) input=\(renderer.nativeInputIsReady(in: targetHost))"
        + " keyWindow=\(targetHost.window?.isKeyWindow == true)"
    }) {
      renderer.hasCanonicalPixels && renderer.nativeInputIsReady(in: targetHost)
    }
    try await renderer.awaitPresentation(token: token)
    XCTAssertEqual(withdrawals, 1)
    XCTAssertTrue(failures.isEmpty, "The retired optional subscriber cannot fail the required remount: \(failures)")
    XCTAssertNil(renderer.acquisitionError)
    XCTAssertEqual(ObjectIdentifier(renderer.view), admittedID)
    XCTAssertTrue(renderer.nativeInputIsReady(in: targetHost))
    XCTAssertTrue(fixture.canonicalPaper(in: 0))
    XCTAssertTrue(session.source(document) === source)
    renderer.invalidate(); targetHost.removeFromSuperview(); fixture.close()
    try await wait(message: { fixture.diagnostics }) { resources.activeWebSurfaceCount == 0 && resources.pendingWebRequestCount == 0 }
  }



  func testCurrentCanonicalPaperAdmitsInputWithoutChangingItsMaterialOrMeasurement() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "\\hyperlink{target}{Target}\\section{Target}\\hypertarget{target}{}")])
    let recorder = DocumentPresentationRecorder(enabled: true)
    _ = recorder.request(documentID: document.id, pageIndex: 0, cause: .open)
    let fixture = try ProgramFixture(document: document, measurements: recorder, interactive: false)
    defer { fixture.close() }
    var navigations = 0; fixture.replaceLinkNavigation { _ in navigations += 1 }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && recorder.records.last?.contentReadyAt != nil }
    let paper = try XCTUnwrap(fixture.paper(in: 0)), raster = try XCTUnwrap(paper.raster)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let count = source.measurementCount
    XCTAssertFalse(try XCTUnwrap(fixture.link(in: paper)).accessibilityActivate())
    XCTAssertNil(recorder.records.last?.installedAt)
    fixture.setInteractive(true)
    XCTAssertNotNil(recorder.records.last?.installedAt)
    try await fixture.assertPaperReceivesNativeHit(paper)
    try fixture.activateLink(in: paper); XCTAssertEqual(navigations, 1)
    fixture.setInteractive(false)
    try await fixture.assertPaperRejectsNativeHit(paper)
    XCTAssertFalse(try XCTUnwrap(fixture.link(in: paper)).accessibilityActivate())
    fixture.setInteractive(true); try fixture.activateLink(in: paper)
    XCTAssertEqual(navigations, 2)
    XCTAssertTrue(fixture.paper(in: 0) === paper && paper.raster === raster)
    XCTAssertEqual(source.measurementCount, count)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
  }

  func testInputPolicyChangedDuringSourcePreparationReachesTheSamePaper() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "\\hyperlink{target}{Target}\\section{Target}\\hypertarget{target}{}")])
    let fixture = try ProgramFixture(document: document, interactive: false, showsNeighbour: false)
    defer { fixture.close() }
    fixture.setInteractive(true)
    XCTAssertFalse(fixture.hosts[0].isUserInteractionEnabled)
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) && fixture.hosts[0].isUserInteractionEnabled }
    let paper = try XCTUnwrap(fixture.paper(in: 0))
    try await fixture.assertPaperReceivesNativeHit(paper)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    XCTAssertEqual(source.measurementCount, 1)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
  }

  func testDisablingNewNativeInputRejectsNewActivationDuringAContact() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "\\hyperlink{target}{Target}\\section{Target}\\hypertarget{target}{}")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    var admittedCalls = 0, laterCalls = 0
    fixture.replaceLinkNavigation { _ in admittedCalls += 1 }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) && fixture.hosts[0].isUserInteractionEnabled }
    let paper = try XCTUnwrap(fixture.paper(in: 0))
    fixture.hosts[0].onContactChange(true)
    fixture.setInteractive(false); fixture.replaceLinkNavigation { _ in laterCalls += 1 }
    try await fixture.assertPaperRejectsNativeHit(paper)
    XCTAssertFalse(try XCTUnwrap(fixture.link(in: paper)).accessibilityActivate())
    XCTAssertEqual(admittedCalls, 0); XCTAssertEqual(laterCalls, 0)
    fixture.hosts[0].onContactChange(false); fixture.setInteractive(true)
    try fixture.activateLink(in: paper)
    XCTAssertEqual(laterCalls, 1); XCTAssertEqual(admittedCalls, 0)
    XCTAssertTrue(fixture.paper(in: 0) === paper)
  }

  func testAcceptedProgramStateDoesNotRevokeTheSameSourceInput() async throws {
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
    let oldToken = fixture.currentToken, raster = try XCTUnwrap(paper.raster)
    // A held physical turn keeps the installed native input owner.
    fixture.activity.update(true)
    defer { fixture.activity.update(false) }
    _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait(message: { fixture.diagnostics }) { fixture.number("counter", field: "count") == 1 }
    XCTAssertNotEqual(fixture.currentToken, oldToken)
    XCTAssertTrue(paper.raster === raster)
    XCTAssertTrue(fixture.presents(.paper))
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
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "First page.\\newpage Intermediate page.\\newpage Last page.")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.canonicalPaper(in: 0) }
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let destination = try XCTUnwrap(source.layout).pageCount - 1
    fixture.showPages(current: 0, neighbour: destination)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.hosts[1].hasSnapshot }
    let original = WeakDocumentPaper(fixture.paper(in: 0))
    fixture.retirePresentation(0); fixture.select(1)
    try await wait(message: { fixture.diagnostics }) {
      fixture.canonicalPaper(in: 1) && !fixture.hosts[1].hasSnapshot && fixture.hosts[1].isUserInteractionEnabled
    }
    XCTAssertTrue(fixture.paper(in: 1) === original.value)
    XCTAssertEqual(fixture.paper(in: 1)?.raster?.sourceKey, source.message.key)
    XCTAssertEqual(source.measurementCount, 1)
    fixture.restorePresentation(0); fixture.select(0)
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) && fixture.hosts[0].isUserInteractionEnabled }
    XCTAssertTrue(fixture.paper(in: 0) === original.value)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
    XCTAssertTrue(fixture.preparationErrors.isEmpty, fixture.diagnostics)
  }

  func testDelayedIncomingCurrentPageKeepsOpenDocumentPaperUntilExplicitClose() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source:
      "First page.\\newpage Intermediate page.\\newpage Last page.")])
    let fixture = try ProgramFixture(document: document)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) && fixture.hosts[0].isUserInteractionEnabled }
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let target = try XCTUnwrap(source.layout).pageCount - 1
    fixture.showPages(current: 0, neighbour: target)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[1] == true && fixture.hosts[1].hasSnapshot }
    let original = WeakDocumentPaper(fixture.paper(in: 0))
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    fixture.retirePresentation(0)
    await owner.observePendingPresentationWork()
    XCTAssertNotNil(original.value)
    fixture.select(1)
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 1) && fixture.hosts[1].isUserInteractionEnabled }
    XCTAssertTrue(fixture.paper(in: 1) === original.value)
    XCTAssertEqual(source.measurementCount, 1)
    fixture.close()
    try await wait(message: { fixture.diagnostics }) { original.value == nil }
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
    XCTAssertEqual(fixture.resources.rasterAdmission.pinnedBytes, 0)
  }

  func testReturnToDocumentReattachesPreparedWorkingPaperWithoutRebuildingIt() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "A prepared formula \\(x^2 + y^2\\) and editable source.")])
    let fixture = try ProgramFixture(document: document, showsNeighbour: false)
    let owner = DocumentPagePresentationOwner.shared(documentID: document.id, resources: fixture.resources)
    let lifetime = owner.retainOpenDocument()
    defer { fixture.close(); lifetime.close() }
    try await wait(message: { fixture.diagnostics }) { fixture.canonicalPaper(in: 0) && fixture.hosts[0].isUserInteractionEnabled }
    let paper = try XCTUnwrap(fixture.paper(in: 0)), raster = try XCTUnwrap(fixture.retainedPaper)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let measurements = source.measurementCount
    lifetime.parkForReturn(); fixture.retirePresentation(0)
    await owner.observePendingPresentationWork()
    XCTAssertFalse(paper.isDescendant(of: fixture.hosts[0]))
    lifetime.resume(); fixture.restorePresentation(0)
    try await wait(message: { fixture.diagnostics }) { fixture.paper(in: 0) === paper && fixture.hosts[0].isUserInteractionEnabled }
    XCTAssertTrue(paper.raster === raster)
    XCTAssertEqual(source.measurementCount, measurements)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
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
    let before = try XCTUnwrap(paper.raster)
    let source = DocumentRenderRegistry.shared.session(documentID: document.id, resources: fixture.resources).source(document)
    let measuredCount = try XCTUnwrap(source.layout?.pageCount)
    XCTAssertGreaterThan(measuredCount, 1)
    try fixture.activateLink(in: paper)
    try await wait(message: { fixture.diagnostics }) { initialCalls == 1 }
    XCTAssertNil(acceptedPage, "The initial one-page closure rejects the later measured destination")
    fixture.replaceLinkNavigation { destination in
      if case .page(let page) = destination, page >= 0, page < measuredCount { acceptedPage = page }
    }
    try fixture.activateLink(in: paper)
    try await wait(message: { fixture.diagnostics }) { acceptedPage != nil }
    XCTAssertEqual(initialCalls, 1, "The old captured layout callback is retired by the same-entry update")
    XCTAssertGreaterThan(try XCTUnwrap(acceptedPage), 0)
    XCTAssertTrue(fixture.paper(in: 0) === paper)
    XCTAssertTrue(paper.raster === before, "Refreshing a callback preserves the exact installed PDF cut")
  }

  func testLoadingCaptionUsesItsTextWidthAndWrapsWithinThePhysicalPage() throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController(), host = DocumentPageHost()
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

  func testCurrentPagePreparationMetadataComesFromItsActualNativeInstallation() async throws {
    let document = DocumentTestFiles.document(contents: [.tex(id: "body", source: "A real canonical page.")])
    let recorder = DocumentPresentationRecorder(enabled: true)
    let request = try XCTUnwrap(recorder.request(documentID: document.id, pageIndex: 0, cause: .open))
    let fixture = try ProgramFixture(document: document, measurements: recorder)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { recorder.records.last?.installedAt != nil }
    let record = try XCTUnwrap(recorder.records.last), identity = try XCTUnwrap(record.pagePreparationIdentity)
    XCTAssertEqual(identity.requestID, request)
    XCTAssertEqual(identity.documentID, document.id)
    XCTAssertEqual(identity.sourceKey, fixture.paper(in: 0)?.raster?.sourceKey)
    let phases = try XCTUnwrap(record.pagePreparationPhasesMS)
    for stage in ["payloadConfiguredAt", "mountAt", "preparedPageStartAt", "preparedPageReadyAt", "paperInstalledAt", "canonicalReadyAt"] {
      XCTAssertNotNil(phases[stage], stage)
    }
    XCTAssertNil(phases["frameEvaluationStartAt"])
    XCTAssertLessThanOrEqual(try XCTUnwrap(phases["preparedPageReadyAt"]), try XCTUnwrap(phases["paperInstalledAt"]))
    XCTAssertLessThanOrEqual(identity.configuredAt + (try XCTUnwrap(phases["canonicalReadyAt"])) / 1_000,
      try XCTUnwrap(record.contentReadyAt))
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
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
    XCTAssertEqual(fixture.paper(in: 1)?.raster?.page.pageIndex, 1)
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
    XCTAssertEqual(fixture.paper(in: 0)?.raster?.page.pageIndex, 0)
    XCTAssertLessThanOrEqual(fixture.resources.activeWebSurfaceCount, 4)
  }

  func testLeavingTheProgramWindowCheckpointsAndReturnsToTheSameResidentHeap() async throws {
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
    fixture.showPages(current: 0, neighbour: 1)
    try await wait(message: { fixture.diagnostics }) { fixture.ready[0] == true && fixture.hosts[0].isUserInteractionEnabled && fixture.web(in: 0) === web }
    XCTAssertEqual(fixture.value("program")?["mounts"], .number(1))
    XCTAssertEqual(fixture.value("program")?["count"], .number(1))
    XCTAssertEqual(fixture.value("program")?["nonce"], firstNonce)
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

  func testPressureReleasesAnOffscreenProgramAfterWritingWithoutRequiringRasterAdmission() async throws {
    let document = DocumentTestFiles.document(actor: UUID(), contents: (0..<4).map { index in
      .program(id: "program-\(index)", html: "<button>Control \(index)</button>",
        javaScript: "notebook.commit({accepted:1});notebook.ready(Promise.resolve());", height: 100)
    })
    let resources = SceneRenderResources(maximumWebSurfaces: 3, maximumRasterCount: 0, reservedInteractiveSlots: 0)
    let fixture = try ProgramFixture(document: document, resources: resources, showsNeighbour: false)
    defer { fixture.close() }
    try await wait(message: { fixture.diagnostics }) { (0..<3).allSatisfy { fixture.web(block: "program-\($0)") != nil } }
    fixture.reveal(block: "program-3")
    // The fourth control is no longer held behind the removed three-program
    // quota. Its presence cannot stand in for completion of the others' writes.
    try await wait(message: { fixture.diagnostics }) {
      fixture.web(block: "program-3") != nil && resources.activeWebSurfaceCount == 3
        && (0..<3).allSatisfy { fixture.checkpointValues["program-\($0)"]?["accepted"] == .number(1) }
    }
    XCTAssertTrue((0..<3).allSatisfy { fixture.checkpointValues["program-\($0)"]?["accepted"] == .number(1) })
    XCTAssertEqual(resources.rasterAdmission.pinnedCount, 0)
    XCTAssertEqual(resources.activeWebSurfaceCount, 3)
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
    let fixture = try ProgramFixture(document: document, resources: SceneRenderResources(maximumWebSurfaces: 9), showsNeighbour: false)
    defer { fixture.close() }
    // Native paper needs no WebKit admission; one slot remains for transient preparation.
    let liveCapacity = fixture.resources.maximumWebSurfaces - 1
    XCTAssertGreaterThanOrEqual(liveCapacity, 4)
    try await wait(message: { fixture.diagnostics }) {
      (0..<9).filter { fixture.web(block: "program-\($0)") != nil }.count == liveCapacity
        && fixture.resources.pendingWebRequestCount == 9 - liveCapacity
    }
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, liveCapacity)
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
  let hosts = [DocumentPageHost(), DocumentPageHost()]
  private let coordinators = [DocumentPhysicalPageCoordinator(), DocumentPhysicalPageCoordinator()]
  private let actor = UUID()
  let window: UIWindow
  private var state: DocumentStateJournal
  private let measurements: DocumentPresentationRecorder?
  private let programStore: NotebookStore
  private let ownedStoreDirectory: URL?
  private var linkNavigation: (DocumentLinkDestination) -> Void = { _ in }
  private(set) var linkActivations: [DocumentLinkActivation] = []
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
  var onStateAccepted: (String) async -> Void = { _ in }
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
    guard let raster = paper(in: index)?.raster else { return false }
    return raster.page.pageIndex == pageIndices[index] && raster.page.artifact.document == document
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
        onPageLayout: { [weak self] layout in self?.installPageGeometry(layout, at: index) },
        onStateChange: { [weak self] program, value in
          guard let self else { return nil }
          _ = state.commit(instanceID: program.id, value: value, actor: actor)
          let accepted = state.records.first { $0.id == program.id }?.valueVersion
          refresh(); await onStateAccepted(program.id); return accepted
        },    onLinkActivation: { [weak self] activation in
          self?.linkActivations.append(activation); self?.linkNavigation(activation.destination)
        },
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

  private func installPageGeometry(_ layout: DocumentPageLayout, at index: Int) {
    guard layout.sourceRevision == DocumentPageNavigation.sourceRevision(document), let record = layout.record else { return }
    let geometry = record.paper(on: pageIndices[index]).geometry, host = hosts[index]
    let height = host.bounds.width * geometry.height / geometry.width
    guard host.bounds.height != height else { return }
    host.frame.size.height = height
    host.setNeedsLayout(); host.layoutIfNeeded()
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
  func paper(in index: Int) -> DocumentPaperView? { views(hosts[index]).compactMap { $0 as? DocumentPaperView }.first }
  func link(in paper: DocumentPaperView) -> UIButton? {
    guard let host = paper.superview else { return nil }
    return views(host).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "document-link" }
  }
  func activateLink(in paper: DocumentPaperView) throws {
    XCTAssertTrue(try XCTUnwrap(link(in: paper)).accessibilityActivate())
  }
  private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
  func assertPaperReceivesNativeHit(_ paper: DocumentPaperView, file: StaticString = #filePath, line: UInt = #line) async throws {
    let button = try XCTUnwrap(link(in: paper), file: file, line: line)
    window.layoutIfNeeded()
    let hit = window.hitTest(button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: window), with: nil)
    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
      "The actual native route must reach the installed PDF link, got \(String(describing: hit))", file: file, line: line)
  }
  func assertPaperRejectsNativeHit(_ paper: DocumentPaperView, file: StaticString = #filePath, line: UInt = #line) async throws {
    let button = try XCTUnwrap(link(in: paper), file: file, line: line)
    let hit = window.hitTest(button.convert(.init(x: button.bounds.midX, y: button.bounds.midY), to: window), with: nil)
    XCTAssertFalse(hit === button || hit?.isDescendant(of: button) == true,
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
  weak var value: UIView?
  init(_ value: UIView?) { self.value = value }
}
