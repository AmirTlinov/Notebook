import Foundation
import Metal
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import simd

typealias Point = InkStrokeGeometry.RenderPoint
typealias Vertex = InkStrokeGeometry.Vertex
struct Node { var position: SIMD2<Float>; var previous: UInt32; var next: UInt32; var color: SIMD4<Float> }
struct Uniforms { var viewport: SIMD2<Float>; var nodeCount: UInt32; var indexCount: UInt32 }
enum Mode: String, CaseIterable { case triangles, scalarGPU, tensorGPU, bitShapeGPU }
let out = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else {
    FileHandle.standardError.write(Data(("CHECK FAILED: "+message+"\n").utf8))
    exit(1)
  }
  checks += 1
}
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds)/1e6 }
func normalize(_ input: [Point]) -> [Point] {
  var result: [Point] = []
  for p in input {
    if let last = result.last, InkStrokeGeometry.areCoincident(last,p) { result[result.count-1] = p }
    else { result.append(p) }
  }
  return result
}
struct Dataset {
  let name: String
  let strokes: [[Point]]
  var count: Int { strokes.reduce(0) { $0+$1.count } }
  var points: [Point] { strokes.flatMap { $0 } }
  func mesh() -> [Vertex] {
    var vertices: [Vertex] = []
    for stroke in strokes { InkStrokeGeometry.appendStrokeVertices(renderPoints:stroke,to:&vertices) }
    return vertices
  }
}
struct Topology {
  var nodes: [Node] = []
  var caps: [SIMD2<UInt32>] = []
  var indices: [UInt32] = []
  init(_ data: Dataset) {
    let total = data.count
    nodes.reserveCapacity(total); indices.reserveCapacity(total*6+data.strokes.count*72)
    func cap(_ node: UInt32, kind: UInt32) {
      let base = UInt32(2*total+caps.count*32)
      caps.append(.init(node,kind))
      for i in 0..<(kind == 2 ? 24 : 12) { indices.append(contentsOf:[base,base+1+UInt32(i),base+2+UInt32(i)]) }
    }
    for stroke in data.strokes where !stroke.isEmpty {
      let start = nodes.count
      for (j,p) in stroke.enumerated() {
        nodes.append(.init(position:p.position, previous:UInt32(start+max(0,j-1)),
          next:UInt32(start+min(stroke.count-1,j+1)),color:p.premultipliedColor))
      }
      if stroke.count == 1 { cap(UInt32(start),kind:2); continue }
      for i in start..<(nodes.count-1) {
        let a = UInt32(i*2), b = a+2
        indices.append(contentsOf:[a,a+1,b,a+1,b+1,b])
      }
      cap(UInt32(start),kind:0); cap(UInt32(nodes.count-1),kind:1)
    }
  }
  func vertexReferences() -> [[Int]] {
    var refs = [[Int]](repeating:[],count:nodes.count)
    for (offset,id) in indices.enumerated() {
      let node = id < nodes.count*2 ? id/2 : caps[(Int(id)-nodes.count*2)/32].x
      refs[Int(node)].append(offset)
    }
    return refs
  }
}
final class Prepared {
  let mode: Mode
  let buffers: [MTLBuffer]
  let count: Int
  let nodeCount: Int
  var payloadBytes: Int { buffers.reduce(0) { $0+$1.length } }
  init(_ mode: Mode, _ buffers: [MTLBuffer], count: Int, nodeCount: Int) {
    self.mode=mode; self.buffers=buffers; self.count=count; self.nodeCount=nodeCount
  }
}
struct Timing {
  var cpu: Double; var gpu: Double; var wall: Double
}
final class GPU {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let library: MTLLibrary
  let target: MTLTexture
  let msaa: MTLTexture
  var pipelines: [Mode:MTLRenderPipelineState] = [:]
  var inspectors: [Mode:MTLComputePipelineState] = [:]
  var editors: [Mode:MTLComputePipelineState] = [:]
  let viewport = SIMD2<Float>(1536,1024)
  init() throws {
    guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else { fatalError("Metal unavailable") }
    self.device=device; self.queue=queue
    library=try device.makeLibrary(URL:URL(fileURLWithPath:CommandLine.arguments[1]))
    check(device.supportsTextureSampleCount(4),"4x MSAA required for same production coverage")
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1536,height:1024,mipmapped:false)
    d.storageMode = .shared; d.usage = [.renderTarget]
    target=device.makeTexture(descriptor:d)!
    d.textureType = .type2DMultisample; d.sampleCount=4; d.storageMode = .private
    msaa=device.makeTexture(descriptor:d)!
    for mode in Mode.allCases {
      let descriptor=MTLRenderPipelineDescriptor()
      if mode == .triangles { descriptor.vertexFunction=library.makeFunction(name:"paperInkVertex") }
      else {
        let constants=MTLFunctionConstantValues(); var tensor=mode != .scalarGPU; var bits=mode == .bitShapeGPU
        constants.setConstantValue(&tensor,type:.bool,index:0)
        constants.setConstantValue(&bits,type:.bool,index:1)
        descriptor.vertexFunction=try library.makeFunction(name:"directInkVertex",constantValues:constants)
        inspectors[mode]=try device.makeComputePipelineState(function:library.makeFunction(name:"inspectPositions",constantValues:constants))
        editors[mode]=try device.makeComputePipelineState(function:library.makeFunction(name:mode == .tensorGPU ? "editTensor" : (mode == .bitShapeGPU ? "editBitShape" : "editScalar"))!)
      }
      descriptor.fragmentFunction=library.makeFunction(name:"paperInkFragment")
      descriptor.rasterSampleCount=4
      let c=descriptor.colorAttachments[0]!
      c.pixelFormat = .bgra8Unorm; c.isBlendingEnabled=true
      c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
      c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
      pipelines[mode]=try device.makeRenderPipelineState(descriptor:descriptor)
    }
  }
  func buffer<T>(_ values: [T]) -> MTLBuffer {
    if values.isEmpty { return device.makeBuffer(length:16,options:.storageModeShared)! }
    return values.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)! }
  }
  func prepare(_ data: Dataset, mode: Mode) -> Prepared {
    if mode == .triangles {
      let vertices=data.mesh()
      return Prepared(mode,[buffer(vertices)],count:vertices.count,nodeCount:data.count)
    }
    let topology=Topology(data)
    let radii=data.strokes.flatMap { $0.map(\.radius) }
    let shape:MTLBuffer
    if mode == .scalarGPU { shape=buffer(radii) }
    else if mode == .bitShapeGPU { shape=buffer(radii.map { UInt32(bitPattern:Int32((log2($0)*256).rounded())) & 4095 }) }
    else { shape=buffer(radii.map { SIMD4<Float>($0*$0,0,$0*$0,0) }) }
    return Prepared(mode,[buffer(topology.nodes),shape,buffer(topology.caps),buffer(topology.indices)],count:topology.indices.count,nodeCount:topology.nodes.count)
  }
  func uniform(_ state: Prepared) -> Uniforms { .init(viewport:viewport,nodeCount:UInt32(state.nodeCount),indexCount:UInt32(state.count)) }
  func encodeEdits(_ edits: [SIMD4<UInt32>], state: Prepared, command: MTLCommandBuffer) {
    precondition(Set(edits.map(\.x)).count == edits.count,"duplicate addressed writes in a dispatch")
    precondition(edits.allSatisfy { $0.x < state.nodeCount && $0.y <= 2 && $0.z <= 1 && $0.w <= 16 })
    precondition(state.mode != .scalarGPU || edits.allSatisfy { $0.y == 0 })
    precondition(state.mode != .bitShapeGPU || edits.allSatisfy { $0.y != 0 || $0.w <= 8 },"pressure step below packed precision")
    let encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(editors[state.mode]!)
    encoder.setBuffer(state.buffers[1],offset:0,index:0)
    encoder.setBuffer(state.buffers[0],offset:0,index:1)
    edits.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:2) }
    var count=UInt32(edits.count); encoder.setBytes(&count,length:4,index:3)
    encoder.dispatchThreads(.init(width:edits.count,height:1,depth:1),threadsPerThreadgroup:.init(width:min(64,edits.count),height:1,depth:1))
    encoder.endEncoding()
  }
  func encodeDraw(_ state: Prepared, command: MTLCommandBuffer, target: MTLTexture? = nil) {
    let pass=MTLRenderPassDescriptor(); let attachment=pass.colorAttachments[0]!
    attachment.texture=msaa; attachment.resolveTexture=target ?? self.target
    attachment.loadAction = .clear; attachment.storeAction = .multisampleResolve
    attachment.clearColor=MTLClearColorMake(0,0,0,0)
    let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
    encoder.setRenderPipelineState(pipelines[state.mode]!)
    if state.mode == .triangles {
      var viewport=viewport, transform=SIMD4<Float>(1,1,0,0)
      encoder.setVertexBuffer(state.buffers[0],offset:0,index:0)
      encoder.setVertexBytes(&viewport,length:8,index:1); encoder.setVertexBytes(&transform,length:16,index:2)
      if state.count > 0 { encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:state.count) }
    } else {
      for i in 0..<3 { encoder.setVertexBuffer(state.buffers[i],offset:0,index:i) }
      var u=uniform(state); encoder.setVertexBytes(&u,length:MemoryLayout<Uniforms>.stride,index:3)
      if state.count > 0 { encoder.drawIndexedPrimitives(type:.triangle,indexCount:state.count,indexType:.uint32,indexBuffer:state.buffers[3],indexBufferOffset:0) }
    }
    encoder.endEncoding()
  }
  func complete(_ command: MTLCommandBuffer) {
    command.waitUntilCompleted()
    check(command.status == .completed,"GPU failed: \(String(describing:command.error))")
  }
  func run(_ state: Prepared, edits: [SIMD4<UInt32>] = [], cpuEdit: (() -> Void)? = nil) -> Timing {
    let start=now(); cpuEdit?()
    let command=queue.makeCommandBuffer()!
    if !edits.isEmpty { encodeEdits(edits,state:state,command:command) }
    encodeDraw(state,command:command)
    command.commit(); let submitted=now()
    complete(command); let finished=now()
    check(command.gpuEndTime > command.gpuStartTime && command.gpuStartTime > 0,"GPU timestamps unavailable")
    return .init(cpu:submitted-start,gpu:(command.gpuEndTime-command.gpuStartTime)*1000,wall:finished-start)
  }
  func editOnly(_ state: Prepared, batches: [[SIMD4<UInt32>]]) {
    let command=queue.makeCommandBuffer()!
    for batch in batches { encodeEdits(batch,state:state,command:command) }
    command.commit(); complete(command)
  }
  func inspect(_ state: Prepared) -> [SIMD2<Float>] {
    if state.count == 0 { return [] }
    let result=device.makeBuffer(length:state.count*8,options:.storageModeShared)!
    let command=queue.makeCommandBuffer()!, encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(inspectors[state.mode]!)
    for i in 0..<3 { encoder.setBuffer(state.buffers[i],offset:0,index:i) }
    var u=uniform(state); encoder.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:3)
    encoder.setBuffer(state.buffers[3],offset:0,index:4); encoder.setBuffer(result,offset:0,index:5)
    encoder.dispatchThreads(.init(width:state.count,height:1,depth:1),threadsPerThreadgroup:.init(width:64,height:1,depth:1))
    encoder.endEncoding(); command.commit(); complete(command)
    return Array(UnsafeBufferPointer(start:result.contents().assumingMemoryBound(to:SIMD2<Float>.self),count:state.count))
  }
  func pixels() -> [UInt8] {
    var bytes=[UInt8](repeating:0,count:1536*1024*4)
    target.getBytes(&bytes,bytesPerRow:1536*4,from:MTLRegionMake2D(0,0,1536,1024),mipmapLevel:0)
    return bytes
  }
  func savePNG(_ name: String) {
    let bytes=pixels()
    let provider=CGDataProvider(data:Data(bytes) as CFData)!
    let image=CGImage(width:1536,height:1024,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:1536*4,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
      provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let dest=CGImageDestinationCreateWithURL(out.appendingPathComponent(name).appendingPathExtension("png") as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(dest,image,nil); check(CGImageDestinationFinalize(dest),"PNG export")
  }
}
