@testable import NotebookCore
import Security
import XCTest
@testable import Notebook
#if os(macOS)
import NotebookCodex
#endif

@MainActor
final class NotebookArchiveLaunchTests: XCTestCase {
  #if os(iOS)
    func testCommittedSelectionRetainsItsOriginalWriterUntilTheSameRetirementRetries() async throws {
      enum Fault: Error { case storageUnavailable }
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-retirement-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
      let root = base.appendingPathComponent("Notebook"), armed = base.appendingPathComponent("armed")
      let repaired = base.appendingPathComponent("repaired")
      let blocked = expectation(description: "The original accepted writer is held after its commit")
      var owners: [(model: NotebookAppModel, writer: NotebookPersistenceQueue)] = []
      let launch = NotebookApplicationLaunch(root: root) { store, _ in
        let original = owners.isEmpty
        let admitted = NotebookStore(root: store.root, storageFault: { phase in
          if original, phase == .afterCommit, FileManager.default.fileExists(atPath: armed.path),
            !FileManager.default.fileExists(atPath: repaired.path) { throw Fault.storageUnavailable }
        })
        let writer = NotebookPersistenceQueue(store: admitted)
        let model = NotebookAppModel(store: admitted, startsNearbySync: false, persistenceQueue: writer)
        if original {
          let receive = writer.onFailureChange
          writer.onFailureChange = { message in receive?(message); if message != nil { blocked.fulfill() } }
        } else {
          try Data().write(to: armed)
          let sourceWriter = try XCTUnwrap(owners.first?.writer)
          // New accepted source work arrives after initial preparation. A
          // manual selection may commit, but retirement must keep this FIFO.
          sourceWriter.enqueueCommand(writesStore: true, { source in
            try source.publishRecords(writes: ["local/transition-tail.json": .string("retained exactly")])
            return true
          }, completion: { _ in })
        }
        owners.append((model, writer)); return model
      }
      addTeardownBlock { @MainActor in
        try Data().write(to: repaired)
        for owner in owners { owner.writer.retry() }
        _ = await launch.shutdown()
        try FileManager.default.removeItem(at: base)
      }
      await launch.start()
      let original = try XCTUnwrap(launch.model)
      let originalWriter = try XCTUnwrap(owners.first?.writer)
      await original.start(pageSize: NotebookAppModel.defaultPageSize)
      let sourceID = try XCTUnwrap(original.admittedWorkspaceID), destinationID = UUID()
      await launch.openWorkspace(destinationID, creatingName: "New selection")
      await fulfillment(of: [blocked], timeout: 3)
      let selected = try XCTUnwrap(launch.model)
      XCTAssertFalse(selected === original)
      XCTAssertEqual(owners.count, 2)
      XCTAssertEqual(launch.selectedWorkspaceID, destinationID)
      XCTAssertEqual(original.admittedWorkspaceID, sourceID)
      XCTAssertEqual(original.shutdownPhase, .closing)
      XCTAssertGreaterThan(originalWriter.pendingCount, 0)
      XCTAssertTrue(launch.hasPendingWorkspaceRetirement)
      XCTAssertEqual(try original.store.storedValue("local/transition-tail.json"), .string("retained exactly"))
      try Data().write(to: repaired)
      let finished = await launch.retryWorkspaceTransition()
      XCTAssertTrue(finished)
      XCTAssertTrue(launch.model === selected)
      XCTAssertEqual(owners.count, 2, "Retirement Retry keeps the original writer instead of constructing another owner")
      XCTAssertEqual(original.admittedWorkspaceID, sourceID)
      XCTAssertEqual(original.shutdownPhase, .stopped)
      XCTAssertEqual(originalWriter.pendingCount, 0)
      XCTAssertFalse(launch.hasPendingWorkspaceRetirement)
      XCTAssertNil(launch.workspaceError)
      XCTAssertEqual(try original.store.storedValue("local/transition-tail.json"), .string("retained exactly"))
    }
  #endif

  #if os(macOS)
    func testRuntimeRetryCoalescesCodexAdmissionAfterDiscoveryFailure() async throws {
      let run = UUID(), actor = UUID()
      let base = URL(fileURLWithPath: "/tmp/" + run.uuidString.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = base.appendingPathComponent("Notebook"), socket = base.appendingPathComponent("bridge.sock")
      let suite = "Notebook.tests.codex-recovery." + run.uuidString
      let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
      preferences.set(actor.uuidString, forKey: "notebook.actor-id")
      let entering = expectation(description: "Retry reaches the original Codex admission")
      let discovery = CodexDiscoveryFault(entering: entering)
      let host = NotebookCodexHost(discoverInstallation: { try discovery.discover() })
      var constructions = 0
      let launch = NotebookApplicationLaunch(root: root, runtimeSocketURL: socket) { store, _ in
        constructions += 1
        let header = try store.initializeWorkspace(actor: actor, pageSize: NotebookAppModel.defaultPageSize)
        let key = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        let endpoint = base.appendingPathComponent(key + ".sock")
        let canonicalRoot = store.root.standardizedFileURL.resolvingSymlinksInPath()
        let bundle = "com.amirtlinov.notebook.mac.acceptance." + String(run.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let acceptance = NotebookAcceptanceConfiguration(version: 1, runID: run, workspaceID: header.workspaceID,
          actorID: actor, role: .mac, bundleID: bundle,
          sourceRevision: String(repeating: "0", count: 40), root: canonicalRoot.path,
          socket: endpoint.path, codexDirectory: canonicalRoot.appendingPathComponent("Codex").path)
        try acceptance.validate(bundle: acceptance.bundleID, enabled: true)
        let model = NotebookAppModel(store: store, startsNearbySync: false, commandSocketURL: endpoint,
          preferences: preferences, acceptance: acceptance)
        model.codexHost = host
        return model
      }
      addTeardownBlock { @MainActor in
        discovery.release.signal()
        _ = await launch.shutdown()
        preferences.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: base)
      }
      await launch.start()
      let model = try XCTUnwrap(launch.model, launch.failure ?? "Runtime launch did not construct its admitted model")
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      let workspaceID = try XCTUnwrap(model.workspaceHeader?.workspaceID)
      await model.startCodexSidecar()
      XCTAssertNotNil(model.agentStartupError); XCTAssertEqual(discovery.attempts, 1)
      var retry = NotebookCommand(command: .runtimeWorkspace)
      retry.runtimeWorkspace = .init(action: .retry, id: workspaceID)
      let first = Task.detached { [retry] in
        try NotebookIPCClient(socketURL: socket).send(retry).decode(NotebookRuntimeWorkspaceResponse.self)
      }
      await fulfillment(of: [entering], timeout: 3)
      XCTAssertFalse(launch.isChecking, "Codex admission does not replace the workspace transition owner")
      let second = Task.detached { [retry] in
        try NotebookIPCClient(socketURL: socket).send(retry).decode(NotebookRuntimeWorkspaceResponse.self)
      }
      discovery.release.signal()
      for response in [try await first.value, try await second.value] {
        XCTAssertEqual(response.status.state, .ready); XCTAssertNil(response.error)
        XCTAssertEqual(response.status.workspaceID, workspaceID)
      }
      XCTAssertNil(model.agentStartupError)
      XCTAssertTrue(launch.model === model); XCTAssertTrue(model.codexHost === host)
      XCTAssertEqual(constructions, 1); XCTAssertEqual(discovery.attempts, 2)
      _ = try await launch.executeRuntimeCommand(retry)
      XCTAssertEqual(discovery.attempts, 2, "An admitted AppServer and workspace route are reused")
      let stopped = await launch.shutdown(); XCTAssertTrue(stopped)
      await model.startCodexSidecar()
      XCTAssertEqual(discovery.attempts, 2, "Shutdown closes Codex admission")
    }

    func testRuntimeBootstrapAndCreateRetryKeepTheAcceptedOwnerAndWorkspaceAddress() async throws {
      enum Fault: Error { case storageUnavailable }
      for (creating, retiringWhileBlocked) in [(false, false), (true, false), (true, true)] {
        let base = URL(fileURLWithPath: "/tmp/nb-start-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = base.appendingPathComponent("Notebook"), socket = base.appendingPathComponent("bridge.sock")
        let repaired = base.appendingPathComponent("repaired")
        let blocked = expectation(description: "Accepted bootstrap reports its storage fault")
        var owners: [(model: NotebookAppModel, writer: NotebookPersistenceQueue)] = []
        let launch = NotebookApplicationLaunch(root: root, runtimeSocketURL: socket) { store, _ in
          if retiringWhileBlocked, owners.count == 2 {
            XCTAssertEqual(owners[1].writer.pendingCount, 0, "A replacement cannot precede the hidden candidate's accepted result")
            XCTAssertNil(owners[1].writer.failure)
            XCTAssertEqual(owners[1].model.shutdownPhase, .stopped)
          }
          let faults = owners.count == (creating ? 1 : 0)
          let admitted = NotebookStore(root: store.root, storageFault: { phase in
            if faults, phase == .afterCommit, !FileManager.default.fileExists(atPath: repaired.path) { throw Fault.storageUnavailable }
          })
          let writer = NotebookPersistenceQueue(store: admitted)
          let key = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
          let model = NotebookAppModel(store: admitted, startsNearbySync: false,
            commandSocketURL: base.appendingPathComponent(key + ".sock"), persistenceQueue: writer)
          let receive = writer.onFailureChange
          writer.onFailureChange = { message in receive?(message); if message != nil { blocked.fulfill() } }
          owners.append((model, writer)); return model
        }
        addTeardownBlock { @MainActor in
          try Data().write(to: repaired)
          for owner in owners { owner.writer.retry() }
          _ = await launch.shutdown()
          try FileManager.default.removeItem(at: base)
        }
        await launch.start()
        let first = try XCTUnwrap(launch.model)
        if creating { await first.start(pageSize: NotebookAppModel.defaultPageSize) }
        let previousID = first.workspaceHeader?.workspaceID, requestedID = UUID()
        let returned = expectation(description: "Bootstrap observer returns without abandoning its write")
        var didReturn = false
        let opening = Task { @MainActor in
          if creating {
            var create = NotebookCommand(command: .runtimeWorkspace)
            create.runtimeWorkspace = .init(action: .create, id: requestedID, name: "После восстановления")
            _ = try? await launch.executeRuntimeCommand(create)
          } else { await first.start(pageSize: NotebookAppModel.defaultPageSize) }
          didReturn = true; returned.fulfill()
        }
        await fulfillment(of: [blocked, returned], timeout: 3)
        guard didReturn else {
          try Data().write(to: repaired); for owner in owners { owner.writer.retry() }
          await opening.value; return
        }
        let candidate = try XCTUnwrap(owners.last?.model), writer = try XCTUnwrap(owners.last?.writer)
        XCTAssertFalse(launch.isChecking); XCTAssertTrue(candidate.runtimeStartupPending)
        XCTAssertGreaterThan(writer.pendingCount, 0)
        let id = try (creating ? requestedID : candidate.store.storedWorkspaceID())
        if creating {
          XCTAssertFalse(candidate === first); XCTAssertEqual(first.shutdownPhase, .running)
          XCTAssertTrue(launch.model === first, "The original scene remains selected until the destination commits")
          XCTAssertEqual(launch.selectedWorkspaceID, first.admittedWorkspaceID)
          let selected = try await NotebookWorkspaceLibrary(originalRoot: root).snapshot().catalog.selectedID
          XCTAssertEqual(selected, previousID)
          var other = NotebookCommand(command: .runtimeWorkspace)
          other.runtimeWorkspace = .init(action: .create, id: UUID(), name: "Cannot displace the accepted candidate")
          do { _ = try await launch.executeRuntimeCommand(other); XCTFail("A pending candidate must retain its transition") }
          catch let error as CollaborationError { XCTAssertEqual(error.code, "owner_unavailable") }
        }
        let constructions = owners.count
        if retiringWhileBlocked {
          let stopped = await launch.shutdown()
          XCTAssertFalse(stopped)
          XCTAssertGreaterThan(writer.pendingCount, 0)
          XCTAssertEqual(owners.count, constructions)
        }
        try Data().write(to: repaired)
        var retry = NotebookCommand(command: .runtimeWorkspace); retry.runtimeWorkspace = .init(action: .retry, id: id)
        let response = try await Task.detached { [retry] in
          try NotebookIPCClient(socketURL: socket).send(retry).decode(NotebookRuntimeWorkspaceResponse.self)
        }.value
        XCTAssertEqual(response.status.state, .ready); XCTAssertEqual(response.status.workspaceID, id)
        XCTAssertNil(response.error)
        if retiringWhileBlocked {
          XCTAssertFalse(launch.model === candidate)
          XCTAssertEqual(candidate.shutdownPhase, .stopped)
          XCTAssertEqual(owners.count, constructions + 1, "The terminal owner is replaced only after its original accepted queue drains")
        } else {
          XCTAssertTrue(launch.model === candidate)
          XCTAssertEqual(owners.count, constructions)
        }
        XCTAssertFalse(candidate.runtimeStartupPending)
        XCTAssertEqual(writer.pendingCount, 0)
        XCTAssertEqual(try candidate.store.storedWorkspaceID(), id)
        if creating {
          let selected = try await NotebookWorkspaceLibrary(originalRoot: root).snapshot().catalog.selectedID
          XCTAssertEqual(selected, requestedID)
        }
      }
    }

    func testAutomaticOpeningRollsBackNewSourceWorkAndRetryCannotCreateASuccessor() async throws {
      enum Fault: Error { case storageUnavailable }
      let base = URL(fileURLWithPath: "/tmp/nb-auto-cut-" + UUID().uuidString.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = base.appendingPathComponent("Notebook"), socket = base.appendingPathComponent("bridge.sock")
      let repaired = base.appendingPathComponent("repaired"), library = NotebookWorkspaceLibrary(originalRoot: root)
      let blocked = expectation(description: "The exact destination startup is retained after its storage fault")
      var owners: [(model: NotebookAppModel, writer: NotebookPersistenceQueue)] = []
      let launch = NotebookApplicationLaunch(root: root, runtimeSocketURL: socket) { store, _ in
        let candidate = !owners.isEmpty
        let admitted = NotebookStore(root: store.root, storageFault: { phase in
          if candidate, phase == .afterCommit, !FileManager.default.fileExists(atPath: repaired.path) { throw Fault.storageUnavailable }
        })
        let writer = NotebookPersistenceQueue(store: admitted)
        let key = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        let model = NotebookAppModel(store: admitted, startsNearbySync: false,
          commandSocketURL: base.appendingPathComponent(key + ".sock"), opensDefaultAccountWorkspace: !candidate,
          persistenceQueue: writer)
        let receive = writer.onFailureChange
        writer.onFailureChange = { message in receive?(message); if message != nil { blocked.fulfill() } }
        owners.append((model, writer)); return model
      }
      addTeardownBlock { @MainActor in
        try Data().write(to: repaired)
        for owner in owners { owner.writer.retry() }
        _ = await launch.shutdown()
        try FileManager.default.removeItem(at: base)
      }
      await launch.start()
      let previous = try XCTUnwrap(launch.model)
      await previous.start(pageSize: NotebookAppModel.defaultPageSize)
      let sourceID = try XCTUnwrap(previous.admittedWorkspaceID), candidateID = UUID()
      let destination = try await library.prepare(candidateID)
      _ = try NotebookStore(root: destination).initializeWorkspace(actor: UUID(), pageSize: NotebookAppModel.defaultPageSize)
      _ = try await library.selectFixture(candidateID, name: "Account destination")
      _ = try await library.selectFixture(sourceID, name: "Original source")
      let returned = expectation(description: "Opening observer returns while the accepted startup survives")
      let opening = Task { await launch.openWorkspace(candidateID, automatically: true); returned.fulfill() }
      await fulfillment(of: [blocked, returned], timeout: 3)
      guard owners.count == 2, owners.last?.writer.failure != nil else {
        await opening.value
        XCTFail("The scenario must retain its exact blocked destination before source input or Retry")
        return
      }
      XCTAssertTrue(launch.model === previous)
      XCTAssertEqual(previous.shutdownPhase, .running)
      XCTAssertTrue(previous.permitsExternalWork && previous.inputGate.permitsNewContact)
      XCTAssertFalse(previous.permitsBackgroundPreparation)
      XCTAssertEqual(launch.selectedWorkspaceID, sourceID)
      XCTAssertEqual(owners.count, 2)
      let candidate = try XCTUnwrap(owners.last?.model)
      XCTAssertTrue(candidate.runtimeStartupPending)
      let acceptedResult = await previous.createNotebook(at: .zero)
      let accepted = try XCTUnwrap(acceptedResult)
      let sourceSaved = await previous.finishPendingPersistence()
      XCTAssertTrue(sourceSaved)
      try Data().write(to: repaired)
      var retry = NotebookCommand(command: .runtimeWorkspace)
      retry.runtimeWorkspace = .init(action: .retry, id: candidateID)
      _ = try await launch.executeRuntimeCommand(retry)
      await opening.value
      XCTAssertTrue(launch.model === previous)
      XCTAssertEqual(launch.selectedWorkspaceID, sourceID)
      let selectedCatalog = try await library.snapshot().catalog
      XCTAssertEqual(selectedCatalog.selectedID, sourceID)
      XCTAssertEqual(owners.count, 2, "Retry resumes the retained attempt; newer source work cancels it without a replacement")
      XCTAssertEqual(previous.shutdownPhase, .running)
      XCTAssertTrue(previous.permitsExternalWork && previous.inputGate.permitsNewContact)
      XCTAssertNotNil(try previous.store.readItemHeader(accepted))
      XCTAssertEqual(candidate.shutdownPhase, .stopped)
      XCTAssertFalse(launch.hasPendingWorkspaceRetirement)
    }

    func testRuntimeShutdownReturnsBlockedAndRetriesTheAcceptedIPCMutationBeforeRetiringItsOwner() async throws {
      enum Fault: Error { case storageUnavailable }
      let base = URL(fileURLWithPath: "/tmp/nb-stop-" + UUID().uuidString.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = base.appendingPathComponent("Notebook"), socket = base.appendingPathComponent("bridge.sock")
      let armed = base.appendingPathComponent("armed"), repaired = base.appendingPathComponent("repaired")
      var owners: [(model: NotebookAppModel, writer: NotebookPersistenceQueue, socket: URL)] = []
      let launch = NotebookApplicationLaunch(root: root, runtimeSocketURL: socket) { store, _ in
        let admitted = NotebookStore(root: store.root, storageFault: { phase in
          if phase == .afterCommit, FileManager.default.fileExists(atPath: armed.path),
            !FileManager.default.fileExists(atPath: repaired.path) { throw Fault.storageUnavailable }
        })
        let writer = NotebookPersistenceQueue(store: admitted)
        let key = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        let endpoint = base.appendingPathComponent(key + ".sock")
        let model = NotebookAppModel(store: admitted, startsNearbySync: false, commandSocketURL: endpoint, persistenceQueue: writer)
        owners.append((model, writer, endpoint)); return model
      }
      addTeardownBlock { @MainActor in
        try Data().write(to: repaired)
        for owner in owners { owner.writer.retry() }
        _ = await launch.shutdown()
        try FileManager.default.removeItem(at: base)
      }
      await launch.start()
      let original = try XCTUnwrap(owners.first)
      await original.model.start(pageSize: NotebookAppModel.defaultPageSize)
      let initiallySaved = await original.model.finishPendingInteraction(); XCTAssertTrue(initiallySaved)
      let workspaceID = try XCTUnwrap(original.model.workspaceHeader?.workspaceID)
      let page = CollaborationTarget(kind: .page, id: try XCTUnwrap(original.model.workspace?.selectedPageID))
      let actionID = UUID(), strokeID = UUID()
      var edit = NotebookCommand(command: .panelEdit)
      edit.panelEdit = .init(workspaceID: workspaceID, actionID: actionID, target: page,
        summary: "Accepted IPC stroke", operations: [.init(kind: .appendInkStroke, target: page, id: strokeID.uuidString,
          values: ["width": .number(4), "points": .array([.object(["x": .number(100), "y": .number(120)]),
            .object(["x": .number(160), "y": .number(190)])])])], sources: [])
      let blocked = expectation(description: "IPC mutation retains its result after an unknown commit")
      let receive = original.writer.onFailureChange
      original.writer.onFailureChange = { message in receive?(message); if message != nil { blocked.fulfill() } }
      try Data().write(to: armed)
      let accepted = Task.detached { [edit, endpoint = original.socket] in try NotebookIPCClient(socketURL: endpoint).send(edit) }
      await fulfillment(of: [blocked], timeout: 3)
      XCTAssertNotNil(original.writer.failure)
      let peer = NotebookStore(root: root), savedResult = try XCTUnwrap(try peer.savedActionResult(actionID))
      let returned = expectation(description: "Shutdown releases its observer while retaining the same terminal task")
      var shutdownResult: Bool?
      let closing = Task { @MainActor in shutdownResult = await launch.shutdown(); returned.fulfill() }
      await fulfillment(of: [returned], timeout: 3)
      guard let shutdownResult else {
        try Data().write(to: repaired); original.writer.retry(); await closing.value; return
      }
      XCTAssertFalse(shutdownResult); XCTAssertEqual(original.model.shutdownPhase, .closing)
      let secondQuit = await launch.shutdown(); XCTAssertFalse(secondQuit)
      let status = try await Task.detached {
        try NotebookIPCClient(socketURL: socket).send(.init(command: .runtimeStatus)).decode(NotebookRuntimeBootstrapStatus.self)
      }.value
      XCTAssertTrue(status.ready); XCTAssertEqual(status.state, .failed)
      XCTAssertGreaterThan(original.writer.pendingCount, 0)
      try Data().write(to: repaired)
      var retry = NotebookCommand(command: .runtimeWorkspace); retry.runtimeWorkspace = .init(action: .retry, id: workspaceID)
      let recovered = try await Task.detached { [retry] in
        try NotebookIPCClient(socketURL: socket).send(retry).decode(NotebookRuntimeWorkspaceResponse.self)
      }.value
      XCTAssertEqual(recovered.status.state, .ready); XCTAssertEqual(recovered.status.workspaceID, workspaceID)
      XCTAssertEqual(original.model.shutdownPhase, .stopped); XCTAssertEqual(original.writer.pendingCount, 0)
      XCTAssertEqual(owners.count, 2)
      _ = await accepted.result
      let current = try XCTUnwrap(owners.last)
      let settled = await current.model.finishPendingInteraction(); XCTAssertTrue(settled)
      let cursor = try peer.currentChangeCursor()
      let repeated = try await Task.detached { [edit, endpoint = current.socket] in try NotebookIPCClient(socketURL: endpoint).send(edit) }.value
      XCTAssertEqual(repeated, savedResult); XCTAssertEqual(try peer.currentChangeCursor(), cursor)
      XCTAssertEqual(try peer.loadPage(page.id).inkDrawing().activeActions.filter { $0.id == strokeID }.count, 1)
      let finalQuit = await launch.shutdown(); XCTAssertTrue(finalQuit)
    }

    func testRuntimeRetriesRetainedAcceptedWritesWithoutQuitOrWorkspaceSwitch() async throws {
      enum Failure: Error { case storageUnavailable }
      let base = URL(fileURLWithPath: "/tmp/nb-runtime-" + UUID().uuidString.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = base.appendingPathComponent("Notebook"), socket = base.appendingPathComponent("bridge.sock")
      let repaired = base.appendingPathComponent("repaired"), accepted = base.appendingPathComponent("accepted")
      var writers: [NotebookPersistenceQueue] = []
      var constructions = 0
      let launch = NotebookApplicationLaunch(root: root, runtimeSocketURL: socket) { store, _ in
        constructions += 1
        let persistence = NotebookPersistenceQueue(store: store); writers.append(persistence)
        let key = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        return NotebookAppModel(store: store, startsNearbySync: false,
          commandSocketURL: base.appendingPathComponent(key + ".sock"), persistenceQueue: persistence)
      }
      addTeardownBlock { @MainActor in
        try Data().write(to: repaired)
        for writer in writers { writer.retry() }
        _ = await launch.shutdown()
        try FileManager.default.removeItem(at: base)
      }
      await launch.start()
      let model = try XCTUnwrap(launch.model), persistence = try XCTUnwrap(writers.first)
      await model.start(pageSize: NotebookAppModel.defaultPageSize)
      let firstID = try XCTUnwrap(model.workspaceHeader?.workspaceID)
      var create = NotebookCommand(command: .runtimeWorkspace)
      create.runtimeWorkspace = .init(action: .create, id: UUID(), name: "Второе")
      let second = try await launch.executeRuntimeCommand(create).decode(NotebookRuntimeWorkspaceResponse.self)
      let selected = try XCTUnwrap(launch.model)
      XCTAssertEqual(second.status.state, .ready); XCTAssertNil(second.error)
      XCTAssertNotEqual(second.status.workspaceID, firstID)
      persistence.enqueue { _ in
        guard FileManager.default.fileExists(atPath: repaired.path) else { throw Failure.storageUnavailable }
        try Data("first".utf8).write(to: accepted); return false
      }
      persistence.enqueue { _ in
        try (Data(contentsOf: accepted) + Data(" second".utf8)).write(to: accepted); return false
      }
      let pageID = try XCTUnwrap(model.workspace?.selectedPageID)
      let contextCount = try model.store.sharedContexts().contexts.count
      model.publishHumanContext(.init(fragments: [.init(target: .init(kind: .page, id: pageID),
        elementID: nil, region: .init(x: 20, y: 20, width: 100, height: 100),
        worldOrigin: nil, pageIndex: nil, label: "Принятый фрагмент")],
        workspace: try XCTUnwrap(model.workspace), hierarchy: try XCTUnwrap(model.boardHierarchy),
        ink: try XCTUnwrap(model.spatialInk), pages: model.pages, documents: model.documents, states: model.documentStates),
        text: "Retained human context")
      let saved = await persistence.flush(); XCTAssertFalse(saved)
      let status = try await launch.executeRuntimeCommand(.init(command: .runtimeStatus)).decode(NotebookRuntimeBootstrapStatus.self)
      XCTAssertTrue(status.ready); XCTAssertEqual(status.state, .failed)
      XCTAssertNotNil(status.socketKey); XCTAssertEqual(model.shutdownPhase, .running)
      var retry = NotebookCommand(command: .runtimeWorkspace); retry.runtimeWorkspace = .init(action: .retry, id: firstID)
      for _ in 0..<3 {
        let blocked = try await Task.detached { [retry] in
          try NotebookIPCClient(socketURL: socket).send(retry).decode(NotebookRuntimeWorkspaceResponse.self)
        }.value
        XCTAssertEqual(blocked.status.state, .failed); XCTAssertNotNil(blocked.error)
        XCTAssertTrue(model.selectionSession.isResolvingContext)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accepted.path),
          "Failed Retry retains the addressed commands before their effects; independent publication may use the same FIFO")
        XCTAssertLessThanOrEqual(persistence.observedLifecycleTaskCount, 1,
          "Failed Retry observes the one retained publication without accumulating finish tasks")
        XCTAssertEqual(try model.store.sharedContexts().contexts.count, contextCount)
      }
      try Data().write(to: repaired)
      let recovered = try await Task.detached { [retry] in
        try NotebookIPCClient(socketURL: socket).send(retry).decode(NotebookRuntimeWorkspaceResponse.self)
      }.value
      XCTAssertEqual(recovered.status.state, .ready); XCTAssertNil(recovered.error)
      XCTAssertEqual(recovered.status.workspaceID, firstID); XCTAssertEqual(recovered.status.socketKey, model.runtimeSocketKey)
      XCTAssertTrue(launch.model === selected); XCTAssertEqual(constructions, 2)
      XCTAssertEqual(model.shutdownPhase, .running); XCTAssertEqual(persistence.pendingCount, 0)
      XCTAssertEqual(persistence.observedLifecycleTaskCount, 0)
      XCTAssertFalse(model.selectionSession.isResolvingContext)
      XCTAssertEqual(try model.store.sharedContexts().contexts.count, contextCount + 1)
      let entries = try model.store.sharedContexts().contexts.flatMap(\.entries)
      XCTAssertEqual(entries.filter { $0.text == "Retained human context" }.count, 1)
      XCTAssertEqual(try String(contentsOf: accepted, encoding: .utf8), "first second")
    }

    func testRuntimeRetryDrainsRetainedAcceptedWritesBeforeReplacingWorkspaceOwners() async throws {
      enum Failure: Error { case storageUnavailable }
      let base = URL(fileURLWithPath: "/tmp/nb-runtime-" + UUID().uuidString.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = base.appendingPathComponent("Notebook"), socket = base.appendingPathComponent("bridge.sock")
      let repaired = base.appendingPathComponent("repaired"), accepted = base.appendingPathComponent("accepted")
      var owners: [(model: NotebookAppModel, writer: NotebookPersistenceQueue)] = []
      let launch = NotebookApplicationLaunch(root: root, runtimeSocketURL: socket) { store, _ in
        for previous in owners where previous.model.store.root == store.root {
          XCTAssertEqual(previous.model.shutdownPhase, .stopped)
          XCTAssertEqual(previous.writer.pendingCount, 0, "The replacement must wait for its previous writer's accepted tail")
        }
        let writer = NotebookPersistenceQueue(store: store)
        let key = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        let model = NotebookAppModel(store: store, startsNearbySync: false,
          commandSocketURL: base.appendingPathComponent(key + ".sock"), persistenceQueue: writer)
        owners.append((model, writer))
        return model
      }
      addTeardownBlock { @MainActor in
        try Data().write(to: repaired)
        for owner in owners { owner.writer.retry() }
        _ = await launch.shutdown()
        try FileManager.default.removeItem(at: base)
      }
      await launch.start()
      let first = try XCTUnwrap(launch.model)
      await first.start(pageSize: NotebookAppModel.defaultPageSize)
      XCTAssertEqual(first.loadState, .ready)
      let firstID = try XCTUnwrap(first.workspaceHeader?.workspaceID)
      func send(_ request: NotebookRuntimeWorkspaceRequest) async throws -> NotebookRuntimeWorkspaceResponse {
        var command = NotebookCommand(command: .runtimeWorkspace); command.runtimeWorkspace = request
        return try await Task.detached { [command] in
          try NotebookIPCClient(socketURL: socket).send(command).decode(NotebookRuntimeWorkspaceResponse.self)
        }.value
      }
      let secondID = UUID()
      let second = try await send(.init(action: .create, id: secondID, name: "Второе"))
      XCTAssertEqual(second.status.state, .ready); XCTAssertEqual(owners.count, 2)
      let firstWriter = try XCTUnwrap(owners.first?.writer)
      firstWriter.enqueue { _ in
        guard FileManager.default.fileExists(atPath: repaired.path) else { throw Failure.storageUnavailable }
        try Data("first".utf8).write(to: accepted)
        return false
      }
      firstWriter.enqueue { _ in
        try (Data(contentsOf: accepted) + Data(" second".utf8)).write(to: accepted)
        return false
      }
      let refused = await launch.shutdown()
      XCTAssertFalse(refused); XCTAssertEqual(first.shutdownPhase, .closing)
      XCTAssertEqual(firstWriter.pendingCount, 2); XCTAssertEqual(owners.count, 2)
      let recoverable = try await send(.init(action: .list))
      XCTAssertTrue(recoverable.status.ready); XCTAssertEqual(recoverable.status.state, .failed)
      XCTAssertEqual(firstWriter.pendingCount, 2, "Reading the recovery state cannot open or retry a writer")
      try Data().write(to: repaired)
      let recovered = try await send(.init(action: .retry, id: firstID))
      XCTAssertTrue(recovered.status.ready); XCTAssertEqual(recovered.status.state, .ready)
      XCTAssertNil(recovered.error); XCTAssertEqual(recovered.status.workspaceID, firstID)
      XCTAssertEqual(owners.count, 4); XCTAssertFalse(launch.model === owners[0].model)
      XCTAssertEqual(first.shutdownPhase, .stopped); XCTAssertEqual(owners[1].model.shutdownPhase, .stopped)
      XCTAssertEqual(firstWriter.pendingCount, 0)
      XCTAssertEqual(try String(contentsOf: accepted, encoding: .utf8), "first second")
    }

    func testRuntimeCommandsCreateAndSelectThroughTheOwnerWithoutADesktopWindow() async {
      do { try await assertRuntimeWorkspaceCommands() }
      catch { XCTFail("Runtime workspace commands failed: \(error)") }
    }

    private func assertRuntimeWorkspaceCommands() async throws {
      let base = URL(fileURLWithPath: "/tmp/nb-runtime-" + UUID().uuidString.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = base.appendingPathComponent("Notebook"), socket = base.appendingPathComponent("bridge.sock")
      let empty = NotebookWorkspaceLibrary.Catalog(format: 1, originalID: nil, selectedID: nil,
        entries: [], deleting: [], pendingCloudDeletion: [:])
      try JSONEncoder().encode(empty).write(to: root.appendingPathExtension("spaces.json"))
      let launch = NotebookApplicationLaunch(root: root, runtimeSocketURL: socket) { store, _ in
        let key = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        return NotebookAppModel(store: store, startsNearbySync: false, commandSocketURL: base.appendingPathComponent(key + ".sock"))
      }
      addTeardownBlock { @MainActor in
        _ = await launch.shutdown()
        try FileManager.default.removeItem(at: base)
      }
      await launch.start()
      let status = try await Task.detached {
        try NotebookIPCClient(socketURL: socket).send(.init(command: .runtimeStatus)).decode(NotebookRuntimeBootstrapStatus.self)
      }.value
      XCTAssertTrue(status.ready); XCTAssertEqual(status.kind, "notebookRuntime")
      XCTAssertEqual(status.pid, Int(ProcessInfo.processInfo.processIdentifier))
      XCTAssertEqual(status.protocolVersion, 1); XCTAssertFalse(status.build.isEmpty)
      XCTAssertEqual(status.state, .workspaceRequired); XCTAssertNil(launch.model)
      func send(_ request: NotebookRuntimeWorkspaceRequest) async throws -> NotebookRuntimeWorkspaceResponse {
        var command = NotebookCommand(command: .runtimeWorkspace); command.runtimeWorkspace = request
        return try await launch.executeRuntimeCommand(command).decode(NotebookRuntimeWorkspaceResponse.self)
      }
      let creationID = UUID()
      let first = try await send(.init(action: .create, id: creationID, name: "Первое"))
      let firstID = try XCTUnwrap(first.status.workspaceID)
      XCTAssertEqual(firstID, creationID)
      XCTAssertEqual(first.status.state, .ready); XCTAssertNil(first.error)
      XCTAssertEqual(launch.model?.loadState, .ready)
      let firstSocket = base.appendingPathComponent(try XCTUnwrap(first.status.socketKey) + ".sock")
      let opened = try await launch.executeRuntimeCommand(.init(command: .runtimeStatus)).decode(NotebookRuntimeBootstrapStatus.self)
      XCTAssertEqual(opened.workspaceID, firstID); XCTAssertEqual(opened.socketKey, first.status.socketKey)
      let second = try await send(.init(action: .create, id: UUID(), name: "Второе"))
      XCTAssertNotEqual(second.status.workspaceID, firstID)
      let firstPanel = try await Task.detached {
        var command = NotebookCommand(command: .panelRead)
        command.panelRead = .init(workspaceID: firstID)
        return try NotebookIPCClient(socketURL: firstSocket).send(command)
      }.value
      XCTAssertEqual(firstPanel["workspaceID"]?.stringValue?.lowercased(), firstID.uuidString.lowercased(),
        "Opening a second workspace keeps the first panel's addressed owner alive")
      XCTAssertEqual(firstPanel["socketKey"]?.stringValue, first.status.socketKey)
      let selected = try await send(.init(action: .select, id: firstID))
      XCTAssertEqual(selected.status.workspaceID, firstID); XCTAssertNil(selected.error)
      let renamed = try await send(.init(action: .rename, id: firstID, name: "Записи"))
      XCTAssertEqual(renamed.workspaces.first(where: { $0.id == firstID })?.name, "Записи")
      // An uncertain create response is retried with the same UUID. It cannot
      // create a second workspace or undo a later explicit rename.
      let repeated = try await send(.init(action: .create, id: creationID, name: "Первое"))
      XCTAssertEqual(repeated.status.workspaceID, firstID)
      XCTAssertEqual(repeated.workspaces.count, 2)
      XCTAssertEqual(repeated.workspaces.first(where: { $0.id == firstID })?.name, "Записи")
      let missing = try await send(.init(action: .select, id: UUID()))
      XCTAssertNotNil(missing.error); XCTAssertEqual(missing.status.workspaceID, firstID)
      XCTAssertEqual(missing.workspaces.count, 2)
    }

    func testRuntimeStatusRemainsAvailableAfterArchiveFailureAndWorkspaceCommandsStayClosed() async throws {
      let base = URL(fileURLWithPath: "/tmp/nb-runtime-" + UUID().uuidString.lowercased(), isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let root = base.appendingPathComponent("Notebook"), socket = base.appendingPathComponent("bridge.sock")
      try Data("damaged activation".utf8).write(to: NotebookArchiveActivation.controlURL(for: root))
      let launch = NotebookApplicationLaunch(root: root,
        target: .init(role: .mac, bundleID: "fixture.mac", actorID: UUID()), runtimeSocketURL: socket) { _, _ in
          XCTFail("Refused archive must not construct a model")
          throw NotebookStorageError.transactionConflict
        }
      addTeardownBlock { @MainActor in
        _ = await launch.shutdown()
        try FileManager.default.removeItem(at: base)
      }
      await launch.start()
      let status = try await launch.executeRuntimeCommand(.init(command: .runtimeStatus)).decode(NotebookRuntimeBootstrapStatus.self)
      XCTAssertTrue(status.ready); XCTAssertEqual(status.state, .failed); XCTAssertNotNil(status.message)
      var list = NotebookCommand(command: .runtimeWorkspace); list.runtimeWorkspace = .init(action: .list)
      do { _ = try await launch.executeRuntimeCommand(list); XCTFail("Archive admission must precede catalog access") }
      catch let error as CollaborationError { XCTAssertEqual(error.code, "owner_unavailable") }
      var retry = NotebookCommand(command: .runtimeWorkspace); retry.runtimeWorkspace = .init(action: .retry)
      let retried = try await launch.executeRuntimeCommand(retry).decode(NotebookRuntimeWorkspaceResponse.self)
      XCTAssertTrue(retried.status.ready); XCTAssertEqual(retried.status.state, .failed)
      XCTAssertTrue(retried.workspaces.isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathExtension("spaces.json").path))
    }

    func testRuntimeAdmissionRefusesLegacySocketAndConcurrentLauncherBeforeWorkspaceAccess() async throws {
      for legacy in [true, false] {
        let base = URL(fileURLWithPath: "/tmp/nb-launch-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let socket = base.appendingPathComponent("bridge.sock"), root = base.appendingPathComponent("Notebook")
        let server = NotebookIPCServer(socketURL: socket) { _ in .string("legacy-owner") }
        defer { server.stop() }
        let lease: NotebookIPCProcessLease?
        if legacy { lease = nil } else { lease = try NotebookIPCProcessLease(socketURL: socket) }
        if legacy { try server.start() }
        let launch = NotebookApplicationLaunch(root: root, runtimeSocketURL: socket) { _, _ in
          XCTFail("The losing launcher must not construct a store-owning model")
          throw NotebookStorageError.transactionConflict
        }
        await launch.start()
        XCTAssertEqual(launch.existingRuntimeSocketURL, socket)
        XCTAssertNotNil(launch.failure); XCTAssertNil(launch.model)
        await launch.refreshWorkspaces()
        let created = await launch.createWorkspace(name: "Must not exist")
        let renamed = await launch.renameWorkspace(UUID(), name: "Must not exist")
        await launch.removeWorkspace(UUID(), everywhere: false)
        XCTAssertFalse(created); XCTAssertFalse(renamed)
        let entries = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(Set(entries), legacy ? Set(["bridge.sock", "bridge.sock.owner"]) : Set(["bridge.sock.owner"]),
          "Refused startup and later catalog actions must leave archive/store/catalog untouched")
        if legacy {
          // The temporary lease from the rejected attempt is released. The
          // old runtime remains protected by its live socket until cutover.
          let released = try NotebookIPCProcessLease(socketURL: socket)
          withExtendedLifetime(released) { XCTAssertNotNil(launch.existingRuntimeSocketURL) }
        }
        withExtendedLifetime(lease) { XCTAssertNil(launch.model) }
      }
    }
  #endif

  func testExplicitPeerRetirementIsCheckedBeforeConstructingTheSelectedModel() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("launch-retirement-" + UUID().uuidString)
    let root = base.appendingPathComponent("Notebook"), store = NotebookStore(root: root), peer = UUID()
    defer { try? FileManager.default.removeItem(at: base) }
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let workspace = try store.storedWorkspaceID(), cursor = try store.currentChangeCursor()
    try store.acknowledgePeer(peerID: peer, through: 0)
    _ = try await NotebookWorkspaceLibrary(originalRoot: root).selectFixture(workspace)
    func arguments(_ id: UUID, _ cut: UInt64) -> [String] {
      ["--notebook-retire-peer", "{\"peerID\":\"\(peer)\",\"workspaceID\":\"\(id)\",\"expectedCursor\":\(cut)}"]
    }
    for request in [arguments(UUID(), cursor), arguments(workspace, cursor - 1)] {
      let refused = NotebookApplicationLaunch(root: root, arguments: request) { _, _ in
        XCTFail("A stale or foreign request must not construct a model")
        throw NotebookStorageError.transactionConflict
      }
      await refused.start()
      XCTAssertNotNil(refused.failure); XCTAssertNil(refused.model)
      XCTAssertTrue(try store.retiredReplicationPeers().isEmpty)
    }
    var constructions = 0
    let launch = NotebookApplicationLaunch(root: root, arguments: arguments(workspace, cursor)) { admitted, _ in
      constructions += 1
      XCTAssertEqual(try admitted.retiredReplicationPeers(), [peer])
      return NotebookAppModel(store: admitted, startsNearbySync: false)
    }
    await launch.start()
    XCTAssertNil(launch.failure); XCTAssertNotNil(launch.model); XCTAssertEqual(constructions, 1)
    XCTAssertEqual(try store.currentChangeCursor(), cursor)
    XCTAssertEqual(try store.peerCursor(peerID: peer, direction: .outgoing), 0)
    let stopped = await launch.shutdown(); XCTAssertTrue(stopped)
    let restart = NotebookApplicationLaunch(root: root, arguments: []) { admitted, _ in
      XCTAssertEqual(try admitted.retiredReplicationPeers(), [peer])
      return NotebookAppModel(store: admitted, startsNearbySync: false)
    }
    await restart.start()
    XCTAssertNil(restart.failure); XCTAssertNotNil(restart.model)
    let restartedStop = await restart.shutdown(); XCTAssertTrue(restartedStop)
  }

  func testNoModelOrDesktopRegistrationBeforeBothActivations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-gate-" + UUID().uuidString)
    let original = root.appendingPathComponent("Notebook"), candidate = root.appendingPathComponent("prepared")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    try Data("old original".utf8).write(to: original.appendingPathComponent("workspace.json"))
    let store = NotebookStore(root: candidate)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    try store.savePresence(.init(mode: .board, camera: .init(), viewport: .init(x: 834, y: 1194)))
    let target = NotebookArchiveTarget(role: .iPad, bundleID: "fixture.ipad", actorID: UUID()), transition = UUID()
    let control = NotebookArchiveActivation.controlURL(for: original)
    _ = try NotebookArchiveActivation().prepare(source: original, candidate: candidate, output: control,
      transitionID: transition, target: target)
    var constructions = 0
    let launch = NotebookApplicationLaunch(root: original, target: target) { store, activationID in
      constructions += 1
      XCTAssertEqual(activationID, transition)
      return NotebookAppModel(store: store, startsNearbySync: false, pairingActivationID: activationID)
    }
    addTeardownBlock { @MainActor in
      if let model = launch.model { _ = await model.shutdown() }
      try FileManager.default.removeItem(at: root)
    }
    await launch.start()
    XCTAssertNil(launch.model); XCTAssertEqual(constructions, 0)
    XCTAssertNil(launch.pairingActivationID)
    XCTAssertFalse(launch.allowsCodexRegistration)
    guard case .waitingForPair(let receipt) = launch.activation else { return XCTFail(launch.message) }
    await launch.start()
    XCTAssertNil(launch.model); XCTAssertEqual(constructions, 0)

    let mac = root.appendingPathComponent("Mac")
    try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: false)
    try Data("Mac original".utf8).write(to: mac.appendingPathComponent("workspace.json"))
    let macTarget = NotebookArchiveTarget(role: .mac, bundleID: "fixture.mac", actorID: UUID())
    let macControl = NotebookArchiveActivation.controlURL(for: mac)
    _ = try NotebookArchiveActivation().prepare(source: mac, candidate: candidate, output: macControl,
      transitionID: transition, target: macTarget)
    guard case .waitingForPair(let macReceipt) = try NotebookArchiveActivation().launch(root: mac, target: macTarget) else {
      return XCTFail("second device must await admission")
    }
    try NotebookArchiveAdmission(receipts: [receipt, macReceipt]).publish(at: control)
    await launch.start()
    XCTAssertNotNil(launch.model); XCTAssertEqual(constructions, 1)
    XCTAssertFalse(launch.allowsCodexRegistration, "An isolated archive cannot repoint the desktop agent to human tools")
    XCTAssertFalse(try XCTUnwrap(launch.model).allowsCodexRegistration)
    XCTAssertEqual(try XCTUnwrap(launch.model).pairingActivationID, transition)
    XCTAssertEqual(launch.pairingActivationID, transition)
    await launch.start()
    XCTAssertEqual(constructions, 1)
    let restart = NotebookApplicationLaunch(root: original, target: target) { store, activationID in
      XCTAssertEqual(activationID, transition, "A cold launch must not discard the newly confirmed pair")
      return NotebookAppModel(store: store, startsNearbySync: false, pairingActivationID: activationID)
    }
    await restart.start()
    XCTAssertNil(restart.failure)
    XCTAssertEqual(restart.model?.pairingActivationID, transition)
    if let model = restart.model { _ = await model.shutdown() }
  }

  func testDamagedPayloadCannotConstructTheDefaultModel() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-refusal-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Notebook")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let original = Data("untouched old input".utf8)
    try original.write(to: archive.appendingPathComponent("workspace.json"))
    let control = NotebookArchiveActivation.controlURL(for: archive)
    try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
    let launch = NotebookApplicationLaunch(root: archive, target: .init(role: .iPad, bundleID: "fixture", actorID: UUID())) { _, _ in
      XCTFail("failed activation must not construct a model")
      return NotebookAppModel(store: NotebookStore(root: root.appendingPathComponent("must-not-open")), startsNearbySync: false)
    }
    await launch.start()
    XCTAssertNotNil(launch.failure); XCTAssertNil(launch.model)
    XCTAssertFalse(launch.allowsCodexRegistration)
    XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("workspace.json")), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("notebook.sqlite").path))
  }

  func testUnitFixtureDoesNotEnterProductionBootstrap() async {
    let launch = NotebookApplicationLaunch(fixture: nil)
    await launch.waitForAdmission()
    XCTAssertNil(launch.model); XCTAssertNil(launch.failure)
    XCTAssertEqual(launch.activation, .unchanged)
    XCTAssertFalse(launch.allowsCodexRegistration)
    XCTAssertNil(launch.pairingActivationID)
  }

  func testNewActivationHasIndependentDeviceTrustWithoutChangingIdentity() async throws {
    let workspace = UUID(), activation = UUID()
    let identity = NotebookTransportIdentity(deviceID: UUID(), workspaceID: workspace, displayName: "Device")
    let peer = NotebookTrustedDevice(identity: .init(deviceID: UUID(), workspaceID: workspace, displayName: "Mac"),
      credentialID: UUID(), secret: Data(repeating: 11, count: 32))
    let service = "Notebook.tests.activation." + UUID().uuidString
    addTeardownBlock {
      await Task.detached {
        _ = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
      }.value
    }
    let old = NotebookKeychainDeviceStore(service: service)
    let current = NotebookKeychainDeviceStore(activationID: activation, service: service)
    try await old.save(.init(account: "account", records: [peer]), for: identity)
    let oldState = try await old.load(for: identity), empty = try await current.load(for: identity)
    XCTAssertEqual(oldState.records, [peer]); XCTAssertTrue(empty.records.isEmpty)
    let newPeer = NotebookTrustedDevice(identity: peer.identity, credentialID: UUID(), secret: Data(repeating: 12, count: 32))
    try await current.save(.init(account: "account", records: [newPeer]), for: identity)
    let reopened = try await NotebookKeychainDeviceStore(activationID: activation, service: service).load(for: identity)
    let retained = try await old.load(for: identity)
    XCTAssertEqual(reopened.records, [newPeer]); XCTAssertEqual(retained.records, [peer])
  }
}

#if os(macOS)
private final class CodexDiscoveryFault: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private let entering: XCTestExpectation
  let release = DispatchSemaphore(value: 0)
  var attempts: Int { lock.withLock { count } }

  init(entering: XCTestExpectation) { self.entering = entering }

  func discover() throws -> CodexRuntimeInstallation {
    let attempt = lock.withLock { count += 1; return count }
    if attempt == 1 { throw CodexBridgeError.notInstalled }
    guard attempt == 2 else { throw CodexBridgeError.invalidInput }
    entering.fulfill()
    guard release.wait(timeout: .now() + 5) == .success else { throw CodexBridgeError.timeout }
    // Preserve the production signature/installation admission. No executor or
    // account request is made; only the isolated workspace route is registered.
    return try CodexRuntimeInstallation.discover()
  }
}
#endif
