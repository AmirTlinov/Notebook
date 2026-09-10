import Foundation
import Darwin
import Testing
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

  @Test func aSecondServerCannotReplaceTheCurrentWriterSocket() async throws {
    let endpoint = try IPCEndpoint(); defer { endpoint.remove() }
    let server = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("first") }
    try server.start(); defer { server.stop() }
    let other = NotebookIPCServer(socketURL: endpoint.socket) { _ in .string("second") }
    #expect(throws: CollaborationError.self) { try other.start() }
    let result = try await blockingIPC { try NotebookIPCClient(socketURL: endpoint.socket).send(.init(command: .read)) }
    #expect(result == .string("first"))
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
      Task { await server.stopAndDrain(); acknowledgements.increment(); first.resolve(.success(())) }
      Task { await server.stopAndDrain(); acknowledgements.increment(); second.resolve(.success(())) }
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
    Task { drained.resolve(.success(await server.stopAndDrain())) }
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
  private var continuation: CheckedContinuation<Void, Never>?
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
        self.continuation = continuation
        return false
      }
      if resume { continuation.resume() }
    }
  }
  func open() {
    let waiting = lock.withLock {
      isOpen = true
      let waiting = continuation; continuation = nil
      return waiting
    }
    waiting?.resume()
  }
}

private struct IPCWaitFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A single protocol event, not a polled observation of another executor.
/// Ten seconds is an external broken-test watchdog, not an IPC latency SLA:
/// the full suite schedules long synchronous Core tests on the same pool as
/// the handler. Only the handler's signal establishes acceptance before stop.
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
  Task { await server.stopAndDrain(); drained.resolve(.success(())) }
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
