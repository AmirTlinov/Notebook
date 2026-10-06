import Foundation
import Testing
@testable import NotebookCore

@Suite("Accepted native outcomes belong to their transaction")
struct NotebookAcceptedWriteTests {
  private enum DiskFailure: Error { case unavailable }

  private func fixture(_ body: (NotebookStore, UUID) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-accepted-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor)
  }

  private func programPage(_ store: NotebookStore, actor: UUID) throws -> PageDocument {
    let index = try store.loadIndex(), pageID = try #require(index.selectedPageID)
    var page = try store.loadPage(pageID)
    let changed = page.replaceElements([
      .init(id: "program", kind: .web, frame: .init(x: 0, y: 0, width: 100, height: 100),
        source: "Original", html: "<button>Run</button>", state: .number(0))
    ], actor: actor)
    #expect(changed)
    try store.savePage(page)
    return page
  }

  private func lostReply(_ store: NotebookStore) -> NotebookStore {
    NotebookStore(root: store.root, storageFault: { phase in
      if phase == .afterCommit { throw DiskFailure.unavailable }
    })
  }

  private func expectUnknown<Value: Sendable>(_ accepted: NotebookAcceptedWrite<Value>, in store: NotebookStore) throws {
    do { _ = try accepted.apply(to: store); Issue.record("A lost COMMIT acknowledgement must keep its accepted instance") }
    catch let error as NotebookAcceptedWriteError { #expect(error.outcome == .unresolved) }
  }

  private func witnessCount(_ store: NotebookStore) throws -> Int64 {
    try store.sqlRead { try $0.rows("SELECT COUNT(*) FROM accepted_write_witnesses").first![0].integer! }
  }

  @Test func aNewWorkspaceKeepsItsAcceptedOwnerThroughCreationPresenceAndReplay() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-cold-" + UUID().uuidString)
      .appendingPathComponent("nested/workspace")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let store = NotebookStore(root: root), actor = UUID()
    let witnesses = NotebookAcceptedWriteWitnesses(root: root)
    let initialized = NotebookAcceptedWrite(witnesses: witnesses) { store in
      try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    }
    let header = try initialized.apply(to: store)
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .board,
      camera: .init(), viewport: .init(x: 834, y: 1194))
    let saved = NotebookAcceptedWrite(witnesses: witnesses) { store in
      try store.savePresence(presence)
      return presence
    }
    let reopened = NotebookStore(root: URL(fileURLWithPath: root.path, isDirectory: true))
    #expect(store.connectionKey == reopened.connectionKey)
    #expect(try saved.apply(to: reopened) == presence)
    #expect(try store.loadPresence() == presence)
    try witnesses.flush(in: reopened)
    #expect(try initialized.apply(to: reopened).rootBoardID == header.rootBoardID)
    #expect(try saved.apply(to: store) == presence)
    #expect(try witnessCount(store) == 0)
  }

  @Test func aMissingWorkspaceThroughASymlinkAliasSharesItsTransactionAndAcceptedOutcome() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-alias-" + UUID().uuidString)
    let physical = parent.appendingPathComponent("physical"), alias = parent.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = physical.appendingPathComponent("nested/workspace")
    let aliasRoot = alias.appendingPathComponent("nested/workspace", isDirectory: true)
    let store = NotebookStore(root: root), aliased = NotebookStore(root: aliasRoot), actor = UUID()
    #expect(store.connectionKey == aliased.connectionKey)
    let witnesses = NotebookAcceptedWriteWitnesses(root: aliasRoot)
    let initialized = NotebookAcceptedWrite(witnesses: witnesses) { store in
      let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
      try aliased.publishRecords(writes: ["accepted-alias.json": .object(["value": .number(1)])])
      return header.rootBoardID
    }
    let boardID = try initialized.apply(to: store)
    #expect(try aliased.currentChangeCursor() == 1, "The aliased nested write shares the outer COMMIT")
    #expect(try aliased.hasStoredValue("accepted-alias.json"))
    let reopened = NotebookStore(root: URL(fileURLWithPath: aliasRoot.path, isDirectory: false))
    #expect(reopened.connectionKey == store.connectionKey)
    try witnesses.flush(in: reopened)
    #expect(try initialized.apply(to: reopened) == boardID)
    let other = NotebookStore(root: parent.appendingPathComponent("other"))
    do { _ = try initialized.apply(to: other); Issue.record("Another root cannot adopt the accepted result") }
    catch let error as NotebookAcceptedWriteError {
      #expect(error.outcome == .storageUnavailable)
      #expect(error.underlying as? NotebookStorageError == .corruptRecord("accepted writer workspace root"))
    }
    #expect(!FileManager.default.fileExists(atPath: other.root.path))
  }

  @Test func refusalAfterNestedWritesRollsBackTheWholeAcceptedCommand() throws {
    try fixture { store, _ in
      let before = try store.currentChangeCursor(), read = try store.currentReadCursor()
      let accepted = NotebookAcceptedWrite<Void>(witnesses: .init(root: store.root)) { store in
        try store.publishRecords(writes: ["accepted-first.json": .object(["value": .number(1)])])
        try store.publishRecords(writes: ["accepted-second.json": .object(["value": .number(2)])])
        throw NotebookStorageError.limitExceeded("complete_reorder")
      }
      do {
        try accepted.apply(to: store)
        Issue.record("The rejected command cannot acknowledge either nested write")
      } catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .rejected)
        #expect(error.underlying as? NotebookStorageError == .limitExceeded("complete_reorder"))
      }
      #expect(try !store.hasStoredValue("accepted-first.json"))
      #expect(try !store.hasStoredValue("accepted-second.json"))
      #expect(try store.currentChangeCursor() == before)
      #expect(try store.currentReadCursor() == read)
    }
  }

  @Test func nestedSourceWritesShareOneCommitAndPublication() throws {
    try fixture { store, _ in
      let before = try store.currentChangeCursor(), read = try store.currentReadCursor()
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) { store in
        try store.publishRecords(writes: ["accepted-first.json": .object(["value": .number(1)])])
        try store.publishRecords(writes: ["accepted-second.json": .object(["value": .number(2)])])
      }
      try accepted.apply(to: store)
      #expect(try store.hasStoredValue("accepted-first.json"))
      #expect(try store.hasStoredValue("accepted-second.json"))
      #expect(try store.currentChangeCursor() == before + 1)
      #expect(try store.currentReadCursor() == read + 1)
    }
  }

  @Test func anErrorNamedAsADomainLimitAfterCommitStillHasAnUnresolvedOutcome() throws {
    try fixture { store, _ in
      let before = try store.currentChangeCursor()
      let lost = NotebookStore(root: store.root, storageFault: { phase in
        if case .afterCommit = phase { throw CollaborationError("resource_limit", "A lost post-commit reply") }
      })
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) {
        try $0.publishRecords(writes: ["accepted.json": .object(["value": .number(1)])])
      }
      do {
        try accepted.apply(to: lost)
        Issue.record("The native writer must retain this identity until its receipt is checked")
      } catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .unresolved, "The error spelling cannot attest rollback")
        #expect((error.underlying as? CollaborationError)?.code == "resource_limit")
      }
      #expect(try store.hasStoredValue("accepted.json"))
      #expect(try store.currentChangeCursor() == before + 1)
    }
  }

  @Test(arguments: [NotebookStorageFault.afterRecordWrites, .beforeCommit])
  func diskFailureKeepsItsStorageOutcomeAfterSuccessfulRollback(phase: NotebookStorageFault) throws {
    try fixture { store, _ in
      let before = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root, storageFault: { point in
        if point == phase { throw DiskFailure.unavailable }
      })
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) {
        try $0.publishRecords(writes: ["accepted.json": .object(["value": .number(1)])])
      }
      do {
        try accepted.apply(to: failing)
        Issue.record("An unavailable disk cannot report a completed native command")
      } catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .storageUnavailable)
        #expect(error.underlying is DiskFailure)
      }
      #expect(try !store.hasStoredValue("accepted.json"))
      #expect(try store.currentChangeCursor() == before)
    }
  }

  @Test func aStorageProtocolBridgeDoesNotBecomeATerminalDomainRefusal() throws {
    try fixture { store, _ in
      let accepted = NotebookAcceptedWrite<Void>(witnesses: .init(root: store.root)) { _ in
        throw CollaborationError("storage_error", "An unreadable body")
      }
      do {
        try accepted.apply(to: store)
        Issue.record("Expected a blocked storage result")
      } catch let error as NotebookAcceptedWriteError {
        #expect(error.outcome == .storageUnavailable)
      }
    }
  }

  @Test func nonpublishingNestedChatCommandsKeepTheirLocalReadFence() throws {
    try fixture { store, actor in
      let before = try store.currentChangeCursor(), read = try store.currentReadCursor()
      let input = NotebookChatInput(author: actor, action: .send(threadID: UUID().uuidString, text: "Accepted", context: ""))
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) { store in
        _ = try store.saveChatSubmission(input)
        return try store.advanceChatJob(input.id, from: .saved, to: .attempting)
      }
      let job = try accepted.apply(to: store)
      #expect(job.state == .attempting)
      #expect(try store.chatJob(input.id) == job)
      #expect(try store.currentChangeCursor() == before)
      #expect(try store.currentReadCursor() == read)
    }
  }

  @Test func coldPageRetryReturnsItsOriginalReceiptWithoutOverwritingAPeerAfterUnknownCommit() throws {
    try fixture { store, actor in
      let page = try programPage(store, actor: actor), basis = try #require(page.programStateBasis("program"))
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) { store in
        try store.commitPageProgramState(pageID: page.id, elementID: "program", state: .number(1), basis: basis, actor: actor)
      }
      try expectUnknown(accepted, in: lostReply(store))
      let original = try #require(store.loadPage(page.id).programStateBasis("program"))
      _ = try store.commitPageProgramState(pageID: page.id, elementID: "program", state: .number(2), basis: basis, actor: UUID())
      let peer = try store.loadPage(page.id), changes = try store.currentChangeCursor(), read = try store.currentReadCursor()
      let result = try accepted.apply(to: store)
      #expect(result.basis == original && result.changed)
      #expect(try store.loadPage(page.id).element(id: "program")?.state == .number(2))
      #expect(try store.loadPage(page.id).agentStamp == peer.agentStamp)
      #expect(try store.currentChangeCursor() == changes)
      #expect(try store.currentReadCursor() == read)
    }
  }

  @Test func warmPageRetryReturnsTheOriginalOutputAfterAPeerAdvancesItsFrozenState() throws {
    try fixture { store, actor in
      let page = try programPage(store, actor: actor)
      var proposal = page
      let replaced = proposal.replaceProgramState(.number(1), elementID: "program", actor: actor)
      #expect(replaced)
      let command = try #require(NotebookPageProgramStateCommand(before: page, after: proposal, elementID: "program"))
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) { try $0.commitPageProgramState(command) }
      try expectUnknown(accepted, in: lostReply(store))
      _ = try store.commitPageProgramState(pageID: page.id, elementID: "program", state: .number(2),
        basis: command.expectedBasis, actor: UUID())
      let changes = try store.currentChangeCursor()
      let result = try accepted.apply(to: store)
      #expect(result.basis == command.expectedBasis && result.changed,
        "Retry must return the original acknowledgement, even when replay would now lose or be a no-op")
      #expect(try store.loadPage(page.id).element(id: "program")?.state == .number(2))
      #expect(try store.currentChangeCursor() == changes)
    }
  }

  @Test func spatialRetryReturnsItsOriginalElementWithoutMintingAnotherDotAfterAPeer() throws {
    try fixture { store, actor in
      let index = try store.loadIndex(), before = try store.loadBoard(items: index.items)
      let boardID = index.rootBoardID
      let element = SpatialElement(id: "program", surface: .cover(index.items[0].id), kind: .web,
        frame: .init(x: 10, y: 20, width: 200, height: 90), source: "Original", stamp: .init(counter: 0, actor: actor))
      var after = before
      let inserted = after.upsertElement(element, in: boardID, expected: nil, actor: actor)
      #expect(inserted)
      _ = try store.saveBoardEdits(before: before, after: after)
      let renderedValue = try store.readSpatialElement(boardID: boardID, elementID: element.id)
      let rendered = try #require(renderedValue)
      let basis = try #require(store.loadBoard(items: index.items).board(boardID)?.programStateBasis(element.id))
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) { store in
        try store.commitSpatialElementState(boardID: boardID, rendered: rendered, state: .number(1), actor: actor, expectedProgramBasis: basis)
      }
      try expectUnknown(accepted, in: lostReply(store))
      let originalValue = try store.readSpatialElement(boardID: boardID, elementID: element.id)
      let original = try #require(originalValue)
      let originalBasis = try #require(store.loadBoard(items: index.items).board(boardID)?.programStateBasis(element.id))
      _ = try store.commitSpatialElementState(boardID: boardID, rendered: rendered, state: .number(2), actor: UUID(), expectedProgramBasis: basis)
      let peer = try store.readSpatialElement(boardID: boardID, elementID: element.id), changes = try store.currentChangeCursor()
      let retried = try accepted.apply(to: store), result = try #require(retried)
      #expect(result.element == original && result.basis == originalBasis)
      #expect(try store.readSpatialElement(boardID: boardID, elementID: element.id) == peer)
      #expect(peer?.state == .number(2))
      #expect(try store.currentChangeCursor() == changes)
    }
  }

  @Test func aBeforeCommitRollbackRetriesTheSameAcceptedIdentityAndOnlyItsSuccessfulOutput() throws {
    try fixture { store, _ in
      let witnesses = NotebookAcceptedWriteWitnesses(root: store.root), value = UUID()
      let accepted = NotebookAcceptedWrite(witnesses: witnesses) { store in
        try store.publishRecords(writes: ["accepted.json": .object(["identity": .string(value.uuidString)])])
        return value
      }
      let identity = accepted.identity, changes = try store.currentChangeCursor()
      let failing = NotebookStore(root: store.root, storageFault: { if $0 == .beforeCommit { throw DiskFailure.unavailable } })
      do { _ = try accepted.apply(to: failing); Issue.record("Expected rollback") }
      catch let error as NotebookAcceptedWriteError { #expect(error.outcome == .storageUnavailable) }
      #expect(try !store.hasStoredValue("accepted.json"))
      #expect(try witnessCount(store) == 0)
      #expect(try accepted.apply(to: store) == value)
      #expect(accepted.identity == identity)
      let saved = try store.sqlRead { try $0.rows("SELECT accepted FROM accepted_write_witnesses WHERE writer=?", [.text(witnesses.id.uuidString)]).first?[0].text }
      #expect(saved == identity.uuidString)
      #expect(try store.currentChangeCursor() == changes + 1)
    }
  }

  @Test func anUnreadableWitnessRetainsTheOriginalOutputAndNeverReexecutesItsBody() throws {
    try fixture { store, _ in
      let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) { store in
        try store.publishRecords(writes: ["accepted.json": .object(["state": .number(1)])])
        return 1
      }
      try expectUnknown(accepted, in: lostReply(store))
      try store.publishRecords(writes: ["accepted.json": .object(["state": .number(2)])])
      let changes = try store.currentChangeCursor()
      let unreadable = NotebookStore(root: store.root, storageFault: { if $0 == .beforeAcceptedWitnessRead { throw DiskFailure.unavailable } })
      try expectUnknown(accepted, in: unreadable)
      #expect(try accepted.apply(to: store) == 1)
      #expect(try store.storedValue("accepted.json")?["state"] == .number(2))
      #expect(try store.currentChangeCursor() == changes)
    }
  }

  @Test func acceptedNoOpWithANestedReadRevisionOwnerAndWitnessFlushKeepsEveryCursor() throws {
    try fixture { store, _ in
      let witnesses = NotebookAcceptedWriteWitnesses(root: store.root)
      let changes = try store.currentChangeCursor(), read = try store.currentReadCursor()
      let accepted = NotebookAcceptedWrite(witnesses: witnesses) { store in
        try store.commandTransaction { 9 }
      }
      #expect(try accepted.apply(to: store) == 9)
      #expect(try witnessCount(store) == 1)
      try witnesses.flush(in: store)
      #expect(try witnessCount(store) == 0)
      #expect(try store.currentChangeCursor() == changes)
      #expect(try store.currentReadCursor() == read)
      #expect(try accepted.apply(to: store) == 9, "An acknowledged output survives its marker retirement")
    }
  }

  @Test func oneWitnessPerWriterPlateausAndOnlyAProvedRetiredLeaseGenerationIsCollected() throws {
    try fixture { store, _ in
      let endpoint = store.root.appendingPathComponent("runtime/writer.sock")
      var oldLease: NotebookIPCProcessLease? = try .init(socketURL: endpoint)
      var oldScope: NotebookAcceptedWriteWitnesses? = .init(root: store.root, processLease: oldLease)
      for value in 0..<32 {
        let accepted = NotebookAcceptedWrite(witnesses: oldScope!) { _ in value }
        #expect(try accepted.apply(to: store) == value)
        #expect(try witnessCount(store) == 1)
      }
      oldScope = nil; oldLease = nil
      let lease = try NotebookIPCProcessLease(socketURL: endpoint)
      let current = NotebookAcceptedWriteWitnesses(root: store.root, processLease: lease)
      let otherLive = NotebookAcceptedWriteWitnesses(root: store.root, processLease: lease)
      let unproved = NotebookAcceptedWriteWitnesses(root: store.root)
      let noProof = NotebookAcceptedWrite(witnesses: unproved) { _ in 7 }
      _ = try noProof.apply(to: store)
      #expect(try witnessCount(store) == 2)
      _ = try NotebookAcceptedWrite(witnesses: current) { _ in 8 }.apply(to: store)
      #expect(try witnessCount(store) == 2, "Only the retired generation's orphan was removed")
      _ = try NotebookAcceptedWrite(witnesses: otherLive) { _ in 9 }.apply(to: store)
      #expect(try witnessCount(store) == 3, "Same-process live scopes and unproved scopes retain their witnesses")
      let changes = try store.currentChangeCursor(), read = try store.currentReadCursor()
      try current.flush(in: store); try otherLive.flush(in: store); try unproved.flush(in: store)
      #expect(try witnessCount(store) == 0)
      #expect(try store.currentChangeCursor() == changes)
      #expect(try store.currentReadCursor() == read)
    }
  }

  @Test func confirmedOutputRequiresTheOriginalWorkspaceIdentityAfterMarkerRetirement() throws {
    try fixture { store, _ in
      let witnesses = NotebookAcceptedWriteWitnesses(root: store.root), workspace = try store.storedWorkspaceID()
      let accepted = NotebookAcceptedWrite(witnesses: witnesses) { store in
        try store.publishRecords(writes: ["accepted.json": .object(["state": .number(7)])])
        return 7
      }
      #expect(try accepted.apply(to: store) == 7)
      try witnesses.flush(in: store)
      let cursor = try store.currentChangeCursor()
      try store.commandTransaction(advancesReadRevision: false) {
        try store.currentSQL!.run("UPDATE metadata SET value=? WHERE key='workspace_id'", [.text(UUID().uuidString)])
      }
      do { _ = try accepted.apply(to: store); Issue.record("A different workspace cannot adopt the original accepted result") }
      catch let error as NotebookAcceptedWriteError { #expect(error.outcome == .storageUnavailable) }
      try store.commandTransaction(advancesReadRevision: false) {
        try store.currentSQL!.run("UPDATE metadata SET value=? WHERE key='workspace_id'", [.text(workspace.uuidString)])
      }
      #expect(try accepted.apply(to: store) == 7)
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try witnessCount(store) == 0)
    }
  }
}
