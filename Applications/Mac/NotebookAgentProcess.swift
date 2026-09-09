import Darwin
import Foundation

/// Private stdio only. A blocked receiver backpressures one 16 KiB read, not a growing task queue.
final class NotebookAgentProcess: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let errors = Pipe()
  private let writer = DispatchQueue(label: "Notebook.agent.stdin")
  private let lifecycle = NSLock()
  private var exited = false
  private var exitWaiters: [CheckedContinuation<Void, Never>] = []

  init(binary: URL, arguments: [String], directory: URL, environment: [String: String],
       receive: @escaping @Sendable (Data) async -> Void,
       didExit: @escaping @Sendable () async -> Void) throws {
    process.executableURL = binary; process.arguments = arguments
    process.currentDirectoryURL = directory; process.environment = environment
    process.standardInput = input; process.standardOutput = output; process.standardError = errors
    process.terminationHandler = { [weak self] _ in
      self?.recordExit()
      Task { await didExit() }
    }
    try process.run()
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
    DispatchQueue(label: "Notebook.agent.stdout").async { [output] in
      var bytes = [UInt8](repeating: 0, count: 16_384)
      while true {
        let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { break }
        let packet = Data(bytes.prefix(count)), consumed = DispatchSemaphore(value: 0)
        Task { await receive(packet); consumed.signal() }
        consumed.wait()
      }
    }
    DispatchQueue(label: "Notebook.agent.stderr").async { [errors] in
      var bytes = [UInt8](repeating: 0, count: 4096)
      // Authentication URLs/tokens and server internals are never forwarded to logs or the card.
      while true {
        let count = Darwin.read(errors.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        #if NOTEBOOK_AGENT_CONTRACT_TEST
          // Isolated mock-provider builds have no credentials or user configuration.
          try? FileHandle.standardError.write(contentsOf: Data(bytes.prefix(count)))
        #endif
      }
    }
  }

  deinit {
    if process.isRunning {
      process.terminate()
      let process = process
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      }
    }
  }

  func send(_ data: Data) async throws {
    guard data.count <= 8 * 1_048_576 else { throw NotebookAgentFailure.messageLimit }
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
      writer.async { [self] in
        do {
          let fd = input.fileHandleForWriting.fileDescriptor
          let deadline = ContinuousClock.now.advanced(by: .seconds(5))
          try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
              guard ContinuousClock.now < deadline else { throw NotebookAgentFailure.transportTimeout }
              var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
              let ready = poll(&descriptor, 1, 100)
              if ready < 0 && errno == EINTR { continue }
              guard ready >= 0, descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                throw NotebookAgentFailure.processExited
              }
              if ready == 0 { continue }
              let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
              if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
              guard count > 0 else { throw NotebookAgentFailure.processExited }
              sent += count
            }
          }
          done.resume()
        } catch { done.resume(throwing: error) }
      }
    }
  }

  func stop() async {
    if process.isRunning { process.terminate() }
    let pid = process.processIdentifier
    let killer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      if !Task.isCancelled, self?.process.isRunning == true { _ = kill(pid, SIGKILL) }
    }
    await withCheckedContinuation { done in
      lifecycle.lock()
      if exited { lifecycle.unlock(); done.resume() }
      else { exitWaiters.append(done); lifecycle.unlock() }
    }
    killer.cancel()
  }

  private func recordExit() {
    lifecycle.lock(); exited = true; let waiters = exitWaiters; exitWaiters.removeAll(); lifecycle.unlock()
    for waiter in waiters { waiter.resume() }
  }
}
