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
    var drawing = try PageInkDrawing().appending(first)
    let firstChanged = page.replaceDrawing(try drawing.dataRepresentation(), actor: actor)
    #expect(firstChanged)
    _ = try store.savePage(page)
    let firstCursor = try store.currentChangeCursor()
    let firstAddress = pageFile(pageID) + "#/drawingData/actions/@" + first.id.uuidString.lowercased() + "/samples"
    let firstHash = try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(firstAddress)]).first?[0].text }
    #expect(firstHash != nil)
    drawing = try drawing.appending(second)
    let secondChanged = page.replaceDrawing(try drawing.dataRepresentation(), actor: actor)
    #expect(secondChanged)
    _ = try store.savePage(page)
    let secondCursor = try store.currentChangeCursor()
    let appended = try store.readChangedAddresses(after: firstCursor, through: secondCursor)
    #expect(!appended.addresses.contains(firstAddress))
    #expect(appended.addresses.filter { $0.hasSuffix("/samples") }.count == 1)
    #expect(try PageInkDrawing.decode(store.loadPage(pageID).drawingData) == drawing)
    let removed = try drawing.settingActive(false,for:[first.id],stamp:.init(counter:3,actor:actor))
    let undoChanged = page.replaceDrawing(try removed.dataRepresentation(), actor: actor)
    #expect(undoChanged)
    _ = try store.savePage(page)
    let undo = try store.readChangedAddresses(after: secondCursor, through: store.currentChangeCursor())
    #expect(!undo.addresses.contains { $0.hasSuffix("/samples") })
    #expect(undo.addresses.count <= 3)
    #expect(try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(firstAddress)]).first?[0].text } == firstHash)
    let reopened = try PageInkDrawing.decode(NotebookStore(root: root).loadPage(pageID).drawingData)
    #expect(reopened.actions.count == 2 && reopened.activeActions.map(\.id) == [second.id])
  }

  @Test func legacyEraserHeaderRefusesNativeUndoBeforeChangingInkHistoryOrCursors() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let pageID = try #require(store.loadIndex().selectedPageID), page = try store.loadPage(pageID)
    // The current format permits this old action. Native live input now seals
    // earlier because targets stay JSON in the immutable action header.
    let targets = (0..<7_000).map { index in
      InkElementTarget(elementID: "legacy-\(index)", frame: .init(x: 0, y: 0, width: 100, height: 100),
        graphicTransform: .identity, elementTransform: .identity)
    }
    let action = PageInkAction(tool: .eraser, samples: [
      .init(point: .init(x: 10, y: 10), timeOffset: 0, width: 20,
        opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ], sequence: 1, elementTargets: targets)
    let appendStamp = try #require(page.drawingStamp.advanced(by: actor))
    let appended = try store.commitPageInk(pageID: pageID,
      command: .append(action, baseStamp: page.drawingStamp, stamp: appendStamp))
    let headerAddress = pageFile(pageID) + "#/drawingData/actions/@" + action.id.uuidString.lowercased()
    let wire = try store.sqlRead { db in
      let hash = try #require(try db.rows("SELECT hash FROM records WHERE address=?",
        [.text(headerAddress)]).first?[0].text)
      return try db.blob(hash)
    }
    #expect(wire.count < 4 * 1_024 * 1_024)
    let allocation = try NotebookJSONAdmission.allocationCost(wire,
      maximumBytes: 256 * 1_024 * 1_024)
    #expect(allocation > NotebookNativeWriteAllowance.maximumExecutionBytes / 5 * 4,
      "The actual stored header exceeds the native finish allocation share before decoding")
    #expect(try store.readPageInkAction(pageID: pageID, actionID: action.id)?.action == action,
      "A native memory refusal preserves readability of the existing source format")
    let history = try store.nativeHistory(domain: .page(pageID), actor: actor)
    #expect(history == [.ink([action.id])])
    let source = try recordHashes(store), changes = try store.currentChangeCursor(), read = try store.currentReadCursor()
    let undoStamp = try #require(appended.stamp.advanced(by: actor))
    do {
      try store.withNativeWriteAllowance {
        _ = try store.commitPageInk(pageID: pageID, command: .state([action.id: action.visibility],
          isActive: false, baseStamp: appended.stamp, stamp: undoStamp))
      }
      Issue.record("An old valid eraser header cannot enlarge an accepted Undo's finish reserve")
    } catch let error as CollaborationError { #expect(error.code == "resource_limit") }
    #expect(try recordHashes(store) == source)
    #expect(try store.nativeHistory(domain: .page(pageID), actor: actor) == history)
    #expect(try store.nativeRedoHistory(domain: .page(pageID), actor: actor).isEmpty)
    #expect(try store.currentChangeCursor() == changes)
    #expect(try store.currentReadCursor() == read)
  }

  private func recordHashes(_ store: NotebookStore) throws -> [String: String] {
    try store.sqlRead { db in
      Dictionary(uniqueKeysWithValues: try db.rows("SELECT address,hash FROM records").map {
        (try #require($0[0].text), try #require($0[1].text))
      })
    }
  }
}
