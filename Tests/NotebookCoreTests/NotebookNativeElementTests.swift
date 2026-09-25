import Foundation
import Testing
@testable import NotebookCore

@Suite("Addressed native element commands")
struct NotebookNativeElementTests {
  private func fixture(id: String = "editor", kind: SpatialElementKind = .nativeText, _ body: (NotebookStore, UUID, UUID, SpatialElement) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let index = try store.loadIndex(), before = try store.loadBoard(items: index.items)
    let element = SpatialElement(id: id, surface: .cover(index.items[0].id), kind: kind,
      frame: .init(x: 10, y: 20, width: 200, height: 90), source: "original", stamp: .init(counter: 0, actor: actor))
    var after = before
    _ = after.upsertElement(element, in: header.rootBoardID, expected: nil, actor: actor)
    _ = try store.saveBoardEdits(before: before, after: after)
    try body(store, actor, header.rootBoardID, element)
  }

  @Test func spatialProgramCommitBorrowsLargeStateAdmissionAndRejectsSourceABA() throws {
    try fixture(kind: .web) { store, actor, boardID, rendered in
      let originalBasis = try #require(store.loadBoard(items: store.loadIndex().items).board(boardID)?.programStateBasis(rendered.id))
      let payload = String(repeating: "😀", count: 1_400_000) // More than 5 MiB UTF-8.
      let large: JSONValue = .string("first" + payload)
      let admission = try JSONEncoder().encode(.string("checkpoint" + payload) as JSONValue).count * 8 + 64
      let first = try #require(try store.commitSpatialElementState(boardID: boardID, rendered: rendered,
        state: large, actor: actor, expectedProgramBasis: originalBasis, admittedStateBytes: admission))
      #expect(first.element.state == large)
      #expect(first.basis.hasSameSource(as: originalBasis))
      let cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.limitExceeded("program_state_admission")) {
        try store.commitSpatialElementState(boardID: boardID, rendered: first.element,
          state: .number(2), actor: actor, expectedProgramBasis: originalBasis, admittedStateBytes: 1)
      }
      #expect(try store.currentChangeCursor() == cursor)
      // A queued explicit commit keeps its captured program source but may
      // follow a newer state from this same program. Old-state credit is held
      // through this large -> scalar transfer, not reserved a second time.
      let secondValue: JSONValue = .string("second" + payload)
      let second = try #require(try store.commitSpatialElementState(boardID: boardID, rendered: first.element,
        state: secondValue, actor: actor, expectedProgramBasis: originalBasis, admittedStateBytes: admission))
      #expect(second.element.state == secondValue)
      #expect(second.basis.hasNewerState(than: first.basis))
      let checkpointValue: JSONValue = .string("checkpoint" + payload)
      let checkpointElement = AgentElement(id: rendered.id, kind: .web,
        frame: .init(x: 0, y: 0, width: rendered.frame.width, height: rendered.frame.height),
        source: rendered.source, html: rendered.html, state: secondValue)
      let checkpointBasis = try #require(try store.checkpointProgramState(target: .init(kind: .board, id: boardID),
        rendered: checkpointElement, state: checkpointValue, basis: second.basis, actor: actor, admittedStateBytes: admission))
      #expect(checkpointBasis.hasNewerState(than: second.basis))
      #expect(try store.checkpointProgramState(target: .init(kind: .board, id: boardID),
        rendered: checkpointElement, state: .null, basis: second.basis, actor: actor, admittedStateBytes: admission) == nil)
      let reopened = NotebookStore(root: store.root)
      #expect(try reopened.readSpatialElement(boardID: boardID, elementID: rendered.id)?.state == checkpointValue)
      let reopenedBasis = try #require(reopened.loadBoard(items: reopened.loadIndex().items).board(boardID)?.programStateBasis(rendered.id))
      #expect(reopenedBasis == checkpointBasis)
      // The next FIFO event still uses the original source basis, not a stale
      // state fence, and can replace a large saved snapshot with a scalar.
      let scalar = try #require(try store.commitSpatialElementState(boardID: boardID, rendered: first.element,
        state: .number(2), actor: actor, expectedProgramBasis: originalBasis, admittedStateBytes: admission))
      #expect(scalar.element.state == .number(2))
      for source in ["different program", rendered.source] {
        let before = try store.loadBoard(items: store.loadIndex().items)
        var element = try #require(before.board(boardID)?.element(id: rendered.id))
        let stamp = element.stamp
        let changed = element.update(source: source, actor: actor)
        #expect(changed)
        var after = before
        let updated = after.upsertElement(element, in: boardID, expected: stamp, actor: actor)
        #expect(updated)
        _ = try store.saveBoardEdits(before: before, after: after)
      }
      let afterABA = try store.currentChangeCursor()
      #expect(throws: CollaborationError.self) {
        try store.commitSpatialElementState(boardID: boardID, rendered: rendered,
          state: .number(3), actor: actor, expectedProgramBasis: originalBasis, admittedStateBytes: admission)
      }
      #expect(try store.currentChangeCursor() == afterABA)
      let current = try #require(store.loadBoard(items: store.loadIndex().items).board(boardID)?.programStateBasis(rendered.id))
      #expect(!current.hasSameSource(as: originalBasis))
      let accepted = try #require(try store.commitSpatialElementState(boardID: boardID, rendered: rendered,
        state: .number(3), actor: actor, expectedProgramBasis: current, admittedStateBytes: admission))
      #expect(accepted.element.state == .number(3))
    }
  }

  @Test func spatialProgramCommitRejectsIdenticalDeletionAndRecreation() throws {
    try fixture(kind: .web) { store, actor, boardID, rendered in
      let before = try store.loadBoard(items: store.loadIndex().items)
      let basis = try #require(before.board(boardID)?.programStateBasis(rendered.id))
      var removed = before
      let removedCount = removed.removeElements(ids: [rendered.id], from: boardID, actor: actor)
      #expect(removedCount == 1)
      _ = try store.saveBoardEdits(before: before, after: removed)
      #expect(try store.commitSpatialElementState(boardID: boardID, rendered: rendered,
        state: .number(1), actor: actor, expectedProgramBasis: basis) == nil)
      var recreated = removed
      let inserted = recreated.upsertElement(rendered, in: boardID, expected: nil, actor: actor)
      #expect(inserted)
      _ = try store.saveBoardEdits(before: removed, after: recreated)
      let cursor = try store.currentChangeCursor()
      #expect(throws: CollaborationError.self) {
        try store.commitSpatialElementState(boardID: boardID, rendered: rendered,
          state: .number(2), actor: actor, expectedProgramBasis: basis)
      }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.readSpatialElement(boardID: boardID, elementID: rendered.id)?.state == rendered.state)
    }
  }

  @Test func everySpatialProgramWriteReturnsItsExactDurableCheckpointBasis() throws {
    try fixture(kind: .web) { store, actor, board, original in
      var element = original
      let basis = try #require(store.loadBoard(items: store.loadIndex().items).board(board)?.programStateBasis(element.id))
      var receipts: [NotebookSpatialProgramStateReceipt] = []
      for value in [1.0, 2.0, 1.0] {
        let receipt = try #require(try store.commitSpatialElementState(boardID: board, rendered: element,
          state: .number(value), actor: actor, expectedProgramBasis: basis))
        element = receipt.element; receipts.append(receipt)
        let rendered = AgentElement(id: element.id, kind: .web,
          frame: .init(x: 0, y: 0, width: element.frame.width, height: element.frame.height),
          source: element.source, html: element.html, state: element.state)
        // No intervening projection read/reload supplies authority to this checkpoint.
        #expect(try store.checkpointProgramState(target: .init(kind: .board, id: board), rendered: rendered,
          state: element.state, basis: receipt.basis, actor: actor) == receipt.basis)
      }
      #expect(receipts[0].element.state == receipts[2].element.state)
      #expect(receipts[0].basis != receipts[2].basis, "An A→B→A receipt cannot adopt a later state clock")
    }
  }

  @Test func spatialProgramCheckpointCommitsOnlyItsExpectedSourceAndState() throws {
    try fixture(kind: .web) { store, actor, board, element in
      let rendered = AgentElement(id: element.id, kind: .web,
        frame: .init(x: 0, y: 0, width: element.frame.width, height: element.frame.height),
        source: element.source, html: element.html, state: element.state)
      let target = CollaborationTarget(kind: .board, id: board)
      func basis() throws -> NotebookProgramStateBasis {
        guard let value = try store.loadBoard(items: store.loadIndex().items).board(board)?.programStateBasis(element.id) else {
          throw CocoaError(.coderValueNotFound)
        }
        return value
      }
      let originalBasis = try basis()
      #expect(try store.checkpointProgramState(target: target, rendered: rendered, state: .number(0.25), basis: originalBasis, actor: actor) != nil)
      #expect(try store.readSpatialElement(boardID: board, elementID: element.id)?.state == .number(0.25))
      #expect(try store.checkpointProgramState(target: target, rendered: rendered, state: .number(0.5), basis: originalBasis, actor: actor) == nil)
      #expect(try store.checkpointProgramState(target: target, rendered: rendered.updating(state: .number(0.25)),
        state: .number(0.75), basis: basis(), actor: actor) != nil)
      let cursor = try store.currentChangeCursor()
      #expect(try store.checkpointProgramState(target: target, rendered: rendered.updating(state: .number(0.75)),
        state: .number(0.75), basis: basis(), actor: actor) != nil)
      #expect(try store.currentChangeCursor() == cursor, "Identical checkpoint has no new write")
    }
  }

  @Test func spatialCheckpointRejectsReplacedThenRestoredProgram() throws {
    try fixture(kind: .web) { store, actor, boardID, element in
      let original = try #require(store.loadBoard(items: store.loadIndex().items).board(boardID)?.programStateBasis(element.id))
      let rendered = AgentElement(id: element.id, kind: .web,
        frame: .init(x: 0, y: 0, width: element.frame.width, height: element.frame.height), source: element.source, html: element.html)
      for source in ["different program", element.source] {
        let before = try store.loadBoard(items: store.loadIndex().items)
        var current = try #require(before.board(boardID)?.elements.first { $0.id == element.id })
        let stamp = current.stamp
        let changed = current.update(source: source, actor: actor)
        #expect(changed)
        var after = before
        let updated = after.upsertElement(current, in: boardID, expected: stamp, actor: actor)
        #expect(updated)
        _ = try store.saveBoardEdits(before: before, after: after)
      }
      let latest = try #require(store.loadBoard(items: store.loadIndex().items).board(boardID)?.programStateBasis(element.id))
      #expect(!latest.hasSameSource(as: original))
      let cursor = try store.currentChangeCursor()
      #expect(try store.checkpointProgramState(target: .init(kind: .board, id: boardID), rendered: rendered,
        state: .number(0.5), basis: original, actor: actor) == nil)
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func AddressedElementIDsNormalizeOnlyUUIDsAndKeepCaseSensitiveNames() throws {
    for id in [UUID().uuidString, "CamelCaseElement"] {
      try fixture(id: id) { store, actor, board, element in
        #expect(try store.readSpatialElement(boardID: board, elementID: id) == element)
        let window = try store.readSceneWindow(boardID: board, bounds: .init(origin: .zero, width: 1, height: 1), limit: 2, pinnedElementIDs: [id])
        #expect(window.boards[0].board.elements.map(\.id) == [id])
        #expect(try updateTestNativeText(store:store,boardID: board, elementID: id, text: "changed", finish: false, actor: actor)?.source == "changed")
        if UUID(uuidString: id) == nil { #expect(try store.readSpatialElement(boardID: board, elementID: id.lowercased()) == nil) }
      }
    }
  }

  @Test func finishingTextWorksWithoutAMountedOwnerAndLateInputCannotRecreateIt() throws {
    try fixture { store, actor, board, _ in
      let start = try store.currentChangeCursor()
      let updated = try updateTestNativeText(store:store,boardID: board, elementID: "editor", text: "after navigation", finish: true, actor: actor)
      #expect(updated?.source == "after navigation")
      #expect(try store.readSpatialElement(boardID: board, elementID: "editor") == updated)
      _ = try updateTestNativeText(store:store,boardID: board, elementID: "editor", text: "", finish: false, actor: actor)
      #expect(try store.readSpatialElement(boardID: board, elementID: "editor")?.source == "")
      #expect(try updateTestNativeText(store:store,boardID: board, elementID: "editor", text: "", finish: true, actor: actor) == nil)
      let deleted = try store.currentChangeCursor()
      #expect(try updateTestNativeText(store:store,boardID: board, elementID: "editor", text: "late", finish: true, actor: actor) == nil)
      #expect(try store.currentChangeCursor() == deleted)
      let addresses = try store.readChangedAddresses(after: start, through: deleted, limit: 1)
      #expect(addresses.addresses.count == 1 && addresses.hasMore)
    }
  }

  @Test func stateReadsCurrentGeometryAndRejectsAnOldProgram() throws {
    try fixture(kind: .web) { store, actor, board, rendered in
      let index = try store.loadIndex(), before = try store.loadBoard(items: index.items)
      let basis = try #require(before.board(board)?.programStateBasis(rendered.id))
      var current = try #require(try store.readSpatialElement(boardID: board, elementID: rendered.id))
      let frame = SpatialRect(x: 70, y: 80, width: 240, height: 100)
      _ = current.update(frame: frame, actor: UUID())
      var moved = before
      _ = moved.upsertElement(current, in: board, expected: rendered.stamp, actor: actor)
      _ = try store.saveBoardEdits(before: before, after: moved)
      let state: JSONValue = .object(["value": .number(19)])
      let committed = try store.commitSpatialElementState(boardID: board, rendered: rendered, state: state, actor: actor, expectedProgramBasis: basis)
      #expect(committed?.element.state == state && committed?.element.frame == frame)
      let sourceBefore = try store.loadBoard(items: index.items)
      var changedProgram = try #require(sourceBefore.board(board)?.elements.first { $0.id == rendered.id })
      let sourceStamp = changedProgram.stamp
      let sourceChanged = changedProgram.update(source: "new source", actor: actor)
      #expect(sourceChanged)
      var sourceAfter = sourceBefore
      let sourceUpdated = sourceAfter.upsertElement(changedProgram, in: board, expected: sourceStamp, actor: actor)
      #expect(sourceUpdated)
      _ = try store.saveBoardEdits(before: sourceBefore, after: sourceAfter)
      let cursor = try store.currentChangeCursor()
      #expect(throws: CollaborationError.self) { try store.commitSpatialElementState(boardID: board, rendered: rendered, state: .number(20), actor: actor, expectedProgramBasis: basis) }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func frameCommitKeepsCurrentSourceAndCannotRecreateADeletedSpatialElement() throws {
    try fixture { store, actor, boardID, element in
      let target = CollaborationTarget(kind:.cover,id:try #require(element.surface.ownerID),boardID:boardID)
      let original = NotebookNativeElementSource(target:target,id:element.id,spatial:element)
      _ = try updateTestNativeText(store:store,boardID:boardID,elementID:element.id,text:"Concurrent source",finish:false,actor:UUID())
      let frame = PageRect(x:60,y:70,width:200,height:90)
      #expect(throws:CollaborationError.self) { try moveTestElement(store:store,source:original,frame:frame,actor:actor) }
      let current = try #require(try store.readSpatialElement(boardID:boardID,elementID:element.id))
      let moved = try moveTestElement(store:store,source:.init(target:target,id:element.id,spatial:current),frame:frame,actor:actor)
      #expect(moved.spatial?.frame == SpatialRect(x:60,y:70,width:200,height:90) && moved.spatial?.source == "Concurrent source")
      _ = try updateTestNativeText(store:store,boardID:boardID,elementID:element.id,text:"",finish:true,actor:actor)
      let cursor = try store.currentChangeCursor()
      #expect(throws:CollaborationError.self) { try moveTestElement(store:store,source:moved,frame:frame,actor:actor) }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try NotebookStore(root: store.root).readSpatialElement(boardID: boardID, elementID: element.id) == nil)
    }
  }

  @Test func offscreenPinsRetainTheirCarrierAndRejectAnInsufficientBudget() throws {
    try fixture { store, actor, board, element in
      let owner = try #require(element.surface.ownerID)
      #expect(try moveTestItem(store: store, itemID: owner, in: board, to: .init(x: 50_000, y: 60_000), actor: actor))
      let bounds = WorkspaceSpatialBounds(origin: .init(x: -100, y: -100), width: 200, height: 200)
      let window = try store.readSceneWindow(boardID: board, bounds: bounds, limit: 2, pinnedElementIDs: [element.id])
      #expect(window.items.map(\.id) == [owner])
      #expect(window.boards[0].board.elements.map(\.id) == [element.id])
      #expect(window.boards[0].board.collaboration?.fields["elements/editor/exists"] != nil)
      #expect(window.totalMatches == 2)
      #expect(throws: NotebookStorageError.limitExceeded("scene_pins")) {
        try store.readSceneWindow(boardID: board, bounds: bounds, limit: 1, pinnedElementIDs: [element.id])
      }
      #expect(throws: CollaborationError.self) {
        try moveTestItem(store: store, itemID: owner, in: UUID(), to: .zero, actor: actor)
      }
    }
  }

  @Test func changedRecordsBindBothHistoricalVersionsIncludingTombstones() throws {
    try fixture { store, actor, board, _ in
      let start = try store.currentChangeCursor()
      let address = "board.json#/boards/@" + board.uuidString.lowercased() + "/board/elements/@editor"
      let original = try #require(try store.currentRecordHash(address))
      _ = try updateTestNativeText(store:store,boardID: board, elementID: "editor", text: "updated", finish: false, actor: actor)
      let updatedCursor = try store.currentChangeCursor(), updated = try #require(try store.currentRecordHash(address))
      _ = try updateTestNativeText(store:store,boardID: board, elementID: "editor", text: "", finish: true, actor: actor)
      let deletedCursor = try store.currentChangeCursor()
      let historical = try #require(try store.readChangedAddresses(after: start, through: updatedCursor).records.first { $0.address == address })
      #expect(historical.beforeHash == original && historical.afterHash == updated)
      let removed = try #require(try store.readChangedAddresses(after: updatedCursor, through: deletedCursor).records.first { $0.address == address })
      #expect(removed.beforeHash == updated && removed.afterHash == nil)
      let creation = try #require(try store.readChangedAddresses(after: 0, through: start).records.first { $0.address == address })
      #expect(creation.beforeHash == nil && creation.afterHash == original)
    }
  }
}

private extension NotebookStore {
  func currentRecordHash(_ address: String) throws -> String? {
    try sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text }
  }
}

func updateTestNativeText(store: NotebookStore, boardID: UUID, elementID: String, text: String,
  finish: Bool, actor: UUID) throws -> SpatialElement? {
  guard let element = try store.readSpatialElement(boardID:boardID,elementID:elementID), element.kind == .nativeText else { return nil }
  let target = CollaborationTarget(kind:element.surface.kind == .cover ? .cover : .board,
    id:element.surface.kind == .cover ? element.surface.ownerID! : boardID,boardID:element.surface.kind == .cover ? boardID : nil)
  let remove = finish && text.isEmpty
  let result = try store.applyNativeElementEdits([.init(kind:remove ? .removeElement : .updateElement,target:target,id:elementID,
    values:remove ? [:] : ["source":.string(text),"html":.string(text)])],summary:"Test text edit",
    sources:[.init(target:target,id:elementID,spatial:element)],actor:actor)
  return result.sources.first?.spatial
}

/// Exercise the application's sole addressed geometry writer.
@discardableResult
func moveTestElement(store:NotebookStore,source:NotebookNativeElementSource,frame:PageRect,actor:UUID) throws -> NotebookNativeElementSource {
  let result=try store.applyNativeElementEdits([.init(kind:.updateElement,target:source.target,id:source.id,
    values:["frame":try .encode(frame)])],summary:"Test element move",sources:[source],actor:actor)
  return try #require(result.sources.first)
}

/// Fixture setup uses the same native action as a physical drop, not a direct
/// placement writer which omits history and captured-source validation.
@discardableResult
func moveTestItem(store: NotebookStore, itemID: UUID, in boardID: UUID,
  to center: WorldPoint, actor: UUID) throws -> Bool {
  let sources = try #require(try store.readBoardItem(itemID)).board.placements
  let command = NotebookNativeCommand([.init(kind: .moveItem, target: .init(kind: .board, id: boardID),
    id: itemID.uuidString, values: ["center": try .encode(center)])], summary: "Test item move",
    placements: sources, actor: actor)
  _ = try command.apply(to: store)
  return true
}
