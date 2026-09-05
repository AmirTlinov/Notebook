import AppKit
import NotebookCore

/// Journal revision and projection name an exact raster. Metal consumes the
/// same samples, triangle builder, shaders and alpha eraser as the iPad.
@MainActor
final class SpatialInkRasterCache {
  static let shared = SpatialInkRasterCache()
  private struct Key: Hashable {
    let surface: SurfaceID
    let stamp: VersionStamp
    let camera: SpatialCamera?
    let width: Int
    let height: Int
  }
  private var entries: [Key: NSImage] = [:]
  private var order: [Key] = []

  func image(surface: SurfaceID, journal: SpatialInkJournal?, camera: SpatialCamera?, viewport: SpatialPoint?, size: CGSize) -> NSImage? {
    guard let journal, size.width > 0, size.height > 0 else { return nil }
    let key = Key(surface: surface, stamp: journal.stamp, camera: camera,
      width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)))
    if let image = entries[key] { return image }
    let layers: [SpatialInkRenderLayer]
    if let camera { layers = SpatialInkComposer.boardLayers(board: surface, journal: journal, camera: camera,
      viewport: viewport ?? .init(x: size.width, y: size.height)) }
    else { layers = SpatialInkComposer.localLayers(for: surface, journal: journal) }
    guard let image = render(layers: layers, size: size) else { return nil }
    entries[key] = image; order.append(key)
    while order.count > 24 || order.reduce(0, { $0 + $1.width * $1.height * 4 }) > 128 * 1024 * 1024 {
      entries.removeValue(forKey: order.removeFirst())
    }
    return image
  }

  func render(layers: [SpatialInkRenderLayer], size: CGSize) -> NSImage? {
    InkRasterRenderer.shared.render(layers:layers,size:size).map { NSImage(cgImage:$0,size:size) }
  }

  func occupiedRegions(_ image: NSImage, size: CGSize) -> [PageRect] {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let bytes = bitmap.bitmapData else { return [] }
    let cell = 32.0
    let columns = Int(ceil(size.width / cell)), rows = Int(ceil(size.height / cell))
    var cells = Set<Int>()
    // NSBitmapImageRep canonicalizes the PNG to RGBA; alpha is its fourth sample.
    guard bitmap.samplesPerPixel == 4 else { return [] }
    let alpha = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide where bytes[y * bitmap.bytesPerRow + x * 4 + alpha] > 0 {
        let column = min(columns - 1, Int(Double(x) / Double(bitmap.pixelsWide) * size.width / cell))
        let row = min(rows - 1, Int(Double(y) / Double(bitmap.pixelsHigh) * size.height / cell))
        cells.insert(row * columns + column)
      }
    }
    var result: [PageRect] = []
    for row in 0..<rows {
      var column = 0
      while column < columns {
        guard cells.contains(row * columns + column) else { column += 1; continue }
        let start = column
        while column < columns && cells.contains(row * columns + column) { column += 1 }
        result.append(.init(x: Double(start) * cell, y: Double(row) * cell,
          width: min(Double(column) * cell, size.width) - Double(start) * cell,
          height: min(cell, size.height - Double(row) * cell)))
      }
    }
    return result
  }

}
