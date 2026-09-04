import PencilKit
import XCTest
@testable import Notebook

final class StableInkRasterTests: XCTestCase {
  @MainActor
  func testReloadUsesPencilKitRasterInsteadOfRebuildingRawPaths() {
    let drawing = PKDrawing(strokes: [stroke(y: 100)])
    let view = InkCanvasView(
      frame: CGRect(x: 0, y: 0, width: 400, height: 400)
    )

    view.apply(drawing)

    XCTAssertEqual(
      view.committedVertexCount,
      0,
      "Устойчивый лист должен принадлежать точному растру PencilKit"
    )
  }

  @MainActor
  func testExactStableTextureProducesVisibleInk() async throws {
    let size = CGSize(width: 400, height: 400)
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.first as? UIWindowScene
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let background = UIView(frame: window.bounds)
    background.backgroundColor = .white
    let view = InkCanvasView(frame: background.bounds)
    background.addSubview(view)
    window.rootViewController = UIViewController()
    window.rootViewController?.view = background
    window.makeKeyAndVisible()

    let ready = expectation(description: "точный растр показан")
    view.onRenderReadinessChange = { isReady in
      if isReady { ready.fulfill() }
    }
    view.apply(PKDrawing(strokes: [stroke(y: 100)]))
    await fulfillment(of: [ready], timeout: 3)

    let image = UIGraphicsImageRenderer(size: size).image { _ in
      background.drawHierarchy(in: background.bounds, afterScreenUpdates: true)
    }
    XCTAssertGreaterThan(
      darkPixelCount(in: image),
      100,
      "Точная текстура должна оставить видимые чернила на белой бумаге"
    )
  }

  @MainActor
  func testLiveMeshRemainsUntilTheExactStableRasterCanReplaceIt() {
    let view = InkCanvasView(frame: .zero)
    view.apply(PKDrawing())

    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(
      from: 0,
      with: [point(x: 20, y: 40), point(x: 180, y: 80)]
    )
    view.displayActiveStroke(active)
    view.commitActiveStroke()
    let liveVertexCount = view.committedVertexCount

    view.settle(PKDrawing(strokes: [stroke(y: 60)]))

    XCTAssertGreaterThan(liveVertexCount, 0)
    XCTAssertEqual(
      view.committedVertexCount,
      liveVertexCount,
      "Живой штрих остаётся видимым, пока точному растру некуда лечь"
    )
  }

  private func stroke(y: CGFloat) -> PKStroke {
    PKStroke(
      ink: PKInk(.monoline, color: .black),
      path: PKStrokePath(
        controlPoints: [point(x: 10, y: y), point(x: 200, y: y)],
        creationDate: Date()
      )
    )
  }

  private func point(x: CGFloat, y: CGFloat) -> PKStrokePoint {
    PKStrokePoint(
      location: CGPoint(x: x, y: y),
      timeOffset: 0,
      size: CGSize(width: 4, height: 4),
      opacity: 1,
      force: 1,
      azimuth: 0,
      altitude: .pi / 2
    )
  }

  private func darkPixelCount(in image: UIImage) -> Int {
    guard let cgImage = image.cgImage else { return 0 }
    let bytesPerPixel = 4
    let bytesPerRow = cgImage.width * bytesPerPixel
    var pixels = [UInt8](
      repeating: 0,
      count: cgImage.height * bytesPerRow
    )
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: cgImage.width,
        height: cgImage.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return false }
      context.draw(
        cgImage,
        in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
      )
      return true
    }
    guard rendered else { return 0 }
    return stride(from: 0, to: pixels.count, by: bytesPerPixel).reduce(0) {
      count, offset in
      count + (pixels[offset] < 80 && pixels[offset + 3] > 200 ? 1 : 0)
    }
  }
}
