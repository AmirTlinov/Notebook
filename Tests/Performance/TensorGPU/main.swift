import Foundation
import Metal
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import simd

func makeSynthetic(_ name: String, strokes: Int, points: Int) -> Dataset {
  let columns=strokes > 100 ? 16 : 8, rows=(strokes+columns-1)/columns
  let cell=SIMD2<Float>(1500/Float(columns),960/Float(rows))
  return Dataset(name:name,strokes:(0..<strokes).map { s in
    (0..<points).map { i in
      let t=Float(i)/Float(max(1,points-1))
      let p=SIMD2<Float>(18+Float(s%columns)*cell.x+t*(cell.x-12),32+Float(s/columns)*cell.y+cell.y*(0.5+0.3*sin(t*12)))
      let radius:Float=0.6+1.5*(0.5+0.5*sin(t*9+Float(s)))
      let alpha:Float=0.3+0.7*(0.5+0.5*cos(t*5))
      return Point(position:p,radius:radius,premultipliedColor:.init(0.08*alpha,0.25*alpha,0.42*alpha,alpha))
    }
  })
}
let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:[[[[Double]]]]]
var measured:[[Point]]=[]
for key in fixture.keys.sorted() { for drawing in fixture[key]! { for stroke in drawing {
  let minX=stroke.map { $0[0] }.min() ?? 0, maxX=stroke.map { $0[0] }.max() ?? 1
  let minY=stroke.map { $0[1] }.min() ?? 0, maxY=stroke.map { $0[1] }.max() ?? 1
  let scale=Float(min(135/max(1,maxX-minX),100/max(1,maxY-minY)))
  let index=measured.count
  measured.append(normalize(stroke.enumerated().map { i,p in
    let alpha:Float=0.4+0.6*(0.5+0.5*sin(Float(i)/27))
    return .init(position:.init(16+Float(index%10)*150+(Float(p[0])-Float(minX))*scale,
      16+Float(index/10)*125+(Float(p[1])-Float(minY))*scale),radius:0.3+1.7*(0.5+0.5*sin(Float(i)/29)),
      premultipliedColor:.init(0.08*alpha,0.25*alpha,0.42*alpha,alpha))
  }))
}}}
let gpu=try GPU()
check(MemoryLayout<Node>.stride == 32 && MemoryLayout<Uniforms>.stride == 16,"CPU/MSL layout")
let cases=[makeSynthetic("synthetic-8192",strokes:32,points:256),Dataset(name:"measured-path",strokes:measured),makeSynthetic("synthetic-98304",strokes:384,points:256)]
var quality:[[String:Any]]=[]
func compare(_ data: Dataset) {
  let reference=data.mesh(), baseline=gpu.prepare(data,mode:.triangles)
  _=gpu.run(baseline); let pixels=gpu.pixels()
  for mode in [Mode.scalarGPU,.tensorGPU,.bitShapeGPU] {
    let state=gpu.prepare(data,mode:mode), positions=gpu.inspect(state)
    check(positions.count == reference.count,"triangle topology")
    var maxError:Float=0
    for i in positions.indices { maxError=max(maxError,simd_length(positions[i]-reference[i].position)) }
    check(maxError <= (mode == .bitShapeGPU ? 0.01 : 0.002),"direct GPU contour error: \(maxError)")
    _=gpu.run(state); let actual=gpu.pixels()
    var squared:Double=0, changed=0, occupied=0, maxAlpha=0
    for i in stride(from:3,to:pixels.count,by:4) {
      let delta=abs(Int(pixels[i])-Int(actual[i]))
      squared += Double(delta*delta); if delta > 2 { changed += 1 }
      if pixels[i] > 0 || actual[i] > 0 { occupied += 1 }; maxAlpha=max(maxAlpha,delta)
    }
    let rmse=sqrt(squared/Double(1536*1024))/255
    let fraction=Double(changed)/Double(max(1,occupied))
    check(rmse <= 0.005 && fraction <= (mode == .bitShapeGPU ? 0.03 : 0.01),"raster equivalence \(data.name) \(mode): \(rmse), \(fraction)")
    quality.append(["case":data.name,"mode":mode.rawValue,"max_vertex_error_pt":maxError,
      "alpha_rmse_normalized":rmse,"alpha_difference_over_2_fraction_of_occupied":fraction,"max_alpha_difference":maxAlpha])
  }
}
for data in cases { compare(data) }
let color=SIMD4<Float>(0.1,0.2,0.3,0.7)
compare(Dataset(name:"edge-cases",strokes:[[],[Point(position:.init(100,100),radius:5,premultipliedColor:color)],
  [.init(position:.init(200,200),radius:2,premultipliedColor:color),.init(position:.init(230,200),radius:6,premultipliedColor:color)],
  [SIMD2<Float>(400,400),.init(440,400),.init(400,400),.init(400,450)].map { .init(position:$0,radius:4,premultipliedColor:color) }]))
print("PASS baseline/direct geometry and Metal image comparisons")

// Known-address CPU patch control: never retessellates the full stroke.
func patchTriangles(_ state: Prepared, edits:[SIMD4<UInt32>], nodes:[Node], refs:[[Int]]) {
  let vertices=state.buffers[0].contents().assumingMemoryBound(to:Vertex.self)
  for edit in edits {
    let node=Int(edit.x), center=nodes[node].position
    let scale=exp2((edit.z == 0 ? Float(-1):1)*exp2(-Float(edit.w)))
    for index in refs[node] { vertices[index].position=center+(vertices[index].position-center)*scale }
  }
}
// Uniform updates must agree with an addressed patch of the current mesh,
// including both end caps. Otherwise the edit benchmark would compare different work.
let updateData=cases[1], updateTopology=Topology(cases[1])
let updateRefs=updateTopology.vertexReferences()
let updateIDs=[0,updateData.count/3,updateData.count/2,updateData.count-1]
let updates=updateIDs.map { SIMD4<UInt32>(UInt32($0),0,1,4) }
let updateBaseline=gpu.prepare(updateData,mode:.triangles)
patchTriangles(updateBaseline,edits:updates,nodes:updateTopology.nodes,refs:updateRefs)
let updatedReference=updateBaseline.buffers[0].contents().assumingMemoryBound(to:Vertex.self)
for mode in [Mode.scalarGPU,.tensorGPU,.bitShapeGPU] {
  let state=gpu.prepare(updateData,mode:mode)
  gpu.editOnly(state,batches:[updates])
  let positions=gpu.inspect(state)
  var error:Float=0
  for i in positions.indices { error=max(error,simd_length(positions[i]-updatedReference[i].position)) }
  check(error <= (mode == .bitShapeGPU ? 0.01 : 0.002),"addressed uniform GPU edit vs current mesh")
  quality.append(["case":"addressed-uniform-edit","mode":mode.rawValue,"max_vertex_error_pt":error])
}

func stats(_ values:[Double]) -> [String:Any] {
  let a=values.sorted(), n=a.count
  return ["median_ms":(a[(n-1)/2]+a[n/2])/2,"p95_ms":a[Int(ceil(Double(n)*0.95))-1],"samples_ms":values]
}
var benchmarks:[[String:Any]]=[]
for data in cases {
  let topology=Topology(data), refs=topology.vertexReferences()
  let states=Dictionary(uniqueKeysWithValues:Mode.allCases.map { ($0,gpu.prepare(data,mode:$0)) })
  for workload in ["cached-draw","edit-1-and-draw","edit-32-and-draw","prepare-and-draw"] {
    var times:[Mode:[Timing]]=[:]
    for round in 0..<34 {
      for offset in 0..<Mode.allCases.count {
        let mode=Mode.allCases[(offset+round)%Mode.allCases.count]
        let state:Prepared; var preparation:Double=0
        if workload == "prepare-and-draw" {
          let start=now(); state=gpu.prepare(data,mode:mode); preparation=now()-start
        } else { state=states[mode]! }
        let count=workload == "edit-1-and-draw" ? 1 : (workload == "edit-32-and-draw" ? 32 : 0)
        let edits=(0..<count).map { i in SIMD4<UInt32>(UInt32((i+1)*data.count/(count+1)),0,UInt32(round%2 == 0 ? 1:0),4) }
        var timing:Timing
        if mode == .triangles {
          timing=gpu.run(state,cpuEdit:{ patchTriangles(state,edits:edits,nodes:topology.nodes,refs:refs) })
        } else { timing=gpu.run(state,edits:edits) }
        timing.cpu += preparation; timing.wall += preparation
        if round >= 4 { times[mode,default:[]].append(timing) }
      }
    }
    for mode in Mode.allCases {
      let t=times[mode]!, state=states[mode]!
      let gpuStats=stats(t.map(\.gpu)), wallStats=stats(t.map(\.wall))
      benchmarks.append(["case":data.name,"nodes":data.count,"workload":workload,"mode":mode.rawValue,
        "gpu_buffer_requested_bytes":state.payloadBytes,"cpu_submit":stats(t.map(\.cpu)),"gpu":gpuStats,"wall":wallStats])
      print(String(format:"%@ %@ %@ bytes=%d gpu=%.4f wall=%.4f",data.name,workload,mode.rawValue,state.payloadBytes,
        gpuStats["median_ms"] as! Double,wallStats["median_ms"] as! Double))
    }
  }
}

// Actual tensor edits, not a relabelled radius: local anisotropy and rotation.
let demo=Dataset(name:"tensor-demo",strokes:[(0..<256).map { i in
  let x=Float(i)*5+100, y=Float(500)+140*sin(Float(i)/32)
  return Point(position:.init(x,y),radius:8,premultipliedColor:.init(0.08,0.25,0.42,1))
}])
let tensor=gpu.prepare(demo,mode:.tensorGPU), topology=Topology(demo)
_ = gpu.run(tensor); gpu.savePNG("tensor-before")
let before=Array(UnsafeBufferPointer(start:tensor.buffers[1].contents().assumingMemoryBound(to:SIMD4<Float>.self),count:demo.count))
let selected=Array(80..<176)
let stretch=selected.map { SIMD4<UInt32>(UInt32($0),1,1,0) }
let rotate=selected.map { SIMD4<UInt32>(UInt32($0),2,1,0) }
gpu.editOnly(tensor,batches:[stretch,rotate])
let after=Array(UnsafeBufferPointer(start:tensor.buffers[1].contents().assumingMemoryBound(to:SIMD4<Float>.self),count:demo.count))
for i in before.indices {
  if !selected.contains(i) { check(before[i] == after[i],"unaddressed tensor changed") }
  else {
    let q=after[i]; check(q.x*q.z-q.y*q.y > 0 && q.x > 0,"positive definite tensor")
    check(abs((q.x+q.z)-320) < 0.002 && abs(q.x*q.z-q.y*q.y-16384) < 0.05,"stretch eigenvalue invariants")
  }
}
_ = gpu.run(tensor); gpu.savePNG("tensor-after")
// Different order must have a different result, despite the same two operations.
let other=gpu.prepare(demo,mode:.tensorGPU)
gpu.editOnly(other,batches:[rotate,stretch])
let reordered=other.buffers[1].contents().assumingMemoryBound(to:SIMD4<Float>.self)
check(selected.contains { simd_length(after[$0]-reordered[$0]) > 1 },"noncommutative shape relation")
// Same local operations with only ONE 32-bit word retained per shape.
let bitTensor=gpu.prepare(demo,mode:.bitShapeGPU)
let bitBefore=gpu.inspect(bitTensor)
let bitWords=Array(UnsafeBufferPointer(start:bitTensor.buffers[1].contents().assumingMemoryBound(to:UInt32.self),count:demo.count))
gpu.editOnly(bitTensor,batches:[stretch,rotate])
let floatAfter=gpu.inspect(tensor), bitAfter=gpu.inspect(bitTensor)
var bitEditError:Float=0
for i in bitAfter.indices { bitEditError=max(bitEditError,simd_length(bitAfter[i]-floatAfter[i])) }
let editedWords=bitTensor.buffers[1].contents().assumingMemoryBound(to:UInt32.self)
for i in bitWords.indices where !selected.contains(i) { check(editedWords[i] == bitWords[i],"unaddressed shape bits changed") }
check(bitEditError < 0.15,"packed tensor edit precision")
let bitOther=gpu.prepare(demo,mode:.bitShapeGPU)
gpu.editOnly(bitOther,batches:[rotate,stretch])
let reorderedBits=bitOther.buffers[1].contents().assumingMemoryBound(to:UInt32.self)
check(selected.contains { editedWords[$0] != reorderedBits[$0] },"packed noncommutative relative edits")

_ = gpu.run(bitTensor); gpu.savePNG("bit-tensor-after")
gpu.editOnly(bitTensor,batches:[selected.map { .init(UInt32($0),2,0,0) },selected.map { .init(UInt32($0),1,0,0) }])
let bitUndone=gpu.inspect(bitTensor)
var bitUndoError:Float=0
for i in bitUndone.indices { bitUndoError=max(bitUndoError,simd_length(bitUndone[i]-bitBefore[i])) }
// Quantized general edits are intentionally measured, not declared exactly reversible.
let bitInversePass=bitUndoError < 0.15
check(bitInversePass,"packed inverse contour bound")

// Undo in reverse order: no reconstruction of preceding nodes or global scan.
gpu.editOnly(tensor,batches:[selected.map { .init(UInt32($0),2,0,0) },selected.map { .init(UInt32($0),1,0,0) }])
let undone=tensor.buffers[1].contents().assumingMemoryBound(to:SIMD4<Float>.self)
var undoError:Float=0
for i in before.indices { undoError=max(undoError,simd_length(undone[i]-before[i])) }
check(undoError < 0.001,"inverse relative edits")
let panel=CGContext(data:nil,width:1400,height:1210,bitsPerComponent:8,bytesPerRow:1400*4,
  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
panel.setFillColor(CGColor(gray:1,alpha:1)); panel.fill(CGRect(x:0,y:0,width:1400,height:1210))
let panels=[("tensor-before","Исходный штрих"),("tensor-after","GPU: локальное растяжение ×2 и поворот 45°"),
  ("bit-tensor-after","Тот же GPU-рендер: форма в 32 битах на узел")]
for (i,item) in panels.enumerated() {
  let source=CGImageSourceCreateWithURL(out.appendingPathComponent(item.0).appendingPathExtension("png") as CFURL,nil)!
  let full=CGImageSourceCreateImageAtIndex(source,0,nil)!
  let crop=full.cropping(to:CGRect(x:70,y:310,width:1350,height:360))!
  let y=CGFloat(795-i*390)
  panel.draw(crop,in:CGRect(x:25,y:y,width:1350,height:360))
  let attributes:[NSAttributedString.Key:Any]=[
    NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,22,nil),
    NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.15,alpha:1)]
  let line=CTLineCreateWithAttributedString(NSAttributedString(string:item.1,attributes:attributes))
  panel.textPosition = .init(x:30,y:y+365); CTLineDraw(line,panel)
}
let panelDestination=CGImageDestinationCreateWithURL(out.appendingPathComponent("comparison.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(panelDestination,panel.makeImage()!,nil)
check(CGImageDestinationFinalize(panelDestination),"GPU comparison export")

let result:[String:Any]=["schema":1,"date":ISO8601DateFormatter().string(from:Date()),"gpu":gpu.device.name,
  "scope":"Offscreen macOS Metal, 1536x1024 4xMSAA; no display FPS, iPad, picking, scene culling, or live Pencil acceptance",
  "warmups":4,"samples":30,"checks_passed":checks,"quality":quality,"benchmarks":benchmarks,
  "tensor_edit":["addressed_nodes":selected.count,"unchanged_other_nodes":true,"inverse_max_error":undoError,"order_matters":true,"packed_edit_max_error_pt":bitEditError,"packed_inverse_max_error_pt":bitUndoError,"packed_inverse_within_0_15pt":bitInversePass],
  "memory_scope":"requested GPU buffer lengths including direct indices/caps; excludes CPU sources, baseline CPU patch adjacency, textures, allocator granularity and RSS"]
try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("results.json"))
print("PASS \(checks) checks; actual tensor edits and inverse verified")
