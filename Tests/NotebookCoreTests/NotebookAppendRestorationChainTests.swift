import Foundation
import Testing
@testable import NotebookCore

@Suite("Append ownership follows authenticated deletion restoration", .serialized)
struct NotebookAppendRestorationChainTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("append-restoration-chain-\(UUID())")
    var store: NotebookStore
    let agent = UUID(), boardID = UUID(), itemID = UUID(), documentID = UUID(), firstPageID = UUID(), appendedPageID = UUID()

    init() throws {
      store = NotebookStore(root: root)
      let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
      let parent = CollaborationTarget(kind: .board, id: header.rootBoardID)
      let board = CollaborationTarget(kind: .board, id: boardID)
      try create([.init(kind: .createBoard, target: parent, id: boardID.uuidString,
        values: ["title": .string("Isolated lifecycle board"), "center": try .encode(WorldPoint.zero)])], on: parent)
      try create([
        .init(kind: .createNotebook, target: board, id: itemID.uuidString,
          values: ["title": .string("Appended notebook"), "center": try .encode(WorldPoint.zero), "pageID": try .encode(firstPageID)]),
        .init(kind: .createDocument, target: board, id: documentID.uuidString,
          values: ["title": .string("Sibling document"), "center": try .encode(WorldPoint(x: 800, y: 0)),
            "paperSize": .string("a4"), "blocks": .array([])])
      ], on: board)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func create(_ operations: [CollaborationOperation], on board: CollaborationTarget) throws {
      let header = try store.workspaceHeader()
      let basis = try store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
      _ = try store.applyCollaborationAction(.init(summary: "Create isolated lifecycle fixture", expected: basis.owners,
        operations: operations), actor: agent)
    }

    func lifecycle(_ ids: [UUID], append: Bool = false) throws -> CollaborationReceipt {
      var command = NotebookCommand(command: .read); command.readSnapshots = true
      command.queries = try ids.map { id in
        try JSONValue.object(["kind": .string("itemLifecycle"), "id": try .encode(id)]).decode(NotebookReadQuery.self)
      }
      let snapshots = try NotebookCommandDispatcher(store: store).handle(command).array
      let basis = try NotebookReadBasis.merging(snapshots.map { try #require($0["basis"]).decode(NotebookReadBasis.self) })
      let targets = try snapshots.map { try #require($0["data"]?["target"]).decode(CollaborationTarget.self) }
      let operations = targets.map { target in
        CollaborationOperation(kind: append ? .appendPage : .deleteItem, target: target,
          id: append ? appendedPageID.uuidString : nil)
      }
      return try store.applyCollaborationAction(.init(additionalOwners: targets, summary: append ? "Append own page" : "Delete explicit owners",
        expected: store.expectations(base: basis, operations: operations), operations: operations), actor: agent)
    }

    func deleteAndRestore(_ ids: [UUID]) throws {
      let deleted = try lifecycle(ids)
      for id in ids { #expect(try store.readItemHeader(id) == nil) }
      store = NotebookStore(root: root)
      let restored = try store.undoCollaborationAction(deleted.id, actor: agent)
      #expect(restored.undo?.lifecycleChanges?.filter { $0.kind == .restoreItem }.count == ids.count)
      #expect(restored.undo?.preservedLifecycle?.isEmpty ?? true)
      store = NotebookStore(root: root)
      for id in ids { #expect(try store.readItemHeader(id) != nil) }
    }

    var membershipKey: String { fieldKey(["items", itemID.uuidString.lowercased(), "pageIDs", appendedPageID.uuidString.lowercased()]) }
    func membershipVersion() throws -> ContentFieldVersion {
      let address = "workspace.json#/collaboration/fields/@" + fieldKey([membershipKey])
      return try #require(try store.storedFragments(address: address, descendants: false).first).value.decode(ContentFieldVersion.self)
    }

    func sourceHashes() throws -> [String: String] {
      try store.readTransaction { store in
        let rows = try store.currentSQL!.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(pageFile(appendedPageID))])
        return Dictionary(uniqueKeysWithValues: rows.map { ($0[0].text!, $0[1].text!) })
      }
    }

    func membershipIsStillOwned(_ birth: ContentFieldVersion) throws -> Bool {
      try store.readTransaction { _ in
        try store.fieldIsOwned(membershipVersion(), by: .init(file: "workspace.json",
          path: [.field("collaboration"), .field("fields"), .field(membershipKey)], before: nil, after: nil, afterVersion: birth))
      }
    }
  }

  @Test(arguments: [0, 1, 2])
  func appendUndoFollowsMembershipRestorationWithoutTreatingItAsAdoption(restorationCount: Int) throws {
    let f = try Fixture(), appended = try f.lifecycle([f.itemID], append: true)
    let birth = try f.membershipVersion(), source = try f.sourceHashes()
    #expect(!source.isEmpty)
    if restorationCount >= 1 { try f.deleteAndRestore([f.itemID]) }
    if restorationCount >= 2 { try f.deleteAndRestore([f.itemID, f.documentID, f.boardID]) }
    #expect(try f.sourceHashes() == source, "No PAGE source or causal field was edited by the intervening actions")
    if restorationCount > 0 {
      #expect(try f.membershipVersion() != birth, "Restoration must author a fresh membership dot, never replay the birth clock")
    }
    #expect(try f.membershipIsStillOwned(birth), "Existing authenticated receipt evidence already proves the restored birth owner")
    let undone = try f.store.undoCollaborationAction(appended.id, actor: f.agent)
    #expect(undone.undo?.preservedLifecycle?.isEmpty ?? true)
    #expect(undone.undo?.lifecycleChanges?.contains { $0.kind == .removePage && $0.pageID == f.appendedPageID } == true)
    #expect(try f.store.readItemHeader(f.itemID)?.pageCount == 1)
    #expect(try f.store.ownerItemID(ofPage: f.appendedPageID) == nil)
    #expect(try !f.store.hasStoredValue(pageFile(f.appendedPageID)))
    #expect(try f.store.pageID(at: 0, in: f.itemID) == f.firstPageID)
  }

  @Test func aRealLaterAgentSourceEditStillAdoptsTheRestoredPage() throws {
    let f = try Fixture(), appended = try f.lifecycle([f.itemID], append: true)
    let birth = try f.membershipVersion()
    try f.deleteAndRestore([f.itemID])
    let target = CollaborationTarget(kind: .page, id: f.appendedPageID)
    let basis = try f.store.readBasis(targets: [target])
    _ = try f.store.applyCollaborationAction(.init(summary: "A real later agent continuation", expected: basis.owners,
      operations: [.init(kind: .insertElement, target: target, id: "later-label",
        values: ["kind": .string("markdown"), "source": .string("Keep this later action"),
          "frame": try .encode(PageRect(x: 0, y: 0, width: 100, height: 80))])]), actor: f.agent)
    let source = try f.sourceHashes()
    #expect(try f.membershipIsStillOwned(birth), "Membership restoration does not establish ownership of later page content")
    let undone = try f.store.undoCollaborationAction(appended.id, actor: f.agent)
    #expect(undone.undo?.preservedLifecycle == appended.lifecycleChanges?.map(\.target))
    #expect(try f.sourceHashes() == source)
    #expect(try f.store.readItemHeader(f.itemID)?.pageCount == 2)
  }

  @Test(arguments: [false, true])
  func anUnattestedObservationOrLosingHeadDoesNotBorrowTheRestoredWinner(frontier: Bool) throws {
    let f = try Fixture(), appended = try f.lifecycle([f.itemID], append: true)
    let birth = try f.membershipVersion()
    try f.deleteAndRestore([f.itemID])
    let before = try f.membershipVersion(), source = try f.sourceHashes()
    let foreign = UUID()
    let continued: ContentFieldVersion
    if frontier {
      continued = try before.joining(.init(stamp: .init(counter: before.stamp.counter + 1, actor: foreign), human: false))
    } else {
      var observed = before.observed; observed[foreign.uuidString.lowercased()] = 0
      continued = .init(stamp: before.stamp, human: before.human, observed: observed)
    }
    #expect(continued.isValid && continued.stamp == before.stamp && continued.human == before.human)
    #expect(continued != before)
    // A typed causal boundary fixture, not a new user mutation API: a joined
    // losing head/observation must not inherit this inverse's attestation.
    try f.store.commandTransaction {
      let address = "workspace.json#/collaboration/fields/@" + fieldKey([f.membershipKey])
      let row = try #require(try f.store.storedFragments(address: address, descendants: false).first)
      try f.store.writeFragment(row.replacing(value: try .encode(continued)), database: f.store.currentSQL!)
    }
    #expect(try f.membershipIsStillOwned(birth), "The ordinary winner-only predicate is deliberately insufficient for destructive undo")
    let undone = try f.store.undoCollaborationAction(appended.id, actor: f.agent)
    #expect(undone.undo?.preservedLifecycle == appended.lifecycleChanges?.map(\.target))
    #expect(try f.membershipVersion() == continued)
    #expect(try f.sourceHashes() == source)
    #expect(try f.store.readItemHeader(f.itemID)?.pageCount == 2)
  }
}
