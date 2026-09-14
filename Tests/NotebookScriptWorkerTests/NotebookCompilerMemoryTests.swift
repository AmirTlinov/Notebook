import Darwin
import Foundation
import Testing
@testable import NotebookScriptWorker

struct NotebookCompilerMemoryTests {
  @Test func aDeniedOrPartialProbeCannotBecomeAnAbsentTaskOrZeroMemory() {
    let size = Int32(MemoryLayout<proc_taskinfo>.stride)
    for errorNumber in [EPERM, EACCES, EIO, 0] {
      #expect(NotebookCompilerMemory.interpret(returnedBytes: 0, errorNumber: errorNumber, residentBytes: 0)
        == .unavailable(errorNumber: errorNumber, returnedBytes: 0))
    }
    #expect(NotebookCompilerMemory.interpret(returnedBytes: size - 1, errorNumber: ESRCH, residentBytes: 0)
      == .unavailable(errorNumber: ESRCH, returnedBytes: size - 1))
    #expect(NotebookCompilerMemory.interpret(returnedBytes: 0, errorNumber: ESRCH, residentBytes: 0) == .taskAbsent)
  }

  @Test func onlyMeasuredResidentBytesCanPassOrExceedTheExactBudget() {
    let size = Int32(MemoryLayout<proc_taskinfo>.stride), limit: UInt64 = 512*1024*1024
    let atLimit = NotebookCompilerMemory.interpret(returnedBytes: size, errorNumber: 0, residentBytes: limit)
    let overLimit = NotebookCompilerMemory.interpret(returnedBytes: size, errorNumber: 0, residentBytes: limit + 1)
    #expect(atLimit == .resident(bytes: limit) && !atLimit.exceeds(limit))
    #expect(overLimit == .resident(bytes: limit + 1) && overLimit.exceeds(limit))
    #expect(NotebookCompilerMemory.Observation.taskAbsent != .resident(bytes: 0))
  }

  @Test func aRunningNativeChildHasMeasuredMemoryAndRemainsCancellable() async throws {
    let process = makeProcess("/bin/sleep", ["30"]), child = NotebookCompilerProcess(process)
    try child.launch()
    let observation = NotebookCompilerMemory.observe(process.processIdentifier)
    child.terminate()
    #expect(await child.waitForExit() != 0)
    guard case .resident(let bytes) = observation else {
      Issue.record("A live native child must expose resident memory: \(observation)")
      return
    }
    #expect(bytes > 0 && observation.exceeds(0))
    #expect(NotebookCompilerMemory.observe(process.processIdentifier) == .taskAbsent)
  }

  @Test func fastChildrenCanLoseTheirKernelTaskBeforeTheirTerminalCallback() async throws {
    for _ in 0..<50 {
      let process = makeProcess("/usr/bin/true"), child = NotebookCompilerProcess(process)
      try child.launch()
      let deadline = ContinuousClock.now + .seconds(2)
      while !child.hasExited, ContinuousClock.now < deadline {
        let observation = NotebookCompilerMemory.observe(process.processIdentifier)
        if case .unavailable = observation { Issue.record("A normally exiting child is not a denied memory probe: \(observation)") }
      }
      // Preserve the same latched terminal owner after task disappearance.
      if !child.hasExited { child.terminate(); Issue.record("Child termination exceeded its deadline") }
      #expect(await child.waitForExit() == 0)
      #expect(NotebookCompilerMemory.observe(process.processIdentifier) == .taskAbsent)
    }
  }

  @Test func absentTaskWaitsForDelayedTerminalDeliveryInsteadOfInventingAnExit() async throws {
    let process = makeProcess("/usr/bin/true"), child = NotebookCompilerProcess(process)
    let ownedCompletion = try #require(process.terminationHandler)
    let delivery = DispatchSemaphore(value: 0)
    // Hold delivery of the real OS callback at its asynchronous boundary.
    // NotebookCompilerProcess still owns and publishes the sole exit status.
    process.terminationHandler = { process in
      _ = delivery.wait(timeout: .now() + .seconds(2))
      ownedCompletion(process)
    }
    defer { delivery.signal() }
    try child.launch()
    let deadline = ContinuousClock.now + .seconds(1)
    var observation = NotebookCompilerMemory.observe(process.processIdentifier)
    while observation != .taskAbsent, ContinuousClock.now < deadline {
      await Task.yield()
      observation = NotebookCompilerMemory.observe(process.processIdentifier)
    }
    #expect(observation == .taskAbsent)
    #expect(!child.hasExited)
    delivery.signal()
    #expect(await child.waitForExit() == 0)
  }

  private func makeProcess(_ executable: String, _ arguments: [String] = []) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    return process
  }
}
