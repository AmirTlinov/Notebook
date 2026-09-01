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
    abs(PencilPressureOpacity.value(force: 0.5, minimum: 0.2) - 0.6)
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

@Test("Одно завершённое движение Pencil создаёт один шаг отмены")
func pencilUndoRecordsOneCompletedAction() {
  let pageID = UUID()
  let empty = Data()
  let drawing = Data("drawing".utf8)
  var history = PencilUndoHistory()

  history.recordAction(
    pageID: pageID,
    before: empty,
    after: drawing
  )

  #expect(history.removeLastChange(for: pageID) == empty)
  #expect(history.removeLastChange(for: pageID) == nil)
}

@Test("История Pencil разделена по листам и ограничена")
func pencilUndoIsPageLocalAndBounded() {
  let firstPage = UUID()
  let secondPage = UUID()
  var history = PencilUndoHistory(capacity: 2)

  history.recordAction(
    pageID: firstPage,
    before: Data("zero".utf8),
    after: Data("one".utf8)
  )
  history.recordAction(
    pageID: firstPage,
    before: Data("one".utf8),
    after: Data("two".utf8)
  )
  history.recordAction(
    pageID: firstPage,
    before: Data("two".utf8),
    after: Data("three".utf8)
  )
  history.recordAction(
    pageID: secondPage,
    before: Data("other zero".utf8),
    after: Data("other one".utf8)
  )

  #expect(history.removeLastChange(for: secondPage) == Data("other zero".utf8))
  #expect(history.removeLastChange(for: firstPage) == Data("two".utf8))
  #expect(history.removeLastChange(for: firstPage) == Data("one".utf8))
  #expect(history.removeLastChange(for: firstPage) == nil)
}

@Test("Новый внешний рисунок завершает локальную историю отмены")
func pencilUndoCanDiscardAStalePageHistory() {
  let pageID = UUID()
  var history = PencilUndoHistory()
  history.recordAction(
    pageID: pageID,
    before: Data("before".utf8),
    after: Data("after".utf8)
  )

  history.discardChanges(for: pageID)

  #expect(history.removeLastChange(for: pageID) == nil)
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

@Test("Запоздавшая запись посадки не возвращает каталог на старый лист")
func stalePageSelectionPersistenceCannotRewindTheWorkspace() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let actor = UUID()
  let size = PageSize(width: 834, height: 1_194)
  let initial = WorkspaceIndex.initial(actor: actor, pageSize: size)
  let store = NotebookStore(root: root)
  let board = BoardDocument.initial(
    itemIDs: [initial.index.selectedItemID],
    actor: actor
  )
  try store.saveWorkspaceBundle(
    index: initial.index,
    page: initial.page,
    board: board
  )

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
  #expect(persisted.selectedPageID == thirdPage.pageID)
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
  let added = board.addItem(created.item.id, near: .zero, actor: actor)
  #expect(added)
  try store.saveWorkspaceBundle(
    index: index,
    page: created.page,
    board: board
  )
  let pageURL = store.pageURL(created.page.id)
  #expect(FileManager.default.fileExists(atPath: pageURL.path))

  let removed = index.deleteItem(created.item.id, actor: actor)
  _ = try #require(removed)
  let removedFromBoard = board.deleteItem(created.item.id, actor: actor)
  #expect(removedFromBoard)
  try store.deleteWorkspaceBundle(
    index: index,
    board: board,
    pageIDs: created.item.pageIDs
  )

  #expect(try store.loadIndex() == index)
  #expect(try store.loadBoard(itemIDs: Set(index.items.map(\.id))) == board)
  #expect(!FileManager.default.fileExists(atPath: pageURL.path))

  #expect(throws: CocoaError.self) {
    try store.saveMergedPage(created.page)
  }
  #expect(!FileManager.default.fileExists(atPath: pageURL.path))
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

  pencil.replaceDrawing(Data("ink".utf8), actor: firstActor)
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
  #expect(pencil.drawingData == Data("ink".utf8))
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
  landscape.replaceDrawing(Data("landscape".utf8), actor: actor)

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
    Data("last".utf8),
    stamp: VersionStamp(
      counter: VersionStamp.maximumCounter,
      actor: actor
    )
  )
  let overflowed = page.replaceDrawing(Data("overflow".utf8), actor: actor)
  #expect(reachedLimit)
  #expect(!overflowed)
  #expect(page.drawingData == Data("last".utf8))

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
  page.replaceDrawing(Data([1, 2, 3]), actor: actor)
  try store.savePage(page)

  let reopened = try store.loadOrCreate(actor: UUID(), pageSize: page.size)
  #expect(reopened.0 == created.0)
  #expect(reopened.1[page.id] == page)
}

@Test("Notebook один раз переносит прежнее локальное хранилище")
func storeMigratesLegacyDirectory() throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let legacyRoot = parent.appendingPathComponent("Tetrad", isDirectory: true)
  let currentRoot = parent.appendingPathComponent("Notebook", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: parent) }

  try FileManager.default.createDirectory(
    at: legacyRoot,
    withIntermediateDirectories: true
  )
  let marker = legacyRoot.appendingPathComponent("workspace.json")
  try Data("saved pages".utf8).write(to: marker)

  try NotebookStore.migrateLegacyStore(from: legacyRoot, to: currentRoot)

  #expect(!FileManager.default.fileExists(atPath: legacyRoot.path))
  #expect(
    try Data(contentsOf: currentRoot.appendingPathComponent("workspace.json"))
      == Data("saved pages".utf8)
  )
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
  pencil.replaceDrawing(Data("new ink".utf8), actor: pencilActor)
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

  #expect(resolved.drawingData == Data("new ink".utf8))
  #expect(resolved.elements.map(\.id) == ["new-agent-layer"])
  #expect(try store.loadPage(resolved.id) == resolved)
  #expect(
    !FileManager.default.fileExists(
      atPath: root.appendingPathComponent(".mutation-lock").path
    )
  )
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
    JSONSerialization.jsonObject(with: Data(contentsOf: pageURL))
      as? [String: Any]
  )
  var size = try #require(json["size"] as? [String: Any])
  size["width"] = 0
  json["size"] = size
  try JSONSerialization.data(withJSONObject: json).write(to: pageURL)

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
    JSONSerialization.jsonObject(with: Data(contentsOf: pageURL))
      as? [String: Any]
  )
  var size = try #require(json["size"] as? [String: Any])
  size["width"] = 1e100
  json["size"] = size
  try JSONSerialization.data(withJSONObject: json).write(to: pageURL)

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
    JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL))
      as? [String: Any]
  )
  json["items"] = []
  try JSONSerialization.data(withJSONObject: json).write(to: store.indexURL)

  #expect(throws: CocoaError.self) {
    try store.loadIndex()
  }
}
