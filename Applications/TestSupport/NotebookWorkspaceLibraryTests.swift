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
    let renamed = await owner.renameWorkspace(second, name: "Идеи")
    XCTAssertTrue(renamed, owner.workspaceError ?? "The local rename must complete")
    XCTAssertEqual(owner.model?.workspaceName, "Идеи")
    await owner.openWorkspace(first)
    XCTAssertEqual(owner.selectedWorkspaceID, first)
    await owner.removeWorkspace(second, everywhere: false)
    let secondRoot = try await library.root(for: second)
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondRoot.path))
    XCTAssertEqual(try NotebookStore(root: root).workspaceHeader(), header)
    await owner.removeWorkspace(first, everywhere: false)
    XCTAssertNil(owner.model); XCTAssertTrue(owner.hasNoWorkspace)
    let selectedRoot = try await library.snapshot().selectedRoot
    XCTAssertNil(selectedRoot)
    XCTAssertEqual(try Data(contentsOf: marker), Data("installation-marker".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: NotebookStore(root: root).databaseURL.path))
    XCTAssertEqual(try Data(contentsOf: codex.appendingPathComponent("project.txt")), Data("independent-work".utf8))
    let reopened = launch()
    await reopened.start()
    XCTAssertNil(reopened.model); XCTAssertTrue(reopened.hasNoWorkspace)
    let emptyCatalog = try await library.snapshot().catalog
    XCTAssertTrue(emptyCatalog.entries.isEmpty)
    await reopened.createWorkspace(name: "Заново")
    XCTAssertNotNil(reopened.model)
    XCTAssertNotEqual(reopened.selectedWorkspaceID, first)
    let stopped = await reopened.model?.shutdown() ?? false
    XCTAssertTrue(stopped)
  }

  func testSelectionDataUpgradeAndInterruptedRemovalHaveOneDurableOwner() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("vault-catalog-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), id = UUID(), original = NotebookStore(root: root)
    try original.prepareEmptyWorkspace(workspaceID: id)
    let selection = root.appendingPathExtension("selected-space.json")
    try JSONEncoder().encode(id).write(to: selection)
    let library = NotebookWorkspaceLibrary(originalRoot: root)
    let initialRoot = try await library.snapshot().selectedRoot
    XCTAssertEqual(initialRoot, root)
    _ = try await library.selectFixture(id, name: "First")
    XCTAssertFalse(FileManager.default.fileExists(atPath: selection.path))
    try await library.beginCloudRemoval(id, account: "private-test-account")
    let retiredRoot = try await library.snapshot().selectedRoot
    XCTAssertNil(retiredRoot)
    let pendingCatalog = try await library.snapshot().catalog
    XCTAssertEqual(pendingCatalog.pendingCloudDeletion[id]?.account, "private-test-account")
    // Simulate a process exit after catalog retirement, before file erasure.
    var catalog = try await library.snapshot().catalog
    catalog.entries = []; catalog.selectedID = nil; catalog.pendingCloudDeletion = [:]; catalog.deleting = [id]
    try JSONEncoder().encode(catalog).write(to: root.appendingPathExtension("spaces.json"), options: .atomic)
    try await library.finishRemovals()
    XCTAssertFalse(FileManager.default.fileExists(atPath: original.databaseURL.path))
    let finished = try await library.snapshot()
    XCTAssertTrue(finished.catalog.deleting.isEmpty)
    XCTAssertNil(finished.selectedRoot)
  }

  func testFirstSelectionUsesTheCutAfterItsOwnedRootPreparation() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-first-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), library = NotebookWorkspaceLibrary(originalRoot: root), id = UUID()
    let ticket = try await library.prepareSelection(id, name: "First selection")
    guard case .committed(let committed) = await library.commitSelection(ticket) else {
      XCTFail("Preparing the first root must not reject its own absent catalog cut"); return
    }
    XCTAssertEqual(committed.catalog.selectedID, id)
    XCTAssertEqual(committed.selectedRoot, ticket.root)
    await library.finishSelection(ticket)
    let cold = try await NotebookWorkspaceLibrary(originalRoot: root).snapshot()
    XCTAssertEqual(cold.revision, committed.revision)
    XCTAssertEqual(cold.catalog, committed.catalog)
    XCTAssertEqual(cold.selectedRoot, ticket.root)
  }

  func testFailureBeforePublicationRejectsWithoutChangingSelectionOrBlockingItsSuccessor() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-before-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), originalID = UUID(), fault = WorkspaceCatalogFault()
    try NotebookStore(root: root).prepareEmptyWorkspace(workspaceID: originalID)
    let library = NotebookWorkspaceLibrary(originalRoot: root, fault: fault.check)
    _ = try await library.selectFixture(originalID, name: "Original")
    let catalogURL = root.appendingPathExtension("spaces.json"), before = try Data(contentsOf: catalogURL)
    let id = UUID(), ticket = try await library.prepareSelection(id, name: "Candidate")
    fault.fail([.beforePublication])
    guard case .rejected = await library.commitSelection(ticket) else { XCTFail("A pre-rename failure must be rejected"); return }
    XCTAssertEqual(try Data(contentsOf: catalogURL), before)
    let source = try await library.snapshot()
    XCTAssertEqual(source.catalog.selectedID, originalID)
    fault.fail([])
    let successor = try await library.prepareSelection(id, name: "Candidate")
    XCTAssertNotEqual(successor.id, ticket.id)
    guard case .committed = await library.commitSelection(successor) else { XCTFail("Rejected selection retained the slot"); return }
    await library.finishSelection(successor)
  }

  func testCleanupFailureCannotUndoKnownPublicationOrReplaceItsExactSnapshot() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-cleanup-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), originalID = UUID(), fault = WorkspaceCatalogFault()
    try NotebookStore(root: root).prepareEmptyWorkspace(workspaceID: originalID)
    let library = NotebookWorkspaceLibrary(originalRoot: root, fault: fault.check)
    _ = try await library.selectFixture(originalID, name: "Original")
    let oldSelection = root.appendingPathExtension("selected-space.json")
    try JSONEncoder().encode(originalID).write(to: oldSelection)
    let id = UUID(), ticket = try await library.prepareSelection(id, name: "Published")
    fault.fail([.cleanup])
    guard case .committed(let committed) = await library.commitSelection(ticket) else {
      XCTFail("Old-marker cleanup must not reject a durable selection"); return
    }
    XCTAssertEqual(committed.catalog, ticket.catalog)
    XCTAssertEqual(committed.catalog.selectedID, id)
    XCTAssertNotNil(committed.cleanupFailure)
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldSelection.path))
    await library.finishSelection(ticket)
    let cold = try await NotebookWorkspaceLibrary(originalRoot: root).snapshot()
    XCTAssertEqual(cold.catalog, committed.catalog)
    XCTAssertEqual(cold.revision, committed.revision)
  }

  func testUnknownPublicationRetainsTheSameBytesAndTicketThroughReadFailureAndConflict() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-unknown-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), originalID = UUID(), fault = WorkspaceCatalogFault()
    try NotebookStore(root: root).prepareEmptyWorkspace(workspaceID: originalID)
    let library = NotebookWorkspaceLibrary(originalRoot: root, fault: fault.check)
    _ = try await library.selectFixture(originalID, name: "Original")
    let catalogURL = root.appendingPathExtension("spaces.json"), before = try Data(contentsOf: catalogURL)
    let id = UUID(), ticket = try await library.prepareSelection(id, name: "Exact candidate")
    fault.fail([.afterPublication])
    guard case .unresolved = await library.commitSelection(ticket) else { XCTFail("Lost post-rename acknowledgement must remain unresolved"); return }
    let published = try Data(contentsOf: catalogURL)
    XCTAssertNotEqual(published, before)
    fault.fail([.resolutionRead])
    guard case .unresolved = await library.commitSelection(ticket) else { XCTFail("Retry lost the visible replacement"); return }
    fault.fail([])
    try before.write(to: catalogURL, options: .atomic)
    guard case .unresolved = await library.commitSelection(ticket) else { XCTFail("A conflicting visible replacement must remain owned"); return }
    await library.cancelSelection(ticket)
    do { _ = try await library.snapshot(); XCTFail("Unresolved publication was exposed as a selectable catalog") }
    catch { }
    do { _ = try await library.prepareSelection(UUID()); XCTFail("Another ticket overtook unresolved selection") }
    catch { }
    try published.write(to: catalogURL, options: .atomic)
    guard case .committed(let committed) = await library.commitSelection(ticket) else { XCTFail("Same-ticket Retry did not resolve exact bytes"); return }
    XCTAssertEqual(committed.catalog, ticket.catalog)
    XCTAssertEqual(committed.catalog.selectedID, id)
    XCTAssertEqual(try Data(contentsOf: catalogURL), published)
    await library.finishSelection(ticket)
  }

  func testStaleNameAndDeletionRepliesCannotRebaseAndRefreshCannotRepointSelection() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-cas-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("Notebook"), id = UUID()
    try NotebookStore(root: root).prepareEmptyWorkspace(workspaceID: id)
    let library = NotebookWorkspaceLibrary(originalRoot: root)
    _ = try await library.selectFixture(id, name: "Cloud name")
    let observed = try await library.snapshot()
    let renamed = try await library.rename(id, name: "New local name", expectedRevision: observed.revision)
    do { _ = try await library.refreshCloudNames([id: "Old cloud reply"], expectedRevision: observed.revision); XCTFail("Cloud reply rebased onto a local rename") }
    catch { guard case .workspaceChanged? = error as? NotebookStoreError else { XCTFail("Expected a stale catalog cut"); return } }
    do { _ = try await library.remove(id, expectedRevision: observed.revision); XCTFail("Late deletion removed a newer catalog cut") }
    catch { guard case .workspaceChanged? = error as? NotebookStoreError else { XCTFail("Expected a stale catalog cut"); return } }
    let current = try await library.snapshot()
    XCTAssertEqual(current.revision, renamed.revision)
    XCTAssertEqual(current.catalog.entries.first?.name, "New local name")
    XCTAssertEqual(try NotebookStore(root: root).storedWorkspaceID(), id)
    let otherID = UUID()
    _ = try await library.selectFixture(otherID, name: "Selected destination")
    let refreshed = try await library.registerCurrentWorkspace(id, name: "Stale visible source")
    XCTAssertEqual(refreshed.catalog.selectedID, otherID)
    XCTAssertEqual(refreshed.catalog.entries.first(where: { $0.id == id })?.name, "New local name")
  }

  func testHeldCatalogPublicationSealsNewSourceWorkAndUnknownRetryRetainsBothModels() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-launch-" + UUID().uuidString)
    let root = base.appendingPathComponent("Notebook"), fault = WorkspaceCatalogFault()
    let library = NotebookWorkspaceLibrary(originalRoot: root, fault: fault.check)
    var owners: [(model: NotebookAppModel, writer: NotebookPersistenceQueue)] = []
    let launch = NotebookApplicationLaunch(root: root, libraryOwner: library) { store, _ in
      let writer = NotebookPersistenceQueue(store: store)
      let model = NotebookAppModel(store: store, startsNearbySync: false,
        opensDefaultAccountWorkspace: owners.isEmpty, persistenceQueue: writer)
      owners.append((model, writer)); return model
    }
    let release = DispatchSemaphore(value: 0)
    addTeardownBlock { @MainActor in
      release.signal(); fault.fail([])
      _ = await launch.retryWorkspaceTransition()
      let stopped = await launch.shutdown(); XCTAssertTrue(stopped)
      try FileManager.default.removeItem(at: base)
    }
    await launch.start()
    let source = try XCTUnwrap(launch.model)
    await source.start(pageSize: NotebookAppModel.defaultPageSize)
    await source.finishStartup()
    let sourceID = try XCTUnwrap(source.admittedWorkspaceID)
    _ = try await library.selectFixture(sourceID, name: "Source")
    let id = UUID(), destination = try await library.prepare(id)
    _ = try NotebookStore(root: destination).initializeWorkspace(actor: UUID(), pageSize: NotebookAppModel.defaultPageSize)
    let entered = expectation(description: "The actual catalog actor waits with the source admission sealed")
    let published = expectation(description: "The retained ticket has replaced the catalog before losing its acknowledgement")
    fault.hold(.beforePublication, entered: entered, release: release)
    fault.observe(.afterPublication, entered: published)
    fault.fail([.afterPublication])
    let opening = Task { await launch.openWorkspace(id, automatically: true) }
    await fulfillment(of: [entered], timeout: 5)
    XCTAssertTrue(launch.model === source)
    XCTAssertEqual(owners.count, 2)
    XCTAssertFalse(source.permitsExternalWork)
    XCTAssertFalse(source.inputGate.permitsNewContact)
    let sourceWriter = try XCTUnwrap(owners.first?.writer)
    let generation = sourceWriter.acceptedMutationGeneration, input = source.inputGate.acceptedContactGeneration
    let sourceWorkspace = source.workspace, sourceHierarchy = source.boardHierarchy
    source.inputGate.notifyAcceptedContact()
    XCTAssertEqual(source.inputGate.acceptedContactGeneration, input)
    XCTAssertNil(source.createNotebook(at: .zero))
    XCTAssertEqual(source.workspace, sourceWorkspace)
    XCTAssertEqual(source.boardHierarchy, sourceHierarchy)
    do { _ = try await source.importDocumentFile(base.appendingPathComponent("unread.notex")); XCTFail("Import entered the sealed source") }
    catch { XCTAssertEqual((error as? CollaborationError)?.code, "owner_unavailable") }
    let change = try XCTUnwrap(try source.store.changeJournal(after: 0, limit: 1).first)
    do { _ = try await source.applyDurablePeerChange(change, peerID: UUID()); XCTFail("Peer delivery entered the sealed source") }
    catch { XCTAssertEqual((error as? CollaborationError)?.code, "owner_unavailable") }
    do { _ = try await sourceWriter.submit(writesStore: true) { _ in true }; XCTFail("Direct accepted writer bypassed the source seal") }
    catch { XCTAssertEqual((error as? CollaborationError)?.code, "workspace_selection_pending") }
    #if os(macOS)
      let files = MacNotebookProjectFiles(persistence: sourceWriter)
      let project = CodexProject(id: "sealed", name: "Sealed", roots: [base.path])
      let address = NotebookFileAddress(computer: UUID(), project: project.id, root: base.path, path: "")
      do { _ = try await files.list(address, project: project, after: nil); XCTFail("New FileWork bypassed sealed workspace admission") }
      catch { XCTAssertEqual((error as? CollaborationError)?.code, "workspace_selection_pending") }
      XCTAssertFalse(files.hasPendingWork)
      await files.stopAndDrain()
    #endif
    XCTAssertEqual(sourceWriter.acceptedMutationGeneration, generation)
    opening.cancel(); release.signal()
    await fulfillment(of: [published], timeout: 3)
    await opening.value
    XCTAssertTrue(launch.model === source)
    XCTAssertTrue(launch.canRetryWorkspaceTransition)
    XCTAssertFalse(source.inputGate.permitsNewContact)
    let candidate = try XCTUnwrap(owners.last?.model), bytes = try Data(contentsOf: root.appendingPathExtension("spaces.json"))
    fault.fail([.resolutionRead])
    let blockedRetry = await launch.retryWorkspaceTransition()
    XCTAssertFalse(blockedRetry)
    XCTAssertEqual(owners.count, 2)
    XCTAssertTrue(launch.model === source)
    fault.fail([])
    let retry = await launch.retryWorkspaceTransition()
    XCTAssertTrue(retry)
    XCTAssertTrue(launch.model === candidate)
    XCTAssertEqual(owners.count, 2)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathExtension("spaces.json")), bytes)
    XCTAssertEqual(launch.selectedWorkspaceID, id)
    XCTAssertTrue(candidate.inputGate.permitsNewContact)
    XCTAssertTrue(sourceWriter.permitsNewWorkspaceMutation)
  }
}

private final class WorkspaceCatalogFault: @unchecked Sendable {
  enum Failure: Error { case injected }
  private let lock = NSLock()
  private var failures: Set<NotebookWorkspaceLibrary.FaultPoint> = []
  private var held: (NotebookWorkspaceLibrary.FaultPoint, XCTestExpectation, DispatchSemaphore)?
  private var observations: [NotebookWorkspaceLibrary.FaultPoint: XCTestExpectation] = [:]
  func fail(_ points: Set<NotebookWorkspaceLibrary.FaultPoint>) { lock.withLock { failures = points } }
  func hold(_ point: NotebookWorkspaceLibrary.FaultPoint, entered: XCTestExpectation, release: DispatchSemaphore) {
    lock.withLock { held = (point, entered, release) }
  }
  func observe(_ point: NotebookWorkspaceLibrary.FaultPoint, entered: XCTestExpectation) {
    lock.withLock { observations[point] = entered }
  }
  func check(_ point: NotebookWorkspaceLibrary.FaultPoint) throws {
    let observation = lock.withLock { observations.removeValue(forKey: point) }
    observation?.fulfill()
    let hold = lock.withLock {
      guard held?.0 == point else { return Optional<(NotebookWorkspaceLibrary.FaultPoint, XCTestExpectation, DispatchSemaphore)>.none }
      defer { held = nil }; return held
    }
    if let (_, entered, release) = hold {
      entered.fulfill()
      guard release.wait(timeout: .now() + 10) == .success else { throw Failure.injected }
    }
    if lock.withLock({ failures.contains(point) }) { throw Failure.injected }
  }
}
