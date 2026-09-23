import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Code contacts share one durable file history", .serialized)
struct NotebookCodeInkHistoryTests {
  private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-history-" + UUID().uuidString)
    let actor = UUID(), computer = UUID()
    var store: NotebookStore { .init(root: root) }
    init() throws { _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194)) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String) -> NotebookFileAddress { .init(computer: computer, project: "demo", root: "/code", path: name) }
    func fragment(_ file: NotebookFileAddress, offset: Int = 0) -> NotebookCodeFragment {
      .init(file: file, sourceHash: NotebookFileVersion.hash(Data("code".utf8)), utf16Offset: offset, text: "code",
        width: 600, height: 100, fontSize: 15, stamp: .init(counter: 1, actor: actor))
    }
    @discardableResult
    func append(_ fragment: NotebookCodeFragment, counter: UInt64) throws -> SpatialInkAction {
      let action = SpatialInkAction(tool: .pen, color: .init(red: 0.25, green: 0.5, blue: 0.75),
        spans: [.init(surface: .codeFragment(fragment.id), samples: [.init(point: .init(x: 20, y: 30),
          timeOffset: 0, width: 3, opacity: 0.4, force: 0.8, azimuth: 0.2, altitude: 1)])],
        stamp: .init(counter: counter, actor: actor))
      _ = try store.commitCodeInk(fragment: fragment, command: .append(action, journalStamp: action.stamp))
      return action
    }
    func inverse(_ file: NotebookFileAddress, active: Bool, counter: UInt64) throws -> NotebookSpatialInkCommand {
      let history = try store.codeInkHistory(file: file, actor: actor)
      let entry = try #require((active ? history.redo : history.undo).last)
      let id: UUID
      switch entry {
      case .ink(let ids), .inkRedo(let ids, _): id = try #require(ids.first)
      default: throw NotebookStorageError.invalidTransaction("expected code contact")
      }
      let state = try #require(history.states[id]).result, stamp = VersionStamp(counter: counter, actor: actor)
      return .state(actionID: id, creationStamp: state.creationStamp, expectedStateStamp: state.stateStamp,
        isActive: active, stateStamp: stamp, journalStamp: stamp, nativeRedo: active)
    }
  }

  @Test func coldHistoryOrdersFragmentsByAcceptedContactsAndKeepsOtherFilesAndMeasurements() throws {
    let f = try Fixture(), a = f.file("a.py"), b = f.file("b.py")
    let first = f.fragment(a), second = f.fragment(a, offset: 10), other = f.fragment(b)
    let x = try f.append(first, counter: 2), y = try f.append(second, counter: 3)
    let z = try f.append(first, counter: 4), untouched = try f.append(other, counter: 5)
    let domain = PencilUndoHistory.Domain.codeFile(a)
    #expect(try f.store.nativeHistory(domain: domain, actor: f.actor) == [.ink([x.id]), .ink([y.id]), .ink([z.id])])
    #expect(try f.store.nativeHistory(domain: .init(.init(kind: .codeFragment, id: first.id)), actor: f.actor).isEmpty)
    let snapshot = try f.store.codeInkHistory(file: a, actor: f.actor)
    #expect(snapshot.states.count == 3)
    #expect(snapshot.stamp == untouched.stamp)
    #expect(snapshot.states.values.allSatisfy { $0.result.journalStamp == snapshot.stamp })
    var clock: UInt64 = 10
    for _ in 0..<2 {
      for id in [z.id, y.id, x.id] {
        let command = try f.inverse(a, active: false, counter: clock); clock += 1
        #expect(command.expectedResult.actionID == id)
        _ = try f.store.commitSpatialInk(command)
        let cursor = try f.store.currentChangeCursor()
        _ = try f.store.commitSpatialInk(command)
        #expect(try f.store.currentChangeCursor() == cursor)
      }
      for id in [x.id, y.id, z.id] {
        let command = try f.inverse(a, active: true, counter: clock); clock += 1
        #expect(command.expectedResult.actionID == id)
        _ = try f.store.commitSpatialInk(command)
      }
    }
    for (fragment, actions) in [(first, [x, z]), (second, [y]), (other, [untouched])] {
      let stored = try #require(try f.store.codeAnnotation(fragment.id))
      #expect(stored.fragment == fragment)
      for source in actions {
        let action = try #require(stored.ink.actions.first { $0.id == source.id })
        #expect(action.isActive && action.spans == source.spans && action.color == source.color)
      }
    }
    let alien = NotebookFileAddress(computer: UUID(), project: a.project, root: a.root, path: a.path)
    #expect(try f.store.codeInkHistory(file: alien, actor: f.actor).undo.isEmpty)
  }

  @Test func newContactAndSameValuedPeerStateInvalidateOnlyTheOldRedo() throws {
    let f = try Fixture(), file = f.file("gate.py"), fragment = f.fragment(file)
    let first = try f.append(fragment, counter: 2)
    _ = try f.store.commitSpatialInk(f.inverse(file, active: false, counter: 3))
    let stale = try f.inverse(file, active: true, counter: 10)
    let later = try f.append(fragment, counter: 4)
    #expect(try f.store.codeInkHistory(file: file, actor: f.actor).redo.isEmpty)
    #expect(throws: CollaborationError.self) { try f.store.commitSpatialInk(stale) }
    #expect(try f.store.codeAnnotation(fragment.id)?.ink.actions.filter(\.isActive).map(\.id) == [later.id])
    _ = try f.store.commitSpatialInk(f.inverse(file, active: false, counter: 11))
    let peer = UUID()
    var gate = VersionStamp(counter: 11, actor: f.actor)
    for (counter, active) in [(12, true), (13, false)] {
      let next = VersionStamp(counter: UInt64(counter), actor: peer)
      _ = try f.store.publishSpatialInk(.state(actionID: later.id, creationStamp: later.stamp,
        expectedStateStamp: gate, isActive: active, stateStamp: next, journalStamp: next), origin: .replication)
      gate = next
    }
    #expect(try f.store.codeInkHistory(file: file, actor: f.actor).redo.isEmpty)
    #expect(try f.store.codeAnnotation(fragment.id)?.ink.actions.first { $0.id == first.id }?.isActive == false)
  }

  @Test func historyReadsOnlyAddressedHeadersAndUsesCurrentBindingForNewContacts() throws {
    let f = try Fixture(), a = f.file("before.py"), b = f.file("after.py")
    let fragment = f.fragment(a), first = try f.append(fragment, counter: 2)
    let rebound = try f.store.rebindCodeFragment(fragment.id, expected: fragment.location, to: f.fragment(b), actor: f.actor)
    let later = try f.append(fragment, counter: 5) // late Pencil cannot restore the old file binding
    #expect(try f.store.codeInkHistory(file: a, actor: f.actor).undo.isEmpty)
    #expect(try f.store.codeInkHistory(file: b, actor: f.actor).undo == [.ink([later.id])])
    #expect(try f.store.codeFragment(fragment.id) == rebound)
    // Damage only the measurements in this isolated fixture: a history read
    // must neither open them nor treat their immutable bytes as an Undo order.
    try f.store.commandTransaction {
      let db = f.store.currentSQL!, address = "spatial-ink.json#/actions/@" + later.id.uuidString.lowercased() + "/spans"
      let record = try #require(try f.store.storedFragments(address: address, descendants: false).first)
      let bytes = try NotebookStore.storageEncoder.encode(record.replacing(value: .string("not measurements")))
      let hash = try db.putBlob(bytes)
      try db.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)])
    }
    let history = try f.store.codeInkHistory(file: b, actor: f.actor)
    #expect(history.states[later.id]?.fragmentID == fragment.id)
    #expect(history.states[first.id] == nil)
  }
  @Test(arguments: [NotebookStorageFault.beforeCommit, .afterCommit])
  func failedInverseRetriesTheSameGateWithoutRepeatingHistory(_ fault: NotebookStorageFault) throws {
    enum Failure: Error { case disk }
    let f = try Fixture(), file = f.file("retry.py"), fragment = f.fragment(file)
    let action = try f.append(fragment, counter: 2)
    for (active, counter) in [(false, UInt64(3)), (true, UInt64(4))] {
      let command = try f.inverse(file, active: active, counter: counter)
      let broken = NotebookStore(root: f.root) { point in if point == fault { throw Failure.disk } }
      #expect(throws: Failure.self) { try broken.commitSpatialInk(command) }
      _ = try f.store.commitSpatialInk(command)
      let cursor = try f.store.currentChangeCursor()
      _ = try f.store.commitSpatialInk(command)
      #expect(try f.store.currentChangeCursor() == cursor)
      let history = try f.store.codeInkHistory(file: file, actor: f.actor)
      #expect(history.undo == (active ? [.ink([action.id])] : []))
      #expect(history.redo.count == (active ? 0 : 1))
      let stored = try #require(try f.store.codeAnnotation(fragment.id)?.ink.actions.first)
      #expect(stored.isActive == active && stored.spans == action.spans)
    }
  }

  @Test func historyAmongOneHundredThousandCodeFragmentsReadsOnlyItsBoundedHeads() throws {
    let f = try Fixture(), file = f.file("large.py"), template = f.fragment(file)
    let start = ContinuousClock.now
    var selected: [NotebookCodeFragment] = []
    try f.store.commandTransaction {
      let db = f.store.currentSQL!
      for index in 0..<100_000 {
        let fragment = NotebookCodeFragment(file: file, sourceHash: template.sourceHash, utf16Offset: index,
          text: template.text, width: template.width, height: template.height, fontSize: template.fontSize, stamp: template.stamp)
        for record in try NotebookRecordCodec.encode(.encode(fragment), file: codeFragmentFile(fragment.id)) {
          try f.store.writeFragment(record, database: db)
        }
        if index < 33 { selected.append(fragment) }
      }
    }
    #expect(try f.store.sqlRead { try $0.rows("SELECT count(*) FROM code_fragment_files").first?[0].integer } == 100_000)
    var actions: [SpatialInkAction] = []
    for (index, fragment) in selected.enumerated() { actions.append(try f.append(fragment, counter: UInt64(index + 2))) }
    print("CODE_HISTORY_SCALE seeded=100000 elapsed=\(start.duration(to: .now))")
    final class Counter { var steps = 0 }
    let counter = Counter(), db = try NotebookSQLConnection(url: f.store.databaseURL, writable: true)
    sqlite3_progress_handler(db.handle, 1, { raw in
      let counter = Unmanaged<Counter>.fromOpaque(raw!).takeUnretainedValue()
      counter.steps += 1; return counter.steps > 200_000 ? 1 : 0
    }, Unmanaged.passUnretained(counter).toOpaque())
    defer { sqlite3_progress_handler(db.handle, 0, nil, nil) }
    let measured = ContinuousClock.now
    let history = try f.store.commandTransaction(preparedDatabase: db) { try f.store.codeInkHistory(file: file, actor: f.actor) }
    #expect(history.undo == actions.suffix(32).map { .ink([$0.id]) })
    #expect(history.states.count == 32 && history.states[actions[0].id] == nil)
    #expect(counter.steps < 200_000, "A file's Undo does not scan every review fragment")
    print("CODE_HISTORY_SCALE heads=32 vm_steps=\(counter.steps) elapsed=\(measured.duration(to: .now))")
  }

}
