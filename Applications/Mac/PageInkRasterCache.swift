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
  private var pending: [Key: Task<Void, Never>] = [:]

  func image(for page: PageDocument) -> CGImage? {
    let key = Key(
      id: page.id, stamp: page.drawingStamp, width: page.size.width, height: page.size.height)
    return images[key]
  }

  func prepare(_ page: PageDocument) async {
    let key = Key(id: page.id, stamp: page.drawingStamp, width: page.size.width, height: page.size.height)
    guard images[key] == nil else { return }
    if let task = pending[key] { _ = await task.value; return }
    let task = Task { [weak self] in
      let image = await Task.detached(priority: .utility) { () -> CGImage? in
        guard let drawing = try? PageInkDrawing.decode(page.drawingData) else { return nil }
        return InkRasterRenderer.shared.page(drawing, size: .init(width: page.size.width, height: page.size.height))
      }.value
      guard let self else { return }
      pending[key] = nil
      guard let image else { return }
      images[key] = image
      order.append(key)
      while order.count > 8 || images.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > 96 * 1024 * 1024 {
        images.removeValue(forKey: order.removeFirst())
      }
    }
    pending[key] = task
    await task.value
  }
}
