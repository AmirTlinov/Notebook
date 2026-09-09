import Foundation
import NotebookCore
import XCTest
@testable import Notebook

/// Tests cross the same private socket and native writer as the production MCP.
/// No command can choose a store; this fixture supplies the endpoint at app creation.
@MainActor
final class MacCommandFixture {
  let store: NotebookStore
  let socketURL: URL
  let model: NotebookAppModel

  init(root: URL) {
    store = NotebookStore(root: root)
    socketURL = URL(fileURLWithPath: "/tmp/nb-mac-test-" + UUID().uuidString)
      .appendingPathComponent("bridge.sock")
    model = NotebookAppModel(store: store, startsNearbySync: false, commandSocketURL: socketURL)
  }

  isolated deinit { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }

  func start(pageSize: PageSize = NotebookAppModel.defaultPageSize, showingPage: Bool = false) async throws {
    if showingPage {
      let header = try store.initializeWorkspace(actor: UUID(), pageSize: pageSize)
      let item = try XCTUnwrap(store.readWorkspaceItems(limit: 1).first)
      try store.savePresence(.init(boardID: header.rootBoardID, mode: .page,
        camera: .init(), viewport: .init(x: pageSize.width, y: pageSize.height),
        focusedItemID: item.id, openProgress: 1, selectedItemID: item.id, notebookPageID: item.pageIDs.first))
    }
    await model.start(pageSize: pageSize)
    XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path), "The actual Mac command owner must start")
    _ = try await read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
  }

  func send(_ command: NotebookCommand) async throws -> JSONValue {
    let socket = socketURL
    return try await Task.detached { try NotebookIPCClient(socketURL: socket).send(command) }.value
  }

  func read(_ query: NotebookReadQuery) async throws -> JSONValue {
    var command = NotebookCommand(command: .read)
    command.queries = [query]
    let response = try await send(command)
    guard case .array(let values) = response["values"], let value = values.first else {
      throw CollaborationError("invalid_response", "The IPC read must return its one addressed result")
    }
    return value
  }

  func expectation(_ target: CollaborationTarget, ink: Bool = false) async throws -> CollaborationExpectation {
    let revision: String
    var inkRevision: String?
    switch target.kind {
    case .workspace:
      revision = try await read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self).stamp.revision
    case .page:
      let page = try await read(.init(kind: .page, id: target.id)).decode(PageDocument.self)
      revision = page.agentStamp.revision
      if ink { inkRevision = page.drawingStamp.revision }
    case .document:
      revision = try await read(.init(kind: .document, id: target.id)).decode(DocumentDocument.self).contentStamp.revision
    case .board, .cover:
      let boardID: UUID
      if target.kind == .board { boardID = target.id } else { boardID = try XCTUnwrap(target.boardID) }
      var query = NotebookReadQuery(kind: .workingSet)
      query.boardIDs = [boardID]
      let value = try await read(query)
      let nodes = try XCTUnwrap(value["boards"]).decode([BoardNode].self)
      revision = try XCTUnwrap(nodes.first(where: { $0.id == boardID })).board.stamp.revision
      if ink {
        let header = try await read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
        inkRevision = try XCTUnwrap(header.spatialInkStamp).revision
      }
    }
    return .init(target: target, revision: revision, inkRevision: inkRevision)
  }

  @discardableResult
  func apply(_ operations: [CollaborationOperation], expected supplied: [CollaborationExpectation]? = nil,
    actionID: UUID = UUID()) async throws -> CollaborationReceipt {
    var targets = Array(Set(operations.map(\.target)))
    if operations.contains(where: { [.createNotebook, .createDocument, .createBoard, .renameItem].contains($0.kind) }) {
      let header = try await read(.init(kind: .workspaceHeader)).decode(NotebookWorkspaceHeader.self)
      targets.append(.init(kind: .workspace, id: header.rootBoardID))
    }
    var expected = supplied ?? []
    if supplied == nil {
      for target in targets {
        expected.append(try await expectation(target, ink: operations.contains { $0.target == target && $0.kind == .appendInkStroke }))
      }
    }
    var owners = targets
    for operation in operations where operation.kind == .moveItem {
      if let id = operation.id.flatMap(UUID.init(uuidString:)) {
        owners.append(.init(kind: .cover, id: id, boardID: operation.target.id))
      }
    }
    var command = NotebookCommand(command: .apply)
    command.action = .init(id: actionID, additionalOwners: Array(Set(owners)), summary: "Test a complete IPC action",
      expected: expected, operations: operations)
    return try await send(command).decode(CollaborationReceipt.self)
  }

  func move(_ itemID: UUID, boardID: UUID, to center: WorldPoint) async throws {
    try await apply([.init(kind: .moveItem, target: .init(kind: .board, id: boardID),
      id: itemID.uuidString, values: ["center": try .encode(center)])])
  }

  func waitUntil(seconds: Double = 2, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .milliseconds(Int64(seconds * 1_000))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), "The committed IPC action must notify its bounded native projection")
  }
}

