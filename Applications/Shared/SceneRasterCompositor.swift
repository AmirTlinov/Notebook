import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers
import SwiftUI

/// A composition owns one accounted output buffer and borrows one source at a
/// time. It never retains the archive's decoded images as a batch. The caller
/// keeps the physical source versions and decides whether publication is current.
@MainActor
final class SceneRasterCompositor {
  private let reservation: RasterReservation
  private let buffer: CompositionPixels
  private let resources: SceneRenderResources
  let scale: Double
  private let size: CGSize
  private let permitsPreparation: @MainActor () -> Bool
  private var isFinished = false
  private var recordedDiagnostics: [RenderDiagnostic] = []
  private var omittedDiagnostics = 0
  var diagnostics: [RenderDiagnostic] {
    guard omittedDiagnostics > 0 else { return recordedDiagnostics }
    return recordedDiagnostics + [.init(kind: "diagnostics_truncated",
      message: "Ещё сообщений исполнения: \(omittedDiagnostics)")]
  }
  func recordDiagnostics(_ values: [RenderDiagnostic]) {
    guard !isFinished else { return }
    for value in values {
      if recordedDiagnostics.count < 255 { recordedDiagnostics.append(value) }
      else { omittedDiagnostics += 1 }
    }
  }


  static func create(size: CGSize, scale: Double, resources: SceneRenderResources,
    permitsPreparation: @escaping @MainActor () -> Bool = { true }) async throws -> SceneRasterCompositor {
    guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
      size.width > 0, size.height > 0, size.width * scale <= 8192, size.height * scale <= 8192
    else { throw SceneRenderError.resourceLimit }
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
    guard let reservation = resources.reserveRaster(pixelWidth: width, pixelHeight: height) else {
      throw SceneRenderError.resourceLimit
    }
    do {
      let buffer = try await CompositionPixels.create(size: size, width: width, height: height, scale: scale)
      try Task.checkCancellation()
      guard permitsPreparation() else { throw CancellationError() }
      return Self(reservation: reservation, buffer: buffer, resources: resources, size: size, scale: scale, permitsPreparation: permitsPreparation)
    } catch { reservation.release(); throw error }
  }

  private init(reservation: RasterReservation, buffer: CompositionPixels,
    resources: SceneRenderResources, size: CGSize, scale: Double, permitsPreparation: @escaping @MainActor () -> Bool) {
    self.reservation = reservation; self.buffer = buffer; self.resources = resources
    self.size = size; self.scale = scale; self.permitsPreparation = permitsPreparation
  }

  func drawPNG(_ data: Data, in frame: CGRect) async throws {
    try checkPreparation()
    try await buffer.drawPNG(data, in: frame)
    try checkPreparation()
  }

  /// The caller keeps the source allocation charged until this copy completes.
  func drawImage(_ image: CGImage, in frame: CGRect) async throws {
    try checkPreparation()
    try await buffer.draw(image, in: frame)
    try checkPreparation()
  }

  /// Use the retained entry, not a cache lookup after an asynchronous boundary.
  /// A newer capture of the same program cannot replace the borrowed pixels.
  func draw(_ raster: RasterLease, in frame: CGRect) async throws {
    try checkPreparation()
    guard !raster.isReleased else { throw SceneRenderError.snapshotPending("released_source") }
    #if os(iOS)
      let image = raster.image.cgImage
    #else
      let image = raster.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #endif
    guard let image else { throw SceneRenderError.snapshotPending("source_pixels") }
    try await buffer.draw(image, in: frame)
    try checkPreparation()
  }

  /// The board grid has no offscreen effects: each destination-aligned piece
  /// can be painted independently, unlike paper covers with shadows.
  func drawBoardGrid(camera: SpatialCamera, size: CGSize, in frame: CGRect) async throws {
    try checkPreparation()
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.resourceLimit }
    let visible = frame.intersection(CGRect(origin: .zero, size: self.size))
    guard !visible.isNull, !visible.isEmpty else { return }
    let left = Int(floor(visible.minX * scale)), top = Int(floor(visible.minY * scale))
    let right = Int(ceil(visible.maxX * scale)), bottom = Int(ceil(visible.maxY * scale))
    for y in stride(from: top, to: bottom, by: CompositionTile.pixelSize) {
      for x in stride(from: left, to: right, by: CompositionTile.pixelSize) {
        let region = CGRect(x: Double(x) / scale, y: Double(y) / scale,
          width: Double(min(CompositionTile.pixelSize, right - x)) / scale,
          height: Double(min(CompositionTile.pixelSize, bottom - y)) / scale)
        try await drawView(SpatialBoardGrid(camera: camera, outputScale: frame.width / size.width),
          size: size, in: frame, clippingTo: region)
      }
    }
  }

  func drawView<Content: View>(_ content: Content, size: CGSize, in frame: CGRect,
    clippingTo region: CGRect? = nil) async throws {
    try checkPreparation()
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.resourceLimit }
    let visible = frame.intersection(CGRect(origin: .zero, size: self.size))
      .intersection(region ?? CGRect(origin: .zero, size: self.size))
    guard !visible.isNull, !visible.isEmpty else { return }
    // Render artwork directly onto the destination pixel grid. A fractional
    // item origin must not introduce another resampling of grain or thin lines.
    let left = floor(visible.minX * scale), top = floor(visible.minY * scale)
    let width = Int(ceil(visible.maxX * scale) - left)
    let height = Int(ceil(visible.maxY * scale) - top)
    let capture = CGRect(x: left / scale, y: top / scale,
      width: Double(width) / scale, height: Double(height) / scale)
    guard let allocation = resources.reserveRaster(pixelWidth: width + 2, pixelHeight: height + 2)
    else { throw SceneRenderError.resourceLimit }
    defer { allocation.release() }
    let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height)
      .scaleEffect(x: frame.width / size.width, y: frame.height / size.height)
      .position(x: frame.midX - capture.minX, y: frame.midY - capture.minY)
      .frame(width: capture.width, height: capture.height).clipped())
    renderer.scale = scale
    // This owner supplies the admitted pixel grid and color format. The
    // convenience cgImage renderer can change Canvas antialias quantization
    // after another AppKit raster runs, changing an otherwise identical receipt.
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: ((width * 4 + 63) / 64) * 64, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    var rendered = false
    renderer.render(rasterizationScale: scale) { renderedSize, render in
      guard renderedSize == capture.size else { return }
      render(context); rendered = true
    }
    guard rendered, let image = context.makeImage() else { throw SceneRenderError.snapshotPending("physical_artwork") }
    try await buffer.draw(image, in: capture)
    try checkPreparation()
  }

  func drawInk(surface: SurfaceID, journal: SpatialInkJournal, camera: SpatialCamera?,
    size: CGSize, in frame: CGRect) async throws {
    try checkPreparation()
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size.width * 2 <= 65536, size.height * 2 <= 65536,
      frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.resourceLimit }
    let visible = frame.intersection(CGRect(origin: .zero, size: self.size))
    guard !visible.isNull, !visible.isEmpty else { return }
    let pixelsWide = Int(ceil(size.width * 2)), pixelsHigh = Int(ceil(size.height * 2))
    let sx = Double(pixelsWide) / size.width, sy = Double(pixelsHigh) / size.height
    let projectedX = frame.width / size.width, projectedY = frame.height / size.height
    let local = CGRect(x: (visible.minX - frame.minX) / projectedX,
      y: (visible.minY - frame.minY) / projectedY,
      width: visible.width / projectedX, height: visible.height / projectedY)
    let side = CompositionTile.pixelSize
    let haloX = Int(min(Double(pixelsWide), max(4, ceil(4 * sx / (projectedX * scale)))))
    let haloY = Int(min(Double(pixelsHigh), max(4, ceil(4 * sy / (projectedY * scale)))))
    let firstX = max(0, Int(floor(local.minX * sx)) - haloX)
    let firstY = max(0, Int(floor(local.minY * sy)) - haloY)
    let lastX = min(pixelsWide, Int(ceil(local.maxX * sx)) + haloX)
    let lastY = min(pixelsHigh, Int(ceil(local.maxY * sy)) + haloY)
    // Keep the physical image extent as well as its pixel grid. Cropping this
    // mask before projection changes Core Graphics' downsampling kernel phase.
    // The CPU mask is accounted before allocation; expensive MSAA work visits
    // only the visible regions and a reconstruction-filter halo.
    // At the native pixel grid, each disjoint tile goes directly into the
    // output. A second full-size mask would spend the entire 256 MiB budget
    // for a 2048-point region before its first 512-pixel tile can render.
    // Resampled projections still need one assembled mask to preserve seams.
    let nativeGrid = projectedX * scale == 2 && projectedY * scale == 2
      && Double(pixelsWide) == size.width * 2 && Double(pixelsHigh) == size.height * 2
      && (frame.minX * scale).rounded() == frame.minX * scale
      && (frame.minY * scale).rounded() == frame.minY * scale
    let mask = nativeGrid ? nil : try await Self.create(size: size, scale: 2,
      resources: resources, permitsPreparation: permitsPreparation)
    for y in stride(from: firstY, to: lastY, by: side) {
      for x in stride(from: firstX, to: lastX, by: side) {
        try checkPreparation()
        let width = min(side, lastX - x), height = min(side, lastY - y)
        let region = CGRect(x: Double(x) / sx, y: Double(y) / sy,
          width: Double(width) / sx, height: Double(height) / sy)
        let shiftedCamera = camera.map {
          SpatialCamera(center: $0.screenToWorld(.init(x: region.midX, y: region.midY),
            viewport: .init(x: size.width, y: size.height)), scale: $0.scale)
        }
        // MSAA, resolve texture and CPU readback coexist for only this 512-pixel
        // region. The physical 2x sampling grid remains the original owner's.
        guard let allocation = resources.reserveRaster(pixelWidth: width, pixelHeight: height, backingCount: 8)
        else { throw SceneRenderError.resourceLimit }
        do {
          let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let layers = shiftedCamera.map { SpatialInkComposer.boardLayers(board: surface, journal: journal,
              camera: $0, viewport: .init(x: region.width, y: region.height)) }
              ?? SpatialInkComposer.localLayers(for: surface, journal: journal,
                origin: .init(x: region.minX, y: region.minY))
            guard !layers.isEmpty else { return nil as CGImage? }
            guard let image = InkRasterRenderer.shared.render(layers: layers, size: region.size, scale: 2) else {
              throw SceneRenderError.snapshotPending("ink_pixels")
            }
            try Task.checkCancellation()
            return image
          }
          let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
          try checkPreparation()
          if let image {
            if let mask { try await mask.buffer.draw(image, in: region) }
            else {
              try await buffer.draw(image, in: .init(x: frame.minX + region.minX * projectedX,
                y: frame.minY + region.minY * projectedY,
                width: region.width * projectedX, height: region.height * projectedY))
            }
          }
          allocation.release()
        } catch { allocation.release(); throw error }
      }
    }
    // Assemble the transparent mask on its integer source grid first. Scaling
    // separate tiles over paper would blend their shared edge twice or leave a
    // faint seam. The physical mask is projected exactly once.
    if let mask { try await mask.finishInto(self, in: frame) }
  }

  private func finishInto(_ destination: SceneRasterCompositor, in frame: CGRect) async throws {
    try checkPreparation(); try destination.checkPreparation()
    let image = try await buffer.finishImage()
    try await destination.buffer.draw(image, in: frame)
    try checkPreparation(); try destination.checkPreparation()
    isFinished = true; reservation.release()
  }

  func pushClip(_ path: sending CGPath) async throws { try checkPreparation(); try await buffer.pushClip(path) }
  func popClip() async throws { try checkPreparation(); try await buffer.popClip() }

  func finishPNG() async throws -> Data {
    try checkPreparation()
    let png = try await buffer.finishPNG()
    try checkPreparation()
    isFinished = true
    reservation.release()
    return png
  }

  /// Ownership transfers directly from the accounted output buffer to the
  /// shared image cache. No decode or unaccounted image survives this boundary.
  func finishRaster(for source: SceneRasterSource) async throws -> RasterLease {
    try checkPreparation()
    let pixels = try await buffer.finishImage()
    try checkPreparation()
    #if os(iOS)
      let image = UIImage(cgImage: pixels, scale: 1, orientation: .up)
    #else
      let image = NSImage(cgImage: pixels, size: .init(width: pixels.width, height: pixels.height))
    #endif
    guard resources.store(image, for: source, reservation: reservation),
      let retained = resources.retainRaster(for: source) else { throw SceneRenderError.resourceLimit }
    isFinished = true
    return retained
  }

  private func checkPreparation() throws {
    try Task.checkCancellation()
    guard !isFinished, permitsPreparation() else { throw CancellationError() }
  }

  isolated deinit { reservation.release() }
}

/// Pixel allocation, blending and PNG encoding run outside the UI actor. This
/// actor serializes one composition; it is neither a source cache nor a writer.
private actor CompositionPixels {
  private var context: CGContext?
  private var clipDepth = 0
  private let size: CGSize
  private let scale: Double

  static func create(size: CGSize, width: Int, height: Int, scale: Double) async throws -> CompositionPixels {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: ((width * 4 + 63) / 64) * 64, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: Double(height))
    context.scaleBy(x: Double(width) / size.width, y: -Double(height) / size.height)
    context.interpolationQuality = .high
    return Self(context: context, size: size, scale: scale)
  }

  private init(context: sending CGContext, size: CGSize, scale: Double) {
    self.context = context; self.size = size; self.scale = scale
  }

  func drawPNG(_ data: Data, in frame: CGRect) throws {
    try Task.checkCancellation()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw SceneRenderError.snapshotPending("base_pixels")
    }
    try draw(image, in: frame)
  }

  func draw(_ image: CGImage, in frame: CGRect) throws {
    try Task.checkCancellation()
    guard let context else { throw CancellationError() }
    guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
      frame.width > 0, frame.height > 0 else { throw SceneRenderError.snapshotPending("invalid_frame") }
    context.saveGState()
    // Sources use top-left page coordinates; CGImage drawing itself is y-up.
    context.translateBy(x: frame.minX, y: frame.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: frame.size))
    context.restoreGState()
  }

  func pushClip(_ path: sending CGPath) throws {
    try Task.checkCancellation()
    guard let context else { throw CancellationError() }
    context.saveGState(); context.addPath(path); context.clip(); clipDepth += 1
  }
  func popClip() throws {
    guard let context, clipDepth > 0 else { throw CancellationError() }
    context.restoreGState(); clipDepth -= 1
  }

  func finishImage() throws -> CGImage {
    try Task.checkCancellation()
    guard clipDepth == 0, let context, let image = context.makeImage() else { throw CancellationError() }
    self.context = nil
    return image
  }

  func finishPNG() throws -> Data {
    try Task.checkCancellation()
    guard clipDepth == 0, let context, let image = context.makeImage() else { throw CancellationError() }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw SceneRenderError.snapshotPending("png_encoding") }
    CGImageDestinationAddImage(destination, image,
      [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw SceneRenderError.snapshotPending("png_encoding") }
    self.context = nil
    return data as Data
  }
}
