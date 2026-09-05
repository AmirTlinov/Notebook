import AppKit
import Metal
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
  private let device = MTLCreateSystemDefaultDevice()
  private lazy var queue = device?.makeCommandQueue()
  private lazy var ink = pipeline(erase: false)
  private lazy var eraser = pipeline(erase: true)

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
    guard let device, let queue, let ink, let eraser, let command = queue.makeCommandBuffer() else { return nil }
    let width = max(1, min(8192, Int(ceil(size.width * 2))))
    let height = max(1, min(8192, Int(ceil(size.height * 2))))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.renderTarget]
    guard let output = device.makeTexture(descriptor: descriptor) else { return nil }
    let samples = device.supportsTextureSampleCount(4) ? 4 : 1
    let pass = MTLRenderPassDescriptor()
    let color = pass.colorAttachments[0]!
    if samples > 1 {
      descriptor.textureType = .type2DMultisample; descriptor.sampleCount = samples; descriptor.storageMode = .private
      color.texture = device.makeTexture(descriptor: descriptor)
      color.resolveTexture = output; color.storeAction = .multisampleResolve
    } else { color.texture = output; color.storeAction = .store }
    color.loadAction = .clear; color.clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
    encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    for layer in layers {
      var vertices: [SpatialInkGeometry.Vertex] = []
      switch layer {
      case .ink(let points, let color):
        encoder.setRenderPipelineState(ink)
        SpatialInkGeometry.appendStrokeVertices(points: points, color: .init(Float(color.red), Float(color.green), Float(color.blue), 1), to: &vertices)
      case .erase(let points):
        encoder.setRenderPipelineState(eraser)
        SpatialInkGeometry.appendStrokeVertices(points: points, color: .init(1,1,1,1), to: &vertices)
      }
      guard !vertices.isEmpty else { continue }
      let buffer = vertices.withUnsafeBytes { bytes in device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) }
      encoder.setVertexBuffer(buffer, offset: 0, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(width: width, height: height,
      bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
    return NSImage(cgImage: image, size: size)
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

  private func pipeline(erase: Bool) -> (any MTLRenderPipelineState)? {
    guard let device, let library = try? device.makeDefaultLibrary(bundle: .main) else { return nil }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "paperInkVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "paperInkFragment")
    descriptor.rasterSampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
    let color = descriptor.colorAttachments[0]!
    color.pixelFormat = .bgra8Unorm; color.isBlendingEnabled = true
    color.sourceRGBBlendFactor = erase ? .zero : .one
    color.sourceAlphaBlendFactor = erase ? .zero : .one
    color.destinationRGBBlendFactor = .oneMinusSourceAlpha
    color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try? device.makeRenderPipelineState(descriptor: descriptor)
  }
}
