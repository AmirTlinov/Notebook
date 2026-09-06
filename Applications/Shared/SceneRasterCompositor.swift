import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers

/// A composition owns one accounted output buffer and borrows one source at a
/// time. It never retains the archive's decoded images as a batch. The caller
/// keeps the physical source versions and decides whether publication is current.
@MainActor
final class SceneRasterCompositor {
  private let reservation: RasterReservation
  private let buffer: CompositionPixels
  private let permitsPreparation: @MainActor () -> Bool
  private var isFinished = false

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
      return Self(reservation: reservation, buffer: buffer, permitsPreparation: permitsPreparation)
    } catch { reservation.release(); throw error }
  }

  private init(reservation: RasterReservation, buffer: CompositionPixels,
    permitsPreparation: @escaping @MainActor () -> Bool) {
    self.reservation = reservation; self.buffer = buffer; self.permitsPreparation = permitsPreparation
  }

  func drawPNG(_ data: Data, in frame: CGRect) async throws {
    try checkPreparation()
    try await buffer.drawPNG(data, in: frame)
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

  func finishPNG() async throws -> Data {
    try checkPreparation()
    let png = try await buffer.finishPNG()
    try checkPreparation()
    isFinished = true
    reservation.release()
    return png
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
  private let size: CGSize
  private let scale: Double

  static func create(size: CGSize, width: Int, height: Int, scale: Double) async throws -> CompositionPixels {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: ((width * 4 + 63) / 64) * 64, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw SceneRenderError.resourceLimit }
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

  func finishPNG() throws -> Data {
    try Task.checkCancellation()
    guard let context, let image = context.makeImage() else { throw CancellationError() }
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
