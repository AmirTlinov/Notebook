import CoreGraphics
import Foundation
import Testing
@testable import NotebookCore

@Suite("Permanent element bases")
struct NotebookElementGroupingTests {
  @Test func addingTheMembershipIndexDoesNotRewriteAdmittedContent() throws {
    #expect(NotebookChangeManifest.currentFormat > 18,"An old reader must not ignore bases or the measured outer transform")
    #expect(NotebookTransportLimits.protocolVersion > 37)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-admission-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let actor = UUID(), store = NotebookStore(root:root)
    _ = try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
    let database = try NotebookSQLConnection(url:store.databaseURL,writable:true,create:false)
    let before = try database.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] }
    let header = try store.workspaceHeader()
    try database.run("DROP INDEX reference_element_children")
    try database.run("ALTER TABLE reference_element_order DROP COLUMN parent_id")
    for name in ["min_x","min_y","max_x","max_y","order","last"] {
      try database.run("DROP INDEX spatial_group_\(name)")
    }
    for name in ["insert","remove","update"] { try database.run("DROP TRIGGER spatial_range_\(name)") }
    try database.run("DROP TABLE spatial_ranges")
    try database.run("DROP INDEX spatial_item_tiles")
    for name in ["parent_id","is_group","has_paint","max_z","lower_key","space_key"] {
      try database.run("ALTER TABLE spatial_entries DROP COLUMN \(name)")
    }
    try database.run("CREATE INDEX spatial_board_tiles ON spatial_entries(board_id,min_tx,min_ty,layer,z_index,paint_key)")
    try database.run("PRAGMA user_version=12")
    let reopened = NotebookStore(root:root)
    let after = try reopened.workspaceHeader()
    #expect(after.workspaceID == header.workspaceID && after.cursor == header.cursor)
    #expect(try database.rows("PRAGMA user_version").first?[0].integer == NotebookStore.currentDatabaseVersion)
    #expect(try database.rows("SELECT count(*) FROM spatial_ranges").first?[0].integer == database.rows("SELECT count(*) FROM spatial_entries").first?[0].integer)
    #expect(try database.rows("SELECT 1 FROM sqlite_master WHERE name='spatial_board_tiles'").isEmpty)
    #expect(try reopened.readScenePaintOrder(boardID:header.rootBoardID,bounds:.init(origin:.init(x:-1000,y:-1000),width:2000,height:2000)).entries.count == 1)
    #expect(try database.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] } == before)
  }

  @Test func nonpaintingWholeFrameMayCrossPaperWithoutChangingMemberCoordinates() throws {
    let whole=AgentElement(id:"whole",kind:.group,frame:.init(x:-40,y:-30,width:400,height:400),source:"",html:"",
      basis:.init(size:.init(x:400,y:400)))
    let child=AgentElement(id:"text",kind:.nativeText,frame:.init(x:80,y:90,width:100,height:40),source:"Visible",html:"",parentID:whole.id)
    let page=PageDocument(size:.init(width:834,height:1194),actor:UUID(),elements:[whole,child])
    #expect(page.isValid)
    let restored=try JSONDecoder().decode(PageDocument.self,from:JSONEncoder().encode(page))
    #expect(restored == page)
    #expect(restored.graphicGraph().placement(child.id)?.transform.tx == 40)
    #expect(restored.graphicGraph().placement(child.id)?.transform.ty == 60)
    let invalid=AgentElement(id:whole.id,kind:.group,frame:.init(x:-2_000_000,y:0,width:400,height:400),source:"",html:"",basis:whole.basis)
    #expect(!PageDocument.elementsAreValid([invalid,child],in:page.size))
  }

  @Test func fittedNativeBoundsSurviveIndexedQueriesWholePoseAndVersion15Admission() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("native-bound-index-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
    let origin=WorldPoint(tileX:1_000_000_000_000,tileY:-1_000_000_000_000,localX:3,localY:7)
    let basis=NotebookElementBasis(size:.init(x:200,y:120),transform:.init(a:0,b:1,c:-1,d:0,tx:1,ty:0))
    let text=SpatialElement(id:"text",surface:.board(target.id),kind:.nativeText,
      frame:.init(x:10,y:20,width:100,height:10),worldOrigin:.zero,source:"12345\n67890\nABCDE",textStyle:.init(fontSize:20),
      parentID:"whole",basis:.init(size:.init(x:100,y:10),transform:.init(a:-1,b:0,c:0,d:1,tx:1,ty:0)),stamp:.init(counter:0,actor:actor))
    let whole=SpatialElement(id:"whole",surface:.board(target.id),kind:.group,frame:.init(x:40,y:30,width:240,height:600),
      worldOrigin:origin,source:"",basis:basis,stamp:text.stamp)
    let operations=try [whole,text].map { element -> CollaborationOperation in
      guard case .object(var values)=try JSONValue.encode(element) else { preconditionFailure() }
      values.removeValue(forKey:"id");values.removeValue(forKey:"stamp");values.removeValue(forKey:"surface")
      return .init(kind:.insertElement,target:target,id:element.id,values:values)
    }
    _ = try store.applyNativeElementEdits(operations,summary:"Вложенный текст",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    let local=try NotebookElementPlacement(id:text.id,frame:.init(x:10,y:20,width:100,height:10))
      .updating(frame:.init(x:10,y:20,width:100,height:10),basis:text.basis)
    let localBounds=NotebookElementPresentation(text,placement:local).bounds
    #expect(localBounds.height>10)
    let group=try #require(try store.readElementGroup(target:target,elementID:whole.id))
    #expect(group.localBounds == localBounds)
    let placed=try #require(try store.readElementPlacement(target:target,elementID:text.id))
    let shown=NotebookElementPresentation(text,placement:placed)
    let p=CGPoint(x:10,y:shown.localBounds.maxY-2).applying(placed.transform)
    func ids(_ store:NotebookStore,_ point:CGPoint,poses:[String:NotebookElementPlacement.Source] = [:]) throws -> [WorkspaceSpatialID] {
      try store.readScenePaintOrder(boardID:target.id,bounds:.init(origin:origin.offsetBy(x:point.x,y:point.y),width:1,height:1),groupPoses:poses).entries.map(\.id)
    }
    #expect(try ids(store,p) == [.element(text.id)],"A viewport seeing only the final line must admit the text")
    var pose=group.source;pose.frame = .init(x:140,y:80,width:240,height:600)
    #expect(try ids(store,.init(x:p.x+100,y:p.y+50),poses:[whole.id:pose]) == [.element(text.id)])
    let damage=try store.readGroupPoseDamage(boardID:target.id,groupPoses:[whole.id:pose])
    #expect(damage.count == 2)
    let board=try store.loadBoard(items:store.loadIndex().items).board(target.id)!
    #expect(board.graphicGraph().groupBounds(whole.id) == shown.bounds)
    let db=try NotebookSQLConnection(url:store.databaseURL,writable:true,create:false)
    let hashes=try db.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] },cursor=try store.currentChangeCursor()
    try db.run("ALTER TABLE spatial_entries ADD COLUMN non_graphic INTEGER NOT NULL DEFAULT 0")
    try db.run("CREATE INDEX spatial_group_non_graphic ON spatial_entries(board_id,parent_id,non_graphic)")
    // Emulate the old derived native rectangle; no authored source is touched.
    try db.run("UPDATE spatial_entries SET min_tx=0,min_ty=0,min_x=10,min_y=20,max_tx=0,max_ty=0,max_x=110,max_y=30 WHERE paint_key='text'")
    try db.run("PRAGMA user_version=15")
    let reopened=NotebookStore(root:root)
    #expect(try ids(reopened,p) == [.element(text.id)])
    #expect(try reopened.readElementGroup(target:target,elementID:whole.id)?.localBounds == localBounds)
    #expect(try reopened.currentChangeCursor() == cursor)
    #expect(try reopened.workspaceHeader().workspaceID == header.workspaceID)
    #expect(try db.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] } == hashes)
    #expect(try !db.rows("PRAGMA table_info(spatial_entries)").contains { $0[1].text == "non_graphic" })
  }

  @Test func completeGroupReadSurvivesLocalIndexAdmissionAndMemberDeletion() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("group-summary-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID(),header=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let target=CollaborationTarget(kind:.board,id:header.rootBoardID)
    func source(_ id:String) throws -> NotebookNativeElementSource {
      try .init(target:target,id:id,spatial:store.readSpatialElement(boardID:target.id,elementID:id))
    }
    let operations=try ["a","b","text"].enumerated().map { i,id in
      var values:[String:JSONValue]=["kind":.string(id == "text" ? "nativeText" : "graphic"),"source":.string(""),
        "worldOrigin":try .encode(WorldPoint.zero),"frame":try .encode(PageRect(x:Double(i)*50,y:0,width:20,height:30))]
      if id != "text" { values["graphic"] = try .encode(NotebookGraphic(shape:.rectangle)) }
      return CollaborationOperation(kind:.insertElement,target:target,id:id,values:values)
    }
    _ = try store.applyNativeElementEdits(operations,summary:"Смешанные участники",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    _ = try store.groupNativeElements([source("a"),source("b")],id:"inner",actor:actor)
    _ = try store.groupNativeElements([source("inner"),source("text")],id:"outer",actor:actor)
    let inner=try #require(try store.readElementGroup(target:target,elementID:"inner"))
    let outer=try #require(try store.readElementGroup(target:target,elementID:"outer"))
    #expect(inner.isSelfContained && outer.isSelfContained)
    #expect(inner.localBounds == CGRect(x:0,y:0,width:70,height:30))
    #expect(outer.localBounds == CGRect(x:0,y:0,width:120,height:30))
    #expect(try store.readElementGroup(target:target,elementID:"a") == nil)
    let db=try NotebookSQLConnection(url:store.databaseURL,writable:true,create:false)
    let hashes=try db.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] }
    let cursor=try store.currentChangeCursor()
    try db.run("ALTER TABLE spatial_entries ADD COLUMN non_graphic INTEGER NOT NULL DEFAULT 0")
    try db.run("CREATE INDEX spatial_group_non_graphic ON spatial_entries(board_id,parent_id,non_graphic)")
    try db.run("PRAGMA user_version=15")
    let reopened=NotebookStore(root:root)
    #expect(try reopened.readElementGroup(target:target,elementID:"inner") == inner)
    #expect(try reopened.readElementGroup(target:target,elementID:"outer") == outer)
    #expect(try reopened.currentChangeCursor() == cursor)
    #expect(try db.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] } == hashes)
    _ = try reopened.applyNativeElementEdits([.init(kind:.removeElement,target:target,id:"text")],summary:"Убрать текст",sources:[source("text")],actor:actor)
    #expect(try reopened.readElementGroup(target:target,elementID:"outer")?.localBounds == inner.localBounds)
    for id in ["a","b"] {
      _ = try reopened.applyNativeElementEdits([.init(kind:.removeElement,target:target,id:id)],summary:"Убрать фигуру",sources:[source(id)],actor:actor)
    }
    let empty=try #require(try reopened.readElementGroup(target:target,elementID:"outer"))
    #expect(empty.localBounds.isNull)
  }

  @Test(arguments:[false,true]) func nestedPoseIsOneAddressAndKeepsChildEditsAfterUndo(onBoard: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("groups-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let actor = UUID(), store = NotebookStore(root:root)
    let (workspace,_) = try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
    _ = try store.loadOrCreateSpatialInk(actor:actor)
    let target = CollaborationTarget(kind:onBoard ? .board : .page,id:onBoard ? workspace.rootBoardID : workspace.selectedPageID!)
    // A distant board origin must not be flattened through an absolute Double.
    let origin = onBoard ? WorldPoint(tileX:1_000_000_000,tileY:-1_000_000_000,localX:0,localY:0) : .zero
    func source(_ id: String) throws -> NotebookNativeElementSource {
      try .init(target:target,id:id,page:onBoard ? nil : store.readPageElement(pageID:target.id,elementID:id),
        spatial:onBoard ? store.readSpatialElement(boardID:target.id,elementID:id) : nil)
    }
    func raw(_ id: String) throws -> JSONValue {
      let value = try source(id)
      return try onBoard ? .encode(#require(value.spatial)) : .encode(#require(value.page))
    }
    func edit(_ id: String,_ patch: [String:JSONValue]) throws -> CollaborationReceipt {
      try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:id,values:patch)],
        summary:"Изменить основание",sources:[source(id)],actor:actor).receipt
    }
    var operations: [CollaborationOperation] = []
    for (index,id) in ["a","interleaved","b","c"].enumerated() {
      let graphic = NotebookGraphic(shape:index%2 == 0 ? .rectangle : .ellipse,style:.init(strokeWidth:3,fill:.black),label:id)
      var fields: [String:JSONValue] = ["kind":.string("graphic"),"source":.string(""),"graphic":try .encode(graphic),
        "frame":try .encode(PageRect(x:40+Double(index)*80,y:60,width:50,height:70))]
      if onBoard { fields["worldOrigin"] = try .encode(origin) }
      operations.append(.init(kind:.insertElement,target:target,id:id,values:fields))
    }
    _ = try store.applyNativeElementEdits(operations,summary:"Создать фигуры",sources:operations.map { .init(target:target,id:$0.id!) },actor:actor)
    let before = try ["a","interleaved","b","c"].map { try #require(try store.readElementPlacement(target:target,elementID:$0)) }
    let unchangedMiddle = try raw("interleaved")
    _ = try store.groupNativeElements([source("a"),source("b")],id:"inner",actor:actor)
    _ = try store.groupNativeElements([source("inner"),source("c")],id:"outer",actor:actor)
    #expect(try store.readElementChildren(target:target,parentID:"inner",limit:1) == ["a"])
    #expect(try store.readElementChildren(target:target,parentID:"inner",afterElementID:"a",limit:1) == ["b"])
    #expect(try store.readElementChildren(target:target,parentID:"outer") == ["c","inner"])
    #expect(try store.readElementChildren(target:target,parentID:nil) == ["interleaved","outer"])
    #expect(throws:CollaborationError.self) { try edit("outer",["parentID":.string("inner")]) }
    #expect(throws:CollaborationError.self) { try edit("a",["parentID":.string("missing")]) }
    for (id,old) in zip(["a","interleaved","b","c"],before) {
      let current = try #require(try store.readElementPlacement(target:target,elementID:id))
      #expect(current.origin == old.origin)
      #expect(current.transform == old.transform)
    }
    #expect(try raw("interleaved") == unchangedMiddle)
    let order = onBoard ? try store.loadBoard(items:store.loadIndex().items).board(target.id)!.elements.map(\.id)
      : try store.loadPage(target.id).elements.map(\.id)
    #expect(Array(order.prefix(4)) == ["a","interleaved","b","c"])
    let children = try ["a","b","c","inner"].map(raw)
    let oldOuter = try raw("outer")
    let oldFrame = try oldOuter["frame"]!.decode(PageRect.self)
    let size = try oldOuter["basis"]!.decode(NotebookElementBasis.self).size
    let turn = NotebookGraphicTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
    let posed = try edit("outer",["frame":try .encode(PageRect(x:oldFrame.x+15,y:oldFrame.y+25,width:oldFrame.height*2,height:oldFrame.width)),
      "basis":try .encode(NotebookElementBasis(size:size,transform:turn))])
    #expect(posed.action.operations.count == 1)
    #expect(posed.changes.allSatisfy { $0.path.contains(.member("outer")) })
    #expect(try ["a","b","c","inner"].map(raw) == children)
    #expect(try store.readElementChildren(target:target,parentID:"inner") == ["a","b"])
    let placed = try #require(try store.readElementPlacement(target:target,elementID:"a"))
    #expect(placed.ancestors == ["inner","outer"])
    let resolved = try #require(try store.readGraphicResolution(target:target,elementID:"a").layout)
    let loadedGraph = onBoard ? try store.loadBoard(items:store.loadIndex().items).board(target.id)!.graphicGraph()
      : try store.loadPage(target.id).graphicGraph()
    #expect(resolved == loadedGraph.resolve("a").layout)
    #expect(resolved.projection != nil)
    #expect(resolved.frame.width == placed.bounds.width && resolved.frame.height == placed.bounds.height)
    let point = CGPoint(x:7,y:11).applying(placed.transform)
    let expected = CGPoint(x:oldFrame.x+15+(oldFrame.height-11)*2,y:oldFrame.y+25+7)
    #expect(abs(point.x-expected.x) < 1e-10 && abs(point.y-expected.y) < 1e-10)
    _ = try edit("a",["graphic":.object(["label":.string("Локальная правка")])])
    let reopened = NotebookStore(root:root)
    _ = try reopened.undoCollaborationAction(posed.id,actor:actor)
    let restored = try #require(try reopened.readElementPlacement(target:target,elementID:"a"))
    #expect(restored.transform == before[0].transform)
    #expect(try raw("a")["graphic"]?["label"] == .string("Локальная правка"))
  }

  @Test func malformedBasisAndMissingParentAreNotInventedGeometry() throws {
    #expect(!NotebookElementBasis(size:.init(x:0,y:10)).isValid)
    #expect(!NotebookElementBasis(size:.init(x:10,y:10),transform:.init(a:0,b:0,c:0,d:0,tx:0,ty:0)).isValid)
    let basis = NotebookElementBasis(size:.init(x:20,y:10),transform:.init(a:-1,b:0,c:0,d:1,tx:1,ty:0))
    #expect(basis.isValid)
    let point = try CGPoint(x:3,y:4).applying(basis.placement(in:.init(x:10,y:20,width:40,height:30)))
    #expect(point == .init(x:44,y:32))
    #expect(try JSONValue.encode(basis).decode(NotebookElementBasis.self) == basis)
    #expect(!NotebookElementBasis.validParent("a",childID:"a"))
    let tiny = NotebookElementBasis(size:.init(x:.leastNonzeroMagnitude,y:10))
    #expect(tiny.isValid)
    #expect(throws:NotebookStorageError.self) { try tiny.placement(in:.init(x:0,y:0,width:40,height:30)) }
  }
}
