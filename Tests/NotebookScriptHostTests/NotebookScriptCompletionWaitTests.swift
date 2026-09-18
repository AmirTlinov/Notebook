import Foundation
import Testing
@testable import NotebookCore
@testable import NotebookScriptHost

@Suite("Coordinator completion waits", .serialized)
@MainActor
struct NotebookScriptCompletionWaitTests {
  @MainActor private final class Owner {
    let store: NotebookStore
    var pageReads = 0
    var pageObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    var holdNextPage = false
    var heldPage: CheckedContinuation<Void, Never>?
    var holdNextTerminal = false
    var heldTerminal: CheckedContinuation<Void, Never>?
    var terminalObserver: CheckedContinuation<Void, Never>?

    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("script-completion-\(UUID())"))
      _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    }
    deinit { try? FileManager.default.removeItem(at: store.root) }

    func persist(_ operation: @Sendable (NotebookStore) throws -> JSONValue) async throws -> JSONValue {
      let value = try operation(store)
      if value["status"] != nil, value["run_id"] != nil {
        pageReads += 1
        let ready = pageObservers.filter { $0.0 <= pageReads }
        pageObservers.removeAll { $0.0 <= pageReads }
        for (_, observer) in ready { observer.resume() }
        if holdNextPage {
          holdNextPage = false
          await withCheckedContinuation { heldPage = $0 }
        }
      }
      if holdNextTerminal, ["completed", "cancelled", "failed", "interrupted"].contains(value.string("state") ?? "") {
        holdNextTerminal = false
        await withCheckedContinuation { heldTerminal = $0; terminalObserver?.resume(); terminalObserver = nil }
      }
      return value
    }

    func host() async throws -> NotebookScriptCoordinator {
      let host = NotebookScriptCoordinator(command: { _ in throw CollaborationError("unexpected_command", "No native effect is dispatched") },
        persistence: { try await self.persist($0) }, workingDirectory: store.root)
      try await host.start()
      return host
    }

    func queued(_ host: NotebookScriptCoordinator) throws -> UUID {
      let run = try store.admitScriptRun(.init(op: .start, runID: UUID(), code: "must not replay"))
      // Queue state is owned by the coordinator. Deliberately do not drive a
      // worker: these tests exercise real persistence without launching XPC.
      host.waiting.append(run)
      return run.id
    }

    func observedPages(_ count: Int) async {
      if pageReads >= count { return }
      await withCheckedContinuation { pageObservers.append((count, $0)) }
    }

    func releasePage() { heldPage?.resume(); heldPage = nil }
    func observedTerminal() async {
      if heldTerminal != nil { return }
      await withCheckedContinuation { terminalObserver = $0 }
    }
    func releaseTerminal() { heldTerminal?.resume(); heldTerminal = nil }
  }

  @Test func deadlineReadsTheJournalOnlyAtEntryAndExitWithoutCancellingTheRun() async throws {
    let owner = try Owner(), host = try await owner.host(), run = try owner.queued(host)
    let page = try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 160))
    #expect(page["status"] == .string("queued"))
    #expect(owner.pageReads == 2)
    #expect(try owner.store.scriptRun(run)?.cancellationRequestedAt == nil)
    #expect(host.waiting.map(\.id) == [run])
    #expect(host.completionWaiters.isEmpty)
    await host.shutdown()
  }

  @Test func completionWhileTheInitialReadReplyIsHeldCannotLoseTheWakeup() async throws {
    let owner = try Owner(), host = try await owner.host(), run = try owner.queued(host)
    owner.holdNextPage = true
    let client = Task { try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 1000)) }
    await owner.observedPages(1)
    let cancelled = try await host.handle(.init(op: .cancel, runID: run, waitMilliseconds: 0))
    #expect(cancelled["status"] == .string("cancelled"))
    owner.releasePage()
    let completed = try await client.value
    #expect(completed["status"] == .string("cancelled"))
    #expect(owner.pageReads == 3)
    #expect(host.waiting.isEmpty && host.active == nil)
    #expect(host.completionWaiters.isEmpty)
    await host.shutdown()
  }

  @Test func queuedCancellationWakesAllClientsAndKeepsTheirOutputCursors() async throws {
    let owner = try Owner(), host = try await owner.host(), run = try owner.queued(host)
    _ = try owner.store.appendScriptEvent(run, kind: "value", value: .string("already persisted"))
    let first = Task { try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 1000)) }
    let second = Task { try await host.handle(.init(op: .resume, runID: run, afterSequence: 1, waitMilliseconds: 1000)) }
    await owner.observedPages(2)
    _ = try await host.handle(.init(op: .cancel, runID: run, waitMilliseconds: 0))
    let a = try await first.value, b = try await second.value
    #expect(a["status"] == .string("cancelled") && b["status"] == .string("cancelled"))
    #expect(a["events"]?.array.count == 1 && b["events"]?.array.isEmpty == true)
    #expect(owner.pageReads == 5)
    #expect(host.completionWaiters.isEmpty)
    await host.shutdown()
  }

  @Test func cancellingAClientNeverCancelsItsAcceptedRunOrAnotherClient() async throws {
    let owner = try Owner(), host = try await owner.host(), run = try owner.queued(host)
    let client = Task { try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 1000)) }
    await owner.observedPages(1)
    client.cancel()
    do { _ = try await client.value; Issue.record("The disconnected client must stop waiting") }
    catch is CancellationError { }
    #expect(try owner.store.scriptRun(run)?.state == .queued)
    #expect(try owner.store.scriptRun(run)?.cancellationRequestedAt == nil)
    #expect(host.waiting.map(\.id) == [run])
    let attached = try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 0))
    #expect(attached["status"] == .string("queued"))
    #expect(owner.pageReads == 2)
    #expect(host.completionWaiters.isEmpty)
    await host.shutdown()
  }

  @Test func shutdownPublishesQueuedCancellationBeforeReleasingWaitingClients() async throws {
    let owner = try Owner(), host = try await owner.host(), run = try owner.queued(host)
    let client = Task { try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 1000)) }
    await owner.observedPages(1)
    await host.shutdown()
    let page = try await client.value
    #expect(page["status"] == .string("cancelled"))
    #expect(try owner.store.scriptRun(run)?.state == .cancelled)
    #expect(host.waiting.isEmpty && host.active == nil)
    #expect(owner.pageReads == 2)
    #expect(host.completionWaiters.isEmpty)
  }

  @Test func completedRunAndZeroWaitDoNotArmAnotherJournalRead() async throws {
    let owner = try Owner(), host = try await owner.host(), run = try owner.queued(host)
    _ = try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 0))
    #expect(owner.pageReads == 1)
    host.waiting.removeAll()
    _ = try owner.store.setScriptRunState(run, state: .completed, result: .number(42))
    let completed = try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 1000))
    #expect(completed["result"] == .number(42))
    #expect(owner.pageReads == 2)
    #expect(host.completionWaiters.isEmpty)
    await host.shutdown()
  }

  @Test func normalCompletionNotifiesOnlyAfterItsDurableTerminalReply() async throws {
    let owner = try Owner(), host = try await owner.host(), run = try owner.queued(host)
    host.waiting.removeAll(); host.active = run
    _ = try owner.store.setScriptRunState(run, state: .running)
    let client = Task { try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 1000)) }
    await owner.observedPages(1)
    owner.holdNextTerminal = true
    let finish = Task { try await host.finishRun(run, state: .completed, result: .number(42)) }
    await owner.observedTerminal()
    #expect(try owner.store.scriptRun(run)?.state == .completed)
    #expect(host.completionWaiters[run]?.count == 1)
    #expect(owner.pageReads == 1)
    owner.releaseTerminal()
    try await finish.value
    let page = try await client.value
    #expect(page["status"] == .string("completed") && page["result"] == .number(42))
    #expect(owner.pageReads == 2 && host.completionWaiters.isEmpty)
    host.active = nil
    await host.shutdown()
  }

  @Test func runningCancellationDoesNotReleaseClientsBeforeAcceptedEffectsDrain() async throws {
    let owner = try Owner(), host = try await owner.host(), run = try owner.queued(host)
    host.waiting.removeAll(); host.active = run
    _ = try owner.store.setScriptRunState(run, state: .running)
    host.beginEffectCall()
    let client = Task { try await host.handle(.init(op: .resume, runID: run, waitMilliseconds: 1000)) }
    await owner.observedPages(1)
    var effect = try owner.store.admitScriptEffect(run, key: "accepted", method: "point", arguments: .null)
    effect.state = .committing
    try owner.store.saveScriptEffect(run, effect: effect)
    let finish = Task { await host.drainAcceptedEffects(); try await host.finishRun(run, state: .completed) }
    let cancellation = try await host.handle(.init(op: .cancel, runID: run, waitMilliseconds: 0))
    #expect(cancellation["status"] == .string("running"))
    #expect(host.completionWaiters[run]?.count == 1)
    effect.state = .saved; effect.value = .string("accepted result")
    try owner.store.saveScriptEffect(run, effect: effect)
    host.endEffectCall()
    try await finish.value
    let page = try await client.value
    #expect(page["status"] == .string("cancelled"))
    #expect(page["effects"]?.array.first?["state"] == .string("saved"))
    #expect(try owner.store.scriptEffect(run, id: effect.id).value == .string("accepted result"))
    #expect(host.completionWaiters.isEmpty)
    host.active = nil
    await host.shutdown()
  }
}
