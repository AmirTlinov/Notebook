import Foundation
import Testing
@testable import NotebookCore

@Suite("Publishing a live whole cut does not erase retained source owners", .serialized)
struct NotebookRetainedContentMergeTests {
  @Test(arguments: [CollaborationOperation.Kind.createNotebook, .createDocument, .createBoard])
  func anUnrelatedLivePageEditCannotEraseADeletedItemsRetainedSource(kind: CollaborationOperation.Kind) throws {
    let f = try NotebookItemLifecycleTests.Fixture(), header = try f.store.workspaceHeader(), id = UUID(), pageID = UUID()
    let board = CollaborationTarget(kind: .board, id: header.rootBoardID)
    let cover = CollaborationTarget(kind: .cover, id: id, boardID: header.rootBoardID)
    var values: [String: JSONValue] = ["center": try .encode(WorldPoint.zero)]
    if kind == .createNotebook { values["pageID"] = try .encode(pageID) }
    if kind == .createDocument {
      values["paperSize"] = .string("a4")
      values["blocks"] = try .encode([DocumentBlock.interactive(id: "kept-program", html: "<button>Keep</button>", initialState: .number(3))])
    }
    let basis = try f.store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
    _ = try f.store.applyCollaborationAction(.init(summary: "Source retained across later deletion", expected: basis.owners,
      operations: [.init(kind: kind, target: board, id: id.uuidString, values: values)]), actor: f.actor)
    if kind == .createDocument {
      var state = try f.store.loadDocumentState(id)
      let changed = state.commit(blockID: "kept-program", value: .number(11), actor: f.actor)
      #expect(changed)
      try f.store.saveDocumentState(state)
    }
    var read = NotebookCommand(command: .read); read.readSnapshots = true
    read.queries = [try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(id)]).decode(NotebookReadQuery.self)]
    let extent = try #require(try NotebookCommandDispatcher(store: f.store).handle(read).array.first?["basis"]?.decode(NotebookReadBasis.self))
    let operation = CollaborationOperation(kind: .deleteItem, target: cover)
    _ = try f.store.applyCollaborationAction(.init(additionalOwners: [cover], summary: "Retire only live membership",
      expected: f.store.expectations(base: extent, operations: [operation]), operations: [operation]), actor: UUID())
    let roots: [String]
    switch kind {
    case .createNotebook: roots = [pageFile(pageID) + "#"]
    case .createDocument: roots = [documentFile(id) + "#", stateFile(id) + "#"]
    case .createBoard: roots = ["board.json#/boards/@" + id.uuidString.lowercased()]
    default: throw NotebookStorageError.invalidTransaction("unexpected fixture kind")
    }
    let retained = try roots.flatMap { try f.store.storedFragments(address: $0) }
    #expect(!retained.isEmpty, "Deletion must already have an admitted retained baseline")
    var local = try f.store.collaborationContent()
    #expect(!local.workspace.items.contains { $0.id == id })
    let position = try #require(local.pages.firstIndex { $0.id == f.pageID })
    var page = local.pages[position]
    let edited = page.replaceElements([.init(id: "harmless", kind: .markdown,
      frame: .init(x: 10, y: 10, width: 100, height: 80), source: "Only the other live page changes", html: "<p>Other page</p>")], actor: f.actor)
    #expect(edited)
    local.pages[position] = page
    // Force board.json publication too: its live projection omits the retained
    // child node, which is not permission to erase that independently owned source.
    let center = WorldPoint(x: 8300, y: -4200)
    let moved = local.hierarchy.moveItem(f.itemID, in: header.rootBoardID, to: center, actor: f.actor)
    #expect(moved)
    _ = try f.store.mergeCollaborationContent(nil, local: local)
    let reopened = NotebookStore(root: f.store.root)
    #expect(try reopened.loadPage(f.pageID).elements.first { $0.id == "harmless" }?.source == "Only the other live page changes")
    #expect(try reopened.readBoardItem(f.itemID)?.board.placement(of: f.itemID)?.center == center)
    #expect(try reopened.readItemHeader(id) == nil)
    #expect(try roots.flatMap { try reopened.storedFragments(address: $0) } == retained,
      "A live projection omits retired sources; absence from that projection never authorizes deleting them")
  }
}
