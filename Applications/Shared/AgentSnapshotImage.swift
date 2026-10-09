#if os(iOS)
import UIKit

typealias AgentSnapshotImage = UIImage
#else
import AppKit

typealias AgentSnapshotImage = NSImage

extension NSImage {
  /// Preserves the admitted backing when logical size differs from pixel size.
  convenience init(raster: CGImage, logicalSize: NSSize) {
    let representation = NSBitmapImageRep(cgImage: raster)
    representation.size = logicalSize
    self.init(size: logicalSize)
    addRepresentation(representation)
  }

  /// A fractional source cut keeps its original color space and component
  /// precision. The caller admits both backings before requesting the capture.
  static func normalizedSnapshot(_ pixels: CGImage, region: CGRect,
    pixelSize: CGSize, logicalSize: CGSize) -> NSImage? {
    let bounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
    guard bounds.contains(region), region.width > 0, region.height > 0,
      pixelSize.width >= 1, pixelSize.height >= 1 else { return nil }
    if region == bounds, pixelSize == bounds.size {
      return .init(raster: pixels, logicalSize: logicalSize)
    }
    guard let space = pixels.colorSpace,
      let context = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height),
        bitsPerComponent: pixels.bitsPerComponent, bytesPerRow: 0, space: space,
        bitmapInfo: pixels.bitmapInfo.rawValue) else { return nil }
    let sx = pixelSize.width / region.width, sy = pixelSize.height / region.height
    context.interpolationQuality = .high
    context.setBlendMode(.copy)
    // The crop is expressed from the snapshot's top edge; CGContext draws
    // from the bottom. Fractional continuation offsets never round to a row.
    context.draw(pixels, in: .init(x: -region.minX * sx,
      y: -(bounds.height - region.maxY) * sy, width: bounds.width * sx, height: bounds.height * sy))
    guard let result = context.makeImage() else { return nil }
    return .init(raster: result, logicalSize: logicalSize)
  }
}
#endif
