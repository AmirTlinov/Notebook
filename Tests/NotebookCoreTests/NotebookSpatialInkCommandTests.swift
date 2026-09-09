import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Spatial contacts publish addressed immutable actions", .serialized)
struct NotebookSpatialInkCommandTests {
  private enum InjectedFailure: Error { case disk }

  private func fixture(_ body: (NotebookStore, UUID, NotebookWorkspaceHeader) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-action-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    try body(store, actor, store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194)))
  }

  private func span(_ surface: SurfaceID, x: Double = 2) -> SpatialInkSpan {
    .init(surface: surface, samples: [.init(point: .init(x: x, y: 3),
      worldPoint: surface.kind == .board ? .init(x: x, y: 3) : nil,
      timeOffset: 0, width: 4, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
  }

  private func state(_ action: SpatialInkAction, active: Bool = false, counter: UInt64,
    journalCounter: UInt64? = nil) -> NotebookSpatialInkCommand {
    .state(actionID: action.id, creationStamp: action.stamp, isActive: active,
      stateStamp: .init(counter: counter, actor: action.stamp.actor),
      journalStamp: .init(counter: journalCounter ?? counter, actor: action.stamp.actor))
  }

  private func actionAddress(_ id: UUID) -> String { "spatial-ink.json#/actions/@" + id.uuidString.lowercased() }
  private func hash(_ address: String, store: NotebookStore) throws -> String? {
    try store.sqlRead { try $0.rows("SELECT hash FROM records WHERE address=?", [.text(address)]).first?[0].text }
  }

  @Test func firstAppendStoresOneMultiSurfaceActionAndUndoNeverRepublishesSpans() throws {
    try fixture { store, actor, header in
      let cover = try #require(try store.readWorkspaceItems(limit: 1).first?.id)
      let surfaces = [SurfaceID.board(header.rootBoardID), .cover(cover), .board(header.rootBoardID)]
      let action = SpatialInkAction(tool: .pen, spans: surfaces.enumerated().map { span($0.element, x: Double($0.offset)) },
        stamp: .init(counter: 1, actor: actor))
      // Also support a known workspace whose spatial journal has not been born.
      try store.commandTransaction { try store.removeFragment("spatial-ink.json#", database: store.currentSQL!) }
      let before = try store.currentChangeCursor()
      let appended = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      #expect(appended == NotebookSpatialInkCommand.append(action, journalStamp: action.stamp).expectedResult)
      let address = actionAddress(action.id), spansHash = try #require(try hash(address + "/spans", store: store))
      let first = try store.readChangedAddresses(after: before, through: store.currentChangeCursor())
      #expect(Set(first.addresses) == ["spatial-ink.json#", address, address + "/spans"])
      #expect(try store.readSpatialInk(surfaces: [surfaces[0], surfaces[1]]).actions == [action])
      let stamp = try store.currentChangeCursor()
      let undone = try store.commitSpatialInk(state(action, counter: 2))
      #expect(!undone.isActive)
      #expect(try hash(address + "/spans", store: store) == spansHash)
      let changes = try store.readChangedAddresses(after: stamp, through: store.currentChangeCursor())
      #expect(Set(changes.addresses) == ["spatial-ink.json#", address])
      let echoCursor = try store.currentChangeCursor()
      let echo = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      #expect(echo == undone)
      #expect(try store.currentChangeCursor() == echoCursor)
      let journal = try store.loadSpatialInk()
      #expect(journal.actions.count == 1 && !journal.actions[0].isActive)
      #expect(journal.actions[0].spans == action.spans)
    }
  }

  @Test func reverseArrivalUsesCreationStampActorAndUUIDWithoutRenumberingEarlierRows() throws {
    try fixture { store, _, header in
      let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
      let high = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
      let first = SpatialInkAction(id: low, tool: .pen, spans: [span(.board(header.rootBoardID))], stamp: .init(counter: 1, actor: high))
      let second = SpatialInkAction(id: high, tool: .eraser, spans: first.spans, stamp: .init(counter: 1, actor: low))
      let third = SpatialInkAction(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        tool: .pen, spans: first.spans, stamp: second.stamp)
      _ = try store.commitSpatialInk(.append(first, journalStamp: first.stamp))
      let oldHash = try hash(actionAddress(first.id), store: store)
      _ = try store.commitSpatialInk(.append(second, journalStamp: first.stamp))
      _ = try store.commitSpatialInk(.append(third, journalStamp: first.stamp))
      #expect(try hash(actionAddress(first.id), store: store) == oldHash)
      let order = [third.id, second.id, first.id]
      #expect(try store.loadSpatialInk().actions.map(\.id) == order)
      #expect(try store.storedValue("spatial-ink.json")?.decode(SpatialInkJournal.self).actions.map(\.id) == order)
      #expect(try store.readSpatialInk(surfaces: [.board(header.rootBoardID)]).actions.map(\.id) == order)
      _ = try store.commitSpatialInk(state(second, counter: 2))
      #expect(try store.loadSpatialInk().actions.map(\.id) == order)
      #expect(try store.readSpatialInk(surfaces: [.board(header.rootBoardID)]).actions.map(\.id) == order)
    }
  }

  @Test func identityConflictsAndUnknownOwnersCannotLeavePartialRows() throws {
    try fixture { store, actor, header in
      let action = SpatialInkAction(tool: .pen, spans: [span(.board(header.rootBoardID))], stamp: .init(counter: 1, actor: actor))
      _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      let before = try store.currentChangeCursor()
      let collision = SpatialInkAction(id: action.id, tool: .pen,
        spans: [span(.board(header.rootBoardID), x: 10)], stamp: action.stamp)
      #expect(throws: NotebookStorageError.transactionConflict) { try store.commitSpatialInk(.append(collision, journalStamp: collision.stamp)) }
      #expect(throws: NotebookStorageError.transactionConflict) { try store.commitSpatialInk(state(action, counter: 1)) }
      let missing = SpatialInkAction(tool: .pen, spans: [span(.board(header.rootBoardID)), span(.cover(UUID()))],
        stamp: .init(counter: 2, actor: actor))
      #expect(throws: CollaborationError.self) { try store.commitSpatialInk(.append(missing, journalStamp: missing.stamp)) }
      #expect(try hash(actionAddress(missing.id), store: store) == nil)
      #expect(try hash(actionAddress(missing.id) + "/spans", store: store) == nil)
      #expect(try store.currentChangeCursor() == before)
    }
  }

  @Test func deletedCoverRetainsOnlyItsExistingActionTombstoneNotNewInkOrResurrection() throws {
    try fixture { store, actor, header in
      let before = try store.loadIndex(), boardBefore = try store.loadBoard(items: before.items)
      var workspace = before, hierarchy = boardBefore
      let created = workspace.createNotebook(title: "Retained", actor: actor, pageSize: .init(width: 834, height: 1194))
      let replacement = try #require(created)
      let added = hierarchy.addItem(replacement.item.id, to: header.rootBoardID, near: .init(x: 2_000, y: 0), actor: actor)
      #expect(added)
      _ = try store.saveWorkspaceEdits(before: before, after: workspace, boardBefore: boardBefore,
        boardAfter: hierarchy, pages: [replacement.page])
      let deleted = before.selectedItemID, action = SpatialInkAction(tool: .pen,
        spans: [span(.board(header.rootBoardID)), span(.cover(before.selectedItemID))], stamp: .init(counter: 1, actor: actor))
      _ = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      _ = try store.deleteWorkspaceItem(itemID: deleted, actor: actor)
      _ = try store.commitSpatialInk(state(action, counter: 2))
      let echo = try store.commitSpatialInk(.append(action, journalStamp: action.stamp))
      #expect(!echo.isActive)
      #expect(throws: CollaborationError.self) { try store.commitSpatialInk(state(action, active: true, counter: 3)) }
      let next = SpatialInkAction(tool: .pen, spans: action.spans, stamp: .init(counter: 3, actor: actor))
      #expect(throws: CollaborationError.self) { try store.commitSpatialInk(.append(next, journalStamp: next.stamp)) }
      #expect(try store.readWorkspaceItem(deleted) == nil)
      let journal = try store.readSpatialInk(surfaces: [.board(header.rootBoardID), .cover(deleted)])
      #expect(journal.actions.count == 1 && !journal.actions[0].isActive)
      #expect(journal.actions[0].spans == action.spans)
    }
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func rollbackAndAmbiguousCommitRetryPreserveTheSameUUIDAndImmutableBlob(fault: NotebookStorageFault) throws {
    try fixture { store, actor, header in
      let action = SpatialInkAction(tool: .eraser, spans: [span(.board(header.rootBoardID))], stamp: .init(counter: 1, actor: actor))
      let command = NotebookSpatialInkCommand.append(action, journalStamp: action.stamp), before = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root) {
        if String(describing: $0) == String(describing: fault) { throw InjectedFailure.disk }
      }
      #expect(throws: InjectedFailure.self) { try failing.commitSpatialInk(command) }
      let afterCommit = String(describing: fault) == String(describing: NotebookStorageFault.afterCommit)
      #expect(try store.currentChangeCursor() == before + (afterCommit ? 1 : 0))
      #expect(try store.readSpatialInk(surfaces: [.board(header.rootBoardID)]).actions.count == (afterCommit ? 1 : 0))
      _ = try store.commitSpatialInk(command)
      #expect(try store.currentChangeCursor() == before + 1)
      let spans = try hash(actionAddress(action.id) + "/spans", store: store)
      #expect(throws: InjectedFailure.self) { try failing.commitSpatialInk(state(action, counter: 2)) }
      _ = try store.commitSpatialInk(state(action, counter: 2))
      #expect(try store.currentChangeCursor() == before + 2)
      #expect(try hash(actionAddress(action.id) + "/spans", store: store) == spans)
      #expect(try store.loadSpatialInk().actions.count == 1)
      #expect(try store.loadSpatialInk().actions[0].isActive == false)
    }
  }

  @Test func appendUndoAndEchoAmongOneHundredThousandOtherActionsStayAddressed() throws {
    try fixture { store, actor, header in
      let foreign = try #require(try store.readWorkspaceItems(limit: 1).first?.id)
      let clock = VersionStamp(counter: 100_000, actor: actor)
      let firstID = UUID()
      let seedStarted = ContinuousClock.now
      // Stream valid fragments through the ordinary row writer. The fixture's
      // whole transaction builds the reference index once, not 100000 archives.
      try store.commandTransaction {
        for position in 0..<100_000 {
          let action = SpatialInkAction(id: position == 0 ? firstID : UUID(), tool: .pen,
            spans: [span(.cover(foreign))], stamp: .init(counter: UInt64(position + 1), actor: actor))
          let rows = try NotebookRecordCodec.encode(.encode(SpatialInkJournal(actions: [action], stamp: clock)), file: "spatial-ink.json")
          for row in rows where row.parent != nil {
            try store.writeFragment(row.replacing(value: row.value, position: row.collection == "actions" ? position : 0), database: store.currentSQL!)
          }
        }
        let root = try #require(try store.storedFragments(address: "spatial-ink.json#", descendants: false).first)
        try store.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(clock))), database: store.currentSQL!)
      }
      print("SPATIAL_INK_SEED actions=100000 duration=\(seedStarted.duration(to: .now))")
      let addressedRead = try measured(store, phase: "descendant_read") {
        let rows = try store.storedFragments(address: actionAddress(firstID))
        #expect(Set(rows.map(\.address)) == [actionAddress(firstID), actionAddress(firstID) + "/spans"])
      }
      #expect(addressedRead < 1_000)
      let action = SpatialInkAction(tool: .pen, spans: [span(.board(header.rootBoardID))], stamp: .init(counter: 100_001, actor: actor))
      let before = try store.currentChangeCursor()
      let append = try measured(store, phase: "append") { try store.commitSpatialInk(.append(action, journalStamp: action.stamp)) }
      let undo = try measured(store, phase: "undo") { try store.commitSpatialInk(state(action, counter: 100_002)) }
      let afterUndo = try store.currentChangeCursor()
      let echo = try measured(store, phase: "echo") { try store.commitSpatialInk(.append(action, journalStamp: action.stamp)) }
      #expect(try store.currentChangeCursor() == afterUndo)
      #expect(try store.readSpatialInk(surfaces: [.board(header.rootBoardID)]).actions.map(\.id) == [action.id])
      #expect(try store.readChangedAddresses(after: before, through: afterUndo).records.count == 3)
      for count in [append, undo, echo] { #expect(count > 0 && count < 40_000) }
      print("SPATIAL_INK_SCALE foreign_actions=100000 append_steps=\(append) undo_steps=\(undo) echo_steps=\(echo)")
    }
  }

  private func measured<T>(_ store: NotebookStore, phase: String, _ operation: () throws -> T) throws -> Int {
    let counter = SQLCounter()
    defer { print("SPATIAL_INK_VM phase=\(phase) steps=\(counter.steps)") }
    try withExtendedLifetime(counter) {
      try store.commandTransaction {
        sqlite3_progress_handler(store.currentSQL!.handle, 1, { pointer in
          let value = Unmanaged<SQLCounter>.fromOpaque(pointer!).takeUnretainedValue()
          value.steps += 1
          return value.steps < 40_000 ? 0 : 1
        }, Unmanaged.passUnretained(counter).toOpaque())
        _ = try operation()
      }
    }
    return counter.steps
  }
}

private final class SQLCounter { var steps = 0 }
