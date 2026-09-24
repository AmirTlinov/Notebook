import Foundation
import Testing
import NotebookCore
import NotebookScriptProtocol
@testable import NotebookScriptHost

struct NotebookMarkupQueueTests {
  private final class Worker: NotebookMarkupWorker, @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<NotebookWorkerReply, Never>?
    var stopped = false
    var didStart = false
    var cancelledID: UUID?
    func execute(_ request: NotebookWorkerRequest, deadline: ContinuousClock.Instant, timeoutCode: String) async -> NotebookWorkerReply {
      await withCheckedContinuation { continuation in
        let stop = lock.withLock {
          didStart = true
          if stopped { return true }
          self.continuation = continuation
          return false
        }
        if stop { continuation.resume(returning: .init(code: "run_cancelled")) }
      }
    }
    func cancel(_ id: UUID) {
      let pending = lock.withLock {
        stopped = true; cancelledID = id
        let result = continuation; continuation = nil; return result
      }
      pending?.resume(returning: .init(code: "run_cancelled"))
    }
    func invalidate() {}
    func finish(_ value: String) {
      let pending = lock.withLock { let result = continuation; continuation = nil; return result }
      pending?.resume(returning: .init(value: Data(value.utf8)))
    }
  }
  private final class Factory: @unchecked Sendable {
    let lock = NSLock()
    var workers: [Worker] = []
    func make() -> Worker { lock.withLock { let worker = Worker(); workers.append(worker); return worker } }
    func started(_ index: Int) async -> Worker {
      for _ in 0..<10_000 {
        if let worker = lock.withLock({ workers.indices.contains(index) ? workers[index] : nil }),
          worker.lock.withLock({ worker.didStart }) { return worker }
        await Task.yield()
      }
      Issue.record("Normalization did not start"); return Worker()
    }
  }

  @Test func cancellationClosesAdmissionAndDropsWaitingPreparationBeforeNextRun() async throws {
    let factory = Factory(), queue = NotebookMarkupQueue(makeWorker: { factory.make() })
    let run = UUID(), firstID = UUID()
    await queue.beginRun(run)
    let first = Task { try await queue.normalize(runID: run, effectID: firstID, arguments: .null) }
    let worker = await factory.started(0)
    let waiting = (0..<3).map { _ in Task { try await queue.normalize(runID: run, effectID: UUID(), arguments: .null) } }
    await queue.endRun(run)
    for task in [first] + waiting {
      do { _ = try await task.value; Issue.record("Cancelled preparation completed") }
      catch { #expect((error as? CollaborationError)?.code == "run_cancelled") }
    }
    #expect(worker.lock.withLock { worker.cancelledID } == firstID)
    #expect(factory.lock.withLock { factory.workers.count } == 1)
    do { _ = try await queue.normalize(runID: run, effectID: UUID(), arguments: .null); Issue.record("Late run reopened") }
    catch { #expect((error as? CollaborationError)?.code == "run_cancelled") }
    let nextRun = UUID()
    await queue.beginRun(nextRun)
    let next = Task { try await queue.normalize(runID: nextRun, effectID: UUID(), arguments: .null) }
    let nextWorker = await factory.started(1)
    nextWorker.finish("42")
    #expect(try await next.value == .number(42))
    await queue.endRun(nextRun)
  }
}
