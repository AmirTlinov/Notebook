import Foundation
import CryptoKit
import Testing
@testable import NotebookCore

@Suite("Native script and raw action identities")
struct NotebookScriptAdmissionTests {
  private func fixture() throws -> (NotebookStore, UUID) {
    let store = NotebookStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("notebook-script-core-\(UUID())"))
    let page = try store.loadOrCreate(actor: UUID(), pageSize: .init(width: 834, height: 1194)).0.selectedPageID!
    _ = try store.loadOrCreateSpatialInk(actor: UUID())
    return (store, page)
  }
  private func action(_ store: NotebookStore, _ pageID: UUID, source: String = "# first") throws -> CollaborationAction {
    let target = CollaborationTarget(kind: .page, id: pageID)
    return .init(summary: "Raw Markdown identity", expected: [.init(target: target,
      revision: try store.targetContentRevision(target: target))], operations: [
        .init(kind: .insertElement, target: target, id: "raw",
          values: ["kind": .string("markdown"), "source": .string(source),
            "frame": try .encode(PageRect(x: 20, y: 20, width: 300, height: 120))])])
  }
  private func normalized(_ plan: NotebookActionPreparation) -> CollaborationAction {
    let source = plan.action
    return .init(id: source.id, summary: source.summary, references: source.references, expected: source.expected,
      operations: source.operations.enumerated().map { index, operation in
        var values = operation.values
        if plan.markdownOperations.contains(index) { values["html"] = .string("<h1>first</h1>") }
        return .init(kind: operation.kind, target: operation.target, id: operation.id, values: values)
      })
  }

  @Test func rawRetryIsResolvedBeforeThePreviouslyCreatedElementIsRead() throws {
    let (store, pageID) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let raw = try action(store, pageID), admission = try store.admitCollaborationSubmission(raw)
    let prepared = try store.prepareCollaborationSubmission(raw.id, fingerprint: admission.fingerprint)
    let receipt = try store.commitCollaborationSubmission(normalized(prepared), fingerprint: admission.fingerprint, actor: UUID())
    let target = CollaborationTarget(kind: .page, id: pageID)
    _ = try store.applyCollaborationAction(.init(summary: "Remove later",
      expected: [.init(target: target, revision: store.targetContentRevision(target: target))],
      operations: [.init(kind: .removeElement, target: target, id: "raw", values: [:])]), actor: UUID())
    let retry = try store.admitCollaborationSubmission(raw)
    #expect(retry.state == .saved)
    #expect(retry.receipt == receipt)
    #expect(try store.commitCollaborationSubmission(normalized(prepared), fingerprint: admission.fingerprint, actor: UUID()) == receipt)
    #expect(try store.loadPage(pageID).elements.isEmpty)
  }

  @Test func staleContentWinsOverWorldDependentNormalizationMismatch() throws {
    let (store, pageID) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let first = try action(store, pageID), firstAdmission = try store.admitCollaborationSubmission(first)
    _ = try store.commitCollaborationSubmission(normalized(store.prepareCollaborationSubmission(first.id, fingerprint: firstAdmission.fingerprint)),
      fingerprint: firstAdmission.fingerprint, actor: UUID())
    let target = CollaborationTarget(kind: .page, id: pageID)
    let raw = CollaborationAction(summary: "Update source", expected: [
      .init(target: target, revision: try store.targetContentRevision(target: target))],
      operations: [.init(kind: .updateElement, target: target, id: "raw", values: ["source": .string("new")])])
    let admission = try store.admitCollaborationSubmission(raw)
    let prepared = try store.prepareCollaborationSubmission(raw.id, fingerprint: admission.fingerprint)
    #expect(prepared.markdownOperations == [0])
    _ = try store.applyCollaborationAction(.init(summary: "Change kind", expected: raw.expected, operations: [
      .init(kind: .removeElement, target: target, id: "raw", values: [:]),
      .init(kind: .insertElement, target: target, id: "raw", values: [
        "kind": .string("web"), "source": .string("human"), "html": .string("<button>human</button>"),
        "frame": try .encode(PageRect(x: 20, y: 20, width: 300, height: 120))])]), actor: UUID())
    do {
      _ = try store.commitCollaborationSubmission(normalized(prepared), fingerprint: admission.fingerprint, actor: UUID())
      Issue.record("A stale prepared action must not be committed.")
    } catch let error as CollaborationError { #expect(error.code == "revision_conflict") }
  }

  @Test func legacyReceiptsRemainReadableWithoutInventingRawIdentity() throws {
    let (store, pageID) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let raw = try action(store, pageID)
    let legacy = try store.applyCollaborationAction(raw, actor: UUID())
    #expect(try store.collaborationAction(raw.id) == legacy)
    do { _ = try store.admitCollaborationSubmission(raw); Issue.record("No historical raw fingerprint exists.") }
    catch let error as CollaborationError { #expect(error.code == "request_identity_unavailable") }
    #expect(try store.collaborationAction(raw.id) == legacy)
  }

  @Test func coldRegionalStatusIsAReadWithoutRenderAdmissionOrFiles() throws {
    let (store, pageID) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let target = CollaborationTarget(kind: .page, id: pageID)
    let reference = CollaborationReference(target: target, region: .init(x: 0, y: 0, width: 100, height: 100),
      revision: try store.referenceRevision(target: target))
    let status = try store.readTransaction { _ in try store.referenceStatus(reference) }
    #expect(status.status == .checking)
    #expect(try store.targetRenderRequests().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("previews/reference-baselines").path))
  }

  @Test func durableRunAndEffectFingerprintsDoNotExposeTheirSourceOnResume() throws {
    let (store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let id = UUID(), request = NotebookScriptRequest(op: .start, runID: id, apiVersion: 1,
      code: "return args.answer", arguments: .object(["answer": .number(42)]))
    let run = try store.admitScriptRun(request)
    #expect(try store.admitScriptRun(request) == run)
    do { _ = try store.admitScriptRun(.init(op: .start, runID: id, apiVersion: 1, code: "return 7")); Issue.record("Conflicting source reused run ID.") }
    catch let error as CollaborationError { #expect(error.code == "run_id_conflict") }
    _ = try store.setScriptRunState(id, state: .running)
    var effect = try store.admitScriptEffect(id, key: "document", method: "transaction",
      arguments: .object(["source": .string(String(repeating: "private-source", count: 50_000))]))
    effect.state = .saved; effect.value = .object(["source": effect.arguments["source"]!])
    try store.saveScriptEffect(id, effect: effect)
    for _ in 0..<4 { _ = try store.appendScriptEvent(id, kind: "value", value: .string(String(repeating: "x", count: 200_000))) }
    _ = try store.setScriptRunState(id, state: .completed, result: .number(42))
    let page = try store.scriptRunPage(id)
    let bytes = try JSONEncoder().encode(page), text = String(decoding: bytes, as: UTF8.self)
    #expect(bytes.count < 1_048_576)
    #expect(!text.contains("private-source"))
    #expect(page["has_more"] == .bool(true))
    #expect(page["result"] == .number(42))
    #expect(try store.scriptEffect(id, id: effect.id).arguments == effect.arguments)
    let compact = try store.readTransaction { _ in
      try store.currentSQL!.limitReads(.init(rows: 128, bytes: 65_536, valueBytes: 32_768, reason: "bounded_resume_metadata"))
      return try store.scriptRunPage(id, after: 4)
    }
    #expect(compact["result"] == .number(42))
    #expect(compact["effects"]?.array.count == 1)
    #expect(try store.unfinishedScriptEffectIDs(id).isEmpty)
  }

  @Test func publicationReceiptAndExportJobCommitTogetherAcrossRestart() throws {
    let (store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "text", source: "Printed")])
    try store.saveDocument(document); try store.saveDocumentState(.init(id: document.id, actor: UUID()))
    let id = UUID()
    try store.saveScriptExportJob(id, value: .object(["status": .string("queued"), "jobID": .string(id.uuidString)]))
    let publication = NotebookExportPublication(documentID: document.id, expectedRevision: document.contentStamp.revision,
      source: "trusted source", pdf: Data("%PDF-proof".utf8), log: "", jobID: id)
    let receipt = try store.publishDocumentExport(publication)
    let lost = UUID()
    try store.saveScriptExportJob(lost, value: .object(["status": .string("queued"), "jobID": .string(lost.uuidString)]))
    let reopened = NotebookStore(root: store.root)
    try reopened.interruptUnfinishedScriptExports()
    #expect(try reopened.scriptExportJob(id)?["status"] == .string("saved"))
    #expect(try reopened.scriptExportJob(id)?["receipt"]?["pdfSHA256"] == .string(receipt.pdfSHA256))
    #expect(try reopened.scriptExportJob(lost)?["status"] == .string("interrupted"))
  }

  @Test func emittedPixelsSurvivePreviewReplacementAndResumePagesHaveFourImages() throws {
    let (store, _) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let run = UUID()
    _ = try store.admitScriptRun(.init(op: .start, runID: run, apiVersion: 1, code: "image-output"))
    _ = try store.setScriptRunState(run, state: .running)
    let png = Data([137,80,78,71,13,10,26,10,1,2,3,4])
    let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    for _ in 0..<6 { _ = try store.appendScriptImageEvent(run, png: png, expectedSHA256: hash) }
    let first = try store.scriptRunPage(run)
    #expect(first["events"]?.array.count == 4)
    #expect(first["next_seq"] == .number(4))
    #expect(first["has_more"] == .bool(true))
    let descriptor = try #require(first["events"]?.array.first?["value"]).decode(NotebookArtifactRequest.self)
    #expect(descriptor.kind == .scriptImage)
    let artifact = try store.authorizedArtifact(descriptor)
    try Data("a later preview".utf8).write(to: store.currentViewPreviewURL, options: .atomic)
    let reopened = NotebookStore(root: store.root)
    #expect(try Data(contentsOf: URL(fileURLWithPath: reopened.authorizedArtifact(descriptor).path)) == png)
    #expect(artifact.sha256 == hash)
    let second = try reopened.scriptRunPage(run, after: 4)
    #expect(second["events"]?.array.count == 2)
    #expect(second["has_more"] == .bool(false))
    do {
      _ = try reopened.setScriptRunState(run, state: .completed, result: .string(String(repeating: "x", count: 262_145)))
      Issue.record("Result overflow must fail before publishing completed.")
    } catch let error as CollaborationError { #expect(error.code == "output_limit") }
    #expect(try reopened.scriptRun(run)?.state == .running)
  }

  @Test func committedLargeActionReturnsBoundedProofAndEveryResultHasAPage() throws {
    let (store, pageID) = try fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
    let source = String(repeating: "PRIVATE_BODY_FOR_INVERSE\n", count: 12_000)
    let first = try action(store, pageID, source: source), target = first.operations[0].target
    let operations = first.operations + (1..<40).map { index in
      CollaborationOperation(kind: .insertElement, target: target, id: "result-\(index)",
        values: ["kind": .string("markdown"), "source": .string("# result"),
          "frame": .object(["x": .number(20), "y": .number(Double(index * 4)), "width": .number(300), "height": .number(120)])])
    }
    let raw = CollaborationAction(id: first.id, summary: first.summary, expected: first.expected, operations: operations)
    let dispatcher = NotebookCommandDispatcher(store: store)
    var admit = NotebookCommand(command: .admitAction); admit.action = raw
    let admission = try dispatcher.handle(admit)
    let fingerprint = try #require(admission["fingerprint"]?.string)
    let prepared = try store.prepareCollaborationSubmission(raw.id, fingerprint: fingerprint)
    var commit = NotebookCommand(command: .commitAction); commit.action = normalized(prepared); commit.fingerprint = fingerprint
    let result = try dispatcher.handle(commit), encoded = try JSONEncoder().encode(result)
    #expect(encoded.count < 65_536)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_BODY_FOR_INVERSE"))
    #expect(result.array.first?["receipt"]?["id"]?.string?.lowercased() == raw.id.uuidString.lowercased())
    #expect(result.array.first?["pages"]?["operations"]?["total"] == .number(40))
    #expect(result.array.first?["pages"]?["operations"]?["nextOffset"] == .number(32))
    #expect(try store.collaborationAction(raw.id).action.operations.first?.values["source"] == .string(source))
    var detail = NotebookCommand(command: .actionDetails); detail.actionID = raw.id
    detail.actionPage = .init(section: .operations, offset: 32, limit: 5)
    let page = try dispatcher.handle(detail).array.first?["page"]
    #expect(page?["items"]?.array.count == 5)
    #expect(page?["items"]?.array.first?["id"] == .string("result-32"))
    #expect(page?["nextOffset"] == .number(37))
    #expect(try dispatcher.handle(admit)["receipt"]?["status"] == .string("saved"))
    var undo = NotebookCommand(command: .undo); undo.actionID = raw.id
    let undone = try dispatcher.handle(undo)
    #expect(try JSONEncoder().encode(undone).count < 65_536)
    #expect(try store.loadPage(pageID).elements.isEmpty)
    #expect(try store.scriptActionOutcome(store.collaborationAction(raw.id)) == undone)
  }
}
