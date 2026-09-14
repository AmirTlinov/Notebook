import Foundation
import Darwin

/// One owner performs all I/O and closes its descriptor exactly once. poll
/// bounds a quiet/full pipe without closing an fd concurrently with read/write
/// (which can otherwise hit a newly reused descriptor). Its deadline includes
/// EOF; cancellation stops draining only when no successful result is possible.
final class NotebookCompilerPipe: @unchecked Sendable {
  enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
    case cancelled, deadline, io(Int32)
    var description: String {
      switch self {
      case .cancelled: "Compiler pipe cancelled"
      case .deadline: "Compiler pipe deadline exceeded"
      case .io(let code): "Compiler pipe I/O failed: \(code)"
      }
    }
  }
  private let group = DispatchGroup(), lock = NSLock()
  private var cancelled = false
  private var failure: Failure?

  init(reading handle: FileHandle, deadline: ContinuousClock.Instant,
    consume: @escaping @Sendable (Data) -> Void) {
    run(handle, deadline: deadline, writing: nil, consume: consume)
  }
  init(writing handle: FileHandle, data: Data, deadline: ContinuousClock.Instant) {
    run(handle, deadline: deadline, writing: data, consume: { _ in })
  }

  func cancel() { lock.withLock { cancelled = true } }
  func finish() async -> Failure? {
    await withCheckedContinuation { continuation in
      group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
    }
    return lock.withLock { failure }
  }

  private func run(_ handle: FileHandle, deadline: ContinuousClock.Instant, writing input: Data?,
    consume: @escaping @Sendable (Data) -> Void) {
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      defer { try? handle.close(); group.leave() }
      let fd = handle.fileDescriptor
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0,
        input == nil || fcntl(fd, F_SETNOSIGPIPE, 1) >= 0 else {
        fail(.io(errno)); return
      }
      var buffer = [UInt8](repeating: 0, count: 64*1024), offset = 0
      while true {
        if lock.withLock({ cancelled }) { fail(.cancelled); return }
        if ContinuousClock.now >= deadline { fail(.deadline); return }
        let count: Int
        if let input {
          if offset == input.count { return }
          count = input.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(64*1024, input.count - offset))
          }
          if count > 0 { offset += count; continue }
        } else {
          count = Darwin.read(fd, &buffer, buffer.count)
          if count > 0 { consume(Data(buffer.prefix(count))); continue }
          if count == 0 { return }
        }
        if count < 0, errno == EINTR { continue }
        guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
          fail(.io(errno)); return
        }
        var descriptor = pollfd(fd: fd, events: Int16(input == nil ? POLLIN : POLLOUT), revents: 0)
        let ready = poll(&descriptor, 1, 25)
        if ready < 0, errno != EINTR { fail(.io(errno)); return }
        // Always attempt read after HUP so the final buffered bytes precede
        // EOF. For a closed reader, write returns EPIPE under F_SETNOSIGPIPE.
      }
    }
  }

  private func fail(_ error: Failure) { lock.withLock { if failure == nil { failure = error } } }
}
