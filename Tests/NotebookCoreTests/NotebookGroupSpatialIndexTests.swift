import CSQLite
import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Group-local spatial index")
struct NotebookGroupSpatialIndexTests {
  @Test func readOnlyWholePosesQueryNewAndOldWindowsWithoutTouchingSources() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-query-pose-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
    let origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    func source(_ id:String) throws -> NotebookNativeElementSource {
      try .init(target:target,id:id,spatial:store.readSpatialElement(boardID:target.id,elementID:id))
    }
    for (id,x) in [("a",10.0),("middle",1230),("b",100),("outside",900)] {
      _ = try store.applyNativeElementEdits([.init(kind:.insertElement,target:target,id:id,values:[
        "kind":.string("graphic"),"source":.string(""),"worldOrigin":try .encode(origin),
        "frame":try .encode(PageRect(x:x,y:20,width:30,height:40)),"graphic":try .encode(NotebookGraphic(shape:.rectangle))])],
        summary:"Фигура",sources:[.init(target:target,id:id)],actor:actor)
    }
    _ = try store.groupNativeElements([source("a"),source("b")],id:"inner",actor:actor)
    _ = try store.groupNativeElements([source("inner"),source("outside")],id:"outer",actor:actor)
    let link=NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),
      end:.init(point:.zero,binding:.init(elementID:"middle"))))
    _ = try store.applyNativeElementEdits([.init(kind:.insertElement,target:target,id:"link",values:["kind":.string("graphic"),
      "source":.string(""),"worldOrigin":try .encode(origin),"frame":try .encode(PageRect(x:0,y:0,width:100,height:100)),"graphic":try .encode(link)])],
      summary:"Внешняя связь",sources:[.init(target:target,id:"link")],actor:actor)
    let workspace=try store.loadIndex(),board=try #require(try store.loadBoard(items:workspace.items).board(target.id)),base=board.graphicGraph()
    var pose=try #require(base.source("inner"));pose.frame = .init(x:1200,y:200,width:200,height:120)
    pose.basis = .init(size:try #require(pose.basis).size,transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    let poses=["inner":pose],projected=base.projecting(placements:poses),revision=try store.currentChangeCursor()
    let region=WorkspaceSpatialBounds(origin:origin.offsetBy(x:-50,y:-100),width:1800,height:1000)
    var entries:[WorkspaceSpatialEntry]=[],cursor:NotebookScenePaintCursor?
    repeat {
      let page=try store.readScenePaintOrder(boardID:target.id,bounds:region,after:cursor,limit:1,groupPoses:poses)
      entries += page.entries;cursor=page.next
    } while cursor != nil
    #expect(entries.map(\.id) == ["a","middle","b","outside","link"].map(WorkspaceSpatialID.element))
    for entry in entries {
      guard case .element(let id)=entry.id else { continue }
      let layout:NotebookGraphicLayout=try #require(projected.resolve(id).layout)
      #expect(try store.readGraphicResolution(target:target,elementID:id,groupPoses:poses).layout == layout)
      #expect(entry.bounds.origin == layout.origin.offsetBy(x:layout.frame.x,y:layout.frame.y))
      let tiny=WorkspaceSpatialBounds(origin:entry.bounds.origin,width:entry.bounds.width,height:entry.bounds.height)
      #expect(try store.readScenePaintOrder(boardID:target.id,bounds:tiny,groupPoses:poses).entries.contains { $0.id == entry.id })
    }
    let first=try store.readScenePaintOrder(boardID:target.id,bounds:region,limit:1,groupPoses:poses)
    let continuation=try #require(first.next)
    #expect(throws:NotebookStorageError.self) { try store.readScenePaintOrder(boardID:target.id,bounds:region,after:continuation) }
    let a=try #require(base.resolve("a").layout)
    let old=WorkspaceSpatialBounds(origin:a.origin.offsetBy(x:a.frame.x,y:a.frame.y),width:a.frame.width,height:a.frame.height)
    #expect(try !store.readScenePaintOrder(boardID:target.id,bounds:old,groupPoses:poses).entries.contains { $0.id == .element("a") })
    var outer=try #require(base.source("outer"));outer.frame = .init(x:8000,y:2000,width:outer.frame.width*2,height:outer.frame.height*2)
    let simultaneous=["inner":pose,"outer":outer],both=base.projecting(placements:simultaneous)
    let damage=try store.readGroupPoseDamage(boardID:target.id,groupPoses:simultaneous)
    for graph in [base,both] {
      for id in ["a","b","outside","link"] {
        let layout=try #require(graph.resolve(id).layout)
        let bounds=WorkspaceSpatialBounds(origin:layout.origin.offsetBy(x:layout.frame.x,y:layout.frame.y),width:layout.frame.width,height:layout.frame.height)
        #expect(damage.contains { $0.contains(bounds) },"Old and new whole bounds must include independently moved descendants and external links")
      }
    }
    #expect(!damage.contains { $0.intersects(.init(origin:origin.offsetBy(x:-10000,y:-10000),width:100,height:100)) })
    var invalid=pose;invalid.parentID=nil
    #expect(throws:NotebookStorageError.self) { try store.readScenePaintOrder(boardID:target.id,bounds:region,groupPoses:["inner":invalid]) }
    #expect(try store.currentChangeCursor() == revision)
    #expect(try store.loadBoard(items:workspace.items).board(target.id) == board)
  }

  @Test func unrepresentableDerivedBoundsRefuseThePoseWithoutArithmeticTraps() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-limits-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    let header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
    let inserts: [CollaborationOperation] = try ["a","b"].map { id in
      .init(kind:.insertElement,target:target,id:id,values:["kind":.string("graphic"),"source":.string(""),
        "worldOrigin":try .encode(WorldPoint.zero),"frame":try .encode(PageRect(x:10,y:10,width:100,height:100)),
        "graphic":try .encode(NotebookGraphic(shape:.rectangle))])
    }
    _ = try store.applyNativeElementEdits(inserts,summary:"Фигуры",sources:inserts.map { .init(target:target,id:$0.id!) },actor:actor)
    _ = try store.groupNativeElements(["a","b"].map { try .init(target:target,id:$0,spatial:store.readSpatialElement(boardID:target.id,elementID:$0)) },id:"whole",actor:actor)
    let original=try #require(try store.readSpatialElement(boardID:target.id,elementID:"whole"))
    let before=try store.currentChangeCursor()
    #expect(throws:NotebookStorageError.self) {
      _ = try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"whole",values:[
        "basis":try .encode(NotebookElementBasis(size:.init(x:1e-100,y:1e-100)))])],summary:"Предельное основание",
        sources:[.init(target:target,id:"whole",spatial:original)],actor:actor)
    }
    #expect(try store.currentChangeCursor() == before)
    #expect(try store.readSpatialElement(boardID:target.id,elementID:"whole") == original)
    #expect(throws:NotebookStorageError.self) { try NotebookElementBasis.spatialBounds(.init(x:0,y:0,width:1e100,height:1)) }
    let a=WorldPoint(tileX:.min,tileY:.max,localX:0,localY:0),b=WorldPoint(tileX:.max,tileY:.min,localX:0,localY:0)
    #expect(a.delta(to:b).x == -b.delta(to:a).x)
    #expect(a.projectionOffset(x:-WorldPoint.tileSize,y:0) == nil)
  }

  @Test func lateAncestorsAndBrokenCyclesRecoverWithoutConflatingIDs() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-arrival-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    let header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let board=header.rootBoardID,address="board.json#/boards/@"+board.uuidString.lowercased()
    let stamp=VersionStamp(counter:0,actor:actor),innerID=UUID().uuidString
    func write(_ element: SpatialElement,_ position: Int) throws {
      try store.commandTransaction {
        _ = try store.writeFragment(.init(address:address+"/board/elements/@"+fieldKey([collaborationIdentity(element.id)]),
          file:"board.json",parent:address,collection:"board/elements",member:element.id,position:position,
          value:try .encode(element),collections:[]),database:store.currentSQL!)
      }
    }
    func group(_ id: String,_ parent: String?,_ x: Double) -> SpatialElement {
      .init(id:id,surface:.board(board),kind:.group,frame:.init(x:x,y:0,width:100,height:100),worldOrigin:.zero,
        source:"",parentID:parent,basis:.init(size:.init(x:100,y:100)),stamp:stamp)
    }
    let leaf=SpatialElement(id:"leaf",surface:.board(board),kind:.graphic,frame:.init(x:5,y:5,width:10,height:10),
      worldOrigin:.zero,source:"",graphic:.init(shape:.rectangle),parentID:innerID.lowercased(),stamp:stamp)
    let window=WorkspaceSpatialBounds(origin:.init(x:110,y:0),width:40,height:40)
    func visible() throws -> [WorkspaceSpatialID] { try store.readScenePaintOrder(boardID:board,bounds:window).entries.map(\.id).filter { if case .element=$0 { return true };return false } }
    try write(leaf,0)
    try write(group(innerID,"outer/~A",10),1)
    #expect(try visible().isEmpty)
    try write(group("outer/~A",nil,100),2)
    #expect(try visible() == [.element("leaf")])
    // Simulate delivered concurrent parent registers, not an authored action:
    // native commands already reject cycles. No canonical record is repaired.
    try write(group("outer/~A",innerID.lowercased(),100),2)
    #expect(try visible().isEmpty)
    #expect(try store.readSpatialElement(boardID:board,elementID:"leaf") == leaf)
    try write(group("outer/~A",nil,100),2)
    #expect(try visible() == [.element("leaf")])
    // Arbitrary case-sensitive names and escaped address segments are distinct.
    try write(group("outer/~a",nil,10_000),3)
    let foreign=SpatialElement(id:"foreign",surface:leaf.surface,kind:leaf.kind,frame:leaf.frame,
      worldOrigin:.zero,source:"",graphic:leaf.graphic,parentID:"outer/~a",stamp:stamp)
    try write(foreign,4)
    try store.commandTransaction {
      try store.currentSQL!.run("UPDATE spatial_entries SET space_key=? WHERE paint_key='foreign'",
        [.integer(NotebookStore.spatialSpaceKey(board:board.uuidString.lowercased(),parent:innerID.lowercased()))])
    }
    #expect(try visible() == [.element("leaf")],"A lossy broad-phase collision is never a member identity")
  }

  @Test func wholePoseKeepsChildRowsAndFlatPaintOrderButUpdatesCrossBoundaryLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-space-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    let header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
    let origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    func source(_ id: String) throws -> NotebookNativeElementSource {
      try .init(target:target,id:id,spatial:store.readSpatialElement(boardID:target.id,elementID:id))
    }
    func insert(_ id: String,_ frame: PageRect,_ graphic: NotebookGraphic = .init(shape:.rectangle)) throws {
      _ = try store.applyNativeElementEdits([.init(kind:.insertElement,target:target,id:id,
        values:["kind":.string("graphic"),"source":.string(""),"frame":try .encode(frame),"worldOrigin":try .encode(origin),"graphic":try .encode(graphic)])],
        summary:"Фигура",sources:[.init(target:target,id:id)],actor:actor)
    }
    func edit(_ id: String,_ fields: [String:JSONValue]) throws {
      _ = try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:id,values:fields)],
        summary:"Правка",sources:[source(id)],actor:actor)
    }
    try insert("a",.init(x:10,y:20,width:30,height:40))
    try insert("middle",.init(x:55,y:20,width:30,height:40))
    try insert("b",.init(x:100,y:20,width:30,height:40))
    let internalLine=NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),
      end:.init(point:.init(x:100,y:0),binding:.init(elementID:"b")),bend:15))
    try insert("internal",.init(x:10,y:20,width:130,height:60),internalLine)
    try insert("c",.init(x:300,y:20,width:30,height:40))
    _ = try store.groupNativeElements([source("a"),source("b"),source("internal")],id:"inner",actor:actor)
    _ = try store.groupNativeElements([source("inner"),source("c")],id:"outer",actor:actor)
    func graph() throws -> NotebookGraphicGraph { try store.loadBoard(items:store.loadIndex().items).board(target.id)!.graphicGraph() }
    func query(_ bounds: WorkspaceSpatialBounds) throws -> [WorkspaceSpatialEntry] {
      var result: [WorkspaceSpatialEntry]=[],cursor: NotebookScenePaintCursor?
      repeat {
        let next=try store.readScenePaintOrder(boardID:target.id,bounds:bounds,after:cursor,limit:1)
        result += next.entries;cursor=next.next
      } while cursor != nil
      return result
    }
    let region=WorkspaceSpatialBounds(origin:origin.offsetBy(x:-50,y:-100),width:800,height:1000)
    #expect(try query(region).map(\.id) == ["a","middle","b","internal","c"].map(WorkspaceSpatialID.element))
    let before=try source("a").spatial
    let body=try #require(try graph().resolve("internal",space:.parent).layout)
    final class Counter { var rows=0 }
    let counter=Counter()
    try store.commandTransaction {
      let db=store.currentSQL!
      sqlite3_update_hook(db.handle,{ raw,_,_,table,_ in
        if String(cString:table!) == "spatial_entries" { Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue().rows += 1 }
      },Unmanaged.passUnretained(counter).toOpaque())
      defer { sqlite3_update_hook(db.handle,nil,nil) }
      // Nested public commands share this transaction; settle its normal index
      // before dropping the hook so the counter includes all derived work.
      let outer=try #require(try source("outer").spatial),basis=try #require(outer.basis)
      try edit("outer",["frame":try .encode(PageRect(x:90,y:80,width:120,height:640)),
        "basis":try .encode(NotebookElementBasis(size:basis.size,transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0)))])
      try store.refreshGraphicIndex(database:db);try store.refreshElementGroupIndex(database:db)
    }
    #expect(counter.rows == 2,"Only the outer row is replaced; child bounds and internal link remain local")
    #expect(try source("a").spatial == before)
    #expect(try graph().resolve("internal",space:.parent).layout == body)
    let moved=try graph(),actual=try query(region)
    #expect(actual.map(\.id) == ["a","middle","b","internal","c"].map(WorkspaceSpatialID.element))
    for entry in actual {
      guard case .element(let id)=entry.id else { continue }
      let layout=try #require(moved.resolve(id).layout)
      let expected=WorkspaceSpatialBounds(origin:layout.origin.offsetBy(x:layout.frame.x,y:layout.frame.y),width:layout.frame.width,height:layout.frame.height)
      #expect(entry.bounds.origin == expected.origin && entry.bounds.maximum == expected.maximum)
    }
    let external=NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),
      end:.init(point:.init(x:200,y:0),binding:.init(elementID:"middle"))))
    try insert("external",.init(x:0,y:0,width:200,height:100),external)
    let oldExternal=try #require(try graph().resolve("external").layout)
    let outer=try #require(try source("outer").spatial)
    try edit("outer",["frame":try .encode(PageRect(x:outer.frame.x+40,y:outer.frame.y,width:outer.frame.width,height:outer.frame.height))])
    let newExternal=try #require(try graph().resolve("external").layout)
    #expect(oldExternal != newExternal)
    let indexed=try #require(try query(region).first { $0.id == .element("external") })
    #expect(indexed.bounds.origin == newExternal.origin.offsetBy(x:newExternal.frame.x,y:newExternal.frame.y))
    // A local edit outside the original body grows ancestors' derived bounds,
    // not their authored frame or every sibling's global rectangle.
    try edit("b",["frame":try .encode(PageRect(x:5000,y:20,width:30,height:40))])
    let far=try #require(try graph().resolve("b").layout)
    let window=WorkspaceSpatialBounds(origin:far.origin.offsetBy(x:far.frame.x,y:far.frame.y),width:far.frame.width,height:far.frame.height)
    #expect(try query(window).contains { $0.id == .element("b") })
    let cut=try store.readSceneWindow(boardID:target.id,bounds:window)
    let members=Set(cut.boards.flatMap { $0.board.elements.map(\.id) })
    #expect(members.isSuperset(of:["b","inner","outer"]))
  }
}
