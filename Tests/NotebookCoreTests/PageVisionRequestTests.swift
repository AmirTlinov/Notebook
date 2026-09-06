import Foundation
import Testing
@testable import NotebookCore

private struct PageVisionRequestFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var store: NotebookStore { .init(root: root) }
  let actor = UUID()

  func page() throws -> PageDocument {
    try store.prepare()
    let page = PageDocument(size: .init(width: 100, height: 100), actor: actor)
    try store.savePage(page)
    return page
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test("Карта читает только явно названный лист и повторяет тот же запрос после перезапуска")
func pageVisionRequestHasAnAddressedSource() throws {
  let fixture = PageVisionRequestFixture(); defer { fixture.remove() }
  let page = try fixture.page(), store = fixture.store
  for url in [store.indexURL, store.boardURL, store.spatialInkURL, store.pageURL(UUID())] {
    try Data("unrelated damaged source".utf8).write(to: url)
  }
  let first = try store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision)
  let reopened = NotebookStore(root: fixture.root)
  #expect(try reopened.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision) == first)
  #expect(first.target == .init(kind: .page, id: page.id))
  #expect(first.pageVisionRevision == page.drawingStamp.revision)
  #expect(first.sourceRevision == (try NotebookStore.pageVisionSourceRevision(page)))
  #expect(first.region == nil && first.worldOrigin == nil)
  #expect(try reopened.targetRenderRequests() == [first])
}

@Test("Правка схемы не готовит чернила заново, а новые чернила заменяют только незавершённую карту")
func pageVisionRequestsCoalesceOnlyTheInkOwner() throws {
  let fixture = PageVisionRequestFixture(); defer { fixture.remove() }
  var page = try fixture.page()
  let store = fixture.store
  let first = try store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision)
  let edited = page.replaceElements([AgentElement(id: "caption", kind: .markdown,
    frame: .init(x: 10, y: 10, width: 80, height: 40), source: "Human continuation",
    html: "<p>Human continuation</p>")], actor: fixture.actor)
  #expect(edited)
  try store.savePage(page)
  #expect(try store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision) == first)
  for counter in 1...20 {
    let action = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 20, y: Double(counter)),
      timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)])
    let drawn = page.replaceDrawing(try PageInkDrawing(actions: [action]).dataRepresentation(), actor: fixture.actor)
    #expect(drawn)
    try store.savePage(page)
    let request = try store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision)
    #expect(request.id != first.id)
    #expect(try store.targetRenderRequests() == [request])
  }
  // A request already captured by an executor keeps its original source.
  #expect(first.pageVisionRevision != page.drawingStamp.revision)
  #expect(first.sourceRevision != (try NotebookStore.pageVisionSourceRevision(page)))
}

@Test("Устаревший или отсутствующий лист не создаёт ожидающий запрос карты")
func pageVisionRequestRejectsStaleAndMissingOwners() throws {
  let fixture = PageVisionRequestFixture(); defer { fixture.remove() }
  let page = try fixture.page(), store = fixture.store
  #expect(throws: (any Error).self) {
    do { _ = try store.requestPageVision(pageID: page.id, expectedRevision: "99@\(fixture.actor)") }
    catch let error as CollaborationError { #expect(error.code == "revision_conflict"); throw error }
  }
  #expect(throws: (any Error).self) {
    do { _ = try store.requestPageVision(pageID: UUID(), expectedRevision: page.drawingStamp.revision) }
    catch let error as CollaborationError { #expect(error.code == "target_missing"); throw error }
  }
  #expect(try store.targetRenderRequests().isEmpty)
}

@Test("Удалённый снимок можно восстановить, ошибка исполнения остаётся явной")
func pageVisionRequestReopensOnlyACompletedDerivative() throws {
  let fixture = PageVisionRequestFixture(); defer { fixture.remove() }
  let page = try fixture.page(), store = fixture.store
  let request = try store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision)
  try store.saveTargetRender(.init(request: request, status: "ready", pngSHA256: String(repeating: "a", count: 64)))
  #expect(!store.hasCurrentPageVision(page))
  #expect(try store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision) == request)
  #expect(!FileManager.default.fileExists(atPath: store.targetReceiptURL(request.id).path))
  let failure = TargetRenderReceipt(request: request, status: "error", diagnostics: [
    .init(kind: "render_error", message: "Unavailable renderer")])
  try store.saveTargetRender(failure)
  #expect(try store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision) == request)
  #expect(try JSONDecoder().decode(TargetRenderReceipt.self,
    from: Data(contentsOf: store.targetReceiptURL(request.id))) == failure)
}

@Test("Карта использует ограниченную очередь целевых снимков")
func pageVisionRequestsKeepOneSharedQueueLimit() throws {
  let fixture = PageVisionRequestFixture(); defer { fixture.remove() }
  for _ in 0..<16 {
    let page = try fixture.page()
    _ = try fixture.store.requestPageVision(pageID: page.id, expectedRevision: page.drawingStamp.revision)
  }
  let extra = try fixture.page()
  #expect(throws: (any Error).self) {
    do { _ = try fixture.store.requestPageVision(pageID: extra.id, expectedRevision: extra.drawingStamp.revision) }
    catch let error as CollaborationError { #expect(error.code == "snapshot_pending"); throw error }
  }
  #expect(try fixture.store.targetRenderRequests().count == 16)
}
