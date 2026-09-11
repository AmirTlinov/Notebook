import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("An existing page element is an addressed command, not a whole page", .serialized)
struct NotebookPageElementCommandTests {
  private let elementID = "program/a~😀"
  private enum Fault: Error { case disk }

  private func fixture(largeNeighbour: Bool = false,
    _ body: (NotebookStore, UUID, PageDocument) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-element-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let index = try store.loadIndex(), pageID = try #require(index.selectedPageID)
    let stroke = PageInkAction(tool: .pen, samples: [20.0, 50].enumerated().map {
      .init(point: .init(x: $0.element, y: 40), timeOffset: Double($0.offset) / 100,
        width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    }, sequence: 1)
    var page = try store.loadPage(pageID)
    let inkChanged = try page.replaceDrawing(PageInkDrawing(actions: [stroke]).dataRepresentation(), actor: actor)
    #expect(inkChanged)
    let elementsChanged = page.replaceElements([
        .init(id: "foreign", kind: .web, frame: .init(x: 500, y: 500, width: 100, height: 100),
          source: "Foreign", html: largeNeighbour ? String(repeating: "x", count: 8 * 1_024 * 1_024) : "Foreign"),
        .init(id: elementID, kind: .web, frame: .init(x: 10, y: 10, width: 200, height: 200),
          source: "Before", html: "<button>Before</button>", css: "button{color:blue}",
          javaScript: "counter=1", state: .object([
            "nested": .object(["id": .string("content"), "stamp": .number(3)]),
            "a/": .object(["actions": .array([.object(["id": .string("one"), "value": .number(1)])])]),
            "a~": .object(["actions": .array([.object(["id": .string("two"), "value": .number(2)])])])])),
        .init(id: elementID + "/child", kind: .markdown, frame: .init(x: 400, y: 100, width: 100, height: 100),
          source: "Unrelated prefix", html: "")], actor: actor)
    #expect(elementsChanged)
    try store.savePage(page)
    _ = try store.activateComputation(id: UUID(), ink: store.readComputationInk(notebookID: index.selectedItemID,
      pageID: pageID, region: .init(x: 0, y: 0, width: 100, height: 100)), actor: actor)
    try body(store, actor, store.loadPage(pageID))
  }

  private func action(_ page: PageDocument, id: String? = nil,
    kind: CollaborationOperation.Kind = .updateElement,
    values: [String: JSONValue] = ["source": .string("After"), "html": .string("<button>After</button>")],
    sourceRevision: String? = nil) -> CollaborationAction {
    let target = CollaborationTarget(kind: .page, id: page.id)
    return .init(summary: "Change one addressed element", references: [.init(target: target,
      region: .init(x: 0, y: 0, width: 250, height: 250), revision: page.agentStamp.revision)],
      expected: [.init(target: target, revision: page.agentStamp.revision, sourceRevision: sourceRevision)],
      operations: [.init(kind: kind, target: target, id: id ?? elementID, values: values)])
  }

  private final class SQLCounter { var steps = 0 }
  private func bounded<T>(_ store: NotebookStore, _ operation: () throws -> T) throws -> T {
    let counter = SQLCounter()
    let value = try withExtendedLifetime(counter) {
      try store.commandTransaction {
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
          let counter = Unmanaged<SQLCounter>.fromOpaque(raw!).takeUnretainedValue()
          counter.steps += 1
          return counter.steps < 200_000 ? 0 : 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        return try operation()
      }
    }
    #expect(counter.steps > 0 && counter.steps < 200_000)
    print("PAGE_ELEMENT_COMMAND sql_vm_steps=\(counter.steps)")
    return value
  }

  private func recordIndex(_ store: NotebookStore, file: String) throws -> [[String]] {
    try store.sqlRead { try $0.rows("SELECT address,hash,position FROM records WHERE file=? ORDER BY address", [.text(file)])
      .map { [$0[0].text!, $0[1].text!, String($0[2].integer!)] } }
  }

  @Test func updateReceiptRetryContinuationsAndUndoNeverReadUnrequestedBodies() throws {
    try fixture(largeNeighbour: true) { store, actor, page in
      let file = pageFile(page.id), root = file + "#"
      let target = CollaborationTarget(kind: .page, id: page.id)
      let request = action(page, values: ["source": .string("After"), "html": .string("After"),
        "frame": try .encode(PageRect(x: 25, y: 25, width: 200, height: 200))],
        sourceRevision: try store.referenceRevision(target: target))
      let records = try recordIndex(store, file: file), cursor = try store.currentChangeCursor()
      let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      var damaged: [String: Data] = [:]
      // This isolated corruption is outside the command writer. Reading any
      // unrelated program, ink value or computation must now fail loudly.
      for record in records where record[0].hasPrefix(root + "/drawingData")
        || record[0].hasPrefix(root + "/computations/")
        || record[0] == root + "/elements/@foreign"
        || record[0] == root + "/elements/@" + fieldKey([elementID + "/child"]) {
        damaged[record[1]] = try database.blob(record[1])
        try database.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(Data("not JSON".utf8)), .text(record[1])])
      }
      #expect(damaged.count >= 6)
      let receipt = try bounded(store) { try store.applyCollaborationAction(request, actor: UUID()) }
      let committed = try store.currentChangeCursor()
      #expect(committed == cursor + 1 && !receipt.changes.isEmpty)
      #expect(try bounded(store) { try store.applyCollaborationAction(request, actor: UUID()) } == receipt)
      #expect(try store.currentChangeCursor() == committed)
      #expect(try bounded(store) { try store.collaborationContinuations(receipt.id) }.isEmpty)
      let undone = try bounded(store) { try store.undoCollaborationAction(receipt.id, actor: actor) }
      #expect(undone.undo?.preserved.isEmpty == true)
      #expect((undone.undo?.restored ?? 0) > 0)
      let changed = Set(try store.readChangedAddresses(after: cursor, through: store.currentChangeCursor()).addresses)
      let after = try recordIndex(store, file: file)
      #expect(after.count == records.count)
      #expect(after.filter { !changed.contains($0[0]) } == records.filter { !changed.contains($0[0]) })
      #expect(!changed.contains { $0.hasPrefix(root + "/drawingData") || $0.hasPrefix(root + "/computations/") })
      #expect(!changed.contains(root + "/elements/@foreign"))
      for (hash, data) in damaged { try database.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(data), .text(hash)]) }
      let reopened = try NotebookStore(root: store.root).loadPage(page.id)
      #expect(reopened.elements == page.elements && reopened.drawingData == page.drawingData)
      #expect(reopened.computations == page.computations)
    }
  }

  @Test func anElementProjectionCannotBeDecodedOrPublishedAsAnArchive() throws {
    try fixture { store, _, page in
      let projection = try store.readTransaction { try $0.actionSourceProjection(action(page)) }
      let value = try #require(projection.files[pageFile(page.id)])
      #expect(projection.projectedPageIDs == [page.id])
      #expect(value["drawingData"] == nil && value["computations"] == nil)
      #expect(try value["elements"]?.decode([AgentElement].self).map(\.id) == [elementID])
      #expect(throws: (any Error).self) { try value.decode(PageDocument.self) }
      #expect(throws: (any Error).self) { try projection.validate() }
      let cursor = try store.currentChangeCursor()
      #expect(throws: (any Error).self) { try store.publishRecords(writes: [pageFile(page.id): value]) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.loadPage(page.id) == page)
    }
  }

  @Test func indexedPhysicalIdentityMatchesCompleteValuesAcrossOrderInkAndBindings() throws {
    try fixture { store, actor, page in
      let target = CollaborationTarget(kind: .page, id: page.id)
      let index = try store.loadIndex()
      let cover = CollaborationTarget(kind: .cover, id: index.selectedItemID, boardID: index.rootBoardID)
      let coverBefore = try store.referenceRevision(target: cover)
      func checked() throws -> String {
        let value = try JSONValue.encode(store.loadPage(page.id))
        let source = try store.referenceRevision(target: target)
        #expect(try source == NotebookStore.referenceRevision(target: target, files: [pageFile(page.id): value]))
        #expect(try store.referenceRevision(target: cover) == coverBefore)
        return source
      }
      let initial = try checked()
      let identities = try store.referenceIdentities(targets: [target])
      let projection = try store.readTransaction { try $0.actionSourceProjection(action(page)) }
      var bound = try NotebookStore.bindReferenceIdentities(identities, to: projection.files)
      #expect(try NotebookStore.referenceRevision(target: target, files: bound) == initial)
      bound[pageFile(page.id)] = bound[pageFile(page.id)]?.setting("elements", .array([]))
      #expect(throws: CollaborationError.self) { try NotebookStore.referenceRevision(target: target, files: bound) }

      let order = CollaborationAction(additionalOwners: [target], summary: "Reverse physical painting order",
        expected: [.init(target: target, revision: page.agentStamp.revision)], operations: [
          .init(kind: .reorderElements, target: target, values: ["ids": .array(page.elements.reversed().map { .string($0.id) })])])
      let receipt = try store.applyCollaborationAction(order, actor: UUID())
      let reversed = try checked()
      #expect(reversed != initial)
      _ = try store.undoCollaborationAction(receipt.id, actor: actor)
      let restored = try checked()
      var drawing = try store.loadPage(page.id)
      let measured = PageInkAction(tool: .pen, samples: [.init(point: .init(x: 70, y: 80), timeOffset: 0,
        width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
      let append = try drawing.prepareInkChange(.append(measured), stamp: .init(counter: 20, actor: actor))
      let appended = drawing.publishInkChange(append)
      #expect(appended); try store.savePage(drawing)
      let withInk = try checked()
      #expect(withInk != restored)
      drawing = try store.loadPage(page.id)
      let remove = try drawing.prepareInkChange(.remove([measured.id]), stamp: .init(counter: 21, actor: actor))
      let removed = drawing.publishInkChange(remove)
      #expect(removed); try store.savePage(drawing)
      #expect(try checked() != withInk)
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.referenceRevision(target: target) == checked())
    }
  }

  @Test(arguments: [false, true])
  func laterHumanAdoptionAndUntouchedFieldClocksSurviveAnAddressedEdit(sameField: Bool) throws {
    try fixture { store, actor, page in
      let receipt = try store.applyCollaborationAction(action(page), actor: UUID())
      let changed = try store.loadPage(page.id)
      let neighbourKeys = AgentElement.causalFieldKeys(id: "foreign") + ["elements/order"]
      for key in neighbourKeys { #expect(changed.collaboration?.fields[key] == page.collaboration?.fields[key]) }
      var human = changed
      let values = try human.elements.map { element -> AgentElement in
        guard element.id == elementID else { return element }
        let updated = element.updating(state: .number(9))
        return sameField ? try JSONValue.encode(updated).setting("source", .string("Human"))
          .setting("html", .string("Human")).decode(AgentElement.self) : updated
      }
      let adopted = human.replaceElements(values, actor: actor)
      #expect(adopted)
      try store.savePage(human)
      let continuations = try store.collaborationContinuations(receipt.id)
      #expect(continuations.isEmpty == !sameField)
      let undone = try store.undoCollaborationAction(receipt.id, actor: UUID())
      let final = try store.loadPage(page.id)
      #expect(final.elements.first { $0.id == elementID }?.state == .number(9))
      #expect(final.elements.first { $0.id == elementID }?.source == (sameField ? "Human" : "Before"))
      #expect(final.elements.first { $0.id == "foreign" } == page.elements.first)
      #expect(undone.undo?.preserved.isEmpty == !sameField)
    }
  }

  @Test func sourceVersionAndGeometryStillNameTheWholePhysicalOwner() throws {
    try fixture { store, actor, page in
      let target = CollaborationTarget(kind: .page, id: page.id)
      let revision = try store.referenceRevision(target: target)
      var moved = page
      let changed = moved.replaceElements(page.elements.map {
        $0.id == "foreign" ? $0.updating(frame: .init(x: 550, y: 500, width: 100, height: 100)) : $0
      }, actor: actor)
      #expect(changed); try store.savePage(moved)
      let current = try store.loadPage(page.id), before = try store.currentChangeCursor()
      let stale = action(current, sourceRevision: revision)
      #expect(throws: (any Error).self) { try store.applyCollaborationAction(stale, actor: UUID()) }
      let outside = action(current, id: "foreign", values: ["frame": try .encode(PageRect(x: 5, y: 5, width: 100, height: 100))])
      #expect(throws: (any Error).self) { try store.applyCollaborationAction(outside, actor: UUID()) }
      #expect(try store.currentChangeCursor() == before && store.loadPage(page.id) == current)
    }
  }

  @Test func requestedOversizedBodyRefusesTheWholeBatchBeforePublishing() throws {
    try fixture(largeNeighbour: true) { store, _, page in
      let target = CollaborationTarget(kind: .page, id: page.id), cursor = try store.currentChangeCursor()
      let request = CollaborationAction(summary: "The batch shares one admission",
        expected: [.init(target: target, revision: page.agentStamp.revision)], operations: [
          .init(kind: .setElementState, target: target, id: elementID, values: ["state": .number(2)]),
          .init(kind: .setElementState, target: target, id: "foreign", values: ["state": .number(3)])])
      #expect(throws: (any Error).self) { try store.applyCollaborationAction(request, actor: UUID()) }
      #expect(try store.currentChangeCursor() == cursor && store.loadPage(page.id) == page)
    }
  }

  @Test(arguments: ["worldOrigin", "textStyle", "frame"])
  func anElementCannotAcquireAnotherOwnersGeometryOrUnknownRectangleFields(field: String) throws {
    try fixture { store, _, page in
      let value: JSONValue = field == "frame"
        ? try JSONValue.encode(PageRect(x: 20, y: 20, width: 100, height: 100)).setting("unknown", .bool(true))
        : .object([:])
      let request = action(page, values: [field: value]), cursor = try store.currentChangeCursor()
      #expect(throws: (any Error).self) { try store.applyCollaborationAction(request, actor: UUID()) }
      #expect(try store.currentChangeCursor() == cursor && store.loadPage(page.id) == page)
    }
  }

  @Test func directCommandsRespectTheSameExpectationCountAsMCP() throws {
    try fixture { store, _, page in
      let target = CollaborationTarget(kind: .page, id: page.id), cursor = try store.currentChangeCursor()
      let request = CollaborationAction(summary: "Reject excess source addresses",
        expected: Array(repeating: .init(target: target, revision: page.agentStamp.revision), count: 1025),
        operations: [.init(kind: .setElementState, target: target, id: elementID, values: ["state": .number(2)])])
      do {
        _ = try store.applyCollaborationAction(request, actor: UUID())
        Issue.record("An oversized direct command must not enter its source read")
      } catch let error as CollaborationError { #expect(error.code == "invalid_action") }
      #expect(try store.currentChangeCursor() == cursor && store.loadPage(page.id) == page)
    }
  }

  @Test func anExistingElementDoesNotReadNinetyNineThousandRetiredFieldBodies() throws {
    try fixture { store, actor, page in
      let file = pageFile(page.id), root = file + "#"
      try store.commandTransaction {
        for index in 0..<99_000 {
          let key = "retired-\(index)"
          try store.writeFragment(.init(address: root + "/collaboration/fields/@" + fieldKey([key]), file: file,
            parent: root, collection: "collaboration/fields", member: key, position: 0,
            value: .encode(ContentFieldVersion(stamp: page.agentStamp, human: true)), collections: []),
            database: store.currentSQL!)
        }
      }
      let database = try NotebookSQLConnection(url: store.databaseURL, writable: true)
      let address = root + "/collaboration/fields/@retired-0"
      let hash = try #require(database.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text)
      let bytes = try database.blob(hash)
      try database.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(Data("unrequested history".utf8)), .text(hash)])
      let request = action(page, kind: .setElementState, values: ["state": .number(7)])
      let receipt = try bounded(store) { try store.applyCollaborationAction(request, actor: UUID()) }
      let undone = try bounded(store) { try store.undoCollaborationAction(receipt.id, actor: actor) }
      #expect(undone.undo?.restored == 1 && undone.undo?.preserved.isEmpty == true)
      #expect(try database.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text == hash)
      try database.run("UPDATE blobs SET data=? WHERE hash=?", [.blob(bytes), .text(hash)])
      let reopened = try store.loadPage(page.id)
      #expect(reopened.elements == page.elements && reopened.drawingData == page.drawingData)
      #expect(reopened.collaboration?.fields.count == (page.collaboration?.fields.count ?? 0) + 99_000)
    }
  }

  @Test func aConcurrentNeighbourDoesNotAcquireTheEditedElementsNewFrontier() throws {
    try fixture { store, _, page in
      let receipt = try store.applyCollaborationAction(action(page), actor: UUID())
      var staleHuman = page
      let elements = try page.elements.map { element -> AgentElement in
        guard element.id == "foreign" else { return element }
        return try JSONValue.encode(element).setting("source", .string("Human neighbour"))
          .setting("html", .string("Human neighbour")).decode(AgentElement.self)
      }
      let changed = staleHuman.replaceElements(elements, actor: UUID())
      #expect(changed)
      try store.savePage(staleHuman)
      let merged = try store.loadPage(page.id)
      #expect(merged.elements.first { $0.id == elementID }?.source == "After")
      #expect(merged.elements.first { $0.id == "foreign" }?.source == "Human neighbour")
      _ = try store.undoCollaborationAction(receipt.id, actor: UUID())
      let undone = try store.loadPage(page.id)
      #expect(undone.elements.first { $0.id == elementID }?.source == "Before")
      #expect(undone.elements.first { $0.id == "foreign" }?.source == "Human neighbour")
    }
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func retryResolvesTheSameReceiptAcrossACommitFault(phase: NotebookStorageFault) throws {
    try fixture { store, _, page in
      let request = action(page), actor = UUID(), cursor = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root) { if $0 == phase { throw Fault.disk } }
      #expect(throws: Fault.self) { try failing.applyCollaborationAction(request, actor: actor) }
      #expect(try store.currentChangeCursor() == cursor + (phase == .afterCommit ? 1 : 0))
      let receipt = try store.applyCollaborationAction(request, actor: actor)
      #expect(try store.currentChangeCursor() == cursor + 1)
      #expect(try store.collaborationAction(request.id) == receipt)
      #expect(try store.loadPage(page.id).elements.first { $0.id == elementID }?.source == "After")
    }
  }
}
