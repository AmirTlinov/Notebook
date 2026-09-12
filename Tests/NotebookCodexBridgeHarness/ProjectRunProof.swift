import Foundation
import NotebookCore
import NotebookCodex

extension Proof {
  static func exerciseRun(_ bridge: CodexAppServer, receipt: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-run-proof-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = NotebookStore(root: directory.appendingPathComponent("archive")), author = UUID()
    _ = try store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let root = NotebookFileAddress(computer: UUID(), project: "isolated-proof", root: directory.path, path: ""), id = UUID()
    let request = NotebookRunRequest(root: root, command: "printf '\\033[32mREADY\\033[0m\\n'; read answer; printf 'ANSWER:%s\\n' \"$answer\"; read finish; printf 'DONE\\n'", columns: 80, rows: 24)
    try store.admitRun(.init(id: id, author: author, request: request))
    try await bridge.startProcess(id: id, request: request) { try store.receiveRunEvent(id, $0) }
    func until(_ text: String) async throws -> String {
      let deadline = ContinuousClock.now + .seconds(20)
      while .now < deadline {
        let page = try store.readRun(.init(root: root)), value = String(decoding: page.data, as: UTF8.self)
        if value.contains(text) { return value }
        if page.record?.isActive != true { throw CodexBridgeError.invalidResponse }
        try await Task.sleep(for: .milliseconds(50))
      }
      throw CodexBridgeError.timeout
    }
    do {
      _ = try await until("READY")
      try await bridge.resizeProcess(id: id, columns: 100, rows: 30)
      try await bridge.writeProcess(id: id, data: Data("Привет😀\r".utf8))
      _ = try await until("ANSWER:Привет😀")
      try await Task.sleep(for: .seconds(13)) // Longer than the ordinary RPC timeout.
      guard try store.runRecord(id)?.isActive == true else { throw CodexBridgeError.invalidResponse }
      let cold = NotebookStore(root: store.root)
      guard try cold.latestRun(root: root)?.id == id else { throw CodexBridgeError.invalidResponse }
      try await bridge.writeProcess(id: id, data: Data("\r".utf8))
      _ = try await until("DONE")
      let deadline = ContinuousClock.now + .seconds(5)
      while try store.runRecord(id)?.isActive == true, .now < deadline { try await Task.sleep(for: .milliseconds(30)) }
      guard try store.runRecord(id)?.exitCode == 0 else { throw CodexBridgeError.invalidResponse }
      let stopped = UUID(), second = NotebookRunRequest(root: root, command: "printf 'STOP_READY\\n'; sleep 60")
      try store.admitRun(.init(id: stopped, author: author, request: second))
      try await bridge.startProcess(id: stopped, request: second) { try store.receiveRunEvent(stopped, $0) }
      _ = try await until("STOP_READY"); try await bridge.stopProcess(id: stopped)
      guard try store.runRecord(stopped)?.isActive == false else { throw CodexBridgeError.invalidResponse }
      try write(["run": id.uuidString, "stopped": stopped.uuidString, "utf8PTY": "passed", "beyondRPCDeadline": "passed", "coldReadSameRun": "passed", "exitAndStop": "passed"], to: receipt)
      await bridge.close()
    } catch { await bridge.close(); throw error }
  }
}
