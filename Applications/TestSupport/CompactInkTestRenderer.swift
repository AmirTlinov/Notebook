import Foundation
import Metal

#if canImport(NotebookCore)
  import NotebookCore
  @testable import Notebook
#endif

/// Test-only reference: canonical CPU triangles versus the actual app shader.
final class CompactInkTestRenderer {
  struct Draw {
    let buffer: MTLBuffer
    let count: Int
    let flags: UInt32
    let color: SIMD4<Float>
    let compact: Bool
  }
  let device: MTLDevice
  let queue: MTLCommandQueue
  let output: MTLTexture
  let msaa: MTLTexture
  let connectivity: InkConnectivity
  let pipelines: [MTLRenderPipelineState]
  init(library: MTLLibrary? = nil) throws {
    device = MTLCreateSystemDefaultDevice()!
    queue = device.makeCommandQueue()!
    connectivity = InkConnectivity(device: device)!
    let app = try library ?? device.makeDefaultLibrary(bundle: .main)
    let reference = try device.makeLibrary(
      source: """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float2 p; float4 c; };
        struct O { float4 position [[position]]; float4 premultipliedColor; };
        vertex O referenceInk(device const V *v [[buffer(0)]], constant float2 &size [[buffer(1)]],
          constant float4 *a [[buffer(2)]], uint id [[vertex_id]]) {
          float2 p=v[id].p;
          float2 q=float2(dot(a[0].xy,p)+a[0].z,dot(a[1].xy,p)+a[1].z)/size;
          return {float4(2*q.x-1,1-2*q.y,0,1),v[id].c};
        }
        """, options: nil)
    var states: [MTLRenderPipelineState] = []
    for compact in [false, true] {
      for erase in [false, true] {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction =
          compact
          ? app.makeFunction(name: "compactInkVertex")
          : reference.makeFunction(name: "referenceInk")
        descriptor.fragmentFunction = app.makeFunction(name: "paperInkFragment")
        descriptor.rasterSampleCount = 4
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = erase ? .zero : .one
        color.sourceAlphaBlendFactor = erase ? .zero : .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        states.append(try device.makeRenderPipelineState(descriptor: descriptor))
      }
    }
    pipelines = states
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: 1024, height: 768, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .renderTarget
    output = device.makeTexture(descriptor: descriptor)!
    descriptor.textureType = .type2DMultisample
    descriptor.sampleCount = 4
    descriptor.storageMode = .private
    msaa = device.makeTexture(descriptor: descriptor)!
  }
  func buffer<T>(_ values: [T]) -> MTLBuffer {
    values.withUnsafeBytes {
      device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
    }
  }
  func prepare(
    _ points: [InkStrokeGeometry.RenderPoint], color: SIMD4<Float>, eraser: Bool = false,
    compact: Bool, lodScale: Float? = nil
  ) -> [Draw] {
    guard !points.isEmpty else { return [] }
    let allNodes = compact ? points.indices.map { InkRenderGeometry.node(at: $0, in: points) } : []
    var canonical: [InkStrokeGeometry.Vertex] = []
    if !compact {
      if eraser {
        InkStrokeGeometry.appendEraserVertices(renderPoints: points, to: &canonical)
      } else {
        InkStrokeGeometry.appendStrokeVertices(renderPoints: points, to: &canonical)
      }
    }
    let last = points.count - 1
    var result: [Draw] = []
    for start in stride(from: 0, to: max(1, last), by: InkRenderGeometry.maximumSegments) {
      let end = min(last, start + InkRenderGeometry.maximumSegments)
      let flags: UInt32 = (start == 0 ? 1 : 0) | (end == last ? 2 : 0) | (eraser ? 4 : 0)
      if compact {
        var nodes = Array(allNodes[start...end])
        if let lodScale {
          let levels = InkRenderGeometry.levels(nodes[...], flags: flags)
          let level = InkRenderGeometry.level(levels, pixelsPerUnit: lodScale, minimumPixelsPerUnit: abs(lodScale))
          if level >= 0 { nodes = levels[level].indices.map { nodes[Int($0)] } }
        }
        result.append(
          .init(
            buffer: buffer(nodes), count: nodes.count, flags: flags, color: color, compact: true))
      } else {
        // Slice the canonical tessellator; no duplicate geometry preparation.
        if eraser || points.count == 1 {
          return [
            .init(
              buffer: buffer(canonical), count: canonical.count, flags: flags, color: color,
              compact: false)
          ]
        }
        var vertices = Array(canonical[(start * 6)..<(end * 6)])
        if start == 0 { vertices.append(contentsOf: canonical.suffix(72).prefix(36)) }
        if end == last { vertices.append(contentsOf: canonical.suffix(36)) }
        result.append(
          .init(
            buffer: buffer(vertices), count: vertices.count, flags: flags, color: color,
            compact: false))
      }
    }
    return result
  }
  func run(_ draws: [Draw], affine: InkAffine = .init()) throws -> (gpu: Double, wall: Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let command = queue.makeCommandBuffer()!
    let pass = MTLRenderPassDescriptor()
    let attachment = pass.colorAttachments[0]!
    attachment.texture = msaa
    attachment.resolveTexture = output
    attachment.loadAction = .clear
    attachment.storeAction = .multisampleResolve
    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
    var viewport = SIMD2<Float>(1024, 768)
    var affine = affine
    encoder.setVertexBytes(&viewport, length: 8, index: 1)
    encoder.setVertexBytes(&affine, length: 32, index: 2)
    for draw in draws {
      encoder.setRenderPipelineState(
        pipelines[(draw.compact ? 2 : 0) + (draw.flags & 4 != 0 ? 1 : 0)])
      encoder.setVertexBuffer(draw.buffer, offset: 0, index: 0)
      var primitive = InkPrimitive(count: UInt32(draw.count), flags: draw.flags, color: draw.color)
      encoder.setVertexBytes(&primitive, length: 32, index: 3)
      if draw.compact {
        connectivity.draw(nodes: draw.count, flags: draw.flags, encoder: encoder)
      } else {
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.count)
      }
    }
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
    return (
      (command.gpuEndTime - command.gpuStartTime) * 1000,
      (ProcessInfo.processInfo.systemUptime - start) * 1000
    )
  }
  func pixels() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 1024 * 768 * 4)
    output.getBytes(
      &bytes, bytesPerRow: 4096,
      from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1024, height: 768, depth: 1)),
      mipmapLevel: 0)
    return bytes
  }
}
