#if DEBUG
import NotebookCore
import SwiftUI

/// Explicit untethered acceptance: unplugging USB or leaving the LAN must not
/// kill an XCTest session. Uses the already mounted production model/owners,
/// with a private, admitted pair only. A saved start prevents automatic replay.
@MainActor enum NotebookPhysicalRemoteProof {
  static func runIfRequested(_ model: NotebookAppModel, phaseChanged: (String) -> Void) async {
    guard let mode = ProcessInfo.processInfo.environment["NOTEBOOK_RUN_REMOTE_PROOF"], ["1", "local"].contains(mode),
      let config = model.acceptance, config.role == .iPad else { return }
    let localOnly = mode == "local"
    #if targetEnvironment(simulator)
      guard localOnly else { phaseChanged("Physical device required"); return }
    #endif
    let progress = config.rootURL.deletingLastPathComponent().appendingPathComponent(localOnly ? "local-proof.json" : "progress.json")
    let fileName = localOnly ? "local-proof.txt" : "proof.txt"
    let documentTitle = localOnly ? "GUI-183 local proof" : "GUI-183 physical proof"
    guard !FileManager.default.fileExists(atPath: progress.path) else { return }
    var recordedThread: String?, recordedCommand: UUID?, recordedTurn: String?
    var observations: [[String: String]] = []
    func record(_ phase: String, thread: String? = nil, command: UUID? = nil) throws {
      if let thread { recordedThread = thread }; if let command { recordedCommand = command }
      let value = ["phase": phase, "thread": recordedThread ?? "", "command": recordedCommand?.uuidString ?? "", "turn": recordedTurn ?? "",
        "time": String(Date().timeIntervalSince1970),
        "route": model.pairedPeers.first.flatMap { model.deviceRouteTitle($0.deviceID) } ?? "disconnected"]
      observations.append(value)
      var receipt: [String: Any] = value; receipt["observations"] = observations
      try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: progress, options: .atomic)
      phaseChanged(phase)
      print("GUI183_PHYSICAL " + phase); fflush(stdout)
    }
    do {
      try record("waiting-for-LAN")
      try await wait(120) { model.chat?.connected == true }
      let chat = try unwrap(model.chat), peer = try unwrap(chat.computerID)
      try equal(model.deviceRouteTitle(peer), NearbySync.Route.direct.title)
      chat.expanded = true
      await chat.create()
      try await wait(60) { chat.threadID != nil }
      let thread = try unwrap(chat.threadID)
      recordedThread = thread
      await chat.setAccess(.workspace, thread: thread)
      try await wait(30) { chat.jobs.contains { if case .setAccess = $0.input.action { return $0.state == .accepted }; return false } }
      let sent = await chat.sendMessage(threadID: thread, text: """
        This is an isolated acceptance project and a fresh private Notebook workspace. Do not access any other project.
        Create \(fileName) containing exactly GUI-183 plus a newline. Run /usr/bin/python3 -c 'from pathlib import Path; assert Path("\(fileName)").read_text() == "GUI-183\\n"; print("GUI-183-CHECK-PASSED")'.
        Then use Notebook MCP notebook_execute to read nb.help('operation/createDocument'), read fresh nb.board({}) basis and create one document titled \(documentTitle) containing the actual check result. Finish with GUI-183-CHECK-PASSED.
        """, context: "")
      try require(sent)
      let input = try unwrap(chat.jobs.first(where: { if case .send = $0.input.action { return true }; return false })?.input)
      recordedCommand = input.id
      try await wait(180) { chat.conversation?.requests.isEmpty == false }
      let pending = try unwrap(chat.conversation?.requests.first)
      if !localOnly {
        try record("switch-to-relay-with-pending-approval", thread: thread, command: input.id)
        try await wait(300) { chat.connected && model.deviceRouteTitle(peer) == NearbySync.Route.relay.title }
        try equal(chat.threadID, thread)
        try await wait(30) { chat.conversation?.requests.contains { $0.id == pending.id } == true }
      }
      var answered = Set<String>()
      let deadline = ContinuousClock.now + .seconds(180)
      while .now < deadline {
        for request in chat.conversation?.requests ?? [] where !answered.contains(request.id) {
          let messages = ["notebook_context", "notebook_execute"].map { "Allow the notebook MCP server to run tool \"\($0)\"?" }
          guard request.isToolApproval, request.parameters["threadId"] == .string(thread),
            request.parameters["serverName"] == .string("notebook"),
            messages.contains(where: { request.parameters["message"] == .string($0) }) else {
            throw NotebookPersistenceQueue.Failure(message: "Unexpected permission; no automatic grant")
          }
          await chat.respond(request, decision: .allowOnce, threadID: thread)
          await chat.respond(request, decision: .allowOnce, threadID: thread)
          answered.insert(request.id)
        }
        if let turn = chat.conversation?.acceptedMessages[input.id.uuidString.lowercased()],
          chat.conversation?.turnStatuses[turn] == "completed" { break }
        try await Task.sleep(for: .milliseconds(300))
      }
      let turn = try unwrap(chat.conversation?.acceptedMessages[input.id.uuidString.lowercased()])
      recordedTurn = turn
      try equal(chat.conversation?.turnStatuses[turn], "completed")
      try await wait(30) { model.workspace?.items.contains { $0.kind == .document && $0.title == documentTitle } == true }
      let replay = try await chat.directQuery(.job(input))
      guard case .job(let job) = replay else { throw NotebookTransportError.invalidAcknowledgement }
      try equal(job.id, input.id); try equal(job.result, .turn(turn))
      if localOnly { try record("LAN-PASS", thread: thread, command: input.id); return }
      try record("relay-PASS-switch-to-nearby", thread: thread, command: input.id)
      try await wait(300) { chat.connected && model.deviceRouteTitle(peer) == NearbySync.Route.nearby.title }
      try equal(chat.threadID, thread)
      guard case .job(let nearby) = try await chat.directQuery(.job(input)) else { throw NotebookTransportError.invalidAcknowledgement }
      try equal(nearby.result, .turn(turn))
      try record("nearby-PASS-restore-LAN", thread: thread, command: input.id)
      try await wait(300) { chat.connected && model.deviceRouteTitle(peer) == NearbySync.Route.direct.title }
      try equal(chat.threadID, thread)
      guard case .job(let direct) = try await chat.directQuery(.job(input)) else { throw NotebookTransportError.invalidAcknowledgement }
      try equal(direct.result, .turn(turn))
      try record("PASS", thread: thread, command: input.id)
    } catch {
      try? record("FAILED: " + error.localizedDescription)
      // Failure neither resubmits an uncertain command nor stops accepted Mac work.
      return
    }
  }

  private static func wait(_ seconds: Double, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    guard condition() else { throw NotebookPersistenceQueue.Failure(message: "Physical pair condition timed out") }
  }
  private static func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NotebookPersistenceQueue.Failure(message: "Missing physical proof value") }; return value
  }
  private static func require(_ value: Bool) throws {
    guard value else { throw NotebookPersistenceQueue.Failure(message: "Physical proof condition failed") }
  }
  private static func equal<T: Equatable>(_ a: T, _ b: T) throws { try require(a == b) }

  static func title(_ phase: String) -> String {
    switch phase {
    case "waiting-for-LAN": "Проверка: ждём Mac в общей сети"
    case "switch-to-relay-with-pending-approval": "Проверка: перейдите в другую сеть, вне прямой связи с Mac"
    case "relay-PASS-switch-to-nearby": "Интернет ✓. Вернитесь к Mac; Wi-Fi включён, но без общей сети"
    case "nearby-PASS-restore-LAN": "Nearby ✓. Верните обычную Wi-Fi сеть"
    case "PASS": "Готово: одна задача через LAN → интернет → nearby → LAN"
    case "LAN-PASS": "Локальная сеть ✓: код, проверка и материал в одной задаче"
    default: phase
    }
  }
}
#endif
