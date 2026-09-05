import AppKit
import NotebookCore
import SwiftUI

/// One immutable raster set belongs to one settled export. Live cameras use
/// InkCanvasView; ImageRenderer only reads these already completed pixels.
struct SpatialInkRasterSnapshot: Sendable {
  typealias Surface = WorkspaceSceneProjection.SnapshotInkSurface
  private let images: [Surface: CGImage]

  static func prepare(_ surfaces: [Surface], journal: SpatialInkJournal?) async throws -> Self {
    let worker = Task.detached(priority: .utility) {
      var images: [Surface: CGImage] = [:]
      for surface in Set(surfaces) {
        try Task.checkCancellation()
        let layers: [SpatialInkRenderLayer]
        if let camera = surface.camera {
          layers = SpatialInkComposer.boardLayers(board: surface.surface, journal: journal,
            camera: camera, viewport: surface.viewport)
        } else { layers = SpatialInkComposer.localLayers(for: surface.surface, journal: journal) }
        guard !layers.isEmpty else { continue }
        images[surface] = InkRasterRenderer.shared.render(layers: layers,
          size: .init(width: surface.viewport.x, height: surface.viewport.y))
      }
      return Self(images: images)
    }
    return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
  }

  func raster(for surface: Surface) -> CGImage? { images[surface] }

  func image(for surface: Surface) -> NSImage? {
    images[surface].map { NSImage(cgImage: $0, size: .init(width: surface.viewport.x, height: surface.viewport.y)) }
  }

  static func occupiedRegions(_ image: CGImage, size: CGSize) -> [PageRect] {
    guard let bitmap = CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = bitmap.data else { return [] }
    bitmap.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let cell = 32.0
    let columns = Int(ceil(size.width / cell)), rows = Int(ceil(size.height / cell))
    var cells = Set<Int>()
    let alpha = 3
    for y in 0..<bitmap.height {
      for x in 0..<bitmap.width where bytes[y * bitmap.bytesPerRow + x * 4 + alpha] > 0 {
        let column = min(columns - 1, Int(Double(x) / Double(bitmap.width) * size.width / cell))
        let row = min(rows - 1, Int(Double(y) / Double(bitmap.height) * size.height / cell))
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

private struct SpatialInkRasterSnapshotKey: EnvironmentKey {
  static let defaultValue: SpatialInkRasterSnapshot? = nil
}
extension EnvironmentValues {
  var spatialInkRasterSnapshot: SpatialInkRasterSnapshot? {
    get { self[SpatialInkRasterSnapshotKey.self] }
    set { self[SpatialInkRasterSnapshotKey.self] = newValue }
  }
}
