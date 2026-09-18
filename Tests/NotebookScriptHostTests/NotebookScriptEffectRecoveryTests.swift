import Foundation
import Testing
@testable import NotebookCore
import NotebookScriptProtocol
@testable import NotebookScriptHost

/// Runs the real host effect logic and the real Core writer in temporary stores.
/// Faults affect delivery of replies, never substitute a fabricated saved receipt.
@MainActor
struct NotebookScriptEffectRecoveryTests {
  @MainActor private final class Owner {
    let store: NotebookStore
    let pageID: UUID
    var commands = 0
    var rejectBeforeWrite = false
    var loseReply = false
    var breakPersistenceAfterCommand = false
    var persistenceAvailable = true
    var holdCommittingForRun: UUID?
    var committingAccepted = false
    var releaseCommitting: CheckedContinuation<Void, Never>?
    var holdEffectAdmission = false
    var effectAdmissionAccepted = false
    var releaseEffectAdmission: CheckedContinuation<Void, Never>?
    init(root: URL? = nil) throws {
      store = NotebookStore(root: root ?? FileManager.default.temporaryDirectory.appendingPathComponent("notebook-host-effect-\(UUID())"))
      pageID = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194)).0.selectedPageID!
      _ = try store.loadOrCreateSpatialInk(actor: UUID())
    }
    func command(_ request: NotebookCommand) throws -> JSONValue {
      commands += 1
      defer { if breakPersistenceAfterCommand { persistenceAvailable = false } }
      if rejectBeforeWrite { throw CollaborationError("new_owner_rejection", "The owner refused before writing") }
      let result = try NotebookCommandDispatcher(store: store).handle(request)
      if loseReply { throw CollaborationError("reply_lost", "The native result was not delivered") }
      return result
    }
    func persist(_ operation: @Sendable (NotebookStore) throws -> JSONValue) async throws -> JSONValue {
      guard persistenceAvailable else { throw CollaborationError("writer_unavailable", "The writer cannot answer") }
      let value = try operation(store)
      if holdEffectAdmission, value.string("state") == "admitted", value["method"] != nil {
        effectAdmissionAccepted = true
        await withCheckedContinuation { releaseEffectAdmission = $0 }
      }
      if let run = holdCommittingForRun, !committingAccepted,
        let effect = try? store.scriptEffect(run, id: NotebookStore.submissionID(run, suffix: "effect:source")), effect.state == .committing {
        committingAccepted = true
        await withCheckedContinuation { releaseCommitting = $0 }
      }
      return value
    }
    func host() -> NotebookScriptCoordinator {
      NotebookScriptCoordinator(command: { try await self.command($0) }, persistence: { try await self.persist($0) },
        workingDirectory: store.root.appendingPathComponent("derived/script-runtime"))
    }
    func run() throws -> UUID {
      let id = UUID()
      _ = try store.admitScriptRun(.init(op: .start, runID: id, apiVersion: 2, code: "host effect contract"))
      _ = try store.setScriptRunState(id, state: .running)
      return id
    }
    func point(_ key: String = "source") throws -> JSONValue {
      let target = CollaborationTarget(kind: .page, id: pageID)
      return .object(["key": .string(key), "references": .array([try .encode(CollaborationReference(
        target: target, revision: store.referenceRevision(target: target)))])])
    }
  }

  @Test(arguments: ["point", "cancelPresentation"])
  func cancelWhileCommittingJournalReplyIsInFlightPreventsNativeDispatch(method: String) async throws {
    let owner = try Owner(), host = owner.host(), run = try owner.run()
    let args = try method == "point" ? owner.point() : JSONValue.object(["key": .string("source"), "id": .string(UUID().uuidString)])
    defer { owner.releaseCommitting?.resume(); try? FileManager.default.removeItem(at: owner.store.root) }
    owner.holdCommittingForRun = run
    let call = Task { try await host.effect(runID: run, method: method, arguments: args) }
    let deadline = ContinuousClock.now + .seconds(2)
    while !owner.committingAccepted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(owner.committingAccepted)
    host.cancelled.insert(run)
    _ = try owner.store.requestScriptRunCancellation(run)
    owner.releaseCommitting?.resume(); owner.releaseCommitting = nil
    do { _ = try await call.value; Issue.record("Cancel before dispatch must prevent content") }
    catch let error as CollaborationError { #expect(error.code == "run_cancelled") }
    #expect(owner.commands == 0)
    let id = NotebookStore.submissionID(run, suffix: "effect:source")
    #expect(try owner.store.scriptPointReceipt(id) == nil)
    #expect(try owner.store.scriptEffect(run, id: id).state == .notSaved)
    await host.shutdown()
  }

  @Test func startupRecoversUnfinishedV1RunWithOldMissingGlobalEffectIndexWithoutReplay() async throws {
    let owner = try Owner(), run = try owner.run(), args = try owner.point()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    var effect = try owner.store.admitScriptEffect(run, key: "source", method: "point", arguments: args)
    effect.state = .committing; try owner.store.saveScriptEffect(run, effect: effect)
    var command = NotebookCommand(command: .point); command.actionID = effect.id
    command.references = try args["references"]?.decode([CollaborationReference].self)
    let receipt = try NotebookCommandDispatcher(store: owner.store).handle(command)
    let file = "local/script-runs/\(run.uuidString.lowercased())/run.json"
    let previous = try #require(try owner.store.storedValue(file))
    try owner.store.publishRecords(writes: [file: previous.setting("apiVersion", .number(1)).setting("fingerprint", .string("original-v1-identity"))],
      removals: [owner.store.scriptEffectRecoveryFile(effect.id)])
    let restarted = owner.host(); try await restarted.start()
    #expect(try owner.store.scriptRun(run)?.state == .interrupted)
    #expect(try owner.store.scriptEffect(run, id: effect.id).state == .saved)
    #expect(try owner.store.scriptEffect(run, id: effect.id).value == receipt)
    #expect(restarted.active == nil && restarted.waiting.isEmpty && owner.commands == 0)
    let page = try await restarted.handle(.init(op: .resume, runID: run, waitMilliseconds: 0))
    #expect(page["run_api_version"] == .number(1))
    #expect(page["fingerprint"] == .string("original-v1-identity"))
    #expect(try owner.store.unfinishedScriptEffects().isEmpty)
    await restarted.shutdown()
  }

  @Test func workerCompletionDrainsAnEffectWhoseAdmissionReplyHasNotArrived() async throws {
    let owner = try Owner(), host = owner.host(), run = try owner.run(), args = try owner.point()
    defer { owner.releaseEffectAdmission?.resume(); try? FileManager.default.removeItem(at: owner.store.root) }
    owner.holdEffectAdmission = true
    host.active = run
    let bytes = try JSONEncoder().encode(args)
    let call = Task { await host.host(.init(runID: run, sequence: 1, method: "point", arguments: bytes)) }
    let deadline = ContinuousClock.now + .seconds(2)
    while !owner.effectAdmissionAccepted, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(owner.effectAdmissionAccepted)
    #expect(host.effectTasks.isEmpty && host.inFlightEffects == 1)
    host.cancelled.insert(run); host.finishedWorkers.insert(run)
    _ = try owner.store.requestScriptRunCancellation(run)
    var drained = false
    let drain = Task { await host.drainAcceptedEffects(); drained = true }
    await Task.yield()
    #expect(!drained)
    owner.releaseEffectAdmission?.resume(); owner.releaseEffectAdmission = nil
    let refusal = await call.value
    #expect(refusal.code == "run_cancelled")
    await drain.value
    #expect(drained && host.inFlightEffects == 0)
    #expect(owner.commands == 0)
    let effect = try owner.store.scriptEffect(run, id: NotebookStore.submissionID(run, suffix: "effect:source"))
    #expect(effect.state == .notSaved && effect.error?["code"] == .string("run_cancelled"))
    _ = try owner.store.setScriptRunState(run, state: .completed)
    #expect(try owner.store.scriptRun(run)?.state == .cancelled)
    await host.shutdown()
  }

  @Test func bothPublicPlacementEntrypointsUseTheSameNativeDefaults() async throws {
    let owner = try Owner(), host = owner.host()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let target = CollaborationTarget(kind: .page, id: owner.pageID)
    let args: JSONValue = .object(["target": try .encode(target), "expectedRevision": .string(try owner.store.targetContentRevision(target: target)),
      "items": .array([.object(["id": .string("next-note"), "size": .object(["width": .number(180), "height": .number(100)]), "direction": .string("free")])])])
    let context = try await host.context(.init(method: "place", arguments: args))
    let sdk = try await host.read(method: "place", arguments: args)
    #expect(context["data"] == sdk["data"])
    #expect(context["basis"] == sdk["basis"])
    #expect(context["data"]?.string("status") == "snapshot_pending")
    #expect(owner.commands == 2)
    await host.shutdown()
  }

  @Test func repeatedRejectedKeyReturnsItsOriginalErrorWithoutRedispatch() async throws {
    let owner = try Owner(), host = owner.host(), run = try owner.run(), args = try owner.point()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    owner.rejectBeforeWrite = true
    for _ in 0..<2 {
      do { _ = try await host.effect(runID: run, method: "point", arguments: args); Issue.record("Rejected effect returned success") }
      catch let error as CollaborationError { #expect(error.code == "new_owner_rejection") }
      owner.rejectBeforeWrite = false // A retry would now save if dispatched.
    }
    #expect(owner.commands == 1)
    let id = NotebookStore.submissionID(run, suffix: "effect:source")
    #expect(try owner.store.scriptEffect(run, id: id).state == .notSaved)
    #expect(try owner.store.scriptPointReceipt(id) == nil)
    #expect(try owner.store.scriptRunPage(run).array("effects").first?["error"]?["code"] == .string("new_owner_rejection"))
    await host.shutdown()
  }

  @Test func realSavedReceiptOutranksAnArbitraryLostReply() async throws {
    let owner = try Owner(), host = owner.host(), run = try owner.run(), args = try owner.point()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    owner.loseReply = true
    let value = try await host.effect(runID: run, method: "point", arguments: args)
    #expect(try await host.effect(runID: run, method: "point", arguments: args) == value)
    let id = NotebookStore.submissionID(run, suffix: "effect:source")
    #expect(try owner.store.scriptPointReceipt(id) == value)
    #expect(try owner.store.scriptEffect(run, id: id).state == .saved)
    #expect(owner.commands == 1)
    await host.shutdown()
  }

  @Test(arguments: [false, true])
  func startupReconcilesUnavailableEffectsEvenAfterJavaScriptFailed(savedBeforeLostReply: Bool) async throws {
    let owner = try Owner(), host = owner.host(), run = try owner.run(), args = try owner.point()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    owner.rejectBeforeWrite = !savedBeforeLostReply; owner.loseReply = true; owner.breakPersistenceAfterCommand = true
    do { _ = try await host.effect(runID: run, method: "point", arguments: args); Issue.record("The reply and recovery writer are unavailable") }
    catch { }
    let id = NotebookStore.submissionID(run, suffix: "effect:source")
    #expect(try owner.store.scriptEffect(run, id: id).state == .committing)
    owner.persistenceAvailable = true
    _ = try owner.store.setScriptRunState(run, state: .failed)
    #expect(try owner.store.unfinishedScriptRuns().isEmpty)
    #expect(try owner.store.unfinishedScriptEffects().map(\.effectID) == [id])
    await host.shutdown()

    let reopened = try Owner(root: owner.store.root), restarted = reopened.host()
    try await restarted.start()
    let effect = try reopened.store.scriptEffect(run, id: id)
    #expect(effect.state == (savedBeforeLostReply ? .saved : .notSaved))
    #expect(try reopened.store.scriptRun(run)?.state == .failed)
    #expect(try reopened.store.unfinishedScriptEffects().isEmpty)
    #expect(reopened.commands == 0) // Reconciliation did not replay any native command.
    if savedBeforeLostReply { #expect(try effect.value == reopened.store.scriptPointReceipt(id)) }
    await restarted.shutdown()
  }

  @Test func presentationRemainsUncertainWithoutADurableWitness() async throws {
    let owner = try Owner(), host = owner.host(), run = try owner.run()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    let args = JSONValue.object(["key": .string("stop"), "id": .string(UUID().uuidString)])
    owner.rejectBeforeWrite = true
    for _ in 0..<2 {
      do { _ = try await host.effect(runID: run, method: "cancelPresentation", arguments: args); Issue.record("Transient effect has no durable proof") }
      catch let error as CollaborationError { #expect(error.code == "effect_outcome_unknown") }
    }
    #expect(owner.commands == 1)
    let id = NotebookStore.submissionID(run, suffix: "effect:stop")
    #expect(try owner.store.scriptEffect(run, id: id).state == .outcomeUnknown)
    _ = try owner.store.setScriptRunState(run, state: .failed)
    await host.shutdown()
    let restarted = owner.host(); try await restarted.start()
    #expect(try owner.store.scriptEffect(run, id: id).state == .outcomeUnknown)
    #expect(owner.commands == 1)
    await restarted.shutdown()
  }

  @Test func explicitResumeCannotInferAbsenceWhileAnAcceptedRunIsStillRunning() async throws {
    let owner = try Owner(), host = owner.host()
    defer { try? FileManager.default.removeItem(at: owner.store.root) }
    try await host.start()
    let run = try owner.run()
    var effect = try owner.store.admitScriptEffect(run, key: "accepted", method: "transaction", arguments: .object([:]))
    effect.state = .committing; try owner.store.saveScriptEffect(run, effect: effect)
    let inFlight = try await host.handle(.init(op: .resume, runID: run))
    #expect(inFlight.string("status") == "running")
    #expect(inFlight.array("effects").first?["state"] == .string("committing"))
    _ = try owner.store.setScriptRunState(run, state: .failed)
    let stopped = try await host.handle(.init(op: .resume, runID: run))
    #expect(stopped.string("status") == "failed")
    #expect(stopped.array("effects").first?["state"] == .string("notSaved"))
    #expect(owner.commands == 0)
    await host.shutdown()
  }
}
