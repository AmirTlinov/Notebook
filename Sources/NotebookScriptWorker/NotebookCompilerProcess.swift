import Foundation
import Darwin

/// A compiler has one terminal signal, installed before launch. Foundation's
/// synchronous waitUntilExit runs a CFRunLoop and can strand a migrating Swift
/// task even after isRunning became false. Its termination callback owns the
/// exit status; every async waiter attaches to that same latched result.
final class NotebookCompilerProcess: @unchecked Sendable {
  let process: Process
  private let lock = NSLock(), exited = DispatchGroup()
  private var status: Int32?
  private var waiters: [CheckedContinuation<Int32, Never>] = []

  init(_ process: Process) {
    self.process = process
    exited.enter()
    process.terminationHandler = { [weak self] process in self?.complete(process.terminationStatus) }
  }

  func launch() throws {
    do { try process.run() }
    catch { complete(-1); throw error }
  }
  var hasExited: Bool { lock.withLock { status != nil } }

  func terminate() {
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  func waitForExit() async -> Int32 {
    await withCheckedContinuation { continuation in
      let result = lock.withLock { () -> Int32? in
        if let status { return status }
        waiters.append(continuation); return nil
      }
      if let result { continuation.resume(returning: result) }
    }
  }

  /// Only the service's ordinary dispatch watchdog uses this bounded wait
  /// before _exit. It never runs on a Swift task or starts a nested run loop.
  func waitForWatchdogCleanup(until deadline: DispatchTime) { _ = exited.wait(timeout: deadline) }

  private func complete(_ status: Int32) {
    let callbacks = lock.withLock { () -> [CheckedContinuation<Int32, Never>]? in
      guard self.status == nil else { return nil }
      self.status = status
      let result = waiters; waiters.removeAll(); return result
    }
    guard let callbacks else { return }
    exited.leave()
    for callback in callbacks { callback.resume(returning: status) }
  }
}

final class NotebookCompilerChildren: @unchecked Sendable {
    static let shared = NotebookCompilerChildren()
    private let lock = NSLock()
    private var closing = false
    private var processes: [ObjectIdentifier: NotebookCompilerProcess] = [:]
    func start(_ process: Process) throws -> NotebookCompilerProcess {
      try lock.withLock {
        guard !closing else { throw CancellationError() }
        // Admission and registration are atomic relative to the service's
        // terminal watchdog, so a new child cannot escape its cleanup.
        let child = NotebookCompilerProcess(process)
        try child.launch()
        processes[ObjectIdentifier(process)] = child
        return child
      }
    }
    var activeProcessIDs: [Int32] { lock.withLock { processes.values.filter { !$0.hasExited }.map { $0.process.processIdentifier } } }
    func remove(_ process: Process) { _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) } }
    func terminate() {
      let current = lock.withLock { closing = true; return Array(processes.values) }
      for child in current { child.terminate() }
      let deadline = DispatchTime.now() + .seconds(1)
      for child in current { child.waitForWatchdogCleanup(until: deadline) }
    }
  }
