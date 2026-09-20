import Foundation
import Testing
@testable import NotebookCore

@Suite(.serialized)
struct InkRelationCodecTests {
  private func sample(_ i: Int) -> SpatialInkSample {
    .init(point:.init(x:Double(i)/4,y:Double(i%13)/2),timeOffset:Double(i)/128,
      width:4,opacity:0.5,force:Double(i%7)/8,azimuth:Double(i%9)/8,altitude:0.5)
  }
  private func source(_ samples: [SpatialInkSample]) -> InkSampleRelations {
    .init(sourceID:UUID(),span:7,revision:UUID(),samples:samples,
      header:.init(tool:.pen,color:.init(red:-0.0,green:0.25,blue:0.75),sequence:91,isActive:false))
  }
  private func check(_ original: InkSampleRelations) throws -> InkSampleRelations {
    let bytes=try original.encodedRelations(),restored=try InkSampleRelations(encodedRelations:bytes)
    #expect(restored.sourceID == original.sourceID && restored.span == original.span && restored.revision == original.revision)
    #expect(restored.header.tool == original.header.tool && restored.header.sequence == original.header.sequence)
    #expect(restored.header.isActive == original.header.isActive && restored.header.elementTargets == original.header.elementTargets)
    #expect(restored.header.color.red.bitPattern == original.header.color.red.bitPattern)
    #expect(restored.header.color.green.bitPattern == original.header.color.green.bitPattern)
    #expect(restored.header.color.blue.bitPattern == original.header.color.blue.bitPattern)
    #expect(restored.count == original.count && restored.frames == original.frames && restored.storage.exit == original.storage.exit)
    for i in 0..<min(300,original.count) {
      let index=original.count <= 300 ? i : i*(original.count-1)/299
      #expect(InkSampleRelations.sameBits(original.sample(at:index),restored.sample(at:index)))
    }
    #expect(try restored.encodedRelations() == bytes)
    return restored
  }

  @Test func measurementsMetadataAndJSONTransportAreBitExact() throws {
    let world=try #require(WorldPoint(exactTileX:WorldPoint.maximumTileIndex,tileY:-WorldPoint.maximumTileIndex,localX:-0.0,localY:0.125))
    let edge=SpatialInkSample(point:.init(x:-0.0,y:.leastNonzeroMagnitude),worldPoint:world,timeOffset:-0.0,
      width:.leastNonzeroMagnitude,opacity:-0.0,force:.greatestFiniteMagnitude,azimuth:-0.0,altitude:-Double.greatestFiniteMagnitude)
    let transform=NotebookGraphicTransform(a:0,b:1,c:-1,d:-0.0,tx:1,ty:-0.0)
    let target=InkElementTarget(elementID:"форма 🧩",frame:.init(x:-0.0,y:0.25,width:100,height:50),
      worldOrigin:world,wholeElement:true,graphicTransform:.identity,elementTransform:transform)
    let a=InkSampleRelations(sourceID:UUID(),span:31,revision:UUID(),samples:[edge]+(0..<777).map(sample),
      header:.init(tool:.eraser,color:.black,sequence:VersionStamp.maximumCounter,isActive:false,elementTargets:[target]))
      .settingExit(.init(x:InkDyadic(2)!,y:InkDyadic(-3)!,time:InkDyadic(0.5)!),revision:UUID())
    // Uncomposable frame order must remain an ordered word, not be rounded.
    let scale=InkExactFrame(a:InkDyadic(1.1)!,b:.zero,c:.zero,d:.one,x:.zero,y:.zero)
    let turn=InkExactFrame(a:.zero,b:.one,c:InkDyadic(-1)!,d:.zero,x:.zero,y:.zero)
    let posed=a.transformed(by:scale).transformed(by:scale).transformed(by:turn)
    #expect(posed.frames.count == 2)
    let restored=try check(posed)
    #expect(InkSampleRelations.sameBits(restored.sample(at:0),edge))
    #expect(restored.header.elementTargets?[0].worldOrigin?.localX.bitPattern == (-0.0 as Double).bitPattern)
    #expect(restored.header.elementTargets?[0].frame.x.bitPattern == (-0.0 as Double).bitPattern)
    #expect(restored.header.elementTargets?[0].elementTransform?.d.bitPattern == (-0.0 as Double).bitPattern)
    let transported=try JSONValue.encode(posed).decode(InkSampleRelations.self)
    #expect(try transported.encodedRelations() == posed.encodedRelations())
    // Public binary decoding also accepts Data slices with nonzero startIndex.
    let bytes=try posed.encodedRelations(),slice=(Data([255])+bytes).dropFirst()
    #expect(try InkSampleRelations(encodedRelations:slice).encodedRelations() == bytes)
    let empty=source([]).settingExit(.init(x:.one,y:.zero,time:.one),revision:UUID())
    _=try check(try #require(empty.repeated(17,revision:UUID())))
    _=try check(.init(sourceID:UUID(),revision:UUID(),samples:[],header:.init(tool:.eraser,color:.black,elementTargets:[])))
  }

  @Test func repeatRestoreAndOneOccurrenceEditDoNotExpandTheBody() throws {
    let body=source((0..<100).map(sample)).settingExit(.init(x:InkDyadic(32)!,y:.zero,time:.one),revision:UUID())
    let repeated=try #require(body.repeated(10_000,revision:UUID()))
    let restored=try check(repeated)
    #expect(restored.count == 1_000_000 && restored.allocationSummary.nodes == repeated.allocationSummary.nodes)
    #expect(try restored.encodedRelations().count < 10_000)
    let middle=501_027,old=restored.sample(at:middle),replacement=sample(991)
    let read=try restored.access(restored.address(at:middle))
    #expect(read.cost.decodedSamples == 1 && read.cost.jumps == 1 && read.cost.visitedNodes <= 3)
    let edited=try restored.editing(restored.address(at:middle),to:replacement,revision:UUID(),normalizationBudget:0)
    let reopened=try check(edited)
    #expect(reopened.storage.root.pending)
    #expect(InkSampleRelations.sameBits(reopened.sample(at:middle),replacement))
    #expect(InkSampleRelations.sameBits(restored.sample(at:middle),old))
    for i in [0,middle-1,middle+1,999_999] {
      #expect(InkSampleRelations.sameBits(reopened.sample(at:i),restored.sample(at:i)))
    }
    #expect(throws:InkSampleRelations.AccessError.self) { try reopened.sample(at:restored.address(at:middle)) }
    #expect(reopened.payloadBytes < body.payloadBytes+25_000)
    // Continuing from restored source proves that decoded generators and jumps
    // obey the existing exact-arithmetic owner, not just a byte comparison.
    let shifted=try reopened.propagatingExitDelta(.init(x:.one,y:.zero,time:.zero),
      from:reopened.address(at:middle+1),revision:UUID())
    _=try check(shifted)
  }

  @Test func sharedGraphAndDistinctBindingsOfOneBasisSurvive() throws {
    typealias S=InkSampleRelations.Sequence
    let leaf=S(block:.init(ArraySlice((0..<8).map(sample)))),origin=UUID()
    let first=try #require(leaf.placing(.init(.init(x:.one,y:.zero,time:.zero),origin:origin),compose:false))
    let second=try #require(leaf.placing(.init(.init(x:InkDyadic(2)!,y:.zero,time:.zero),origin:origin),compose:false))
    let pair=S.pair(first,second),root=S.pair(pair,pair),a=source([])
    let original=InkSampleRelations(sourceID:a.sourceID,span:a.span,revision:a.revision,count:root.count,
      storage:.init(root),frames:[],header:a.header)
    let restored=try check(original)
    guard case .pair(let left,let right)=restored.storage.root.content,
      case .pair(let x,let y)=left.content,
      case .shifted(let b1,let s1)=x.content,case .shifted(let b2,let s2)=y.content else { Issue.record("Lost graph structure");return }
    #expect(left === right && b1 === b2 && s1.origin == s2.origin && s1.step != s2.step)
  }

  @Test func generatorBoundaryProofNeverRoundsOrRejectsValidFields() throws {
    // The fast common lattice is conservative near IEEE endpoints and zero;
    // its bounded fallback still accepts exactly generated source fields.
    let sequences:[[Double]]=[(0..<4).map { Double($0)*pow(2,900) },
      [pow(2,53)-3,pow(2,53)-2,pow(2,53)-1,pow(2,53)],
      (0..<4).map { Double($0)*Double.leastNonzeroMagnitude }]
    for values in sequences {
      let a=source(values.enumerated().map { i,x in
        SpatialInkSample(point:.init(x:x,y:0),timeOffset:Double(i),width:1,opacity:1,force:0,azimuth:0,altitude:0)
      })
      _=try check(a)
    }
  }

  private func le<T:FixedWidthInteger>(_ n:T) -> Data {
    var n=n.littleEndian;return withUnsafeBytes(of:&n) { Data($0) }
  }
  private func graph(_ nodes:[Data]) throws -> Data {
    var prefix=try source([]).encodedRelations().dropLast(6)
    prefix.replaceSubrange((prefix.endIndex-4)..<prefix.endIndex,with:le(UInt32(nodes.count)))
    return nodes.reduce(Data(prefix),+)
  }
  private func literal(_ samples:[SpatialInkSample]) throws -> Data {
    // Existing codec emits a literal for <=3 events. Strip its checked header.
    Data(try source(samples).encodedRelations().dropFirst(117))
  }

  @Test func malformedSourcesAreRejectedBeforeArithmeticOrAllocation() throws {
    let bytes=try source([sample(0)]).encodedRelations()
    for end in bytes.indices { #expect(throws:InkSampleRelations.CodingError.self) { try InkSampleRelations(encodedRelations:bytes.prefix(end)) } }
    #expect(throws:InkSampleRelations.CodingError.self) { try InkSampleRelations(encodedRelations:bytes+Data([0])) }
    let leaf=try literal([sample(0)])
    let forward=Data([0,2])+le(UInt32(0))+le(UInt32(0))
    let oversized=Data([0,0])+le(UInt32.max)
    let badRepeat=Data([0,3])+le(UInt32(0))+le(UInt32.max)+Data(repeating:0,count:30)
    let noncanonicalStep=le(Int64(0))+le(Int16(1))+Data(repeating:0,count:20)
    let badStep=Data([0,3])+le(UInt32(0))+le(UInt32(2))+noncanonicalStep
    for nodes in [[Data([0,255])],[forward],[oversized],[leaf,leaf],[leaf,badRepeat],[leaf,badStep]] {
      let wire=try graph(nodes)
      #expect(throws:InkSampleRelations.CodingError.self) { try InkSampleRelations(encodedRelations:wire) }
    }
    // A generator with representable endpoints but an unrepresentable middle
    // must fail before Field.value's intentionally proved arithmetic runs.
    var field=Data([0,1])+le(UInt32(3))+Data([1])+le(Int64(1))+le(Int16(53))+le(Int64(1))+le(Int16(0))
    for v in [0.0,0,1,1,0,0,0] { field += Data([0])+le(v.bitPattern) }
    #expect(throws:InkSampleRelations.CodingError.self) { try InkSampleRelations(encodedRelations:graph([field])) }
    // Non-finite literal position and a negative width never reach constructors.
    for (offset,value) in [(6,Double.nan),(6+3*8,-1.0)] {
      var invalid=leaf;invalid.replaceSubrange(offset..<offset+8,with:le(value.bitPattern))
      #expect(throws:InkSampleRelations.CodingError.self) { try InkSampleRelations(encodedRelations:graph([invalid])) }
    }
    var nodes=[leaf]
    let one=le(Int64(1))+le(Int16(0))+Data(repeating:0,count:20)
    for i in 0..<128 { nodes.append(Data([0,4])+le(UInt32(i))+Data(repeating:0,count:16)+one) }
    #expect(throws:InkSampleRelations.CodingError.self) { try InkSampleRelations(encodedRelations:graph(nodes)) }
    // Deterministic mutation probe: accepted changes still pass the same exact
    // arithmetic, bounds and re-encoding, not unchecked byte reinterpretation.
    let wire=try source((0..<24).map(sample)).encodedRelations()
    for i in wire.indices {
      var changed=wire;changed[i] ^= UInt8(1 << (i%8))
      if let decoded=try? InkSampleRelations(encodedRelations:changed) {
        if decoded.count > 0 { _=decoded.sample(at:decoded.count-1) }
        _=try decoded.encodedRelations()
      }
    }
  }

  @Test func codecCostIncludesRestoreAndRetainedIndex() throws {
    func ms(_ start:ContinuousClock.Instant) -> Double {
      let d=start.duration(to:.now).components;return Double(d.seconds)*1000+Double(d.attoseconds)/1e15
    }
    var reports:[[String:Any]]=[]
    for name in ["regular-100k","irregular-100k","repeat-1m"] {
      let begin=ContinuousClock.now
      let original:InkSampleRelations
      if name == "repeat-1m" {
        original=try #require(source((0..<100).map(sample)).settingExit(.init(x:InkDyadic(32)!,y:.zero,time:.one),revision:UUID())
          .repeated(10_000,revision:UUID()))
      } else {
        let samples=(0..<100_000).map { i in
          SpatialInkSample(point:.init(x:name.hasPrefix("regular") ? Double(i)/4 : sin(Double(i))*300,
            y:name.hasPrefix("regular") ? 40 : cos(Double(i)*1.1)*300),timeOffset:Double(i)/128,width:4,
            opacity:0.5,force:0.5,azimuth:0,altitude:0.5)
        }
        original=source(samples)
      }
      let preparation=ms(begin),materializeStart=ContinuousClock.now,flat=original.decoded(),materialize=ms(materializeStart)
      var encode:[Double]=[],decode:[Double]=[],jsonEncode:[Double]=[],jsonDecode:[Double]=[],jsonRestore:[Double]=[],wireEncode:[Double]=[],wireDecode:[Double]=[]
      var bytes=Data(),json=Data(),wire=Data(),retained=0
      for _ in 0..<3 {
        var start=ContinuousClock.now;bytes=try original.encodedRelations();encode.append(ms(start))
        start = .now;let reopened=try InkSampleRelations(encodedRelations:bytes);decode.append(ms(start));retained=reopened.payloadBytes
        #expect(InkSampleRelations.sameBits(reopened.sample(at:original.count-1),flat.last!))
        start = .now;wire=try JSONEncoder().encode(original);wireEncode.append(ms(start))
        start = .now;let transported=try JSONDecoder().decode(InkSampleRelations.self,from:wire);wireDecode.append(ms(start))
        #expect(InkSampleRelations.sameBits(transported.sample(at:original.count-1),flat.last!))
        start = .now;json=try JSONEncoder().encode(flat);jsonEncode.append(ms(start))
        start = .now;let old=try JSONDecoder().decode([SpatialInkSample].self,from:json);jsonDecode.append(ms(start))
        let indexed=source(old);jsonRestore.append(ms(start))
        #expect(InkSampleRelations.sameBits(indexed.sample(at:original.count-1),flat.last!))
      }
      reports.append(["case":name,"events":original.count,"sourcePreparationMS":preparation,
        "materializeControlMS":materialize,"binaryBytes":bytes.count,"base64JSONBytes":wire.count,"base64JSONEncodeMS":wireEncode,"base64JSONDecodeAndIndexMS":wireDecode,
        "flatJSONBytes":json.count,"encodeMS":encode,"decodeMS":decode,"flatJSONEncodeMS":jsonEncode,"flatJSONDecodeMS":jsonDecode,"flatJSONAndIndexRestoreMS":jsonRestore,
        "estimatedRestoredSourceAndIndexBytes":retained,"flatSampleBufferBytes":flat.capacity*MemoryLayout<SpatialInkSample>.stride,
        "physicalNodes":original.allocationSummary.nodes])
    }
    print("INK_RELATION_CODEC_COST "+String(decoding:try JSONSerialization.data(withJSONObject:reports,options:[.sortedKeys]),as:UTF8.self))
  }
}
