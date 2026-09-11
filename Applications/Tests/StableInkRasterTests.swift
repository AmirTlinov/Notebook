import NotebookCore
import PencilKit
import XCTest

@testable import Notebook

final class StableInkRasterTests: XCTestCase {
  @MainActor
  func testReloadUsesTheSharedInkRaster() {
    let drawing = PageInkDrawing(actions: [stroke(y: 100)])
    let view = InkCanvasView(
      frame: CGRect(x: 0, y: 0, width: 400, height: 400)
    )

    view.apply(drawing)

    XCTAssertEqual(
      view.committedVertexCount,
      0,
      "Устойчивый лист должен принадлежать точному растру общей геометрии"
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
    view.apply(PageInkDrawing(actions: [stroke(y: 100)]))
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
    view.apply(PageInkDrawing())

    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(
      from: 0,
      with: [point(x: 20, y: 40), point(x: 180, y: 80)]
    )
    view.displayActiveStroke(active)
    view.commitActiveStroke()
    let liveVertexCount = view.committedVertexCount

    view.settle(PageInkDrawing(actions: [stroke(y: 60)]))

    XCTAssertGreaterThan(liveVertexCount, 0)
    XCTAssertEqual(
      view.committedVertexCount,
      liveVertexCount,
      "Живой штрих остаётся видимым, пока точному растру некуда лечь"
    )
  }

  @MainActor
  func testLiveSettledAndReloadedLineKeepTheSamePixels() async throws {
    let size = CGSize(width: 400, height: 400)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let background = UIView(frame: window.bounds)
    background.backgroundColor = .white
    let view = InkCanvasView(frame: background.bounds)
    background.addSubview(view)
    window.rootViewController = UIViewController()
    window.rootViewController?.view = background
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    view.apply(PageInkDrawing())
    var drawing = PageInkDrawing()
    for (index, color) in PenColor.allCases.enumerated() {
      let style = PenStyle(color: color, width: 4, minimumOpacity: 0.18)
      let points: [PKStrokePoint] = (0..<80).map { step in
        let x = CGFloat(30 + step * 4)
        let y = CGFloat(50 + index * 85 + (step % 16 < 8 ? 0 : 28))
        return PKStrokePoint(
          location: CGPoint(x: x, y: y),
          timeOffset: Double(step) / 240, size: CGSize(width: 4, height: 4),
          opacity: 0.18 + 0.82 * Double(step) / 79, force: 1, azimuth: 0, altitude: .pi / 2)
      }
      let active = ActiveInkStroke(style: style)
      active.replaceMeasuredTail(from: 0, with: points)
      view.displayActiveStroke(active)
      view.commitActiveStroke()
      let rgb = color.components
      drawing = try drawing.appending(
        PageInkAction(
          tool: .pen,
          color: .init(red: rgb.red, green: rgb.green, blue: rgb.blue), points: points))
    }
    let eraserPoints = [point(x: 160, y: 20), point(x: 160, y: 380)]
    let eraser = ActiveEraserStroke()
    eraser.replaceMeasuredTail(from: 0, with: eraserPoints)
    view.displayActiveEraser(eraser)
    view.commitActiveEraser()
    drawing = try drawing.appending(PageInkAction(tool: .eraser, points: eraserPoints))
    try await Task.sleep(for: .milliseconds(100))
    func pixels() throws -> Data {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 2
      let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        background.drawHierarchy(in: background.bounds, afterScreenUpdates: true)
      }
      return try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
    }
    let live = try pixels()
    let ready = expectation(description: "same geometry settled")
    view.onRenderReadinessChange = { if $0 { ready.fulfill() } }
    view.settle(drawing)
    await fulfillment(of: [ready], timeout: 4)
    view.onRenderReadinessChange = nil
    try await Task.sleep(for: .milliseconds(60))
    let settled = try pixels()
    XCTAssertEqual(live.count, settled.count)
    let error =
      zip(live, settled).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(live.count)
    XCTAssertLessThan(
      error, 0.15, "Перенос в устойчивую текстуру сохраняет цвет, толщину и острые повороты")
    let decoded = try PageInkDrawing.decode(drawing.dataRepresentation())
    let originalRaster = try XCTUnwrap(InkRasterRenderer.shared.page(drawing, size: size))
    let reloadedRaster = try XCTUnwrap(InkRasterRenderer.shared.page(decoded, size: size))
    XCTAssertEqual(
      originalRaster.dataProvider?.data as Data?, reloadedRaster.dataProvider?.data as Data?)
    XCTAssertGreaterThan(darkPixelCount(in: UIImage(cgImage: reloadedRaster)), 100)
  }

  private func stroke(y: CGFloat) -> PageInkAction {
    PageInkAction(tool: .pen, points: [point(x: 10, y: y), point(x: 200, y: y)])
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
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: cgImage.width,
          height: cgImage.height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
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
