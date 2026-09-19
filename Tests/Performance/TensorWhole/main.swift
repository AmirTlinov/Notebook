import Foundation
import Metal
import simd

struct Space {
  var x:SIMD4<Float>,y:SIMD4<Float>
  static let identity=Space(x:.init(1,0,0,0),y:.init(0,1,0,0))
  static func around(_ a:simd_float2x2,_ pivot:SIMD2<Float>) -> Space {
    let t=pivot-a*pivot
    return .init(x:.init(a[0].x,a[1].x,t.x,0),y:.init(a[0].y,a[1].y,t.y,0))
  }
  var linear:simd_double2x2 { .init(.init(Double(x.x),Double(y.x)),.init(Double(x.y),Double(y.y))) }
  var offset:SIMD2<Double> { .init(Double(x.z),Double(y.z)) }
}
let pivot=SIMD2<Float>(768,512)
let stretch=Space.around(.init(diagonal:.init(2,1)),pivot)
let unstretch=Space.around(.init(diagonal:.init(0.5,1)),pivot)
let angle=Float.pi/4,c=cos(angle),s=sin(angle)
let rotate=Space.around(.init(.init(c,s),.init(-s,c)),pivot)
let unrotate=Space.around(.init(.init(c,-s),.init(s,c)),pivot)
let cycle=[stretch,rotate,unrotate,unstretch]
struct Group { let nodes:Range<Int>,indices:Range<Int> }
final class Scene {
  let gpu:GPU,local:Prepared,world:Prepared,spaces:MTLBuffer
  let groups:[Group]
  let pipeline:MTLRenderPipelineState,editor:MTLComputePipelineState,materializer:MTLComputePipelineState
  let initializer:MTLComputePipelineState,inspector:MTLComputePipelineState
  init(_ gpu:GPU,_ data:Dataset,firstGroupStrokes:Int?=nil,packed:Bool=true) throws {
    self.gpu=gpu
    local=gpu.prepare(data,mode:packed ? .bitShapeGPU:.tensorGPU);world=gpu.prepare(data,mode:.tensorGPU)
    var groups:[Group]=[],startNode=0,startIndex=0,n=0,k=0
    for (i,stroke) in data.strokes.enumerated() {
      n+=stroke.count;k += stroke.isEmpty ? 0:(stroke.count == 1 ? 72:(stroke.count-1)*6+72)
      if i+1 == firstGroupStrokes || i+1 == data.strokes.count {
        groups.append(.init(nodes:startNode..<n,indices:startIndex..<k));startNode=n;startIndex=k
      }
    }
    self.groups=groups
    spaces=gpu.buffer([Space](repeating:.identity,count:groups.count))
    let constants=MTLFunctionConstantValues();var yes=true,bits=packed
    constants.setConstantValue(&yes,type:.bool,index:0);constants.setConstantValue(&bits,type:.bool,index:1)
    let d=MTLRenderPipelineDescriptor()
    d.vertexFunction=try gpu.library.makeFunction(name:"wholeInkVertex",constantValues:constants)
    d.fragmentFunction=gpu.library.makeFunction(name:"paperInkFragment");d.rasterSampleCount=4
    let a=d.colorAttachments[0]!
    a.pixelFormat = .bgra8Unorm;a.isBlendingEnabled=true
    a.sourceRGBBlendFactor = .one;a.sourceAlphaBlendFactor = .one
    a.destinationRGBBlendFactor = .oneMinusSourceAlpha;a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    pipeline=try gpu.device.makeRenderPipelineState(descriptor:d)
    editor=try gpu.device.makeComputePipelineState(function:gpu.library.makeFunction(name:"updateWholeSpace")!)
    materializer=try gpu.device.makeComputePipelineState(function:gpu.library.makeFunction(name:"materializeWholeEdit")!)
    initializer=try gpu.device.makeComputePipelineState(function:gpu.library.makeFunction(name:"initializeWorldShapes")!)
    inspector=try gpu.device.makeComputePipelineState(function:gpu.library.makeFunction(name:"inspectWholePositions",constantValues:constants))
    reset()
  }
  func reset() {
    let p=spaces.contents().assumingMemoryBound(to:Space.self)
    for i in groups.indices { p[i] = .identity }
    let command=gpu.queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!
    blit.copy(from:local.buffers[0],sourceOffset:0,to:world.buffers[0],destinationOffset:0,size:local.buffers[0].length)
    if local.mode == .tensorGPU {
      blit.copy(from:local.buffers[1],sourceOffset:0,to:world.buffers[1],destinationOffset:0,size:local.buffers[1].length)
    }
    blit.endEncoding()
    if local.mode == .bitShapeGPU {
      let encoder=command.makeComputeCommandEncoder()!
      encoder.setComputePipelineState(initializer)
      encoder.setBuffer(local.buffers[1],offset:0,index:0);encoder.setBuffer(world.buffers[1],offset:0,index:1)
      encoder.dispatchThreads(.init(width:local.nodeCount,height:1,depth:1),threadsPerThreadgroup:.init(width:64,height:1,depth:1))
      encoder.endEncoding()
    }
    command.commit();gpu.complete(command)
  }
  func run(whole:Bool,delta:Space?=nil,draw:Bool=true,group:Int=0) -> Timing {
    let start=now(),command=gpu.queue.makeCommandBuffer()!
    if var delta {
      let encoder=command.makeComputeCommandEncoder()!
      encoder.setComputePipelineState(whole ? editor:materializer)
      encoder.setBytes(&delta,length:32,index:2)
      let count:Int
      if whole { encoder.setBuffer(spaces,offset:group*32,index:0);count=1 }
      else {
        encoder.setBuffer(world.buffers[0],offset:0,index:0);encoder.setBuffer(world.buffers[1],offset:0,index:1)
        var range=SIMD2<UInt32>(UInt32(groups[group].nodes.lowerBound),UInt32(groups[group].nodes.count))
        encoder.setBytes(&range,length:8,index:3);count=groups[group].nodes.count
      }
      encoder.dispatchThreads(.init(width:count,height:1,depth:1),threadsPerThreadgroup:.init(width:min(64,count),height:1,depth:1))
      encoder.endEncoding()
    }
    if draw {
      if !whole { gpu.encodeDraw(world,command:command) }
      else {
        let pass=MTLRenderPassDescriptor(),a=pass.colorAttachments[0]!
        a.texture=gpu.msaa;a.resolveTexture=gpu.target;a.loadAction = .clear;a.storeAction = .multisampleResolve
        a.clearColor=MTLClearColorMake(0,0,0,0)
        let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
        encoder.setRenderPipelineState(pipeline)
        for i in 0..<3 { encoder.setVertexBuffer(local.buffers[i],offset:0,index:i) }
        var u=gpu.uniform(local);encoder.setVertexBytes(&u,length:16,index:3)
        for (i,group) in groups.enumerated() {
          encoder.setVertexBuffer(spaces,offset:i*32,index:4)
          encoder.drawIndexedPrimitives(type:.triangle,indexCount:group.indices.count,indexType:.uint32,
            indexBuffer:local.buffers[3],indexBufferOffset:group.indices.lowerBound*4)
        }
        encoder.endEncoding()
      }
    }
    command.commit();let submitted=now();gpu.complete(command);let end=now()
    check(command.gpuEndTime > command.gpuStartTime,"GPU timestamp")
    return .init(cpu:submitted-start,gpu:(command.gpuEndTime-command.gpuStartTime)*1000,wall:end-start)
  }
  func inspect() -> [SIMD2<Float>] {
    let output=gpu.device.makeBuffer(length:local.count*8,options:.storageModeShared)!
    let command=gpu.queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(inspector)
    for i in 0..<3 { encoder.setBuffer(local.buffers[i],offset:0,index:i) }
    encoder.setBuffer(output,offset:0,index:6)
    for (i,group) in groups.enumerated() {
      var u=gpu.uniform(local);u.indexCount=UInt32(group.indices.count)
      encoder.setBytes(&u,length:16,index:3);encoder.setBuffer(spaces,offset:i*32,index:4)
      encoder.setBuffer(local.buffers[3],offset:group.indices.lowerBound*4,index:5)
      encoder.setBuffer(output,offset:group.indices.lowerBound*8,index:6)
      encoder.dispatchThreads(.init(width:group.indices.count,height:1,depth:1),threadsPerThreadgroup:.init(width:64,height:1,depth:1))
    }
    encoder.endEncoding();command.commit();gpu.complete(command)
    return Array(UnsafeBufferPointer(start:output.contents().assumingMemoryBound(to:SIMD2<Float>.self),count:local.count))
  }
}
func synthetic(_ count:Int) -> Dataset {
  precondition(count%250 == 0)
  return .init(name:"synthetic-\(count)",strokes:(0..<(count/250)).map { j in
    (0..<250).map { i in
      let t=Float(i)/249,alpha:Float=0.32
      return Point(position:.init(608+t*320,365+Float(j%40)*7+18*sin(t*9+Float(j)*0.19)),
        radius:1+0.5*sin(t*6),premultipliedColor:.init(alpha*Float(j%3)/3,0.1,0.2,alpha))
    }
  })
}
func metrics(_ a:[Double]) -> [String:Any] {
  let b=a.sorted(),n=b.count
  return ["median_ms":(b[(n-1)/2]+b[n/2])/2,"p95_ms":b[Int(ceil(Double(n)*0.95))-1],"samples_ms":a]
}
func times(_ a:[Timing]) -> [String:Any] {
  ["cpu_submit":metrics(a.map(\.cpu)),"gpu":metrics(a.map(\.gpu)),"wall":metrics(a.map(\.wall))]
}
func bytes(_ b:MTLBuffer) -> Data { Data(bytes:b.contents(),count:b.length) }
func compare(_ a:[UInt8],_ b:[UInt8]) -> [String:Any] {
  var sum:Double=0,n=0,differing=0,maximum=0
  for i in stride(from:0,to:a.count,by:4) {
    var d=0
    for c in 0..<4 { let x=abs(Int(a[i+c])-Int(b[i+c]));sum+=Double(x*x);d=max(d,x) }
    if a[i+3] > 0 || b[i+3] > 0 { n+=1 };if d > 2 { differing+=1 };maximum=max(maximum,d)
  }
  let rmse=sqrt(sum/Double(a.count))/255,fraction=Double(differing)/Double(max(1,n))
  check(rmse <= 0.003 && fraction <= 0.01,"whole/eager pixels: \(rmse), \(fraction)")
  return ["rgba_rmse":rmse,"difference_over_2_fraction_occupied":fraction,"differing_pixels":differing,"maximum_channel_error":maximum]
}
let gpu=try GPU()
check(MemoryLayout<Space>.stride == 32,"affine layout")
var benchmarks:[[String:Any]]=[],quality:[[String:Any]]=[]
for (n,packed) in [(1_000,true),(10_000,true),(100_000,true),(1_000_000,true),(1_000_000,false)] {
  try autoreleasepool {
    let scene=try Scene(gpu,synthetic(n),packed:packed)
    for task in ["edit-only","cached-draw","edit-and-draw"] {
      scene.reset()
      if task == "cached-draw" {
        for delta in [stretch,rotate] { _=scene.run(whole:false,delta:delta,draw:false);_=scene.run(whole:true,delta:delta,draw:false) }
      }
      var eager:[Timing]=[],whole:[Timing]=[]
      for i in 0..<36 {
        let delta=task == "cached-draw" ? nil:cycle[i%4],draw=task != "edit-only"
        let a:Timing,b:Timing
        if i%2 == 0 { a=scene.run(whole:false,delta:delta,draw:draw);b=scene.run(whole:true,delta:delta,draw:draw) }
        else { b=scene.run(whole:true,delta:delta,draw:draw);a=scene.run(whole:false,delta:delta,draw:draw) }
        if i >= 4 { eager.append(a);whole.append(b) }
        if task == "edit-and-draw" && (i == 1 || i == 35) {
          _=scene.run(whole:false);let expected=gpu.pixels();_=scene.run(whole:true)
          quality.append(["case":n,"local_shape":packed ? "packed":"float32_control","step":i,"comparison":compare(expected,gpu.pixels())])
        }
      }
      benchmarks.append(["nodes":n,"local_shape":packed ? "packed":"float32_control","scenario":task,"eager":times(eager),"whole":times(whole),
        "eager_geometry_bytes":scene.world.payloadBytes,"whole_geometry_bytes":scene.local.payloadBytes+scene.spaces.length,
        "eager_logical_write_bytes_per_edit":n*24,"whole_logical_write_bytes_per_edit":32,
        "eager_edited_records":n,"whole_edited_records":1,"indices_drawn":scene.local.count])
      print(String(format:"%d %@ %@ GPU %.4f -> %.4f wall %.4f -> %.4f",n,packed ? "packed":"float32",task,
        metrics(eager.map(\.gpu))["median_ms"] as! Double,metrics(whole.map(\.gpu))["median_ms"] as! Double,
        metrics(eager.map(\.wall))["median_ms"] as! Double,metrics(whole.map(\.wall))["median_ms"] as! Double))
    }
  }
}

// Small, independently inspectable two-group case; group boundaries are between
// complete strokes, never through a stroke's neighbour/miter dependency.
let fixture=Dataset(name:"two-groups",strokes:[
  (0..<80).map { i in Point(position:.init(650+Float(i)*2.2,430+38*sin(Float(i)/14)),radius:4,premultipliedColor:.init(0.45,0.05,0.04,0.6)) },
  (0..<70).map { i in Point(position:.init(730+22*sin(Float(i)/11),400+Float(i)*2.1),radius:3,premultipliedColor:.init(0.03,0.12,0.42,0.55)) },
  [Point(position:.init(870,570),radius:9,premultipliedColor:.init(0.04,0.42,0.08,0.65))],
  (0..<60).map { i in Point(position:.init(100+Float(i)*2.3,150+24*sin(Float(i)/9)),radius:5,premultipliedColor:.init(0.15,0.05,0.4,0.5)) }
])
let scene=try Scene(gpu,fixture,firstGroupStrokes:3)
let localBefore=scene.local.buffers.map(bytes),initialShapes=bytes(scene.world.buffers[1])
let worldBefore=scene.world.buffers.map(bytes)
let initialPositions=scene.inspect()
_=scene.run(whole:true);let initialImage=gpu.pixels();gpu.savePNG("before")
var a=matrix_identity_double2x2,t=SIMD2<Double>(repeating:0)
var maxCenter:Double=0,maxQ:Double=0,maxVertex:Float=0,rows:[[String:Any]]=[]
for (step,delta) in cycle.enumerated() {
  _=scene.run(whole:false,delta:delta);let expected=gpu.pixels()
  _=scene.run(whole:true,delta:delta);let image=gpu.pixels()
  let pixel=compare(expected,image)
  a=delta.linear*a;t=delta.linear*t+delta.offset
  let state=scene.spaces.contents().assumingMemoryBound(to:Space.self)[0]
  let nodes=scene.local.buffers[0].contents().assumingMemoryBound(to:Node.self)
  let worldNodes=scene.world.buffers[0].contents().assumingMemoryBound(to:Node.self)
  let tensors=scene.world.buffers[1].contents().assumingMemoryBound(to:SIMD4<Float>.self)
  let q0=initialShapes.withUnsafeBytes { Array($0.bindMemory(to:SIMD4<Float>.self)) }
  for id in scene.groups[0].nodes {
    let p=SIMD2<Double>(Double(nodes[id].position.x),Double(nodes[id].position.y)),expectedCenter=a*p+t
    let actual=state.linear*p+state.offset
    maxCenter=max(maxCenter,simd_length(actual-expectedCenter))
    maxCenter=max(maxCenter,simd_length(SIMD2<Double>(Double(worldNodes[id].position.x),Double(worldNodes[id].position.y))-expectedCenter))
    let base=simd_double2x2(.init(Double(q0[id].x),Double(q0[id].y)),.init(Double(q0[id].y),Double(q0[id].z)))
    let q=a*base*a.transpose,visible=state.linear*base*state.linear.transpose
    let world=simd_double2x2(.init(Double(tensors[id].x),Double(tensors[id].y)),.init(Double(tensors[id].y),Double(tensors[id].z)))
    for j in 0..<2 { maxQ=max(maxQ,simd_length(q[j]-visible[j]),simd_length(q[j]-world[j])) }
    check(simd_determinant(visible) > 0,"positive shape")
  }
  let eagerVertices=gpu.inspect(scene.world),wholeVertices=scene.inspect()
  for (x,y) in zip(eagerVertices,wholeVertices) { maxVertex=max(maxVertex,simd_length(x-y)) }
  check(maxVertex < 0.03,"contour tolerance \(maxVertex)")
  check(maxCenter < 0.002 && maxQ < 0.002,"independent Double oracle")
  check(scene.local.buffers.map(bytes) == localBefore,"whole does not modify local geometry or shapes")
  check(scene.spaces.contents().assumingMemoryBound(to:Space.self)[1].x == Space.identity.x &&
    scene.spaces.contents().assumingMemoryBound(to:Space.self)[1].y == Space.identity.y,"other group state unchanged")
  let other=scene.groups[1].nodes
  check(bytes(scene.world.buffers[0]).subdata(in:other.lowerBound*32..<other.upperBound*32) == worldBefore[0].subdata(in:other.lowerBound*32..<other.upperBound*32),"unselected world nodes")
  check(bytes(scene.world.buffers[1]).subdata(in:other.lowerBound*16..<other.upperBound*16) == worldBefore[1].subdata(in:other.lowerBound*16..<other.upperBound*16),"unselected tensors")
  for i in scene.groups[1].indices { check(wholeVertices[i] == initialPositions[i],"unselected contour") }
  rows.append(["step":step,"comparison":pixel])
  if step == 1 { gpu.savePNG("stretch-then-rotate") }
}
let inverseVertices=scene.inspect()
let inverseError=zip(initialPositions,inverseVertices).map { simd_length($0-$1) }.max()!
check(inverseError < 0.01,"inverse drift")
_=scene.run(whole:true);let inversePixels=compare(initialImage,gpu.pixels());gpu.savePNG("restored")
scene.reset();_=scene.run(whole:true,delta:stretch);_=scene.run(whole:true,delta:rotate);let sr=scene.inspect()
scene.reset();_=scene.run(whole:true,delta:rotate);_=scene.run(whole:true,delta:stretch);let rs=scene.inspect()
let orderDistance=zip(sr,rs).map { simd_length($0-$1) }.max()!
check(orderDistance > 20,"negative control: operation order must matter")
gpu.savePNG("rotate-then-stretch")
// Repeated editing checks local immutability and quantifies Float32 accumulation.
scene.reset()
for i in 0..<256 { _=scene.run(whole:true,delta:cycle[i%4],draw:false) }
let repeated=scene.inspect(),drift=zip(initialPositions,repeated).map { simd_length($0-$1) }.max()!
check(drift < 0.1,"256-action drift \(drift)")
check(scene.local.buffers.map(bytes) == localBefore,"immutable local representation after 256 actions")
quality.append(["case":"two-groups","steps":rows,"max_center_error_double":maxCenter,"max_q_error_double":maxQ,
  "max_whole_eager_vertex_error":maxVertex,"inverse_vertex_error":inverseError,"inverse_pixels":inversePixels,
  "wrong_order_max_vertex_distance":orderDistance,"after_256_actions_vertex_drift":drift])
let receipt:[String:Any]=["schema":1,"date":ISO8601DateFormatter().string(from:Date()),"gpu":gpu.device.name,
  "checks_passed":checks,"warmups":4,"samples":32,"benchmarks":benchmarks,"quality":quality,
  "scope":"offscreen 1536x1024 4xMSAA; same indexed geometry evaluator; all geometry is drawn, no tiles/LOD",
  "semantics":"whole owns affine A,t; visible centers = A p + t, Q = A Qlocal A transpose; join/cap rule evaluated in visible space; group boundaries only between complete strokes",
  "baseline":"GPU materializes real positions and Float32 Q at each node from the same local Q; packed main cases plus equal-layout Float32 local control at 1M; no CPU node rewrite baseline",
  "memory_scope":"requested GPU buffers; logical member-write bytes are not physical traffic or RSS; common render targets excluded",
  "limits":"no production/iPad installation, FPS, energy, eraser, arbitrary membership or individual world-space edits; initial preparation excluded"]
try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("results.json"))
print("PASS \(checks) checks; local state immutable, ordered whole transform equals materialized world within measured precision")
