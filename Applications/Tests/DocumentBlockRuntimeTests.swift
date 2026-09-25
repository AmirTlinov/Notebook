import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentBlockRuntimeTests: XCTestCase {
  func testReadinessFailureRetainsEarlierAcceptedCommitUntilDurable() async throws {
    let fixture = try RuntimeFixture(block: .interactive(id: "failed-ready", html: "<output>Early</output>", javaScript: """
      notebook.ready(Promise.reject(new Error('author readiness failure')));
      window.earlyAccepted=notebook.commit({savedBeforeFailure:1});
      """, height: 120))
    defer { fixture.close() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), queue = NotebookPersistenceQueue(store: store)
    try store.saveDocument(fixture.document)
    var journal = DocumentStateJournal(id: fixture.document.id, actor: UUID())
    try store.saveDocumentState(journal)
    var held: CheckedContinuation<Void, Never>?
    fixture.runtime.onStateChange = { value in
      await withCheckedContinuation { held = $0 }
      _ = journal.commit(blockID: "failed-ready", value: value, actor: journal.stamp.actor)
      let accepted = journal, version = journal.records.first { $0.id == "failed-ready" }?.valueVersion
      await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        queue.enqueue(owner: .documentState(fixture.document.id)) { store in
          try store.saveDocumentState(accepted)
          done.resume()
          return true
        }
      }
      return version
    }
    fixture.runtime.onStateDrained = { await queue.finishAcceptedProgramWrites() }
    let deadline = ContinuousClock.now + .seconds(5)
    while (held == nil || fixture.runtime.failure == nil), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let release = try XCTUnwrap(held)
    XCTAssertNotNil(fixture.runtime.failure)
    let web = try XCTUnwrap(fixture.runtime.webView, "An author error cannot dispose an earlier accepted snapshot")
    let admitted = try await web.evaluateJavaScript("window.earlyAccepted") as? Bool
    XCTAssertEqual(admitted, true)
    var saved = false
    let closing = Task { @MainActor in
      _ = try await fixture.runtime.checkpoint()
      saved = true
    }
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertFalse(saved)
    XCTAssertTrue(try store.loadDocumentState(fixture.document.id).records.isEmpty)
    release.resume(); held = nil
    try await closing.value
    XCTAssertTrue(saved)
    XCTAssertEqual(try store.loadDocumentState(fixture.document.id).records.first { $0.id == "failed-ready" }?.value,
      .object(["savedBeforeFailure": .number(1)]))
    XCTAssertNotNil(fixture.runtime.failure, "Durability does not hide the author's failure or restart it")
    XCTAssertNil(fixture.runtime.webView, "Only the completed boundary releases the broken executor")
  }

  func testUnreadyProgramCheckpointJoinsAcceptedStateBeforeRetirement() async throws {
    let fixture = try RuntimeFixture(block: .interactive(id: "early", html: "<output>Early</output>",
      javaScript: "notebook.ready(new Promise(()=>{})); window.earlyAccepted=notebook.commit({early:1});", height: 120))
    defer { fixture.close() }
    var held: CheckedContinuation<Void, Never>?
    fixture.runtime.onStateDrained = { await withCheckedContinuation { held = $0 } }
    let deadline = ContinuousClock.now + .seconds(5)
    while held == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let release = try XCTUnwrap(held, "The accepted event must reach its existing durability fence")
    let web = try XCTUnwrap(fixture.runtime.webView)
    let admitted = try await web.evaluateJavaScript("window.earlyAccepted") as? Bool
    XCTAssertEqual(admitted, true)
    XCTAssertFalse(fixture.runtime.ready)
    var completed = false
    let checkpoint = Task { @MainActor in
      let value = try await fixture.runtime.checkpoint()
      completed = true
      return value
    }
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertFalse(completed)
    XCTAssertNotNil(fixture.runtime.webView, "Readiness cannot dispose an admitted heap")
    let rejected = try await web.evaluateJavaScript("notebook.commit({late:2})") as? Bool
    XCTAssertEqual(rejected, false)
    release.resume(); held = nil
    let value = try await checkpoint.value
    XCTAssertEqual(value, .object(["early": .number(1)]))
    XCTAssertTrue(completed)
    XCTAssertFalse(fixture.runtime.ready, "The boundary must not manufacture author readiness")
    let resumed = await fixture.runtime.resume()
    XCTAssertTrue(resumed)
    fixture.runtime.onStateDrained = {}
    let next = try await web.evaluateJavaScript("notebook.commit({early:2})") as? Bool
    XCTAssertEqual(next, true, "Returning restores admission in the same heap, without rerunning the author")
  }

  func testLCCircuitQuarterPeriodsAndCheckpointUseTheShippedAuthorSources() async throws {
    func source(_ suffix: String) throws -> String {
      let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lc", withExtension: suffix, subdirectory: "animation"))
      return try String(contentsOf: url, encoding: .utf8)
    }
    let fixture = try RuntimeFixture(block: .interactive(id: "lc", html: source("html"),
      css: source("css"), javaScript: source("js"), height: 720), width: 760)
    defer { fixture.close() }
    try await fixture.waitUntilReady()
    let web = try XCTUnwrap(fixture.runtime.webView)
    let overflows = try await web.evaluateJavaScript("document.documentElement.scrollHeight > innerHeight + 1") as? Bool
    XCTAssertEqual(overflows, false, "The explanatory footer must stay inside the physical frame")
    for quarter in 0..<4 {
      let snapshot = try await fixture.runtime.capture(sourceOffset: 0, height: 720, pixelWidth: 760)
      let attachment = XCTAttachment(image: snapshot.image); snapshot.release()
      attachment.name = "LC-phase-\(quarter)-of-4"; attachment.lifetime = .keepAlways; add(attachment)
      let m = try await web.evaluateJavaScript("sampleLC({phase:\(Double(quarter)/4),inductance:100,capacitance:25,voltage:5})") as? [String:Double]
      XCTAssertEqual((m?["electric"] ?? -1) + (m?["magnetic"] ?? -1), 0.0003125, accuracy: 1e-10)
      _ = try await web.evaluateJavaScript("document.querySelector('#forward').click();true")
      try await Task.sleep(for: .milliseconds(40))
      XCTAssertEqual(fixture.runtime.value["phase"], .number(Double((quarter+1)%4)/4))
    }
    _ = try await web.evaluateJavaScript("document.querySelector('#play').click();true")
    try await Task.sleep(for: .milliseconds(180))
    let value = try await fixture.runtime.checkpoint()
    XCTAssertNotEqual(value["phase"], .number(0))
    let shown = try await web.evaluateJavaScript("Number(document.querySelector('#phase').value)") as? Double
    if case .number(let phase) = value["phase"] { XCTAssertEqual(shown ?? -1, phase, accuracy: 0.001) }
    else { XCTFail("Checkpoint must contain the shown phase") }
  }

  func testCheckpointFreezesTheActualAnimatedMomentBeforeAcceptingStateAndPixels() async throws {
    let block = DocumentBlock.interactive(id: "animation", html: "<output></output>", javaScript: """
      let phase=0,frame=0;
      const draw=()=>document.querySelector('output').textContent=String(phase);
      const tick=()=>{phase++;draw();frame=requestAnimationFrame(tick)};
      notebook.lifecycle({pause:()=>cancelAnimationFrame(frame),checkpoint:()=>({phase}),
        resume:()=>{frame=requestAnimationFrame(tick)},dispose:()=>cancelAnimationFrame(frame)});
      notebook.ready(Promise.resolve().then(()=>{draw();frame=requestAnimationFrame(tick)}));
      """, initialState: .object(["phase": .number(0)]), height: 100)
    let fixture = try RuntimeFixture(block: block)
    defer { fixture.close() }
    try await fixture.waitUntilReady()
    let web = try XCTUnwrap(fixture.runtime.webView)
    try await Task.sleep(for: .milliseconds(100))
    let saved = try await fixture.runtime.checkpoint()
    XCTAssertNotEqual(saved, block.initialState, "Checkpoint must read the model, not the last button commit")
    XCTAssertEqual(fixture.runtime.value, saved)
    let first = try await fixture.runtime.capture(sourceOffset: 0, height: 100, pixelWidth: 360)
    defer { first.release() }
    try await Task.sleep(for: .milliseconds(100))
    let last = try await fixture.runtime.capture(sourceOffset: 0, height: 100, pixelWidth: 360)
    defer { last.release() }
    XCTAssertEqual(first.image.pngData(), last.image.pngData(), "The frozen picture must not drift after the state checkpoint")
    let shown = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertEqual(shown.map(JSONValue.number), saved["phase"])
    await fixture.runtime.resume()
    try await Task.sleep(for: .milliseconds(100))
    let resumed = try await web.evaluateJavaScript("Number(document.querySelector('output').textContent)") as? Double
    XCTAssertGreaterThan(resumed ?? 0, shown ?? 0)
  }

  func testRejectedCheckpointRetainsTheLiveRuntimeForRecovery() async throws {
    let fixture = try RuntimeFixture(block: .interactive(id: "rejected", html: "<output>0.5</output>", javaScript: """
      window.pauses=0;window.checkpoints=0;window.resumes=0;
      notebook.lifecycle({pause:()=>{window.pauses++},checkpoint:()=>{window.checkpoints++;return {phase:0.5}},
        resume:()=>{window.resumes++}});notebook.ready(Promise.resolve());
      """, initialState: .object(["phase": .number(0)]), height: 100))
    defer { fixture.close() }
    try await fixture.waitUntilReady()
    let web = try XCTUnwrap(fixture.runtime.webView)
    let persist = fixture.runtime.onStateCheckpoint
    var attempts: [JSONValue] = []
    fixture.runtime.onStateCheckpoint = { value, _ in
      attempts.append(value)
      throw SceneRenderError.snapshotPending("checkpoint_not_accepted")
    }
    for _ in 0..<2 {
      do { _ = try await fixture.runtime.checkpoint(); XCTFail("Unaccepted state cannot retire the program") }
      catch { XCTAssertEqual(error as? SceneRenderError, .snapshotPending("checkpoint_not_accepted")) }
      XCTAssertTrue(fixture.runtime.webView === web)
      XCTAssertTrue(fixture.runtime.ready)
      XCTAssertNil(fixture.runtime.failure, "Writer refusal is retained by the checkpoint owner, not an author failure")
      XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 1)
      let resumed = await fixture.runtime.resume()
      XCTAssertFalse(resumed, "Resume cannot silently discard or write an unaccepted frozen state")
      let suspended = try await web.evaluateJavaScript("documentProgram.suspended") as? Bool
      XCTAssertEqual(suspended, true)
      XCTAssertEqual(fixture.runtime.value, .object(["phase": .number(0)]))
    }
    XCTAssertEqual(attempts, [.object(["phase": .number(0.5)]), .object(["phase": .number(0.5)])])
    let hooksBeforeRetry = try await web.evaluateJavaScript("[pauses,checkpoints,resumes]") as? [Int]
    XCTAssertEqual(hooksBeforeRetry, [1, 1, 0], "A writer retry must not repeat successful pause or checkpoint hooks")
    // This is the explicit persistence retry used by the existing checkpoint
    // owner; resume is not a hidden attempt to save or replace the executor.
    fixture.runtime.onStateCheckpoint = persist
    let saved = try await fixture.runtime.checkpoint()
    XCTAssertEqual(saved, .object(["phase": .number(0.5)]))
    XCTAssertTrue(fixture.runtime.webView === web)
    XCTAssertEqual(fixture.runtime.value, saved)
    let resumed = await fixture.runtime.resume()
    XCTAssertTrue(resumed)
    let suspended = try await web.evaluateJavaScript("documentProgram.suspended") as? Bool
    XCTAssertEqual(suspended, false)
    let hooksAfterRetry = try await web.evaluateJavaScript("[pauses,checkpoints,resumes]") as? [Int]
    XCTAssertEqual(hooksAfterRetry, [1, 1, 1])
  }

  func testCheckpointCannotOverwriteAnUnobservedExternalState() async throws {
    let fixture = try RuntimeFixture(block: .interactive(id: "stale", html: "<output>0.5</output>", javaScript: """
      notebook.lifecycle({checkpoint:()=>({phase:0.5})});notebook.ready(Promise.resolve());
      """, initialState: .object(["phase": .number(0)]), height: 100))
    defer { fixture.close() }
    try await fixture.waitUntilReady()
    fixture.runtime.onStateCheckpoint = { _, _ in nil }
    var writes = 0
    fixture.runtime.onStateChange = { _ in writes += 1; return nil }
    do { _ = try await fixture.runtime.checkpoint(); XCTFail("A newer state owns this program") }
    catch { XCTAssertTrue(error is NotebookProgramCheckpointError) }
    XCTAssertEqual(writes, 0)
    XCTAssertTrue(fixture.runtime.ready)
    await fixture.runtime.resume()
  }

  func testMissingRejectedAndHungReadinessAreLocalFailuresNotReadySurfaces() async throws {
    for source in ["window.unfinished=true", "notebook.ready(Promise.reject(new Error('setup failed')))",
      "notebook.ready(new Promise(()=>{}))"] {
      let fixture = try RuntimeFixture(block: .interactive(id: "unready", html: "<output>Not ready</output>",
        javaScript: source, height: 100))
      defer { fixture.close() }
      try await wait(seconds: 9) { fixture.runtime.failure != nil }
      XCTAssertFalse(fixture.runtime.ready)
      // Failure is visible before the asynchronous accepted-state boundary
      // finishes. Join that actual owner, not a scheduler-dependent UI instant.
      _ = try await fixture.runtime.checkpoint()
      XCTAssertNotNil(fixture.runtime.failure)
      XCTAssertNil(fixture.runtime.webView)
      XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 0)
    }
  }

  func testHTMLScriptReceivesTheAPIAndAnOlderStateEchoCannotUndoItsInput() async throws {
    let block = DocumentBlock.interactive(id: "counter", html: """
      <script>notebook.commit({count:0,inline:true});notebook.ready(Promise.resolve());</script>
      <button onclick="notebook.commit({...notebook.state,count:notebook.state.count+1})">Increment</button>
      """, css: "", javaScript: "", initialState: .null, height: 300)
    let fixture = try RuntimeFixture(block: block)
    defer { fixture.close() }
    try await fixture.waitUntilReady()
    let web = try XCTUnwrap(fixture.runtime.webView)
    XCTAssertEqual(fixture.runtime.value["inline"], .bool(true))
    let capabilities = try await web.evaluateJavaScript("({secure:isSecureContext,uuid:typeof crypto.randomUUID,origin:location.origin})") as? [String: Any]
    XCTAssertEqual(capabilities?["secure"] as? Bool, true)
    XCTAssertEqual(capabilities?["uuid"] as? String, "function", "Moving a program out of file-backed srcdoc preserves its Web Crypto capability")
    let uuid = try await web.evaluateJavaScript("crypto.randomUUID()")
    XCTAssertNotNil((uuid as? String).flatMap(UUID.init(uuidString:)))
    _ = try await web.evaluateJavaScript("document.querySelector('button').click();true")
    try await wait { fixture.runtime.value["count"] == .number(1) }
    try await fixture.runtime.apply(.null, stateVersion: nil)
    let retained = try await web.evaluateJavaScript("notebook.state.count")
    XCTAssertEqual(retained as? Int, 1, "The unchanged observed state version is an echo, even while the local value has advanced")
    var journal = DocumentStateJournal(id: fixture.document.id, actor: UUID())
    _ = journal.commit(blockID: block.id, value: .object(["count": .number(7)]), actor: UUID())
    let accepted = try XCTUnwrap(journal.records.first)
    try await fixture.runtime.apply(accepted.value, stateVersion: accepted.valueVersion)
    let advanced = try await web.evaluateJavaScript("notebook.state.count")
    XCTAssertEqual(advanced as? Int, 7, "A newly observed causal state can update this same context")
  }

  func testConcurrentPhysicalCutsKeepTheReadyControlAndViewportInstalled() async throws {
    let block = DocumentBlock.interactive(id: "counter",
      html: "<button style='height:70px' onclick='notebook.commit({clicked:true})'>Ready control</button><div style='height:1930px;background:linear-gradient(red,blue)'></div>",
      css: "", javaScript: "", initialState: .null, height: 2000)
    let fixture = try RuntimeFixture(block: block)
    defer { fixture.close() }
    try await fixture.waitUntilReady()
    let web = try XCTUnwrap(fixture.runtime.webView), parent = web.superview, frame = web.frame
    async let first = fixture.runtime.capture(sourceOffset: 0, height: 600, pixelWidth: 360)
    async let second = fixture.runtime.capture(sourceOffset: 600, height: 600, pixelWidth: 360)
    async let third = fixture.runtime.capture(sourceOffset: 1200, height: 600, pixelWidth: 360)
    let captures = try await [first, second, third]
    defer { captures.forEach { $0.release() } }
    XCTAssertEqual(Set(captures.map(\.entryID)).count, 3)
    XCTAssertTrue(web.superview === parent)
    XCTAssertEqual(web.frame, frame)
    XCTAssertTrue(web.isUserInteractionEnabled)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 1)
    XCTAssertNotEqual(captures[0].image.pngData(), captures[2].image.pngData())
    XCTAssertGreaterThan(try bluePixels(captures[2].image), 100,
      "The cut outside the displayed clip must contain its actual lower blue pixels, not an empty capture")
    XCTAssertEqual(try bluePixels(captures[0].image), 0)
    let attachment = XCTAttachment(image: captures[2].image)
    attachment.name = "document-program-offscreen-lower-cut"; attachment.lifetime = .keepAlways; add(attachment)
  }

  func testAQueuedNeighborReceivesTheInputSlotWhenItBecomesCurrent() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 2, maximumBackgroundWebSurfaces: 1, reservedInteractiveSlots: 1)
    let background = try await resources.acquireWebSurface(priority: .visible)
    defer { background.release() }
    let fixture = try RuntimeFixture(block: .interactive(id: "queued", html: "<button>Current control</button>", height: 100),
      resources: resources, priority: .neighbor)
    defer { fixture.close() }
    try await wait { resources.pendingWebRequestCount == 1 }
    XCTAssertNil(fixture.runtime.webView)
    fixture.runtime.start(priority: .input)
    try await fixture.waitUntilReady()
    XCTAssertNotNil(fixture.runtime.webView)
    XCTAssertEqual(resources.activeWebSurfaceCount, 2)
    XCTAssertEqual(resources.pendingWebRequestCount, 0)
    XCTAssertFalse(background.isReleased, "Foreground navigation uses its reserved slot instead of waiting for an unrelated neighbor")
  }

  func testAFullAdmissionQueueResumesTheVisibleRuntimeOnActualCapacityRelease() async throws {
    let resources = SceneRenderResources(maximumWebSurfaces: 1, maximumPendingWebRequests: 0)
    let held = try await resources.acquireWebSurface(priority: .input)
    defer { held.release() }
    let fixture = try RuntimeFixture(block: .interactive(id: "waiting", html: "<button>First touch</button>", height: 100),
      resources: resources, priority: .input)
    defer { fixture.close() }
    await Task.yield(); await Task.yield()
    XCTAssertNil(fixture.runtime.webView)
    XCTAssertNil(fixture.runtime.failure, "Admission waiting is not a program failure")
    held.release()
    try await fixture.waitUntilReady()
    XCTAssertNotNil(fixture.runtime.webView, "Actual release wakes the same demand without an activation tap or a timer")
    XCTAssertEqual(resources.activeWebSurfaceCount, 1)
  }

  private func bluePixels(_ value: UIImage) throws -> Int {
    let image = try XCTUnwrap(value.cgImage)
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    }
    return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 90 && bytes[$0 + 2] > 180 }.count
  }

  private func wait(seconds: Double = 5, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(predicate())
  }
}

@MainActor
private final class RuntimeFixture {
  let document: DocumentDocument
  let resources: SceneRenderResources
  let runtime: DocumentBlockRuntime
  private var journal: DocumentStateJournal
  let overlay = DocumentProgramOverlayHost()
  let window: UIWindow
  init(block: DocumentBlock, resources: SceneRenderResources = SceneRenderResources(), priority: WebPriority = .input, width: Double = 360) throws {
    self.resources = resources
    document = .init(actor: UUID(), blocks: [block])
    journal = .init(id: document.id, actor: UUID())
    runtime = .init(documentID: document.id, block: block, programIdentity: document.programIdentity(blockID: block.id),
      value: block.initialState, stateVersion: nil, width: width, resources: resources)
    window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let root = UIViewController(); window.rootViewController = root
    overlay.frame = .init(x: 0, y: 0, width: width, height: 700); root.view.addSubview(overlay)
    window.makeKeyAndVisible()
    runtime.onStateChange = { [weak self] value in
      guard let self else { return nil }
      _ = journal.commit(blockID: block.id, value: value, actor: journal.stamp.actor)
      return journal.records.first { $0.id == block.id }?.valueVersion
    }
    runtime.onStateCheckpoint = { [weak self] value, version in
      guard let self, journal.records.first(where: { $0.id == block.id })?.valueVersion == version else { return nil }
      _ = journal.commit(blockID: block.id, value: value, actor: journal.stamp.actor)
      return journal.records.first { $0.id == block.id }?.valueVersion
    }
    runtime.onMount = { [weak overlay] web, size in overlay?.park(web, fullSize: size) }
    runtime.start(priority: priority)
  }
  func waitUntilReady() async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !runtime.ready, runtime.failure == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    if let failure = runtime.failure { throw failure }
    XCTAssertTrue(runtime.ready)
    let web = try XCTUnwrap(runtime.webView)
    XCTAssertTrue(overlay.present([.init(blockID: runtime.block.id, webView: web,
      rect: .init(x: 0, y: 0, width: runtime.blockWidth, height: min(700, runtime.block.height)), sourceOffset: 0, fullSize: web.bounds.size)],
      paperSize: .init(width: runtime.blockWidth, height: 700), interactive: true))
  }
  func close() { runtime.stop(); overlay.removePrograms(); window.isHidden = true; window.rootViewController = nil }
}
