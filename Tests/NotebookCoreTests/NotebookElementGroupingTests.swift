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
    #expect(try database.rows("PRAGMA user_version").first?[0].integer == 14)
    #expect(try database.rows("SELECT count(*) FROM spatial_ranges").first?[0].integer == database.rows("SELECT count(*) FROM spatial_entries").first?[0].integer)
    #expect(try database.rows("SELECT 1 FROM sqlite_master WHERE name='spatial_board_tiles'").isEmpty)
    #expect(try reopened.readScenePaintOrder(boardID:header.rootBoardID,bounds:.init(origin:.init(x:-1000,y:-1000),width:2000,height:2000)).entries.count == 1)
    #expect(try database.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!,$0[1].text!] } == before)
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
