import Darwin
import Foundation
import NotebookCore

/// A partial frame has an absolute deadline; an idle subscription can wait indefinitely.
struct CodexFrames {
  enum Framing: Sendable { case length, lines }
  let framing: Framing
  var buffer = Data()
  var partialSince: ContinuousClock.Instant?

  mutating func append(_ data: Data) throws -> [JSONValue] {
    if buffer.isEmpty, !data.isEmpty { partialSince = .now }
    buffer.append(data)
    var messages: [JSONValue] = []
    while !buffer.isEmpty {
      let body: Data, consumed: Int
      switch framing {
      case .length:
        guard buffer.count >= 4 else { return messages }
        let count = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard count > 0, count <= CodexDesktopProtocol.frameLimit else { throw CodexBridgeError.invalidFrame }
        guard buffer.count >= count + 4 else { return messages }
        body = buffer.subdata(in: 4..<(count + 4)); consumed = count + 4
      case .lines:
        guard let end = buffer.firstIndex(of: 10) else {
          guard buffer.count <= CodexDesktopProtocol.frameLimit else { throw CodexBridgeError.invalidFrame }
          return messages
        }
        let length = buffer.distance(from: buffer.startIndex, to: end)
        guard length > 0, length <= CodexDesktopProtocol.frameLimit else { throw CodexBridgeError.invalidFrame }
        body = Data(buffer.prefix(length)); consumed = length + 1
      }
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

  static func encode(_ value: JSONValue, framing: Framing) throws -> Data {
    let body = try JSONEncoder().encode(value)
    guard body.count <= CodexDesktopProtocol.frameLimit else { throw CodexBridgeError.invalidFrame }
    switch framing {
    case .lines: return body + Data([10])
    case .length:
      var size = UInt32(body.count).littleEndian
      return withUnsafeBytes(of: &size) { Data($0) } + body
    }
  }
}

/// One bounded reader and writer. Neither model work nor credentials are implemented here.
final class CodexChannel: @unchecked Sendable {
  private let readFD: Int32
  private let writeFD: Int32
  private let framing: CodexFrames.Framing
  private let writer = DispatchQueue(label: "Notebook.Codex.write")
  private let lock = NSLock()
  private var stopped = false
  private let process: Process?
  private let socket: Bool
  private let stdin: FileHandle?

  private init(readFD: Int32, writeFD: Int32, framing: CodexFrames.Framing,
    process: Process? = nil, stdin: FileHandle? = nil) {
    self.readFD = readFD; self.writeFD = writeFD; self.framing = framing
    self.process = process; self.stdin = stdin; socket = process == nil
    _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
    _ = fcntl(writeFD, F_SETFL, O_NONBLOCK)
    _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
  }

  static func connect(_ endpoint: URL) throws -> CodexChannel {
    var parent = stat(), file = stat()
    guard lstat(endpoint.deletingLastPathComponent().path, &parent) == 0,
      parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == geteuid(), parent.st_mode & 0o022 == 0,
      lstat(endpoint.path, &file) == 0, file.st_mode & S_IFMT == S_IFSOCK,
      file.st_uid == geteuid(), file.st_mode & 0o077 == 0 else { throw CodexBridgeError.unsafeEndpoint }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CodexBridgeError.unavailable }
    do {
      var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
      let bytes = Array(endpoint.path.utf8) + [0]
      guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexBridgeError.unsafeEndpoint }
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      guard connected == 0 else { throw CodexBridgeError.unavailable }
      var uid: uid_t = 0, gid: gid_t = 0
      guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw CodexBridgeError.unsafeEndpoint }
      let out = dup(fd)
      guard out >= 0 else { throw CodexBridgeError.unavailable }
      return CodexChannel(readFD: fd, writeFD: out, framing: .length)
    } catch { Darwin.close(fd); throw error }
  }

  static func metadata(binary: URL, directory: URL) throws -> CodexChannel {
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
    DispatchQueue(label: "Notebook.Codex.metadata.stderr").async {
      // Do not log account URLs, credentials or unrelated conversation details.
      while let bytes = try? errors.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {}
    }
    return CodexChannel(readFD: readFD, writeFD: writeFD, framing: .lines,
      process: process, stdin: input.fileHandleForWriting)
  }

  func start(receive: @escaping @Sendable (JSONValue) async throws -> Void,
    ended: @escaping @Sendable (CodexBridgeError) async -> Void) {
    DispatchQueue(label: "Notebook.Codex.read").async { [self] in
      defer { Darwin.close(readFD) }
      var decoder = CodexFrames(framing: framing), bytes = [UInt8](repeating: 0, count: 16_384)
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
          for message in try decoder.append(Data(bytes.prefix(count))) {
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
    let data = try CodexFrames.encode(value, framing: framing)
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
    if socket { _ = shutdown(readFD, SHUT_RDWR) }
    writer.async { [self] in
      Darwin.close(writeFD)
      try? stdin?.close()
    }
    if let process {
      // EOF first lets Codex flush task metadata; terminate only our metadata helper on timeout.
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
