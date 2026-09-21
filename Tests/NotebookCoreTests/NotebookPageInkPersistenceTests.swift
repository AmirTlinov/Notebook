import Foundation
import Testing
@testable import NotebookCore

@Suite(.serialized)
struct NotebookPageInkPersistenceTests {
  private func stroke(id: UUID = UUID(), x: Double = 10) -> PageInkAction {
    .init(id: id, tool: .pen, samples: [.init(point: .init(x: x, y: 10),
      timeOffset: 0, width: 4, opacity: 1, force: 0.5, azimuth: 0, altitude: 1)])
  }

  @Test func addressedContactAndUndoDoNotReadOrRewriteRetainedHistory() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store=NotebookStore(root:root),actor=UUID()
    _=try store.initializeWorkspace(actor:actor,pageSize:.init(width:834,height:1194))
    let pageID=try #require(store.loadIndex().selectedPageID)
    let history=(0..<2_048).map { stroke(x:Double($0%800)) }
    let archive=PageInkDrawing(actions:history)
    var page=try store.loadPage(pageID)
    #expect(page.replaceDrawing(try archive.dataRepresentation(),actor:actor))
    _=try store.savePage(page)
    let appended=try page.prepareInkChange(.append(stroke(x:801)),stamp:.init(counter:2,actor:actor))
    let action=try #require(appended.drawing.action(id:appended.mutation.actionID!))
    let sampleAddress=pageFile(pageID)+"#/drawingData/actions/@"+history[0].id.uuidString.lowercased()+"/samples"
    let retainedHash=try store.sqlRead { try #require($0.rows("SELECT hash FROM records WHERE address=?",[.text(sampleAddress)]).first?.first?.text) }
    let accepted=try store.commitPageInk(pageID:pageID,command:.append(action,baseStamp:appended.baseStamp,stamp:appended.stamp))
    #expect(accepted.stamp == appended.stamp)
    let undoStamp=try #require(accepted.stamp.advanced(by:actor))
    _=try store.commitPageInk(pageID:pageID,command:.deactivate([action.id],baseStamp:accepted.stamp,stamp:undoStamp))
    let afterHash=try store.sqlRead { try #require($0.rows("SELECT hash FROM records WHERE address=?",[.text(sampleAddress)]).first?.first?.text) }
    #expect(afterHash == retainedHash)
    page=try store.loadPage(pageID)
    let reopened=try page.inkDrawing()
    #expect(reopened.action(id:history[0].id)?.isActive == true)
    #expect(reopened.action(id:action.id)?.isActive == false)
  }

  @Test func drawingPublicationAndRepeatedHistoryDoNotReadUnrelatedHundredThousandNodeBody() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let pageID = try #require(store.loadIndex().selectedPageID), target = CollaborationTarget(kind: .page, id: pageID)
    let frame = PageRect(x: 0, y: 0, width: 600, height: 128)
    let samples: [SpatialInkSample] = (0..<100_000).map { i in
      let point = SpatialPoint(x: Double(i) / 200, y: 64 + sin(Double(i) * 0.31) * 20)
      let force = Double((i * 17) % 997) / 1024
      return SpatialInkSample(point: point, timeOffset: Double(i) / 128, width: 4,
        opacity: 0.75, force: force, azimuth: 0, altitude: 1)
    }
    let source = InkSampleRelations(sourceID: UUID(), revision: UUID(), samples: samples, header: .init(tool: .pen, color: .black))
    let graphic = NotebookGraphic(shape: .freehand, freehand: .init(layers: [
      .init(tool: .pen, color: .black, measured: .init(sourceID: source.sourceID, measurements: source.measurements, frame: frame))]))
    var page = try store.loadPage(pageID)
    let changed = page.replaceElements([.init(id: "large", kind: .graphic, frame: frame, source: "", html: "", graphic: graphic)], actor: actor)
    #expect(changed)
    _ = try store.savePage(page)
    let oldRows = try store.sqlRead { try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(pageFile(pageID))]).map { [$0[0].text!, $0[1].text!] } }
    let change = try page.prepareInkChange(.append(stroke()), stamp: .init(counter: 1, actor: actor))
    let start = ContinuousClock.now
    let saved = try store.commandTransaction(readAllowance: .init(rows: 512, bytes: 262_144, valueBytes: 65_536, reason: "ink_must_not_read_graphics")) {
      try store.commitPageInk(pageID:pageID,command:.init(change))
    }
    print("page-ink-beside-100k-source \(start.duration(to: .now))")
    #expect(saved.stamp == change.stamp)
    let afterRows = try store.sqlRead { try $0.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(pageFile(pageID))]).map { [$0[0].text!, $0[1].text!] } }
    let inkRoot = pageFile(pageID) + "#/drawingData", pageRoot = pageFile(pageID) + "#"
    #expect(oldRows.filter { $0[0] != pageRoot && !$0[0].hasPrefix(inkRoot) }
      == afterRows.filter { $0[0] != pageRoot && !$0[0].hasPrefix(inkRoot) })

    let actions = try (0..<16).map { index in
      let action = CollaborationAction(summary: "Move \(index)", expected: [],
        operations: [.init(kind: .updateElement, target: target, id: "large")])
      let receipt = CollaborationReceipt(id: action.id, action: action,
        createdAt: Date(timeIntervalSince1970: Double(index)), revisions: [], changes: [])
      try store.publishCollaboration(writes: ["collaboration/actions/\(action.id.uuidString.lowercased()).json": .encode(receipt)])
      return try NotebookActionReadModel(receipt)
    }
    let snapshot = try store.readTransaction { _ in
      try store.currentSQL!.limitReads(.init(rows: 2_048, bytes: 16 * 1_024 * 1_024,
        valueBytes: 8 * 1_024 * 1_024, reason: "history_must_share_geometry"))
      return try CollaborationReadSnapshot(store: store, actions: actions, references: [])
    }
    let results = actions.flatMap { snapshot.results[$0.id] ?? [] }
    #expect(results.count == 16 && Set(results.map(\.id)).count == 16)
    #expect(results.allSatisfy { $0.elementID == "large" && $0.region == frame })
    #expect(try store.loadPage(pageID).elements == page.elements)
  }

  @Test func staleDrawingMergesUndoIsIrreversibleAndConflictsRollBack() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let pageID = try #require(store.loadIndex().selectedPageID), one = stroke(), two = stroke(x: 20)
    let base=try store.loadPage(pageID),a=try base.prepareInkChange(.append(one),stamp:.init(counter:1,actor:actor))
    _=try store.commitPageInk(pageID:pageID,command:.init(a))
    let b=try base.prepareInkChange(.append(two),stamp:.init(counter:1,actor:UUID()))
    let joined=try store.commitPageInk(pageID:pageID,command:.init(b))
    let drawing = try store.loadPage(pageID).inkDrawing()
    #expect(Set(drawing.actions.map(\.id)) == [one.id, two.id])
    let undoStamp = try #require(joined.stamp.advanced(by: actor))
    _=try store.commitPageInk(pageID:pageID,command:.deactivate([one.id],baseStamp:joined.stamp,stamp:undoStamp))
    _=try store.commitPageInk(pageID:pageID,command:.init(a))
    #expect(try store.loadPage(pageID).inkDrawing().action(id:one.id)?.isActive == false)
    let cursor = try store.currentChangeCursor()
    let conflict = PageInkDrawing(actions: [stroke(id: one.id, x: 100)]).actions[0]
    #expect(throws: NotebookStorageError.self) {
      _=try store.commitPageInk(pageID:pageID,command:.append(conflict,baseStamp:joined.stamp,stamp:.init(counter:100,actor:actor)))
    }
    #expect(try store.currentChangeCursor() == cursor)
    #expect(try store.loadPage(pageID).inkDrawing().action(id:one.id)?.isActive == false)
  }
}

private extension PageInkMutation {
  var actionID:UUID? { if case .append(let action)=self { action.id } else { nil } }
}
