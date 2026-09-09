import Foundation
import CryptoKit
import NotebookCore

@MainActor
private final class CoordinatorFixture {
  let store: NotebookStore
  let queue: NotebookPersistenceQueue
  let human = UUID(), mac = UUID(), requestID = UUID()
  let target: CollaborationTarget
  let reference: CollaborationReference
  let coordinator: NotebookAgentCoordinator

  init(arguments: [String]) throws {
    let a = arguments
    store = NotebookStore(root: URL(fileURLWithPath: a[2]).appendingPathComponent("archive"))
    _ = try store.initializeWorkspace(actor: human, pageSize: .init(width: 834, height: 1194))
    guard let pageID = try store.readWorkspaceItems(limit: 1).first?.pageIDs.first else { throw NotebookAgentFailure.invalidRequest }
    target = .init(kind: .page, id: pageID)
    var page = try store.loadPage(pageID)
    _ = page.replaceElements([
      .init(id: "selected", kind: .markdown, frame: .init(x: 10, y: 10, width: 60, height: 30), source: "Frozen selected text", html: "<p>Frozen selected text</p>"),
      .init(id: "outside", kind: .markdown, frame: .init(x: 400, y: 400, width: 50, height: 40), source: "Private outside source", html: "<p>Private outside source</p>")
    ], actor: human)
    _ = try store.saveMergedPage(page)
    let files = try store.referenceSourceFiles(target: target)
    reference = .init(target: target, region: .init(x: 0, y: 0, width: 200, height: 100),
      revision: try NotebookStore.referenceRevision(target: target, files: files))
    let context = try store.appendContext(references: [reference], author: .human, actor: human, select: true)
    let png = try Data(contentsOf: URL(fileURLWithPath: a[6]))
    let image = try AgentPinnedImage(referenceID: reference.id, sourceRevision: reference.revision,
      region: reference.region!, worldOrigin: nil, pageIndex: nil, pixelWidth: 16, pixelHeight: 8,
      pixelsPerPoint: 0.08, png: png, sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
    let source = try AgentPinnedSource.capture(requestID: requestID, reference: reference, files: files).withVisual(image)
    let mode: RequestGrant.Mode = ["change", "input_active", "mutation_unconfirmed", "input_stop"].contains(a[5]) ? .change : .question
    let grant = try RequestGrant(mode: mode, references: [reference])
    try store.createAgentRequest(id: requestID, contextID: context.id, replyTo: context.entries[0].id,
      question: "Прочитай выбранный фрагмент и помоги здесь.", grant: grant, sources: [source], actor: human)
    if a[5] == "input_active" || a[5] == "input_stop" {
      try store.saveInputActivity(.init(deviceID: human, sessionID: UUID(), sequence: 1, targets: [target]))
    }
    if a[5] == "question" {
      // The current scene may change after capture; read/render must keep the immutable selected source.
      _ = page.replaceElements([.init(id: "selected", kind: .markdown,
        frame: .init(x: 10, y: 10, width: 60, height: 30), source: "New live text, not the selected source", html: "<p>New live text, not the selected source</p>")], actor: human)
      _ = try store.saveMergedPage(page)
      try store.selectSharedContext(nil, actor: human)
    }
    queue = NotebookPersistenceQueue(store: store)
    let queue = queue
    let executor = try NotebookAgentExecutor(binary: URL(fileURLWithPath: a[1]),
      runtimeDirectory: URL(fileURLWithPath: a[2]).appendingPathComponent("runtime"),
      configuration: URL(fileURLWithPath: a[3]), contractProvider: URL(string: a[4])!)
    coordinator = NotebookAgentCoordinator(executor: executor, persistence: queue, actorID: mac, render: { authority, referenceID in
      let frozen = try await queue.submit { try $0.agentPinnedSource(authority, referenceID: referenceID) }
      guard let image = frozen.image else { throw NotebookAgentFailure.invalidImage }
      return try .init(value: .object(["referenceID": .string(image.referenceID.uuidString),
        "sourceRevision": .string(image.sourceRevision), "sha256": .string(image.sha256),
        "region": .encode(image.region)]), images: [NotebookAgentImage(png: image.png, sha256: image.sha256,
          pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)])
    })
    queue.onCommit = { [weak self] owner in
      if owner == nil { self?.coordinator.storeDidCommit() }
    }
  }

  func output(_ value: JSONValue) {
    if var bytes = try? JSONEncoder().encode(value) { bytes.append(10); try? FileHandle.standardOutput.write(contentsOf: bytes) }
  }
  func command(_ command: String) async {
    do {
      let id = requestID, human = human
      if command == "stop" {
        try await queue.submit(publishesChanges: true) { try $0.requestAgentStop(id, actor: human) }
        output(.object(["event": .string("stopCommitted")]))
      } else if command == "release" {
        try await queue.submit { try $0.resetInputActivity(deviceID: human) }
        output(.object(["event": .string("inputReleased")]))
      } else if command == "queue-probe" {
        let held = try await queue.submit { try $0.inputActivities().contains(where: \.isActive) }
        output(.object(["event": .string("writerAvailable"), "inputHeld": .bool(held)]))
      }
    } catch { output(.object(["event": .string("fixtureError"), "error": .string(error.localizedDescription)])) }
  }
  func run() async throws {
    output(.object(["event": .string("fixture"), "requestID": .string(requestID.uuidString),
      "referenceID": .string(reference.id.uuidString), "target": try .encode(target), "revision": .string(reference.revision)]))
    await coordinator.start()
    let deadline = ContinuousClock.now.advanced(by: .seconds(25))
    let id = requestID
    while ContinuousClock.now < deadline {
      let snapshot = try await queue.submit { try $0.agentRequest(id) }
      if let snapshot, [.completed, .failed, .stopped].contains(snapshot.status), !coordinator.isRunning {
        let cursor = try await queue.submit { try $0.currentReadCursor() }
        for _ in 0..<20 { coordinator.storeDidCommit() }
        let stop = await coordinator.stop()
        let after = try store.currentReadCursor()
        let actionCount = try store.loadPage(target.id).elements.filter { $0.id == "agent-answer" }.count
        output(.object(["event": .string("complete"), "snapshot": try .encode(snapshot), "status": .string(snapshot.status.rawValue),
          "stoppedCleanly": .bool(stop), "idempotentStop": .bool(after == cursor),
          "savedElements": .number(Double(actionCount))]))
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    _ = await coordinator.stop()
    throw NotebookAgentFailure.transportTimeout
  }
}

@main struct NotebookAgentCoordinatorHarness {
  @MainActor static func main() async throws {
    guard CommandLine.arguments.count == 7 else { fatalError("Isolated SQL coordinator harness: binary fixtureRoot profile loopbackProvider scenario png") }
    let fixture = try CoordinatorFixture(arguments: CommandLine.arguments)
    Task.detached {
      while let command = readLine() { await fixture.command(command) }
    }
    try await fixture.run()
  }
}
