import Foundation
import Testing
@testable import NotebookCore

@Suite("The agent's WAL read allowance cannot be bypassed by another helper", .serialized)
struct NotebookAgentCommandBudgetTests {
  private func fixture(_ body: (NotebookStore, UUID, PageDocument) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-budget-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    try body(store, actor, store.loadPage(#require(store.loadIndex().selectedPageID)))
  }

  private func allowance(rows: Int = 20, bytes: Int = 20, valueBytes: Int = 20) -> NotebookSQLReadAllowance {
    .init(rows: rows, bytes: bytes, valueBytes: valueBytes, reason: "test_command_read")
  }

  @Test(arguments: [false, true])
  func aValueIsRefusedBeforeSwiftCopiesIt(blob: Bool) throws {
    try fixture { store, _, _ in
      #expect(throws: NotebookStorageError.limitExceeded("test_command_read")) {
        try store.readTransaction { _ in
          let database = store.currentSQL!
          try database.limitReads(allowance(bytes: 100, valueBytes: 7))
          _ = try database.rows("SELECT ?", [blob ? .blob(Data(repeating: 1, count: 8)) : .text("😀😀")])
        }
      }
      // A failed command does not leave an allowance on the next connection.
      let restored = try store.sqlRead { try $0.rows("SELECT ?", [.text("😀😀")]).first?[0].text }
      #expect(restored == "😀😀")
    }
  }

  @Test func repeatedQueriesShareBytesAndNestedCommandsCannotRenewThem() throws {
    try fixture { store, _, _ in
      let cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.limitExceeded("test_command_read")) {
        try store.commandTransaction(readAllowance: allowance(bytes: 8)) {
          let database = store.currentSQL!
          _ = try database.rows("SELECT ?", [.text("12345678")])
          try store.commandTransaction(readAllowance: allowance(bytes: 8)) {
            _ = try database.rows("SELECT ?", [.text("x")])
          }
        }
      }
      #expect(try store.currentChangeCursor() == cursor)
    }
  }

  @Test func emptyRowsStillConsumeTheCommandAllowance() throws {
    try fixture { store, _, _ in
      #expect(throws: NotebookStorageError.limitExceeded("test_command_read")) {
        try store.readTransaction { _ in
          let database = store.currentSQL!
          try database.limitReads(allowance(rows: 2, bytes: 0))
          _ = try database.rows("SELECT NULL UNION ALL SELECT NULL UNION ALL SELECT NULL")
        }
      }
    }
  }

  @Test func swallowingAReadRefusalCannotCommitAPartialCommand() throws {
    try fixture { store, _, _ in
      let cursor = try store.currentChangeCursor()
      #expect(throws: NotebookStorageError.limitExceeded("test_command_read")) {
        try store.commandTransaction {
          let database = store.currentSQL!
          try database.run("INSERT INTO metadata(key,value) VALUES('test_partial_command','must roll back')")
          try database.limitReads(allowance(rows: 0))
          _ = try? database.rows("SELECT 1")
          // An inner reader swallowing the error cannot re-enable the lease.
          _ = try? database.limitReads(allowance(rows: 100))
        }
      }
      #expect(try store.currentChangeCursor() == cursor)
      let absent = try store.sqlRead { try $0.rows("SELECT value FROM metadata WHERE key='test_partial_command'").isEmpty }
      #expect(absent)
    }
  }

  @Test func theFinalCommitCheckRetainsTheRefusalEvenAfterTheBodyReturns() throws {
    try fixture { store, _, _ in
      let cursor = try store.currentChangeCursor()
      let checked = NotebookStore(root: store.root) { fault in
        guard fault == .beforeCommit else { return }
        let database = store.currentSQL!
        try database.limitReads(allowance(rows: 0))
        _ = try? database.rows("SELECT 1")
      }
      #expect(throws: NotebookStorageError.limitExceeded("test_command_read")) {
        try checked.commandTransaction {
          try store.currentSQL!.run("INSERT INTO metadata(key,value) VALUES('test_final_command','must roll back')")
        }
      }
      #expect(try store.currentChangeCursor() == cursor)
      let absent = try store.sqlRead { try $0.rows("SELECT value FROM metadata WHERE key='test_final_command'").isEmpty }
      #expect(absent)
    }
  }

  private func largePage(_ original: PageDocument, actor: UUID, store: NotebookStore) throws -> PageDocument {
    var page = original
    let changed = page.replaceElements([
      .init(id: "large", kind: .web, frame: .init(x: 300, y: 300, width: 200, height: 200),
        source: "Large", html: String(repeating: "x", count: 8 * 1_024 * 1_024)),
      .init(id: "small", kind: .markdown, frame: .init(x: 10, y: 10, width: 100, height: 100),
        source: "Before", html: "Before")], actor: actor)
    #expect(changed)
    return try store.savePage(page)
  }

  private func action(_ page: PageDocument, kind: CollaborationOperation.Kind, id: String? = nil,
    values: [String: JSONValue] = [:]) -> CollaborationAction {
    let target = CollaborationTarget(kind: .page, id: page.id)
    return .init(summary: "Bounded page command", references: [.init(target: target, revision: page.agentStamp.revision)],
      expected: [.init(target: target, revision: page.agentStamp.revision)],
      operations: [.init(kind: kind, target: target, id: id, values: values)])
  }

  @Test(arguments: [CollaborationOperation.Kind.insertElement, .removeElement, .reorderElements])
  func structuralPageCommandsRefuseACompleteOversizedOwnerWithoutWriting(kind: CollaborationOperation.Kind) throws {
    try fixture { store, actor, initial in
      let page = try largePage(initial, actor: actor, store: store)
      let cursor = try store.currentChangeCursor()
      let values: [String: JSONValue]
      switch kind {
      case .insertElement:
        values = ["kind": .string("markdown"), "source": .string("New"),
          "frame": try .encode(PageRect(x: 600, y: 600, width: 100, height: 100))]
      case .reorderElements: values = ["ids": .array([.string("small"), .string("large")])]
      default: values = [:]
      }
      let operation = action(page, kind: kind, id: kind == .insertElement ? "new" : kind == .removeElement ? "small" : nil,
        values: values)
      #expect(throws: NotebookStorageError.limitExceeded("agent_command_read")) {
        try store.applyCollaborationAction(operation, actor: actor)
      }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.loadPage(page.id) == page)
      #expect(try store.collaborationActions().isEmpty)
    }
  }

  @Test func anAddressedEditOfTheSameLargePageStillCommitsRetriesAndUndoes() throws {
    try fixture { store, actor, initial in
      let page = try largePage(initial, actor: actor, store: store)
      let change = action(page, kind: .updateElement, id: "small", values: ["source": .string("After")])
      let receipt = try store.applyCollaborationAction(change, actor: actor)
      let cursor = try store.currentChangeCursor()
      #expect(try store.applyCollaborationAction(change, actor: actor) == receipt)
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.collaborationAction(change.id) == receipt)
      _ = try store.collaborationContinuations(change.id)
      _ = try store.undoCollaborationAction(change.id, actor: actor)
      let restored = try store.loadPage(page.id)
      #expect(restored.elements == page.elements)
      #expect(restored.drawingData == page.drawingData)
    }
  }

  @Test func dispatcherReadsAndMutationsUseTheSameResourceRefusal() throws {
    try fixture { store, actor, initial in
      let page = try largePage(initial, actor: actor, store: store)
      let dispatcher = NotebookCommandDispatcher(store: store)
      var read = NotebookCommand(command: .read)
      read.queries = [.init(kind: .page, id: page.id)]
      var apply = NotebookCommand(command: .apply)
      apply.action = action(page, kind: .removeElement, id: "small")
      let cursor = try store.currentChangeCursor()
      for command in [read, apply] {
        do {
          _ = try dispatcher.handle(command)
          Issue.record("The dispatcher returned a partial oversized owner")
        } catch let error as CollaborationError {
          #expect(error.code == "resource_limit")
        }
      }
      #expect(try store.currentChangeCursor() == cursor)
      #expect(try store.loadPage(page.id) == page)
      var header = NotebookCommand(command: .read)
      header.queries = [.init(kind: .workspaceHeader)]
      #expect(try dispatcher.handle(header)["values"]?.array.count == 1)
    }
  }

  @Test func placementEnqueuesItsRenderThroughTheExistingCommandQueue() throws {
    try fixture { store, _, page in
      let target = CollaborationTarget(kind: .page, id: page.id)
      var command = NotebookCommand(command: .placement)
      command.placement = .init(target: target, expectedRevision: page.agentStamp.revision,
        items: [.init(id: "new", size: .init(width: 100, height: 80))])
      #expect(command.changesStore)
      let dispatcher = NotebookCommandDispatcher(store: store)
      let value = try dispatcher.handle(command).decode(CollaborationPlacement.self)
      #expect(value.status == .snapshotPending)
      let request = try #require(value.renderRequest)
      #expect(try store.targetRenderRequests(target: target).map(\.id) == [request.id])
      let repeated = try dispatcher.handle(command).decode(CollaborationPlacement.self)
      #expect(repeated.renderRequest?.id == request.id)
      #expect(try store.targetRenderRequests(target: target).count == 1)
      #expect(try store.loadPage(page.id) == page)
    }
  }
}
