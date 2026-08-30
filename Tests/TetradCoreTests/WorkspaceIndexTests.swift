import Foundation
import Testing
@testable import TetradCore

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

  let created = index.turnPage(
    by: 1,
    actor: actor,
    pageSize: initial.page.size
  )
  #expect(created != nil)
  #expect(index.selectedNotebook.pageIDs.count == 2)
  #expect(index.selectedPageID == created?.id)

  _ = index.turnPage(by: -1, actor: actor, pageSize: initial.page.size)
  let reopened = index.turnPage(by: 1, actor: actor, pageSize: initial.page.size)
  #expect(reopened == nil)
  #expect(index.selectedNotebook.pageIDs.count == 2)
}

@Test("Вертикальный переход создаёт новую тетрадь только за краем")
func notebookChangeCreatesAtEdge() {
  let actor = UUID()
  let size = PageSize(width: 834, height: 1_194)
  var index = WorkspaceIndex.initial(actor: actor, pageSize: size).index

  let page = index.changeNotebook(by: 1, actor: actor, pageSize: size)
  #expect(page != nil)
  #expect(index.notebooks.count == 2)
  #expect(index.selectedNotebook.title == "Тетрадь 2")

  _ = index.changeNotebook(by: -1, actor: actor, pageSize: size)
  let existing = index.changeNotebook(by: 1, actor: actor, pageSize: size)
  #expect(existing == nil)
  #expect(index.notebooks.count == 2)
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
  let notebookID = UUID()
  var index = WorkspaceIndex(
    notebooks: [Notebook(id: notebookID, title: "Тетрадь 1", pageIDs: [pageID])],
    selectedNotebookID: notebookID,
    selectedPageID: pageID,
    stamp: VersionStamp(
      counter: VersionStamp.maximumCounter,
      actor: actor
    )
  )
  let before = index
  #expect(index.turnPage(by: 1, actor: actor, pageSize: size) == nil)
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

  let store = TetradStore(root: root)
  let actor = UUID()
  let created = try store.loadOrCreate(
    actor: actor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var page = try #require(created.1[created.0.selectedPageID])
  page.replaceDrawing(Data([1, 2, 3]), actor: actor)
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

  let store = TetradStore(root: root)
  let pencilActor = UUID()
  let agentActor = UUID()
  let created = try store.loadOrCreate(
    actor: pencilActor,
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var pencil = try #require(created.1[created.0.selectedPageID])
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

  let store = TetradStore(root: root)
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

  let store = TetradStore(root: root)
  let created = try store.loadOrCreate(
    actor: UUID(),
    pageSize: PageSize(width: 834, height: 1_194)
  )
  let pageID = created.0.selectedPageID
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

  let store = TetradStore(root: root)
  let created = try store.loadOrCreate(
    actor: UUID(),
    pageSize: PageSize(width: 834, height: 1_194)
  )
  let pageURL = store.pageURL(created.0.selectedPageID)
  var json = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: pageURL))
      as? [String: Any]
  )
  var size = try #require(json["size"] as? [String: Any])
  size["width"] = 1e100
  json["size"] = size
  try JSONSerialization.data(withJSONObject: json).write(to: pageURL)

  #expect(throws: CocoaError.self) {
    try store.loadPage(created.0.selectedPageID)
  }
}

@Test("Хранилище отвергает тетрадь без выбранного живого листа")
func storeRejectsInvalidDecodedWorkspace() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = TetradStore(root: root)
  _ = try store.loadOrCreate(
    actor: UUID(),
    pageSize: PageSize(width: 834, height: 1_194)
  )
  var json = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL))
      as? [String: Any]
  )
  json["notebooks"] = []
  try JSONSerialization.data(withJSONObject: json).write(to: store.indexURL)

  #expect(throws: CocoaError.self) {
    try store.loadIndex()
  }
}
