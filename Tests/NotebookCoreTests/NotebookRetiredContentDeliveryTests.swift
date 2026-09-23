import Foundation
import Testing
@testable import NotebookCore

@Suite("A legacy live cut cannot acknowledge a discarded retired source", .serialized)
struct NotebookRetiredContentDeliveryTests {
  @Test(arguments: ["page", "document", "state", "board"], [false, true])
  func explicitRetiredSourcesRequireAddressedDeliveryWithoutAnyPublication(source: String, local: Bool) throws {
    let f = try NotebookItemLifecycleTests.Fixture(), header = try f.store.workspaceHeader(), id = UUID(), pageID = UUID()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let kind: CollaborationOperation.Kind = source == "page" ? .createNotebook : source == "board" ? .createBoard : .createDocument
    var values: [String: JSONValue] = ["center": try .encode(WorldPoint.zero)]
    if kind == .createNotebook { values["pageID"] = try .encode(pageID) }
    if kind == .createDocument {
      values["paperSize"] = .string("a4")
      values["blocks"] = try .encode([DocumentBlock.interactive(id: "body", html: "<button>Before</button>", initialState: .number(0))])
    }
    let basis = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Birth before a stale whole cut",
      expected: basis.owners, operations: [.init(kind: kind, target: board, id: id.uuidString, values: values)]), actor: f.actor)
    var submitted = try f.store.collaborationContent()
    let human = UUID(), roots: [String]
    switch source {
    case "page":
      let position = try #require(submitted.pages.firstIndex { $0.id == pageID })
      let changed = submitted.pages[position].replaceElements([.init(id: "late", kind: .markdown,
        frame: .init(x: 0, y: 0, width: 100, height: 100), source: "Late source", html: "<p>Late source</p>")], actor: human)
      #expect(changed); roots = [pageFile(pageID) + "#"]
    case "document":
      let position = try #require(submitted.documents.firstIndex { $0.id == id })
      let changed = submitted.documents[position].replaceContent(preamble: "Late preamble", actor: human)
      #expect(changed); roots = [documentFile(id) + "#", stateFile(id) + "#"]
    case "state":
      let position = try #require(submitted.states.firstIndex { $0.id == id })
      let changed = submitted.states[position].commit(blockID: "body", value: .number(77), actor: human)
      #expect(changed)
      submitted.documents = [] // A partial envelope can carry state independently.
      roots = [documentFile(id) + "#", stateFile(id) + "#"]
    default:
      let changed = submitted.hierarchy.updatePortalCamera(.init(center: .init(x: 80, y: -30), scale: 1.4), for: id, actor: human)
      #expect(changed); roots = ["board.json#/boards/@" + id.uuidString.lowercased()]
    }
    try f.store.commandTransaction { try f.store.deleteWorkspaceItemContent(itemID: id, actor: UUID(), human: false) }
    let retained = try roots.flatMap { try f.store.storedFragments(address: $0) }
    let cursor = try f.store.currentChangeCursor(), before = try f.store.collaborationContent()
    let context = SharedContext(entries: [.init(author: .human, references: [], text: "Must not be acknowledged",
      stamp: .init(counter: 1, actor: human))])
    do {
      if local { _ = try f.store.mergeCollaborationContent(nil, local: submitted, contexts: [context]) }
      else { _ = try f.store.receiveCollaboration(.init(content: submitted, contexts: [context])) }
      Issue.record("A live-only envelope must not acknowledge a filtered retired source")
    } catch let error as CollaborationError {
      #expect(error.code == "addressed_delivery_required")
    }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.collaborationContent() == before)
    #expect(try f.store.readItemHeader(id) == nil)
    #expect(try !f.store.hasStoredValue(f.store.contextFile(context.id)))
    #expect(try roots.flatMap { try f.store.storedFragments(address: $0) } == retained)
  }
  @Test func aLocalLiveCutCannotBypassTheNativeRetiredInkGuardButRemoteInkStillMerges() throws {
    let f = try NotebookItemLifecycleTests.Fixture(), before = try f.store.loadIndex()
    let tree = try f.store.loadBoard(items: before.items), id = UUID()
    var next = before, nextTree = tree
    let created = next.createBoard(title: "Retired ink owner", actor: f.actor, boardID: id)
    let placed = nextTree.createBoard(id, in: before.rootBoardID, near: .zero, actor: f.actor)
    #expect(created != nil && placed)
    _ = try f.store.saveWorkspaceEdits(before: before, after: next, boardBefore: tree, boardAfter: nextTree)
    _ = try f.store.deleteTestItem(itemID: id, actor: f.actor)
    var local = try f.store.collaborationContent()
    let saved = local, cursor = try f.store.currentChangeCursor()
    let added = local.ink.append(tool: .pen, spans: [.init(surface: .board(id), samples: [
      .init(point: .init(x: 10, y: 20), worldPoint: .init(x: 10, y: 20), timeOffset: 0,
        width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], actor: UUID())
    let action = try #require(added)
    #expect(throws: (any Error).self) { _ = try f.store.mergeCollaborationContent(nil, local: local) }
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.collaborationContent() == saved)
    // An already-authored remote measurement uses the existing ink merger;
    // it is not a local UI mutation of the now-invisible board.
    _ = try f.store.mergeCollaborationContent(local)
    #expect(try f.store.loadSpatialInk().actions.first { $0.id == action.id } == action)
    // A stale live cut does not contain the newly received hidden history.
    // Omission in an additive merge is not a request to remove that history.
    var stale = saved
    let liveAdded = stale.ink.append(tool: .pen, spans: [.init(surface: .board(before.rootBoardID), samples: [
      .init(point: .init(x: 30, y: 40), worldPoint: .init(x: 30, y: 40), timeOffset: 0,
        width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], actor: UUID())
    let liveAction = try #require(liveAdded)
    _ = try f.store.mergeCollaborationContent(nil, local: stale)
    let finalInk = try f.store.loadSpatialInk()
    #expect(finalInk.actions.first { $0.id == action.id } == action)
    #expect(finalInk.actions.first { $0.id == liveAction.id } == liveAction)
    #expect(try f.store.readItemHeader(id) == nil)
    #expect(try f.store.readBoardNode(id) == nil)
  }

}
