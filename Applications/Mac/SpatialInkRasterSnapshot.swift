import AppKit
import ImageIO
import NotebookCore

/// Alpha-derived regional map of the common renderer's transparent ink PNG.
/// Painting belongs to Page/SceneCompositionRenderer, not to this proof reader.
struct SpatialInkRasterSnapshot: Sendable {
  let png: Data
  let regions: [PageRect]

  @MainActor
  static func prepare(png: Data, size: CGSize, resources: SceneRenderResources = .shared,
    permitsPreparation: @escaping @MainActor () -> Bool) async throws -> Self {
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size.width * 2 <= 8192, size.height * 2 <= 8192,
      let metadata = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(metadata, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width == Int(ceil(size.width * 2)), height == Int(ceil(size.height * 2)) else {
      throw SceneRenderError.snapshotPending("ink_pixel_dimensions")
    }
    // Decoded CGImage and the alpha-analysis bitmap coexist until the worker
    // completes. Metadata inspection above never decodes that pixel storage.
    guard let allocation = resources.reserveRaster(pixelWidth: width, pixelHeight: height,
      backingCount: 2) else { throw SceneRenderError.resourceLimit }
    defer { allocation.release() }
    let worker = Task.detached(priority: .utility) { () throws -> [PageRect] in
      try Task.checkCancellation()
      guard let source = CGImageSourceCreateWithData(png as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw SceneRenderError.snapshotPending("ink_pixels")
      }
      return try occupiedRegions(image, size: size)
    }
    let regions = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    try Task.checkCancellation()
    guard permitsPreparation() else { throw CancellationError() }
    return Self(png: png, regions: regions)
  }

  static func occupiedRegions(_ image: CGImage, size: CGSize) throws -> [PageRect] {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      let bitmap = CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = bitmap.data else {
      throw SceneRenderError.resourceLimit
    }
    bitmap.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    let cell = 32.0
    let columns = Int(ceil(size.width / cell)), rows = Int(ceil(size.height / cell))
    var cells = Set<Int>()
    let alpha = 3
    for y in 0..<bitmap.height {
      try Task.checkCancellation()
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
