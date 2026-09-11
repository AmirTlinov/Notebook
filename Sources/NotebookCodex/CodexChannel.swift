import Darwin
import Foundation
import NotebookCore

/// A partial frame has an absolute deadline; an idle subscription can wait indefinitely.
struct CodexFrames {
  var buffer = Data()
  var partialSince: ContinuousClock.Instant?

  mutating func append(_ data: Data) throws -> [JSONValue] {
    if buffer.isEmpty, !data.isEmpty { partialSince = .now }
    buffer.append(data)
    var messages: [JSONValue] = []
    while !buffer.isEmpty {
      guard let end = buffer.firstIndex(of: 10) else {
        guard buffer.count <= CodexProtocol.frameLimit else { throw CodexBridgeError.invalidFrame }
        return messages
      }
      let length = buffer.distance(from: buffer.startIndex, to: end)
      guard length > 0, length <= CodexProtocol.frameLimit else { throw CodexBridgeError.invalidFrame }
      let body = Data(buffer.prefix(length)), consumed = length + 1
      guard let value = try? JSONDecoder().decode(JSONValue.self, from: body), value.object != nil else {
        throw CodexBridgeError.invalidFrame
      }
      messages.append(value)
      buffer = Data(buffer.dropFirst(consumed))
      partialSince = buffer.isEmpty ? nil : .now
    }
    return messages
  }

  func checkDeadline() throws {
    if let partialSince, ContinuousClock.now > partialSince.advanced(by: .seconds(10)) { throw CodexBridgeError.timeout }
  }

  static func encode(_ value: JSONValue) throws -> Data {
    let body = try JSONEncoder().encode(value)
    guard body.count <= CodexProtocol.frameLimit else { throw CodexBridgeError.invalidFrame }
    return body + Data([10])
  }

}

/// One bounded reader and writer. Neither model work nor credentials are implemented here.
final class CodexChannel: @unchecked Sendable {
  private let readFD: Int32
  private let writeFD: Int32
  private let writer = DispatchQueue(label: "Notebook.Codex.write")
  private let lock = NSLock()
  private var stopped = false
  private let process: Process?
  private let stdin: FileHandle?

  private init(readFD: Int32, writeFD: Int32, process: Process? = nil, stdin: FileHandle? = nil) {
    self.readFD = readFD; self.writeFD = writeFD
    self.process = process; self.stdin = stdin
    _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
    _ = fcntl(writeFD, F_SETFL, O_NONBLOCK)
    _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
  }

  static func appServer(binary: URL, directory: URL) throws -> CodexChannel {
    let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
    process.executableURL = binary; process.arguments = ["app-server", "--stdio"]
    process.currentDirectoryURL = directory
    // Codex uses its own account/configuration. No token reads or copied credentials.
    process.standardInput = input; process.standardOutput = output; process.standardError = errors
    try process.run()
    let readFD = dup(output.fileHandleForReading.fileDescriptor), writeFD = dup(input.fileHandleForWriting.fileDescriptor)
    guard readFD >= 0, writeFD >= 0 else {
      if readFD >= 0 { Darwin.close(readFD) }; if writeFD >= 0 { Darwin.close(writeFD) }
      process.terminate(); throw CodexBridgeError.unavailable
    }
    DispatchQueue(label: "Notebook.Codex.stderr").async {
      // Do not log account URLs, credentials or unrelated conversation details.
      while let bytes = try? errors.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {}
    }
    return CodexChannel(readFD: readFD, writeFD: writeFD, process: process, stdin: input.fileHandleForWriting)
  }

  func start(receive: @escaping @Sendable (JSONValue) async throws -> Void,
    ended: @escaping @Sendable (CodexBridgeError) async -> Void) {
    DispatchQueue(label: "Notebook.Codex.read").async { [self] in
      defer { Darwin.close(readFD) }
      var decoder = CodexFrames(), bytes = [UInt8](repeating: 0, count: 16_384)
      do {
        while !isStopped {
          try decoder.checkDeadline()
          var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
          let ready = poll(&descriptor, 1, 100)
          if ready < 0 && errno == EINTR { continue }
          guard ready >= 0 else { throw CodexBridgeError.disconnected }
          if ready == 0 { continue }
          let count = Darwin.read(readFD, &bytes, bytes.count)
          if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
          guard count > 0 else { throw CodexBridgeError.disconnected }
          let input = Data(bytes.prefix(count))
          let messages = try decoder.append(input)
          for message in messages {
            let result = DeliveryResult()
            Task {
              do { try await receive(message) } catch { result.error = error as? CodexBridgeError ?? .invalidResponse }
              result.done.signal()
            }
            result.done.wait()
            if let error = result.error { throw error }
          }
        }
      } catch {
        stop()
        let error = error as? CodexBridgeError ?? .invalidResponse
        Task { await ended(error) }
      }
    }
  }

  private final class DeliveryResult: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var error: CodexBridgeError?
  }

  func send(_ value: JSONValue) async throws {
    let data = try CodexFrames.encode(value)
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
      writer.async { [self] in
        do {
          guard !isStopped else { throw CodexBridgeError.disconnected }
          let deadline = ContinuousClock.now.advanced(by: .seconds(5))
          try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
              guard !isStopped else { throw CodexBridgeError.disconnected }
              guard .now < deadline else { throw CodexBridgeError.timeout }
              var descriptor = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
              let ready = poll(&descriptor, 1, 100)
              if ready < 0 && errno == EINTR { continue }
              guard ready >= 0 else { throw CodexBridgeError.disconnected }
              if ready == 0 { continue }
              let count = Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
              if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
              guard count > 0 else { throw CodexBridgeError.disconnected }
              offset += count
            }
          }
          done.resume()
        } catch { done.resume(throwing: error) }
      }
    }
  }

  var isStopped: Bool { lock.withLock { stopped } }

  func stop() {
    guard lock.withLock({ if stopped { return false }; stopped = true; return true }) else { return }
    writer.async { [self] in
      Darwin.close(writeFD)
      try? stdin?.close()
    }
    if let process {
      // EOF first lets Codex flush task metadata; terminate only our App Server on timeout.
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
        if process.isRunning {
          process.terminate()
          DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
          }
        }
      }
    }
  }

  func waitForExit() async {
    guard let process else { return }
    await withCheckedContinuation { done in
      DispatchQueue.global().async { process.waitUntilExit(); done.resume() }
    }
  }
}
