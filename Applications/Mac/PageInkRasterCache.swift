import AppKit
import NotebookCore

/// A stable page revision owns one raster regardless of camera updates.
@MainActor
final class PageInkRasterCache {
  static let shared = PageInkRasterCache()
  private struct Key: Hashable {
    let id: UUID
    let stamp: VersionStamp
    let width: Double
    let height: Double
  }
  private var images: [Key: CGImage] = [:]
  private var order: [Key] = []

  func image(for page: PageDocument) -> CGImage? {
    let key = Key(
      id: page.id, stamp: page.drawingStamp, width: page.size.width, height: page.size.height)
    if let image = images[key] { return image }
    guard let drawing = try? PageInkDrawing.decode(page.drawingData),
      let image = InkRasterRenderer.shared.page(
        drawing, size: .init(width: page.size.width, height: page.size.height))
    else { return nil }
    images[key] = image
    order.append(key)
    while order.count > 8
      || images.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > 96 * 1024 * 1024
    {
      images.removeValue(forKey: order.removeFirst())
    }
    return image
  }
}
