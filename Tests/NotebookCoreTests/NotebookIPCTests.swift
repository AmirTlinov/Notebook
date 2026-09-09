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

  @Test func stopAcknowledgesOnlyAfterAnAcceptedWriterAndDisconnectedClientHaveDrained() async throws {
    let endpoint = try IPCEndpoint()
    var drained = true
    defer { if drained { endpoint.remove() } }
    let store = NotebookStore(root: endpoint.directory.appendingPathComponent("store")), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 100, height: 140))
    let pageID = try #require(store.readWorkspaceItems(limit: 1).first?.pageIDs.first)
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
    _ = Data([0, 0]).withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    let accepted = await waitForIPC { server.activeConnectionCount == 1 }
    #expect(accepted)
    let start = ContinuousClock.now
    await server.stopAndDrain()
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(server.activeConnectionCount == 0)
    #expect(calls.value == 0)
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
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
  var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(url.path.utf8CString)
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in bytes.withUnsafeBytes { buffer.copyBytes(from: $0) } }
  let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  guard connected == 0 else { close(fd); throw CocoaError(.fileReadUnknown) }
  return fd
}

private func oversizedFrameResponse(_ url: URL) throws -> JSONValue {
  let fd = try connectIPC(url); defer { close(fd) }
  var timeout = timeval(tv_sec: 3, tv_usec: 0)
  _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  _ = Data([255, 255, 255, 255]).withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
  func take(_ count: Int) throws -> Data {
    var output = Data(count: count)
    let completed = output.withUnsafeMutableBytes { buffer -> Bool in
      var offset = 0
      while offset < count {
        let n = read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
        if n <= 0 { return false }; offset += n
      }
      return true
    }
    guard completed else { throw CocoaError(.fileReadUnknown) }; return output
  }
  let length = try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  guard length <= 65_536 else { throw CocoaError(.fileReadTooLarge) }
  return try JSONDecoder().decode(JSONValue.self, from: take(Int(length)))
}
