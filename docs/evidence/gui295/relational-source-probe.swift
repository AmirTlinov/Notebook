import Foundation
import NotebookCore

func millis<T>(_ run: () throws -> T) rethrows -> (T,Double) {
  let start=ContinuousClock.now,value=try run(),d=start.duration(to:.now).components
  return (value,Double(d.seconds)*1000+Double(d.attoseconds)/1e15)
}
func sample(_ i:Int) -> SpatialInkSample {
  let p=SpatialPoint(x:Double(i)/4,y:10*sin(Double(i)/1000))
  return .init(point:p,timeOffset:Double(i)/128,width:4,opacity:1,force:1,azimuth:0,altitude:1)
}
func source(_ samples:[SpatialInkSample]) -> InkSampleRelations {
  .init(sourceID:UUID(),revision:UUID(),samples:samples,header:.init(tool:.pen,color:.black))
}
@main struct Probe {
  static func main() throws {
    var rows:[[String:Any]]=[]
    for n in [10_000,100_000] {
      let samples=(0..<n).map { sample($0) }
      let (control,encodeMS)=millis { source(samples) }
      let index=n*3/4,prior=samples[index-1]
      let changed=SpatialInkSample(point:.init(x:prior.point.x+0.00001,y:prior.point.y),timeOffset:samples[index].timeOffset,width:4,opacity:1,force:1,azimuth:0,altitude:1)
      let altered=try control.editing(control.address(at:index),to:changed,revision:UUID())
      for (name,value) in [("regular_curve",control),("one_distant_near_coincident_pair",altered)] {
        var times:[Double]=[],prepared=0,visits=0,chunks=0,reads=0,kind="",bytes=0
        for _ in 0..<6 {
          let (display,ms)=millis { SpatialInkGeometry.Source(source:value,projection:.init()) }
          times.append(ms);prepared=display.preparedNodeCount;bytes=display.auxiliaryBytes
          switch display.storage { case .relative:kind="relative";case .prepared:kind="prepared" }
          let query=display.query(viewport:.init(x:0,y:-20,width:100,height:40),affine:.init())
          visits=query.cost.visitedNodes;chunks=query.chunks.count;reads=query.cost.decodedSamples
          for selection in query.chunks { reads += display.prepare(selection).decodedPoints }
        }
        let warm=times.dropFirst().sorted()
        rows.append(["case":name,"logicalEvents":n,"sourceConstructionMs":encodeMS,"displayMode":kind,
          "displayConstructionFirstMs":times[0],"displayConstructionWarmMedianMs":warm[warm.count/2],
          "preparedBeforeViewportQuery":prepared,"derivedBytes":bytes,"visibleChunks":chunks,"queryNodeVisits":visits,
          "queryAndPreparationReads":reads,"allDisplayConstructionMs":times])
        if name == "regular_curve" { precondition(kind == "relative" && prepared == 0) }
        else { precondition(kind == "prepared" && prepared > n/2) }
      }
    }
    let localSamples=(0..<100_000).map { sample($0) }
    let worldSamples=localSamples.map { p in
      SpatialInkSample(point:.zero,worldPoint:WorldPoint.zero.offsetBy(x:p.point.x,y:p.point.y),
        timeOffset:p.timeOffset,width:p.width,opacity:p.opacity,force:p.force,azimuth:p.azimuth,altitude:p.altitude)
    }
    let local=source(localSamples),world=source(worldSamples)
    rows.append(["case":"same_curve_local_vs_tiled_storage","logicalEvents":100_000,
      "localBytes":local.allocationSummary.bytes,"worldBytes":world.allocationSummary.bytes,
      "localEncodedBytes":try local.encodedRelations().count,"worldEncodedBytes":try world.encodedRelations().count,
      "scope":"payload estimates and codec bytes; not process memory or device performance"])
    let body=source((0..<100).map { i in
      SpatialInkSample(point:.init(x:Double(i)/4,y:Double(i%13)/2),timeOffset:Double(i)/128,width:4,opacity:1,force:1,azimuth:0,altitude:1)
    }).settingExit(.init(x:InkDyadic(32)!,y:.zero,time:.one),revision:UUID())
    let repeated=body.repeated(10_000,revision:UUID())!
    let (encoded,encodeMS)=try millis { try repeated.encodedRelations() }
    let (restored,decodeMS)=try millis { try InkSampleRelations(encodedRelations:encoded) }
    let index=500_027,old=restored.sample(at:index)
    let replacement=SpatialInkSample(point:.init(x:old.point.x,y:old.point.y+1),timeOffset:old.timeOffset,width:old.width,opacity:old.opacity,force:old.force,azimuth:old.azimuth,altitude:old.altitude)
    let (edited,editMS)=try millis { try restored.editing(restored.address(at:index),to:replacement,revision:UUID()) }
    for i in [0,1,index-1,index+1,999_999] { precondition(InkSampleRelations.sameBits(repeated.sample(at:i),edited.sample(at:i))) }
    precondition(InkSampleRelations.sameBits(edited.sample(at:index),replacement))
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("notebook-relation-audit-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let pageID=try store.loadIndex().selectedPageID!
    var page=try store.loadPage(pageID)
    let change=try page.prepareInkChange(.append(edited.restoredAction()),stamp:.init(counter:10,actor:actor))
    precondition(page.publishInkChange(change));_=try store.savePage(page)
    let reopened=try NotebookStore(root:root).loadPage(pageID).inkDrawing().actions.first!.samples
    precondition(reopened == edited.measurements)
    rows.append(["case":"declared_repeat_roundtrip_edit_save_reopen","logicalEvents":repeated.count,
      "originalNodes":repeated.allocationSummary.nodes,"editedNodes":edited.allocationSummary.nodes,
      "reopenedBytes":reopened.payloadBytes,"encodedBytes":encoded.count,"encodeMs":encodeMS,"decodeMs":decodeMS,"singleEditMs":editMS,
      "saveReopenExact":true,"comparedEventsOnEdit":edited.lastEdit!.work.comparedEvents,"scannedEventsOnEdit":edited.lastEdit!.work.scannedEvents])
    print(String(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
  }
}
