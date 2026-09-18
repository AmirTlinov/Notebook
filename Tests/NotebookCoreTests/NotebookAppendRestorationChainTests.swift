import Foundation
import Testing
@testable import NotebookCore

@Suite("Append ownership follows authenticated deletion restoration", .serialized)
struct NotebookAppendRestorationChainTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("append-restoration-chain-\(UUID())")
    var store: NotebookStore
    var boardCreation: CollaborationReceipt?
    var childrenCreation: CollaborationReceipt?
    let agent = UUID(), boardID = UUID(), itemID = UUID(), documentID = UUID(), firstPageID = UUID(), appendedPageID = UUID()

    init() throws {
      store = NotebookStore(root: root)
      let header = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
      let parent = CollaborationTarget(kind: .board, id: header.rootBoardID)
      let board = CollaborationTarget(kind: .board, id: boardID)
      boardCreation = try create([.init(kind: .createBoard, target: parent, id: boardID.uuidString,
        values: ["title": .string("Isolated lifecycle board"), "center": try .encode(WorldPoint.zero)])], on: parent)
      childrenCreation = try create([
        .init(kind: .createNotebook, target: board, id: itemID.uuidString,
          values: ["title": .string("Appended notebook"), "center": try .encode(WorldPoint.zero), "pageID": try .encode(firstPageID)]),
        .init(kind: .createDocument, target: board, id: documentID.uuidString,
          values: ["title": .string("Sibling document"), "center": try .encode(WorldPoint(x: 800, y: 0)),
            "paperSize": .string("a4"), "blocks": .array([])])
      ], on: board)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func create(_ operations: [CollaborationOperation], on board: CollaborationTarget) throws -> CollaborationReceipt {
      let header = try store.workspaceHeader()
      let basis = try store.readBasis(targets: [board, .init(kind: .workspace, id: header.rootBoardID)])
      return try store.applyCollaborationAction(.init(summary: "Create isolated lifecycle fixture", expected: basis.owners,
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

    func sourceHashes(_ pageID: UUID? = nil) throws -> [String: String] {
      try store.readTransaction { store in
        let rows = try store.currentSQL!.rows("SELECT address,hash FROM records WHERE file=? ORDER BY address", [.text(pageFile(pageID ?? appendedPageID))])
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

  @Test(arguments: ["none", "delete", "rename", "append", "move", "full", "reindex"])
  func creationUndoAfterItsOwnReversedContinuationsRemovesBothUnadoptedChildren(continuation: String) throws {
    let f = try Fixture(), creation = try #require(f.childrenCreation)
    let originalHeader = try f.store.readItemHeader(f.itemID), source = try f.sourceHashes(f.firstPageID)
    var reposition: CollaborationReceipt?
    if ["rename", "move", "full", "reindex"].contains(continuation) {
      let target = CollaborationTarget(kind: .board, id: f.boardID)
      let cover = CollaborationTarget(kind: .cover, id: f.itemID, boardID: f.boardID)
      let basis = try f.store.readBasis(targets: [target, .init(kind: .workspace, id: f.store.workspaceHeader().rootBoardID)])
      var operations: [CollaborationOperation] = []
      if continuation != "move" {
        operations.append(.init(kind: .renameItem, target: target, id: f.itemID.uuidString, values: ["title": .string("Own later title")]))
      }
      if continuation != "rename" {
        operations.append(.init(kind: .moveItem, target: target, id: f.itemID.uuidString,
          values: ["center": try .encode(WorldPoint(x: 400, y: 300))]))
      }
      reposition = try f.store.applyCollaborationAction(.init(additionalOwners: [cover], summary: "Own later title and placement",
        expected: basis.owners, operations: operations), actor: f.agent)
    }
    let append = ["append", "full", "reindex"].contains(continuation) ? try f.lifecycle([f.itemID], append: true) : nil
    if ["delete", "full", "reindex"].contains(continuation) { try f.deleteAndRestore([f.itemID]) }
    if ["full", "reindex"].contains(continuation) {
      try f.deleteAndRestore([f.documentID])
      try f.deleteAndRestore([f.itemID, f.documentID, f.boardID])
    }
    if let append {
      let result = try f.store.undoCollaborationAction(append.id, actor: f.agent)
      #expect(result.undo?.preservedLifecycle?.isEmpty ?? true)
      #expect(result.undo?.lifecycleChanges?.contains { $0.kind == .removePage && $0.pageID == f.appendedPageID } == true)
    }
    if let reposition {
      let result = try f.store.undoCollaborationAction(reposition.id, actor: f.agent)
      #expect(result.undo?.preserved.isEmpty == true)
    }
    f.store = NotebookStore(root: f.root)
    if continuation == "reindex" {
      try f.store.commandTransaction {
        let receipts = try f.store.storedValues(prefix: "collaboration/actions/").map { try $0.decode(CollaborationReceipt.self) }
          .sorted { $0.createdAt < $1.createdAt }
        try f.store.currentSQL!.run("DELETE FROM action_field_restorations")
        // Original action order is deliberately the reverse of undo dependency
        // order. This disposable index must not require ancestors to be ready.
        for receipt in receipts {
          try f.store.indexFieldRestorations(receipt, address: "collaboration/actions/" + receipt.id.uuidString.lowercased() + ".json#",
            database: f.store.currentSQL!)
        }
      }
    }
    #expect(try f.store.readItemHeader(f.itemID) == originalHeader)
    #expect(try f.sourceHashes(f.firstPageID) == source, "The original PAGE has never received a content or causal edit")
    let itemPath: [CollaborationPathComponent] = [.field("items"), .member(f.itemID.uuidString.lowercased())]
    let itemChange = try #require(creation.changes.first { $0.file == "workspace.json" && $0.path == itemPath })
    let placement = try #require(creation.changes.first { $0.file == "board.json" && $0.path.last == .member(f.itemID.uuidString.lowercased()) })
    try f.store.readTransaction { store in
      let workspace = try store.storedValue("workspace.json"), board = try store.storedValue("board.json")
      let existence = collaborationFieldVersion(file: workspace, path: itemChange.path)
      #expect(try store.fieldIsOwned(existence, by: itemChange), "Every intervening existence write was explicitly undone")
      #expect(try store.placementIsOwned(board?.value(at: placement.path[...]), after: placement.after,
        file: placement.file, path: placement.path), "Every intervening placement write was explicitly undone")
    }
    let undone = try f.store.undoCollaborationAction(creation.id, actor: f.agent)
    #expect(undone.undo?.preserved.contains {
      $0.file == pageFile(f.firstPageID) || ($0.file == "workspace.json" && $0.path == itemPath)
        || ($0.file == placement.file && $0.path == placement.path)
    } == false)
    #expect(try f.store.readItemHeader(f.itemID) == nil)
    #expect(try f.store.readItemHeader(f.documentID) == nil)
    #expect(try f.store.ownerItemID(ofPage: f.firstPageID) == nil)
    #expect(try !f.store.hasStoredValue(pageFile(f.firstPageID)))
    let boardCreation = try #require(f.boardCreation)
    _ = try f.store.undoCollaborationAction(boardCreation.id, actor: f.agent)
    #expect(try f.store.readItemHeader(f.boardID) == nil, "The explicitly undone child creations do not adopt their empty parent")
  }

  @Test(arguments: [false, true])
  func anImplicitRestorationCannotLaunderAnAdditionalObservationOrHead(frontier: Bool) throws {
    let f = try Fixture(), creation = try #require(f.childrenCreation)
    let target = CollaborationTarget(kind: .board, id: f.boardID)
    let basis = try f.store.readBasis(targets: [target, .init(kind: .workspace, id: f.store.workspaceHeader().rootBoardID)])
    let renamed = try f.store.applyCollaborationAction(.init(summary: "Own title edit", expected: basis.owners,
      operations: [.init(kind: .renameItem, target: target, id: f.itemID.uuidString, values: ["title": .string("Later")])]), actor: f.agent)
    _ = try f.store.undoCollaborationAction(renamed.id, actor: f.agent)
    let itemPath: [CollaborationPathComponent] = [.field("items"), .member(f.itemID.uuidString.lowercased())]
    let change = try #require(creation.changes.first { $0.file == "workspace.json" && $0.path == itemPath })
    try f.store.commandTransaction {
      let key = fieldKey(["items", f.itemID.uuidString.lowercased(), "exists"])
      let row = try #require(try f.store.storedFragments(address: "workspace.json#/collaboration/fields/@" + fieldKey([key]), descendants: false).first)
      let previous = try row.value.decode(ContentFieldVersion.self), foreign = UUID()
      let current: ContentFieldVersion
      if frontier {
        current = try previous.joining(.init(stamp: .init(counter: previous.stamp.counter + 1, actor: foreign), human: false))
      } else {
        var observed = previous.observed; observed[foreign.uuidString.lowercased()] = 0
        current = .init(stamp: previous.stamp, human: previous.human, observed: observed)
      }
      #expect(current.isValid && current.stamp == previous.stamp && current.human == previous.human && current != previous)
      try f.store.writeFragment(row.replacing(value: try .encode(current)), database: f.store.currentSQL!)
      #expect(try !f.store.fieldIsOwned(current, by: change), "A conditional inverse owns the complete written version, not just its winner")
    }
    _ = try f.store.undoCollaborationAction(creation.id, actor: f.agent)
    #expect(try f.store.readItemHeader(f.itemID) != nil)
    #expect(try f.store.ownerItemID(ofPage: f.firstPageID) == f.itemID)
  }
}
