import Foundation
import Testing
@testable import NotebookCore

@Test("Панель: автор пользователя, CAS, точный повтор и отмена сохраняют дальнейшую правку агента", arguments: [false, true])
func notebookPanelHumanEdit(onBoard: Bool) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-panel-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let actor = UUID(), store = NotebookStore(root: root)
  let (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
  _ = try store.loadOrCreateSpatialInk(actor: actor)
  let workspaceID = try store.storedWorkspaceID()
  let target = CollaborationTarget(kind: onBoard ? .board : .page, id: onBoard ? workspace.rootBoardID : workspace.selectedPageID!)
  let dispatcher = NotebookCommandDispatcher(store: store, nativeActor: actor)
  func source() throws -> NotebookPanelElementSource {
    .init(id: "caption", page: onBoard ? nil : try store.readPageElement(pageID: target.id, elementID: "caption"),
      spatial: onBoard ? try store.readSpatialElement(boardID: target.id, elementID: "caption") : nil)
  }
  func edit(_ request: NotebookPanelEditRequest) throws -> JSONValue {
    var command = NotebookCommand(command: .panelEdit); command.panelEdit = request
    return try dispatcher.handle(command)
  }
  var values: [String: JSONValue] = ["kind": .string("nativeText"), "source": .string("Мысль пользователя"),
    "frame": try .encode(PageRect(x: 20, y: 30, width: 200, height: 80))]
  if onBoard { values["worldOrigin"] = try .encode(WorldPoint.zero) }
  let create = NotebookPanelEditRequest(workspaceID: workspaceID, actionID: UUID(), target: target, summary: "Добавить подпись",
    operations: [.init(kind: .insertElement, target: target, id: "caption", values: values)], sources: [.init(id: "caption")])
  _ = try edit(create)
  #expect(try store.collaborationAction(create.actionID).author == .human)
  #expect(try store.nativeHistory(domain: .init(target), actor: actor).last == .command(create.actionID))
  let original = try source()
  let move = NotebookPanelEditRequest(workspaceID: workspaceID, actionID: UUID(), target: target, summary: "Переместить подпись",
    operations: [.init(kind: .updateElement, target: target, id: "caption", values: ["frame": try .encode(PageRect(x: 60, y: 90, width: 200, height: 80))])], sources: [original])
  let committed = try edit(move)
  #expect(try store.collaborationAction(move.actionID).author == .human)
  let conflicting = NotebookPanelEditRequest(workspaceID: workspaceID, actionID: UUID(), target: target, summary: "Старое перемещение",
    operations: move.operations, sources: [original])
  #expect(throws: CollaborationError.self) { try edit(conflicting) }
  let revision = try store.targetContentRevision(target: target)
  let agent = CollaborationAction(summary: "Уточнить мысль", expected: [.init(target: target, revision: revision)],
    operations: [.init(kind: .updateElement, target: target, id: "caption", values: ["source": .string("Мысль, уточнённая агентом")])])
  _ = try store.applyCollaborationAction(agent, actor: UUID())
  #expect(try edit(move) == committed)
  var repeated = NotebookCommand(command: .panelEdit); repeated.panelEdit = move
  #expect(try NotebookCommandDispatcher(store: NotebookStore(root: root), nativeActor: actor).handle(repeated) == committed)
  var undo = NotebookCommand(command: .panelUndo)
  undo.panelUndo = .init(workspaceID: workspaceID, target: target, actionID: move.actionID)
  let undone = try dispatcher.handle(undo)
  #expect(try dispatcher.handle(undo) == undone)
  #expect(try edit(move) == committed)
  let restored = try source()
  #expect((restored.page?.frame.x ?? restored.spatial?.frame.x) == 20)
  #expect((restored.page?.source ?? restored.spatial?.source) == "Мысль, уточнённая агентом")
  var read = NotebookCommand(command: .panelRead)
  read.panelRead = .init(workspaceID: workspaceID, target: target)
  let readResult = try dispatcher.handle(read)
  #expect(readResult["target"] == (try JSONValue.encode(target)))
  #expect(readResult["elements"]?.array.first?["source"]?["source"] == .string("Мысль, уточнённая агентом"))
  #expect(readResult["history"]?["undoActionID"]?.string?.lowercased() == create.actionID.uuidString.lowercased())
  #expect(readResult["rawInkPresent"] == .bool(false))
  if onBoard { #expect(readResult["cards"]?.array.isEmpty == false) }
  read.panelRead = .init(workspaceID: workspaceID, target: target, knownCursor: readResult["cursor"]?.string)
  let unchanged = try dispatcher.handle(read)
  #expect(unchanged["unchanged"] == .bool(true))
  #expect(unchanged["elements"] == nil)
  read.panelRead = .init(workspaceID: UUID(), target: target)
  #expect(throws: CollaborationError.self) { try dispatcher.handle(read) }
  #expect(throws: CollaborationError.self) { try NotebookCommandDispatcher(store: store).handle(undo) }
}

@Test("Панель доски читает нативные стирания текста и фигуры", arguments: [false, true])
func notebookPanelBoardAppearance(fullyErased: Bool) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-panel-appearance-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let actor = UUID(), store = NotebookStore(root: root)
  let (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
  _ = try store.loadOrCreateSpatialInk(actor: actor)
  let workspaceID = try store.storedWorkspaceID()
  let target = CollaborationTarget(kind: .board, id: workspace.rootBoardID), surface = SurfaceID.board(target.id)
  let frame = PageRect(x: 100, y: 200, width: 160, height: 100)
  let ids = ["caption", "box"]
  let operations: [CollaborationOperation] = try ids.map { id in
    var values: [String: JSONValue] = ["kind": .string(id == "box" ? "graphic" : "nativeText"),
      "source": .string("Исходный материал"), "frame": try .encode(frame), "worldOrigin": try .encode(WorldPoint.zero)]
    if id == "box" { values["graphic"] = try .encode(NotebookGraphic(shape: .rectangle, style: .init(strokeWidth: 4))) }
    return .init(kind: .insertElement, target: target, id: id, values: values)
  }
  _ = try store.editPanel(.init(workspaceID: workspaceID, actionID: UUID(), target: target, summary: "Добавить материал",
    operations: operations, sources: ids.map { .init(id: $0) }), actor: actor)
  let capturedSources = try ids.map { id in
    let source = try store.readSpatialElement(boardID: target.id, elementID: id)
    return try #require(source)
  }
  let read = NotebookPanelReadRequest(workspaceID: workspaceID, target: target,
    bounds: .init(anchor: .zero, region: .init(x: 0, y: 0, width: 800, height: 800)))
  let intact = try store.readPanel(read, actor: actor)
  for entry in intact["elements"]!.array { #expect(entry["appearance"]?["state"] == .string("intact")) }
  let point = SpatialPoint(x: frame.x + (fullyErased ? 80 : 5), y: frame.y + 50)
  let sample = SpatialInkSample(point: point, worldPoint: WorldPoint(x: point.x, y: point.y), timeOffset: 0,
    width: fullyErased ? 400 : 30, opacity: 1, force: 1, azimuth: 0, altitude: 1)
  let erase = SpatialInkAction(tool: .eraser,
    spans: [.init(surface: surface, samples: [sample]).erasingElements(ids.map {
      .init(elementID: $0, frame: frame, worldOrigin: .zero)
    })], stamp: .init(counter: 20, actor: actor))
  try store.commitSpatialInk(.append(erase, journalStamp: erase.stamp))
  let entries = try store.readPanel(read, actor: actor)["elements"]!.array
  #expect(entries.count == ids.count)
  for source in capturedSources {
    let entry = try #require(entries.first { $0["source"]?["id"] == .string(source.id) })
    #expect(entry["source"] == (try JSONValue.encode(source)), "Erasures change appearance without rewriting authored content")
    #expect(entry["appearance"]?["state"] == .string(fullyErased ? "erased" : "partial"))
    #expect(entry["appearance"]?["sourceIsCompleteAppearance"] == .bool(false))
  }
}
