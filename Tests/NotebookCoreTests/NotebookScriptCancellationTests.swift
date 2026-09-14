import Foundation
import Testing
@testable import NotebookCore

@Suite("The writer orders cancellation and worker completion")
struct NotebookScriptCancellationTests {
  private func fixture() throws -> (NotebookStore, UUID) {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-script-cancel-\(UUID())"))
    _ = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let id = UUID()
    _ = try store.admitScriptRun(.init(op: .start, runID: id, apiVersion: 1, code: "cancel ordering"))
    return (store, id)
  }

  @Test(arguments: [NotebookScriptRun.State.completed, .failed, .interrupted])
  func acceptedCancellationWinsLateWorkerSuccessFailureOrRestart(workerState: NotebookScriptRun.State) throws {
    let (store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    _ = try store.setScriptRunState(id, state: .running)
    let requested = try store.requestScriptRunCancellation(id)
    #expect(requested.state == .running && requested.cancellationRequestedAt != nil)
    #expect(try store.requestScriptRunCancellation(id).cancellationRequestedAt == requested.cancellationRequestedAt)
    let reopened = NotebookStore(root: store.root)
    let stopped = try reopened.setScriptRunState(id, state: workerState,
      result: .string(String(repeating: "ignored late result", count: 20_000)),
      error: .object(["code": .string("script_worker_unavailable"), "message": .string("NSCocoaErrorDomain Code=4097")]))
    #expect(stopped.state == .cancelled && stopped.result == nil)
    #expect(try stopped.error?.decode(CollaborationError.self) == NotebookStore.scriptCancellationError)
    #expect(try reopened.unfinishedScriptRuns().isEmpty)
  }

  @Test func CompletionBeforeCancelRemainsCompletedAndQueuedCancelNeverRuns() throws {
    let (store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    _ = try store.setScriptRunState(id, state: .running)
    let completed = try store.setScriptRunState(id, state: .completed, result: .number(42))
    #expect(try store.requestScriptRunCancellation(id) == completed)
    #expect(completed.cancellationRequestedAt == nil)
    let queued = UUID()
    _ = try store.admitScriptRun(.init(op: .start, runID: queued, apiVersion: 1, code: "must never execute"))
    let cancelled = try store.requestScriptRunCancellation(queued)
    #expect(cancelled.state == .cancelled)
    #expect(try store.setScriptRunState(queued, state: .running) == cancelled)
  }

  @Test func cancellationClosesNewEffectsWhileAnAcceptedNativeEffectCanStillSave() throws {
    let (store, id) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    _ = try store.setScriptRunState(id, state: .running)
    var accepted = try store.admitScriptEffect(id, key: "before-cancel", method: "point", arguments: .object([:]))
    accepted.state = .committing; try store.saveScriptEffect(id, effect: accepted)
    _ = try store.requestScriptRunCancellation(id)
    do {
      _ = try store.admitScriptEffect(id, key: "after-cancel", method: "point", arguments: .object([:]))
      Issue.record("Cancellation closes native effect admission")
    } catch let error as CollaborationError { #expect(error.code == "run_cancelled") }
    // A native receipt can arrive after cancel; this test verifies journal
    // ownership. The native service suite verifies an actual content commit.
    accepted.state = .saved; accepted.value = .object(["receipt": .string("accepted")])
    try store.saveScriptEffect(id, effect: accepted)
    #expect(try store.admitScriptEffect(id, key: accepted.key, method: accepted.method, arguments: accepted.arguments) == accepted)
    let stopped = try store.setScriptRunState(id, state: .failed)
    #expect(stopped.state == .cancelled)
    #expect(try store.scriptEffect(id, id: accepted.id).state == .saved)
  }
}
