import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class DocumentImageReadinessTests: XCTestCase {
  func testActualWebKitClassifiesFixedSVGGeometryAndPreservesItsCSSConstrainedBounds() async throws {
    let fixture = try ImageFixture(); defer { fixture.stop() }
    try await ready(fixture)
    let web = try XCTUnwrap(fixture.renderer.webView)
    let result = try await web.callAsyncJavaScript("""
      const flow=document.createElement('div');flow.style.width='220px';document.body.append(flow);
      try {
        const image=document.createElement('img');image.width=451;image.height=158;image.src=source;
        image.style.maxWidth='100%';flow.append(image);
        const rect=()=>{const r=image.getBoundingClientRect();return [r.width,r.height]};
        const before=rect(),fixed=notebookDocumentImages.hasFixedGeometry(image,flow);
        await notebookDocumentImages.waitForGeometry(flow,()=>false);
        await notebookDocumentImages.waitForPixels(flow);
        const after=rect();
        image.style.height='auto';const auto=notebookDocumentImages.hasFixedGeometry(image,flow);
        image.style.height='158px';image.style.width='100%';const percent=notebookDocumentImages.hasFixedGeometry(image,flow);
        image.style.width='451px';const parent=document.createElement('div');parent.style.display='flex';
        flow.append(parent);parent.append(image);const flex=notebookDocumentImages.hasFixedGeometry(image,flow);
        return {fixed,auto,percent,flex,before,after,complete:image.complete,naturalWidth:image.naturalWidth};
      } finally {flow.remove()}
      """, arguments: ["source": ImageFixture.svg], in: nil, contentWorld: .page)
    let proof = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(proof["fixed"] as? Bool, true, "iOS must exercise the fast path, not silently classify every image as intrinsic")
    XCTAssertEqual(proof["auto"] as? Bool, false)
    XCTAssertEqual(proof["percent"] as? Bool, false)
    XCTAssertEqual(proof["flex"] as? Bool, false)
    XCTAssertEqual(proof["complete"] as? Bool, true)
    XCTAssertEqual(proof["naturalWidth"] as? Int, 451)
    XCTAssertEqual(proof["before"] as? [Double], proof["after"] as? [Double])
    XCTAssertEqual((proof["after"] as? [Double])?.first, 220)
  }

  func testDistantFixedImageDoesNotBlockFirstPageAndLatestPageWaitsForTheRealDecodeTail() async throws {
    let fixture = try ImageFixture(); defer { fixture.stop() }
    try await ready(fixture)
    let web = try XCTUnwrap(fixture.renderer.webView)
    try await installDecodeGate(in: web)
    fixture.replaceWithImage()
    try await ready(fixture)
    let source = try XCTUnwrap(fixture.renderer.payload?.source)
    let layout = try XCTUnwrap(source.layout)
    let target = try XCTUnwrap(layout.anchorPages["image-target"])
    XCTAssertGreaterThan(target, 0)
    let firstCalls = try await web.evaluateJavaScript("imageProbe.calls") as? Int
    XCTAssertEqual(firstCalls, 0,
      "A far fixed image has no decode barrier on the first text page")
    XCTAssertEqual(source.measurementCount, 1)
    let rawInstalls = try await web.evaluateJavaScript("notebookRenderer.pageReceipt().work.pageInstalls")
    let initialInstalls = try XCTUnwrap(rawInstalls as? Int)
    fixture.update(page: target)
    try await entered(in: web)
    XCTAssertFalse(fixture.renderer.renderIsReady)
    let previous = try await web.evaluateJavaScript("notebookRenderer.pageReceipt().pageIndex") as? Int
    XCTAssertEqual(previous, 0, "Old physical pixels remain installed until the new fragment's images are ready")
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 1)
    fixture.update(page: 0)
    let newest = try XCTUnwrap(fixture.renderer.payload?.renderToken)
    _ = try await web.evaluateJavaScript("imageProbe.release(); true")
    try await ready(fixture)
    let rawReceipt = try await web.evaluateJavaScript("notebookRenderer.pageReceipt()")
    let receipt = try XCTUnwrap(rawReceipt as? [String: Any])
    XCTAssertEqual(receipt["pageIndex"] as? Int, 0)
    XCTAssertEqual(receipt["renderToken"] as? String, newest)
    XCTAssertEqual((receipt["work"] as? [String: Int])?["pageInstalls"], initialInstalls + 1,
      "Only the latest frame may install: the cancelled far-image frame cannot publish old pixels after decode")
    XCTAssertTrue(fixture.renderer.webView === web)
    XCTAssertTrue(source.layout === layout)
    XCTAssertEqual(source.measurementCount, 1)
    let finalCalls = try await web.evaluateJavaScript("imageProbe.calls") as? Int
    XCTAssertEqual(finalCalls, 1)
    fixture.update(page: target)
    try await ready(fixture)
    let imageState = try await web.evaluateJavaScript("""
      (()=>{const img=document.querySelector('#document img');return img && img.complete && img.naturalWidth===451
        && notebookRenderer.pageReceipt().pageIndex===\(target)})()
      """) as? Bool
    XCTAssertEqual(imageState, true)
    XCTAssertTrue(source.layout === layout)
    XCTAssertEqual(source.measurementCount, 1)
    attachWindow(fixture.window, name: "distant-image-actual-ready")
    // The gate delayed completion of a real native img.decode Promise; it did
    // not substitute pixels or publish a manufactured render-ready receipt.
  }

  func testIntrinsicImageWaitsBeforeCanonicalGeometry() async throws {
    let fixture = try ImageFixture(); defer { fixture.stop() }
    try await ready(fixture)
    let web = try XCTUnwrap(fixture.renderer.webView)
    try await installDecodeGate(in: web)
    fixture.replaceWithImage(fixed: false)
    try await entered(in: web)
    XCTAssertFalse(fixture.renderer.renderIsReady)
    XCTAssertNil(fixture.renderer.payload?.source.layout, "Intrinsic dimensions are an input to the canonical cut")
    _ = try await web.evaluateJavaScript("imageProbe.release(); true")
    try await ready(fixture)
    XCTAssertNotNil(fixture.renderer.payload?.source.layout)
    XCTAssertEqual(fixture.renderer.payload?.source.measurementCount, 1)
  }

  func testBrokenFarFixedImageFailsOnlyWhenItsPhysicalPageIsRequested() async throws {
    let fixture = try ImageFixture(); defer { fixture.stop() }
    try await ready(fixture)
    fixture.replaceWithImage(source: "data:image/png;base64,bm90LWFuLWltYWdl")
    try await ready(fixture)
    let source = try XCTUnwrap(fixture.renderer.payload?.source)
    let target = try XCTUnwrap(source.layout?.anchorPages["image-target"])
    XCTAssertGreaterThan(target, 0)
    fixture.update(page: target)
    await waitUntil { fixture.renderer.acquisitionError != nil }
    XCTAssertFalse(fixture.renderer.renderIsReady)
    XCTAssertTrue(String(describing: fixture.renderer.acquisitionError).contains("document_image_decode_failed"))
    XCTAssertEqual(source.measurementCount, 1)
    attachWindow(fixture.window, name: "broken-image-page-native-error")
    let broken = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "first-broken", source:
      "<img width='451' height='158' src='data:image/png;base64,bm90LWFuLWltYWdl'>")])
    let initial = try ImageFixture(document: broken); defer { initial.stop() }
    await waitUntil { initial.renderer.acquisitionError != nil }
    XCTAssertTrue(String(describing: initial.renderer.acquisitionError).contains("document_image_decode_failed"),
      "A first-frame error carries its own runtime identity even before any payload has been installed")
    XCTAssertFalse(initial.renderer.renderIsReady)
  }

  func testInvalidationKeepsThePhysicalAdmissionUntilSubmittedImageDecodeActuallyFinishes() async throws {
    let fixture = try ImageFixture(); defer { fixture.stop() }
    try await ready(fixture)
    let web = try XCTUnwrap(fixture.renderer.webView)
    try await installDecodeGate(in: web)
    fixture.replaceWithImage()
    try await ready(fixture)
    let target = try XCTUnwrap(fixture.renderer.payload?.source.layout?.anchorPages["image-target"])
    fixture.update(page: target)
    try await entered(in: web)
    fixture.renderer.invalidate()
    XCTAssertNil(fixture.renderer.webView)
    XCTAssertEqual(fixture.resources.activeWebSurfaceCount, 1,
      "An in-flight non-cancellable decode still owns the submitted bridge bytes and a physical borrow")
    _ = try await web.evaluateJavaScript("imageProbe.release(); true")
    await waitUntil { fixture.resources.activeWebSurfaceCount == 0 }
    XCTAssertFalse(fixture.renderer.renderIsReady)
    XCTAssertEqual(fixture.resources.pendingWebRequestCount, 0)
  }

  private func attachWindow(_ window: UIWindow, name: String) {
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { _ in
      XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }

  private func installDecodeGate(in web: WKWebView) async throws {
    _ = try await web.evaluateJavaScript("""
      window.imageProbe={calls:0};imageProbe.gate=new Promise(resolve=>imageProbe.release=resolve);
      const original=HTMLImageElement.prototype.decode;
      HTMLImageElement.prototype.decode=function(){
        const decoded=original.call(this);
        if(!this.hasAttribute('data-image-gate'))return decoded;
        imageProbe.calls++;return decoded.then(()=>imageProbe.gate);
      };true;
      """)
  }

  private func entered(in web: WKWebView) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    var count = 0
    repeat {
      count = try await web.evaluateJavaScript("imageProbe.calls") as? Int ?? 0
      if count > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    XCTAssertGreaterThan(count, 0, "The actual production image barrier must submit decode")
  }

  private func ready(_ fixture: ImageFixture) async throws {
    await waitUntil { fixture.renderer.renderIsReady || fixture.renderer.acquisitionError != nil }
    XCTAssertNil(fixture.renderer.acquisitionError)
    XCTAssertTrue(fixture.renderer.renderIsReady)
  }

  private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition())
  }
}

@MainActor
private final class ImageFixture {
  static let svg = "data:image/svg+xml;base64," + Data("<svg xmlns='http://www.w3.org/2000/svg' width='451' height='158' viewBox='0 0 451 158'><rect width='451' height='158' fill='#126b92'/><circle cx='100' cy='79' r='45' fill='#f36b45'/></svg>".utf8).base64EncodedString()
  let resources = SceneRenderResources(maximumWebSurfaces: 1)
  let renderer: DocumentWebCoordinator
  let host = DocumentWebHost()
  let window: UIWindow
  var document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "# Ready source\n\nA real physical page.")])
  let state: DocumentStateJournal

  init(document supplied: DocumentDocument? = nil) throws {
    if let supplied { document = supplied }
    state = DocumentStateJournal(id: document.id, actor: UUID())
    renderer = DocumentWebCoordinator(resources: resources, onRenderReady: .init { _ in }, onPageLayout: { _ in },
      onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    window = UIWindow(windowScene: scene)
    let controller = UIViewController(); window.rootViewController = controller
    controller.view.addSubview(host); host.frame = controller.view.bounds; host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    update()
    let paper = WorkspaceItemGeometry.document(document.paperSize)
    renderer.mount(in: host, physicalSize: .init(width: paper.width, height: paper.height), isInteractive: true, priority: .currentPage)
    window.makeKeyAndVisible(); host.layoutIfNeeded()
  }

  func update(page: Int = 0) {
    renderer.update(document: document, state: state, selectedPageIndex: page, capturesSnapshot: false,
      onRenderReady: .init { _ in }, onPageLayout: { _ in }, onSourceChange: { _ in .committed }, onStateChange: { _, _ in nil })
  }

  func replaceWithImage(fixed: Bool = true, source: String = ImageFixture.svg) {
    let paragraphs = (0..<55).map { "Paragraph \($0). " + String(repeating: "Physical text keeps its canonical line position. ", count: 5) }.joined(separator: "\n\n")
    let image = "<h2 id='image-target'>Distant image</h2><img data-image-gate='yes' \(fixed ? "width='451' height='158'" : "") src='\(source)'>"
    XCTAssertTrue(document.replaceContent(blocks: [.markdown(id: "first", source: "# First page\n\n[Image](#image-target)\n\n" + paragraphs),
      .markdown(id: "picture", source: image)], actor: UUID()))
    update()
  }

  func stop() { renderer.invalidate(); window.isHidden = true; window.rootViewController = nil }
}
