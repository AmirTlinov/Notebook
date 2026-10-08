import Foundation
import Darwin
import Testing
import CSQLite
@testable import NotebookCore

struct NotebookIPCTests {
  @Test func realUnixSocketReturnsTypedResultAndKeepsPrivatePermissions() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let server = NotebookIPCServer(socketURL: endpoint.socket) { command in
      .object(["command": .string(command.command.rawValue)])
    }
    try server.start(); defer { server.stop() }
    let result = try await blockingIPC {
      try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read))
    }
    #expect(result == .object(["command": .string("read")]))
    let attributes = try FileManager.default.attributesOfItem(atPath: endpoint.socket.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func typedErrorSurvivesTheTransport() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in
      throw CollaborationError("revision_conflict", "Обновите прочитанную версию.", expected: "one", actual: "two")
    }
    try server.start(); defer { server.stop() }
    do {
      _ = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
      Issue.record("An explicit conflict cannot become a successful response")
    } catch let error as CollaborationError {
      #expect(error.code == "revision_conflict"); #expect(error.expected == "one"); #expect(error.actual == "two")
    }
  }

  @Test(arguments: [false, true])
  func canonicalSocketAppearsOnlyAfterPrivateBindingIsProtectedAndListening(_ abortPublication: Bool) async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("ready") }
    defer { server.stop() }
    var stagedIdentity: SocketIO.Identity?, stagedURL: URL?
    do {
      try server.start(afterAddressCheck: nil, beforeAddressPublication: { binding in
        var absent = stat()
        #expect(lstat(endpoint.socket.path, &absent) < 0 && errno == ENOENT)
        try SocketIO.validateSocket(binding)
        stagedIdentity = try SocketIO.Identity(binding); stagedURL = binding
        let probe = try SocketIO.makeSocket(); defer { close(probe) }
        try SocketIO.connect(probe, url: binding)
        try SocketIO.authenticate(probe)
        if abortPublication { throw CollaborationError("test_publication_abort", "Controlled publication failure") }
      })
      #expect(!abortPublication)
    } catch let error as CollaborationError {
      #expect(abortPublication)
      #expect(error.code == "test_publication_abort")
    }
    let staging = try #require(stagedURL)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    if abortPublication {
      #expect(!FileManager.default.fileExists(atPath: endpoint.socket.path))
    } else {
      #expect(stagedIdentity?.matchesSocket(at: endpoint.socket) == true)
      let response = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
      #expect(response == .string("ready"))
    }
    try await drainIPC(server)
    #expect(try FileManager.default.contentsOfDirectory(atPath: endpoint.directory.path).isEmpty)
  }

  @Test func maximumLengthCanonicalSocketKeepsABoundedPrivateBinding() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let maximumPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    let count = maximumPath - endpoint.directory.path.utf8.count - 3
    try #require(count > 0)
    let directory = endpoint.directory.appendingPathComponent(String(repeating: "x", count: count), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let socket = directory.appendingPathComponent("s")
    #expect(socket.path.utf8.count == maximumPath)
    let server = NotebookIPCServer(socketURL: socket) { _ in .string("bounded") }
    defer { server.stop() }
    try server.start(afterAddressCheck: nil, beforeAddressPublication: { binding in
      #expect(binding.path.utf8.count <= maximumPath)
      #expect(binding.lastPathComponent.utf8.count == 1)
      try SocketIO.validateSocket(binding)
    })
    let response = try await blockingIPC { try NotebookIPCClient(socketURL: socket).send(.init(command: .read)) }
    #expect(response == .string("bounded"))
    try await drainIPC(server)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  @Test func aSecondServerCannotReplaceTheCurrentWriterSocket() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("first") }
    try server.start(); defer { server.stop() }
    let other = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("second") }
    #expect(throws: CollaborationError.self) { try other.start() }
    let result = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
    #expect(result == .string("first"))
  }

  @Test func failedBindAfterAnEmptyAddressCheckPreservesTheWinningSocket() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let winner = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("winner") }
    let loser = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("loser") }
    defer { loser.stop(); winner.stop() }
    // Both launches observed an empty address. The second completes its real
    // publication before the first resumes; exclusive rename preserves the winner.
    #expect(throws: CollaborationError.self) {
      try loser.start(afterAddressCheck: { try winner.start() })
    }
    loser.stop()
    let response = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
    #expect(response == .string("winner"))
    try await drainIPC(winner)
    #expect(try FileManager.default.contentsOfDirectory(atPath: endpoint.directory.path).isEmpty)
  }

  @Test func stoppingARetiredServerDoesNotUnlinkTheReplacementSocket() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let first = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("first") }
    let replacement = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("replacement") }
    try first.start(); defer { first.stop(); replacement.stop() }
    try FileManager.default.moveItem(at: endpoint.socket, to: endpoint.directory.appendingPathComponent("retired.sock"))
    try replacement.start()
    try await drainIPC(first)
    let response = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
    #expect(response == .string("replacement"))
    try await drainIPC(replacement)
  }

  @Test func processLeaseKeepsOneOwnerUntilReleaseAndIsNotInheritedByChildren() throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    var owner: NotebookIPCProcessLease? = try .init(socketURL: endpoint.socket)
    let descriptor = try #require(owner?.descriptor)
    #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    do {
      _ = try NotebookIPCProcessLease(socketURL: endpoint.socket)
      Issue.record("A second launcher cannot open its store before the first owner releases its lease")
    } catch let error as CollaborationError { #expect(error.code == "ipc_owner_running") }
    let path = endpoint.socket.appendingPathExtension("owner").path
    var before = stat(), after = stat()
    #expect(lstat(path, &before) == 0)
    owner = nil
    #expect(lstat(path, &after) == 0 && before.st_ino == after.st_ino)
    let replacement = try NotebookIPCProcessLease(socketURL: endpoint.socket)
    withExtendedLifetime(replacement) { () -> Void in
      #expect(throws: CollaborationError.self) { _ = try NotebookIPCProcessLease(socketURL: endpoint.socket) }
    }
  }

  @Test func acceptedHandlerKeepsItsServerExecutorAcrossSuspensionAndActorHops() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let execution = IPCQueueIdentity()
    let server = NotebookIPCServer(socketURL: endpoint.socket,
      workerQueue: .init(label: "Notebook.IPCTests.transport", attributes: .concurrent),
      requestQueue: execution.queue) { _ in
        let entered = execution.isCurrent
        try await Task.sleep(for: .milliseconds(2))
        let resumed = execution.isCurrent
        let actorIsHonored = await MainActor.run { Thread.isMainThread }
        return .array([.bool(entered), .bool(resumed), .bool(actorIsHonored), .bool(execution.isCurrent)])
      }
    try server.start(); defer { server.stop() }
    let response = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
    #expect(response == .array([.bool(true), .bool(true), .bool(true), .bool(true)]))
    try await drainIPC(server)
  }

  @Test func malformedFrameDoesNotWaitForThePausedAsyncOwner() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let queue = DispatchQueue(label: "Notebook.IPCTests.paused-handler")
    queue.suspend(); defer { queue.resume() }
    let calls = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket,
      workerQueue: .init(label: "Notebook.IPCTests.transport", attributes: .concurrent), requestQueue: queue) { _ in
        calls.increment(); return .bool(true)
      }
    try server.start(); defer { server.stop() }
    let response = try await blockingIPC { try oversizedFrameResponse(endpoint.socket) }
    #expect(response["error"]?["code"] == .string("resource_limit"))
    #expect(calls.value == 0)
    try await drainIPC(server)
  }

  @Test func shutdownRetainsAQueuedAcceptedHandlerUntilItsOwnExecutorCompletes() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let queue = DispatchQueue(label: "Notebook.IPCTests.queued-handler")
    queue.suspend()
    var suspended = true
    defer { if suspended { queue.resume() } }
    let calls = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket,
      workerQueue: .init(label: "Notebook.IPCTests.queued-handler-transport", attributes: .concurrent), requestQueue: queue) { _ in
        calls.increment(); return .bool(true)
      }
    try server.start(); defer { server.stop() }
    let client = IPCCompletion<Result<JSONValue, any Error>>("the queued handler's disconnected client")
    DispatchQueue(label: "Notebook.IPCTests.queued-handler-client").async {
      client.resolve(.success(Result { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .pageVision)) }))
    }
    let accepted = await waitForIPC { server.acceptedHandlerCount == 1 }
    #expect(accepted)
    server.stop()
    let disconnected = try await client.value()
    if case .success = disconnected { Issue.record("Shutdown must close the transport without undoing its accepted command") }
    #expect(calls.value == 0 && server.acceptedHandlerCount == 1 && server.activeConnectionCount == 1)
    queue.resume(); suspended = false
    try await drainIPC(server)
    #expect(calls.value == 1 && server.acceptedHandlerCount == 0 && server.activeConnectionCount == 0)
  }

  @Test func clientRefusesInsecureSocketBeforeSendingACommand() throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in .bool(true) }
    try server.start(); defer { server.stop() }
    #expect(chmod(endpoint.socket.path, 0o666) == 0)
    #expect(throws: CollaborationError.self) { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
  }

  @Test func serverRefusesSymlinkOrWorldAccessibleDirectory() throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    #expect(chmod(endpoint.directory.path, 0o755) == 0)
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in .bool(true) }
    #expect(throws: CollaborationError.self) { try server.start() }
    #expect(chmod(endpoint.directory.path, 0o700) == 0)
    let link = endpoint.directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: endpoint.directory)
    let linked = NotebookIPCServer(socketURL: link.appendingPathComponent("bridge.sock")) { _ in .bool(true) }
    #expect(throws: CollaborationError.self) { try linked.start() }
  }

  @Test func wireCannotChooseRootPathsOrUnknownCommands() throws {
    for text in [#"{"command":"read","root":"/tmp/another-owner"}"#,
      #"{"command":"read","path":"workspace.json"}"#, #"{"command":"snapshot"}"#, #"{"command":"run","query":"rm"}"#] {
      #expect(throws: CollaborationError.self) { try NotebookIPC.decodeCommand(Data(text.utf8)) }
    }
  }

  @Test func runtimeCommandsDecodeWithoutOpeningAWorkspaceAndRejectTheStoreDispatcher() throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let store = NotebookStore(root: endpoint.directory.appendingPathComponent("must-not-open"))
    let id = UUID()
    let requests = [
      JSONValue.object(["command": .string("runtimeStatus")]),
      .object(["command": .string("runtimeWorkspace"), "runtimeWorkspace": .object([
        "action": .string("create"), "id": .string(id.uuidString), "name": .string("Мои записи")])]),
      .object(["command": .string("runtimeWorkspace"), "runtimeWorkspace": .object([
        "action": .string("rename"), "id": .string(id.uuidString), "name": .string("Мои записи")])]),
    ]
    for wire in requests {
      let command = try NotebookIPC.decodeCommand(JSONEncoder().encode(wire))
      if command.command == .runtimeWorkspace {
        #expect(command.runtimeWorkspace?.id == id && command.runtimeWorkspace?.name == "Мои записи")
        try command.runtimeWorkspace?.validate()
      }
      do {
        _ = try NotebookCommandDispatcher(store: store).handle(command)
        Issue.record("The store cannot execute a runtime lifecycle command")
      } catch let error as CollaborationError { #expect(error.code == "runtime_owner_required") }
    }
    #expect(!FileManager.default.fileExists(atPath: store.root.path))
    for invalid in [NotebookRuntimeWorkspaceRequest(action: .create, name: "name"), .init(action: .select, name: "name"),
      .init(action: .list, id: id), .init(action: .retry, name: "name")] {
      #expect(throws: CollaborationError.self) { try invalid.validate() }
    }
    try NotebookRuntimeWorkspaceRequest(action: .retry, id: id).validate()
    let response = NotebookRuntimeWorkspaceResponse(status: .init(ready: true, pid: 42, build: "249",
      state: .ready, workspaceID: id, socketKey: "addressed-owner"), workspaces: [])
    let wire = try JSONValue.encode(response)
    #expect(try wire.decode(NotebookRuntimeWorkspaceResponse.self) == response)
    #expect(wire["status"]?["protocolVersion"] == .number(1))
    #expect(wire["status"]?["build"] == .string("249"))
    #expect(wire["status"]?["socketKey"] == .string("addressed-owner"))
  }

  @Test func removedPanelCommandsAndFieldsAreRejectedBeforeTheOwner() throws {
    for name in ["panelRead", "panelEdit", "panelUndo", "panelPresentation", "panelChanges"] {
      let wire = JSONValue.object(["command": .string(name)])
      #expect(throws: CollaborationError.self) { try NotebookIPC.decodeCommand(JSONEncoder().encode(wire)) }
      let field = JSONValue.object(["command": .string("read"), name: .object([:])])
      #expect(throws: CollaborationError.self) { try NotebookIPC.decodeCommand(JSONEncoder().encode(field)) }
    }
  }

  @Test func anOversizedFrameIsRejectedWithoutCallingTheOwner() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let calls = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in calls.increment(); return .bool(true) }
    try server.start(); defer { server.stop() }
    let value = try await blockingIPC { try oversizedFrameResponse(endpoint.socket) }
    #expect(value["error"]?["code"] == .string("resource_limit"))
    #expect(calls.value == 0)
  }

  @Test func aRawMalformedPeerUsesTheProductionSocketAdmissionPolicy() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let calls = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in calls.increment(); return .bool(true) }
    try server.start(); defer { server.stop() }
    let policy = try await blockingIPC {
      let fd = try connectIPC(endpoint.socket); defer { close(fd) }
      var receive = timeval(), send = timeval(), noSignal: Int32 = 0
      var timeSize = socklen_t(MemoryLayout<timeval>.size), intSize = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, &timeSize) == 0,
        getsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, &timeSize) == 0,
        getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, &intSize) == 0 else {
        throw IPCWaitFailure("Reading the raw peer's socket policy failed: errno=\(errno)")
      }
      let flags = fcntl(fd, F_GETFD)
      guard flags >= 0 else { throw IPCWaitFailure("Reading descriptor flags failed: errno=\(errno)") }
      return (receive.tv_sec, send.tv_sec, flags & FD_CLOEXEC != 0, noSignal)
    }
    #expect(policy.0 >= Int(NotebookIPC.requestTimeout))
    #expect(policy.1 >= Int(NotebookIPC.requestTimeout))
    #expect(policy.2)
    #expect(policy.3 == 1)
    #expect(calls.value == 0)
  }

  @Test func frameReaderRejectsImpossibleHeadersWhileThePeerKeepsItsBodyOpen() async throws {
    for size in [UInt32(0), UInt32(NotebookIPC.maximumFrameBytes + 1), UInt32.max] {
      let code = try await blockingIPC {
        try withIPCSocketPair { reader, peer in
          var prefix = size.bigEndian
          try writeRawIPCBytes(withUnsafeBytes(of: &prefix) { Data($0) }, fd: peer)
          // The peer stays open and sends no body. Reading any declared payload
          // would wait for the socket deadline instead of rejecting its header.
          do { _ = try SocketIO.readFrame(fd: reader); return "success" }
          catch let error as CollaborationError { return error.code }
        }
      }
      #expect(code == "resource_limit")
    }
  }

  @Test func frameReaderReturnsExactlyTheRawPeerPayload() async throws {
    let payload = Data([0, 255, 128, 240, 159, 146])
    let result = try await blockingIPC {
      try withIPCSocketPair { reader, peer in
        // Hand-authored bytes keep this control independent from writeFrame
        // and JSON command encoding, including zero and non-UTF8 payload bytes.
        try writeRawIPCBytes(Data([0, 0, 0, 6]) + payload, fd: peer)
        guard shutdown(peer, SHUT_WR) == 0 else {
          throw IPCWaitFailure("Closing the peer's write half failed: errno=\(errno)")
        }
        return try SocketIO.readFrame(fd: reader)
      }
    }
    #expect(result == payload)
  }

  @Test func frameReaderRejectsTruncatedHeaderAndPayloadWithoutDecoding() async throws {
    for bytes in [Data([0, 0]), Data([0, 0, 0, 2, 1])] {
      let code = try await blockingIPC {
        try withIPCSocketPair { reader, peer in
          try writeRawIPCBytes(bytes, fd: peer)
          guard shutdown(peer, SHUT_WR) == 0 else {
            throw IPCWaitFailure("Closing the peer's write half failed: errno=\(errno)")
          }
          do { _ = try SocketIO.readFrame(fd: reader); return "success" }
          catch let error as CollaborationError { return error.code }
        }
      }
      #expect(code == "ipc_unavailable")
    }
  }

  @Test func stopAcknowledgesOnlyAfterAnAcceptedWriterAndDisconnectedClientHaveDrained() async throws {
    let endpoint = try IPCEndpoint()
    var drained = true
    defer { if drained { endpoint.remove() } }
    let store = NotebookStore(root: endpoint.directory.appendingPathComponent("store")), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 100, height: 140))
    let pageID = try #require(store.readItemHeaders(limit: 1).first?.firstPageID)
    let page = try store.loadPage(pageID)
    let gate = IPCHandlerGate(), calls = IPCCount(), acknowledgements = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in
      await gate.wait()
      let request = try store.requestPageVision(pageID: pageID, expectedRevision: page.drawingStamp.revision)
      calls.increment()
      return try .encode(request)
    }
    try server.start()
    drained = false
    defer { gate.open(); server.stop() }
    let client = IPCCompletion<Result<JSONValue, any Error>>("the disconnected IPC client")
    // send is a blocking socket API. It must not occupy the cooperative pool
    // that the real server uses to enter its async writer handler.
    DispatchQueue(label: "Notebook.IPCTests.client").async {
      let result = Result { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .pageVision)) }
      gate.clientFinished(result)
      client.resolve(.success(result))
    }
    do {
      try await gate.waitUntilEntered()
      server.stop()
      let first = IPCCompletion<Void>("the first IPC drain"), second = IPCCompletion<Void>("the second IPC drain")
      Task(executorPreference: IPCQueueIdentity()) { await server.stopAndDrain(); acknowledgements.increment(); first.resolve(.success(())) }
      Task(executorPreference: IPCQueueIdentity()) { await server.stopAndDrain(); acknowledgements.increment(); second.resolve(.success(())) }
      // The client loses its socket immediately; that is not the writer's ACK.
      let disconnected = try await client.value()
      if case .success = disconnected { Issue.record("Closing the server must close the accepted client socket") }
      try await Task.sleep(for: .milliseconds(40))
      #expect(acknowledgements.value == 0)
      #expect(calls.value == 0)
      #expect(server.activeConnectionCount == 1)
      gate.open()
      try await first.value(); try await second.value()
      drained = true
      #expect(acknowledgements.value == 2)
      #expect(calls.value == 1)
      #expect(server.activeConnectionCount == 0)
      #expect(try store.targetRenderRequests().count == 1)
      #expect(throws: CollaborationError.self) {
        try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read))
      }
      try await drainIPC(server)
    } catch {
      gate.open(); server.stop()
      do { try await drainIPC(server); drained = true }
      catch { Issue.record("IPC did not drain; preserving its store at \(endpoint.directory.path): \(error)") }
      throw error
    }
  }

  @Test func stopDrainsAnIncompleteFrameWithoutWaitingForItsSocketTimeout() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let calls = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in calls.increment(); return .bool(true) }
    try server.start()
    let fd: Int32
    do { fd = try connectIPC(endpoint.socket) }
    catch { await server.stopAndDrain(); throw error }
    defer { close(fd) }
    do { try writeRawIPCBytes(Data([0, 0]), fd: fd) }
    catch { await server.stopAndDrain(); throw error }
    let accepted = await waitForIPC { server.activeConnectionCount == 1 }
    #expect(accepted)
    let start = ContinuousClock.now
    let draining = await server.stopAndDrain()
    let awaitingCaller = start.duration(to: .now)
    // The full suite also runs synchronous 100,000-owner tests on Swift's
    // cooperative pool. Their scheduling cannot become the socket's latency.
    // Keep the one-second bound at the real server completion, not after this
    // test eventually receives another executor slot.
    print("IPC incomplete-frame drain: server=\(draining), caller=\(awaitingCaller)")
    #expect(draining < .seconds(1))
    #expect(draining <= awaitingCaller)
    #expect(server.activeConnectionCount == 0)
    #expect(calls.value == 0)
  }

  @Test func stopOwnsAcceptedSocketsBeforeTheirWorkerQueueRuns() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let calls = IPCCount(), workers = DispatchQueue(label: "Notebook.IPCTests.suspended-workers")
    workers.suspend()
    var resumed = false
    defer { if !resumed { workers.resume() } }
    let server = NotebookIPCServer(socketURL: endpoint.socket, workerQueue: workers) { _ in
      calls.increment(); return .bool(true)
    }
    try server.start()
    var descriptors: [Int32] = []
    defer { for descriptor in descriptors { close(descriptor) }; server.stop() }
    for _ in 0..<NotebookIPC.maximumConnections {
      let fd = try connectIPC(endpoint.socket)
      descriptors.append(fd)
      try writeRawIPCBytes(Data([0, 0]), fd: fd)
    }
    #expect(await waitForIPC { server.activeConnectionCount == NotebookIPC.maximumConnections })
    let drained = IPCCompletion<Duration>("closed queued IPC sockets")
    let probe = IPCQueueIdentity()
    Task(executorPreference: probe) {
      #expect(probe.isCurrent, "The timed probe starts independently of unrelated synchronous Core tests")
      let duration = await server.stopAndDrain()
      #expect(probe.isCurrent, "The protocol completion returns to the same probe executor")
      drained.resolve(.success(duration))
    }
    let duration = try await drained.value()
    #expect(duration < .seconds(1))
    #expect(server.activeConnectionCount == 0)
    #expect(calls.value == 0)
    #expect(!FileManager.default.fileExists(atPath: endpoint.socket.path))
    // Late closures are deliberately released only after drain. They cannot
    // revive the handler or read a descriptor closed by the admission owner.
    workers.resume(); resumed = true
    await withCheckedContinuation { continuation in workers.async { continuation.resume() } }
    #expect(calls.value == 0)
    #expect(await server.stopAndDrain() == .zero)
  }

  @Test func typedReadsAndWritesShareTheBoundedCommandQuotaAndPreserveHalfClose() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let observations = IPCHandlerGate(), writes = IPCHandlerGate(), readCalls = IPCCount(), writeCalls = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket) { command in
      if command.command == .search { readCalls.increment(); await observations.wait(); return .string("observed") }
      writeCalls.increment(); await writes.wait(); return .bool(!Task.isCancelled)
    }
    try server.start(); defer { observations.open(); writes.open(); server.stop() }
    var peers: [Int32] = []
    defer { for fd in peers { close(fd) } }
    for count in 1...NotebookIPC.maximumConnections {
      let fd = try connectIPC(endpoint.socket); peers.append(fd)
      try sendRawIPC(count % 2 == 1 ? observingIPCCommand() : .init(command: .pageVision), id: UUID(), fd: fd)
      let admitted = await waitForIPC { server.commandConnectionCount == count && readCalls.value + writeCalls.value == count }
      try #require(admitted)
    }
    #expect(shutdown(peers[0], SHUT_WR) == 0, "A completed request half retains its response reader")
    #expect(server.activeConnectionCount == NotebookIPC.maximumConnections)
    for command in [observingIPCCommand(), NotebookCommand(command: .pageVision)] {
      let code = try await blockingIPC {
        do { _ = try NotebookIPCClient(socketURL: endpoint.socket).send(command); return "accepted" }
        catch let error as CollaborationError { return error.code }
      }
      #expect(code == "ipc_busy")
    }
    #expect(readCalls.value == NotebookIPC.maximumConnections / 2 && writeCalls.value == NotebookIPC.maximumConnections / 2)
    #expect(server.cancelledHandlerCount == 0)
    observations.open(); writes.open()
    for (index, fd) in peers.enumerated() {
      let response = try await blockingIPC { try JSONDecoder().decode(JSONValue.self, from: SocketIO.readFrame(fd: fd)) }
      #expect(response["result"] == (index % 2 == 0 ? .string("observed") : .bool(true)))
    }
    #expect(await waitForIPC { server.activeConnectionCount == 0 })
    try await drainIPC(server)
  }

  @Test(arguments: [ReadWithdrawal.disconnect, .deadline])
  func withdrawnObservationKeepsItsCommandQuotaUntilItsHandlerActuallyFinishes(reason: ReadWithdrawal) async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let observations = IPCHandlerGate(), calls = IPCCount()
    let withdrawal = IPCCompletion<Void>("the read observation withdrawal")
    let server = NotebookIPCServer(socketURL: endpoint.socket,
      workerQueue: .init(label: "Notebook.IPCTests.read-quota", attributes: .concurrent),
      requestTimeout: reason == .deadline ? .seconds(2) : .seconds(30)) { _ in
        calls.increment()
        await withTaskCancellationHandler { await observations.wait() }
          onCancel: { withdrawal.resolve(.success(())) }
        return .bool(Task.isCancelled)
      }
    try server.start(); defer { observations.open(); server.stop() }
    let waiting = observingIPCCommand()
    var peers: [Int32] = []
    defer { for fd in peers where fd >= 0 { close(fd) } }
    for count in 1...NotebookIPC.maximumConnections {
      let fd = try connectIPC(endpoint.socket); peers.append(fd)
      try sendRawIPC(waiting, id: UUID(), fd: fd)
      let admitted = await waitForIPC { calls.value == count }
      try #require(admitted)
    }
    if reason == .disconnect { close(peers[0]); peers[0] = -1 }
    try await withdrawal.value()
    #expect(server.commandConnectionCount == NotebookIPC.maximumConnections)
    #expect(server.acceptedHandlerCount == NotebookIPC.maximumConnections)
    let extra = try await blockingIPC {
      do { _ = try NotebookIPCClient(socketURL: endpoint.socket).send(waiting); return "accepted" }
      catch let error as CollaborationError { return error.code }
    }
    #expect(extra == "ipc_busy", "Socket withdrawal is not the handler's completion")
    if reason == .disconnect { #expect(server.cancelledHandlerCount == 1) }
    observations.open()
    #expect(await waitForIPC { server.commandConnectionCount == 0 })
    let next = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(waiting) }
    #expect(next == .bool(false), "A finished observation releases its slot to the next live reader")
    try await drainIPC(server)
  }

  @Test func unclassifiedPartialFramesHaveTheirOwnBoundedAdmission() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let gate = IPCHandlerGate(), calls = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket) { command in
      calls.increment()
      if command.command == .search { await gate.wait() }
      return .bool(true)
    }
    try server.start(); defer { gate.open(); server.stop() }
    var peers: [Int32] = []
    defer { for fd in peers { close(fd) } }
    for count in 1...NotebookIPC.maximumUnclassifiedConnections {
      let fd = try connectIPC(endpoint.socket); peers.append(fd)
      try writeRawIPCBytes(Data([0, 0]), fd: fd)
      let admitted = await waitForIPC { server.unclassifiedConnectionCount == count }
      try #require(admitted)
    }
    let code = try await blockingIPC {
      do {
        let extra = try connectIPC(endpoint.socket); defer { close(extra) }
        _ = try SocketIO.readFrame(fd: extra); return "admitted"
      }
      catch let error as CollaborationError { return error.code }
    }
    #expect(code == "ipc_unavailable")
    #expect(server.commandConnectionCount == 0 && calls.value == 0)
    let data = try JSONEncoder().encode(JSONValue.object(["version": .number(Double(NotebookIPC.version)),
      "id": .string(UUID().uuidString), "request": try .encode(observingIPCCommand())]))
    try #require(data.count < 65_536)
    var length = UInt32(data.count).bigEndian
    let frame = withUnsafeBytes(of: &length) { Data($0) } + data
    try writeRawIPCBytes(Data(frame.dropFirst(2)), fd: peers[0])
    try await gate.waitUntilEntered()
    #expect(server.commandConnectionCount == 1)
    #expect(server.unclassifiedConnectionCount == NotebookIPC.maximumUnclassifiedConnections - 1)
    let ordinary = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
    #expect(ordinary == .bool(true))
    gate.open(); try await drainIPC(server)
    #expect(server.activeConnectionCount == 0 && calls.value == 2)
  }

  @Test func stopDrainsReadObserversAndAcceptedMutationThroughTheirRealCompletion() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let observation = IPCHandlerGate(), write = IPCHandlerGate(), written = IPCCount(), acknowledged = IPCCount()
    let server = NotebookIPCServer(socketURL: endpoint.socket) { command in
      if command.command == .search { await observation.wait(); #expect(Task.isCancelled) }
      else { await write.wait(); #expect(!Task.isCancelled); written.increment() }
      return .bool(true)
    }
    try server.start(); defer { observation.open(); write.open(); server.stop() }
    let observer = try connectIPC(endpoint.socket); defer { close(observer) }
    let writer = try connectIPC(endpoint.socket); defer { close(writer) }
    try sendRawIPC(observingIPCCommand(), id: UUID(), fd: observer)
    try sendRawIPC(.init(command: .pageVision), id: UUID(), fd: writer)
    try await observation.waitUntilEntered(); try await write.waitUntilEntered()
    server.stop()
    let drained = IPCCompletion<Void>("observation and accepted write completion")
    Task(executorPreference: IPCQueueIdentity()) { await server.stopAndDrain(); acknowledged.increment(); drained.resolve(.success(())) }
    #expect(server.commandConnectionCount == 2)
    #expect(server.cancelledHandlerCount == 1 && written.value == 0 && acknowledged.value == 0)
    observation.open()
    #expect(await waitForIPC { server.commandConnectionCount == 1 })
    #expect(server.commandConnectionCount == 1 && acknowledged.value == 0)
    write.open(); try await drained.value()
    #expect(server.activeConnectionCount == 0 && written.value == 1 && acknowledged.value == 1)
  }

  enum ReadWithdrawal: Sendable, Equatable { case disconnect, deadline, stop, halfClose }
  @Test(arguments: [ReadWithdrawal.disconnect, .deadline, .stop, .halfClose])
  func socketObservationOwnsCancellationBeforeTheFirstSQLiteRow(reason: ReadWithdrawal) async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let store = NotebookStore(root: endpoint.directory.appendingPathComponent("store"))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 100, height: 140))
    let gate = IPCSQLGate(), probe = IPCSQLReader(store: store, gate: gate)
    let server = NotebookIPCServer(socketURL: endpoint.socket,
      workerQueue: .init(label: "Notebook.IPCTests.read-withdrawal", attributes: .concurrent),
      requestTimeout: reason == .deadline ? .seconds(2) : .seconds(30)) { command in
        _ = try NotebookReadCommand(command)
        return try await probe.read()
      }
    try server.start(); defer { gate.release.signal(); server.stop() }
    var fd = try connectIPC(endpoint.socket)
    defer { if fd >= 0 { close(fd) } }
    let requestID = UUID()
    try sendRawIPC(.init(command: .read), id: requestID, fd: fd)
    let entered = try await blockingIPC { gate.entered.wait(timeout: .now() + 5) == .success }
    #expect(entered)
    switch reason {
    case .disconnect: close(fd); fd = -1
    case .deadline: break
    case .stop: server.stop()
    case .halfClose:
      #expect(Darwin.shutdown(fd, SHUT_WR) == 0)
      #expect(server.cancelledHandlerCount == 0)
    }
    if reason != .halfClose {
      #expect(await waitForIPC { server.cancelledHandlerCount == 1 })
      #expect(server.activeConnectionCount == 1, "The read slot is charged until actual SQL completion")
    }
    let drained = IPCCompletion<Duration>("the actual cancelled SQL producer")
    if reason == .stop {
      Task(executorPreference: IPCQueueIdentity()) { drained.resolve(.success(await server.stopAndDrain())) }
      #expect(server.activeConnectionCount == 1)
    }
    gate.release.signal()
    let result = try await probe.finished.value()
    #expect(result.cancelled == (reason != .halfClose))
    #expect(result.rows == (reason == .halfClose ? 1 : 0))
    #expect(result.steps > 1_024 && result.steps < 150_000)
    if reason == .halfClose {
      let responseFD = fd
      let response = try await blockingIPC { try JSONDecoder().decode(JSONValue.self, from: SocketIO.readFrame(fd: responseFD)) }
      #expect(response["id"]?.string?.lowercased() == requestID.uuidString.lowercased())
      #expect(response["result"] == .number(4_001))
    }
    if reason == .stop { _ = try await drained.value() }
    else {
      #expect(await waitForIPC { server.activeConnectionCount == 0 })
      let next = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
      #expect(next == .number(42), "A cancelled snapshot cannot poison the next idle handle")
      try await drainIPC(server)
    }
  }

  @Test func queuedReadDisconnectCannotCancelOrWriteToAReusedDescriptor() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let requestQueue = DispatchQueue(label: "Notebook.IPCTests.read-registration")
    requestQueue.suspend(); var suspended = true
    defer { if suspended { requestQueue.resume() } }
    let calls = IPCCount(), server = NotebookIPCServer(socketURL: endpoint.socket,
      workerQueue: .init(label: "Notebook.IPCTests.read-transport", attributes: .concurrent), requestQueue: requestQueue) { _ in
        calls.increment(); return .string("new peer")
      }
    try server.start(); defer { server.stop() }
    let first = try connectIPC(endpoint.socket)
    try sendRawIPC(.init(command: .read), id: UUID(), fd: first)
    #expect(await waitForIPC { server.acceptedHandlerCount == 1 })
    close(first)
    #expect(await waitForIPC { server.cancelledHandlerCount == 1 })
    let replacement = try connectIPC(endpoint.socket); defer { close(replacement) }
    let replacementID = UUID()
    try sendRawIPC(.init(command: .read), id: replacementID, fd: replacement)
    #expect(await waitForIPC { server.acceptedHandlerCount == 2 })
    requestQueue.resume(); suspended = false
    let response = try await blockingIPC { try JSONDecoder().decode(JSONValue.self, from: SocketIO.readFrame(fd: replacement)) }
    #expect(response["id"]?.string?.lowercased() == replacementID.uuidString.lowercased())
    #expect(response["result"] == .string("new peer") && calls.value == 1)
    try await drainIPC(server)
  }

  @Test func disconnectedAcceptedWriteRecoversItsLostCommitReplyWithoutRepeatingTheBody() async throws {
    enum LostCommit: Error { case reply }
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let store = NotebookStore(root: endpoint.directory.appendingPathComponent("store"))
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 100, height: 140))
    let calls = IPCCount(), retry = IPCHandlerGate(), acceptedEntered = IPCCompletion<Void>("the lost commit reply")
    let accepted = NotebookAcceptedWrite(witnesses: .init(root: store.root)) { store in
      calls.increment(); try store.publishRecords(writes: ["local/ipc-retained.json": .string("exact bytes")])
      return JSONValue.string("original result")
    }
    let lost = NotebookStore(root: store.root) { if case .afterCommit = $0 { throw LostCommit.reply } }
    let output = IPCCompletion<JSONValue>("the retained accepted result")
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in
      do { _ = try accepted.apply(to: lost); throw IPCWaitFailure("The accepted fixture must lose its reply") }
      catch let error as NotebookAcceptedWriteError { #expect(error.outcome == .unresolved) }
      acceptedEntered.resolve(.success(()))
      await retry.wait()
      #expect(!Task.isCancelled, "Transport loss never revokes accepted mutations")
      let value = try accepted.apply(to: store); output.resolve(.success(value)); return value
    }
    try server.start(); defer { retry.open(); server.stop() }
    let fd = try connectIPC(endpoint.socket)
    try sendRawIPC(.init(command: .pageVision), id: UUID(), fd: fd)
    try await acceptedEntered.value()
    close(fd); server.stop()
    #expect(server.cancelledHandlerCount == 0 && server.acceptedHandlerCount == 1)
    #expect(try store.storedValue("local/ipc-retained.json") == .string("exact bytes"))
    let draining = IPCCompletion<Duration>("accepted result before transport drain")
    Task(executorPreference: IPCQueueIdentity()) { draining.resolve(.success(await server.stopAndDrain())) }
    #expect(server.activeConnectionCount == 1)
    retry.open()
    let restored = try await output.value(); #expect(restored == .string("original result"))
    _ = try await draining.value()
    #expect(calls.value == 1 && server.activeConnectionCount == 0)
    #expect(try NotebookStore(root: store.root).storedValue("local/ipc-retained.json") == .string("exact bytes"))
  }
}

private final class IPCSQLGate: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
}
private actor IPCSQLReader {
  private let store: NotebookStore, session: NotebookReadSession, gate: IPCSQLGate
  private var first = true
  let finished = IPCCompletion<(cancelled: Bool, rows: Int, steps: Int)>("SQL cancellation after its first VM prefix")
  init(store: NotebookStore, gate: IPCSQLGate) {
    self.store = store; session = .init(store: store); self.gate = gate
  }
  func read() throws -> JSONValue {
    if !first { return try session.observe { _ in .number(Double(try store.currentSQL!.rows("SELECT 42").first![0].integer!)) } }
    first = false
    var rows = 0, cancelled = false, actualSteps = 0
    do {
      let count = try session.observe { _ in
        let sql = try #require(store.currentSQL)
        defer {
          // Statement/connection borrows end inside this exact SQL snapshot.
          // Only scalars cross the cancellation catch and actor boundary.
          var cursor = sqlite3_next_stmt(sql.handle, nil)
          while let statement = cursor {
            if let raw = sqlite3_sql(statement), String(cString: raw).contains("COUNT(ipc_probe") {
              actualSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
            }
            cursor = sqlite3_next_stmt(sql.handle, cursor)
          }
        }
        #expect(sqlite3_create_function_v2(sql.handle, "ipc_probe", 1, SQLITE_UTF8,
          Unmanaged.passUnretained(gate).toOpaque(), { context, _, values in
            guard let context, let values, let pointer = sqlite3_user_data(context) else { return }
            let value = sqlite3_value_int64(values[0])
            if value == 1_024 {
              let gate = Unmanaged<IPCSQLGate>.fromOpaque(pointer).takeUnretainedValue()
              gate.entered.signal(); _ = gate.release.wait(timeout: .now() + 5)
            }
            sqlite3_result_int64(context, value)
          }, nil, nil, nil) == SQLITE_OK)
        var count: Int64 = 0
        try sql.forEachRow("WITH RECURSIVE input(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM input WHERE x<4000) SELECT COUNT(ipc_probe(x)) FROM input") { row in
          rows += 1; count = row[0].integer!
        }
        return count
      }
      finished.resolve(.success((false, rows, actualSteps)))
      return .number(Double(count))
    } catch is CancellationError { cancelled = true }
    catch { finished.resolve(.failure(error)); throw error }
    finished.resolve(.success((cancelled, rows, actualSteps)))
    throw CancellationError()
  }
}

private func sendRawIPC(_ command: NotebookCommand, id: UUID, fd: Int32) throws {
  try SocketIO.writeFrame(JSONEncoder().encode(JSONValue.object(["version": .number(Double(NotebookIPC.version)),
    "id": .string(id.uuidString), "request": try .encode(command)])), fd: fd)
}

private func observingIPCCommand() -> NotebookCommand {
  var command = NotebookCommand(command: .search)
  command.query = "held-observation"
  return command
}

private struct IPCEndpoint: Sendable {
  let directory: URL
  let socket: URL
  init() throws {
    directory = URL(fileURLWithPath: "/tmp/nb-ipc-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    socket = directory.appendingPathComponent("bridge.sock")
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}
private final class IPCCount: @unchecked Sendable {
  let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
private final class IPCHandlerGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var isOpen = false
  private var didEnter = false
  private let entry = IPCCompletion<Void>("the accepted IPC writer")
  func waitUntilEntered() async throws { try await entry.value() }
  func clientFinished(_ result: Result<JSONValue, any Error>) {
    lock.withLock {
      guard !didEnter else { return }
      entry.resolve(.failure(IPCWaitFailure("The IPC client completed before its writer was accepted: \(result)")))
    }
  }
  func wait() async {
    await withCheckedContinuation { continuation in
      let resume = lock.withLock {
        didEnter = true
        entry.resolve(.success(()))
        if isOpen { return true }
        continuations.append(continuation)
        return false
      }
      if resume { continuation.resume() }
    }
  }
  func open() {
    let waiting = lock.withLock {
      isOpen = true
      let waiting = continuations; continuations.removeAll()
      return waiting
    }
    for continuation in waiting { continuation.resume() }
  }
}

/// A timed protocol probe must be runnable before its independent watchdog fires.
/// Long synchronous tests may occupy the cooperative pool; they are not part of
/// either the server's drain latency or the test's deliberately suspended workers.
private final class IPCQueueIdentity: TaskExecutor, @unchecked Sendable {
  let queue = DispatchQueue(label: "Notebook.IPCTests.protocol-event", qos: .userInitiated)
  private let key = DispatchSpecificKey<Bool>()
  init() { queue.setSpecific(key: key, value: true) }
  var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }
  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { [self] in job.runSynchronously(on: asUnownedTaskExecutor()) }
  }
}

private struct IPCWaitFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A single protocol event, not a polled observation of another executor.
/// Ten seconds is an external broken-test watchdog, not an IPC latency SLA:
/// the full suite also schedules long synchronous Core tests. The server's
/// executor must still reach the handler; only its signal establishes acceptance.
private final class IPCCompletion<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let event: String
  private var result: Result<Value, any Error>?
  private var continuation: CheckedContinuation<Value, any Error>?
  init(_ event: String) { self.event = event }
  func resolve(_ result: Result<Value, any Error>) {
    let waiting = lock.withLock {
      guard self.result == nil else { return nil as CheckedContinuation<Value, any Error>? }
      self.result = result
      let waiting = continuation; continuation = nil
      return waiting
    }
    waiting?.resume(with: result)
  }
  func value() async throws -> Value {
    let deadline = DispatchWorkItem { [self] in
      resolve(.failure(IPCWaitFailure("Timed out waiting for \(event)")))
    }
    defer { deadline.cancel() }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10, execute: deadline)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let completed: Result<Value, any Error>? = lock.withLock {
          if let result { return result }
          precondition(self.continuation == nil)
          self.continuation = continuation
          return nil as Result<Value, any Error>?
        }
        if let completed { continuation.resume(with: completed) }
      }
    } onCancel: { resolve(.failure(CancellationError())) }
  }
}

private func drainIPC(_ server: NotebookIPCServer) async throws {
  let drained = IPCCompletion<Void>("IPC cleanup")
  Task(executorPreference: IPCQueueIdentity()) { await server.stopAndDrain(); drained.resolve(.success(())) }
  try await drained.value()
}

private func blockingIPC<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
  let completed = IPCCompletion<Value>("the blocking IPC operation")
  DispatchQueue(label: "Notebook.IPCTests.socket").async { completed.resolve(Result(catching: operation)) }
  return try await completed.value()
}

private func waitForIPC(_ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(2)
  while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
  return condition()
}

private func connectIPC(_ url: URL) throws -> Int32 {
  try SocketIO.validateDirectory(url.deletingLastPathComponent(), create: false)
  try SocketIO.validateSocket(url)
  let fd = try SocketIO.makeSocket()
  do {
    try SocketIO.connect(fd, url: url)
    try SocketIO.authenticate(fd)
    return fd
  } catch { close(fd); throw error }
}

private func oversizedFrameResponse(_ url: URL) throws -> JSONValue {
  let fd = try connectIPC(url); defer { close(fd) }
  // Only the deliberately invalid request bypasses production framing. The
  // response has the same bounds, interrupt handling and deadline as the client.
  try writeRawIPCBytes(Data([255, 255, 255, 255]), fd: fd)
  return try JSONDecoder().decode(JSONValue.self, from: SocketIO.readFrame(fd: fd))
}

private func withIPCSocketPair<Value>(_ operation: (Int32, Int32) throws -> Value) throws -> Value {
  var descriptors: [Int32] = [-1, -1]
  guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
    throw IPCWaitFailure("Creating the controlled peer failed: errno=\(errno)")
  }
  defer { close(descriptors[0]); close(descriptors[1]) }
  try SocketIO.configure(descriptors[0]); try SocketIO.configure(descriptors[1])
  return try operation(descriptors[0], descriptors[1])
}

/// A malformed peer alone writes unframed bytes; receiving them still belongs
/// to SocketIO. Check every byte and preserve the actual syscall on failure.
private func writeRawIPCBytes(_ bytes: Data, fd: Int32) throws {
  try bytes.withUnsafeBytes { buffer in
    var offset = 0
    while offset < buffer.count {
      let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
      if written < 0 && errno == EINTR { continue }
      guard written > 0 else { throw IPCWaitFailure("Writing raw peer bytes failed: result=\(written), errno=\(errno)") }
      offset += written
    }
  }
}
