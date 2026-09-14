import NotebookCore
import UIKit
import WebKit
import XCTest
@testable import Notebook

final class NotebookSubmittedPixelsTests: XCTestCase {
  @MainActor
  func testNativeSendCropSurvivesLaterDOMAndNeverIncludesAnotherLayer() async throws {
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    let (window, web) = try await fixture()
    defer { window.isHidden = true; window.rootViewController = nil }
    let other = UIView(frame: web.frame); other.backgroundColor = .green
    web.superview?.addSubview(other)
    var frozen: NotebookSubmittedPixels? = try XCTUnwrap(NotebookSubmittedPixels.capture(view: web,
      physicalSize: .init(width: 128, height: 128), region: .init(x: 8, y: 8, width: 32, height: 32), resources: resources))
    XCTAssertGreaterThan(resources.reservedBytes, 0)
    _ = try await web.evaluateJavaScript("document.body.style.background='#0000ff';true")
    let png = try await XCTUnwrap(frozen).png()
    let color = try pixel(png)
    XCTAssertGreaterThan(color[0], 240); XCTAssertLessThan(color[1], 10); XCTAssertLessThan(color[2], 10)
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "send-time-red-program-crop-before-blue-dom"; attachment.lifetime = .keepAlways; add(attachment)
    frozen = nil
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testHiddenDetachedAndClippedCropsCannotClaimVisiblePixels() async throws {
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    let (window, web) = try await fixture()
    defer { window.isHidden = true; window.rootViewController = nil }
    let region = PageRect(x: 8, y: 8, width: 32, height: 32), size = CGSize(width: 128, height: 128)
    web.isHidden = true
    XCTAssertNil(try NotebookSubmittedPixels.capture(view: web, physicalSize: size, region: region, resources: resources))
    web.isHidden = false
    let container = try XCTUnwrap(web.superview)
    container.clipsToBounds = true
    web.frame.origin = .init(x: container.bounds.maxX - 4, y: 0)
    XCTAssertNil(try NotebookSubmittedPixels.capture(view: web, physicalSize: size, region: region, resources: resources))
    web.removeFromSuperview()
    XCTAssertNil(try NotebookSubmittedPixels.capture(view: web, physicalSize: size, region: region, resources: resources))
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  func testTransferringPixelsToARasterKeepsOneAccountedOwnerUntilBothReadersFinish() async throws {
    let resources = SceneRenderResources(byteLimit: 16 * 1024 * 1024)
    let (window, web) = try await fixture()
    defer { window.isHidden = true; window.rootViewController = nil }
    let region = PageRect(x: 8, y: 8, width: 32, height: 32)
    var frozen: NotebookSubmittedPixels? = try XCTUnwrap(NotebookSubmittedPixels.capture(view: web,
      physicalSize: .init(width: 128, height: 128), region: region, resources: resources))
    let element = AgentElement(id: "submitted", kind: .web, frame: .init(x: 0, y: 0, width: 128, height: 128), source: "Red", html: "<body/>")
    let raster = try XCTUnwrap(frozen).retainRaster(source: .agentRegion(element, region), resources: resources)
    XCTAssertEqual(resources.reservedBytes, 0)
    XCTAssertGreaterThan(resources.residentBytes, 0)
    raster.release()
    let png = try await XCTUnwrap(frozen).png()
    XCTAssertGreaterThan(try pixel(png)[0], 240, "The pixel owner keeps its own raster pin after another reader releases")
    frozen = nil
    XCTAssertEqual(resources.reservedBytes, 0)
  }

  @MainActor
  private func fixture() async throws -> (UIWindow, WKWebView) {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; window.makeKeyAndVisible()
    let web = WKWebView(frame: .init(x: 32, y: 32, width: 128, height: 128))
    controller.view.addSubview(web)
    web.loadHTMLString("<meta name='viewport' content='width=device-width, initial-scale=1'><style>html,body{margin:0;width:100%;height:100%;background:#ff0000}</style><body></body>", baseURL: nil)
    let deadline = ContinuousClock.now + .seconds(5)
    while web.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(web.isLoading)
    web.layoutIfNeeded()
    _ = try await web.callAsyncJavaScript("await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));return true;",
      arguments: [:], in: nil, contentWorld: .page)
    return (window, web)
  }

  private func pixel(_ png: Data) throws -> [UInt8] {
    let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: .init(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
  }
}
