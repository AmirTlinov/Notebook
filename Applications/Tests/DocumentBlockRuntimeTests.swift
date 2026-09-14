import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentBlockRuntimeTests: XCTestCase {
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
      resources: resources, priority: .liveProgram)
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

  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
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
  init(block: DocumentBlock, resources: SceneRenderResources = SceneRenderResources(), priority: WebPriority = .input) throws {
    self.resources = resources
    document = .init(actor: UUID(), blocks: [block])
    journal = .init(id: document.id, actor: UUID())
    runtime = .init(documentID: document.id, block: block, sourceVersion: document.sourceVersion(blockID: block.id),
      value: block.initialState, stateVersion: nil, width: 360, resources: resources)
    window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let root = UIViewController(); window.rootViewController = root
    overlay.frame = .init(x: 0, y: 0, width: 360, height: 700); root.view.addSubview(overlay)
    window.makeKeyAndVisible()
    runtime.onStateChange = { [weak self] value in
      guard let self else { return nil }
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
      rect: .init(x: 0, y: 0, width: 360, height: min(700, runtime.block.height)), sourceOffset: 0, fullSize: web.bounds.size)],
      paperSize: .init(width: 360, height: 700), interactive: true))
  }
  func close() { runtime.stop(); overlay.removePrograms(); window.isHidden = true; window.rootViewController = nil }
}
