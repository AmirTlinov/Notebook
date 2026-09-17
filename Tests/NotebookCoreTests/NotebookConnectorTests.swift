import Foundation
import Testing
@testable import NotebookCore

@Test("Пакет векторов не перескакивает через незагруженного соседа в авторском порядке")
func graphicPaintSuccessorsKeepOffWindowBarriers() throws {
  let fixture = try ConnectorFixture(board: true)
  defer { fixture.clean() }
  _ = try fixture.write([fixture.node("a", x: 0), fixture.node("off-window", x: 100_000), fixture.node("b", x: 120)])
  let result = try fixture.store.readSceneElementSuccessors(boardID: fixture.target.id, elementIDs: ["a", "b"])
  #expect(result["a"] == "off-window")
  #expect(result["b"] == nil)
  _ = try fixture.write([fixture.operation(.removeElement, "off-window", [:])])
  #expect(try fixture.store.readSceneElementSuccessors(boardID: fixture.target.id, elementIDs: ["a"])["a"] == "off-window")
}

private struct ConnectorFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("connector-\(UUID())")
  let store: NotebookStore
  let target: CollaborationTarget
  let actor = UUID()
  init(board: Bool, seed: CollaborationContent? = nil, target: CollaborationTarget? = nil) throws {
    store = .init(root: root)
    let (index, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834,height: 1194))
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    if let seed { _ = try store.mergeCollaborationContent(seed) }
    self.target = target ?? .init(kind: board ? .board : .page, id: board ? index.rootBoardID : index.selectedPageID!)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func operation(_ kind: CollaborationOperation.Kind, _ id: String, _ values: [String: JSONValue]) -> CollaborationOperation {
    .init(kind: kind, target: target, id: id, values: values)
  }
  func write(_ operations: [CollaborationOperation], human: Bool = true) throws -> CollaborationReceipt {
    let action = try CollaborationAction(summary: "Связь", references: [.init(target: target, revision: store.targetContentRevision(target: target))],
      expected: [.init(target: target, revision: store.targetContentRevision(target: target),inkRevision:store.inkRevision(on:target))], operations: operations)
    return try human ? store.applyNativeGraphicAction(action, actor: actor) : store.applyCollaborationAction(action, actor: actor)
  }
  func node(_ id: String, x: Double, y: Double = 80) throws -> CollaborationOperation {
    try insert(id, graphic: .init(label: id), frame: .init(x:x,y:y,width:100,height:100))
  }
  func insert(_ id: String, graphic: NotebookGraphic, frame: PageRect) throws -> CollaborationOperation {
    var values: [String: JSONValue] = ["kind": .string("graphic"), "source": .string(""), "graphic": try .encode(graphic), "frame": try .encode(frame)]
    if target.kind == .board { values["worldOrigin"] = try .encode(WorldPoint(x: 20_000,y: -30_000)) }
    return operation(.insertElement,id,values)
  }
  func arrow(_ id: String = "ab", from: String = "a", to: String = "b") throws -> CollaborationOperation {
    try insert(id, graphic: .init(shape: .connector, label: "1:2", connection: .init(
      start: .init(point: .zero, binding: .init(elementID: from)),
      end: .init(point: .init(x:100,y:1), binding: .init(elementID: to)))), frame: .init(x:180,y:120,width:100,height:10))
  }
  func graphic(_ id: String) throws -> NotebookGraphic? {
    if target.kind == .page { return try store.readPageElement(pageID: target.id, elementID: id)?.graphic }
    return try store.readSpatialElement(boardID: target.id, elementID: id)?.graphic
  }
  func resolution(_ id: String = "ab") throws -> NotebookGraphicResolution { try store.readGraphicResolution(target: target, elementID: id) }
}

@Test("Связь следует за узлом без записи её координат; удаление и отмена сохраняют привязки", arguments: [false,true])
func connectorFollowsAndRestores(board: Bool) throws {
  let f = try ConnectorFixture(board: board); defer { f.clean() }
  let created = try f.write([f.node("a",x:60),f.node("b",x:400),f.arrow()])
  let original = try f.graphic("ab"), layout = try #require(f.resolution().layout)
  #expect(abs(layout.frame.x+layout.start.x-160) < 0.001)
  #expect(abs(layout.frame.x+layout.end.x-400) < 0.001)
  let moved = try f.write([f.operation(.updateElement,"a",["frame": .encode(PageRect(x:60,y:260,width:100,height:100))])])
  let next = try #require(f.resolution().layout)
  #expect(next.start.y+next.frame.y > 250)
  #expect(try f.graphic("ab") == original)
  let history = try CollaborationReadSnapshot(store:f.store,actions:[f.store.actionReadModel(created.id)],references:[])
  let result = try #require(history.results[created.id]?.first { $0.elementID == "ab" })
  #expect(result.region == next.frame)
  if board, case .board(_,_,let region) = try f.store.readReferenceLocation(result) { #expect(region == next.frame) }
  let hidden = try f.write([f.operation(.removeElement,"a",[:])])
  #expect(try f.resolution() == .hidden)
  #expect(try f.graphic("ab") == original)
  // Hidden intent is still editable; a new invalid endpoint is not.
  let hiddenEdit = try f.write([f.operation(.updateElement,"ab",["graphic":.object(["connection":.object(["endArrowhead":.string("diamond")])])])],human:false)
  #expect(try f.resolution() == .hidden)
  #expect(try f.graphic("ab")?.connection?.endArrowhead == .diamond)
  _ = try f.store.undoCollaborationAction(hiddenEdit.id,actor:f.actor)
  let reopened = NotebookStore(root:f.root)
  _ = try reopened.undoCollaborationAction(hidden.id,actor:f.actor)
  #expect(try f.resolution().layout == next)
  _ = try reopened.undoCollaborationAction(moved.id,actor:f.actor)
  #expect(try f.resolution().layout == layout)
  _ = try f.write([f.operation(.updateElement,"ab",["graphic": .object(["connection": .object(["bend": .number(100),"startArrowhead": .string("diamond")])])])],human:false)
  #expect(try f.resolution().layout?.curves.count ?? 0 > 1)
  #expect(try f.graphic("ab")?.connection?.end.binding?.elementID == "b")
}

@Test("Ограниченное окно читает адресные концы за пределами камеры")
func connectorWindowResolvesEndpoints() throws {
  let f = try ConnectorFixture(board:true); defer { f.clean() }
  _ = try f.write([f.node("a",x:-8000),f.node("b",x:8000),f.arrow()])
  let window = try f.store.readSceneWindow(boardID:f.target.id,
    bounds:.init(origin:.init(x:19_950,y:-29_900),width:100,height:100),limit:16)
  #expect(window.totalMatches == 1)
  let board = try #require(window.boards.first?.board)
  #expect(Set(board.elements.map(\.id)) == ["a","b","ab"])
  #expect(board.graphicGraph().resolve("ab") == (try f.resolution()))
  let rows = try f.store.readScenePaintOrder(boardID:f.target.id,
    bounds:.init(origin:.init(x:19_950,y:-29_900),width:100,height:100))
  #expect(rows.entries.count == 1)
  _ = try f.write([f.operation(.removeElement,"a",[:])])
  #expect(try f.store.readScenePaintOrder(boardID:f.target.id,
    bounds:.init(origin:.init(x:19_950,y:-29_900),width:100,height:100)).entries.isEmpty)
}

@Test("Удаление и конкурентная привязка сходятся без воскрешения; отмена показывает сохранённую связь", arguments:[false,true])
func connectorConcurrentDeletion(board: Bool) throws {
  let base = try ConnectorFixture(board:board); defer { base.clean() }
  _ = try base.write([base.node("a",x:60),base.node("b",x:400)])
  let seed = try base.store.collaborationContent()
  let human = try ConnectorFixture(board:board,seed:seed,target:base.target); defer { human.clean() }
  let agent = try ConnectorFixture(board:board,seed:seed,target:base.target); defer { agent.clean() }
  let removal = try human.write([human.operation(.removeElement,"a",[:])])
  let creation = try agent.write([agent.arrow()],human:false)
  let edits = try [human.store.collaborationContent(),agent.store.collaborationContent()]
  for (order,grouped) in [([0,1,0,1],false),([1,0,1,0],false),([0,1],true),([1,0],true)] {
    let peer = try ConnectorFixture(board:board,seed:seed,target:base.target); defer { peer.clean() }
    if grouped {
      var merged = edits[order[0]]; try merged.merge(edits[order[1]])
      _ = try peer.store.mergeCollaborationContent(merged,actions:[removal,creation])
    } else {
      for index in order { _ = try peer.store.mergeCollaborationContent(edits[index],actions:[index == 0 ? removal : creation]) }
    }
    #expect(try peer.resolution() == .hidden)
    #expect(try peer.graphic("a")?.visible == false)
    #expect(try peer.graphic("ab")?.connection?.start.binding?.elementID == "a")
    _ = try peer.store.undoCollaborationAction(removal.id,actor:peer.actor)
    #expect(try peer.resolution().layout != nil)
  }
}

@Test("Концы связи имеют независимые причинные поля; циклы связей допустимы", arguments:[false,true])
func connectorIndependentEnds(board: Bool) throws {
  let base = try ConnectorFixture(board:board); defer { base.clean() }
  _ = try base.write([base.node("a",x:60),base.node("b",x:400),base.node("c",x:200,y:400),base.arrow(),base.arrow("ba",from:"b",to:"a")])
  let seed = try base.store.collaborationContent()
  let left = try ConnectorFixture(board:board,seed:seed,target:base.target); defer { left.clean() }
  let right = try ConnectorFixture(board:board,seed:seed,target:base.target); defer { right.clean() }
  let endpoint = NotebookGraphicConnection.Endpoint(point:.zero,binding:.init(elementID:"c"))
  let a = try left.write([left.operation(.updateElement,"ab",["graphic":.object(["connection":.object(["start":.encode(endpoint)])])])])
  let b = try right.write([right.operation(.updateElement,"ab",["graphic":.object(["connection":.object(["end":.encode(endpoint)])])])],human:false)
  let payloads = try [left.store.collaborationContent(),right.store.collaborationContent()]
  for (order,grouped) in [([0,1,0,1],false),([1,0,1,0],false),([0,1],true),([1,0],true)] {
    let peer = try ConnectorFixture(board:board,seed:seed,target:base.target); defer { peer.clean() }
    if grouped {
      var merged = payloads[order[0]]; try merged.merge(payloads[order[1]])
      _ = try peer.store.mergeCollaborationContent(merged,actions:[a,b])
    } else {
      for index in order { _ = try peer.store.mergeCollaborationContent(payloads[index],actions:[index == 0 ? a : b]) }
    }
    #expect(try peer.graphic("ab")?.connection?.start.binding?.elementID == "c")
    #expect(try peer.graphic("ab")?.connection?.end.binding?.elementID == "c")
    _ = try peer.store.undoCollaborationAction(a.id,actor:peer.actor)
    #expect(try peer.graphic("ab")?.connection?.start.binding?.elementID == "a")
    #expect(try peer.graphic("ab")?.connection?.end.binding?.elementID == "c")
    _ = try peer.store.undoCollaborationAction(b.id,actor:peer.actor)
    #expect(try peer.resolution().layout != nil)
    #expect(try peer.resolution("ba").layout != nil)
  }
}

@Test("Поздняя связь защищает создание узла от отмены, но собственная атомарная конструкция отменяется", arguments:[false,true])
func connectorUndoPreservesDependencies(board: Bool) throws {
  let f = try ConnectorFixture(board:board); defer { f.clean() }
  let created = try f.write([f.node("a",x:60),f.node("b",x:400)])
  let link = try f.write([f.arrow()],human:false)
  let undo = try f.store.undoCollaborationAction(created.id,actor:f.actor)
  #expect(undo.undo?.preserved.isEmpty == false)
  #expect(undo.undo?.dependencies?.count == 2)
  #expect(undo.undo?.dependencies?.allSatisfy { $0.path.last == .member("ab") } == true)
  let details = try f.store.actionDetails(undo,page:.init(section:.undo))
  #expect(details["page"]?["items"]?.array.contains { $0["reason"] == .string("retained_dependency") } == true)
  #expect(try f.resolution().layout != nil)
  _ = try f.store.undoCollaborationAction(link.id,actor:f.actor)
  let atomic = try f.write([f.node("x",x:60,y:500),f.node("y",x:400,y:500),f.arrow("xy",from:"x",to:"y")])
  let inverse = try f.store.undoCollaborationAction(atomic.id,actor:f.actor)
  #expect(inverse.undo?.preserved.isEmpty == true)
  #expect(try f.graphic("x") == nil)
  #expect(try f.graphic("xy") == nil)
}

@Test("Неизвестный конец не становится свободной линией; локальный неверный граф отклоняется атомарно")
func connectorPendingAndInvalidBinding() throws {
  let f = try ConnectorFixture(board:false); defer { f.clean() }
  #expect(throws: (any Error).self) { try f.write([f.node("a",x:60),f.arrow()]) }
  #expect(try f.graphic("a") == nil)
  let graphic = NotebookGraphic(shape:.connector,connection:.init(start:.init(point:.zero,binding:.init(elementID:"off-window")),end:.init(point:.init(x:100,y:0))))
  let graph = NotebookGraphicGraph([.init(id:"arrow",graphic:graphic,frame:.init(x:0,y:0,width:100,height:1),surface:.page(UUID()),shown:true)])
  #expect(graph.resolve("arrow") == .pending(["off-window"]))
}

@Test("Пересечение чернильных заявок и обратных привязок индексируется один раз без цикла")
func connectorClaimComponentWithItsOwnDependent() throws {
  let base = try ConnectorFixture(board:true); defer { base.clean() }
  let strokes = [UUID(),UUID()]
  _ = try base.write([base.node("b",x:400)] + strokes.map { id in
    base.operation(.appendInkStroke,id.uuidString,["worldOrigin":try .encode(WorldPoint(x:20_000,y:-30_000)),
      "points":.array([.object(["x":.number(100),"y":.number(100)]),.object(["x":.number(200),"y":.number(150)])])])
  },human:false)
  let seed = try base.store.collaborationContent()
  let left = try ConnectorFixture(board:true,seed:seed,target:base.target); defer { left.clean() }
  let right = try ConnectorFixture(board:true,seed:seed,target:base.target); defer { right.clean() }
  func convert(_ f: ConnectorFixture, _ id: String, graphic: NotebookGraphic) throws -> CollaborationOperation {
    let insertion = try f.insert(id,graphic:graphic,frame:.init(x:100,y:100,width:100,height:100))
    return f.operation(.convertInkToElement,id,insertion.values)
  }
  let a = try left.write([convert(left,"a",graphic:.init(sourceInkIDs:[strokes[0]])),
    convert(left,"ab",graphic:.init(shape:.connector,sourceInkIDs:[strokes[1]],connection:.init(
      start:.init(point:.zero,binding:.init(elementID:"a")),end:.init(point:.init(x:100,y:0),binding:.init(elementID:"b")))))] )
  let b = try right.write([convert(right,"alternative",graphic:.init(sourceInkIDs:strokes))],human:false)
  let payloads = try [left.store.collaborationContent(),right.store.collaborationContent()]
  for order in [[0,1,1,0],[1,0,0,1]] {
    let peer = try ConnectorFixture(board:true,seed:seed,target:base.target); defer { peer.clean() }
    for index in order { _ = try peer.store.mergeCollaborationContent(payloads[index],actions:[index == 0 ? a : b]) }
    #expect(try peer.resolution().layout != nil)
    #expect(try peer.resolution("alternative") == .hidden)
    let window = try peer.store.readSceneWindow(boardID:peer.target.id,
      bounds:.init(origin:.init(x:20_000,y:-30_000),width:600,height:600),limit:16)
    #expect(window.totalMatches == 3)
  }
}

@Test("Касание использует ту же дугу при сильном приближении, а заполненные наконечники доступны изнутри")
func connectorCurveHitUsesPhysicalTolerance() throws {
  let surface = SurfaceID.board(UUID())
  let graphic = NotebookGraphic(shape:.connector,style:.init(strokeWidth:0.1),connection:.init(
    start:.init(point:.zero),end:.init(point:.init(x:100_000,y:0)),bend:40_000))
  let graph = NotebookGraphicGraph([.init(id:"arc",graphic:graphic,frame:.init(x:0,y:0,width:1,height:1),surface:surface,shown:true)])
  let layout = try #require(graph.resolve("arc").layout)
  for curve in layout.curves { for t in [0.037,0.241,0.673,0.937] {
    #expect(layout.hitTest(curve.point(at:t),graphic:graphic,tolerance:0.01))
  } }
  #expect(!layout.hitTest(.init(x:layout.frame.width/2,y:0),graphic:graphic,tolerance:0.01))
  let solid = NotebookGraphic(shape:.connector,style:.init(strokeWidth:10),connection:.init(
    start:.init(point:.zero),end:.init(point:.init(x:500,y:0)),endArrowhead:.square))
  let square = try #require(NotebookGraphicGraph([.init(id:"square",graphic:solid,frame:.init(x:0,y:0,width:1,height:1),surface:surface,shown:true)]).resolve("square").layout)
  let points = try #require(square.heads.first).points
  #expect(square.hitTest(.init(x:points.map(\.x).reduce(0,+)/4,y:points.map(\.y).reduce(0,+)/4),graphic:solid,tolerance:0.01))
}

@Test("Связь обрезается о сторону прямоугольника, а не о вписанный эллипс")
func connectorRectangleBoundary() throws {
  let surface = SurfaceID.board(UUID())
  let graph = NotebookGraphicGraph([
    .init(id:"box",graphic:.init(shape:.rectangle),frame:.init(x:0,y:0,width:100,height:100),surface:surface,shown:true),
    .init(id:"link",graphic:.init(shape:.connector,connection:.init(start:.init(point:.init(x:50,y:50),binding:.init(elementID:"box")),
      end:.init(point:.init(x:200,y:125)),endArrowhead:.none)),frame:.init(x:0,y:0,width:200,height:125),surface:surface,shown:true)
  ])
  let layout = try #require(graph.resolve("link").layout)
  #expect(abs(layout.frame.x+layout.start.x-100) < 0.01)
  #expect(abs(layout.frame.y+layout.start.y-75) < 0.01)
  #expect(graph.binding(at:.init(x:0,y:0),origin:.zero,surface:surface,tolerance:4)?.elementID == "box")
}
