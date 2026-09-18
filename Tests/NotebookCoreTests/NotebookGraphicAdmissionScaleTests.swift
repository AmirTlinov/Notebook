import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Test("Допуск 96 векторов и их соседей остаётся адресным среди 100000 элементов")
func graphicAdmissionAtOneHundredThousandElements() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-admission-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root), actor = UUID()
  let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
  let parent = "board.json#/boards/@" + header.rootBoardID.uuidString.lowercased()
  let stamp = VersionStamp(counter: 0, actor: actor), started = ContinuousClock.now
  // Real addressed source records and their normal derived indexes. The
  // fixture streams, without decoding a 100000-element BoardDocument.
  try store.commandTransaction {
    for index in 0..<100_000 {
      let id = "shape-\(index)"
      let element = SpatialElement(id: id, surface: .board(header.rootBoardID), kind: .nativeText,
        frame: .init(x: 0, y: 0, width: 24, height: 24), worldOrigin: .init(x: Double(index) * 50, y: 0),
        source: "\(index)", stamp: stamp)
      try store.writeFragment(.init(address: parent + "/board/elements/@" + id, file: "board.json", parent: parent,
        collection: "board/elements", member: id, position: index, value: try .encode(element), collections: []), database: store.currentSQL!)
    }
  }
  print("GRAPHIC_ADMISSION_SEED count=100000 elapsed=\(started.duration(to: .now))")
  final class Counter { var steps = 0 }
  let counter = Counter(), ids = (99_904..<100_000).map { "shape-\($0)" }
  try store.readTransaction { _ in
    let database = store.currentSQL!
    sqlite3_progress_handler(database.handle, 1, { raw in
      let counter = Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue()
      counter.steps += 1
      return counter.steps > 50_000 ? 1 : 0
    }, Unmanaged.passUnretained(counter).toOpaque())
    defer { sqlite3_progress_handler(database.handle, 0, nil, nil) }
    for (offset, id) in ids.enumerated() {
      #expect(try store.readScenePaintPosition(boardID: header.rootBoardID, id: .element(id))?.zIndex == Double(99_904 + offset))
    }
    let next = try store.readSceneElementSuccessors(boardID: header.rootBoardID, elementIDs: ids)
    #expect(next.count == 95)
    #expect(next[ids[0]] == ids[1])
  }
  #expect(counter.steps < 50_000)
  print("GRAPHIC_ADMISSION_SQL owners=100000 admitted=96 vm_steps=\(counter.steps)")
  let origin = WorldPoint(x:99_999 * 50,y:0)
  let target = InkElementTarget(elementID:"shape-99999",frame:.init(x:0,y:0,width:24,height:24),worldOrigin:origin)
  let sample = SpatialInkSample(point:.init(x:12,y:12),worldPoint:origin.offsetBy(x:12,y:12),
    timeOffset:0,width:60,opacity:1,force:1,azimuth:0,altitude:1)
  let action = SpatialInkAction(tool:.eraser,spans:[SpatialInkSpan(surface:.board(header.rootBoardID),samples:[sample]).erasingElements([target])],stamp:.init(counter:1,actor:actor))
  try store.commitSpatialInk(.append(action,journalStamp:action.stamp))
  counter.steps = 0
  try store.readTransaction { _ in
    let db = store.currentSQL!
    try db.limitReads(.init(rows:30,bytes:20_000,valueBytes:8_000,reason:"Erasure lookup must not read unrelated bodies"))
    sqlite3_progress_handler(db.handle,1,{ raw in
      let counter = Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue()
      counter.steps += 1; return counter.steps > 2_000 ? 1 : 0
    },Unmanaged.passUnretained(counter).toOpaque())
    defer { sqlite3_progress_handler(db.handle,0,nil,nil) }
    #expect(try store.readElementErasures(on:.board(header.rootBoardID),elementID:target.elementID).count == 1)
    #expect(try store.readElementErasures(on:.board(header.rootBoardID),elementID:"shape-0").isEmpty)
  }
  print("ELEMENT_ERASURE_SQL owners=100000 vm_steps=\(counter.steps) read_rows_budget=30")
}
