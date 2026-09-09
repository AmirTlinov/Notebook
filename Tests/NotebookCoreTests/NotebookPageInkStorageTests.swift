import Foundation
import Testing
@testable import NotebookCore

@Suite("SQL pen samples have immutable addressed owners")
struct NotebookPageInkStorageTests {
  @Test func appendAndUndoDoNotRepublishHistoricalSamples() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let pageID = try #require(store.loadIndex().selectedPageID)
    var page = try store.loadPage(pageID)
    func action(_ x: Double) -> PageInkAction {
      .init(tool: .pen, samples: (0..<512).map { offset in
        .init(point: .init(x: x + Double(offset), y: 12), timeOffset: Double(offset) / 120,
          width: 2, opacity: 1, force: 0.5, azimuth: 0, altitude: 1)
      })
    }
    let first = action(10), second = action(20)
    var drawing = PageInkDrawing().appending(first)
    let firstChanged = page.replaceDrawing(try drawing.dataRepresentation(), actor: actor)
    #expect(firstChanged)
    _ = try store.saveMergedPage(page)
    let firstCursor = try store.currentChangeCursor()
    let firstAddress = pageFile(pageID) + "#/drawingData/actions/@" + first.id.uuidString.lowercased() + "/samples"
    let firstHash = try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(firstAddress)]).first?[0].text }
    #expect(firstHash != nil)
    drawing = drawing.appending(second)
    let secondChanged = page.replaceDrawing(try drawing.dataRepresentation(), actor: actor)
    #expect(secondChanged)
    _ = try store.saveMergedPage(page)
    let secondCursor = try store.currentChangeCursor()
    let appended = try store.readChangedAddresses(after: firstCursor, through: secondCursor)
    #expect(!appended.addresses.contains(firstAddress))
    #expect(appended.addresses.filter { $0.hasSuffix("/samples") }.count == 1)
    #expect(try PageInkDrawing.decode(store.loadPage(pageID).drawingData) == drawing)
    let removed = drawing.removing([first.id])
    let undoChanged = page.replaceDrawing(try removed.dataRepresentation(), actor: actor)
    #expect(undoChanged)
    _ = try store.saveMergedPage(page)
    let undo = try store.readChangedAddresses(after: secondCursor, through: store.currentChangeCursor())
    #expect(!undo.addresses.contains { $0.hasSuffix("/samples") })
    #expect(undo.addresses.count <= 3)
    #expect(try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(firstAddress)]).first?[0].text } == firstHash)
    let reopened = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(pageID).drawingData)
    #expect(reopened.actions.count == 2 && reopened.activeActions.map(\.id) == [second.id])
  }
}
