import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Agent spatial operations read their UUIDs, not their whole surfaces", .serialized)
struct NotebookAgentSpatialProjectionTests {
  private func fixture(_ body: (NotebookStore, UUID, NotebookWorkspaceHeader) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-spatial-projection-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    try body(store, actor, store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194)))
  }

  private func address(_ id: UUID) -> String { "spatial-ink.json#/actions/@" + id.uuidString.lowercased() }
  private func span(_ surface: SurfaceID) -> SpatialInkSpan {
    .init(surface: surface, samples: [.init(point: .init(x: 20, y: 30),
      worldPoint: surface.kind == .board ? .init(x: 20, y: 30) : nil,
      timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
  }
  private func stroke(target: CollaborationTarget, id: UUID = UUID()) throws -> CollaborationOperation {
    var values: [String: JSONValue] = ["points": .array([.object(["x": .number(20), "y": .number(30)])])]
    if target.kind == .board { values["worldOrigin"] = try .encode(WorldPoint.zero) }
    return .init(kind: .appendInkStroke, target: target, id: id.uuidString, values: values)
  }
  private func action(_ operations: [CollaborationOperation], store: NotebookStore) throws -> CollaborationAction {
    let header = try store.workspaceHeader(), ink = try #require(header.spatialInkStamp)
    return try .init(summary: "Addressed stroke", expected: Set(operations.map(\.target)).map { target in
      let board = try #require(try store.readBoardNodeHeader(target.boardID ?? target.id))
      return .init(target: target, revision: board.board.stamp.revision, inkRevision: ink.revision)
    }, operations: operations)
  }

  @Test func appendUndoAndEchoDoNotDecodeOneHundredThousandEarlierContactsOnTheSameBoard() throws {
    try fixture { store, actor, header in
      let clock = VersionStamp(counter: 100_000, actor: actor), firstID = UUID()
      var corruptAddress = ""
      try store.commandTransaction {
        let database = store.currentSQL!
        for index in 0..<100_000 {
          let action = SpatialInkAction(id: index == 0 ? firstID : UUID(), tool: .pen,
            spans: [span(.board(header.rootBoardID))], stamp: .init(counter: UInt64(index + 1), actor: actor))
          let rows = try NotebookRecordCodec.encode(.encode(SpatialInkJournal(actions: [action], stamp: clock)), file: "spatial-ink.json")
          for row in rows where row.parent != nil {
            try store.writeFragment(row.replacing(value: row.value, position: row.collection == "actions" ? index : 0), database: database)
          }
          if index == 50_000 { corruptAddress = address(action.id) }
        }
        let root = try #require(try store.storedFragments(address: "spatial-ink.json#", descendants: false).first)
        try store.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(clock))), database: database)
      }
      // Finish canonical seeding (including derived reference indexes) before
      // poisoning an unrequested body. The probe belongs to the later command.
      try store.commandTransaction {
        let database = store.currentSQL!
        let hash = try database.putBlob(Data("Unrequested same-surface action must not be decoded".utf8))
        try database.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(corruptAddress)])
      }
      let first = try store.storedFragments(address: address(firstID)), cursor = try store.currentChangeCursor()
      let target = CollaborationTarget(kind: .board, id: header.rootBoardID)
      let contribution = try action([stroke(target: target), stroke(target: target)], store: store)
      let committed = try bounded(store) { try store.applyCollaborationAction(contribution, actor: UUID()) }
      #expect(committed.action == contribution)
      let ids = contribution.operations.compactMap { $0.id.flatMap(UUID.init(uuidString:)) }
      let rowsBeforeUndo = try ids.map { try store.storedFragments(address: address($0)) }
      let undone = try bounded(store) { try store.undoCollaborationAction(committed.id, actor: UUID()) }
      #expect(undone.undo?.restored == 2)
      for (id, before) in zip(ids, rowsBeforeUndo) {
        let rows = try store.storedFragments(address: address(id))
        let stored = try NotebookRecordCodec.decode(rows, root: address(id)).decode(SpatialInkAction.self)
        #expect(!stored.isActive)
        #expect(rows.first { $0.collection == "spans" } == before.first { $0.collection == "spans" })
      }
      let afterUndo = try store.currentChangeCursor()
      let echo = try bounded(store) { try store.applyCollaborationAction(contribution, actor: actor) }
      #expect(echo == undone)
      #expect(try store.currentChangeCursor() == afterUndo)
      #expect(try store.storedFragments(address: address(firstID)) == first)
      let changed = try store.readChangedAddresses(after: cursor, through: afterUndo)
      let inkAddresses = Set(changed.addresses.filter { $0.hasPrefix("spatial-ink.json#") })
      #expect(inkAddresses == Set(["spatial-ink.json#"] + ids.flatMap { [address($0), address($0) + "/spans"] }))
      let count = try store.sqlRead { try $0.rows("SELECT count(*) FROM records WHERE parent='spatial-ink.json#' AND collection='actions'").first![0].integer }
      #expect(count == 100_002)
    }
  }

  @Test func aStrokeUUIDAlreadyOnAnotherSurfaceIsRejectedWithoutRewritingThatOwner() throws {
    try fixture { store, actor, header in
      let itemID = try #require(try store.readItemHeaders(limit: 1).first?.id)
      let existing = SpatialInkAction(tool: .pen, spans: [span(.cover(itemID))], stamp: .init(counter: 1, actor: actor))
      _ = try store.commitSpatialInk(.append(existing, journalStamp: existing.stamp))
      let before = try store.storedFragments(address: address(existing.id)), cursor = try store.currentChangeCursor()
      let operation = try stroke(target: .init(kind: .board, id: header.rootBoardID), id: existing.id)
      let contribution = try action([operation], store: store)
      do { _ = try store.applyCollaborationAction(contribution, actor: UUID()); Issue.record("A foreign stroke UUID was reused") }
      catch let error as CollaborationError { #expect(error.code == "invalid_operation") }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.storedFragments(address: address(existing.id)) == before)
      #expect(try store.collaborationActions().isEmpty)
    }
  }

  private final class SQLCounter { var steps = 0 }
  private func bounded<T>(_ store: NotebookStore, _ operation: () throws -> T) throws -> T {
    let counter = SQLCounter()
    let result = try withExtendedLifetime(counter) {
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
    print("AGENT_SPATIAL_ADDRESSED foreign_same_surface_actions=100000 vm=\(counter.steps)")
    return result
  }
}
