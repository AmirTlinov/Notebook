import Foundation
import CoreGraphics
import ImageIO

/// Raster decoding uses ImageIO in the markup sandbox; SVG has a dedicated
/// bounded real renderer child. Neither route creates an AppKit/WebKit runtime.
enum NotebookExportImageRenderer {
  struct Failure: Error { let message: String }
  static func rasterPDF(_ data: Data) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let fields = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = fields[kCGImagePropertyPixelWidth] as? Int, let height = fields[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 16_777_216,
      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
      throw Failure(message: "PNG/JPEG не декодирован или превышает 16384 px / 16 мегапикселей.")
    }
    let output = NSMutableData()
    var bounds = CGRect(x: 0, y: 0, width: width, height: height)
    guard let consumer = CGDataConsumer(data: output as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
      throw Failure(message: "Не создана поверхность печати изображения.")
    }
    context.beginPDFPage(nil); context.draw(image, in: bounds); context.endPDFPage(); context.closePDF()
    guard output.length <= 8*1024*1024 else { throw Failure(message: "Подготовленное изображение превышает 8 МиБ.") }
    return output as Data
  }
}
