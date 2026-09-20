import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Test("Whole pose and small visible window do not visit 100000 child sources")
func groupSpatialIndexAtOneHundredThousandElements() throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-scale-\(UUID())")
  defer { try? FileManager.default.removeItem(at:root) }
  let store=NotebookStore(root:root),actor=UUID()
  let header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
  let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
  let parent="board.json#/boards/@"+header.rootBoardID.uuidString.lowercased()
  let stamp=VersionStamp(counter:0,actor:actor)
  let origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
  let whole=SpatialElement(id:"whole",surface:.board(target.id),kind:.group,
    frame:.init(x:0,y:0,width:500_000,height:100),worldOrigin:origin,source:"",basis:.init(size:.init(x:500_000,y:100)),stamp:stamp)
  let seed=ContinuousClock.now
  try store.commandTransaction {
    func write(_ element: SpatialElement,_ position: Int) throws {
      try store.writeFragment(.init(address:parent+"/board/elements/@"+element.id,file:"board.json",parent:parent,
        collection:"board/elements",member:element.id,position:position,value:try .encode(element),collections:[]),database:store.currentSQL!)
    }
    try write(whole,100_000)
    for i in 0..<100_000 {
      try write(.init(id:"shape-\(i)",surface:.board(target.id),kind:.nativeText,
        frame:.init(x:Double(i)*5,y:0,width:2,height:3),worldOrigin:.zero,source:"\(i)",parentID:"whole",stamp:stamp),i)
    }
  }
  print("GROUP_SPATIAL_SEED children=100000 elapsed=\(seed.duration(to:.now))")
  final class Counter { var steps=0;var spatialRows=0;var sourceRows=0 }
  let counter=Counter(),db=try NotebookSQLConnection(url:store.databaseURL,writable:true)
  // The full public command, its causal publication and all derived-index work
  // remain inside the hooks; a child-body read would exhaust the read allowance.
  sqlite3_update_hook(db.handle,{ raw,_,_,table,_ in
    let c=Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue()
    switch String(cString:table!) { case "spatial_entries":c.spatialRows += 1;case "records":c.sourceRows += 1;default:break }
  },Unmanaged.passUnretained(counter).toOpaque())
  sqlite3_progress_handler(db.handle,1,{ raw in
    let c=Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue();c.steps += 1;return c.steps>100_000 ? 1 : 0
  },Unmanaged.passUnretained(counter).toOpaque())
  defer { sqlite3_update_hook(db.handle,nil,nil);sqlite3_progress_handler(db.handle,0,nil,nil) }
  let pose=ContinuousClock.now
  try store.commandTransaction(readAllowance:.init(rows:1000,bytes:1_000_000,valueBytes:100_000,reason:"A whole pose must not decode child sources"),preparedDatabase:db) {
    _ = try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"whole",
      values:["frame":try .encode(PageRect(x:400,y:50,width:1_000_000,height:300))])],summary:"Растянуть целое",
      sources:[.init(target:target,id:"whole",spatial:whole)],actor:actor)
  }
  print("GROUP_SPATIAL_POSE children=100000 elapsed=\(pose.duration(to:.now)) vm_steps=\(counter.steps) spatial_row_writes=\(counter.spatialRows) record_row_writes=\(counter.sourceRows)")
  #expect(counter.spatialRows == 2)
  #expect(counter.sourceRows < 32)
  sqlite3_update_hook(db.handle,nil,nil);sqlite3_progress_handler(db.handle,0,nil,nil)
  counter.steps=0
  let window=WorkspaceSpatialBounds(origin:origin.offsetBy(x:400+99_994*10,y:50),width:54,height:9)
  let read=ContinuousClock.now
  try store.readTransaction { _ in
    let sql=store.currentSQL!
    try sql.limitReads(.init(rows:64,bytes:40_000,valueBytes:8_000,reason:"Only visible index entries and their basis may be read"))
    sqlite3_progress_handler(sql.handle,1,{ raw in
      let c=Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue();c.steps += 1;return c.steps>20_000 ? 1 : 0
    },Unmanaged.passUnretained(counter).toOpaque())
    defer { sqlite3_progress_handler(sql.handle,0,nil,nil) }
    let page=try store.readScenePaintOrder(boardID:target.id,bounds:window)
    #expect(page.entries.map(\.id) == (99_994..<100_000).map { .element("shape-\($0)") })
    #expect(page.next == nil)
  }
  print("GROUP_SPATIAL_QUERY children=100000 visible=6 elapsed=\(read.duration(to:.now)) vm_steps=\(counter.steps) read_rows_budget=64")
}
