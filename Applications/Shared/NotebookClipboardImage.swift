import CoreGraphics
import Foundation
import ImageIO
import NotebookCore
import UniformTypeIdentifiers

/// Canonical clipboard pixels. Display rasters remain derivatives owned by
/// presentation; capacity refusal never changes the author's resolution.
enum NotebookClipboardImage {
  static let maximumEncodedBytes = 4 * 1_048_576
  static let maximumPreparationBytes = 192 * 1_048_576

  struct Source: Sendable {
    let png: Data
    let width: Int
    let height: Int
  }

  static func prepare(_ data: Data, totalInputBytes: Int, retainedHTMLBytes: Int) throws -> Source {
    try Task.checkCancellation()
    guard let input = CGImageSourceCreateWithData(data as CFData,
      [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(input) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
      let rawWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let rawHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      rawWidth.doubleValue.isFinite, rawHeight.doubleValue.isFinite,
      rawWidth.doubleValue > 0, rawHeight.doubleValue > 0,
      rawWidth.doubleValue <= 1_000_000, rawHeight.doubleValue <= 1_000_000 else {
      throw failure("Нужно целое неподвижное изображение с допустимыми размерами.")
    }
    let width = rawWidth.intValue, height = rawHeight.intValue
    let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 16
    guard (1...16).contains(depth) else {
      throw failure("Этот формат пикселей пока нельзя перенести без изменения качества.")
    }
    // Include decoder/provider copies, orientation, lossless encoder workspace,
    // retained compressed inputs, HTML/base64 and the later action codec. The
    // caller reserves this peak before asking an item provider for its bytes.
    let rowBytes = ((width * (depth > 8 ? 8 : 4) + 63) / 64) * 64
    let pixelBytes = rowBytes * height
    let peak = pixelBytes * 7 + totalInputBytes * 2 + retainedHTMLBytes * 6 + 32 * 1_048_576
    guard totalInputBytes >= data.count, retainedHTMLBytes >= 0,
      peak <= maximumPreparationBytes else {
      throw failure("Исходное изображение не помещается в ёмкость вставки. Выберите меньший материал.")
    }
    try Task.checkCancellation()
    guard let decoded = CGImageSourceCreateImageAtIndex(input, 0,
      [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
      decoded.width == width, decoded.height == height,
      [8, 16].contains(decoded.bitsPerComponent),
      !decoded.bitmapInfo.contains(.floatComponents), !decoded.isMask, decoded.decode == nil,
      decoded.bitsPerPixel % 8 == 0, decoded.bitsPerPixel <= (depth > 8 ? 64 : 32),
      decoded.bytesPerRow <= rowBytes,
      let color = decoded.colorSpace, [.rgb, .monochrome].contains(color.model) else {
      throw failure("Этот формат пикселей пока нельзя перенести без изменения качества.")
    }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let image = try oriented(decoded, orientation: orientation)
    try Task.checkCancellation()
    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
      throw failure("Не удалось подготовить изображение.")
    }
    // A new PNG receives only decoded pixels and their color space. EXIF, GPS,
    // thumbnails and source properties are not copied into canonical content.
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination), encoded.length <= maximumEncodedBytes else {
      throw failure("Изображение без потери качества слишком велико для вставки.")
    }
    try Task.checkCancellation()
    return .init(png: encoded as Data, width: image.width, height: image.height)
  }

  private static func oriented(_ image: CGImage, orientation: Int) throws -> CGImage {
    guard (1...8).contains(orientation) else { throw failure("Некорректная ориентация изображения.") }
    guard orientation != 1 else { return image }
    guard let bytes = image.dataProvider?.data,
      CFDataGetLength(bytes) >= image.bytesPerRow * image.height else {
      throw failure("Не удалось прочитать пиксели изображения.")
    }
    let transposes = orientation >= 5
    let width = transposes ? image.height : image.width
    let height = transposes ? image.width : image.height
    let pixelBytes = image.bitsPerPixel / 8, rowBytes = width * pixelBytes
    var output = Data(count: rowBytes * height)
    try output.withUnsafeMutableBytes { destination in
      guard let base = destination.baseAddress, let source = CFDataGetBytePtr(bytes) else {
        throw failure("Не удалось исправить ориентацию изображения.")
      }
      for y in 0..<image.height {
        if y % 32 == 0 { try Task.checkCancellation() }
        for x in 0..<image.width {
          let target: (Int, Int)
          switch orientation {
          case 2: target = (image.width - 1 - x, y)
          case 3: target = (image.width - 1 - x, image.height - 1 - y)
          case 4: target = (x, image.height - 1 - y)
          case 5: target = (y, x)
          case 6: target = (image.height - 1 - y, x)
          case 7: target = (image.height - 1 - y, image.width - 1 - x)
          case 8: target = (y, image.width - 1 - x)
          default: preconditionFailure()
          }
          base.advanced(by: target.1 * rowBytes + target.0 * pixelBytes).copyMemory(
            from: source.advanced(by: y * image.bytesPerRow + x * pixelBytes), byteCount: pixelBytes)
        }
      }
    }
    guard let provider = CGDataProvider(data: output as CFData),
      let result = CGImage(width: width, height: height, bitsPerComponent: image.bitsPerComponent,
        bitsPerPixel: image.bitsPerPixel, bytesPerRow: rowBytes, space: image.colorSpace!,
        bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
        shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) else {
      throw failure("Не удалось исправить ориентацию изображения без изменения пикселей.")
    }
    return result
  }

  private static func failure(_ message: String) -> CollaborationError { .init("clipboard_unavailable", message) }
}
