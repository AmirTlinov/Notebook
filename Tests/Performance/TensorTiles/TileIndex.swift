import Foundation
import Metal
import simd

// Benchmark-only address-to-damage index. It is NOT installed alongside the
// application's existing spatial owner. Bounds are derived, conservative metadata;
// the actual shape is owned only by the GPU's packed word.
final class TileIndex {
  static let side=128, columns=12, rows=8
  struct Chunk { let indices:Range<Int>; let nodes:Range<Int>; var bounds:CGRect }
  struct Plan {
    let tiles:[Int]
    let fullRedraw:Bool
    let estimatedTileIndices:Int
    let ranges:[[Range<Int>]]
    let submittedIndices:Int
    let sourceNodes:Int
    let changedChunks:Int
    var pixels:Int { (fullRedraw ? TileIndex.columns*TileIndex.rows:tiles.count)*TileIndex.side*TileIndex.side }
  }
  let state:Prepared
  var chunks:[Chunk]=[]
  var owners:[SIMD2<Int32>]
  var radiusBounds:[Float]
  var bins=[Set<Int>](repeating:[],count:columns*rows)
  var binIndexCounts=[Int](repeating:0,count:columns*rows)
  private(set) var initialMilliseconds:Double=0
  var nodes:UnsafePointer<Node> { UnsafePointer(state.buffers[0].contents().assumingMemoryBound(to:Node.self)) }
  init(_ data:Dataset,state:Prepared) {
    let start=now()
    self.state=state
    owners=[SIMD2<Int32>](repeating:.init(-1,-1),count:data.count)
    // Includes initial quantization error; miter and antialias expansion are below.
    radiusBounds=data.strokes.flatMap { $0.map { $0.radius*1.01 } }
    var nodeStart=0,indexStart=0
    for stroke in data.strokes where !stroke.isEmpty {
      let count=stroke.count
      if count == 1 {
        add(indices:indexStart..<(indexStart+72),nodes:nodeStart..<(nodeStart+1)); indexStart+=72
      } else {
        for first in stride(from:0,to:count-1,by:64) {
          let end=min(first+64,count-1)
          add(indices:(indexStart+first*6)..<(indexStart+end*6),nodes:(nodeStart+first)..<(nodeStart+end+1))
        }
        indexStart+=(count-1)*6
        add(indices:indexStart..<(indexStart+36),nodes:nodeStart..<(nodeStart+1)); indexStart+=36
        add(indices:indexStart..<(indexStart+36),nodes:(nodeStart+count-1)..<(nodeStart+count)); indexStart+=36
      }
      nodeStart+=count
    }
    precondition(indexStart == state.count && nodeStart == state.nodeCount)
    initialMilliseconds=now()-start
  }
  private func add(indices:Range<Int>,nodes range:Range<Int>) {
    let id=chunks.count, b=bounds(range)
    chunks.append(.init(indices:indices,nodes:range,bounds:b))
    for n in range {
      if owners[n].x < 0 { owners[n].x=Int32(id) }
      else { precondition(owners[n].y < 0); owners[n].y=Int32(id) }
    }
    for tile in tiles(b) { bins[tile].insert(id); binIndexCounts[tile]+=indices.count }
  }
  private func bounds(_ range:Range<Int>) -> CGRect {
    var lo=SIMD2<Float>(repeating:.infinity),hi=SIMD2<Float>(repeating:-.infinity)
    for i in range {
      let extent=radiusBounds[i]*1.8+1 // current miter limit + pixel fringe
      lo=simd_min(lo,nodes[i].position-SIMD2(repeating:extent))
      hi=simd_max(hi,nodes[i].position+SIMD2(repeating:extent))
    }
    return CGRect(x:Double(lo.x),y:Double(lo.y),width:Double(hi.x-lo.x),height:Double(hi.y-lo.y))
  }
  private func tiles(_ rect:CGRect) -> [Int] {
    let visible=rect.intersection(CGRect(x:0,y:0,width:Self.columns*Self.side,height:Self.rows*Self.side))
    guard !visible.isNull && visible.width > 0 && visible.height > 0 else { return [] }
    let x0=max(0,Int(floor(visible.minX/Double(Self.side)))),x1=min(Self.columns-1,Int(floor(visible.maxX/Double(Self.side))))
    let y0=max(0,Int(floor(visible.minY/Double(Self.side)))),y1=min(Self.rows-1,Int(floor(visible.maxY/Double(Self.side))))
    return (y0...y1).flatMap { y in (x0...x1).map { y*Self.columns+$0 } }
  }
  func apply(_ edits:[SIMD4<UInt32>]) -> Plan {
    precondition(edits.allSatisfy { $0.x < state.nodeCount && $0.y == 0 && $0.z <= 1 && $0.w <= 8 },"this index updates uniform shape edits only")
    precondition(Set(edits.map(\.x)).count == edits.count)
    var changed=Set<Int>()
    for edit in edits {
      let id=Int(edit.x), pair=owners[id]
      changed.insert(Int(pair.x)); if pair.y >= 0 { changed.insert(Int(pair.y)) }
      let factor=exp2((edit.z == 0 ? Float(-1):1)*exp2(-Float(edit.w)))
      radiusBounds[id] *= factor
      precondition(radiusBounds[id] >= 0.004 && radiusBounds[id] < 250,"outside packed, non-saturating test domain")
    }
    var damaged=Set<Int>()
    for id in changed {
      let old=tiles(chunks[id].bounds), next=bounds(chunks[id].nodes), new=tiles(next)
      damaged.formUnion(old); damaged.formUnion(new)
      for tile in old { bins[tile].remove(id); binIndexCounts[tile]-=chunks[id].indices.count }
      for tile in new { bins[tile].insert(id); binIndexCounts[tile]+=chunks[id].indices.count }
      chunks[id].bounds=next
    }
    let selected=damaged.sorted()
    let estimated=selected.reduce(0) { $0+binIndexCounts[$1] }
    // Count before walking/sorting contributors: dense overlap must not pay
    // for a tile draw list only to discover that a single full pass is cheaper.
    if estimated >= state.count {
      return .init(tiles:selected,fullRedraw:true,estimatedTileIndices:estimated,ranges:[],submittedIndices:state.count,
        sourceNodes:state.nodeCount,changedChunks:changed.count)
    }
    var ranges:[[Range<Int>]]=[], allChunks=Set<Int>(), submitted=0
    for tile in selected {
      // This order is the original stroke/triangle order, not spatial order.
      let ids=bins[tile].sorted(); allChunks.formUnion(ids)
      var merged:[Range<Int>]=[]
      for id in ids {
        let range=chunks[id].indices
        if let last=merged.last,last.upperBound == range.lowerBound { merged[merged.count-1]=last.lowerBound..<range.upperBound }
        else { merged.append(range) }
      }
      submitted += merged.reduce(0) { $0+$1.count }; ranges.append(merged)
    }
    let intervals=allChunks.map { chunks[$0].nodes }.sorted { $0.lowerBound < $1.lowerBound }
    var unique=0,end=0
    for range in intervals { unique += max(0,range.upperBound-max(end,range.lowerBound)); end=max(end,range.upperBound) }
    return .init(tiles:selected,fullRedraw:false,estimatedTileIndices:estimated,ranges:ranges,submittedIndices:submitted,sourceNodes:unique,changedChunks:changed.count)
  }
  var metadataPayloadBytes:Int {
    // Excludes Array/Set capacity and allocator headers; not process RSS.
    owners.count*MemoryLayout<SIMD2<Int32>>.stride+radiusBounds.count*4
      + binIndexCounts.count*MemoryLayout<Int>.stride+chunks.count*MemoryLayout<Chunk>.stride+bins.reduce(0) { $0+$1.count*MemoryLayout<Int>.stride }
  }
}
