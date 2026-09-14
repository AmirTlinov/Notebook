import Foundation
import Testing
@testable import NotebookCore

@Suite("Script effects reconcile durable witnesses")
struct NotebookScriptEffectOutcomeTests {
  private struct Fixture {
    let store: NotebookStore
    let actor = UUID()
    let run = UUID()
    let labelID = UUID()
    let pageID: UUID
    let itemID: UUID
    let boardID: UUID
    init() throws {
      store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-effect-proof-\(UUID())"))
      let index = try store.loadOrCreate(actor: actor, pageSize: .init(width: 834, height: 1194)).0
      pageID = index.selectedPageID!; itemID = index.selectedItemID; boardID = index.rootBoardID
      _ = try store.loadOrCreateSpatialInk(actor: actor)
      _ = try store.admitScriptRun(.init(op: .start, runID: run, apiVersion: 1, code: "effect proof"))
      _ = try store.setScriptRunState(run, state: .running)
    }
    func clean() { try? FileManager.default.removeItem(at: store.root) }
    func effect(_ method: String = "transaction", key: String = "effect", arguments: JSONValue = .object([:])) throws -> NotebookScriptEffect {
      var effect = try store.admitScriptEffect(run, key: key, method: method, arguments: arguments)
      effect.state = .committing; try store.saveScriptEffect(run, effect: effect)
      return effect
    }
    var board: CollaborationTarget { .init(kind: .board, id: boardID) }
    func expectation(_ target: CollaborationTarget) throws -> CollaborationExpectation {
      .init(target: target, revision: try store.targetContentRevision(target: target))
    }
    func insert() -> CollaborationOperation {
      .init(kind: .insertElement, target: board, id: labelID.uuidString, values: ["kind": .string("nativeText"),
        "source": .string("Atomic label"), "worldOrigin": .object(["tileX": .number(0), "tileY": .number(0), "localX": .number(0), "localY": .number(0)]),
        "frame": .object(["x": .number(0), "y": .number(0), "width": .number(200), "height": .number(80)])])
    }
  }

  @Test func rejectedCompositionHasNoPartialContentAndItsKeyStaysNotSaved() throws {
    let f = try Fixture(); defer { f.clean() }
    let effect = try f.effect()
    let before = try f.store.readBoardNode(f.boardID)
    let action = CollaborationAction(id: effect.id, summary: "Insert label and move carrier", expected: [try f.expectation(f.board)],
      operations: [f.insert(), .init(kind: .moveItem, target: f.board, id: f.itemID.uuidString,
        values: ["center": try .encode(WorldPoint(x: 500, y: 200))])])
    let admission = try f.store.admitCollaborationSubmission(action)
    let prepared = try f.store.prepareCollaborationSubmission(action.id, fingerprint: admission.fingerprint)
    let failure: CollaborationError
    do {
      _ = try f.store.commitCollaborationSubmission(prepared.action, fingerprint: admission.fingerprint, actor: f.actor)
      Issue.record("Missing composition scope must reject the entire compound action"); return
    } catch let error as CollaborationError { failure = error }
    #expect(failure.code == "composition_scope")
    #expect(try f.store.readBoardNode(f.boardID) == before)
    #expect(try f.store.collaborationActionIfPresent(effect.id) == nil)
    #expect(try f.store.scriptEffectOutcome(effect) == .notSaved)
    let resolved = try f.store.reconcileScriptEffect(f.run, id: effect.id, failure: .encode(failure))
    #expect(resolved.state == .notSaved)
    #expect(try resolved.error == .encode(failure))
    #expect(try f.store.admitScriptEffect(f.run, key: effect.key, method: effect.method, arguments: effect.arguments) == resolved)
    try f.store.saveScriptEffect(f.run, effect: effect) // A stale committing copy cannot reopen the key.
    #expect(try f.store.scriptEffect(f.run, id: effect.id) == resolved)
    #expect(try f.store.unfinishedScriptEffects().isEmpty)
  }

  @Test func aSavedNativeActionAndItsUndoOutrankLostResponses() throws {
    let f = try Fixture(); defer { f.clean() }
    let effect = try f.effect()
    let receipt = try f.store.applyCollaborationAction(.init(id: effect.id, summary: "Native action", expected: [f.expectation(f.board)],
      operations: [f.insert()]), actor: f.actor)
    let expected = try f.store.scriptActionOutcome(receipt)
    #expect(try f.store.scriptEffectOutcome(effect) == .saved(expected))
    let resolved = try f.store.reconcileScriptEffect(f.run, id: effect.id,
      failure: .encode(CollaborationError("lost_response", "Native reply was lost")))
    #expect(resolved.state == .saved && resolved.value == expected && resolved.error == nil)
    let undo = try f.effect("undo", key: "undo", arguments: .object(["actionID": .string(effect.id.uuidString)]))
    #expect(try f.store.scriptEffectOutcome(undo) == .notSaved)
    let undone = try f.store.undoCollaborationAction(effect.id, actor: f.actor)
    #expect(try f.store.scriptEffectOutcome(undo) == .saved(f.store.scriptActionOutcome(undone)))
    #expect(try f.store.reconcileScriptEffect(f.run, id: undo.id).state == .saved)
    #expect(try f.store.unfinishedScriptEffects().isEmpty)
  }

  @Test(arguments: ["transaction", "point", "export"])
  func malformedWitnessIsNotAbsence(method: String) throws {
    let f = try Fixture(); defer { f.clean() }
    let effect = try f.effect(method)
    let prefix = method == "transaction" ? "collaboration/actions/" : method == "point" ? "local/script-points/" : "local/script-exports/"
    try f.store.fixtureWrite(Data("damaged witness".utf8), to: f.store.root.appendingPathComponent(prefix + effect.id.uuidString.lowercased() + ".json"))
    do { _ = try f.store.scriptEffectOutcome(effect); Issue.record("A present malformed witness must throw, never return notSaved") }
    catch { /* The reconciliation below records unavailable, not a guessed absence. */ }
    let resolved = try f.store.reconcileScriptEffect(f.run, id: effect.id)
    #expect(resolved.state == .outcomeUnknown)
    #expect(try f.store.unfinishedScriptEffects().map(\.effectID) == [effect.id])
  }

  @Test func recoveryIndexIsPagedAndSurvivesTerminalRuns() throws {
    let f = try Fixture(); defer { f.clean() }
    var ids: [UUID] = []
    for index in 0..<70 { ids.append(try f.effect("present", key: "show-\(index)").id) }
    _ = try f.store.setScriptRunState(f.run, state: .failed)
    #expect(try f.store.unfinishedScriptRuns().isEmpty)
    let reopened = NotebookStore(root: f.store.root)
    var cursor: UUID?, visited: [UUID] = []
    while true {
      let page = try reopened.readTransaction { _ in
        try reopened.currentSQL!.limitReads(.init(rows: 100, bytes: 16_384, valueBytes: 2048, reason: "bounded_effect_recovery"))
        return try reopened.unfinishedScriptEffects(after: cursor, limit: 7)
      }
      #expect(page.count <= 7)
      guard let last = page.last else { break }
      for address in page {
        #expect(address.runID == f.run)
        #expect(try reopened.reconcileScriptEffect(address.runID, id: address.effectID).state == .outcomeUnknown)
      }
      visited += page.map(\.effectID); cursor = last.effectID
    }
    #expect(Set(visited) == Set(ids) && visited.count == ids.count)
    #expect(try reopened.scriptRun(f.run)?.state == .failed)
  }

  @Test func explicitOldRunRepairIsAddressedAndWaitsForTerminalState() throws {
    let f = try Fixture(); defer { f.clean() }
    let effect = try f.effect()
    // Preserve the run/effect journal while modelling its older missing index.
    try f.store.publishRecords(writes: [:], removals: [f.store.scriptEffectRecoveryFile(effect.id)])
    #expect(try f.store.terminalScriptEffectsForRecovery(f.run).isEmpty)
    #expect(try f.store.unfinishedScriptEffects().isEmpty)
    #expect(try f.store.scriptEffect(f.run, id: effect.id).state == .committing)
    _ = try f.store.setScriptRunState(f.run, state: .failed)
    let unrelated = f.store.root.appendingPathComponent("local/script-runs/\(UUID().uuidString.lowercased())/run.json")
    try f.store.fixtureWrite(Data("unrelated malformed history".utf8), to: unrelated)
    #expect(try f.store.terminalScriptEffectsForRecovery(f.run) == [effect.id])
    #expect(try f.store.unfinishedScriptEffects().map(\.effectID) == [effect.id])
    #expect(try f.store.reconcileScriptEffect(f.run, id: effect.id).state == .notSaved)
    #expect(try f.store.terminalScriptEffectsForRecovery(f.run).isEmpty)
    #expect(try f.store.unfinishedScriptEffects().isEmpty)
  }
}
