import Foundation
import Testing
@testable import TetradCore

@Test("Клетка равна одному сантиметру на полноразмерном iPad")
func centimeterGrid() {
  #expect(abs(PhysicalPaper.pointsPerCentimeter - 51.968_503_937) < 0.000_001)
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
