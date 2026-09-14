import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Pixels fixed in the synchronous Send event. Encoding may finish later;
/// neither WebKit nor a cache lookup can replace the retained native image.
@MainActor
final class NotebookSubmittedPixels {
  let region: PageRect
  let pixelScale: Double
  private var image: CGImage?
  private let reservation: RasterReservation
  private var retainedRaster: RasterLease?

  private init(region: PageRect, pixelScale: Double, image: CGImage, reservation: RasterReservation) {
    self.region = region; self.pixelScale = pixelScale; self.image = image; self.reservation = reservation
  }
  isolated deinit { reservation.release() }

  func png() async throws -> Data {
    defer { withExtendedLifetime(self) { } }
    guard let image else { throw SceneRenderError.resourceLimit }
    let scale = pixelScale
    let encoding = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
      else { throw SceneRenderError.snapshotPending("png_encoding") }
      CGImageDestinationAddImage(destination, image,
        [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw SceneRenderError.snapshotPending("png_encoding") }
      try Task.checkCancellation()
      return data as Data
    }
    return try await withTaskCancellationHandler { try await encoding.value } onCancel: { encoding.cancel() }
  }

  #if os(iOS)
  /// The caller first proves source identity and installation. This method
  /// proves that the requested crop belongs to the currently visible subtree.
  /// It does not flush layout, await a newer DOM frame, or draw other layers.
  static func capture(view: UIView, physicalSize: CGSize, region: PageRect,
    resources: SceneRenderResources, sourceOrigin: CGPoint = .zero) throws -> NotebookSubmittedPixels? {
    let source = CGRect(origin: sourceOrigin, size: physicalSize)
    let crop = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
    guard [source.minX, source.minY, source.width, source.height, crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
      source.width > 0, source.height > 0, crop.width > 0, crop.height > 0, source.contains(crop),
      let window = view.window, !window.isHidden, !view.bounds.isEmpty else { return nil }
    let local = CGRect(x: view.bounds.minX + (crop.minX - source.minX) / source.width * view.bounds.width,
      y: view.bounds.minY + (crop.minY - source.minY) / source.height * view.bounds.height,
      width: crop.width / source.width * view.bounds.width, height: crop.height / source.height * view.bounds.height)
    let screenCrop = view.convert(local, to: window)
    var ancestor: UIView? = view
    while let current = ancestor {
      guard !current.isHidden, current.alpha > 0.001 else { return nil }
      if current.clipsToBounds || current === window {
        let visible = current.convert(current.bounds, to: window)
        guard visible.contains(screenCrop) else { return nil }
      }
      ancestor = current.superview
    }
    let scale = min(2, min(screenCrop.width / crop.width, screenCrop.height / crop.height) * window.screen.scale)
    let width = ceil(crop.width * scale), height = ceil(crop.height * scale)
    guard scale.isFinite, scale > 0, width >= 1, height >= 1, width <= 4096, height <= 4096,
      width * height <= 4_000_000,
      let reservation = resources.reserveRaster(pixelWidth: Int(width), pixelHeight: Int(height))
    else { throw SceneRenderError.resourceLimit }
    let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
    format.preferredRange = .standard
    var succeeded = false
    let pixels = UIGraphicsImageRenderer(size: crop.size, format: format).image { _ in
      succeeded = view.drawHierarchy(in: CGRect(x: source.minX - crop.minX, y: source.minY - crop.minY,
        width: source.width, height: source.height), afterScreenUpdates: false)
    }
    guard succeeded, let image = pixels.cgImage else {
      reservation.release(); throw SceneRenderError.snapshotPending("submitted_native_pixels_unavailable")
    }
    return .init(region: region, pixelScale: scale, image: image, reservation: reservation)
  }

  func retainRaster(source: SceneRasterSource, resources: SceneRenderResources) throws -> RasterLease {
    if retainedRaster == nil {
      guard let image else { throw SceneRenderError.resourceLimit }
      retainedRaster = resources.storeAndRetain(UIImage(cgImage: image, scale: pixelScale, orientation: .up),
        for: source, reservation: reservation)
      if retainedRaster == nil { self.image = nil }
    }
    guard let retainedRaster, retainedRaster.source == source,
      let lease = retainedRaster.retainedCopy() else { throw SceneRenderError.resourceLimit }
    return lease
  }
  #endif
}
