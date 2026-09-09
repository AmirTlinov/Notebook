import Foundation
import Testing
@testable import NotebookCore

@Test("Клетка равна половине сантиметра на полноразмерном iPad")
func halfCentimeterGrid() {
  #expect(abs(PhysicalPaper.pointsPerCentimeter - 51.968_503_937) < 0.000_001)
  #expect(abs(PhysicalPaper.gridSpacing - 25.984_251_969) < 0.000_001)
}

@Test("Сила Pencil поднимает непрозрачность от выбранного минимума до единицы")
func pencilPressureControlsOpacity() {
  #expect(PencilPressureOpacity.value(force: 0, minimum: 0.2) == 0.2)
  #expect(
    abs(PencilPressureOpacity.value(force: 0.5, minimum: 0.2) - 0.8)
      < 0.000_001
  )
  #expect(PencilPressureOpacity.value(force: 1, minimum: 0.2) == 1)
  #expect(PencilPressureOpacity.value(force: 2, minimum: 0.2) == 1)
  #expect(PencilPressureOpacity.value(force: -1, minimum: 0.2) == 0.2)
  #expect(
    PencilPressureOpacity.value(force: 0, minimum: 1)
      == PencilPressureOpacity.maximumFloor
  )
}

@Test("Сила Pencil измеряется относительно максимума его датчика")
func pencilForceUsesTheHardwareRange() {
  #expect(PencilPressure.normalized(force: 0, maximum: 4) == 0)
  #expect(PencilPressure.normalized(force: 1, maximum: 4) == 0.25)
  #expect(PencilPressure.normalized(force: 4, maximum: 4) == 1)
  #expect(PencilPressure.normalized(force: 8, maximum: 4) == 1)
  #expect(PencilPressure.normalized(force: -1, maximum: 4) == 0)
  #expect(PencilPressure.normalized(force: 1, maximum: 0) == 0)
}

@Test("Короткий фильтр убирает дрожание нажима без скачка")
func pencilPressureSmoothingHasAStableTimeResponse() {
  #expect(
    PencilPressureSmoothing.value(
      force: 0.7,
      previous: nil,
      elapsed: nil
    ) == 0.7
  )
  #expect(
    PencilPressureSmoothing.value(
      force: 1,
      previous: 0.25,
      elapsed: 0
    ) == 0.25
  )
  let oneResponseTime = PencilPressureSmoothing.value(
    force: 1,
    previous: 0,
    elapsed: PencilPressureSmoothing.responseTime
  )
  #expect(abs(oneResponseTime - (1 - exp(-1))) < 0.000_001)
}

@Test("Нажим Pencil расширяет ластик до выбранной толщины")
func pencilPressureControlsEraserWidth() {
  #expect(PencilPressureWidth.value(force: 0, minimum: 3, maximum: 21) == 3)
  #expect(PencilPressureWidth.value(force: 0.5, minimum: 3, maximum: 21) == 12)
  #expect(PencilPressureWidth.value(force: 1, minimum: 3, maximum: 21) == 21)
  #expect(PencilPressureWidth.value(force: 2, minimum: 3, maximum: 21) == 21)
  #expect(PencilPressureWidth.value(force: -1, minimum: 3, maximum: 21) == 3)
}

@Test("Уточнение одного замера Pencil может только расширить уже стёртое место")
func eraserForceCorrectionKeepsErasureMonotonic() {
  #expect(PencilEraserContact.reconciledWidth(previous: 18, updated: 7) == 18)
  #expect(PencilEraserContact.reconciledWidth(previous: 18, updated: 24) == 24)
}

private func undoTestStroke() -> PageInkAction {
  .init(tool: .pen, samples: [.init(point: .init(x: 10, y: 20), timeOffset: 0,
    width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
}

@Test("Один контакт владеет UUID отмены, а не копией рисунка")
func pencilUndoRecordsOneCompletedAction() throws {
  let pageID = UUID(), stroke = undoTestStroke()
  var history = PencilUndoHistory()
  history.recordAction(pageID: pageID, actionID: stroke.id)
  let ids = try #require(history.lastContribution(for: pageID))
  #expect(ids == [stroke.id])
  let drawing = PageInkDrawing().appending(stroke).removing(ids)
  #expect(drawing.isEmpty)
  #expect(drawing.actions.first?.isActive == false)
  history.didRemoveContribution(ids, for: pageID)
  #expect(history.lastContribution(for: pageID) == nil)
}

@Test("История Pencil разделена по листам и ограничена")
func pencilUndoIsPageLocalAndBounded() throws {
  let firstPage = UUID(), secondPage = UUID()
  var history = PencilUndoHistory(capacity: 2)
  let strokes = (0..<3).map { _ in undoTestStroke() }
  for stroke in strokes { history.recordAction(pageID: firstPage, actionID: stroke.id) }
  let other = UUID()
  history.recordAction(pageID: secondPage, actionID: other)
  #expect(history.lastContribution(for: secondPage) == [other])
  history.didRemoveContribution([other], for: secondPage)
  #expect(history.lastContribution(for: secondPage) == nil)
  #expect(history.lastContribution(for: firstPage) == [strokes[2].id])
  history.didRemoveContribution([strokes[2].id], for: firstPage)
  #expect(history.lastContribution(for: firstPage) == [strokes[1].id])
  history.didRemoveContribution([strokes[1].id], for: firstPage)
  #expect(history.lastContribution(for: firstPage) == nil)
}

@Test("Удаление листа освобождает его локальную историю отмены")
func pencilUndoCanDiscardAStalePageHistory() {
  let pageID = UUID()
  var history = PencilUndoHistory()
  history.recordAction(pageID: pageID, actionID: UUID())
  history.discardChanges(for: pageID)
  #expect(history.lastContribution(for: pageID) == nil)
}

@Test("Перелистывание за последний лист создаёт ровно один лист")
func pageTurnCreatesOnePage() {
  let actor = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let initial = WorkspaceIndex.initial(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var index = initial.index

  let created = index.selectPage(
    at: 1,
    in: index.selectedItemID,
    actor: actor,
    pageSize: initial.page.size
  )
  #expect(created?.createdPage != nil)
  #expect(index.selectedItem.pageIDs.count == 2)
  #expect(index.selectedPageID == created?.pageID)

  _ = index.selectPage(
    at: 0,
    in: index.selectedItemID,
    actor: actor,
    pageSize: initial.page.size
  )
  let reopened = index.selectPage(
    at: 1,
    in: index.selectedItemID,
    actor: actor,
    pageSize: initial.page.size
  )
  #expect(reopened?.createdPage == nil)
  #expect(index.selectedItem.pageIDs.count == 2)
}

@Test("Абсолютная посадка листа не зависит от запоздавшего текущего индекса")
func absolutePageSelectionLandsOnTheRequestedSheet() throws {
  let actor = UUID()
  let size = PageSize(width: 834, height: 1_194)
  let initial = WorkspaceIndex.initial(actor: actor, pageSize: size)
  var index = initial.index
  let itemID = index.selectedItemID

  let secondResult = index.selectPage(
    at: 1,
    in: itemID,
    actor: actor,
    pageSize: size
  )
  _ = try #require(secondResult)
  let thirdResult = index.selectPage(
    at: 2,
    in: itemID,
    actor: actor,
    pageSize: size
  )
  let third = try #require(thirdResult)
  let firstResult = index.selectPage(
    at: 0,
    in: itemID,
    actor: actor,
    pageSize: size
  )
  _ = try #require(firstResult)

  let landingResult = index.selectPage(
    at: 2,
    in: itemID,
    actor: actor,
    pageSize: size
  )
  let landing = try #require(landingResult)
  #expect(landing.pageID == third.pageID)
  #expect(landing.createdPage == nil)
  #expect(index.selectedPageIndex == 2)
}

@Test("Выбор принадлежит последней команде Presence и не меняет состав листов")
func orderedPresenceSelectionPreservesEveryCreatedPage() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let actor = UUID()
  let size = PageSize(width: 834, height: 1_194)
  let initial = WorkspaceIndex.initial(actor: actor, pageSize: size)
  let store = NotebookStore(root: root)
  let board = BoardHierarchy.initial(
    rootBoardID: initial.index.rootBoardID,
    itemIDs: [initial.index.selectedItemID],
    actor: actor
  )
  try store.saveWorkspaceBundle(
    index: initial.index,
    page: initial.page,
    board: board
  )

  try store.savePresence(SessionPresence(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194), selectedItemID: initial.index.selectedItemID, notebookPageID: initial.page.id))
  var firstLanding = initial.index
  let itemID = firstLanding.selectedItemID
  let secondPageResult = firstLanding.selectPage(
    at: 1,
    in: itemID,
    actor: actor,
    pageSize: size
  )
  let secondPage = try #require(secondPageResult)
  _ = try store.saveWorkspaceSelection(
    index: firstLanding,
    createdPage: secondPage.createdPage
  )

  var latestLanding = firstLanding
  let thirdPageResult = latestLanding.selectPage(
    at: 2,
    in: itemID,
    actor: actor,
    pageSize: size
  )
  let thirdPage = try #require(thirdPageResult)
  _ = try store.saveWorkspaceSelection(
    index: latestLanding,
    createdPage: thirdPage.createdPage
  )
  _ = try store.saveWorkspaceSelection(
    index: firstLanding,
    createdPage: nil
  )

  let persisted = try store.loadIndex()
  #expect(persisted.selectedPageID == secondPage.pageID)
  #expect(Set(persisted.selectedItem.pageIDs) == Set([initial.page.id, secondPage.pageID, thirdPage.pageID]))
  #expect(try store.loadPage(thirdPage.pageID).id == thirdPage.pageID)
}

@Test("Обложка может жить без печатного названия и сохраняет устойчивый UUID")
func blankNotebookTitleIsAValidVisualCover() throws {
  let actor = UUID()
  let initial = WorkspaceIndex.initial(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var index = initial.index

  let creation = index.createNotebook(
    title: "   ",
    actor: actor,
    pageSize: initial.page.size
  )
  let created = try #require(creation)

  #expect(created.item.title.isEmpty)
  #expect(index.isValid)
  #expect(index.selectedItemID == created.item.id)
}

@Test("Удаление публикует каталог и доску, затем убирает страницы")
func storeDeletesOneCompleteNotebookBundle() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let actor = UUID()
  let store = NotebookStore(root: root)
  let loaded = try store.loadOrCreate(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var index = loaded.0
  var board = try store.loadOrCreateBoard(workspace: index, actor: actor)
  let creation = index.createNotebook(
    title: "",
    actor: actor,
    pageSize: loaded.1.values.first!.size
  )
  let created = try #require(creation)
  let added = board.addItem(
    created.item.id,
    to: index.rootBoardID,
    near: .zero,
    actor: actor
  )
  #expect(added)
  try store.saveWorkspaceBundle(
    index: index,
    page: created.page,
    board: board
  )
  let pageURL = store.pageURL(created.page.id)
  #expect(try store.hasStoredValue(at: pageURL))

  let expectedIndex = index
  let removed = index.deleteItem(created.item.id, actor: actor)
  _ = try #require(removed)
  let removedFromBoard = board.deleteItem(
    created.item.id,
    from: index.rootBoardID,
    kind: .notebook,
    spatialInk: SpatialInkJournal(stamp: VersionStamp(counter: 0, actor: actor)),
    actor: actor
  )
  #expect(removedFromBoard)
  try store.deleteWorkspaceBundle(
    expectedIndex: expectedIndex,
    index: index,
    board: board,
    pageIDs: created.item.pageIDs
  )

  #expect(try store.loadIndex() == index)
  #expect(try store.loadBoard(items: index.items) == board)
  #expect(try !store.hasStoredValue(at: pageURL))

  #expect(throws: CocoaError.self) {
    try store.saveMergedPage(created.page)
  }
  #expect(try !store.hasStoredValue(at: pageURL))
}

@Test("Удаление выбранной тетради выбирает ближайшую живую тетрадь")
func deletingNotebookKeepsWorkspaceSelectionLive() throws {
  let actor = UUID()
  let initial = WorkspaceIndex.initial(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var index = initial.index
  let secondCreation = index.createNotebook(
    title: "",
    actor: actor,
    pageSize: initial.page.size
  )
  let second = try #require(secondCreation)
  let thirdCreation = index.createNotebook(
    title: "Третья",
    actor: actor,
    pageSize: initial.page.size
  )
  let third = try #require(thirdCreation)
  _ = index.selectItem(second.item.id, actor: actor)

  let deletion = index.deleteItem(second.item.id, actor: actor)
  let removed = try #require(deletion)

  #expect(removed.id == second.item.id)
  #expect(index.selectedItemID == third.item.id)
  #expect(index.selectedPageID == third.page.id)
  #expect(index.isValid)
  let removedFirst = index.deleteItem(
    initial.index.selectedItemID,
    actor: actor
  )
  let refusedLast = index.deleteItem(third.item.id, actor: actor)
  #expect(removedFirst != nil)
  #expect(refusedLast == nil)
}

@Test("Штрихи и агентские элементы сходятся независимо")
func pageFieldsMergeIndependently() {
  let firstActor = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let secondActor = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  let id = UUID()
  let size = PageSize(width: 834, height: 1_194)
  var pencil = PageDocument(id: id, size: size, actor: firstActor)
  var agent = pencil

  pencil.replaceDrawing(pageDrawingFixture(Data("ink".utf8)), actor: firstActor)
  agent.replaceElements(
    [
      AgentElement(
        id: "idea",
        kind: .markdown,
        frame: PageRect(x: 52, y: 52, width: 300, height: 100),
        source: "**Мысль**",
        html: "<strong>Мысль</strong>"
      )
    ],
    actor: secondActor
  )

  let changed = pencil.merge(agent)
  #expect(changed)
  #expect(pencil.drawingData == pageDrawingFixture(Data("ink".utf8)))
  #expect(pencil.elements.map(\.id) == ["idea"])
}

@Test("Один UUID листа не может соединить разные физические размеры")
func pageMergeKeepsItsPhysicalSizeInvariant() {
  let actor = UUID()
  let id = UUID()
  var portrait = PageDocument(
    id: id,
    size: PageSize(width: 834, height: 1_194),
    actor: actor
  )
  var landscape = PageDocument(
    id: id,
    size: PageSize(width: 1_194, height: 834),
    actor: actor
  )
  landscape.replaceDrawing(pageDrawingFixture(Data("landscape".utf8)), actor: actor)

  let changed = portrait.merge(landscape)
  #expect(!changed)
  #expect(portrait.drawingData.isEmpty)
  #expect(portrait.size == PageSize(width: 834, height: 1_194))
}

@Test("Исчерпанная версия спокойно оставляет лист и выбор без изменений")
func exhaustedVersionDoesNotCrashOrMutate() {
  let actor = UUID()
  let size = PageSize(width: 834, height: 1_194)
  var page = PageDocument(size: size, actor: actor)
  let reachedLimit = page.replaceDrawing(
    pageDrawingFixture(Data("last".utf8)),
    stamp: VersionStamp(
      counter: VersionStamp.maximumCounter,
      actor: actor
    )
  )
  let overflowed = page.replaceDrawing(pageDrawingFixture(Data("overflow".utf8)), actor: actor)
  #expect(reachedLimit)
  #expect(!overflowed)
  #expect(page.drawingData == pageDrawingFixture(Data("last".utf8)))

  let pageID = UUID()
  let itemID = UUID()
  var index = WorkspaceIndex(
    items: [WorkspaceItem.notebook(id: itemID, title: "Notebook 1", pageIDs: [pageID])],
    selectedItemID: itemID,
    selectedPageID: pageID,
    stamp: VersionStamp(
      counter: VersionStamp.maximumCounter,
      actor: actor
    )
  )
  let before = index
  #expect(index.selectPage(
    at: 1,
    in: itemID,
    actor: actor,
    pageSize: size
  ) == nil)
  #expect(index == before)
}

@Test("Состояние интерактивного слоя содержит только конечные JSON-числа")
func pageRejectsNonFiniteInteractiveState() {
  let actor = UUID()
  var page = PageDocument(
    size: PageSize(width: 834, height: 1_194),
    actor: actor
  )
  let element = AgentElement(
    id: "counter",
    kind: .web,
    frame: PageRect(x: 0, y: 0, width: 100, height: 100),
    source: "",
    html: "",
    state: .number(.infinity)
  )

  let changed = page.replaceElements([element], actor: actor)
  #expect(!changed)
  #expect(page.elements.isEmpty)
}

@Test("Хранилище атомарно возвращает тот же лист")
func storeRoundTrip() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = NotebookStore(root: root)
  let actor = UUID()
  let created = try store.loadOrCreate(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  let selectedPageID = try #require(created.0.selectedPageID)
  var page = try #require(created.1[selectedPageID])
  page.replaceDrawing(pageDrawingFixture(Data([1, 2, 3])), actor: actor)
  try store.savePage(page)

  let reopened = try store.loadOrCreate(actor: UUID(), pageSize: page.size)
  #expect(reopened.0 == created.0)
  #expect(reopened.1[page.id] == page)
}


@Test("Поздняя запись сохраняет новые штрихи и новые элементы вместе")
func storeMergesConcurrentStreams() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = NotebookStore(root: root)
  let pencilActor = UUID()
  let agentActor = UUID()
  let created = try store.loadOrCreate(
    actor: pencilActor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  let selectedPageID = try #require(created.0.selectedPageID)
  var pencil = try #require(created.1[selectedPageID])
  var agent = pencil
  pencil.replaceDrawing(pageDrawingFixture(Data("new ink".utf8)), actor: pencilActor)
  agent.replaceElements(
    [
      AgentElement(
        id: "new-agent-layer",
        kind: .markdown,
        frame: PageRect(x: 0, y: 0, width: 200, height: 100),
        source: "Новый слой",
        html: "<p>Новый слой</p>"
      )
    ],
    actor: agentActor
  )

  try store.savePage(agent)
  let resolved = try store.saveMergedPage(pencil)

  #expect(resolved.drawingData == pageDrawingFixture(Data("new ink".utf8)))
  #expect(resolved.elements.map(\.id) == ["new-agent-layer"])
  #expect(try store.loadPage(resolved.id) == resolved)
  #expect(try store.databaseURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
}

@Test("Хранилище отвергает два физических размера одного листа")
func storeRejectsConflictingPageSize() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = NotebookStore(root: root)
  let actor = UUID()
  let id = UUID()
  try store.savePage(
    PageDocument(
      id: id,
      size: PageSize(width: 834, height: 1_194),
      actor: actor
    )
  )
  let conflicting = PageDocument(
    id: id,
    size: PageSize(width: 1_194, height: 834),
    actor: actor
  )

  #expect(throws: CocoaError.self) {
    try store.saveMergedPage(conflicting)
  }
}

@Test("Хранилище отвергает лист с невозможным физическим размером")
func storeRejectsInvalidDecodedPage() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = NotebookStore(root: root)
  let created = try store.loadOrCreate(
    actor: UUID(),
    pageSize: PageSize(width: 834, height: 1_194)
  )
  let pageID = try #require(created.0.selectedPageID)
  let pageURL = store.pageURL(pageID)
  var json = try #require(
    JSONSerialization.jsonObject(with: store.storedData(at: pageURL))
      as? [String: Any]
  )
  var size = try #require(json["size"] as? [String: Any])
  size["width"] = 0
  json["size"] = size
  try store.fixtureWrite(JSONSerialization.data(withJSONObject: json), to: pageURL)

  #expect(throws: CocoaError.self) {
    try store.loadPage(pageID)
  }
}

@Test("Хранилище не передаёт рендереру чрезмерный размер листа")
func storeRejectsAPathologicalPageAllocation() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = NotebookStore(root: root)
  let created = try store.loadOrCreate(
    actor: UUID(),
    pageSize: PageSize(width: 834, height: 1_194)
  )
  let pageID = try #require(created.0.selectedPageID)
  let pageURL = store.pageURL(pageID)
  var json = try #require(
    JSONSerialization.jsonObject(with: store.storedData(at: pageURL))
      as? [String: Any]
  )
  var size = try #require(json["size"] as? [String: Any])
  size["width"] = 1e100
  json["size"] = size
  try store.fixtureWrite(JSONSerialization.data(withJSONObject: json), to: pageURL)

  #expect(throws: CocoaError.self) {
    try store.loadPage(pageID)
  }
}

@Test("Хранилище отвергает тетрадь без выбранного живого листа")
func storeRejectsInvalidDecodedWorkspace() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = NotebookStore(root: root)
  _ = try store.loadOrCreate(
    actor: UUID(),
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var json = try #require(
    JSONSerialization.jsonObject(with: store.storedData(at: store.indexURL))
      as? [String: Any]
  )
  json["items"] = []
  try store.fixtureWrite(JSONSerialization.data(withJSONObject: json), to: store.indexURL)

  #expect(throws: CocoaError.self) {
    try store.loadIndex()
  }
}

@Test("Адрес предмета остаётся актуальным после добавления, удаления и быстрых новых страниц")
func workspaceItemLookupTracksMembershipAndPageContinuation() throws {
  let actor = UUID(), size = PageSize(width: 834, height: 1194)
  var workspace = WorkspaceIndex.initial(actor: actor, pageSize: size).index
  let firstID = workspace.selectedItemID
  let addedNotebook = workspace.createNotebook(title: "Continuation", actor: actor, pageSize: size)
  let notebook = try #require(addedNotebook)
  let addedDocument = workspace.createDocument(title: "Document", actor: actor)
  let document = try #require(addedDocument)
  let addedBoard = workspace.createBoard(title: "Board", actor: actor)
  let board = try #require(addedBoard)
  for value in workspace.items { #expect(workspace.item(id: value.id) == value) }
  let removedFirst = workspace.deleteItem(firstID, actor: actor)
  #expect(removedFirst?.id == firstID)
  #expect(workspace.item(id: firstID) == nil)
  let selectedNotebook = workspace.selectItem(notebook.item.id, actor: actor)
  #expect(selectedNotebook)
  for target in 1...8 {
    let changedPage = workspace.selectPage(at: target, in: notebook.item.id, actor: actor, pageSize: size)
    let selected = try #require(changedPage)
    let current = try #require(workspace.item(id: notebook.item.id))
    #expect(current.pageIDs.count == target + 1)
    #expect(current.pageIDs[target] == selected.pageID)
    #expect(workspace.selectedItem == current)
  }
  let removedDocument = workspace.deleteItem(document.id, actor: actor)
  #expect(removedDocument?.id == document.id)
  #expect(workspace.item(id: document.id) == nil)
  #expect(workspace.item(id: board.id) == board)
  #expect(workspace.item(id: UUID()) == nil)
  for value in workspace.items { #expect(workspace.item(id: value.id) == value) }
}

@Test("Декодирование сохраняет причинные версии каталога и восстанавливает производные адреса")
func workspaceItemLookupFollowsMergeAndDecodeWithoutWireMetadata() throws {
  let actor = UUID(), size = PageSize(width: 834, height: 1194)
  var workspace = WorkspaceIndex.initial(actor: actor, pageSize: size).index
  let second = workspace.createNotebook(title: "Second", actor: actor, pageSize: size)
  _ = try #require(second)
  let third = workspace.createBoard(title: "Third", actor: actor)
  _ = try #require(third)
  let reordered = WorkspaceIndex(items: Array(workspace.items.reversed()),
    selectedItemID: workspace.selectedItemID, selectedPageID: workspace.selectedPageID,
    stamp: VersionStamp(counter: workspace.stamp.counter + 1, actor: actor))
  let merged = workspace.merge(reordered)
  #expect(merged)
  for value in reordered.items { #expect(workspace.item(id: value.id) == value) }
  let data = try JSONEncoder().encode(workspace)
  let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(Set(fields.keys) == Set(["format", "rootBoardID", "items", "stamp", "collaboration", "pageOrders", "pageOrderNodes", "isProjection"]))
  let decoded = try JSONDecoder().decode(WorkspaceIndex.self, from: data)
  #expect(decoded == reordered)
  for value in reordered.items { #expect(decoded.item(id: value.id) == value) }
}
