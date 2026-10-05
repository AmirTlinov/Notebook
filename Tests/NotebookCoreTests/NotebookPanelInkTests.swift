import Foundation
import Testing
@testable import NotebookCore

@Suite("Panel pen contacts use native causal actions")
struct NotebookPanelInkTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-panel-ink-\(UUID())")
    let actor = UUID(), peer = UUID()
    let store: NotebookStore
    let workspaceID: UUID
    let page: CollaborationTarget, board: CollaborationTarget
    init() throws {
      store = .init(root: root)
      let (workspace, _) = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194))
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      workspaceID = try store.storedWorkspaceID()
      page = .init(kind: .page, id: workspace.selectedPageID!); board = .init(kind: .board, id: workspace.rootBoardID)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func stroke(_ target: CollaborationTarget, id: UUID = UUID()) throws -> CollaborationOperation {
      var values: [String: JSONValue] = ["width": .number(4), "opacity": .number(0.7),
        "points": .array([.object(["x": .number(100), "y": .number(120), "timeOffset": .number(0), "force": .number(0.23)]),
          .object(["x": .number(160), "y": .number(190), "width": .number(3), "opacity": .number(0.4),
            "timeOffset": .number(0.01823456789), "force": .number(0.8123), "azimuth": .number(1.125), "altitude": .number(0.7125)])])]
      if target.kind == .board { values["worldOrigin"] = try .encode(WorldPoint(tileX: 100_000, tileY: -10, localX: 20, localY: 30)) }
      return .init(kind: .appendInkStroke, target: target, id: id.uuidString, values: values)
    }
    func request(_ operation: CollaborationOperation, actionID: UUID = UUID(), sources: [NotebookPanelEditSource] = []) -> NotebookPanelEditRequest {
      .init(workspaceID: workspaceID, actionID: actionID, target: operation.target,
        summary: "Штрих пользователя", operations: [operation], sources: sources)
    }
    func active(_ store: NotebookStore, target: CollaborationTarget) throws -> Set<UUID> {
      if target.kind == .page { return Set(try store.loadPage(target.id).inkDrawing().activeActions.map(\.id)) }
      return Set(try store.readSpatialInk(surfaces: [.board(target.id)]).actions.filter(\.isActive).map(\.id))
    }
    func agent(_ operation: CollaborationOperation) throws {
      let basis = try store.readBasis(targets: [operation.target])
      _ = try store.applyCollaborationAction(.init(summary: "Штрих агента", expected: basis.owners, operations: [operation]), actor: peer)
    }
  }

  @Test(arguments: [false, true])
  func contactCommutesWithPeersAndItsUndoSurvivesReopen(onBoard: Bool) throws {
    let f = try Fixture(); defer { f.clean() }
    let target = onBoard ? f.board : f.page
    let before = try f.stroke(target), human = try f.stroke(target), after = try f.stroke(target)
    let request = f.request(human)
    try f.agent(before)
    try f.store.saveInputActivity(.init(deviceID: f.peer, sessionID: UUID(), sequence: 1, targets: [target]))
    let accepted = try f.store.editPanel(request, actor: f.actor)
    let action = try f.store.collaborationAction(request.actionID)
    #expect(action.author == .human && action.requestFingerprint != nil && action.changes.isEmpty)
    #expect(action.action.expected.isEmpty)
    #expect(try f.store.nativeHistory(domain: .init(target), actor: f.actor).last == .command(request.actionID))
    let measured = try CollaborationInkStroke(human)
    let samples: InkMeasurements
    if onBoard {
      samples = try #require(try f.store.readSpatialInk(surfaces: [.board(target.id)]).actions.first { $0.id == measured.id }).spans[0].samples
    } else {
      let saved = try #require(try f.store.readPageInkAction(pageID: target.id, actionID: measured.id)).action
      #expect(saved.sequence == 2)
      samples = saved.samples
    }
    #expect(samples.elementsEqual(measured.samples, by: InkSampleRelations.sameBits))
    #expect(samples[1].timeOffset == 0.01823456789 && samples[1].force == 0.8123)
    _ = try f.store.applyNativeAction(.init(summary: "Независимое касание", expected: [], operations: [after]), actor: f.peer)
    let cold = NotebookStore(root: f.root)
    #expect(try cold.editPanel(request, actor: f.actor) == accepted)
    let all = Set([before, human, after].map { UUID(uuidString: $0.id!)! })
    #expect(try f.active(cold, target: target) == all)
    let altered = f.request(try f.stroke(target), actionID: request.actionID)
    #expect(throws: CollaborationError.self) { try cold.editPanel(altered, actor: f.actor) }
    #expect(throws: CollaborationError.self) { try cold.editPanel(request, actor: f.peer) }
    let undo = NotebookPanelUndoRequest(workspaceID: f.workspaceID, target: target, actionID: request.actionID)
    let undone = try cold.undoPanel(undo, actor: f.actor)
    #expect(try cold.undoPanel(undo, actor: f.actor) == undone)
    #expect(try cold.editPanel(request, actor: f.actor) == accepted)
    #expect(try f.active(NotebookStore(root: f.root), target: target) == all.subtracting([measured.id]))
    #expect(try cold.nativeHistory(domain: .init(target), actor: f.actor).isEmpty)
  }

  @Test func malformedContactCannotPublishAReceiptOrChangeInk() throws {
    let f = try Fixture(); defer { f.clean() }
    let valid = try f.stroke(f.page)
    let bad = CollaborationOperation(kind: .appendInkStroke, target: f.page, id: UUID().uuidString,
      values: valid.values.merging(["points": .array([.object(["x": .number(100), "y": .number(120), "force": .number(-1)])])]) { _, new in new })
    for request in [f.request(bad), f.request(valid, sources: [.init(id: "unrelated")]),
      .init(workspaceID: f.workspaceID, actionID: UUID(), target: f.board, summary: "Неверная поверхность", operations: [valid], sources: [])] {
      let cursor = try f.store.currentChangeCursor()
      #expect(throws: CollaborationError.self) { try f.store.editPanel(request, actor: f.actor) }
      #expect(try f.store.currentChangeCursor() == cursor)
      #expect(try f.store.collaborationActionIfPresent(request.actionID) == nil)
    }
    #expect(try f.active(f.store, target: f.page).isEmpty)
    #expect(try f.store.nativeHistory(domain: .init(f.page), actor: f.actor).isEmpty)
    do {
      _ = try f.store.applyCollaborationAction(.init(summary: "Нет основания", expected: [], operations: [valid]), actor: f.actor)
      Issue.record("Agent admission must retain its read basis even with the human actor ID")
    } catch let error as CollaborationError { #expect(error.code == "revision_required") }
  }

  @Test func humanContactRetainsNativeWidthAndPageEdgeMeasurements() throws {
    let f = try Fixture(); defer { f.clean() }
    let operation = CollaborationOperation(kind: .appendInkStroke, target: f.page, id: UUID().uuidString,
      values: ["width": .number(176), "points": .array([
        .object(["x": .number(-2), "y": .number(300)]), .object(["x": .number(840), "y": .number(300)])])])
    let request = f.request(operation)
    _ = try f.store.editPanel(request, actor: f.actor)
    let samples = try #require(try f.store.readPageInkAction(pageID: f.page.id, actionID: UUID(uuidString: operation.id!)!)).action.samples
    #expect(samples[0].width == 176 && samples[0].point.x == -2 && samples[1].point.x == 840)
    #expect(throws: CollaborationError.self) { try f.agent(operation) }
    let overflow = CollaborationOperation(kind: .appendInkStroke, target: f.page, id: UUID().uuidString,
      values: ["width": .number(.greatestFiniteMagnitude), "points": .array([
        .object(["x": .number(.greatestFiniteMagnitude), "y": .number(300)])])])
    #expect(throws: CollaborationError.self) { try f.store.editPanel(f.request(overflow), actor: f.actor) }
  }

  @Test func fullMeasuredContactFitsTheNativeLeaseAndRetriesAfterReopen() throws {
    let f = try Fixture(); defer { f.clean() }
    let points = (0..<65_536).map { i -> JSONValue in
      .object(["x": .number(100 + Double(i) / 1024), "y": .number(200 + sin(Double(i))),
        "width": .number(3.123456789012345), "opacity": .number(0.834567890123456),
        "timeOffset": .number(Double(i) / 120), "force": .number(0.123456789012345),
        "azimuth": .number(0.987654321098765), "altitude": .number(1.123456789012345)])
    }
    let operation = CollaborationOperation(kind: .appendInkStroke, target: f.page, id: UUID().uuidString,
      values: ["points": .array(points)])
    let request = f.request(operation)
    #expect(try JSONEncoder().encode(request).count > 8 * 1_024 * 1_024)
    let result = try f.store.editPanel(request, actor: f.actor)
    let cold = NotebookStore(root: f.root)
    #expect(try cold.editPanel(request, actor: f.actor) == result)
    let actionID = UUID(uuidString: operation.id!)!
    let saved = try #require(try cold.readPageInkAction(pageID: f.page.id, actionID: actionID)).action
    #expect(saved.samples.count == points.count)
    #expect(saved.samples.last!.timeOffset == Double(points.count - 1) / 120)
    _ = try cold.undoPanel(.init(workspaceID: f.workspaceID, target: f.page, actionID: request.actionID), actor: f.actor)
    #expect(try NotebookStore(root: f.root).editPanel(request, actor: f.actor) == result)
    #expect(try cold.readPageInkAction(pageID: f.page.id, actionID: actionID)?.action.isActive == false)
    #expect(throws: CollaborationError.self) { try f.agent(operation) }
    let overLimit = CollaborationOperation(kind: .appendInkStroke, target: f.page, id: UUID().uuidString,
      values: ["points": .array(points + [points[0]])])
    #expect(throws: CollaborationError.self) { try cold.editPanel(f.request(overLimit), actor: f.actor) }
  }

  @Test func appendAndUndoReadOnlyTheirOwnMaterialAndMigrationPreservesContent() throws {
    let f = try Fixture(); defer { f.clean() }
    var page = try f.store.loadPage(f.page.id)
    let source = String(repeating: "<p>Сохранённая программа</p>", count: 20_000)
    let replaced = page.replaceElements([.init(id: "large-program", kind: .web,
      frame: .init(x: 20, y: 20, width: 400, height: 200), source: source, html: source)], actor: f.actor)
    #expect(replaced)
    try f.store.savePage(page)
    try f.agent(f.stroke(f.page))
    let records = try f.store.sqlRead { try $0.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] } }
    try f.store.commandTransaction {
      try f.store.currentSQL!.run("DROP TABLE page_ink_order")
      try f.store.currentSQL!.run("PRAGMA user_version=27")
    }
    let cold = NotebookStore(root: f.root); try cold.prepare()
    #expect(try cold.sqlRead { try $0.rows("SELECT address,hash FROM records ORDER BY address").map { [$0[0].text!, $0[1].text!] } } == records)
    let request = f.request(try f.stroke(f.page))
    try cold.commandTransaction(readAllowance: .init(rows: 4096, bytes: 2_000_000, valueBytes: 65_536, reason: "pen_reads_only_its_contact")) {
      _ = try cold.editPanel(request, actor: f.actor)
    }
    let strokeID = UUID(uuidString: request.operations[0].id!)!
    #expect(try cold.readPageInkAction(pageID: f.page.id, actionID: strokeID)?.action.sequence == 2)
    try cold.commandTransaction(readAllowance: .init(rows: 4096, bytes: 2_000_000, valueBytes: 65_536, reason: "undo_reads_only_its_contact")) {
      _ = try cold.undoPanel(.init(workspaceID: f.workspaceID, target: f.page, actionID: request.actionID), actor: f.actor)
    }
    #expect(try cold.readPageElement(pageID: f.page.id, elementID: "large-program")?.source == source)
  }
}
