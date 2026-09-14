import Foundation
import Testing
@testable import NotebookScriptWorker

struct NotebookCompilerProcessTests {
  private func child(_ executable: String, _ arguments: [String] = []) -> NotebookCompilerProcess {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    return NotebookCompilerProcess(process)
  }

  @Test func exitBeforeWaitRegistrationRemainsLatchedForEveryWaiter() async throws {
    let value = child("/usr/bin/true")
    try value.launch()
    let deadline = ContinuousClock.now + .seconds(2)
    while !value.hasExited, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(value.hasExited)
    async let first = value.waitForExit()
    async let second = value.waitForExit()
    let results = await (first, second)
    #expect(results.0 == 0 && results.1 == 0)
    #expect(await value.waitForExit() == 0)
  }

  @Test func earlyFailureAndFailedLaunchHaveTerminalResults() async throws {
    let failure = child("/usr/bin/false")
    try failure.launch()
    #expect(await failure.waitForExit() != 0)
    let missing = child("/nonexistent-notebook-compiler")
    #expect(throws: (any Error).self) { try missing.launch() }
    #expect(missing.hasExited)
    #expect(await missing.waitForExit() == -1)
  }

  @Test func cancellationStopsTheChildBeforeCleanupCompletes() async throws {
    let value = child("/bin/sleep", ["30"])
    try value.launch()
    let waiting = Task {
      await withTaskCancellationHandler { await value.waitForExit() } onCancel: { value.terminate() }
    }
    waiting.cancel()
    #expect(await waiting.value != 0)
    #expect(value.hasExited && !value.process.isRunning)
    // A repeated stop cannot resolve a waiter twice or resurrect this PID.
    value.terminate()
    #expect(await value.waitForExit() != 0)
  }

  @Test func repeatedJobsPreserveEveryByteAndReachEOF() async throws {
    let bytes = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
    for _ in 0..<20 {
      let process = Process(), input = Pipe(), output = Pipe(), collected = Bytes()
      process.executableURL = URL(fileURLWithPath: "/bin/cat")
      process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
      let value = NotebookCompilerProcess(process)
      try value.launch()
      try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
      let deadline = ContinuousClock.now + .seconds(3)
      let reader = NotebookCompilerPipe(reading: output.fileHandleForReading, deadline: deadline) { collected.append($0) }
      let writer = NotebookCompilerPipe(writing: input.fileHandleForWriting, data: bytes, deadline: deadline)
      #expect(await writer.finish() == nil)
      #expect(await value.waitForExit() == 0)
      #expect(await reader.finish() == nil)
      #expect(collected.value == bytes)
    }
  }

  @Test func quietReaderAndBackpressuredWriterHaveBoundedDeadlines() async throws {
    let quiet = Pipe()
    let reader = NotebookCompilerPipe(reading: quiet.fileHandleForReading, deadline: .now + .milliseconds(30)) { _ in }
    #expect(await reader.finish() == .deadline)
    try quiet.fileHandleForWriting.close()
    let full = Pipe()
    let writer = NotebookCompilerPipe(writing: full.fileHandleForWriting, data: Data(repeating: 1, count: 1_048_576),
      deadline: .now + .milliseconds(30))
    #expect(await writer.finish() == .deadline)
    try full.fileHandleForReading.close()
  }

  @Test func pipeCancellationAndEarlyReaderExitDoNotRaiseSIGPIPE() async throws {
    let quiet = Pipe()
    let reader = NotebookCompilerPipe(reading: quiet.fileHandleForReading, deadline: .now + .seconds(30)) { _ in }
    reader.cancel()
    #expect(await reader.finish() == .cancelled)
    try quiet.fileHandleForWriting.close()
    let closed = Pipe()
    try closed.fileHandleForReading.close()
    let writer = NotebookCompilerPipe(writing: closed.fileHandleForWriting, data: Data(repeating: 1, count: 65_536),
      deadline: .now + .seconds(1))
    #expect(await writer.finish() == .io(EPIPE))
  }

  private final class Bytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ value: Data) { lock.withLock { bytes.append(value) } }
    var value: Data { lock.withLock { bytes } }
  }
}
