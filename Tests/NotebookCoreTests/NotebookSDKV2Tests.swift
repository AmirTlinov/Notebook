import Foundation
import Testing
@testable import NotebookCore

@Suite("Notebook SDK v2", .serialized)
struct NotebookSDKV2Tests {
  @Test func publicAdmissionRequiresVersionTwoAndRejectsVersionOne() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-v2-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root)
    _ = try store.initializeWorkspace(actor: UUID(), pageSize: .init(width: 834, height: 1194))
    let run = try store.admitScriptRun(.init(op: .start, runID: UUID(), apiVersion: 2, code: "return 2"))
    #expect(run.apiVersion == 2)
    #expect(throws: CollaborationError.self) { try store.admitScriptRun(.init(op: .start, runID: UUID(), apiVersion: 1, code: "return 1")) }
  }

  @Test func actionOutcomeNamesAnImmutableVersionAndPostEffectBasis() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-result-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), pageID = UUID()
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialPageID: pageID)
    let target = CollaborationTarget(kind: .page, id: pageID)
    let action = try CollaborationAction(summary: "Result witness", expected: [.init(target: target, revision: store.targetContentRevision(target: target))],
      operations: [.init(kind: .insertElement, target: target, id: "label", values: ["kind": .string("markdown"),
        "source": .string("Canonical source"), "frame": try .encode(PageRect(x: 10, y: 10, width: 100, height: 100))])])
    let receipt = try store.applyCollaborationAction(action, actor: actor)
    let result = try store.scriptActionOutcome(receipt)
    #expect(result["actionID"]?.string.flatMap(UUID.init(uuidString:)) == receipt.id)
    #expect(result["actionVersion"]?.string == (try receipt.deliveryVersion()))
    #expect(result["basis"]?["workspaceID"]?.string.flatMap(UUID.init(uuidString:)) == header.workspaceID)
    #expect(result["changed"]?.array.isEmpty == false)
  }
  @Test func basisNeverFreshensAndReadScopeDoesNotAuthorizeMoves() throws {
    let f = try NotebookObservationReadTests.Fixture()
    _ = try f.store.applyCollaborationAction(.init(summary: "Initial", expected: [.init(target: f.target, revision: f.store.targetContentRevision(target: f.target))],
      operations: [.init(kind: .insertElement, target: f.target, id: "node", values: ["kind": .string("markdown"), "source": .string("initial"),
        "frame": try .encode(PageRect(x: 10, y: 10, width: 100, height: 100))])]), actor: f.actor)
    let base = try f.store.readBasis(targets: [f.target])
    let operation = CollaborationOperation(kind: .updateElement, target: f.target, id: "node", values: ["source": .string("agent")])
    let expected = try f.store.expectations(base: base, operations: [operation])
    _ = try f.store.applyCollaborationAction(.init(summary: "Human", expected: expected,
      operations: [.init(kind: .updateElement, target: f.target, id: "node", values: ["source": .string("human")])]), actor: f.actor)
    #expect(throws: CollaborationError.self) {
      try f.store.applyCollaborationAction(.init(summary: "Stale", expected: f.store.expectations(base: base, operations: [operation]), operations: [operation]), actor: f.actor)
    }
    #expect(try f.store.readPageElement(pageID: f.pageID, elementID: "node")?.source == "human")
    do { _ = try f.store.expectations(base: .init(workspaceID: base.workspaceID, owners: []), operations: [operation]); Issue.record("Missing basis") }
    catch let error as CollaborationError { #expect(error.code == "basis_incomplete"); #expect(error.operation?.index == 0) }
    do { _ = try f.store.expectations(base: .init(workspaceID: UUID(), owners: base.owners), operations: [operation]); Issue.record("Wrong workspace") }
    catch let error as CollaborationError { #expect(error.code == "basis_workspace_mismatch") }
    let fresh = try f.store.readBasis(targets: [f.target])
    do { _ = try NotebookReadBasis.merging([base, fresh]); Issue.record("Conflicting basis") }
    catch let error as CollaborationError { #expect(error.code == "basis_conflict") }
    let move = CollaborationOperation(kind: .updateElement, target: f.target, id: "node", values: ["frame": try .encode(PageRect(x: 20, y: 20, width: 100, height: 100))])
    do { _ = try f.store.applyCollaborationAction(.init(summary: "Read is not permission", expected: f.store.expectations(base: fresh, operations: [move]), operations: [move]), actor: f.actor); Issue.record("Scope required") }
    catch let error as CollaborationError { #expect(error.code == "composition_scope") }
  }

  @Test func originalResultAndItsPagesSurviveUndoAndNativeCommitAlreadySavesEffect() throws {
    let f = try NotebookObservationReadTests.Fixture(), runID = UUID()
    _ = try f.store.admitScriptRun(.init(op: .start, runID: runID, apiVersion: 2, code: "immutable result"))
    _ = try f.store.setScriptRunState(runID, state: .running)
    var effect = try f.store.admitScriptEffect(runID, key: "commit", method: "transaction", arguments: .object([:]))
    effect.state = .committing; try f.store.saveScriptEffect(runID, effect: effect)
    let operations = try (0..<40).map { index in
      CollaborationOperation(kind: .insertElement, target: f.target, id: "node-\(index)", values: ["kind": .string("graphic"), "source": .string(""),
        "frame": try .encode(PageRect(x: 10, y: 10, width: 100, height: 100)),
        "graphic": try .encode(NotebookGraphic(shape: .ellipse, label: "Before"))])
    }
    let base = try f.store.readBasis(targets: [f.target])
    let action = CollaborationAction(id: effect.id, summary: "Original", expected: try f.store.expectations(base: base, operations: operations), operations: operations)
    let admission = try f.store.admitCollaborationSubmission(action)
    let prepared = try f.store.prepareCollaborationSubmission(action.id, fingerprint: admission.fingerprint)
    var request = NotebookCommand(command: .commitAction)
    request.action = prepared.action; request.fingerprint = admission.fingerprint
    request.scriptEffect = .init(runID: runID, effectID: effect.id)
    let original = try NotebookCommandDispatcher(store: f.store).handle(request)
    // Simulate losing the native reply: no host saveScriptEffect call follows.
    #expect(try f.store.scriptEffect(runID, id: effect.id).value == original)
    let version = try #require(original["actionVersion"]?.string), next = try #require(original["next"]?.string)
    let originalPage = try f.store.actionResultPage(effect.id, version: version, next: next)
    let undone = try f.store.undoCollaborationAction(effect.id, actor: f.actor)
    #expect(try undone.deliveryVersion() != version)
    #expect(try f.store.savedActionResult(effect.id) == original)
    #expect(try f.store.reconcileScriptEffect(runID, id: effect.id).value == original)
    #expect(try f.store.actionResultPage(effect.id, version: version, next: next) == originalPage)
    #expect(throws: CollaborationError.self) { try f.store.actionResultPage(effect.id, version: undone.deliveryVersion(), next: next) }
    #expect(try f.store.actionVersionModel(effect.id, version: version).undo == nil)
  }

  @Test func historicalRunIsReadableThroughV2ButCannotRestartV1() throws {
    let f = try NotebookObservationReadTests.Fixture(), id = UUID()
    _ = try f.store.admitScriptRun(.init(op: .start, runID: id, code: "return 'historical'"))
    _ = try f.store.setScriptRunState(id, state: .completed, result: .string("historical"))
    let file = "local/script-runs/\(id.uuidString.lowercased())/run.json"
    let saved = try #require(try f.store.storedValue(file))
    try f.store.publishRecords(writes: [file: saved.setting("apiVersion", .number(1)).setting("fingerprint", .string("historical-v1"))])
    let reply = try f.store.scriptRunPage(id)
    #expect(reply["api_version"] == .number(2))
    #expect(reply["run_api_version"] == .number(1))
    #expect(reply["result"] == .string("historical"))
    #expect(reply["fingerprint"] == .string("historical-v1"))
    #expect(throws: CollaborationError.self) { try f.store.admitScriptRun(.init(op: .start, runID: id, apiVersion: 1, code: "return 'historical'")) }
    #expect(throws: CollaborationError.self) { try f.store.admitScriptRun(.init(op: .start, runID: id, apiVersion: 2, code: "return 'historical'")) }
  }

}
