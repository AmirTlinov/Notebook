import Foundation
import Testing
@testable import NotebookCore

@Test("Одинаковое тело после A→B→A сохраняет новый причинный исходник для native CAS")
func nativeGraphicSourceRejectsSameValuedSuccessor() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("graphic-source-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let actor = UUID(), pageID = UUID(), store = NotebookStore(root: root)
  _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
  let target = CollaborationTarget(kind: .page, id: pageID)
  let original = PageRect(x: 20, y: 30, width: 100, height: 80)
  func mutate(_ kind: CollaborationOperation.Kind, _ values: [String: JSONValue]) throws {
    let revision = try store.targetContentRevision(target: target)
    _ = try store.applyNativeAction(.init(summary: "Изменить фигуру",
      references: [.init(target: target, elementID: "source", revision: revision)],
      expected: [.init(target: target, revision: revision)],
      operations: [.init(kind: kind, target: target, id: "source", values: values)]), actor: actor)
  }
  try mutate(.insertElement, ["kind": .string("graphic"), "source": .string(""),
    "frame": .encode(original), "graphic": .encode(NotebookGraphic(shape: .rectangle))])
  let before = try store.readNativeElementSource(target: target, id: "source")
  try mutate(.updateElement, ["frame": .encode(PageRect(x: 60, y: 30, width: 100, height: 80))])
  try mutate(.updateElement, ["frame": .encode(original)])
  let current = try store.readNativeElementSource(target: target, id: "source")
  #expect(before.page == current.page)
  #expect(before.versions != current.versions)
  let operation = CollaborationOperation(kind: .updateElement, target: target, id: "source",
    values: ["frame": try .encode(PageRect(x: 120, y: 30, width: 100, height: 80))])
  do {
    _ = try store.applyNativeElementEdits([operation], summary: "Старый исходник", sources: [before], actor: actor)
    Issue.record("Старый причинный исходник не должен применяться к одинаковому новому телу")
  } catch let error as CollaborationError {
    #expect(error.code == "revision_conflict")
  }
  #expect(try store.readNativeElementSource(target: target, id: "source") == current)
  let accepted = try store.applyNativeElementEdits([operation], summary: "Текущий исходник", sources: [current], actor: actor)
  #expect(accepted.sources.first?.page?.frame.x == 120)
}

@Test("Фигуры на листе и доске: все исходные штрихи, преобразование, удаление и две отмены с перезапуском", arguments: [false, true], [NotebookGraphic.Shape.ellipse, .rectangle, .triangle, .diamond, .plus])
func graphicConversionDeletionUndo(onBoard: Bool, shape: NotebookGraphic.Shape) throws {
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
  let strokes = (0..<(shape == .ellipse ? 1 : shape == .plus ? 2 : 4)).map { _ in UUID() }
  var values: [String: JSONValue] = ["points": .array((0...48).map { index in
    let angle = Double(index) / 48 * 2 * Double.pi
    return .object(["x": .number(100 + 40 * cos(angle)), "y": .number(100 + 40 * sin(angle))])
  })]
  if onBoard { values["worldOrigin"] = try .encode(WorldPoint.zero) }
  for stroke in strokes {
    _ = try store.applyCollaborationAction(action(.appendInkStroke, id: stroke.uuidString, values: values, store: store), actor: actor)
  }
  let rawPage = onBoard ? nil : try store.loadPage(target.id).drawingData
  let rawBoard = onBoard ? try store.loadSpatialInk() : nil
  let vertices: [SpatialPoint]? = shape == .triangle
    ? [.init(x:0,y:0.2),.init(x:1,y:0),.init(x:0.8,y:1)] : nil
  let graphic = NotebookGraphic(shape:shape,sourceInkIDs:strokes,vertices:vertices)
  values = ["kind": .string("graphic"), "source": .string(""), "graphic": try .encode(graphic),
    "frame": try .encode(PageRect(x: 60, y: 60, width: 80, height: 80))]
  if onBoard { values["worldOrigin"] = try .encode(WorldPoint.zero) }
  let converted = try store.applyNativeAction(action(.convertInkToElement, id: "circle", values: values, store: store), actor: actor)
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
  #expect(try store.graphicPresentation(on: surface, sourceInkIDs: Set(strokes)) == state(store).1)
  #expect(try state(store).1.suppressedInkIDs == Set(strokes))
  func indexed(_ store: NotebookStore) throws -> [String] {
    try store.readSceneWindow(boardID: target.id,
      bounds: .init(origin: .zero, width: 200, height: 200), pinnedElementIDs: ["circle"])
      .boards.first!.board.elements.filter { $0.graphic != nil }.map(\.id)
  }
  if onBoard { #expect(try indexed(store) == ["circle"]) }
  let deleted = try store.applyNativeAction(action(.removeElement, id: "circle", values: [:], store: store), actor: actor)
  #expect(try state(store).1.geometryIDs.isEmpty)
  #expect(try state(store).1.suppressedInkIDs == Set(strokes))
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
  let repeatedConversion = try NotebookStore(root: root).redoNativeAction(converted.id,
    actionID: UUID(), actor: actor)
  #expect(repeatedConversion.redoOf == converted.id)
  #expect(try state(reopened).0 == graphic)
  #expect(try state(reopened).1.suppressedInkIDs == Set(strokes))
  let repeatedDeletion = try NotebookStore(root: root).redoNativeAction(deleted.id,
    actionID: UUID(), actor: actor)
  #expect(repeatedDeletion.redoOf == deleted.id)
  #expect(try state(reopened).1.geometryIDs.isEmpty)
  #expect(try state(reopened).1.suppressedInkIDs == Set(strokes))
  _ = try reopened.undoNativeAction(repeatedDeletion.id, actor: actor)
  #expect(try state(reopened).0 == graphic)
  _ = try reopened.undoNativeAction(repeatedConversion.id, actor: actor)
  #expect(try state(reopened).0.representation == .ink)
  #expect(try state(reopened).1.suppressedInkIDs.isEmpty)
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

@Test("Локальное причинное изменение пересчитывает только свой конфликтующий компонент")
func localGraphicPresentationRevealsThePreviousWholeAfterRemoval() {
  let a=UUID(),b=UUID(),c=UUID(),actor=UUID()
  let previous=NotebookGraphicPresentation.Candidate(id:"previous",
    graphic:.init(sourceInkIDs:[a,b]),
    version:.init(stamp:.init(counter:1,actor:actor),human:true))
  let winner=NotebookGraphicPresentation.Candidate(id:"winner",
    graphic:.init(sourceInkIDs:[b,c]),
    version:.init(stamp:.init(counter:2,actor:actor),human:true))
  let restored=NotebookGraphicPresentation(prioritizing:[],then:[previous])
  #expect(NotebookGraphicPresentation([previous,winner]).suppressedInkIDs == [b,c])
  #expect(restored.suppressedInkIDs == [a,b])
  let ink=NotebookGraphicPresentation.PrioritizedCandidate(id:"winner",
    graphic:.init(representation:.ink,sourceInkIDs:[b,c]))
  #expect(NotebookGraphicPresentation(prioritizing:[ink],then:[previous,winner]).suppressedInkIDs == [a,b])
}
