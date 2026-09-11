import Foundation
import NotebookCore

/// Exercises the production queue, not an OCR provider or an installed notebook.
@main
struct ComputationQueueProof {
  enum Failure: Error { case contract(String) }

  @MainActor
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-computation-queue-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), notebook = UUID(), page = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194), initialNotebookID: notebook, initialPageID: page)
    let queue = NotebookPersistenceQueue(store: store)
    var checks: [String] = [], commits = 0
    queue.onCommit = { _ in commits += 1 }
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw Failure.contract(label) }
      checks.append(label)
    }
    @Sendable func action(x: Double) -> PageInkAction {
      .init(tool: .pen, samples: [.init(point: .init(x: x, y: 40), timeOffset: 0,
        width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    }
    @Sendable func append(_ stroke: PageInkAction, in store: NotebookStore) throws {
      var document = try store.loadPage(page)
      let change = try document.prepareInkChange(.append(stroke), stamp: .init(counter: document.drawingStamp.counter + 1, actor: actor))
      guard document.publishInkChange(change) else { throw Failure.contract("publish accepted contact") }
      try store.savePage(document)
    }

    let first = action(x: 30)
    queue.enqueue(owner: .page(page)) { store in try append(first, in: store); return false }
    let ink = try await queue.submit { store in
      try store.readComputationInk(notebookID: notebook, pageID: page, region: .init(x: 10, y: 10, width: 150, height: 100))
    }
    try check(ink.drawing.actions.map(\.id) == [first.id], "recognition input follows durable contact")
    let record = try await queue.submit(publishesChanges: true) { try $0.activateComputation(id: UUID(), ink: ink, actor: actor).computation }
    let input = try await queue.submit(publishesChanges: true) {
      try $0.beginComputationRecognition(pageID: page, id: record.id, expectedRevision: record.revision, attemptID: UUID(), ink: ink, actor: actor)
    }
    let packet = try await Task.detached {
      try input.preparing(.init(recognizer: "authored-contract-fixture", candidates: [.init(kind: .python, text: "x = 2\nprint(x)\n")]))
    }.value
    let second = action(x: 60)
    queue.enqueue(owner: .page(page)) { store in try append(second, in: store); return false }
    _ = await queue.flush()
    let beforeRejected = commits
    do {
      _ = try await queue.submit(publishesChanges: true) { try $0.publishComputationRecognition(packet, actor: actor) }
      throw Failure.contract("late recognition must be rejected")
    } catch let error as CollaborationError {
      try check(error.code == "source_conflict", "late recognition reports source conflict")
    }
    try check(commits == beforeRejected, "rejected recognition has no commit notification")
    try check(queue.failure == nil, "recognition failure does not block accepted ink")
    let third = action(x: 90)
    queue.enqueue(owner: .page(page)) { store in try append(third, in: store); return false }
    let flushed = await queue.flush()
    try check(flushed, "later native contact is durable")
    try check(try PageInkDrawing.decode(store.loadPage(page).drawingData).activeActions.map(\.id) == [first.id, second.id, third.id], "all accepted contact UUIDs survive")

    let freshInk = try await queue.submit { try $0.readComputationInk(notebookID: notebook, pageID: page, region: ink.source.region) }
    let fresh = try await queue.submit(publishesChanges: true) { store in
      let current = try store.readComputation(pageID: page, id: record.id).computation
      return try store.beginComputationRecognition(pageID: page, id: record.id, expectedRevision: current.revision,
        attemptID: UUID(), ink: freshInk, actor: actor)
    }
    let late = try await Task.detached { try fresh.preparing(.init(recognizer: "authored-contract-fixture", candidates: [.init(kind: .mathematics, text: "2 + 3")])) }.value
    _ = try await queue.submit(publishesChanges: true) { try $0.stopComputation(pageID: page, id: record.id, expectedRevision: fresh.revision, actor: actor) }
    do {
      _ = try await queue.submit(publishesChanges: true) { try $0.publishComputationRecognition(late, actor: actor) }
      throw Failure.contract("stopped recognition must be rejected")
    } catch NotebookStorageError.transactionConflict { checks.append("stopped attempt cannot publish") }
    let finished = await queue.flush()
    try check(finished && queue.pendingCount == 0 && queue.failure == nil, "queue drains after cancellation")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let result: [String: JSONValue] = ["status": .string("passed"), "checks": .array(checks.map(JSONValue.string)),
      "recognitionAcceptance": .bool(false), "installedApplicationsTouched": .bool(false)]
    print(String(decoding: try encoder.encode(result), as: UTF8.self))
  }
}
