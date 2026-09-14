import Foundation
import Testing
import NotebookScriptProtocol
@testable import NotebookScriptHost

struct NotebookScriptDeadlineTests {
  private final class Probe: @unchecked Sendable {
    let lock = NSLock()
    var gate: NotebookWorkerReplyGate?
    var expirations = 0
    func hold(_ gate: NotebookWorkerReplyGate) { lock.withLock { self.gate = gate } }
    func expire() { lock.withLock { expirations += 1 } }
    func answerLate() -> Bool { lock.withLock { gate }?.finish(.init(value: Data("42".utf8))) ?? false }
  }

  @Test func hostDeadlineDoesNotRequireTheTransportToReplyOrEnterMain() async throws {
    let probe = Probe(), started = ContinuousClock.now
    let result: NotebookWorkerReply = await withCheckedContinuation { continuation in
      let gate = NotebookWorkerReplyGate(continuation); probe.hold(gate)
      gate.arm(deadline: .now + .milliseconds(40), reply: .init(code: "script_timeout")) { probe.expire() }
      // Deliberately no transport callback: the OS may still be starting its
      // sandbox container, before either engine watchdog can exist.
    }
    #expect(result.code == "script_timeout")
    #expect(started.duration(to: .now) < .seconds(1))
    #expect(!probe.answerLate())
    try await Task.sleep(for: .milliseconds(10))
    #expect(probe.lock.withLock { probe.expirations } == 1)
  }

  @Test func aTimelyReplyDisarmsTheDeadlineWithoutReplacingItsResult() async throws {
    let probe = Probe()
    let result: NotebookWorkerReply = await withCheckedContinuation { continuation in
      let gate = NotebookWorkerReplyGate(continuation); probe.hold(gate)
      gate.arm(deadline: .now + .milliseconds(30), reply: .init(code: "script_timeout")) { probe.expire() }
      #expect(gate.finish(.init(value: Data("42".utf8))))
    }
    try await Task.sleep(for: .milliseconds(60))
    #expect(result.value == Data("42".utf8))
    #expect(probe.lock.withLock { probe.expirations } == 0)
    #expect(!probe.answerLate())
  }

  @Test func expiredDeadlineAndPrelaunchCancelNeverDispatchAnXPCRequest() async throws {
    let id = UUID()
    // No service or app is launched: both requests close before connection
    // creation. Native signed-service tests separately cover actual XPC.
    let expired = NotebookXPCWorker(serviceName: "must-not-launch") { _ in .init(code: "unexpected_host") }
    let timeout = await expired.execute(.init(id: id, code: "return 42", arguments: Data("{}".utf8)), deadline: .now - .seconds(1))
    #expect(timeout.code == "script_timeout")
    expired.invalidate()
    let cancelled = NotebookXPCWorker(serviceName: "must-not-launch") { _ in .init(code: "unexpected_host") }
    cancelled.cancel(id)
    let stopped = await cancelled.execute(.init(id: id, code: "return 42", arguments: Data("{}".utf8)))
    #expect(stopped.code == "run_cancelled")
    cancelled.invalidate()
  }
}
