import XCTest
import NotebookCore
import NotebookCodex
@testable import Notebook

private actor RunOwner: NotebookCodexProcessOwner, NotebookCodexCatalogueOwner {
  var starts = 0, writes: [Data] = [], stops = 0
  var unknownWrite = false
  var outputs: [UUID: @Sendable (NotebookProcessEvent) async throws -> Void] = [:]
  func setUnknownWrite() { unknownWrite = true }
  func counts() -> (Int, Int, Int) { (starts, writes.count, stops) }
  func startProcess(id: UUID, request: NotebookRunRequest, publish: @escaping @Sendable (NotebookProcessEvent) async throws -> Void) async throws {
    starts += 1; outputs[id] = publish; try await publish(.output(Data("ready\r\n".utf8)))
  }
  func writeProcess(id: UUID, data: Data) async throws {
    writes.append(data); try await outputs[id]?(.output(data))
    if unknownWrite { throw CodexBridgeError.acceptanceUnknown }
  }
  func resizeProcess(id: UUID, columns: Int, rows: Int) { }
  func stopProcess(id: UUID) async throws { stops += 1; try await outputs.removeValue(forKey: id)?(.exited(-15)) }
  func readProject(id: String) -> CodexProject { .init(id: id, name: "Demo", roots: ["/tmp/demo"]) }
  func updateProject(_ edit: CodexProjectEdit) throws -> CodexProject { throw CodexBridgeError.invalidInput }
  func models() -> [CodexModelOption] { [.init(id: "fixture", name: "Fixture", efforts: ["low", "high"], defaultEffort: "low")] }
  func resources(threadID: String, kind: CodexResourceKind, cursor: String?) -> CodexResourcePage { .init(resources: []) }
  func projects(cursor: String?) -> CodexProjectPage { .init(projects: [], nextCursor: nil) }
  func tasks(cursor: String?, project: CodexProject?) -> CodexTaskPage { .init(tasks: [], nextCursor: nil) }
  func history(threadID: String, cursor: String?) -> CodexHistoryPage { .init(messages: [], nextCursor: nil) }
  func create(directory: URL, title: String, workspaceID: UUID, project: CodexProject?) throws -> CodexTask { throw CodexBridgeError.invalidInput }
}

@MainActor final class NotebookProjectRunsTests: XCTestCase {
  private func fixture(_ body: (NotebookStore, NotebookPersistenceQueue, RunOwner, NotebookFileAddress, UUID) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory), author = UUID(), queue = NotebookPersistenceQueue(store: store)
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    try await body(store, queue, RunOwner(), .init(computer: UUID(), project: "demo", root: "/tmp/demo", path: ""), author)
    let done = await queue.flush(); XCTAssertTrue(done)
  }
  func testReplayLostInputAcknowledgementAndMacRestartNeverExecuteTwice() async throws {
    try await fixture { store, queue, native, root, author in
      let service = MacNotebookProjectRuns(persistence: queue, executor: native, metadata: native, computer: root.computer)
      let start = NotebookChatInput(author: author, action: .startRun(.init(root: root, command: "read answer")))
      let accepted = try await service.receive(start); XCTAssertEqual(accepted.result, .run(start.id))
      _ = try await service.receive(start)
      let page = try await service.read(.init(root: root)); XCTAssertEqual(String(decoding: page.data, as: UTF8.self), "ready\r\n")
      await native.setUnknownWrite()
      let input = NotebookChatInput(author: author, action: .writeRun(start.id, Data("hello\r".utf8)))
      let receipt = try await service.receive(input); XCTAssertEqual(receipt.state, .uncertain)
      _ = try await service.receive(input)
      let cold = MacNotebookProjectRuns(persistence: queue, executor: native, metadata: native, computer: root.computer)
      let recovered = try await cold.read(.init(root: root)); XCTAssertEqual(recovered.record?.phase, .interrupted)
      _ = try await cold.receive(start); _ = try await cold.receive(input)
      let counts = await native.counts(); XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
      XCTAssertEqual(try store.runRecord(start.id)?.phase, .interrupted)
    }
  }
  func testRestartWaitsForPreviousExitAndIdenticalPathsOnOtherMacAreRejected() async throws {
    try await fixture { store, queue, native, root, author in
      let service = MacNotebookProjectRuns(persistence: queue, executor: native, metadata: native, computer: root.computer)
      let start = NotebookChatInput(author: author, action: .startRun(.init(root: root, command: "read answer")))
      _ = try await service.receive(start)
      let restart = NotebookChatInput(author: author, action: .startRun(.init(root: root, command: "echo finished", replacing: start.id)))
      _ = try await service.receive(restart); _ = try await service.receive(restart)
      let counts = await native.counts(); XCTAssertEqual(counts.0, 2); XCTAssertEqual(counts.2, 1)
      XCTAssertEqual(try store.runRecord(start.id)?.phase, .exited)
      XCTAssertEqual(try store.activeRuns().map(\.id), [restart.id])
      let other = NotebookFileAddress(computer: UUID(), project: root.project, root: root.root, path: "")
      let rejected = try await service.receive(.init(author: author, action: .startRun(.init(root: other, command: "echo wrong"))))
      XCTAssertEqual(rejected.state, .rejected)
      let final = await native.counts(); XCTAssertEqual(final.0, 2)
    }
  }
}
