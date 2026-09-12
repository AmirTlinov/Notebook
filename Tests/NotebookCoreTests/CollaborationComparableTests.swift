import Foundation
import Testing
@testable import NotebookCore

private let programMetadataNames = ["stamp", "agentStamp", "drawingStamp", "stateStamp", "contentStamp",
  "portalStamp", "collaboration", "fieldVersion", "selectionVersion"]

private func programState(_ key: String, _ value: String) -> JSONValue {
  // The only changed leaf sits below the tested name, inside arbitrary program
  // data, including an id-bearing array that is not a domain member collection.
  .object(["nested": .array([.object(["id": .string("program-record"),
    "payload": .object([key: .object(["value": .string(value)])])])])])
}

private struct ComparableFixture {
  let root: URL
  let store: NotebookStore
  let human = UUID(), agent = UUID()
  let pageID: UUID, boardID: UUID

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-comparable-" + UUID().uuidString)
    store = NotebookStore(root: root)
    let header = try store.initializeWorkspace(actor: human, pageSize: .init(width: 834, height: 1194))
    boardID = header.rootBoardID
    pageID = try store.loadIndex().items[0].pageIDs[0]
    _ = try store.loadOrCreateSpatialInk(actor: human)
  }
  func clean() { try? FileManager.default.removeItem(at: root) }
  var board: CollaborationTarget { .init(kind: .board, id: boardID) }
  var page: CollaborationTarget { .init(kind: .page, id: pageID) }

  func action(_ operations: [CollaborationOperation], targets: [CollaborationTarget]) throws -> CollaborationAction {
    .init(summary: "Изменение значения программы", expected: try targets.map { target in
      switch target.kind {
      case .codeFragment: return .init(target: target, revision: try #require(try store.codeFragment(target.id)).stamp.revision)
      case .workspace: return .init(target: target, revision: try store.loadIndex().stamp.revision)
      case .board, .cover: return .init(target: target, revision: try store.targetContentRevision(target: target))
      case .page: return .init(target: target, revision: try store.loadPage(target.id).agentStamp.revision)
      case .document: return .init(target: target, revision: try store.loadDocument(target.id).contentStamp.revision,
        stateRevision: try store.loadDocumentState(target.id).stamp.revision)
      }
    }, operations: operations)
  }

  func insert(_ target: CollaborationTarget, state: JSONValue) throws -> CollaborationOperation {
    var values: [String: JSONValue] = ["kind": .string("web"), "source": .string("<button>Подтвердить</button>"),
      "frame": try .encode(PageRect(x: 20, y: 20, width: 200, height: 80)), "state": state]
    if target.kind != .page { values["worldOrigin"] = try .encode(WorldPoint.zero) }
    return .init(kind: .insertElement, target: target, id: "confirmation", values: values)
  }

  func createDocument(initialState: JSONValue) throws -> (CollaborationTarget, CollaborationAction) {
    let target = CollaborationTarget(kind: .document, id: UUID())
    let block = DocumentBlock.interactive(id: "confirmation", html: "<button>Подтвердить</button>", initialState: initialState)
    let action = try action([.init(kind: .createDocument, target: board, id: target.id.uuidString, values: [
      "paperSize": .string("a4"), "center": try .encode(WorldPoint.zero), "blocks": try .encode([block])])],
      targets: [board, .init(kind: .workspace, id: boardID)])
    _ = try store.applyCollaborationAction(action, actor: agent)
    return (target, action)
  }
}

@Test("Отмена создания сохраняет принятую человеком тетрадь, страницу и вложенное состояние",
  arguments: programMetadataNames + ["status"])
func collaborationComparableProtectsHumanAdoptedNotebook(stateKey: String) throws {
  let f = try ComparableFixture(); defer { f.clean() }
  let itemID = UUID(), pageID = UUID(), target = CollaborationTarget(kind: .page, id: pageID)
  let action = try f.action([.init(kind: .createNotebook, target: f.board, id: itemID.uuidString, values: [
    "pageID": .string(pageID.uuidString), "center": try .encode(WorldPoint.zero)]),
    f.insert(target, state: programState(stateKey, "draft"))], targets: [f.board, .init(kind: .workspace, id: f.boardID)])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  #expect(receipt.changes.contains { $0.file == pageFile(pageID) && $0.path.isEmpty })

  // This is the real native commitElementState path, not a fixture overwrite.
  var page = try f.store.loadPage(pageID)
  let state = programState(stateKey, "confirmed by the person")
  let changed = page.replaceElements([page.elements[0].updating(state: state)], actor: f.human)
  #expect(changed)
  _ = try f.store.savePage(page)
  #expect(try f.store.loadPage(pageID).elements[0].state == state)
  #expect(try f.store.collaborationContinuations(action.id).contains { $0.file == pageFile(pageID) && $0.author == .human })

  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  let pageRetained = try f.store.hasStoredValue(pageFile(pageID))
  let itemRetained = try f.store.readItemHeader(itemID) != nil
  #expect(itemRetained)
  #expect(pageRetained)
  #expect(undone.undo?.restored == 0)
  #expect(undone.undo?.preserved.count == receipt.changes.count)
  if pageRetained { #expect(try f.store.loadPage(pageID).elements[0].state == state) }
  if itemRetained { #expect(try f.store.readNotebookPageDirectory(itemID: itemID, limit: 4).pages.map(\.position.pageID) == [pageID]) }
}

@Test("Квитанция и отмена листа сохраняют все имена во вложенном JSON", arguments: programMetadataNames)
func collaborationComparablePageStateReceiptAndUndo(stateKey: String) throws {
  let f = try ComparableFixture(); defer { f.clean() }
  let initial = programState(stateKey, "human value"), edited = programState(stateKey, "agent value")
  var page = try f.store.loadPage(f.pageID)
  let inserted = page.replaceElements([.init(id: "confirmation", kind: .web,
    frame: .init(x: 20, y: 20, width: 200, height: 80), source: "<button/>", html: "<button/>", state: initial)], actor: f.human)
  #expect(inserted)
  page = try f.store.savePage(page)
  let action = try f.action([.init(kind: .setElementState, target: f.page, id: "confirmation", values: ["state": edited])], targets: [f.page])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  let change = try #require(receipt.changes.count == 1 ? receipt.changes.first : nil)
  #expect(change.file == pageFile(f.pageID))
  #expect(change.path == [.field("elements"), .member("confirmation"), .field("state")])
  #expect(change.before == initial && change.after == edited)
  #expect(change.afterVersion?.human == false)
  let delivered = try f.store.loadPage(f.pageID)
  #expect(delivered.elements[0].state == edited)
  #expect(delivered.agentStamp > page.agentStamp)
  #expect(delivered.drawingStamp == page.drawingStamp)

  let sameAction = try f.action([.init(kind: .setElementState, target: f.page, id: "confirmation", values: ["state": edited])], targets: [f.page])
  let sameReceipt = try f.store.applyCollaborationAction(sameAction, actor: f.agent)
  #expect(sameReceipt.changes.isEmpty)
  #expect(try f.store.loadPage(f.pageID).agentStamp == delivered.agentStamp)

  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(undone.undo?.restored == 1 && undone.undo?.preserved.isEmpty == true)
  let restored = try f.store.loadPage(f.pageID)
  #expect(restored.elements[0].state == initial)
  #expect(restored.agentStamp > delivered.agentStamp)
  #expect(restored.drawingStamp == delivered.drawingStamp)
  let afterEcho = try f.store.savePage(delivered)
  #expect(afterEcho.elements[0].state == initial)
}

@Test("Stamp элемента доски остаётся метаданными, а одноимённое состояние записывается и отменяется",
  arguments: programMetadataNames)
func collaborationComparableSpatialStateReceiptAndUndo(stateKey: String) throws {
  let f = try ComparableFixture(); defer { f.clean() }
  let initial = programState(stateKey, "before"), edited = programState(stateKey, "after")
  _ = try f.store.applyCollaborationAction(f.action([f.insert(f.board, state: initial)], targets: [f.board]), actor: f.agent)
  let before = try #require(try f.store.readSpatialElement(boardID: f.boardID, elementID: "confirmation"))
  let action = try f.action([.init(kind: .setElementState, target: f.board, id: "confirmation", values: ["state": edited])], targets: [f.board])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  let change = try #require(receipt.changes.count == 1 ? receipt.changes.first : nil)
  #expect(change.file == "board.json")
  #expect(change.path == [.field("boards"), .member(f.boardID.uuidString.lowercased()), .field("board"),
    .field("elements"), .member("confirmation"), .field("state")])
  #expect(change.before == initial && change.after == edited)
  let editedElement = try #require(try f.store.readSpatialElement(boardID: f.boardID, elementID: "confirmation"))
  #expect(editedElement.state == edited && editedElement.stamp > before.stamp)
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(undone.undo?.restored == 1 && undone.undo?.preserved.isEmpty == true)
  let restored = try #require(try f.store.readSpatialElement(boardID: f.boardID, elementID: "confirmation"))
  #expect(restored.state == initial)
}

@Test("Отмена состояния документа обновляет причинную версию и переживает старую доставку",
  arguments: programMetadataNames)
func collaborationComparableDocumentStateReceiptAndUndo(stateKey: String) throws {
  let f = try ComparableFixture(); defer { f.clean() }
  let initial = programState(stateKey, "human value"), edited = programState(stateKey, "agent value")
  let (target, _) = try f.createDocument(initialState: .object([:]))
  var state = try f.store.loadDocumentState(target.id)
  let committed = state.commit(blockID: "confirmation", value: initial, actor: f.human)
  #expect(committed)
  _ = try f.store.commitDocumentState(.init(documentID: target.id,
    record: #require(state.records.first { $0.id == "confirmation" }), journalStamp: state.stamp))
  state = try f.store.loadDocumentState(target.id)
  let document = try f.store.loadDocument(target.id)
  let action = try f.action([.init(kind: .setBlockState, target: target, id: "confirmation", values: ["state": edited])], targets: [target])
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  let change = try #require(receipt.changes.count == 1 ? receipt.changes.first : nil)
  #expect(change.file == stateFile(target.id))
  #expect(change.path == [.field("records"), .member("confirmation"), .field("value")])
  #expect(change.before == initial && change.after == edited)
  #expect(change.afterVersion?.human == false)
  let delivered = try f.store.loadDocumentState(target.id)
  #expect(delivered.value(for: "confirmation") == edited && delivered.stamp > state.stamp)
  #expect(try f.store.loadDocument(target.id).contentStamp == document.contentStamp)

  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(undone.undo?.restored == 1 && undone.undo?.preserved.isEmpty == true)
  let restored = try f.store.loadDocumentState(target.id)
  #expect(restored.value(for: "confirmation") == initial)
  #expect(restored.stamp > delivered.stamp)
  #expect(restored.records[0].stamp > delivered.records[0].stamp)
  #expect(restored.records[0].fieldVersion?.human == true)
  let afterEcho = try f.store.commitDocumentState(.init(documentID: target.id,
    record: #require(delivered.records.first { $0.id == "confirmation" }), journalStamp: delivered.stamp))
  #expect(afterEcho.record.value == initial)
}

@Test("Начальное состояние блока тоже является авторским содержанием, а не служебными полями",
  arguments: programMetadataNames)
func collaborationComparableProtectsHumanDocumentInitialState(stateKey: String) throws {
  let f = try ComparableFixture(); defer { f.clean() }
  let initial = programState(stateKey, "draft"), edited = programState(stateKey, "human value")
  let (target, action) = try f.createDocument(initialState: initial)
  var document = try f.store.loadDocument(target.id)
  let changed = document.replaceContent(blocks: [.interactive(id: "confirmation", html: "<button>Подтвердить</button>", initialState: edited)], actor: f.human)
  #expect(changed)
  _ = try f.store.saveMergedDocument(document)
  let undone = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(try f.store.readItemHeader(target.id) != nil)
  let retained = try f.store.hasStoredValue(documentFile(target.id))
  #expect(retained)
  #expect(try f.store.hasStoredValue(stateFile(target.id)))
  #expect(undone.undo?.restored == 0)
  if retained { #expect(try f.store.loadDocument(target.id).blocks[0].initialState == edited) }
}

private func metadataReceipt(file: String, value: JSONValue) -> CollaborationReceipt {
  let action = CollaborationAction(summary: "Сравнение вклада", expected: [], operations: [])
  return .init(id: action.id, action: action, createdAt: Date(), revisions: [],
    changes: [.init(file: file, path: [], before: nil, after: value)])
}

private func expectQualifiedMetadata<T: Codable>(_ original: T, file: String,
  changes: [([CollaborationPathComponent], JSONValue)]) throws -> T {
  let before = try JSONValue.encode(original)
  var after = before
  for (path, value) in changes { after = try #require(after.setting(at: path[...], to: value)) }
  let typed = try after.decode(T.self)
  #expect(before != after)
  #expect(metadataReceipt(file: file, value: before).continuations(in: [file: try .encode(typed)]).isEmpty)
  return typed
}

@Test("Сравнение исключает версии только у точного типизированного доменного владельца")
func collaborationComparableQualifiedDomainMetadata() throws {
  let f = try ComparableFixture(); defer { f.clean() }
  let next = VersionStamp(counter: 100, actor: f.human), stamp = try JSONValue.encode(next)
  var metadata = CollaborativeContent()
  metadata.recordField("preamble", stamp: next, human: true)
  let metadataValue = try JSONValue.encode(metadata)

  let page = try f.store.loadPage(f.pageID)
  let laterPage = try expectQualifiedMetadata(page, file: pageFile(page.id), changes: [
    ([.field("agentStamp")], stamp), ([.field("drawingStamp")], stamp), ([.field("collaboration")], metadataValue)])
  #expect(laterPage.isValid)

  let document = DocumentDocument(actor: f.human, blocks: [.interactive(id: "confirmation", html: "<button/>", initialState: programState("contentStamp", "same"))])
  let laterDocument = try expectQualifiedMetadata(document, file: documentFile(document.id), changes: [
    ([.field("contentStamp")], stamp), ([.field("collaboration")], metadataValue)])
  #expect(laterDocument.isValid)

  var state = DocumentStateJournal(id: document.id, actor: f.human)
  _ = state.commit(blockID: "confirmation", value: programState("fieldVersion", "same"), actor: f.human)
  let recordPath: [CollaborationPathComponent] = [.field("records"), .member("confirmation")]
  let laterState = try expectQualifiedMetadata(state, file: stateFile(document.id), changes: [
    ([.field("stamp")], stamp), (recordPath + [.field("stamp")], stamp),
    (recordPath + [.field("fieldVersion")], try .encode(ContentFieldVersion(stamp: next, human: true)))])
  #expect(laterState.isValid)

  let workspace = try f.store.loadIndex()
  var workspaceMetadata = workspace.collaboration
  workspaceMetadata.recordField(fieldKey(["items", workspace.items[0].id.uuidString.lowercased(), "title"]), stamp: next, human: true)
  let laterWorkspace = try expectQualifiedMetadata(workspace, file: "workspace.json", changes: [
    ([.field("stamp")], stamp), ([.field("collaboration")], try .encode(workspaceMetadata))])
  #expect(laterWorkspace.isValid)

  let itemIDs = [UUID(), UUID(), UUID()], stackID = UUID()
  let element = SpatialElement(id: "confirmation", surface: .board(f.boardID), kind: .web,
    frame: .init(x: 0, y: 0, width: 200, height: 80), worldOrigin: .zero, source: "<button/>",
    state: programState("stamp", "same"), stamp: .init(counter: 0, actor: f.human))
  let board = BoardDocument(freeItems: [.init(itemID: itemIDs[0], center: .zero, zIndex: 0, stamp: .init(counter: 0, actor: f.human))],
    stacks: [.init(id: stackID, center: .init(x: 1000, y: 0), zIndex: 1, itemIDs: Array(itemIDs.dropFirst()), stamp: .init(counter: 0, actor: f.human))],
    elements: [element], stamp: .init(counter: 0, actor: f.human))
  let tree = BoardHierarchy(rootBoardID: f.boardID, boards: [.init(id: f.boardID, board: board)], stamp: .init(counter: 0, actor: f.human))
  let nodePath: [CollaborationPathComponent] = [.field("boards"), .member(f.boardID.uuidString)]
  let boardPath = nodePath + [.field("board")]
  let laterTree = try expectQualifiedMetadata(tree, file: "board.json", changes: [
    ([.field("stamp")], stamp), (nodePath + [.field("portalStamp")], stamp),
    (boardPath + [.field("stamp")], stamp), (boardPath + [.field("collaboration")], metadataValue),
    (boardPath + [.field("elements"), .member("confirmation"), .field("stamp")], stamp)])
  #expect(laterTree.isValid(items: itemIDs.map { .notebook(id: $0, title: "", pageIDs: [UUID()]) }))

  let action = SpatialInkAction(tool: .pen, spans: [.init(surface: .board(f.boardID), samples: [
    .init(point: .zero, worldPoint: .zero, timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])],
    stamp: .init(counter: 0, actor: f.human))
  let ink = SpatialInkJournal(actions: [action], stamp: action.stamp)
  let actionPath: [CollaborationPathComponent] = [.field("actions"), .member(action.id.uuidString)]
  let laterInk = try expectQualifiedMetadata(ink, file: "spatial-ink.json", changes: [
    ([.field("stamp")], stamp), (actionPath + [.field("stamp")], stamp), (actionPath + [.field("stateStamp")], stamp)])
  #expect(laterInk.isValid)
}

@Test("Экранированный предмет читает собственную причинную версию и сохраняет принятие человеком",
  arguments: ["counter/a~😀", "A1451830-782E-4D5D-9131-64C0FDA01C24"])
func collaborationEscapedSpatialCausalOwnerSurvivesAValueRoundTrip(id: String) throws {
  let f = try ComparableFixture(); defer { f.clean() }
  let template = try f.insert(f.board, state: .number(1))
  _ = try f.store.applyCollaborationAction(f.action([
    .init(kind: .insertElement, target: f.board, id: id, values: template.values)
  ], targets: [f.board]), actor: f.agent)
  let action = try f.action([.init(kind: .setElementState, target: f.board, id: id,
    values: ["state": .number(2)])], targets: [f.board])
  let key = fieldKey(["elements", collaborationIdentity(id), "state"])
  let full = try #require(try f.store.loadBoard(items: f.store.loadIndex().items).board(f.boardID))
  let expected = try #require(full.collaboration?.fields[key])
  let files = try f.store.readTransaction { _ in try f.store.actionSourceProjection(action) }
  let projected = try #require(files.files["board.json"]).decode(BoardHierarchy.self)
  #expect(projected.board(f.boardID)?.collaboration?.fields[key] == expected,
    "The partial owner must not substitute the aggregate board stamp for this field")
  let receipt = try f.store.applyCollaborationAction(action, actor: f.agent)
  let authored = try #require(receipt.changes.first?.afterVersion)
  var rendered = try #require(try f.store.readSpatialElement(boardID: f.boardID, elementID: id))
  rendered = try #require(try f.store.commitSpatialElementState(boardID: f.boardID, rendered: rendered,
    state: .number(3), actor: f.human))
  _ = try f.store.commitSpatialElementState(boardID: f.boardID, rendered: rendered,
    state: .number(2), actor: f.human)
  let human = try #require(try f.store.loadBoard(items: f.store.loadIndex().items).board(f.boardID)?.collaboration?.fields[key])
  #expect(human.human && human.includes(authored))
  let undo = try f.store.undoCollaborationAction(action.id, actor: f.human)
  #expect(undo.undo?.restored == 0 && undo.undo?.preserved.count == 1)
  #expect(try f.store.readSpatialElement(boardID: f.boardID, elementID: id)?.state == .number(2))
}
