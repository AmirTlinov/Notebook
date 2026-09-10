import CSQLite
import Foundation
import Testing
@testable import NotebookCore

@Suite("Native document state retains one accepted block", .serialized)
struct NotebookDocumentStateCommandTests {
  private func fixture(_ body: (NotebookStore, UUID, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-state-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    var index = try store.loadIndex(), tree = try store.loadBoard(items: index.items)
    let created = index.createDocument(title: "Programs", actor: actor)
    let item = try #require(created)
    let added = tree.addItem(item.id, to: header.rootBoardID, near: .zero, actor: actor)
    #expect(added)
    try store.saveDocumentWorkspaceBundle(index: index, document: .init(id: item.id, actor: actor,
      blocks: [.interactive(id: "body", html: "<button>+</button>")]),
      state: .init(id: item.id, actor: actor), board: tree)
    try body(store, actor, item.id)
  }

  private func command(_ journal: inout DocumentStateJournal, block: String = "body", value: JSONValue,
    actor: UUID, human: Bool = true) throws -> NotebookDocumentStateCommand {
    let accepted = journal.commit(blockID: block, value: value, actor: actor, human: human)
    #expect(accepted)
    return .init(documentID: journal.id, record: try #require(journal.records.first { $0.id == block }), journalStamp: journal.stamp)
  }

  @Test func oneBlockAmongOneHundredThousandRetiredValuesDoesNotReadOrRenumberThem() throws {
    try fixture { store, actor, id in
      let file = stateFile(id), rootAddress = file + "#", clock = VersionStamp(counter: 100_000, actor: actor)
      try store.commandTransaction {
        for index in 0..<100_000 {
          let record = DocumentStateRecord(id: "retired-\(index)", value: .number(Double(index)), stamp: clock)
          try store.writeFragment(.init(address: rootAddress + "/records/@" + record.id, file: file,
            parent: rootAddress, collection: "records", member: record.id, position: index,
            value: try .encode(record), collections: []), database: store.currentSQL!)
        }
        let root = try #require(store.storedFragments(address: rootAddress, descendants: false).first)
        try store.writeFragment(root.replacing(value: root.value.setting("stamp", try .encode(clock))), database: store.currentSQL!)
      }
      let kept = try store.storedFragments(address: rootAddress + "/records/@retired-75000")
      // After derived indexes exist, corrupt two bodies which the command has
      // no reason to read. A hidden full-file path must fail this test.
      try store.commandTransaction {
        let hash = try store.currentSQL!.putBlob(Data("unrequested state and source".utf8))
        for address in [rootAddress + "/records/@retired-50000", documentFile(id) + "#/blocks/@body"] {
          try store.currentSQL!.run("UPDATE records SET hash=? WHERE address=?", [.text(hash), .text(address)])
        }
      }
      let firstStamp = VersionStamp(counter: clock.counter + 1, actor: actor)
      let first = NotebookDocumentStateCommand(documentID: id, record: .init(id: "counter/a~😀", value: .number(1),
        stamp: firstStamp, fieldVersion: .init(stamp: firstStamp, human: true)), journalStamp: firstStamp)
      let cursor = try store.currentChangeCursor()
      let (inserted, appendWork) = try bounded(store) { try store.commitDocumentState(first) }
      #expect(inserted == first.expectedResult)
      let nextStamp = VersionStamp(counter: firstStamp.counter + 1, actor: actor)
      let next = NotebookDocumentStateCommand(documentID: id, record: .init(id: first.record.id, value: .number(2),
        stamp: nextStamp, fieldVersion: .init(stamp: nextStamp, human: true, previous: first.record.fieldVersion)), journalStamp: nextStamp)
      let (edited, editWork) = try bounded(store) { try store.commitDocumentState(next) }
      let (repeated, retryWork) = try bounded(store) { try store.commitDocumentState(next) }
      #expect(edited == next.expectedResult && repeated == edited)
      #expect(try store.currentChangeCursor() == cursor + 2)
      #expect(try store.storedFragments(address: rootAddress + "/records/@retired-75000") == kept)
      let changes = try store.readChangedAddresses(after: cursor, through: store.currentChangeCursor()).addresses
      #expect(Set(changes) == [rootAddress, rootAddress + "/records/@" + fieldKey([first.record.id])])
      print("Native document state SQL instructions: append=\(appendWork), edit=\(editWork), retry=\(retryWork)")
    }
  }

  @Test func acceptedValuesFromDifferentBlocksSurviveAConcurrentAggregateAndAnExactRetry() throws {
    try fixture { store, actor, id in
      var local = try store.loadDocumentState(id), remote = local
      let a = try command(&local, block: "a", value: .number(1), actor: actor)
      let b = try command(&remote, block: "b", value: .number(2), actor: UUID())
      _ = try store.commitDocumentState(b)
      let accepted = try store.commitDocumentState(a)
      let combined = try store.loadDocumentState(id), cursor = try store.currentChangeCursor()
      #expect(combined.value(for: "a") == .number(1) && combined.value(for: "b") == .number(2))
      #expect(combined.stamp >= max(a.journalStamp, b.journalStamp))
      if b.journalStamp >= a.journalStamp { #expect(accepted.journalStamp.counter == b.journalStamp.counter + 1) }
      #expect(try store.commitDocumentState(a) == accepted)
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func capturedCausalityCannotAdoptAnUnseenHumanContinuation() throws {
    try fixture { store, actor, id in
      var initial = try store.loadDocumentState(id)
      _ = try store.commitDocumentState(command(&initial, value: .number(3), actor: actor))
      var agent = initial, human = initial
      let proposal = try command(&agent, value: .number(7), actor: UUID(), human: false)
      let continuation = try command(&human, value: .number(11), actor: actor)
      _ = try store.commitDocumentState(continuation)
      let result = try store.commitDocumentState(proposal)
      #expect(result.record.value == .number(11))
      #expect(result.record.fieldVersion?.human == true)
      #expect(result.record.fieldVersion?.includes(try #require(proposal.record.fieldVersion)) == true)
      let cursor = try store.currentChangeCursor()
      #expect(try store.commitDocumentState(proposal) == result)
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func nestedCollectionsAndPrefixLikeIDsRemainTheirOwnProgramValues() throws {
    try fixture { store, actor, id in
      var state = try store.loadDocumentState(id)
      let ids = ["a0", "a!", "a", "a/child", "a~child", UUID().uuidString]
      for block in ids {
        let value: JSONValue = .object(["blocks": .array([.object(["id": .string("nested"), "stamp": .string(block)])])])
        let result = try store.commitDocumentState(command(&state, block: block, value: value, actor: actor))
        #expect(result.journalStamp == state.stamp)
      }
      let prefix = stateFile(id) + "#/records/@"
      let kept = try store.storedFragments(address: prefix + "a!")
      _ = try store.commitDocumentState(command(&state, block: "a", value: .number(9), actor: actor))
      #expect(try store.loadDocumentState(id) == state)
      #expect(try store.storedFragments(address: prefix + "a!") == kept)
      #expect(try store.storedFragments(address: prefix + "a").count == 1)
    }
  }

  private enum Fault: Error { case injected }
  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit, .afterCommit])
  func valueClockAndDeliveryHaveOneFailureBoundary(fault: NotebookStorageFault) throws {
    try fixture { store, actor, id in
      var state = try store.loadDocumentState(id)
      let before = state, cursor = try store.currentChangeCursor()
      let accepted = try command(&state, value: .number(5), actor: actor)
      let failing = NotebookStore(root: store.root) { point in
        if String(describing: point) == String(describing: fault) { throw Fault.injected }
      }
      #expect(throws: Fault.self) { try failing.commitDocumentState(accepted) }
      if case .afterCommit = fault {
        #expect(try store.loadDocumentState(id) == state)
        #expect(try store.currentChangeCursor() == cursor + 1)
      } else {
        #expect(try store.loadDocumentState(id) == before)
        #expect(try store.currentChangeCursor() == cursor)
      }
      #expect(try store.commitDocumentState(accepted) == accepted.expectedResult)
      #expect(try store.currentChangeCursor() == cursor + 1)
    }
  }

  @Test(arguments: ["oversized-clock", "future-record", "mismatched-version", "oversized-observations", "missing-version"])
  func invalidCommandCannotPublish(kind: String) throws {
    try fixture { store, actor, id in
      let stamp = VersionStamp(counter: kind == "oversized-clock" ? VersionStamp.maximumCounter + 1 : 1, actor: actor)
      let versionStamp = kind == "mismatched-version" ? VersionStamp(counter: 2, actor: actor) : stamp
      let observations = kind == "oversized-observations"
        ? Dictionary(uniqueKeysWithValues: (0..<257).map { _ in (UUID().uuidString.lowercased(), UInt64(1)) })
        : [actor.uuidString.lowercased(): stamp.counter]
      let value = NotebookDocumentStateCommand(documentID: id, record: .init(id: "body", value: .number(5), stamp: stamp,
        fieldVersion: kind == "missing-version" ? nil : .init(stamp: versionStamp, human: true, observed: observations)),
        journalStamp: kind == "future-record" ? .init(counter: 0, actor: actor) : stamp)
      let before = try store.loadDocumentState(id), cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.self) { try store.commitDocumentState(value) }
      #expect(try store.loadDocumentState(id) == before && store.currentChangeCursor() == cursor)
    }
  }

  @Test func causalUnionCannotExceedTheExistingObservationLimit() throws {
    try fixture { store, actor, id in
      let stamp = VersionStamp(counter: 1, actor: actor)
      var observations = Dictionary(uniqueKeysWithValues: (0..<255).map { _ in (UUID().uuidString.lowercased(), UInt64(1)) })
      observations[actor.uuidString.lowercased()] = 1
      let initial = NotebookDocumentStateCommand(documentID: id, record: .init(id: "body", value: .number(1), stamp: stamp,
        fieldVersion: .init(stamp: stamp, human: true, observed: observations)), journalStamp: stamp)
      _ = try store.commitDocumentState(initial)
      let nextStamp = VersionStamp(counter: 2, actor: UUID())
      let incoming = NotebookDocumentStateCommand(documentID: id, record: .init(id: "body", value: .number(2), stamp: nextStamp,
        fieldVersion: .init(stamp: nextStamp, human: true)), journalStamp: nextStamp)
      let before = try store.loadDocumentState(id), cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.self) { try store.commitDocumentState(incoming) }
      #expect(try store.loadDocumentState(id) == before && store.currentChangeCursor() == cursor)
    }
  }

  @Test func exhaustedAggregateCannotPublishADifferentFrameWithTheSameClock() throws {
    try fixture { store, actor, id in
      let stamp = VersionStamp(counter: VersionStamp.maximumCounter, actor: actor)
      let initial = NotebookDocumentStateCommand(documentID: id, record: .init(id: "a", value: .number(1), stamp: stamp,
        fieldVersion: .init(stamp: stamp, human: true)), journalStamp: stamp)
      _ = try store.commitDocumentState(initial)
      let older = VersionStamp(counter: stamp.counter - 1, actor: actor)
      let incoming = NotebookDocumentStateCommand(documentID: id, record: .init(id: "b", value: .number(2), stamp: older,
        fieldVersion: .init(stamp: older, human: true)), journalStamp: older)
      let before = try store.loadDocumentState(id), cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.self) { try store.commitDocumentState(incoming) }
      #expect(try store.loadDocumentState(id) == before && store.currentChangeCursor() == cursor)
    }
  }

  private func bounded<T>(_ store: NotebookStore, _ operation: () throws -> T) throws -> (T, Int) {
    let count = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    count.initialize(to: 0); defer { count.deinitialize(count: 1); count.deallocate() }
    let result = try store.commandTransaction {
      sqlite3_progress_handler(store.currentSQL!.handle, 1, { raw in
        let count = raw!.assumingMemoryBound(to: Int.self)
        count.pointee += 1; return count.pointee > 200_000 ? 1 : 0
      }, count)
      return try operation()
    }
    #expect(count.pointee > 0 && count.pointee < 200_000)
    return (result, count.pointee)
  }
}
