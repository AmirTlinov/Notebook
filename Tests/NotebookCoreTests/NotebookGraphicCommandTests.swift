import Foundation
import Testing
@testable import NotebookCore

@Test("Круг на листе и доске: чернила, преобразование, удаление и две отмены с перезапуском", arguments: [false, true])
func graphicConversionDeletionUndo(onBoard: Bool) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-command-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let actor = UUID(), store = NotebookStore(root: root)
  let (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
  _ = try store.loadOrCreateSpatialInk(actor: actor)
  let target = CollaborationTarget(kind: onBoard ? .board : .page, id: onBoard ? workspace.rootBoardID : workspace.selectedPageID!)
  func action(_ kind: CollaborationOperation.Kind, id: String, values: [String: JSONValue], store: NotebookStore) throws -> CollaborationAction {
    try .init(summary: "Круг", references: [.init(target: target, revision: store.targetContentRevision(target: target))],
      expected: [.init(target: target, revision: store.targetContentRevision(target: target),
        inkRevision: onBoard ? store.loadSpatialInk().stamp.revision : store.loadPage(target.id).drawingStamp.revision)],
      operations: [.init(kind: kind, target: target, id: id, values: values)])
  }
  let stroke = UUID()
  var values: [String: JSONValue] = ["points": .array((0...48).map { index in
    let angle = Double(index) / 48 * 2 * Double.pi
    return .object(["x": .number(100 + 40 * cos(angle)), "y": .number(100 + 40 * sin(angle))])
  })]
  if onBoard { values["worldOrigin"] = try .encode(WorldPoint.zero) }
  _ = try store.applyCollaborationAction(action(.appendInkStroke, id: stroke.uuidString, values: values, store: store), actor: actor)
  let rawPage = onBoard ? nil : try store.loadPage(target.id).drawingData
  let rawBoard = onBoard ? try store.loadSpatialInk() : nil
  let graphic = NotebookGraphic(sourceInkIDs: [stroke])
  values = ["kind": .string("graphic"), "source": .string(""), "graphic": try .encode(graphic),
    "frame": try .encode(PageRect(x: 60, y: 60, width: 80, height: 80))]
  if onBoard { values["worldOrigin"] = try .encode(WorldPoint.zero) }
  let converted = try store.applyNativeGraphicAction(action(.convertInkToElement, id: "circle", values: values, store: store), actor: actor)
  #expect(converted.author == .human)
  func state(_ store: NotebookStore) throws -> (NotebookGraphic, NotebookGraphicPresentation) {
    if onBoard {
      let board = try store.loadBoard(items: store.loadIndex().items).board(target.id)!
      return (board.elements.first!.graphic!, board.graphicPresentation)
    }
    let page = try store.loadPage(target.id)
    return (page.elements.first!.graphic!, page.graphicPresentation)
  }
  #expect(try state(store).1.geometryIDs == ["circle"])
  let surface: SurfaceID = onBoard ? .board(target.id) : .page(target.id)
  #expect(try store.graphicPresentation(on: surface, sourceInkIDs: [stroke]) == state(store).1)
  #expect(try state(store).1.suppressedInkIDs == [stroke])
  func indexed(_ store: NotebookStore) throws -> [String] {
    try store.readSceneWindow(boardID: target.id,
      bounds: .init(origin: .zero, width: 200, height: 200), pinnedElementIDs: ["circle"])
      .boards.first!.board.elements.filter { $0.graphic != nil }.map(\.id)
  }
  if onBoard { #expect(try indexed(store) == ["circle"]) }
  let deleted = try store.applyNativeGraphicAction(action(.removeElement, id: "circle", values: [:], store: store), actor: actor)
  #expect(try state(store).1.geometryIDs.isEmpty)
  #expect(try state(store).1.suppressedInkIDs == [stroke])
  if onBoard { #expect(try indexed(store).isEmpty) }
  let reopened = NotebookStore(root: root)
  _ = try reopened.undoCollaborationAction(deleted.id, actor: actor)
  #expect(try state(reopened).0 == graphic)
  if onBoard { #expect(try indexed(reopened) == ["circle"]) }
  _ = try NotebookStore(root: root).undoCollaborationAction(converted.id, actor: actor)
  #expect(try state(reopened).0.representation == .ink)
  #expect(try state(reopened).1.geometryIDs.isEmpty)
  #expect(try state(reopened).1.suppressedInkIDs.isEmpty)
  if onBoard { #expect(try indexed(reopened).isEmpty) }
  if onBoard { #expect(try reopened.loadSpatialInk() == rawBoard) }
  else { #expect(try reopened.loadPage(target.id).drawingData == rawPage) }
}

@Test("Перекрывающиеся многоштриховые преобразования применяются целиком и независимо от порядка")
func graphicPresentationArbitratesWholeCandidates() {
  let a = UUID(), b = UUID(), c = UUID(), actor = UUID()
  let left = NotebookGraphicPresentation.Candidate(id: "left", graphic: .init(sourceInkIDs: [a, b]),
    version: .init(stamp: .init(counter: 1, actor: actor), human: false))
  let right = NotebookGraphicPresentation.Candidate(id: "right", graphic: .init(sourceInkIDs: [b, c]),
    version: .init(stamp: .init(counter: 2, actor: actor), human: true))
  for candidates in [[left, right], [right, left]] {
    let presentation = NotebookGraphicPresentation(candidates)
    #expect(presentation.geometryIDs == ["right"])
    #expect(presentation.suppressedInkIDs == [b, c])
  }
}
