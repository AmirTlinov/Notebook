import AppKit
@testable import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class NotebookHeadlessWorkspaceTests: XCTestCase {
  func testHeadlessIPCReadsPeerContextWithoutPreparingPixelsUntilImageDemand() async {
    do { try await checkPeerContextAndDemandedImage() }
    catch { XCTFail("Headless IPC/observe failed: \(String(reflecting: error))") }
  }

  private func checkPeerContextAndDemandedImage() async throws {
    let fixture = try makeRuntime()
    let runtime = fixture.runtime, store = runtime.store
    let resources = SceneRenderResources.shared
    let physicalOwners = resources.activePhysicalOwnerCount, webSurfaces = resources.activeWebSurfaceCount
    let readCount = NotebookPersistenceFenceContract.Signal<Int>()
    let previous = MacPreviewPublisher.acceptanceConfiguration
    MacPreviewPublisher.acceptanceConfiguration = .init(storeRoot: store.root, currentViewDelay: .zero,
      reconciliationInterval: .milliseconds(25), sourceReader: .init(store: store, beforeRead: {
        readCount.set((readCount.value ?? 0) + 1)
      }))
    defer { MacPreviewPublisher.acceptanceConfiguration = previous }
    await runtime.start(pageSize: .init(width: 96, height: 144))
    XCTAssertEqual(runtime.loadState, .ready)
    let header = try store.workspaceHeader(), item = try XCTUnwrap(store.readItemHeaders(limit: 1).first)
    let page = try XCTUnwrap(item.firstPageID), peer = UUID(), generation = UUID(), session = UUID()
    let presence = SessionPresence(boardID: header.rootBoardID, mode: .page, camera: .init(),
      viewport: .init(x: 96, y: 144), focusedItemID: item.id, openProgress: 1,
      selectedItemID: item.id, notebookPageID: page)
    runtime.connection.peerGenerations[peer] = generation
    runtime.connection.hooks.connected(.init(deviceID: peer, workspaceID: header.workspaceID, displayName: "iPad"), generation)
    runtime.connection.hooks.transient(.presence(.init(sessionID: session, sequence: 1, phase: .settled, presence: presence)), peer, generation)
    let surface = CollaborationTarget(kind: .page, id: page)
    let selection = NotebookSelection(id: UUID(), kind: .empty, surface: surface)
    runtime.connection.hooks.transient(.selection(.init(deviceID: peer, sessionID: session, sequence: 1, selection: selection)), peer, generation)
    let accepted = runtime.persistence.acceptedMutationGeneration
    var read = NotebookCommand(command: .read); read.queries = [.init(kind: .presence), .init(kind: .selection)]
    let response = try await send(read, socket: fixture.socket)
    guard case .array(let values) = response["values"] else { return XCTFail("IPC must return the addressed results") }
    let observedPresence = try values[0].decode(SessionPresence.self)
    let observedSelection = try values[1].decode(NotebookSelectionSnapshot.self)
    XCTAssertEqual(observedPresence, presence)
    XCTAssertEqual(observedSelection.selection, selection)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(readCount.value ?? 0, 0, "Settled iPad context must not request any scene/page source")
    XCTAssertEqual(runtime.persistence.acceptedMutationGeneration, accepted, "Idle render discovery is a WAL read, not a new accepted mutation")
    XCTAssertEqual(resources.activePhysicalOwnerCount, physicalOwners)
    XCTAssertEqual(resources.activeWebSurfaceCount, webSurfaces)
    let idleReceipt = try store.loadCurrentViewReceipt()
    let idleRequests = try store.targetRenderRequests()
    XCTAssertNil(idleReceipt)
    XCTAssertTrue(idleRequests.isEmpty)

    var observe = NotebookCommand(command: .scriptContext)
    observe.scriptContext = .init(method: "observe", arguments: .object(["includeImage": .bool(true)]))
    let image = try await send(observe, socket: fixture.socket)
    XCTAssertEqual(image["value"]?["data"]?["visual"]?["status"], .string("ready"))
    XCTAssertGreaterThan(readCount.value ?? 0, 0)
    let storedReceipt = try store.loadCurrentViewReceipt()
    let receipt = try XCTUnwrap(storedReceipt)
    XCTAssertEqual(receipt.presence, presence)
    XCTAssertNotNil(NSImage(contentsOf: store.currentViewPreviewURL))
  }

  func testLateBackdatedRenderStillPublishesAfterANewerRequestFinished() async throws {
    let fixture = try makeRuntime(), runtime = fixture.runtime, store = fixture.runtime.store
    let previous = MacPreviewPublisher.acceptanceConfiguration
    MacPreviewPublisher.acceptanceConfiguration = .init(storeRoot: store.root, currentViewDelay: .zero,
      reconciliationInterval: .milliseconds(25), sourceReader: .init(store: store))
    defer { MacPreviewPublisher.acceptanceConfiguration = previous }
    await runtime.start(pageSize: .init(width: 96, height: 144))
    let pageID = try XCTUnwrap(store.readItemHeaders(limit: 1).first?.firstPageID)
    let target = CollaborationTarget(kind: .page, id: pageID)
    let newer = try await runtime.persistence.submit(writesStore: true) { store in
      try store.requestTargetRender(target: target, expectedRevision: store.targetContentRevision(target: target),
        region: .init(x: 0, y: 0, width: 24, height: 24))
    }
    try await awaitReceipt(newer, store: store)
    let newerReceipt = try Data(contentsOf: store.targetReceiptURL(newer.id))
    // Let the normal reconciliation observe that all current work has finished.
    try await Task.sleep(for: .milliseconds(100))
    let older = try await runtime.persistence.submit(writesStore: true) { store in
      let incoming = try store.requestTargetRender(target: target, expectedRevision: store.targetContentRevision(target: target),
        region: .init(x: 30, y: 30, width: 24, height: 24))
      let older = TargetRenderRequest(id: incoming.id, target: incoming.target, sourceRevision: incoming.sourceRevision,
        region: incoming.region, worldOrigin: incoming.worldOrigin, pageIndex: incoming.pageIndex,
        pageVisionRevision: incoming.pageVisionRevision, createdAt: newer.createdAt.addingTimeInterval(-60))
      try store.publishRecords(writes: ["collaboration/render-requests/" + older.id.uuidString.lowercased() + ".json": try .encode(older)])
      return older
    }
    try await awaitReceipt(older, store: store)
    XCTAssertEqual(try store.loadTargetRenderReceipt(older.id)?.status, "ready")
    XCTAssertEqual(try Data(contentsOf: store.targetReceiptURL(newer.id)), newerReceipt)
    XCTAssertNil(try store.loadCurrentViewReceipt(), "An addressed render request does not prepare an ambient current view")
  }

  private func awaitReceipt(_ request: TargetRenderRequest, store: NotebookStore) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while try store.loadTargetRenderReceipt(request.id) == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(try store.loadTargetRenderReceipt(request.id), "Accepted target must finish through the actual headless publisher")
  }

  func testFailedShutdownRetainsWriterReaderAndTransportReaderUntilRetry() async throws {
    let fixture = try makeRuntime(), runtime = fixture.runtime
    await runtime.start(pageSize: .init(width: 96, height: 144))
    _ = try await runtime.connection.makeTransportStorage()
    let queue = runtime.persistence, reader = runtime.commandReader, transportReader = runtime.connection.transportReader
    let repaired = NotebookPersistenceFenceContract.Signal<Bool>()
    let marker = runtime.store.root.appendingPathComponent("accepted-tail")
    queue.enqueue { _ in
      guard repaired.value == true else { throw CocoaError(.fileWriteNoPermission) }
      try Data("accepted".utf8).write(to: marker); return false
    }
    let failed = await runtime.shutdown()
    XCTAssertFalse(failed); XCTAssertNotNil(queue.failure)
    XCTAssertTrue(runtime.persistence === queue); XCTAssertTrue(runtime.commandReader === reader)
    XCTAssertTrue(runtime.connection.transportReader === transportReader)
    repaired.set(true); runtime.retryPendingPersistence()
    let stopped = await runtime.shutdown()
    XCTAssertTrue(stopped)
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "accepted")
    XCTAssertEqual(runtime.shutdownPhase, .stopped)
    XCTAssertNil(runtime.connection.transportReader)
  }

  func testAutomaticWorkspaceSealKeepsFreshAuthorshipClosedAndRejectsChangedAcceptance() async throws {
    let fixture = try makeRuntime(opensDefaultAccountWorkspace: true), runtime = fixture.runtime
    await runtime.start(pageSize: .init(width: 96, height: 144))
    let queue = runtime.persistence, reader = runtime.commandReader
    XCTAssertEqual(runtime.workspaceHeader?.cursor, try runtime.store.currentChangeCursor(),
      "Automatic selection starts from the completed bootstrap journal, not its pre-COMMIT header")
    let preparation = await runtime.prepareAutomaticWorkspaceSwitch()
    let original = try XCTUnwrap(preparation)
    let froze = try await runtime.freezeAutomaticWorkspaceSwitch(original)
    XCTAssertTrue(froze, "The exact owner must finish its post-seal read while new authorship stays closed")
    XCTAssertFalse(runtime.permitsExternalWork)
    XCTAssertFalse(runtime.permitsAuthoredWork)
    XCTAssertFalse(queue.permitsNewWorkspaceMutation)
    do {
      _ = try await queue.submit(writesStore: true) { try $0.currentChangeCursor() }
      XCTFail("A new accepted writer crossed the automatic workspace seal")
    } catch {
      XCTAssertEqual((error as? CollaborationError)?.code, "workspace_selection_pending")
    }
    XCTAssertEqual(queue.acceptedMutationGeneration, original.mutationGeneration)
    XCTAssertEqual(try runtime.store.currentChangeCursor(), original.cursor)
    runtime.rollbackAutomaticWorkspaceSwitch(original)
    XCTAssertTrue(runtime.permitsAuthoredWork)
    XCTAssertTrue(queue.permitsNewWorkspaceMutation)

    let nextPreparation = await runtime.prepareAutomaticWorkspaceSwitch()
    let next = try XCTUnwrap(nextPreparation)
    let nextFroze = try await runtime.freezeAutomaticWorkspaceSwitch(next)
    XCTAssertTrue(nextFroze)
    runtime.commitAutomaticWorkspaceSwitch(original)
    runtime.rollbackAutomaticWorkspaceSwitch(original)
    XCTAssertFalse(runtime.permitsAuthoredWork, "A retired transition cannot release its successor's seal")
    XCTAssertFalse(queue.permitsNewWorkspaceMutation)
    runtime.commitAutomaticWorkspaceSwitch(next)
    XCTAssertTrue(runtime.permitsAuthoredWork)
    XCTAssertTrue(queue.permitsNewWorkspaceMutation)
    XCTAssertTrue(runtime.persistence === queue)
    XCTAssertTrue(runtime.commandReader === reader)

    let changedPreparation = await runtime.prepareAutomaticWorkspaceSwitch()
    let changed = try XCTUnwrap(changedPreparation)
    _ = try await queue.submit(writesStore: true) { try $0.currentChangeCursor() }
    let drained = await queue.flush()
    XCTAssertTrue(drained)
    XCTAssertEqual(try runtime.store.currentChangeCursor(), changed.cursor)
    XCTAssertGreaterThan(queue.acceptedMutationGeneration, changed.mutationGeneration)
    let changedFroze = try await runtime.freezeAutomaticWorkspaceSwitch(changed)
    XCTAssertFalse(changedFroze, "Even an accepted material no-op revokes the source's earlier acceptance basis")
    runtime.rollbackAutomaticWorkspaceSwitch(changed)
    XCTAssertTrue(runtime.permitsAuthoredWork)
    XCTAssertTrue(queue.permitsNewWorkspaceMutation)
    XCTAssertEqual(runtime.shutdownPhase, .running)
  }

  private func makeRuntime(opensDefaultAccountWorkspace: Bool = false) throws -> (runtime: NotebookHeadlessWorkspace, socket: URL) {
    let root = URL(fileURLWithPath: "/tmp/nb-runtime-" + UUID().uuidString)
    // The IPC owner creates its private 0700 directory independently of the
    // store, whose bootstrap has already created the workspace directory.
    let socket = root.appendingPathComponent("ipc/runtime.sock"), store = NotebookStore(root: root)
    let suite = "notebook-runtime-tests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let writer = NotebookPersistenceQueue(store: store)
    let runtime = NotebookHeadlessWorkspace(configuration: .init(store: store, persistence: writer,
      commandSocketURL: socket, allowsCodexRegistration: false, pairingActivationID: nil,
      opensDefaultAccountWorkspace: opensDefaultAccountWorkspace, requiresExistingAccountContent: false, expectedWorkspaceID: nil,
      preferences: defaults), startsNearbySync: false)
    addTeardownBlock { @MainActor in
      let saved = await runtime.shutdown(); XCTAssertTrue(saved, runtime.persistenceFailure ?? "")
      if saved { try FileManager.default.removeItem(at: root) }
      defaults.removePersistentDomain(forName: suite)
    }
    return (runtime, socket)
  }
  private func send(_ command: NotebookCommand, socket: URL) async throws -> JSONValue {
    try await Task.detached { try NotebookIPCClient(socketURL: socket).send(command) }.value
  }
}
