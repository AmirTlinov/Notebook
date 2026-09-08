import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import NotebookCore

/// Immutable GPU resources; each render owns its command buffer and textures.
/// Live InkCanvasView uses the same geometry, shaders, blending and sample count.
final class InkRasterRenderer: @unchecked Sendable {
  static let shared = InkRasterRenderer()
  let device: (any MTLDevice)?
  let queue: (any MTLCommandQueue)?
  let ink: (any MTLRenderPipelineState)?
  let eraser: (any MTLRenderPipelineState)?
  let baseline: (any MTLRenderPipelineState)?

  private init() {
    let device = MTLCreateSystemDefaultDevice()
    self.device = device
    queue = device?.makeCommandQueue()
    func pipeline(erase: Bool = false, raster: Bool = false) -> (any MTLRenderPipelineState)? {
      guard let device, let library = try? device.makeDefaultLibrary(bundle: .main) else {
        return nil
      }
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(
        name: raster ? "stableInkVertex" : "paperInkVertex")
      descriptor.fragmentFunction = library.makeFunction(
        name: raster ? "stableInkFragment" : "paperInkFragment")
      descriptor.rasterSampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
      let color = descriptor.colorAttachments[0]!
      color.pixelFormat = .bgra8Unorm
      color.isBlendingEnabled = true
      color.sourceRGBBlendFactor = erase ? .zero : .one
      color.sourceAlphaBlendFactor = erase ? .zero : .one
      color.destinationRGBBlendFactor = .oneMinusSourceAlpha
      color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      return try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    ink = pipeline()
    eraser = pipeline(erase: true)
    baseline = pipeline(raster: true)
  }

  func page(_ drawing: PageInkDrawing, size: CGSize, scale: Double = 2) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    return render(
      layers: SpatialInkComposer.pageLayers(drawing), size: size, baselinePNG: drawing.baselinePNG,
      scale: scale)
  }

  func render(
    layers: [SpatialInkRenderLayer], size: CGSize, baselinePNG: Data? = nil, scale: Double = 2
  ) -> CGImage? {
    guard !Task.isCancelled, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0, scale.isFinite, scale > 0,
      size.width * scale <= 8192, size.height * scale <= 8192,
      let device, let queue, let ink, let eraser, let baseline,
      let command = queue.makeCommandBuffer()
    else { return nil }
    let width = max(1, Int(ceil(size.width * scale)))
    let height = max(1, Int(ceil(size.height * scale)))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget]
    guard let output = device.makeTexture(descriptor: descriptor) else { return nil }
    let samples = device.supportsTextureSampleCount(4) ? 4 : 1
    let pass = MTLRenderPassDescriptor()
    let color = pass.colorAttachments[0]!
    if samples > 1 {
      descriptor.textureType = .type2DMultisample
      descriptor.sampleCount = samples
      descriptor.storageMode = .private
      color.texture = device.makeTexture(descriptor: descriptor)
      color.resolveTexture = output
      color.storeAction = .multisampleResolve
    } else {
      color.texture = output
      color.storeAction = .store
    }
    color.loadAction = .clear
    color.clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
    if let baselinePNG {
      guard let source = CGImageSourceCreateWithData(baselinePNG as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let texture = try? MTKTextureLoader(device: device).newTexture(
          cgImage: image, options: [.SRGB: false])
      else {
        encoder.endEncoding()
        return nil
      }
      encoder.setRenderPipelineState(baseline)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
    encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    var identity = SIMD4<Float>(1, 1, 0, 0)
    encoder.setVertexBytes(&identity, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
    for layer in layers {
      guard !Task.isCancelled else { encoder.endEncoding(); return nil }
      var vertices: [SpatialInkGeometry.Vertex] = []
      switch layer {
      case .ink(let points, let color):
        encoder.setRenderPipelineState(ink)
        SpatialInkGeometry.appendStrokeVertices(
          points: points, color: .init(Float(color.red), Float(color.green), Float(color.blue), 1),
          to: &vertices)
      case .erase(let points):
        encoder.setRenderPipelineState(eraser)
        SpatialInkGeometry.appendStrokeVertices(
          points: points, color: .init(1, 1, 1, 1), to: &vertices)
      }
      guard !Task.isCancelled else { encoder.endEncoding(); return nil }
      guard !vertices.isEmpty else { continue }
      for chunk in SpatialInkGeometry.chunks(for: vertices)
        where chunk.intersects(viewport: CGRect(origin: .zero, size: size), transform: identity) {
        guard !Task.isCancelled else { encoder.endEncoding(); return nil }
        let buffer = vertices.withUnsafeBytes { bytes in
          device.makeBuffer(bytes: bytes.baseAddress!.advanced(by: chunk.vertices.lowerBound * MemoryLayout<SpatialInkGeometry.Vertex>.stride),
            length: chunk.vertices.count * MemoryLayout<SpatialInkGeometry.Vertex>.stride, options: .storageModeShared)
        }
        guard let buffer else { encoder.endEncoding(); return nil }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: chunk.vertices.count)
      }
    }
    encoder.endEncoding()
    guard !Task.isCancelled else { return nil }
    command.commit()
    command.waitUntilCompleted()
    guard !Task.isCancelled, command.status == .completed else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    output.getBytes(
      &bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: [
        .byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
      ],
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
