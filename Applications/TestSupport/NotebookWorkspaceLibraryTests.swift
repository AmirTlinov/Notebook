import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor final class NotebookWorkspaceLibraryTests: XCTestCase {
  func testLocalLifecycleKeepsIndependentDataAndDoesNotRecreateTheDeletedLastSpace() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("vault-lifecycle-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), library = NotebookWorkspaceLibrary(originalRoot: root)
    func launch() -> NotebookApplicationLaunch {
      .init(root: root, makeModel: { store, _ in NotebookAppModel(store: store, startsNearbySync: false) })
    }
    let owner = launch()
    await owner.start()
    await owner.model?.start(pageSize: NotebookAppModel.defaultPageSize)
    let first = try XCTUnwrap(owner.model?.store.storedWorkspaceID())
    let header = try XCTUnwrap(owner.model?.store.workspaceHeader())
    let marker = root.appendingPathComponent(".notebook-activation.json")
    try Data("installation-marker".utf8).write(to: marker)
    let codex = root.appendingPathComponent("Codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: false)
    try Data("independent-work".utf8).write(to: codex.appendingPathComponent("project.txt"))
    await owner.refreshWorkspaces()
    await owner.createWorkspace(name: "Работа")
    let second = try XCTUnwrap(owner.selectedWorkspaceID)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(owner.model?.workspaceName, "Работа")
    XCTAssertTrue(owner.workspaceList.contains(where: { $0.id == second && $0.name == "Работа" && $0.local }))
    XCTAssertEqual(try NotebookStore(root: root).workspaceHeader(), header)
    await owner.renameWorkspace(second, name: "Идеи")
    XCTAssertEqual(owner.model?.workspaceName, "Идеи")
    await owner.openWorkspace(first)
    XCTAssertEqual(owner.selectedWorkspaceID, first)
    await owner.removeWorkspace(second, everywhere: false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: try library.root(for: second).path))
    XCTAssertEqual(try NotebookStore(root: root).workspaceHeader(), header)
    await owner.removeWorkspace(first, everywhere: false)
    XCTAssertNil(owner.model); XCTAssertTrue(owner.hasNoWorkspace)
    XCTAssertNil(try library.selectedRoot())
    XCTAssertEqual(try Data(contentsOf: marker), Data("installation-marker".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: NotebookStore(root: root).databaseURL.path))
    XCTAssertEqual(try Data(contentsOf: codex.appendingPathComponent("project.txt")), Data("independent-work".utf8))
    let reopened = launch()
    await reopened.start()
    XCTAssertNil(reopened.model); XCTAssertTrue(reopened.hasNoWorkspace)
    XCTAssertTrue(try library.catalog().entries.isEmpty)
    await reopened.createWorkspace(name: "Заново")
    XCTAssertNotNil(reopened.model)
    XCTAssertNotEqual(reopened.selectedWorkspaceID, first)
    let stopped = await reopened.model?.shutdown() ?? false
    XCTAssertTrue(stopped)
  }

  func testSelectionDataUpgradeAndInterruptedRemovalHaveOneDurableOwner() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("vault-catalog-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), id = UUID(), original = NotebookStore(root: root)
    try original.prepareEmptyWorkspace(workspaceID: id)
    let selection = root.appendingPathExtension("selected-space.json")
    try JSONEncoder().encode(id).write(to: selection)
    let library = NotebookWorkspaceLibrary(originalRoot: root)
    XCTAssertEqual(try library.selectedRoot(), root)
    _ = try library.select(id, name: "First")
    XCTAssertFalse(FileManager.default.fileExists(atPath: selection.path))
    try library.beginCloudRemoval(id, account: "private-test-account")
    XCTAssertNil(try library.selectedRoot())
    XCTAssertEqual(try library.catalog().pendingCloudDeletion[id]?.account, "private-test-account")
    // Simulate a process exit after catalog retirement, before file erasure.
    var catalog = try library.catalog()
    catalog.entries = []; catalog.selectedID = nil; catalog.pendingCloudDeletion = [:]; catalog.deleting = [id]
    try JSONEncoder().encode(catalog).write(to: root.appendingPathExtension("spaces.json"), options: .atomic)
    try library.finishRemovals()
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.databaseURL.path))
    XCTAssertTrue(try library.catalog().deleting.isEmpty)
    XCTAssertNil(try library.selectedRoot())
  }
}
