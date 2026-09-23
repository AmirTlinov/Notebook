import Foundation
import Testing
@testable import NotebookCore

@Suite("Atomic native graphic selections")
struct NotebookGraphicSelectionTests {
  private enum Fault: Error { case storage }

  @Test(arguments: [false,true], [NotebookStorageFault.afterRecordWrites,.beforeCommit,.afterCommit])
  func retainedCommandRetriesItsOwnCommitWithoutBorrowingNewerMaterial(onBoard: Bool, fault: NotebookStorageFault) throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    let (workspace,_)=try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
    _=try store.loadOrCreateSpatialInk(actor:actor)
    let target=CollaborationTarget(kind:onBoard ? .board : .page,
      id:onBoard ? workspace.rootBoardID : workspace.selectedPageID!)
    func source(_ id:String) throws -> NotebookNativeElementSource {
      try .init(target:target,id:id,page:onBoard ? nil : store.readPageElement(pageID:target.id,elementID:id),
        spatial:onBoard ? store.readSpatialElement(boardID:target.id,elementID:id) : nil)
    }
    let mask=NotebookGraphicMask().appending(.subtract,polygon:[.zero,.init(x:0.3,y:0),.init(x:0.3,y:1),.init(x:0,y:1)])
    func values(_ x:Double) throws -> [String:JSONValue] {
      var result:[String:JSONValue]=["kind":.string("graphic"),"source":.string(""),
        "frame":try .encode(PageRect(x:x,y:20,width:80,height:100)),
        "graphic":try .encode(NotebookGraphic(shape:.rectangle,style:.init(fill:.black),mask:mask))]
      if onBoard { result["worldOrigin"]=try .encode(WorldPoint.zero) }
      return result
    }
    _=try store.applyNativeElementEdits(["a","b","read-only"].enumerated().map {
      .init(kind:.insertElement,target:target,id:$0.element,values:try values(Double($0.offset)*120))
    },summary:"Original",sources:["a","b","read-only"].map(source),actor:actor)
    let sources=try ["a","b","copy","read-only"].map(source),actionID=UUID()
    let command=NotebookNativeCommand([
      .init(kind:.updateElement,target:target,id:"a",values:["frame":try .encode(PageRect(x:45,y:20,width:80,height:100))]),
      .init(kind:.removeElement,target:target,id:"b"),
      .init(kind:.insertElement,target:target,id:"copy",values:try values(360))
    ],summary:"Move, remove and insert",sources:sources,actionID:actionID,actor:actor)
    let failing=NotebookStore(root:root) { point in
      if String(describing:point) == String(describing:fault) { throw Fault.storage }
    }
    #expect(throws:Fault.self) { try command.apply(to:failing) }
    let committed:Bool
    if case .afterCommit = fault { committed=true } else { committed=false }
    var committedSources:[NotebookNativeElementSource]?
    if committed {
      committedSources=try sources.map { try source($0.id) }
      _=try store.applyNativeElementEdits([
        .init(kind:.updateElement,target:target,id:"a",values:["graphic":.object(["label":.string("Peer continuation")])])
      ],summary:"Peer continuation",sources:[source("a")],actor:UUID())
    }
    let cursor=try store.currentChangeCursor(),result=try command.apply(to:NotebookStore(root:root))
    #expect(result.receipt.id == actionID)
    #expect(try store.currentChangeCursor() == cursor + (committed ? 0 : 1))
    #expect(try store.collaborationActions().filter { $0.id == actionID }.count == 1)
    let removed=try #require(result.sources.first { $0.id == "b" })
    #expect((removed.page?.graphic ?? removed.spatial?.graphic)?.visible == false)
    if committed {
      #expect(result.sources == committedSources,"A retry returns the exact saved cut, including spatial stamps and cuts, not peer values")
      #expect(throws:CollaborationError.self) {
        try store.applyNativeElementEdits([.init(kind:.removeElement,target:target,id:"a")],summary:"Dependent old cut",
          sources:[result.sources[0]],actor:actor)
      }
      #expect(try source("a").page?.graphic?.label == "Peer continuation"
        || source("a").spatial?.graphic?.label == "Peer continuation")
    } else { #expect(try result.sources == sources.map { try source($0.id) }) }
    let after=try store.currentChangeCursor(),again=try command.apply(to:store)
    #expect(again.sources == result.sources && again.receipt == result.receipt)
    #expect(try store.currentChangeCursor() == after)
  }

  @Test func rolledBackCommandStillRejectsAChangedSourceOnRetry() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    let (workspace,_)=try store.loadOrCreate(actor:actor,pageSize:.init(width:834,height:1194))
    _=try store.loadOrCreateSpatialInk(actor:actor)
    let target=CollaborationTarget(kind:.page,id:workspace.selectedPageID!)
    let inserted=try store.applyNativeElementEdits([.init(kind:.insertElement,target:target,id:"a",values:[
      "kind":.string("graphic"),"source":.string(""),"graphic":try .encode(NotebookGraphic(shape:.rectangle)),
      "frame":try .encode(PageRect(x:0,y:0,width:100,height:100))])],summary:"Original",
      sources:[.init(target:target,id:"a")],actor:actor)
    let id=UUID(),command=NotebookNativeCommand([.init(kind:.removeElement,target:target,id:"a")],
      summary:"Delete",sources:inserted.sources,actionID:id,actor:actor)
    let failing=NotebookStore(root:root) { if case .beforeCommit = $0 { throw Fault.storage } }
    #expect(throws:Fault.self) { try command.apply(to:failing) }
    let peer=try store.applyNativeElementEdits([.init(kind:.updateElement,target:target,id:"a",
      values:["graphic":.object(["label":.string("New source")])])],summary:"Peer",sources:inserted.sources,actor:UUID())
    #expect(throws:CollaborationError.self) { try command.apply(to:store) }
    #expect(try store.collaborationActionIfPresent(id) == nil)
    #expect(try store.readPageElement(pageID:target.id,elementID:"a") == peer.sources[0].page)
  }

  @Test func layerStepsRetainRelativeOrderAndStopAtTheStackEdges() {
    let order = ["a","b","c","d","e"], selected: Set<String> = ["b","d"]
    #expect(NotebookElementLayerMove.lower.applying(to:order,selected:selected) == ["b","a","d","c","e"])
    #expect(NotebookElementLayerMove.higher.applying(to:order,selected:selected) == ["a","c","b","e","d"])
    #expect(NotebookElementLayerMove.toBack.applying(to:order,selected:selected) == ["b","d","a","c","e"])
    #expect(NotebookElementLayerMove.toFront.applying(to:order,selected:selected) == ["a","c","e","b","d"])
    #expect(NotebookElementLayerMove.higher.applying(to:order,selected:["b","c"]) == ["a","d","b","c","e"])
    #expect(NotebookElementLayerMove.lower.applying(to:order,selected:["b","c"]) == ["b","c","a","d","e"])
    for move in NotebookElementLayerMove.allCases {
      #expect(move.applying(to:order,selected:Set(order)) == order)
      #expect(!move.canApply(to:order,selected:Set(order)))
      #expect(!move.canApply(to:order,selected:[]))
    }
    #expect(!NotebookElementLayerMove.lower.canApply(to:order,selected:["a","b"]))
    #expect(!NotebookElementLayerMove.higher.canApply(to:order,selected:["d","e"]))
    // Exercise the same linear ordering pass at the board's large-item scale.
    let large = (0..<100_000).map(String.init), ids: Set<String> = ["1","50000","99998"]
    let higher = NotebookElementLayerMove.higher.applying(to:large,selected:ids)
    #expect(higher.count == large.count)
    #expect(higher.filter { ids.contains($0) } == ["1","50000","99998"])
    #expect(higher.filter { !ids.contains($0) } == large.filter { !ids.contains($0) })
    #expect(higher[2] == "1" && higher[50001] == "50000" && higher[99999] == "99998")
  }

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
      return try objects.map { .init(id:$0.id,frame:$0.frame,graphic:$0.graphic!,layout:try #require(graph.resolve($0.id).layout),body:try #require(graph.resolve($0.id,space:.body).layout),placement:try #require(graph.placement($0.id))) }
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
      sources:["a","b"].map(source),layerMove:.toFront,actor:actor)
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

  @Test func selectionTransformsRelativeBasesWithoutRewritingMaskedMaterialOrBoundCurves() throws {
    let mask=NotebookGraphicMask().appending(.intersect,polygon:[.zero,.init(x:0.6,y:0),.init(x:0.6,y:1),.init(x:0,y:1)])
    let page=PageDocument(size:.init(width:1000,height:1000),actor:UUID(),elements:[
      .init(id:"group",kind:.group,frame:.init(x:80,y:60,width:300,height:200),source:"",html:"",
        basis:.init(size:.init(x:200,y:100),transform:.init(a:0.7,b:0,c:0.3,d:1,tx:0,ty:0))),
      .init(id:"a",kind:.graphic,frame:.init(x:10,y:20,width:60,height:50),source:"",html:"",
        graphic:.init(shape:.rectangle,style:.init(fill:.black),mask:mask),parentID:"group"),
      .init(id:"b",kind:.graphic,frame:.init(x:500,y:200,width:80,height:100),source:"",html:"",
        graphic:.init(shape:.ellipse,style:.init(fill:.black),mask:mask)),
      .init(id:"link",kind:.graphic,frame:.init(x:50,y:50,width:300,height:100),source:"",html:"",
        graphic:.init(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"a")),
          end:.init(point:.init(x:300,y:100),binding:.init(elementID:"b")),bend:20)))])
    let graph=page.graphicGraph()
    let members=try ["a","b","link"].map { id in
      let node=try #require(graph.node(id))
      return NotebookGraphicSelection.Member(id:id,frame:node.frame,graphic:node.graphic,
        layout:try #require(graph.resolve(id).layout),body:try #require(graph.resolve(id,space:.body).layout),placement:node.placement)
    }
    let change=CGAffineTransform(a:1.7,b:0,c:0,d:0.6,tx:35,ty:20)
    let edits=NotebookGraphicSelection.transformed(members,by:change,relativeTo:.zero)
    #expect(edits.count == members.count)
    for (member,edit) in zip(members,edits) {
      #expect(edit.graphic == member.graphic)
      let placed=try member.placement.updating(frame:edit.frame,basis:edit.basis)
      for point in [CGPoint.zero,.init(x:17,y:29),.init(x:member.placement.localSize.x,y:member.placement.localSize.y)] {
        let expected=point.applying(member.placement.transform).applying(change),actual=point.applying(placed.transform)
        #expect(abs(actual.x-expected.x)<1e-9 && abs(actual.y-expected.y)<1e-9)
      }
    }
    let moved=NotebookGraphicSelection.translated(members,by:.init(x:40,y:30))
    for (member,edit) in zip(members,moved) {
      let placed=try member.placement.updating(frame:edit.frame,basis:edit.basis)
      let before=CGPoint.zero.applying(member.placement.transform),after=CGPoint.zero.applying(placed.transform)
      #expect(abs(after.x-before.x-40)<1e-9 && abs(after.y-before.y-30)<1e-9)
    }
    let onlyLink=NotebookGraphicSelection.transformed([members[2]],by:change,relativeTo:.zero)
    #expect(onlyLink[0].graphic.connection?.bindings.isEmpty == true)
    #expect(onlyLink[0].graphic.style == members[2].graphic.style)
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
    let copies = NotebookGraphicSelection.duplicated([.init(id:"arrow",frame:frame,graphic:arrow,layout:original,body:try #require(graph.resolve("arrow",space:.body).layout),placement:try #require(graph.placement("arrow")))],namespace:UUID(),offset:.zero)
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
    let members: [NotebookGraphicSelection.Member] = [.init(id:"a",frame:f,graphic:graphic,layout:layout,body:try #require(graph.resolve("a",space:.body).layout),placement:try #require(graph.placement("a"))),
      .init(id:"b",frame:f,graphic:graphic,layout:layout,body:try #require(graph.resolve("a",space:.body).layout),
        placement:.init(id:"b",frame:f,origin:WorldPoint.zero.offsetBy(x:1000,y:500)))]
    #expect(NotebookGraphicSelection.duplicated(members,namespace:UUID(),offset:.init(x:20,y:20)).allSatisfy { $0.graphic.sourceInkIDs.isEmpty })
    let aligned = NotebookGraphicSelection.aligned(members,to:.left)
    #expect(aligned[0].frame.x == 0 && aligned[1].frame.x == -1000)
  }
}
