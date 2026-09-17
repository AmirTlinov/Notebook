import Foundation
import Testing
@testable import NotebookCore

private struct GraphicFixture {
  let root: URL
  let store: NotebookStore
  let target: CollaborationTarget
  let actor: UUID
  init(onBoard: Bool, actor: UUID = UUID(), seed: CollaborationContent? = nil, target: CollaborationTarget? = nil) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-peer-\(UUID())")
    store = .init(root: root); self.actor = actor
    let (index, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
    _ = try store.loadOrCreateSpatialInk(actor: actor)
    if let seed { _ = try store.mergeCollaborationContent(seed) }
    self.target = target ?? .init(kind: onBoard ? .board : .page, id: onBoard ? index.rootBoardID : index.selectedPageID!)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  func write(_ kind: CollaborationOperation.Kind, id: String, values: [String: JSONValue], human: Bool = true) throws -> CollaborationReceipt {
    let action = try CollaborationAction(summary: "Graphic edit",
      references: [.init(target: target, elementID: id, revision: store.targetContentRevision(target: target))],
      expected: [.init(target: target, revision: store.targetContentRevision(target: target), inkRevision: store.inkRevision(on: target))],
      operations: [.init(kind: kind, target: target, id: id, values: values)])
    return try human ? store.applyNativeGraphicAction(action, actor: actor) : store.applyCollaborationAction(action, actor: actor)
  }
  func stroke() throws -> UUID {
    let id = UUID()
    var values: [String: JSONValue] = ["points": .array([.object(["x": .number(10), "y": .number(10)]), .object(["x": .number(100), "y": .number(100)])])]
    if target.kind == .board { values["worldOrigin"] = try .encode(WorldPoint.zero) }
    _ = try write(.appendInkStroke, id: id.uuidString, values: values, human: false)
    return id
  }
  func convert(_ id: String, sources: [UUID], shape: NotebookGraphic.Shape = .ellipse, vertices: [SpatialPoint]? = nil, human: Bool = true) throws -> CollaborationReceipt {
    var values: [String: JSONValue] = ["kind": .string("graphic"), "source": .string(""),
      "frame": try .encode(PageRect(x: 10, y: 10, width: 100, height: 100)), "graphic": try .encode(NotebookGraphic(shape:shape,sourceInkIDs:sources,vertices:vertices))]
    if target.kind == .board { values["worldOrigin"] = try .encode(WorldPoint.zero) }
    return try write(.convertInkToElement, id: id, values: values, human: human)
  }
  func presentation() throws -> NotebookGraphicPresentation {
    if target.kind == .page { return try store.loadPage(target.id).graphicPresentation }
    return try store.loadBoard(items: store.loadIndex().items).board(target.id)!.graphicPresentation
  }
}

@Test("Правка агента принимает геометрию; её причинная отмена разрешает отменить преобразование", arguments: [false, true])
func graphicUndoPreservesAdoption(onBoard: Bool) throws {
  for undoEdit in [false, true] {
    let f = try GraphicFixture(onBoard: onBoard); defer { f.clean() }
    let source = try f.stroke(), conversion = try f.convert("circle", sources: [source])
    let moved = try f.write(.updateElement, id: "circle", values: ["frame": try .encode(PageRect(x: 34, y: 28, width: 100, height: 100))])
    let edit = try f.write(.updateElement, id: "circle", values: ["graphic": .object(["label": .string("+")])], human: false)
    if undoEdit {
      _ = try f.store.undoCollaborationAction(edit.id, actor: f.actor)
      _ = try f.store.undoCollaborationAction(moved.id, actor: f.actor)
    }
    let inverse = try NotebookStore(root: f.root).undoCollaborationAction(conversion.id, actor: f.actor)
    #expect(try f.presentation().geometryIDs == (undoEdit ? [] : ["circle"]))
    #expect(inverse.undo?.preserved.isEmpty == undoEdit)
  }
}

@Test("Три конкурирующих преобразования сходятся на SQLite при перестановках, повторах и группировке", arguments: [false, true])
func graphicConcurrentClaimsConverge(onBoard: Bool) throws {
  let base = try GraphicFixture(onBoard: onBoard); defer { base.clean() }
  let strokes = try (0..<4).map { _ in try base.stroke() }
  let seed = try base.store.collaborationContent()
  var payloads: [(CollaborationContent, CollaborationReceipt)] = []
  for i in 0..<3 {
    let peer = try GraphicFixture(onBoard: onBoard,
      actor: UUID(uuidString: "00000000-0000-4000-8000-00000000000\(i + 1)")!, seed: seed, target: base.target)
    defer { peer.clean() }
    let action = try peer.convert("shape-\(i)", sources: [strokes[i], strokes[i + 1]], shape: [NotebookGraphic.Shape.ellipse,.rectangle,.plus][i], human: i != 1)
    payloads.append((try peer.store.collaborationContent(), action))
  }
  let orders = [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]]
  for order in orders {
    for grouped in [false, true] {
      let peer = try GraphicFixture(onBoard: onBoard, seed: seed, target: base.target); defer { peer.clean() }
      if grouped {
        var merged = payloads[order[0]].0
        for i in order.dropFirst() { try merged.merge(payloads[i].0) }
        _ = try peer.store.mergeCollaborationContent(merged, actions: order.map { payloads[$0].1 })
      } else {
        for i in order + order.reversed() {
          _ = try peer.store.mergeCollaborationContent(payloads[i].0, actions: [payloads[i].1])
        }
      }
      let expected: Set<String> = ["shape-0", "shape-2"]
      #expect(try peer.presentation().geometryIDs == expected)
      #expect(try peer.presentation().suppressedInkIDs == Set(strokes))
      if onBoard {
        let window = try peer.store.readSceneWindow(boardID: base.target.id,
          bounds: .init(origin: .zero, width: 200, height: 200), pinnedElementIDs: ["shape-1"])
        #expect(Set(window.boards[0].board.elements.filter { $0.graphic != nil }.map(\.id)) == expected)
      }
    }
  }
}

@Test("Агентская последовательная отмена завершается внутри адресной IPC транзакции")
func graphicAgentUndoInDispatcherTransaction() throws {
  let f = try GraphicFixture(onBoard: false); defer { f.clean() }
  let source = try f.stroke(), conversion = try f.convert("circle", sources: [source], human: false)
  let edited = try f.write(.updateElement, id: "circle", values: ["graphic": .object(["label": .string("1:2")])], human: false)
  let deleted = try f.write(.removeElement, id: "circle", values: [:], human: false)
  for receipt in [deleted, edited, conversion] {
    _ = try f.store.commandTransaction(readAllowance: .agentCommand) {
      try f.store.scriptActionOutcome(f.store.undoCollaborationAction(receipt.id, actor: f.store.collaborationActorID()))
    }
  }
  #expect(try f.presentation().geometryIDs.isEmpty)
}

@Test("Изменение и очистка углов принимают многоугольник; отмена правки возвращает прежнее авторство", arguments:[false,true], [false,true])
func graphicPolygonVerticesAdoption(onBoard: Bool, undoEdit: Bool) throws {
  let f = try GraphicFixture(onBoard:onBoard); defer { f.clean() }
  let points: [SpatialPoint] = [.init(x:0,y:0),.init(x:1,y:0.2),.init(x:0.4,y:1)]
  let source = try f.stroke()
  let conversion = try f.convert("triangle",sources:[source],shape:.triangle,vertices:points)
  let cleared = try f.write(.updateElement,id:"triangle",values:["graphic":.object(["vertices":.null])],human:false)
  if undoEdit { _ = try f.store.undoCollaborationAction(cleared.id,actor:f.actor) }
  let inverse = try NotebookStore(root:f.root).undoCollaborationAction(conversion.id,actor:f.actor)
  #expect(try f.presentation().geometryIDs == (undoEdit ? [] : ["triangle"]))
  #expect(inverse.undo?.preserved.isEmpty == undoEdit)
}
