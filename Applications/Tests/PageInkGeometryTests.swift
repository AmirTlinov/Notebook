import NotebookCore
import PencilKit
import XCTest

@testable import Notebook

final class PageInkGeometryTests: XCTestCase {
  @MainActor
  func testCorrectedActiveTailKeepsTheSameBoundaryForBothRenderers() {
    let stroke=ActiveEraserStroke()
    stroke.replaceMeasuredTail(from:0,with:[point(x:20,y:20),point(x:80,y:80)])
    let firstRevision=stroke.revision
    XCTAssertEqual(stroke.changedStart(after:nil),0)
    XCTAssertEqual(stroke.changedStart(after:nil),0,"Reading a boundary is not destructive")
    stroke.replaceMeasuredTail(from:0,with:[point(x:25,y:20),point(x:85,y:80)])
    XCTAssertEqual(stroke.measured.count,2)
    XCTAssertEqual(stroke.changedStart(after:firstRevision),0)
    XCTAssertEqual(stroke.changedStart(after:firstRevision),0,
      "Page ink and the element mask must both rebuild an estimated correction")
  }

  @MainActor
  func testReloadRetainsMeasuredGeometry() async throws {
    let drawing = PageInkDrawing(actions: [stroke(y: 100)])
    let view = InkCanvasView(
      frame: CGRect(x: 0, y: 0, width: 400, height: 400)
    )

    view.apply(drawing)

    try await prepared(view)
    XCTAssertGreaterThan(view.committedSourceNodeCount, 0)
    XCTAssertEqual(view.pageMeshBuildCount, 1)
    view.frame.size = .init(width: 800, height: 800)
    view.layoutIfNeeded()
    XCTAssertEqual(view.pageMeshBuildCount, 1, "Resizing changes projection, not the source mesh")
  }

  @MainActor
  func testReloadedGeometryProducesVisibleInk() async throws {
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

    let ready = expectation(description: "геометрия показана")
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
      "Геометрия должна оставить видимые чернила на белой бумаге"
    )
  }

  @MainActor
  func testLiveMeshRemainsDuringDurablePreparation() {
    let view = InkCanvasView(frame: .zero)
    view.apply(PageInkDrawing())

    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(
      from: 0,
      with: [point(x: 20, y: 40), point(x: 180, y: 80)]
    )
    view.displayActiveStroke(active)
    view.commitActiveStroke()
    let liveVertexCount = view.committedSourceNodeCount

    view.settle(PageInkDrawing(actions: [stroke(y: 60)]))

    XCTAssertGreaterThan(liveVertexCount, 0)
    XCTAssertEqual(
      view.committedSourceNodeCount,
      liveVertexCount,
      "Подготовка не убирает живой штрих"
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
      let rgb = color.components
      let action = PageInkAction(tool: .pen, color: .init(red: rgb.red, green: rgb.green, blue: rgb.blue), points: points)
      view.commitActiveStroke(action)
      drawing = try drawing.appending(action)
    }
    let eraserPoints = [point(x: 160, y: 20), point(x: 160, y: 380)]
    let eraser = ActiveEraserStroke()
    eraser.replaceMeasuredTail(from: 0, with: eraserPoints)
    view.displayActiveEraser(eraser)
    let eraseAction = PageInkAction(tool: .eraser, points: eraserPoints)
    view.commitActiveEraser(eraseAction)
    drawing = try drawing.appending(eraseAction)
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
      error, 0.15, "Принятие измеренной сетки сохраняет цвет, толщину и острые повороты")
    XCTAssertEqual(view.pageMeshBuildCount, 0, "Pencil-up/delivery must retain the measured meshes")
    let decoded = try PageInkDrawing.decode(drawing.dataRepresentation())
    view.apply(decoded)
    try await prepared(view)
    try await Task.sleep(for: .milliseconds(100))
    let reloaded = try pixels()
    let reloadError = zip(settled, reloaded).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(settled.count)
    XCTAssertLessThan(reloadError, 0.15, "Reload uses the same geometry, not a resampled 2x page texture")
    let originalRaster = try XCTUnwrap(InkRasterRenderer.shared.page(drawing, size: size))
    let reloadedRaster = try XCTUnwrap(InkRasterRenderer.shared.page(decoded, size: size))
    XCTAssertEqual(
      originalRaster.dataProvider?.data as Data?, reloadedRaster.dataProvider?.data as Data?)
    XCTAssertGreaterThan(darkPixelCount(in: UIImage(cgImage: reloadedRaster)), 100)
  }

  @MainActor
  func testLongAcceptedContactReleasesHiddenGeometryOnceWithoutRebuildingHistory() async throws {
    let view=InkCanvasView(frame:.init(x:0,y:0,width:400,height:400))
    view.apply(PageInkDrawing());try await prepared(view)
    let points=(0..<10_000).map { point(x:CGFloat($0)/2,y:40+CGFloat(sin(Double($0)/8))*5) }
    let active=ActiveInkStroke(style:.standard)
    active.replaceMeasuredTail(from:0,with:points)
    let action=active.measured.frozen().restoredAction()
    view.displayActiveStroke(active);view.commitActiveStroke(action)
    XCTAssertEqual(view.committedPreparedNodeCount,points.count)
    let drawing=PageInkDrawing(actions:[action])
    view.settle(drawing);try await prepared(view)
    XCTAssertEqual(view.committedPreparedNodeCount,0,"Only the visible neighbourhood may build display nodes after acceptance")
    XCTAssertEqual(view.committedSourceNodeCount,points.count)
    XCTAssertEqual(view.pageMeshBuildCount,1)
    view.settle(drawing);try await prepared(view)
    XCTAssertEqual(view.pageMeshBuildCount,1,"Subsequent delivery reuses the canonical source")
  }

  @MainActor
  func testColdLoadAndDurableDeliveryPreserveANewerMeasuredTailAndUndo() async throws {
    let base = stroke(y: 100), tail = stroke(y: 160)
    let view = InkCanvasView(frame: .init(x: 0, y: 0, width: 400, height: 400))
    view.apply(.init(actions: [base]))
    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(from: 0, with: [point(x: 10, y: 160), point(x: 200, y: 160)])
    view.displayActiveStroke(active)
    view.commitActiveStroke(tail)
    let tailVertices = view.committedSourceNodeCount
    try await prepared(view)
    XCTAssertGreaterThan(view.committedSourceNodeCount, tailVertices, "Cold completion keeps the newer contact")
    let count = view.committedSourceNodeCount, built = view.pageMeshBuildCount
    let accepted = PageInkDrawing(actions: [base, tail])
    view.settle(accepted)
    try await prepared(view)
    XCTAssertEqual(view.committedSourceNodeCount, count, "Delivery cannot duplicate the already measured tail")
    XCTAssertEqual(view.pageMeshBuildCount, built, "Delivery does not rebuild the history or contact")
    view.apply(accepted.removing([tail.id]))
    try await prepared(view)
    XCTAssertEqual(view.committedSourceNodeCount, count - tailVertices)
    XCTAssertEqual(view.pageMeshBuildCount, built, "Undo removes a batch, not rasterizes/rebuilds the page")
  }

  @MainActor
  func testReplacedPreparationCannotInstallOldPageOrLoseAnActiveContact() async throws {
    let view = InkCanvasView(frame: .init(x: 0, y: 0, width: 400, height: 400))
    view.apply(.init(actions: (0..<40).map { stroke(y: CGFloat($0 * 5)) }))
    view.apply(.init())
    let active = ActiveInkStroke(style: .standard)
    active.replaceMeasuredTail(from: 0, with: [point(x: 10, y: 40), point(x: 200, y: 40)])
    view.displayActiveStroke(active)
    try await prepared(view)
    XCTAssertEqual(view.committedSourceNodeCount, 0)
    view.commitActiveStroke(stroke(y: 40))
    XCTAssertGreaterThan(view.committedSourceNodeCount, 0, "Preparation must not discard the active contact")
    XCTAssertEqual(view.pageMeshBuildCount, 0, "The cancelled old page must never publish")
  }

  @MainActor
  func testUnmountedPreparationCanResumeTheSamePageWithoutALateCancellationClearingIt() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
    let view = InkCanvasView(frame: .init(x: 0, y: 0, width: 400, height: 400))
    controller.view.addSubview(view)
    defer { view.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil }
    view.apply(.init(actions: (0..<40).map { stroke(y: CGFloat($0 * 5)) }))
    view.removeFromSuperview()
    controller.view.addSubview(view)
    try await prepared(view)
    XCTAssertGreaterThan(view.committedSourceNodeCount, 0)
    XCTAssertEqual(view.pageMeshBuildCount, 40, "Only the replacement preparation may publish")
  }

  @MainActor
  func testImportedBaselineRemainsVisibleBesideGeometry() async throws {
    let size = CGSize(width: 200, height: 200)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let png = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
      UIColor.black.setFill(); context.fill(.init(x: 20, y: 20, width: 40, height: 40))
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene); window.frame = .init(origin: .zero, size: size)
    let background = UIView(frame: window.bounds); background.backgroundColor = .white
    let view = InkCanvasView(frame: background.bounds); background.addSubview(view)
    let controller = UIViewController(); controller.view = background; window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    view.apply(.init(baselinePNG: png, baselineActionCount: 1, actions: [stroke(y: 120)]))
    try await prepared(view)
    let deadline = ContinuousClock.now + .seconds(3)
    while !view.isStableFramePresented, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(view.isStableFramePresented)
    XCTAssertGreaterThan(view.committedSourceNodeCount, 0, "An imported baseline cannot flatten newly measured ink")
    let image = UIGraphicsImageRenderer(size: size).image { _ in background.drawHierarchy(in: background.bounds, afterScreenUpdates: true) }
    XCTAssertGreaterThan(darkPixelCount(in: image), 5000, "Both original baseline and vector stroke remain visible")
  }

  @MainActor
  func testActivePageFramesCompositeRetainedInkWithoutRedrawingHistory() async throws {
    let size=CGSize(width:400,height:400)
    let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window=UIWindow(windowScene:scene); window.frame = .init(origin:.zero,size:size)
    let controller=UIViewController();window.rootViewController=controller
    let resources=SceneRenderResources(byteLimit:32*1024*1024)
    let view=InkCanvasView(frame:.init(origin:.zero,size:size),resources:resources);controller.view.addSubview(view)
    view.projectPage(region:.init(origin:.zero,size:size),sourceSize:size,pixelDensity:1)
    window.makeKeyAndVisible()
    defer { view.removeFromSuperview();window.isHidden=true;window.rootViewController=nil }
    view.apply(.init(actions:(0..<120).map { stroke(y:CGFloat(($0*3)%380+10)) }))
    try await prepared(view)
    let ready=ContinuousClock.now + .seconds(4)
    while !view.isStableFramePresented,ContinuousClock.now < ready { try await Task.sleep(for:.milliseconds(10)) }
    XCTAssertTrue(view.isStableFramePresented)
    let committed=view.pageCommittedPassCount,composited=view.pageActivePassCount
    XCTAssertGreaterThan(committed,0)

    let active=ActiveInkStroke(style:.standard)
    for index in 0..<24 {
      active.replaceMeasuredTail(from:active.measured.count,with:[point(x:CGFloat(20+index*10),y:200)])
      view.displayActiveStroke(active)
      try await Task.sleep(for:.milliseconds(9))
    }
    XCTAssertEqual(view.pageCommittedPassCount,committed,
      "Pencil frames must sample one retained page instead of encoding every saved stroke")
    XCTAssertGreaterThan(view.pageActivePassCount,composited)

    view.commitActiveStroke(active.measured.frozen().restoredAction())
    let deadline=ContinuousClock.now + .seconds(2)
    while view.pageCommittedPassCount == committed,ContinuousClock.now < deadline {
      try await Task.sleep(for:.milliseconds(10))
    }
    XCTAssertEqual(view.pageCommittedPassCount,committed+1,
      "Only the accepted change invalidates the retained page")
  }

  func testReloadPreservesChronologicalPenErasePenGeometry() throws {
    let pen = stroke(y: 100), erase = PageInkAction(tool: .eraser, points: [point(x: 80, y: 50), point(x: 80, y: 150)]), last = stroke(y: 120)
    let drawing = PageInkDrawing(actions: [pen, erase, last])
    let mesh = try PageInkMesh.prepare(drawing, reusing: [])
    let expected = SpatialInkMesh.local(SpatialInkComposer.pageLayers(drawing))
    XCTAssertEqual(mesh.entries.map { $0.mesh.tool }, [.pen, .eraser, .pen])
    for (entry, batch) in zip(mesh.entries, expected.batches) {
      XCTAssertEqual(entry.mesh.expandedForTesting().nodes, batch.expandedForTesting().nodes)
    }
  }

  @MainActor
  private func prepared(_ view: InkCanvasView) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while !view.pageGeometryIsReady, view.renderFailure == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNil(view.renderFailure)
    XCTAssertTrue(view.pageGeometryIsReady)
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
