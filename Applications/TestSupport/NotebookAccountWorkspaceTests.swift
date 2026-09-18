import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookAccountWorkspaceTests: XCTestCase {
  func testOpeningAccountSpaceWaitsForItsRealMaterialInsteadOfCreatingAnotherNotebook() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("account-workspace-" + UUID().uuidString)
    let suite = "Notebook.tests.account-workspace." + UUID().uuidString
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: base) }
    let source = NotebookStore(root: base.appendingPathComponent("source")), actor = UUID()
    let notebook = UUID(), page = UUID()
    let header = try source.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize,
      initialNotebookID: notebook, initialPageID: page)
    let receiver = NotebookStore(root: base.appendingPathComponent("receiver"))
    try receiver.prepareEmptyWorkspace(workspaceID: header.workspaceID)
    let model = NotebookAppModel(store: receiver, startsNearbySync: false, preferences: preferences,
      requiresExistingAccountContent: true)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertTrue(model.awaitingAccountContent)
    XCTAssertNil(model.workspaceHeader)
    XCTAssertFalse(try receiver.hasWorkspaceContent())
    XCTAssertEqual(try receiver.currentChangeCursor(), 0)
    try await NotebookPeerFixture.deliver(from: source, to: model, peerID: actor)
    for _ in 0..<250 where model.loadState != .ready { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(model.loadState, .ready)
    XCTAssertFalse(model.awaitingAccountContent)
    XCTAssertEqual(model.workspaceHeader?.workspaceID, header.workspaceID)
    XCTAssertEqual(try receiver.readItemHeaders(limit: 10).map(\.id), [notebook])
    XCTAssertNil(try receiver.readItemHeader(NotebookAppModel.initialNotebookID))
    let saved = await model.shutdown()
    XCTAssertTrue(saved)
  }

  func testWaitingForAccountMaterialCanShutDownWithoutHangingOrCreatingContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-wait-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    try store.prepareEmptyWorkspace(workspaceID: UUID())
    let model = NotebookAppModel(store: store, startsNearbySync: false, requiresExistingAccountContent: true)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    XCTAssertTrue(model.awaitingAccountContent)
    let saved = await model.shutdown()
    XCTAssertTrue(saved)
    XCTAssertFalse(try store.hasWorkspaceContent())
  }

  func testAcceptedLocalWorkCancelsAutomaticSelectionAndKeepsInputOpen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("account-local-input-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = NotebookAppModel(store: NotebookStore(root: root), startsNearbySync: false,
      opensDefaultAccountWorkspace: true)
    await model.start(pageSize: NotebookAppModel.defaultPageSize)
    let initiallyEmpty = await model.mayAutomaticallySwitchWorkspace()
    XCTAssertTrue(initiallyEmpty)
    let created = try XCTUnwrap(model.createNotebook(at: .zero))
    let accepted = await model.prepareAutomaticWorkspaceSwitch()
    XCTAssertFalse(accepted)
    XCTAssertEqual(model.shutdownPhase, .running)
    XCTAssertNotNil(try model.store.readItemHeader(created))
    let saved = await model.shutdown()
    XCTAssertTrue(saved)
  }
}
