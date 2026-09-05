import Foundation
import Testing

@testable import NotebookCore

@Test func pageInkRoundTripKeepsExactSamplesAndOperationOrder() throws {
  let point = SpatialInkSample(
    point: .init(x: 10, y: 20), timeOffset: 0.2, width: 2.2, opacity: 0.344, force: 0.2,
    azimuth: 0.3, altitude: 1)
  let pen = PageInkAction(tool: .pen, samples: [point])
  let eraser = PageInkAction(tool: .eraser, samples: [point])
  let drawing = PageInkDrawing().appending(pen).appending(eraser)
  #expect(try PageInkDrawing.decode(drawing.dataRepresentation()) == drawing)
  #expect(drawing.actions.map(\.tool) == [.pen, .eraser])
  #expect(drawing.appending(pen) == drawing)
  #expect(!PageInkDrawing.needsMigration(try drawing.dataRepresentation()))
}

@Test func pageInkMigrationHasAnExplicitBoundary() throws {
  #expect(try PageInkDrawing.decode(Data()).isEmpty)
  #expect(PageInkDrawing.needsMigration(Data([1, 2, 3])))
  #expect(throws: PageInkDrawing.InkError.self) { try PageInkDrawing.decode(Data([1, 2, 3])) }
}

@Test func pageInkMigrationBacksUpTheOriginalAndKeepsItsRevision() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = NotebookStore(root: root)
  try store.prepare()
  let actor = UUID()
  var page = PageDocument(size: .init(width: 400, height: 400), actor: actor)
  page.replaceDrawing(Data([1, 2, 3]), actor: actor)
  try store.savePage(page)
  let original = try Data(contentsOf: store.pageURL(page.id))
  let point = SpatialInkSample(
    point: .init(x: 10, y: 20), timeOffset: 0, width: 2.2, opacity: 1, force: 1, azimuth: 0,
    altitude: 1)
  let data = try PageInkDrawing(actions: [PageInkAction(tool: .pen, samples: [point])])
    .dataRepresentation()
  let migrated = try store.migratePageInk(page: page, data: data)
  #expect(migrated.drawingStamp == page.drawingStamp)
  #expect(migrated.drawingData == data)
  let backup = root.appendingPathComponent(
    "migrations/before-ink-v1/pages/\(page.id.uuidString.lowercased()).json")
  #expect(try Data(contentsOf: backup) == original)
  #expect(try store.migratePageInk(page: page, data: data) == migrated)
  var edited = migrated
  edited.replaceDrawing(Data(), actor: actor)
  try store.savePage(edited)
  #expect(try store.migratePageInk(page: page, data: data) == edited)
  #expect(try Data(contentsOf: backup) == original)
}
