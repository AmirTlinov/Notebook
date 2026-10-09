import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Native item births use one addressed, finite accepted command", .serialized)
struct NotebookNativeItemCreationTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-item-" + UUID().uuidString)
    let actor = UUID()
    let store: NotebookStore
    let header: NotebookWorkspaceHeader
    init(hasPresence: Bool = true) throws {
      store = .init(root: root)
      header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      if hasPresence {
        try store.savePresence(.init(boardID: header.rootBoardID, mode: .board, camera: .init(),
          viewport: .init(x: 1194, y: 834)))
      }
    }
    func plan(_ kind: NotebookNativeItemCreation.Kind) throws -> NotebookNativeItemCreation {
      try .init(kind: kind, workspaceID: header.workspaceID, boardID: header.rootBoardID,
        center: .init(x: 1200, y: 300), actor: actor)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func headlessBirthCommitsWithoutCreatingHumanPresence() throws {
    let f = try Fixture(hasPresence: false); defer { f.clean() }
    let plan = try f.plan(.board), command = plan.command()
    let witnesses = NotebookAcceptedWriteWitnesses(root: f.root)
    let accepted = NotebookAcceptedWrite(witnesses: witnesses) { try command.apply(to: $0) }
    let result = try accepted.apply(to: f.store)
    #expect(result.receipt.id == plan.actionID && result.sources.first?.itemID == plan.itemID)
    #expect(result.sources.first?.selectedPresence == nil)
    #expect(try f.store.readItemHeader(plan.itemID)?.kind == .board)
    #expect(try f.store.ownerBoardID(of: plan.itemID) == f.header.rootBoardID)
    #expect(try f.store.readPresenceIfAvailable() == nil)
    #expect(try f.store.nativeHistory(domain: .cover(plan.itemID), actor: f.actor) == [.command(plan.actionID)])
    try witnesses.flush(in: f.store)
    let cursor = try f.store.currentChangeCursor()
    #expect(try accepted.apply(to: f.store).receipt == result.receipt)
    #expect(try f.store.currentChangeCursor() == cursor)
  }

  @Test func allThreeKindsKeepTheirActualOwnersPresenceAndColdUndoRedoIdentity() throws {
    for kind: NotebookNativeItemCreation.Kind in [.notebook(.init(width: 1024, height: 1366)), .document(.book), .board] {
      print("NATIVE_BIRTH kind=\(kind.itemKind.rawValue) cold_undo_redo=started")
      let f = try Fixture(); defer { f.clean() }
      let plan = try f.plan(kind), output = try plan.command().apply(to: f.store)
      #expect(plan.nativeHistoryDomains == output.receipt.action.nativeHistoryDomains,
        "Admission and the durable birth retain the same history owners")
      let source = try #require(output.sources.first)
      let header = try f.store.readItemHeader(plan.itemID), presence = try f.store.loadPresence()
      #expect(header?.kind == kind.itemKind && presence.selectedItemID == plan.itemID)
      #expect(source.itemID == plan.itemID && output.receipt.id == plan.actionID)
      if let page = plan.pageID {
        let stored = try f.store.loadPage(page)
        #expect(stored.size == PageSize(width: 1024, height: 1366))
      }
      if case .document(let template) = kind {
        let document = try f.store.loadDocument(plan.itemID)
        #expect(document.files.sorted { $0.id < $1.id } == template.files.sorted { $0.id < $1.id })
      }
      for domain in output.receipt.action.nativeHistoryDomains {
        let entries = try f.store.nativeHistory(domain: domain, actor: f.actor)
        #expect(entries == [.command(plan.actionID)])
      }
      let cold = NotebookStore(root: f.root), undone = try cold.undoNativeAction(plan.actionID, actor: f.actor)
      let removed = try cold.readItemHeader(plan.itemID)
      #expect(removed == nil && undone.undo?.preserved.isEmpty == true)
      #expect(try cold.ownerBoardID(of: plan.itemID) == nil)
      if let page = plan.pageID { #expect(try !cold.hasStoredValue(pageFile(page))) }
      if kind.itemKind == .document {
        #expect(try !cold.hasStoredValue(documentFile(plan.itemID)) && !cold.hasStoredValue(stateFile(plan.itemID)))
      }
      if kind.itemKind == .board { #expect(try cold.readBoardNode(plan.itemID) == nil) }
      try cold.collaborationContent().validate()
      let parent = CollaborationTarget(kind: .board, id: f.header.rootBoardID)
      _ = try cold.applyNativeAction(.init(summary: "Peer writes surviving parent", expected: [
        .init(target: parent, revision: try cold.targetContentRevision(target: parent))], operations: [
          .init(kind: .insertElement, target: parent, id: "independent-peer", values: [
            "kind": .string("web"), "source": .string("<button>Keep peer</button>"),
            "frame": try .encode(PageRect(x: 20, y: 20, width: 180, height: 60)), "worldOrigin": try .encode(WorldPoint.zero)])]), actor: UUID())
      let peer = try cold.readSpatialElement(boardID: f.header.rootBoardID, elementID: "independent-peer")
      let redo = try cold.redoNativeAction(plan.actionID, actionID: UUID(), actor: f.actor)
      let restored = try cold.readItemHeader(plan.itemID)
      #expect(restored?.kind == kind.itemKind && restored?.firstPageID == plan.pageID)
      #expect(redo.redoOf == plan.actionID)
      #expect(try cold.ownerBoardID(of: plan.itemID) == f.header.rootBoardID)
      #expect(try cold.workspaceHeader().itemCount == f.header.itemCount + 1)
      #expect(try cold.readSpatialElement(boardID: f.header.rootBoardID, elementID: "independent-peer") == peer)
      try cold.collaborationContent().validate()
      print("NATIVE_BIRTH kind=\(kind.itemKind.rawValue) cold_undo_redo=first_cycle peer_parent=preserved")
      let reopened = NotebookStore(root: f.root)
      _ = try reopened.undoNativeAction(redo.id, actor: f.actor)
      #expect(try reopened.readItemHeader(plan.itemID) == nil && reopened.ownerBoardID(of: plan.itemID) == nil)
      _ = try reopened.redoNativeAction(redo.id, actionID: UUID(), actor: f.actor)
      #expect(try reopened.readItemHeader(plan.itemID)?.firstPageID == plan.pageID)
      #expect(try reopened.ownerBoardID(of: plan.itemID) == f.header.rootBoardID)
      #expect(try reopened.readSpatialElement(boardID: f.header.rootBoardID, elementID: "independent-peer") == peer)
      try reopened.collaborationContent().validate()
      print("NATIVE_BIRTH kind=\(kind.itemKind.rawValue) cold_undo_redo=2_cycles peer_parent=preserved")
    }
  }

  @Test func coldUndoKeepsPeerAdoptedOwnersAndRejectsRedoWithoutDuplicatingThem() throws {
    for kind: NotebookNativeItemCreation.Kind in [.notebook(.init(width: 834, height: 1194)), .document(.book), .board] {
      let f = try Fixture(); defer { f.clean() }
      let plan = try f.plan(kind)
      _ = try plan.command().apply(to: f.store)
      let target: CollaborationTarget, operation: CollaborationOperation
      switch kind {
      case .notebook:
        target = .init(kind: .page, id: plan.pageID!)
        operation = .init(kind: .insertElement, target: target, id: "peer-answer", values: [
          "kind": .string("web"), "source": .string("<button>Peer answer</button>"),
          "frame": try .encode(PageRect(x: 20, y: 20, width: 180, height: 60))])
      case .document:
        target = .init(kind: .document, id: plan.itemID)
        operation = .init(kind: .putDocumentFile, target: target, id: "peer-answer", values: [
          "path": .string("peer.tex"), "source": .string("Peer answer"), "expectedVersion": .null])
      case .board:
        target = .init(kind: .board, id: plan.itemID)
        operation = .init(kind: .insertElement, target: target, id: "peer-answer", values: [
          "kind": .string("web"), "source": .string("<button>Peer answer</button>"),
          "frame": try .encode(PageRect(x: 20, y: 20, width: 180, height: 60)), "worldOrigin": try .encode(WorldPoint.zero)])
      }
      let adoption = CollaborationAction(summary: "Peer adopts new owner",
        expected: [.init(target: target, revision: try f.store.targetContentRevision(target: target))],
        operations: [operation])
      _ = try f.store.applyCollaborationActionImmediately(adoption, actor: UUID(), requestFingerprint: nil, human: true)
      let cold = NotebookStore(root: f.root)
      let before = try cold.collaborationContent(), undone = try cold.undoNativeAction(plan.actionID, actor: f.actor)
      #expect(undone.undo?.preserved.isEmpty == false)
      #expect(try cold.readItemHeader(plan.itemID) != nil && cold.ownerBoardID(of: plan.itemID) == f.header.rootBoardID)
      let after = try cold.collaborationContent()
      #expect(after.workspace.items == before.workspace.items)
      #expect(after.pages == before.pages && after.documents == before.documents && after.states == before.states && after.hierarchy == before.hierarchy)
      try after.validate()
      let cursor = try cold.currentChangeCursor(), read = try cold.currentReadCursor()
      #expect(throws: CollaborationError.self) {
        _ = try cold.redoNativeAction(plan.actionID, actionID: UUID(), actor: f.actor)
      }
      #expect(try cold.currentChangeCursor() == cursor && cold.currentReadCursor() == read)
    }
  }

  @Test func unknownCommitKeepsItsExactBirthResultAfterAnIndependentPeerMove() throws {
    enum Lost: Error { case completion }
    let f = try Fixture(); defer { f.clean() }
    let plan = try f.plan(.document(.article)), command = plan.command()
    let fault = NotebookStore(root: f.root) { if $0 == .afterCommit { throw Lost.completion } }
    #expect(throws: Lost.self) { _ = try command.apply(to: fault) }
    let born = try #require(try f.store.collaborationActionIfPresent(plan.actionID))
    let node = try #require(try f.store.readBoardItem(plan.itemID))
    let moved = try NotebookNativeCommand([.init(kind: .moveItem, target: .init(kind: .board, id: f.header.rootBoardID),
      id: plan.itemID.uuidString, values: ["center": try .encode(WorldPoint(x: -900, y: 800))])], summary: "Peer move",
      placements: node.board.placements, actor: UUID()).apply(to: f.store)
    let cursor = try f.store.currentChangeCursor(), read = try f.store.currentReadCursor()
    let retry = try command.apply(to: NotebookStore(root: f.root))
    let current = try f.store.readBoardItem(plan.itemID)?.board.placement(of: plan.itemID)?.center
    #expect(retry.receipt == born && retry.sources.first?.itemID == plan.itemID)
    #expect(current == moved.sources.first?.pose?.center && current == WorldPoint(x: -900, y: 800))
    #expect(try f.store.currentChangeCursor() == cursor)
    #expect(try f.store.currentReadCursor() == read)
  }

  @Test func retainedCreationCannotUseItsCopiedReceiptInAReplacedWorkspace() throws {
    let f = try Fixture(); defer { f.clean() }
    let plan = try f.plan(.board), command = plan.command(), saved = try command.apply(to: f.store)
    try f.store.commandTransaction {
      try f.store.currentSQL!.run("UPDATE metadata SET value=? WHERE key='workspace_id'", [.text(UUID().uuidString.lowercased())])
    }
    let cursor = try f.store.currentChangeCursor(), read = try f.store.currentReadCursor()
    #expect(throws: NotebookStoreError.self) { _ = try command.apply(to: f.store) }
    #expect(try f.store.currentChangeCursor() == cursor && f.store.currentReadCursor() == read)
    try f.store.commandTransaction {
      try f.store.currentSQL!.run("UPDATE metadata SET value=? WHERE key='workspace_id'", [.text(f.header.workspaceID.uuidString.lowercased())])
    }
    let resumed = try command.apply(to: f.store)
    #expect(resumed.receipt == saved.receipt && resumed.sources == saved.sources)
  }

  @Test func oneBirthOnOneHundredThousandNeighboursDoesNotDecodeTheHeavyUpperNeighbour() throws {
    let f = try Fixture(); defer { f.clean() }
    let board = f.header.rootBoardID, boardAddress = "board.json#/boards/@" + board.uuidString.lowercased()
    var upperAddress = ""
    // Fixture construction is outside the command's read/codec allowance.
    // Every item, empty child board and placement uses the canonical row owner.
    try f.store.commandTransaction {
      let database = f.store.currentSQL!
      for position in 1...100_000 {
        let id = UUID(), item = WorkspaceItem(id: id, kind: .board, title: "", pageIDs: [])
        let itemRows = try NotebookRecordCodec.encode(.object(["items": .array([try .encode(item)])]), file: "workspace.json")
        for row in itemRows where row.collection == "items" {
          try f.store.writeFragment(row.replacing(value: row.value, position: position), database: database)
        }
        let child = BoardNode(id: id, board: .initial(itemIDs: [], actor: f.actor))
        let childRows = try NotebookRecordCodec.encode(.object(["boards": .array([try .encode(child)])]), file: "board.json")
        for row in childRows where row.collection == "boards" { try f.store.writeFragment(row, database: database) }
        let placement = WorkspacePlacement(itemID: id, heads: [.init(pose: .init(center: .init(x: Double(position) * 1500, y: 0),
          zIndex: position), version: .init(stamp: .init(counter: UInt64(position), actor: f.actor), human: true))])
        let placementRows = try NotebookRecordCodec.encode(.object(["boards": .array([.object([
          "id": .string(board.uuidString.lowercased()), "board": .object(["placements": .array([try .encode(placement)])])])])]), file: "board.json")
        for row in placementRows where row.collection == "board/placements" {
          try f.store.writeFragment(row, database: database); upperAddress = row.address
        }
      }
      let clock = try JSONValue.encode(VersionStamp(counter: 100_001, actor: f.actor))
      for address in ["workspace.json#", "board.json#", boardAddress] {
        let root = try #require(try f.store.storedFragments(address: address, descendants: false).first)
        let value = address == boardAddress ? root.value.setting("board", root.value["board"]!.setting("stamp", clock))
          : root.value.setting("stamp", clock)
        try f.store.writeFragment(root.replacing(value: value), database: database)
      }
    }
    var heavyHash = ""
    try f.store.commandTransaction {
      heavyHash = try f.store.currentSQL!.putBlob(Data(repeating: 0x78, count: 4 * 1_024 * 1_024))
      try f.store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(heavyHash), .text(upperAddress)])
    }
    let counter = FrontierCounter(), plan = try f.plan(.board), start = ContinuousClock.now
    let result = try f.store.commandTransaction {
      let database = f.store.currentSQL!
      sqlite3_trace_v2(database.handle, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, _ in
        guard let context, let statement else { return 0 }
        let stmt = OpaquePointer(statement), sql = sqlite3_sql(stmt).map { String(cString: $0) } ?? ""
        if sql.hasPrefix("SELECT z_index FROM spatial_entries INDEXED BY spatial_item_order") {
          Unmanaged<FrontierCounter>.fromOpaque(context).takeUnretainedValue().steps += Int(sqlite3_stmt_status(stmt, SQLITE_STMTSTATUS_VM_STEP, 1))
        }
        return 0
      }, Unmanaged.passUnretained(counter).toOpaque())
      defer { sqlite3_trace_v2(database.handle, 0, nil, nil) }
      return try plan.command().apply(to: f.store)
    }
    let placed = try f.store.readBoardItem(plan.itemID)?.board.placement(of: plan.itemID)?.zIndex
    let hash = try f.store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(upperAddress)]).first?[0].text }
    #expect(result.sources.first?.itemID == plan.itemID && placed == 100_001)
    #expect(hash == heavyHash && counter.steps > 0 && counter.steps < 128)
    print("NATIVE_ITEM_CREATION neighbours=100000 frontier_vm=\(counter.steps) birth_elapsed=\(start.duration(to: .now)) finish_credit=\(plan.cost.completionBytes) upper_body_bytes=4194304 upper_body_unchanged=true")
  }
}

private final class FrontierCounter { var steps = 0 }
