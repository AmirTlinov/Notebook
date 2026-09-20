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
  let connectivity: InkConnectivity?

  private init() {
    let device = MTLCreateSystemDefaultDevice()
    self.device = device
    queue = device?.makeCommandQueue()
    connectivity = device.flatMap(InkConnectivity.init(device:))
    func pipeline(erase: Bool = false, raster: Bool = false) -> (any MTLRenderPipelineState)? {
      guard let device, let library = try? device.makeDefaultLibrary(bundle: .main) else {
        return nil
      }
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(
        name: raster ? "stableInkVertex" : "compactInkVertex")
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
    let mesh = SpatialInkMesh.local(layers)
    return render(mesh:mesh,size:size,baselinePNG:baselinePNG,scale:scale)
  }

  func render(mesh: SpatialInkMesh, size: CGSize, baselinePNG: Data? = nil,
    scale: Double = 2, affine: InkAffine = .init()) -> CGImage? {
    raster(size:size,baselinePNG:baselinePNG,scale:scale,
      batches:mesh.batches.map { .init(mesh:$0,affine:affine) })
  }

  private struct DrawBatch {
    let mesh: SpatialInkMesh.Batch
    let affine: InkAffine
  }

  /// Pixels are replaceable output. Query the immutable vector hierarchy BEFORE
  /// reading source vertices; whole transforms never rebuild that hierarchy.
  func freehand(_ ink: NotebookFreehand, transform: NotebookGraphicTransform?, size: CGSize,
    region: CGRect, scale: Double, mask: Bool) -> CGImage? {
    guard size.width > 0, size.height > 0, scale > 0 else { return nil }
    let source = ink.geometry, basis = transform ?? .identity
    let area = NotebookFreehandGeometry.sourceBounds(region.insetBy(dx:-1/scale,dy:-1/scale),
      size:size,transform:transform)
    let batches = source.index.query(area).indices.map { id -> DrawBatch in
      let chunk = source.chunks[id], unit = chunk.sourceSize
      let affine = InkAffine(
        x:.init(Float(basis.a*size.width/unit.width),Float(basis.c*size.width/unit.height),
          Float(basis.tx*size.width-region.minX),0),
        y:.init(Float(basis.b*size.height/unit.width),Float(basis.d*size.height/unit.height),
          Float(basis.ty*size.height-region.minY),0))
      let color = mask || source.tool(at:id) == .eraser ? SpatialInkColor(red:1,green:1,blue:1) : source.color(at:id)
      let nodes = source.nodes(at:id)
      let c = SpatialInkGeometry.Chunk(nodes:0..<nodes.count,bounds:InkRenderGeometry.bounds(nodes[...]),
        color:.init(Float(color.red),Float(color.green),Float(color.blue),1),flags:chunk.flags)
      return .init(mesh:.init(tool:source.tool(at:id),nodes:nodes,chunks:[c],projection:.local),affine:affine)
    }
    return raster(size:region.size,baselinePNG:nil,scale:scale,batches:batches)
  }

  private func raster(
    size: CGSize, baselinePNG: Data?, scale: Double,
    batches: [DrawBatch]
  ) -> CGImage? {
    guard !Task.isCancelled, size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0, scale.isFinite, scale > 0,
      size.width * scale <= 8192, size.height * scale <= 8192,
      let device, let queue, let ink, let eraser, let baseline, let connectivity,
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
      var textureRect = SIMD4<Float>(0, 0, 1, 1)
      encoder.setVertexBytes(&textureRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    var viewport = SIMD2<Float>(Float(size.width), Float(size.height))
    encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    let area = CGRect(origin: .zero, size: size).insetBy(dx: -1 / scale, dy: -1 / scale)
    for draw in batches {
      guard !Task.isCancelled else { encoder.endEncoding(); return nil }
      let batch = draw.mesh
      var affine = draw.affine
      let stretch = affine.maximumStretch
      encoder.setVertexBytes(&affine,length:MemoryLayout<InkAffine>.stride,index:2)
      encoder.setRenderPipelineState(batch.tool == .eraser ? eraser : ink)
      for id in batch.query(viewport:area,affine:affine).chunks {
        let prepared=batch.prepareChunk(id).chunk,chunk=prepared.descriptor
        let level=InkRenderGeometry.level(chunk.levels,pixelsPerUnit:stretch*Float(scale))
        let nodes=prepared.selected(level:level)
        guard !nodes.isEmpty else { continue }
        guard
          let buffer = nodes.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
          })
        else { encoder.endEncoding(); return nil }
        var primitive = InkPrimitive(
          count: UInt32(nodes.count), flags: chunk.flags, color: chunk.color)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&primitive, length: MemoryLayout<InkPrimitive>.stride, index: 3)
        connectivity.draw(nodes: nodes.count, flags: chunk.flags, encoder: encoder)
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
