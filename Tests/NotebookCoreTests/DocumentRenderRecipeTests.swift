import Foundation
import Testing
@testable import NotebookCore

@Suite("Persistent document pictures name their rendering recipe")
struct DocumentRenderRecipeTests {
  private func requestID(_ key: JSONValue) throws -> UUID {
    let hex = Array(try collaborationHash(key))
    let value = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-4" + String(hex[13..<16])
      + "-8" + String(hex[17..<20]) + "-" + String(hex[20..<32])
    return try #require(UUID(uuidString: value))
  }

  @Test(arguments: ["error", "ready"])
  func anotherRecipeCannotReuseOrEraseThePreviousResult(status: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-render-recipe-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    let document = DocumentDocument(actor: actor, blocks: [.markdown(id: "formula", source: "$x^2+y^2=z^2$")])
    let state = DocumentStateJournal(id: document.id, actor: actor)
    try store.saveDocument(document); try store.saveDocumentState(state)
    let acceptedDocument = try store.loadDocument(document.id), acceptedState = try store.loadDocumentState(document.id)
    let target = CollaborationTarget(kind: .document, id: document.id)
    let revision = try store.referenceRevision(target: target)
    let originalKey: JSONValue = .object(["target": try .encode(target), "source": .string(revision),
      "region": .null, "origin": .null, "page": .number(0)])
    let previous = TargetRenderRequest(id: try requestID(originalKey), target: target, sourceRevision: revision,
      region: nil, worldOrigin: nil, pageIndex: 0, pageVisionRevision: nil, createdAt: Date())
    try store.publishRecords(writes: ["collaboration/render-requests/" + previous.id.uuidString.lowercased() + ".json": try .encode(previous)])
    let receipt = TargetRenderReceipt(request: previous, status: status,
      diagnostics: status == "error" ? [.init(kind: "render_error", message: "Previous preparation exceeded its deadline")] : [])
    try store.saveTargetRender(receipt)
    let previousBytes = try Data(contentsOf: store.targetReceiptURL(previous.id))

    let current = try store.requestTargetRender(target: target, expectedRevision: document.contentStamp.revision)
    #expect(throws: CollaborationError.self) { try previous.requireCurrentRenderingRecipe() }
    try current.requireCurrentRenderingRecipe()
    #expect(current.id != previous.id)
    #expect(current.id == (try requestID(originalKey.setting("renderer", .string("NotebookDocumentFragments/2")))))
    #expect(current.sourceRevision == previous.sourceRevision)
    #expect(!FileManager.default.fileExists(atPath: store.targetReceiptURL(current.id).path))
    #expect(try Data(contentsOf: store.targetReceiptURL(previous.id)) == previousBytes)
    #expect(try store.loadDocument(document.id) == acceptedDocument)
    #expect(try store.loadDocumentState(document.id) == acceptedState)
    #expect(try Set(store.targetRenderRequests().map(\.id)) == [previous.id, current.id])

    // The same recipe is still stable after restart. Even its failure remains
    // explicit: this contract does not clear errors or add an automatic retry.
    let currentFailure = TargetRenderReceipt(request: current, status: "error",
      diagnostics: [.init(kind: "render_error", message: "Current explicit failure")])
    try store.saveTargetRender(currentFailure)
    let currentBytes = try Data(contentsOf: store.targetReceiptURL(current.id))
    let reopened = NotebookStore(root: root)
    #expect(try reopened.requestTargetRender(target: target, expectedRevision: document.contentStamp.revision) == current)
    #expect(try Data(contentsOf: reopened.targetReceiptURL(current.id)) == currentBytes)
    #expect(try Data(contentsOf: reopened.targetReceiptURL(previous.id)) == previousBytes)
  }

  @Test func anotherDocumentPageGetsItsOwnStablePhysicalAddress() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-render-page-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "Measured book")])
    try store.saveDocument(document)
    try store.saveDocumentState(.init(id: document.id, actor: UUID()))
    let target = CollaborationTarget(kind: .document, id: document.id)
    let first = try store.requestTargetRender(target: target, expectedRevision: document.contentStamp.revision)
    let distant = try store.requestTargetRender(target: target, expectedRevision: document.contentStamp.revision, pageIndex: 37)
    #expect(first.id != distant.id)
    #expect(first.sourceRevision == distant.sourceRevision)
    #expect(distant.pageIndex == 37)
    #expect(try store.requestTargetRender(target: target, expectedRevision: document.contentStamp.revision, pageIndex: 37) == distant)
  }

  @Test func pageInkAboveArtifactsGetsANewStableCompositeIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-render-ink-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), page = PageDocument(size: .init(width: 100, height: 100), actor: UUID())
    try store.savePage(page)
    let target = CollaborationTarget(kind: .page, id: page.id), source = try store.referenceRevision(target: .init(kind: .page, id: page.id))
    let key: JSONValue = .object(["target": try .encode(target), "source": .string(source),
      "region": .null, "origin": .null, "page": .number(0)])
    let request = try store.requestTargetRender(target: target, expectedRevision: page.agentStamp.revision)
    #expect(request.id != (try requestID(key)))
    #expect(request.id == (try requestID(key.setting("renderer", .string("NotebookPageComposition/2")))))
    #expect(try store.requestTargetRender(target: target, expectedRevision: page.agentStamp.revision).id == request.id)
  }

  @Test(arguments: ["error", "ready"])
  func regionalProofUsesTheCurrentRecipeWithoutRewritingHistoricalBaseline(status: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-render-baseline-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), document = DocumentDocument(actor: UUID(), blocks: [.markdown(id: "body", source: "$x^2$")])
    try store.saveDocument(document); try store.saveDocumentState(.init(id: document.id, actor: UUID()))
    let target = CollaborationTarget(kind: .document, id: document.id), region = PageRect(x: 20, y: 20, width: 200, height: 120)
    let revision = try store.referenceRevision(target: target)
    let reference = CollaborationReference(target: target, region: region, pageIndex: 0, revision: revision)
    let oldKey: JSONValue = .object(["target": try .encode(target), "source": .string(revision),
      "region": try .encode(region), "origin": .null, "page": .number(0)])
    let previous = TargetRenderRequest(id: try requestID(oldKey), target: target, sourceRevision: revision,
      region: region, worldOrigin: nil, pageIndex: 0, pageVisionRevision: nil, createdAt: Date())
    try store.publishRecords(writes: ["collaboration/render-requests/" + previous.id.uuidString.lowercased() + ".json": try .encode(previous)])
    try store.saveTargetRender(.init(request: previous, status: status, referenceFingerprint: "old-pixels"))
    let oldBaseline = root.appendingPathComponent("previews/reference-baselines/" + (try collaborationHash(oldKey)) + ".json")
    try FileManager.default.createDirectory(at: oldBaseline.deletingLastPathComponent(), withIntermediateDirectories: true)
    let historicalBytes = try JSONEncoder().encode(JSONValue.object(["reference": try .encode(reference), "fingerprint": .string("old-pixels")]))
    try historicalBytes.write(to: oldBaseline)

    let current = try store.requestTargetRender(target: target, expectedRevision: document.contentStamp.revision, region: region)
    #expect(try store.referenceStatus(reference, prepareRender: false).status == .checking)
    try store.saveTargetRender(.init(request: current, status: "ready", referenceFingerprint: "current-pixels"))
    let proof = try store.referenceStatus(reference, prepareRender: false)
    #expect(proof.status == .current)
    #expect(proof.fingerprint == "current-pixels")
    #expect(try Data(contentsOf: oldBaseline) == historicalBytes)
    let oldReceipt = try JSONDecoder().decode(TargetRenderReceipt.self, from: Data(contentsOf: store.targetReceiptURL(previous.id)))
    #expect(oldReceipt.status == status)
    #expect(oldReceipt.referenceFingerprint == "old-pixels")
  }

}
