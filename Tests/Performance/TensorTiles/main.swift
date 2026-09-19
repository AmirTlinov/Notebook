import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

struct TileUniforms { var viewport:SIMD2<Float>; var origin:SIMD2<Float>; var counts:SIMD2<UInt32> }
struct TileTiming { let timing:Timing; let plan:TileIndex.Plan }
final class TileCanvas {
  let gpu:GPU, state:Prepared, index:TileIndex
  let saved:MTLTexture, scratch:MTLTexture, msaa:MTLTexture
  let pipeline:MTLRenderPipelineState
  init(gpu:GPU,state:Prepared,data:Dataset) throws {
    self.gpu=gpu; self.state=state; index=TileIndex(data,state:state)
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1536,height:1024,mipmapped:false)
    d.storageMode = .shared; d.usage = [.renderTarget,.shaderRead]
    saved=gpu.device.makeTexture(descriptor:d)!
    d.width=TileIndex.side; d.height=TileIndex.side; d.storageMode = .private
    scratch=gpu.device.makeTexture(descriptor:d)!
    d.textureType = .type2DMultisample; d.sampleCount=4
    msaa=gpu.device.makeTexture(descriptor:d)!
    let constants=MTLFunctionConstantValues(); var yes=true
    constants.setConstantValue(&yes,type:.bool,index:0); constants.setConstantValue(&yes,type:.bool,index:1)
    let descriptor=MTLRenderPipelineDescriptor()
    descriptor.vertexFunction=try gpu.library.makeFunction(name:"tileInkVertex",constantValues:constants)
    descriptor.fragmentFunction=gpu.library.makeFunction(name:"paperInkFragment")
    descriptor.rasterSampleCount=4
    let c=descriptor.colorAttachments[0]!
    c.pixelFormat = .bgra8Unorm; c.isBlendingEnabled=true
    c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
    c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    pipeline=try gpu.device.makeRenderPipelineState(descriptor:descriptor)
    // Cold initial frame is explicitly paid once, not counted as a local edit.
    _=gpu.run(state)
    let command=gpu.queue.makeCommandBuffer()!, blit=command.makeBlitCommandEncoder()!
    blit.copy(from:gpu.target,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:1536,height:1024,depth:1),
      to:saved,destinationSlice:0,destinationLevel:0,destinationOrigin:.init(x:0,y:0,z:0))
    blit.endEncoding(); command.commit(); gpu.complete(command)
  }
  func run(_ edits:[SIMD4<UInt32>]) -> TileTiming {
    let start=now(), plan=index.apply(edits)
    let command=gpu.queue.makeCommandBuffer()!
    gpu.encodeEdits(edits,state:state,command:command)
    if plan.fullRedraw { gpu.encodeDraw(state,command:command,target:saved) }
    for (i,tile) in (plan.fullRedraw ? []:plan.tiles).enumerated() {
      let x=(tile%TileIndex.columns)*TileIndex.side,y=(tile/TileIndex.columns)*TileIndex.side
      let pass=MTLRenderPassDescriptor(), attachment=pass.colorAttachments[0]!
      attachment.texture=msaa; attachment.resolveTexture=scratch
      attachment.loadAction = .clear; attachment.storeAction = .multisampleResolve
      attachment.clearColor=MTLClearColorMake(0,0,0,0)
      let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
      encoder.setRenderPipelineState(pipeline)
      for j in 0..<3 { encoder.setVertexBuffer(state.buffers[j],offset:0,index:j) }
      var u=TileUniforms(viewport:.init(Float(TileIndex.side),Float(TileIndex.side)),origin:.init(Float(x),Float(y)),counts:.init(UInt32(state.nodeCount),UInt32(state.count)))
      encoder.setVertexBytes(&u,length:MemoryLayout<TileUniforms>.stride,index:3)
      for range in plan.ranges[i] {
        encoder.drawIndexedPrimitives(type:.triangle,indexCount:range.count,indexType:.uint32,indexBuffer:state.buffers[3],indexBufferOffset:range.lowerBound*4)
      }
      encoder.endEncoding()
      let blit=command.makeBlitCommandEncoder()!
      blit.copy(from:scratch,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:TileIndex.side,height:TileIndex.side,depth:1),
        to:saved,destinationSlice:0,destinationLevel:0,destinationOrigin:.init(x:x,y:y,z:0))
      blit.endEncoding()
    }
    command.commit(); let submitted=now(); gpu.complete(command); let end=now()
    check(command.gpuEndTime > command.gpuStartTime,"GPU timestamps")
    return .init(timing:.init(cpu:submitted-start,gpu:(command.gpuEndTime-command.gpuStartTime)*1000,wall:end-start),plan:plan)
  }
  func pixels() -> [UInt8] {
    var p=[UInt8](repeating:0,count:1536*1024*4)
    saved.getBytes(&p,bytesPerRow:1536*4,from:MTLRegionMake2D(0,0,1536,1024),mipmapLevel:0)
    return p
  }
}
struct Difference {
  let rmse:Double, occupiedFraction:Double, differingPixels:Int, maxChannel:Int
  var json:[String:Any] { ["rgba_rmse_normalized":rmse,"difference_over_2_fraction_occupied":occupiedFraction,"differing_pixels":differingPixels,"max_channel_error":maxChannel] }
}
func difference(_ a:[UInt8],_ b:[UInt8]) -> Difference {
  precondition(a.count == b.count)
  var squared:Double=0, occupied=0, changed=0,maxDelta=0
  for i in stride(from:0,to:a.count,by:4) {
    var delta=0
    for j in 0..<4 { let d=abs(Int(a[i+j])-Int(b[i+j])); squared+=Double(d*d); delta=max(delta,d) }
    if a[i+3] > 0 || b[i+3] > 0 { occupied+=1 }
    if delta > 2 { changed+=1 }; maxDelta=max(maxDelta,delta)
  }
  return .init(rmse:sqrt(squared/Double(a.count))/255,occupiedFraction:Double(changed)/Double(max(1,occupied)),differingPixels:changed,maxChannel:maxDelta)
}
func verify(_ a:[UInt8],_ b:[UInt8],label:String) -> Difference {
  let d=difference(a,b)
  check(d.rmse <= 0.003 && d.occupiedFraction <= 0.005,"\(label): \(d.json)")
  return d
}
func savePNG(_ pixels:[UInt8],_ name:String) {
  let provider=CGDataProvider(data:Data(pixels) as CFData)!
  let image=CGImage(width:1536,height:1024,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:1536*4,
    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],
    provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
  let destination=CGImageDestinationCreateWithURL(out.appendingPathComponent(name).appendingPathExtension("png") as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(destination,image,nil); check(CGImageDestinationFinalize(destination),"PNG")
}
func synthetic(_ total:Int,dense:Bool=false) -> Dataset {
  let length=250, count=total/length
  precondition(total%length == 0 && count >= 8)
  var strokes:[[Point]]=[]; strokes.reserveCapacity(count)
  for s in 0..<count {
    let local=s >= count-8 || dense
    let localID=s >= count-8 ? s-(count-8):s%8
    let points=(0..<length).map { i -> Point in
      let t=Float(i)/Float(length-1)
      let x:Float=local ? 65+t*380 : 620+t*850
      let y:Float=local ? 395+Float(localID)*17+42*sin(t*9+Float(localID)*0.3)
        : 32+Float(s%100)*9.3+9*sin(t*12+Float(s)*0.17)
      let radius:Float=local ? 1.4+0.5*sin(t*7):0.6+0.3*sin(t*8)
      let alpha:Float=local ? 0.48:0.15
      let rgb=SIMD3<Float>(0.08+0.55*Float(s%3)/2,0.18+0.25*Float((s+1)%3)/2,0.35+0.4*Float((s+2)%3)/2)
      return .init(position:.init(x,y),radius:radius,premultipliedColor:.init(rgb.x*alpha,rgb.y*alpha,rgb.z*alpha,alpha))
    }
    strokes.append(points)
  }
  return .init(name:"\(dense ? "dense" : "separated")-\(total)",strokes:strokes)
}
func metrics(_ values:[Double]) -> [String:Any] {
  let a=values.sorted(),n=a.count
  return ["median_ms":(a[(n-1)/2]+a[n/2])/2,"p95_ms":a[Int(ceil(Double(n)*0.95))-1],"samples_ms":values]
}
func timingJSON(_ times:[Timing]) -> [String:Any] {
  ["cpu_submit":metrics(times.map(\.cpu)),"gpu":metrics(times.map(\.gpu)),"wall":metrics(times.map(\.wall))]
}
let gpu=try GPU()
check(MemoryLayout<TileUniforms>.stride == 24,"MSL layout")
var quality:[[String:Any]]=[],results:[[String:Any]]=[]
for spec in [(10_000,false),(100_000,false),(1_000_000,false),(100_000,true)] {
  try autoreleasepool {
    let data=synthetic(spec.0,dense:spec.1)
    let full=gpu.prepare(data,mode:.bitShapeGPU),local=gpu.prepare(data,mode:.bitShapeGPU)
    let canvas=try TileCanvas(gpu:gpu,state:local,data:data)
    let nodes=(0..<32).map { UInt32(data.count-250+100+$0) }
    var fullTimes:[Timing]=[],tileTimes:[Timing]=[],lastPlan:TileIndex.Plan?
    var maxDifference:Double=0
    for round in 0..<34 {
      let edits=nodes.map { SIMD4<UInt32>($0,0,UInt32(round%2 == 0 ? 1:0),0) }
      let a:Timing,b:TileTiming
      if round%2 == 0 { a=gpu.run(full,edits:edits); b=canvas.run(edits) }
      else { b=canvas.run(edits); a=gpu.run(full,edits:edits) }
      lastPlan=b.plan
      if round >= 4 { fullTimes.append(a);tileTimes.append(b.timing) }
      if round < 2 || round == 33 {
        let d=verify(gpu.pixels(),canvas.pixels(),label:data.name+" round \(round)")
        maxDifference=max(maxDifference,d.rmse)
        quality.append(["case":data.name,"round":round,"comparison":d.json])
      }
    }
    let plan=lastPlan!
    // Spatial density near the edit remains constant in separated cases.
    results.append(["case":data.name,"nodes":data.count,"edited_nodes":32,"full_indices":full.count,
      "submitted_tile_indices":plan.submittedIndices,"unique_source_nodes_replayed":plan.sourceNodes,
      "dirty_tiles":plan.tiles,"updated_pixels":plan.pixels,"selected_full_redraw":plan.fullRedraw,"estimated_tile_indices":plan.estimatedTileIndices,"changed_chunks":plan.changedChunks,
      "draw_calls":plan.fullRedraw ? 1:plan.ranges.reduce(0) { $0+$1.count },"full":timingJSON(fullTimes),"tiles":timingJSON(tileTimes),
      "geometry_gpu_bytes":local.payloadBytes,"derived_cpu_index_payload_bytes":canvas.index.metadataPayloadBytes,
      "index_build_ms":canvas.index.initialMilliseconds,"retained_image_bytes":1536*1024*4,
      "tile_scratch_bytes":128*128*4*5,"full_msaa_scratch_bytes":1536*1024*4*4,"max_rgba_rmse":maxDifference])
    print(String(format:"%@ tiles=%d nodes=%d/%d indices=%d/%d gpu=%.4f -> %.4f wall=%.4f -> %.4f",data.name,
      plan.tiles.count,plan.sourceNodes,data.count,plan.submittedIndices,full.count,
      metrics(fullTimes.map(\.gpu))["median_ms"] as! Double,metrics(tileTimes.map(\.gpu))["median_ms"] as! Double,
      metrics(fullTimes.map(\.wall))["median_ms"] as! Double,metrics(tileTimes.map(\.wall))["median_ms"] as! Double))
  }
}

// Boundary regression: visible expansion crosses x/y=128, contraction must
// remove old pixels outside the NEW bounds; transparent crossings remain ordered.
let regression=Dataset(name:"crossing-boundary",strokes:[
  (0..<180).map { i in Point(position:.init(20+Float(i)*1.8,110+25*sin(Float(i)/18)),radius:5,premultipliedColor:.init(0.30,0.05,0.03,0.5)) },
  (0..<160).map { i in Point(position:.init(100+25*sin(Float(i)/17),20+Float(i)*1.7),radius:4,premultipliedColor:.init(0.04,0.11,0.40,0.55)) },
  (0..<40).map { i in Point(position:.init(122,90+Float(i)*0.7),radius:3,premultipliedColor:.init(0.06,0.38,0.10,0.6)) }
] + Array(synthetic(10_000).strokes.prefix(8)))
let reference=gpu.prepare(regression,mode:.bitShapeGPU),local=gpu.prepare(regression,mode:.bitShapeGPU)
let canvas=try TileCanvas(gpu:gpu,state:local,data:regression)
let initial=canvas.pixels();savePNG(initial,"before")
let reversed=gpu.prepare(Dataset(name:"reverse",strokes:regression.strokes.reversed()),mode:.bitShapeGPU)
_=gpu.run(reversed)
let orderDelta=difference(initial,gpu.pixels())
check(orderDelta.differingPixels > 100,"negative control must expose wrong transparency order")
var boundaryRows:[[String:Any]]=[],negativeOldDamage=0
for step in 0..<6 {
  let before=canvas.pixels()
  let edits=(0..<32).map { SIMD4<UInt32>(UInt32(344+$0),0,UInt32(step < 3 ? 1:0),0) }
  _=gpu.run(reference,edits:edits);let expected=gpu.pixels()
  let run=canvas.run(edits),actual=canvas.pixels()
  check(!run.plan.fullRedraw,"boundary regression must exercise the TILE path")
  let d=verify(expected,actual,label:"boundary \(step)")
  let dirty=Set(run.plan.tiles)
  var outsideChanges=0
  for pixel in 0..<(1536*1024) {
    let tile=(pixel/1536/128)*12+(pixel%1536/128)
    if !dirty.contains(tile) {
      let i=pixel*4
      if before[i] != actual[i] || before[i+1] != actual[i+1] || before[i+2] != actual[i+2] || before[i+3] != actual[i+3] { outsideChanges+=1 }
    }
  }
  check(outsideChanges == 0,"unaffected tiles must remain bitwise unchanged")
  if step == 2 { savePNG(actual,"expanded-tiles"); savePNG(expected,"expanded-full") }
  if step >= 3 {
    // Fault injection: pretend only the new, small top-left tile was refreshed.
    var stale=before
    for y in 0..<128 { for x in 0..<128 { let i=(y*1536+x)*4; for c in 0..<4 { stale[i+c]=actual[i+c] } } }
    negativeOldDamage=max(negativeOldDamage,difference(expected,stale).differingPixels)
  }
  boundaryRows.append(["step":step,"dirty_tiles":run.plan.tiles,"outside_changes":outsideChanges,"selected_full_redraw":run.plan.fullRedraw,"comparison":d.json])
}
check(negativeOldDamage > 100,"negative control must expose stale old contour: \(negativeOldDamage)")
let inverse=verify(initial,canvas.pixels(),label:"uniform inverse restores initial")
savePNG(canvas.pixels(),"restored")
quality.append(["case":"crossing-boundary","steps":boundaryRows,"negative_wrong_order_pixels":orderDelta.differingPixels,
  "negative_missing_old_damage_pixels":negativeOldDamage,"inverse":inverse.json])
let receipt:[String:Any]=["schema":1,"date":ISO8601DateFormatter().string(from:Date()),"gpu":gpu.device.name,
  "checks_passed":checks,"warmups":4,"samples":30,"benchmarks":results,"quality":quality,
  "scope":"offscreen 1536x1024 4xMSAA; same direct bit-shape evaluator; source-over pen only; no production install, iPad, FPS or power measurement",
  "geometry_scope":"all nodes are inside viewport; separated scenes grow away from fixed local edit, dense control increases overlapping contributors",
  "memory_scope":"GPU requested geometry buffers and theoretical texture pixel storage; CPU index used payload excludes capacities/Set headers; not RSS",
  "initial_frame":"one full render retained before edits; construction and initial render are not local-edit timing",
  "limits":"fixed camera/viewport/topology; only known-address uniform shape edits update bounds; cold opening and arbitrary deformation/position changes are not optimized"]
try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("results.json"))
print("PASS \(checks) checks; tile output agrees with full redraw, including old/new bounds and transparent overlap")
