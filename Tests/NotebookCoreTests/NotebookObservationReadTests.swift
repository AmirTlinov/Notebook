import Foundation
import Testing
@testable import NotebookCore

@Suite("Incremental addressed observation", .serialized)
struct NotebookObservationReadTests {
  final class Fixture {
    let store: NotebookStore, pageID = UUID(), actor = UUID()
    var target: CollaborationTarget { .init(kind: .page, id: pageID) }
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("observation-\(UUID())"))
      _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    }
    deinit { try? FileManager.default.removeItem(at: store.root) }
    func put(_ id: String, x: Double = 0, source: String = "source", graphic: NotebookGraphic? = nil) throws {
      try store.commandTransaction {
        let file = pageFile(pageID), element = AgentElement(id: id, kind: graphic == nil ? .markdown : .graphic,
          frame: .init(x: x, y: 0, width: 100, height: 100), source: source, html: "<p>source</p>", graphic: graphic)
        try store.writeFragment(.init(address: file + "#/elements/@" + fieldKey([id]), file: file, parent: file + "#",
          collection: "elements", member: id, position: 0, value: try .encode(element), collections: []), database: store.currentSQL!)
      }
    }
    func poison(_ id: String) throws {
      try store.commandTransaction {
        try store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
          [.blob(Data("body must not be decoded".utf8)), .text(pageFile(pageID) + "#/elements/@" + id)])
      }
    }
  }
  @Test func changeAddressPagesExposeTheirPosition() throws {
    let f = try Fixture()
    let page = try f.store.readChangedAddresses(after: 0, through: f.store.currentChangeCursor(), limit: 1)
    #expect(page.hasMore)
    #expect(page.nextAddress == page.records.last?.address)
  }
  @Test func deltaDoesNotDecodeUnchangedBodiesAndProjectionChangesReset() throws {
    let f = try Fixture()
    try f.put("a"); try f.put("z")
    var scope = NotebookObservationScope(target: f.target, fields: [.content])
    let first = try f.store.observeContent(scope: scope)
    try f.put("z", source: "new")
    try f.poison("a")
    let delta = try f.store.observeContent(scope: scope, since: first.checkpoint)
    #expect(delta.mode == "delta")
    #expect(delta.objects.map(\.id) == ["z"])
    #expect(delta.objects.first?.value?["content"]?["source"] == .string("new"))
    try f.poison("z")
    #expect(try f.store.observeContent(scope: scope, since: delta.checkpoint).objects.isEmpty)
    scope.ids = ["missing"]
    let reset = try f.store.observeContent(scope: scope, since: delta.checkpoint)
    #expect(reset.reset == "scope_changed")
    #expect(reset.mode == "snapshot")
  }
  @Test func snapshotAndDeltaDrainMoreThan4096WithoutSkippingOrPrematureCheckpoint() throws {
    let f = try Fixture(), scope = NotebookObservationScope(target: f.target)
    let empty = try f.store.observeContent(scope: scope)
    try f.store.commandTransaction { for i in 0..<4103 { try f.put(String(format: "id-%05d", i)) } }
    func drain(since: String?) throws -> [String] {
      var next: String?, result: [String] = [], pages = 0
      repeat {
        let page = try f.store.observeContent(scope: scope, since: next == nil ? since : nil, next: next, limit: 31)
        if !page.coverage.complete { #expect(page.checkpoint == nil) }
        else { #expect(page.checkpoint != nil) }
        result += page.objects.map(\.id); pages += 1; next = page.coverage.next
        #expect(pages < 150)
      } while next != nil && pages < 150
      return result
    }
    let snapshot = try drain(since: nil), delta = try drain(since: empty.checkpoint)
    #expect(snapshot.count == 4103)
    #expect(delta == snapshot)
    #expect(Set(delta).count == 4103)
  }
  @Test func continuationRejectsMutationScopeMismatchAndCheckpointMisuse() throws {
    let f = try Fixture(), scope = NotebookObservationScope(target: f.target)
    try f.put("a"); try f.put("b")
    let first = try f.store.observeContent(scope: scope, limit: 1)
    #expect(throws: CollaborationError.self) { try f.store.observeContent(scope: scope, since: first.coverage.next) }
    #expect(throws: CollaborationError.self) {
      try f.store.observeContent(scope: .init(target: f.target, fields: [.content]), next: first.coverage.next)
    }
    try f.put("c")
    #expect(throws: CollaborationError.self) { try f.store.observeContent(scope: scope, next: first.coverage.next) }
    let complete = try f.store.observeContent(scope: scope)
    try f.store.commandTransaction {
      try f.store.currentSQL!.run("INSERT OR REPLACE INTO metadata(key,value) VALUES('placement_outgoing_floor',?)", [.text(String(try f.store.currentChangeCursor() + 1))])
    }
    #expect(throws: CollaborationError.self) { try f.store.observeContent(scope: scope, since: complete.checkpoint) }
  }
  @Test func offScopeEndpointMotionInvalidatesConnectorWithoutAuthoringIt() throws {
    let f = try Fixture()
    try f.put("node", graphic: .init())
    let connection = NotebookGraphicConnection(start: .init(point: .init(x: 0, y: 0), binding: .init(elementID: "node")),
      end: .init(point: .init(x: 1, y: 1)))
    try f.put("arrow", x: 300, graphic: .init(shape: .connector, connection: connection))
    let scope = NotebookObservationScope(target: f.target, ids: ["arrow"], fields: [.geometry])
    let first = try f.store.observeContent(scope: scope)
    let original = try f.store.readPageElement(pageID: f.pageID, elementID: "arrow")
    try f.put("node", x: 150, graphic: .init())
    let delta = try f.store.observeContent(scope: scope, since: first.checkpoint)
    #expect(delta.objects.map(\.id) == ["arrow"])
    #expect(delta.objects.first?.value != first.objects.first?.value)
    #expect(try f.store.readPageElement(pageID: f.pageID, elementID: "arrow") == original)
    try f.store.commandTransaction { try f.store.removeFragment(pageFile(f.pageID) + "#/elements/@node", database: f.store.currentSQL!) }
    let absent = try f.store.observeContent(scope: scope, since: delta.checkpoint)
    #expect(absent.objects.first?.value?["graphicResolution"]?["state"] == .string("pending"))
    try f.put("node", x: 150, graphic: .init())
    let restored = try f.store.observeContent(scope: scope, since: absent.checkpoint)
    #expect(restored.objects.first?.value == delta.objects.first?.value)
  }
  @Test func outgoingExpansionDistinguishesUnbindingFromDeletion() throws {
    let f = try Fixture()
    try f.put("node", graphic: .init())
    var connection = NotebookGraphicConnection(start: .init(point: .init(x: 0, y: 0), binding: .init(elementID: "node")),
      end: .init(point: .init(x: 1, y: 1)))
    try f.put("arrow", graphic: .init(shape: .connector, connection: connection))
    let scope = NotebookObservationScope(target: f.target, ids: ["arrow"], fields: [.preview], expand: [.outgoing])
    let first = try f.store.observeContent(scope: scope)
    #expect(first.objects.map(\.id) == ["arrow", "node"])
    connection.start.binding = nil
    try f.put("arrow", graphic: .init(shape: .connector, connection: connection))
    let delta = try f.store.observeContent(scope: scope, since: first.checkpoint)
    #expect(delta.objects.first { $0.id == "node" }?.change == .outOfScope)
    let deletionScope = NotebookObservationScope(target: f.target, ids: ["node"])
    let beforeDelete = try f.store.observeContent(scope: deletionScope)
    try f.store.commandTransaction {
      try f.store.removeFragment( pageFile(f.pageID) + "#/elements/@node", database: f.store.currentSQL!)
    }
    let deleted = try f.store.observeContent(scope: deletionScope, since: beforeDelete.checkpoint)
    #expect(deleted.objects.first?.change == .deleted)
  }
  @Test func spatialWindowExitsEntriesAndDeletionsStayDifferent() throws {
    let f = try Fixture(), boardID = try f.store.workspaceHeader().rootBoardID
    let target = CollaborationTarget(kind: .board, id: boardID)
    func write(_ kind: CollaborationOperation.Kind, _ x: Double) throws {
      var values: [String: JSONValue] = kind == .removeElement ? [:] : [
        "source": .string("window"),
        "frame": try .encode(PageRect(x: 0, y: 0, width: 100, height: 100)),
        "worldOrigin": try .encode(WorldPoint.zero.offsetBy(x: x, y: 0))]
      if kind == .insertElement { values["kind"] = .string("markdown") }
      let revision = try f.store.targetContentRevision(target: target)
      _ = try f.store.applyCollaborationAction(.init(summary: "Window", references: [.init(target: target, revision: revision)],
        expected: [.init(target: target, revision: revision)], operations: [.init(kind: kind, target: target, id: "moving", values: values)]), actor: f.actor)
    }
    try write(.insertElement, 0)
    let scope = NotebookObservationScope(target: target, bounds: .init(anchor: .zero, region: .init(x: 0, y: 0, width: 200, height: 200)))
    let first = try f.store.observeContent(scope: scope)
    #expect(first.objects.map(\.id) == ["moving"])
    try write(.updateElement, 1000)
    let exit = try f.store.observeContent(scope: scope, since: first.checkpoint)
    #expect(exit.objects.first?.change == .outOfScope)
    try write(.updateElement, 0)
    let enter = try f.store.observeContent(scope: scope, since: exit.checkpoint)
    #expect(enter.objects.first?.change == .upsert)
    try write(.removeElement, 0)
    let deleted = try f.store.observeContent(scope: scope, since: enter.checkpoint)
    #expect(deleted.objects.first?.change == .deleted)
  }

  @Test func documentStateNestedRecordsAndEscapedIDsAreOneDeltaObject() throws {
    let f = try Fixture(), id = "program/a~b"
    var index = try f.store.loadIndex(), board = try f.store.loadBoard(items: index.items)
    let created = index.createDocument(title: "Programs", actor: f.actor)
    let document = try #require(created)
    let added = board.addItem(document.id, to: index.rootBoardID, near: .zero, actor: f.actor)
    #expect(added)
    try f.store.saveDocumentWorkspaceBundle(index: index, document: .init(id: document.id, actor: f.actor,
      blocks: [.interactive(id: id, html: "<p>Program</p>")]), state: .init(id: document.id, actor: f.actor), board: board)
    let scope = NotebookObservationScope(target: .init(kind: .document, id: document.id), ids: [id], fields: [.state])
    let before = try f.store.observeContent(scope: scope)
    var state = try f.store.loadDocumentState(document.id)
    let changed = state.commit(blockID: id, value: .object(["records": .array([.object(["id": .string("child"), "n": .number(3)])])]), actor: f.actor)
    #expect(changed)
    try f.store.saveDocumentState(state)
    let delta = try f.store.observeContent(scope: scope, since: before.checkpoint)
    #expect(delta.objects.map(\.id) == [id])
    #expect(delta.objects.first?.value?["state"] == state.value(for: id))
  }

  @Test func presenceGenerationDoesNotAdvanceContentCheckpointAndCannotABA() throws {
    let f = try Fixture(), header = try f.store.workspaceHeader()
    let scope = NotebookObservationScope(target: f.target)
    let before = try f.store.observeContent(scope: scope), generation = try f.store.presenceGeneration()
    let a = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: .init(), viewport: .init(x: 800, y: 600))
    let b = SessionPresence(boardID: header.rootBoardID, mode: .board, camera: .init(scale: 0.4), viewport: .init(x: 800, y: 600))
    try f.store.savePresence(a)
    let first = try f.store.presenceGeneration()
    try f.store.savePresence(a)
    #expect(try f.store.presenceGeneration() == first)
    try f.store.savePresence(b); try f.store.savePresence(a)
    #expect(try f.store.presenceGeneration() != first)
    #expect(generation != first)
    let after = try f.store.observeContent(scope: scope, since: before.checkpoint)
    #expect(after.through == before.through)
    #expect(after.objects.isEmpty)
  }

  @Test func forgedContinuationCannotReadAnotherPhysicalOrLocalOwner() throws {
    let f = try Fixture()
    try f.put("a"); try f.put("b")
    let scope = NotebookObservationScope(target: f.target, ids: ["a", "b"])
    let first = try f.store.observeContent(scope: scope, limit: 1)
    let valid = try NotebookObservationCursor.decode(#require(first.coverage.next))
    let forged = NotebookObservationCursor(workspaceID: valid.workspaceID, scope: valid.scope, from: valid.from,
      through: valid.through, position: valid.position, members: ["last-context.json#"], previousMembers: nil)
    #expect(throws: CollaborationError.self) { try f.store.observeContent(scope: scope, next: forged.encode()) }
  }

}
