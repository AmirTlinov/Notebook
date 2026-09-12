import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class SceneTileSamplingTests: XCTestCase {
  func testFractionalTilesPreserveThinLinesAlphaAndTheSharedEdge() throws {
    let resources = SceneRenderResources()
    let rasters = try makeRasters(resources: resources, includesLines: true)
    defer { rasters.forEach { $0.release() } }
    var reports: [String] = []
    for zoom in [0.373, 0.619] {
      for phase in [0.17, 0.67] {
        let geometry = SamplingGeometry(zoom: zoom, phase: phase)
        let native = try capture(rasters: rasters, geometry: geometry, native: true)
        let previous = try capture(rasters: rasters, geometry: geometry, native: false)
        let name = "zoom-\(zoom)-phase-\(phase)"
        attach(native, name: "tile-native-\(name)")
        attach(previous, name: "tile-previous-image-high-\(name)")
        attach(comparison(native: native, previous: previous), name: "tile-comparison-native-top-\(name)")
        let nativeMetrics = try metrics(native, geometry: geometry)
        let previousMetrics = try metrics(previous, geometry: geometry)
        for (path, measured) in [("native", nativeMetrics), ("previous-image-high", previousMetrics)] {
          let detail = "\(name) \(path): \(measured)"
          reports.append(detail)
          XCTAssertEqual(measured.interiorAlpha, 0.5, accuracy: 0.055, detail)
          // Two separately filtered transparent edges need not match one
          // monolithic image byte for byte. Neither may expose a white seam
          // or double-paint the half-opacity source as an opaque join.
          XCTAssertGreaterThan(measured.minimumSeamAlpha, 0.38, detail)
          XCTAssertLessThan(measured.maximumSeamAlpha, 0.62, detail)
          let expectedLineWeight = zoom * Double(native.scale)
          XCTAssertGreaterThan(measured.minimumHorizontalInk, expectedLineWeight * 0.35, detail)
          XCTAssertGreaterThan(measured.minimumVerticalInk, expectedLineWeight * 0.35, detail)
          XCTAssertLessThan(measured.maximumHorizontalInk, expectedLineWeight * 1.6 + 0.03, detail)
          XCTAssertLessThan(measured.maximumVerticalInk, expectedLineWeight * 1.6 + 0.03, detail)
        }
      }
    }
    let report = XCTAttachment(string: reports.joined(separator: "\n"))
    report.name = "tile-fractional-sampling-coverage"; report.lifetime = .keepAlways; add(report)
  }

  func testSamplingChecksDetectAnActualGapAndMissingSourceLines() throws {
    let resources = SceneRenderResources()
    let rasters = try makeRasters(resources: resources, includesLines: false)
    defer { rasters.forEach { $0.release() } }
    let geometry = SamplingGeometry(zoom: 0.373, phase: 0.17, gap: 2)
    let image = try capture(rasters: rasters, geometry: geometry, native: true)
    attach(image, name: "tile-negative-control-two-point-gap-and-no-lines")
    let measured = try metrics(image, geometry: geometry)
    XCTAssertEqual(measured.interiorAlpha, 0.5, accuracy: 0.055,
      "The negative control must still paint real translucent source pixels, not a blank host")
    XCTAssertLessThan(measured.minimumSeamAlpha, 0.05,
      "The seam measurement must detect the deliberately separated tile edges")
    XCTAssertLessThan(measured.minimumHorizontalInk, 0.01)
    XCTAssertLessThan(measured.minimumVerticalInk, 0.01)
  }

  private func makeRasters(resources: SceneRenderResources, includesLines: Bool) throws -> [RasterLease] {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: .init(width: 512, height: 512), format: format).image { context in
      UIColor(red: 1, green: 0, blue: 0, alpha: 0.5).setFill()
      context.fill(.init(x: 0, y: 64, width: 512, height: 144))
      if includesLines {
        UIColor.black.setFill()
        context.fill(.init(x: 0, y: 288, width: 512, height: 1))
        context.fill(.init(x: 128, y: 352, width: 1, height: 96))
      }
    }
    return try (0..<2).map { index in
      let source = AgentElement(id: "tile-sampling-\(index)", kind: .web,
        frame: .init(x: 0, y: 0, width: 512, height: 512), source: "Prepared sampling control", html: "")
      XCTAssertTrue(resources.store(image, for: source))
      return try XCTUnwrap(resources.retainRaster(for: source))
    }
  }

  private func capture(rasters: [RasterLease], geometry: SamplingGeometry, native: Bool) throws -> UIImage {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    window.frame = .init(origin: .zero, size: geometry.size)
    let host = UIHostingController(rootView: SamplingRow(rasters: rasters, geometry: geometry, native: native)
      .ignoresSafeArea())
    host.safeAreaRegions = []
    window.rootViewController = host; window.makeKeyAndVisible()
    defer {
      window.isHidden = true; window.rootViewController = nil
    }
    host.view.backgroundColor = .white
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    let presenters = descendants(host.view)
    XCTAssertEqual(presenters.count, native ? 2 : 0)
    for presenter in presenters {
      XCTAssertFalse(presenter.layer.shouldRasterize)
      XCTAssertEqual(presenter.bounds.size, CGSize(width: 512, height: 512),
        "The camera must project the prepared source rather than resize it")
      XCTAssertNotNil(presenter.layer.contents)
    }
    let format = UIGraphicsImageRendererFormat(); format.scale = scene.screen.scale
    format.preferredRange = .standard
    var didDraw = false
    let image = UIGraphicsImageRenderer(size: geometry.size, format: format).image { context in
      UIColor.white.setFill(); context.fill(.init(origin: .zero, size: geometry.size))
      didDraw = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    XCTAssertTrue(didDraw, "Pixel capture must complete; this is not a display-presentation or FPS receipt")
    return image
  }

  private func descendants(_ view: UIView) -> [AgentSnapshotRasterView] {
    (view as? AgentSnapshotRasterView).map { [$0] } ?? view.subviews.flatMap(descendants)
  }

  private func metrics(_ image: UIImage, geometry: SamplingGeometry) throws -> SamplingMetrics {
    let cg = try XCTUnwrap(image.cgImage), scale = Double(image.scale)
    var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(cg, in: .init(x: 0, y: 0, width: cg.width, height: cg.height))
    }
    func channel(_ x: Int, _ y: Int, _ channel: Int) -> Double {
      precondition((0..<cg.width).contains(x) && (0..<cg.height).contains(y))
      return Double(pixels[(y * cg.width + x) * 4 + channel]) / 255
    }
    func x(_ source: Double) -> Int { Int(((geometry.origin.x + source * geometry.zoom) * scale).rounded(.down)) }
    func y(_ source: Double) -> Int { Int(((geometry.origin.y + source * geometry.zoom) * scale).rounded(.down)) }
    let alphaRows = (y(136) - 2)...(y(136) + 2)
    func alpha(_ column: Int) -> Double {
      alphaRows.reduce(0) { $0 + 1 - channel(column, $1, 1) } / Double(alphaRows.count)
    }
    let seam = ((x(512) - 3)...(x(512) + 3)).map(alpha)
    let interior = [128.0, 384, 640, 896].map { alpha(x($0)) }
    let horizontal = (x(8)...x(1016)).map { column in
      ((y(288.5) - 3)...(y(288.5) + 3)).reduce(0.0) { $0 + 1 - channel(column, $1, 0) }
    }
    let vertical = [128.5, 640.5].flatMap { sourceX in
      (y(360)...y(440)).map { row in
        ((x(sourceX) - 3)...(x(sourceX) + 3)).reduce(0.0) { $0 + 1 - channel($1, row, 0) }
      }
    }
    return .init(interiorAlpha: interior.reduce(0, +) / Double(interior.count),
      minimumSeamAlpha: try XCTUnwrap(seam.min()), maximumSeamAlpha: try XCTUnwrap(seam.max()),
      minimumHorizontalInk: try XCTUnwrap(horizontal.min()), maximumHorizontalInk: try XCTUnwrap(horizontal.max()),
      minimumVerticalInk: try XCTUnwrap(vertical.min()), maximumVerticalInk: try XCTUnwrap(vertical.max()))
  }

  private func comparison(native: UIImage, previous: UIImage) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = native.scale; format.preferredRange = .standard
    let size = CGSize(width: native.size.width, height: native.size.height * 2 + 8)
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.white.setFill(); context.fill(.init(origin: .zero, size: size))
      native.draw(at: .zero)
      previous.draw(at: .init(x: 0, y: native.size.height + 8))
    }
  }

  private func attach(_ image: UIImage, name: String) {
    guard let data = image.pngData() else { return XCTFail("Could not encode sampling evidence: \(name)") }
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
}

private struct SamplingGeometry {
  let zoom: Double
  let phase: Double
  var gap: Double = 0
  var origin: CGPoint { .init(x: 24 + phase, y: 24.375) }
  var size: CGSize { .init(width: ceil(48 + 1024 * zoom + gap), height: ceil(48 + 512 * zoom)) }
}

private struct SamplingMetrics: CustomStringConvertible {
  let interiorAlpha: Double
  let minimumSeamAlpha: Double
  let maximumSeamAlpha: Double
  let minimumHorizontalInk: Double
  let maximumHorizontalInk: Double
  let minimumVerticalInk: Double
  let maximumVerticalInk: Double
  var description: String {
    "alpha=\(interiorAlpha), seam=\(minimumSeamAlpha)...\(maximumSeamAlpha), "
      + "horizontal=\(minimumHorizontalInk)...\(maximumHorizontalInk), vertical=\(minimumVerticalInk)...\(maximumVerticalInk)"
  }
}

private struct SamplingRow: View {
  let rasters: [RasterLease]
  let geometry: SamplingGeometry
  let native: Bool
  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.white
      ZStack(alignment: .topLeading) {
        ForEach(rasters.indices, id: \.self) { index in
          Group {
            if native { SamplingNativeRaster(raster: rasters[index]) }
            else { Image(uiImage: rasters[index].image).resizable().interpolation(.high) }
          }
          .frame(width: 512, height: 512)
          .offset(x: Double(index) * (512 + geometry.gap / geometry.zoom))
        }
      }
      .frame(width: 1024 + geometry.gap / geometry.zoom, height: 512, alignment: .topLeading)
      .scaleEffect(geometry.zoom, anchor: .topLeading)
      .frame(width: 1024 * geometry.zoom + geometry.gap, height: 512 * geometry.zoom, alignment: .topLeading)
      .offset(x: geometry.origin.x, y: geometry.origin.y)
    }
    .frame(width: geometry.size.width, height: geometry.size.height)
  }
}

private struct SamplingNativeRaster: UIViewRepresentable {
  let raster: RasterLease
  func makeUIView(context: Context) -> AgentSnapshotRasterView { .init() }
  func updateUIView(_ view: AgentSnapshotRasterView, context: Context) {
    view.updateRaster(raster, displayScale: context.environment.displayScale)
  }
  static func dismantleUIView(_ view: AgentSnapshotRasterView, coordinator: ()) { view.uninstall() }
}
