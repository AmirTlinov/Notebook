import Foundation
import Testing
@testable import NotebookCore

@Suite("A destructive item basis covers unseen stored content", .serialized)
struct NotebookItemLifecycleTests {
  final class Fixture {
    let store: NotebookStore, actor = UUID()
    let size = PageSize(width: 834, height: 1194)
    let itemID: UUID, pageID: UUID
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("item-lifecycle-\(UUID())"))
      _ = try store.initializeWorkspace(actor: actor, pageSize: size)
      let index = try store.loadIndex(); itemID = index.selectedItemID; pageID = try #require(index.selectedPageID)
      try store.savePresence(.init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194),
        selectedItemID: itemID, notebookPageID: pageID))
    }
    deinit { try? FileManager.default.removeItem(at: store.root) }
    func write(_ pageID: UUID, text: String) throws {
      var page = try store.loadPage(pageID)
      let element = AgentElement(id: "label", kind: .markdown,
        frame: .init(x: 0, y: 0, width: 100, height: 100), source: text, html: "<p>\(text)</p>")
      let changed = page.replaceElements([element], actor: actor)
      #expect(changed)
      _ = try store.savePage(page)
    }
    func append() throws -> UUID {
      var index = try store.loadIndex()
      let selected = index.selectPage(at: index.selectedItem.pageIDs.count, in: itemID, actor: actor, pageSize: size)
      let result = try #require(selected)
      let page = try #require(result.createdPage)
      _ = try store.saveWorkspaceSelection(index: index, createdPage: page)
      return page.id
    }
  }

  @Test func pageEditChangesDestructiveBasisWithoutChangingTheCoverIdentity() throws {
    let f = try Fixture(), before = try #require(try f.store.readItemLifecycle(f.itemID))
    let cover = try f.store.referenceRevision(target: before.target)
    try f.write(f.pageID, text: "Human continuation")
    let after = try #require(try f.store.readItemLifecycle(f.itemID))
    #expect(before.revision != after.revision)
    #expect(try f.store.referenceRevision(target: before.target) == cover,
      "A lifecycle fence must not redefine historical cover/pixel identity")
    #expect(try NotebookStore(root: f.store.root).readItemLifecycle(f.itemID) == after)
  }

  @Test func appendAndUnseenLastPageBothAdvanceTheItemExtent() throws {
    let f = try Fixture(), before = try #require(try f.store.readItemLifecycle(f.itemID))
    let last = try f.append(), appended = try #require(try f.store.readItemLifecycle(f.itemID))
    #expect(appended.item.pageCount == 2)
    #expect(appended.revision != before.revision)
    try f.write(last, text: "Outside the selected page")
    #expect(try f.store.readItemLifecycle(f.itemID)?.revision != appended.revision)
  }

  @Test func unchangedExtentIsReadWithoutDecodingAnyPageBody() throws {
    let f = try Fixture(); try f.write(f.pageID, text: "Stored but not selected")
    let before = try #require(try f.store.readItemLifecycle(f.itemID))
    try f.store.commandTransaction {
      try f.store.currentSQL!.run("UPDATE blobs SET data=? WHERE hash=(SELECT hash FROM records WHERE address=?)",
        [.blob(Data("This body must remain unread".utf8)), .text(pageFile(f.pageID) + "#/elements/@label")])
    }
    let after = try f.store.readTransaction { store in
      try store.currentSQL!.limitReads(.init(rows: 80, bytes: 32_768, valueBytes: 8_192, reason: "item_lifecycle_header"))
      return try store.readItemLifecycle(f.itemID)
    }
    #expect(after == before)
  }
}

extension NotebookItemLifecycleTests {
  @Test func publicLifecycleReadCarriesFrozenCatalogParentAndExtentBasis() throws {
    let f = try Fixture(), extent = try #require(try f.store.readItemLifecycle(f.itemID))
    let query = try JSONValue.object(["kind": .string("itemLifecycle"), "id": .string(f.itemID.uuidString)]).decode(NotebookReadQuery.self)
    var command = NotebookCommand(command: .read); command.queries = [query]; command.readSnapshots = true
    let value = try #require(try NotebookCommandDispatcher(store: f.store).handle(command).array.first)
    #expect(value["data"]?["revision"] == .string(extent.revision))
    let basis = try #require(try value["basis"]?.decode(NotebookReadBasis.self))
    #expect(Set(basis.owners.map(\.target.kind)) == [.workspace, .board, .cover])
    let owner = try #require(value["basis"]?["owners"]?.array.first { $0["target"]?["kind"] == .string("cover") })
    #expect(owner["lifecycleRevision"] == .string(extent.revision))
    #expect(value["coverage"]?["complete"] == .bool(true))
  }

  @Test func extentBasisRejectsUnseenEditsAndConflictingMerges() throws {
    let f = try Fixture(), extent = try #require(try f.store.readItemLifecycle(f.itemID))
    let header = try f.store.workspaceHeader(), board = CollaborationTarget(kind: .board, id: try #require(extent.target.boardID))
    let base = try f.store.readBasis(targets: [.init(kind: .workspace, id: header.rootBoardID), board, extent.target])
    func withExtent(_ revision: String) throws -> NotebookReadBasis {
      let owners = try base.owners.map { owner -> JSONValue in
        let raw = try JSONValue.encode(owner)
        return owner.target == extent.target ? raw.setting("lifecycleRevision", .string(revision)) : raw
      }
      return try JSONValue.encode(base).setting("owners", .array(owners)).decode(NotebookReadBasis.self)
    }
    let frozen = try withExtent(extent.revision)
    try f.write(f.pageID, text: "Unseen human edit")
    let current = try #require(try f.store.readItemLifecycle(f.itemID))
    let operation = CollaborationOperation(kind: .renameItem, target: board, id: f.itemID.uuidString, values: ["title": .string("Must not be saved")])
    let beforeCursor = try f.store.currentReadCursor()
    do {
      _ = try f.store.applyCollaborationAction(.init(summary: "Frozen lifecycle", expected: frozen.owners, operations: [operation]), actor: f.actor)
      Issue.record("An unseen page edit must invalidate the explicitly supplied destructive extent")
    } catch let error as CollaborationError { #expect(error.code == "revision_conflict"); #expect(error.target == extent.target) }
    #expect(try f.store.currentReadCursor() == beforeCursor)
    #expect(try f.store.readItemHeader(f.itemID)?.title != "Must not be saved")
    do {
      _ = try NotebookReadBasis.merging([frozen, withExtent(current.revision)])
      Issue.record("Two different item extents must not merge")
    } catch let error as CollaborationError { #expect(error.code == "basis_conflict") }
  }
}
