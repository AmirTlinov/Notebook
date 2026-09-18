import Foundation
import Testing
@testable import NotebookCore

@Suite("Atomic native graphic selections")
struct NotebookGraphicSelectionTests {
  @Test(arguments:[false,true]) func moveCopyAlignUndoAndStaleMember(onBoard: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID())")
    defer { try? FileManager.default.removeItem(at:root) }
    let actor = UUID(), store = NotebookStore(root:root)
    let (workspace,_) = try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
    _ = try store.loadOrCreateSpatialInk(actor:actor)
    let target = CollaborationTarget(kind:onBoard ? .board : .page,id:onBoard ? workspace.rootBoardID : workspace.selectedPageID!)
    let surface: SurfaceID = onBoard ? .board(target.id) : .page(target.id)
    func perform(_ operations: [CollaborationOperation]) throws -> CollaborationReceipt {
      try store.applyCollaborationAction(.init(summary:"Agent edit",expected:[.init(target:target,revision:store.targetContentRevision(target:target))],operations:operations),actor:actor)
    }
    func source(_ id: String) throws -> NotebookNativeElementSource {
      try .init(target:target,id:id,page:onBoard ? nil : store.readPageElement(pageID:target.id,elementID:id),
        spatial:onBoard ? store.readSpatialElement(boardID:target.id,elementID:id) : nil)
    }
    func element(_ id: String) throws -> AgentElement {
      let value = try source(id)
      if let page = value.page { return page }
      let spatial = try #require(value.spatial)
      return .init(id:id,kind:.graphic,frame:.init(x:spatial.frame.x,y:spatial.frame.y,width:spatial.frame.width,height:spatial.frame.height),source:"",html:"",graphic:spatial.graphic)
    }
    func values(_ graphic: NotebookGraphic, _ frame: PageRect) throws -> [String:JSONValue] {
      var v: [String:JSONValue] = ["kind":.string("graphic"),"source":.string(""),"graphic":try .encode(graphic),"frame":try .encode(frame)]
      if onBoard { v["worldOrigin"] = try .encode(WorldPoint.zero) }; return v
    }
    let link = NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),
      end:.init(point:.init(x:200,y:80),binding:.init(elementID:"b")),bend:25))
    _ = try perform([
      .init(kind:.insertElement,target:target,id:"a",values:values(.init(label:"A"),.init(x:40,y:60,width:60,height:60))),
      .init(kind:.insertElement,target:target,id:"b",values:values(.init(shape:.rectangle,label:"B"),.init(x:240,y:140,width:80,height:80))),
      .init(kind:.insertElement,target:target,id:"link",values:values(link,.init(x:40,y:60,width:200,height:80)))])
    func members() throws -> [NotebookGraphicSelection.Member] {
      let objects = try ["a","b","link"].map(element)
      let graph = NotebookGraphicGraph(objects.map { .init(id:$0.id,graphic:$0.graphic!,frame:$0.frame,surface:surface,shown:true) })
      return try objects.map { .init(id:$0.id,frame:$0.frame,graphic:$0.graphic!,layout:try #require(graph.resolve($0.id).layout)) }
    }
    func commit(_ edits: [NotebookGraphicSelection.Edit]) throws -> CollaborationReceipt {
      let operations: [CollaborationOperation] = try edits.map { edit in
        var fields: [String:JSONValue] = ["frame":try .encode(edit.frame)]
        if let connection = edit.graphic.connection { fields["graphic"] = .object(["connection":try .encode(connection)]) }
        return .init(kind:.updateElement,target:target,id:edit.id,values:fields)
      }
      return try store.applyNativeElementEdits(operations,summary:"Move selection",sources:edits.map { try source($0.id) },actor:actor).receipt
    }
    let before = try members(), translated = NotebookGraphicSelection.translated(before,by:.init(x:20,y:35))
    #expect(translated.last?.graphic.connection?.bindings.map(\.elementID) == ["a","b"])
    let moved = try commit(translated)
    #expect(moved.author == .human)
    let reopened = NotebookStore(root:root)
    _ = try reopened.undoCollaborationAction(moved.id,actor:actor)
    #expect(try members() == before)
    let aligned = NotebookGraphicSelection.aligned(before,to:.left)
    #expect(aligned.count == 2)
    #expect(aligned.allSatisfy { $0.frame.x == 40 })
    let alignedAction = try commit(aligned)
    #expect(try element("link").graphic == link)
    _ = try reopened.undoCollaborationAction(alignedAction.id,actor:actor)

    // Capture both sources; a later agent changes only B. Admission must reject
    // the entire human batch instead of moving A and silently rebasing B.
    let stale = try ["a","b"].map(source)
    _ = try perform([.init(kind:.updateElement,target:target,id:"b",values:["graphic":.object(["label":.string("Agent B")])])])
    #expect(throws:CollaborationError.self) {
      try store.applyNativeElementEdits(aligned.map { .init(kind:.updateElement,target:target,id:$0.id,values:["frame":try .encode($0.frame)]) },
        summary:"Stale selection",sources:stale,actor:actor)
    }
    #expect(try element("a").frame == before[0].frame)
    #expect(try element("b").frame == before[1].frame)
    #expect(try element("b").graphic?.label == "Agent B")

    // Complete painter order, not the selected or loaded subset. The pair's
    // relative order is retained when crossing the unselected connector.
    let arranged = try store.applyNativeElementEdits([.init(kind:.reorderElements,target:target,id:"a")],summary:"Arrange pair",
      sources:["a","b"].map(source),moveToFront:true,actor:actor)
    let order = onBoard ? try store.loadBoard(items:store.loadIndex().items).board(target.id)!.elements.map(\.id) : try store.loadPage(target.id).elements.map(\.id)
    #expect(order == ["link","a","b"])
    _ = try reopened.undoCollaborationAction(arranged.receipt.id,actor:actor)

    let removed = try store.applyNativeElementEdits(["a","b"].map { .init(kind:.removeElement,target:target,id:$0) },
      summary:"Delete pair",sources:["a","b"].map(source),actor:actor)
    #expect(try store.readGraphicResolution(target:target,elementID:"link") == .hidden)
    #expect(try element("link").graphic == link,"An unselected binding is hidden, not rewritten or detached")
    _ = try reopened.undoCollaborationAction(removed.receipt.id,actor:actor)
    #expect(try store.readGraphicResolution(target:target,elementID:"link").layout != nil)

    let current = try members(), copies = NotebookGraphicSelection.duplicated(current,namespace:UUID(),offset:.init(x:25,y:25))
    #expect(copies.allSatisfy { $0.graphic.sourceInkIDs.isEmpty })
    #expect(copies.last?.graphic.connection?.bindings.map(\.elementID) == [copies[0].id,copies[1].id])
    let inserted = try store.applyNativeElementEdits(copies.reversed().map { .init(kind:.insertElement,target:target,id:$0.id,values:try values($0.graphic,$0.frame)) },
      summary:"Duplicate",sources:(current.map(\.id)+copies.map(\.id)).map(source),
      copiedFrom:Dictionary(uniqueKeysWithValues:zip(copies,current).map { ($0.id,$1.id) }),actor:actor)
    #expect(try element(copies[0].id).graphic?.label == "A")
    let copiedOrder = onBoard ? try store.loadBoard(items:store.loadIndex().items).board(target.id)!.elements.map(\.id) : try store.loadPage(target.id).elements.map(\.id)
    #expect(Array(copiedOrder.suffix(3)) == copies.map(\.id), "Picking order cannot reverse the copied painter order")
    _ = try reopened.undoCollaborationAction(inserted.receipt.id,actor:actor)
    #expect(try source(copies[0].id).page == nil && source(copies[0].id).spatial == nil)
    #expect(try element("b").graphic?.label == "Agent B")
  }

  @Test func copyingAtThePageEdgeDetachesUnselectedNodesWithoutLosingVisibleGeometry() throws {
    let surface = SurfaceID.page(UUID()), node = NotebookGraphic(label:"Outside selection")
    let arrow = NotebookGraphic(shape:.connector,connection:.init(
      start:.init(point:.zero,binding:.init(elementID:"node")),end:.init(point:.init(x:300,y:100)),bend:35))
    let frame = PageRect(x:0,y:0,width:300,height:100)
    let graph = NotebookGraphicGraph([
      .init(id:"node",graphic:node,frame:.init(x:50,y:50,width:80,height:80),surface:surface,shown:true),
      .init(id:"arrow",graphic:arrow,frame:frame,surface:surface,shown:true)])
    let original = try #require(graph.resolve("arrow").layout)
    let copies = NotebookGraphicSelection.duplicated([.init(id:"arrow",frame:frame,graphic:arrow,layout:original)],namespace:UUID(),offset:.zero)
    let copied = try #require(copies.first)
    #expect(copied.graphic.connection?.bindings.isEmpty == true)
    let resolved = try #require(NotebookGraphicGraph([.init(id:copied.id,graphic:copied.graphic,frame:copied.frame,surface:surface,shown:true)]).resolve(copied.id).layout)
    #expect(abs(original.frame.x+original.start.x-resolved.frame.x-resolved.start.x) < 0.0001)
    #expect(abs(original.frame.y+original.end.y-resolved.frame.y-resolved.end.y) < 0.0001)
  }

  @Test func duplicateDoesNotClaimOriginalInkAndAlignmentUsesWorldOrigins() throws {
    let graphic = NotebookGraphic(sourceInkIDs:[UUID()]), surface = SurfaceID.board(UUID())
    let f = PageRect(x:0,y:0,width:40,height:40)
    let graph = NotebookGraphicGraph([.init(id:"a",graphic:graphic,frame:f,surface:surface,shown:true)])
    let layout = try #require(graph.resolve("a").layout)
    let members: [NotebookGraphicSelection.Member] = [.init(id:"a",frame:f,graphic:graphic,layout:layout),
      .init(id:"b",frame:f,origin:WorldPoint.zero.offsetBy(x:1000,y:500),graphic:graphic,layout:layout)]
    #expect(NotebookGraphicSelection.duplicated(members,namespace:UUID(),offset:.init(x:20,y:20)).allSatisfy { $0.graphic.sourceInkIDs.isEmpty })
    let aligned = NotebookGraphicSelection.aligned(members,to:.left)
    #expect(aligned[0].frame.x == 0 && aligned[1].frame.x == -1000)
  }
}
