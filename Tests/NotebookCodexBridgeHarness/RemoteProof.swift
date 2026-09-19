import Foundation
import NotebookCore
import NotebookCodex

extension Proof {
  /// Human confirmation is required; credentials remain in this isolated official profile.
  static func exerciseLiveDeviceCode(installation: CodexRuntimeInstallation, entry: URL, receipt: String) async throws {
    guard let home = ProcessInfo.processInfo.environment["CODEX_HOME"], home.contains("gui-183/auth-") else { throw CodexBridgeError.unsafeEndpoint }
    let bridge = CodexAppServer(installation: installation)
    do {
      guard try await bridge.account(.read).account == nil else { throw CodexBridgeError.unsafeEndpoint }
      guard let login = try await bridge.account(.beginLogin(attempt: UUID())).login, login.isValid else { throw CodexBridgeError.invalidResponse }
      print("CONFIRM_DEVICE_LOGIN URL=\(login.verificationURL.absoluteString) CODE=\(login.userCode)")
      fflush(stdout)
      let deadline = ContinuousClock.now.advanced(by: .seconds(600))
      while ContinuousClock.now < deadline {
        let state = try await bridge.account(.read)
        if state.account != nil, !state.requiresSignIn {
          print("PASS: fresh official device-code login; limitsAvailable=\(state.limits != nil)")
          await bridge.close()
          try await exerciseStandalone(installation: installation, entry: entry, receipt: receipt)
          let signedIn = try await bridge.account(.read)
          let signedOut = try await bridge.account(.logout(revision: signedIn.revision))
          guard signedOut.account == nil, signedOut.requiresSignIn else { throw CodexBridgeError.invalidResponse }
          await bridge.close()
          try write(["result": "PASS", "verified": "fresh official device-code login, standalone real edit/check, isolated logout", "limitsAvailable": String(state.limits != nil)], to: receipt + ".auth.json")
          print("PASS: logout affected only the isolated test profile")
          return
        }
        if state.login == nil { throw CodexBridgeError.signInRequired }
        try await Task.sleep(for: .seconds(3))
      }
      _ = try await bridge.account(.cancelLogin(id: login.id))
      throw CodexBridgeError.timeout
    } catch { await bridge.close(); throw error }
  }

  static func exerciseDeviceCode(installation: CodexRuntimeInstallation) async throws {
    guard let home = ProcessInfo.processInfo.environment["CODEX_HOME"], home.contains("gui-183/auth-") else { throw CodexBridgeError.unsafeEndpoint }
    let bridge = CodexAppServer(installation: installation)
    do {
      let initial = try await bridge.account(.read)
      guard initial.account == nil, initial.requiresSignIn else { throw CodexBridgeError.unsafeEndpoint }
      let folder = URL(fileURLWithPath: home).appendingPathComponent("project")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let key = UUID()
      let project = try await bridge.createProject(name: "Standalone project", path: folder.path, idempotencyKey: key)
      let replayedProject = try await bridge.createProject(name: project.name, path: folder.path, idempotencyKey: key)
      guard replayedProject == project, try await bridge.projects().projects.contains(project) else { throw CodexBridgeError.invalidResponse }
      let attempt = UUID(), started = try await bridge.account(.beginLogin(attempt: attempt))
      guard let login = started.login, login.isValid else { throw CodexBridgeError.invalidResponse }
      let replay = try await bridge.account(.beginLogin(attempt: attempt))
      guard replay.login == login else { throw CodexBridgeError.invalidResponse }
      let cancelled = try await bridge.account(.cancelLogin(id: login.id))
      guard cancelled.login == nil, cancelled.account == nil else { throw CodexBridgeError.invalidResponse }
      await bridge.close()
      print("PASS: native project creation/idempotency and device-code start, same-attempt deduplication and cancel in an empty isolated official profile; no account tokens copied")
    } catch { await bridge.close(); throw error }
  }

  /// Explicit opt-in live proof. Only a fresh temporary project is writable;
  /// no existing conversation, account credential or global MCP config changes.
  static func exerciseStandalone(installation: CodexRuntimeInstallation, entry: URL, receipt: String) async throws {
    guard !FileManager.default.fileExists(atPath: receipt) else { throw CocoaError(.fileWriteFileExists) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nb183-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let scope = try CodexRuntimeScope(directory: root, toolsEntry: entry, socket: root.appendingPathComponent("bridge.sock"))
    let bridge = CodexAppServer(installation: installation, scope: scope)
    let account = try await bridge.account(.read)
    guard account.account != nil, !account.requiresSignIn else { throw CodexBridgeError.signInRequired }
    let task = try await bridge.create(directory: root, title: "GUI-183 isolated standalone proof", workspaceID: UUID())
    do {
      try await bridge.attach(threadID: task.id)
      _ = try await wait(bridge, threadID: task.id) { $0.ready }
      try await bridge.setAccess(threadID: task.id, mode: .workspace)
      let id = UUID()
      let turn = try await bridge.send(threadID: task.id, clientMessageID: id, text: """
        This is an isolated acceptance project. Create proof.txt containing exactly GUI-183 plus a newline in the current directory.
        Run /usr/bin/python3 -c 'from pathlib import Path; assert Path("proof.txt").read_text() == "GUI-183\\n"; print("GUI-183-CHECK-PASSED")'.
        Do not access any other project or use MCP. Report the actual check result briefly.
        """)
      let state = try await wait(bridge, threadID: task.id) { $0.turnStatuses[turn] == "completed" || !$0.requests.isEmpty }
      guard state.requests.isEmpty, state.turnStatuses[turn] == "completed",
        try String(contentsOf: root.appendingPathComponent("proof.txt"), encoding: .utf8) == "GUI-183\n" else { throw CodexBridgeError.invalidResponse }
      guard state.messages.contains(where: { $0.text.contains("GUI-183-CHECK-PASSED") || $0.activity?.detail?.contains("GUI-183-CHECK-PASSED") == true }) else { throw CodexBridgeError.invalidResponse }
      let duplicate = try await bridge.send(threadID: task.id, clientMessageID: id, text: "same receipt")
      guard duplicate == turn else { throw CodexBridgeError.invalidResponse }
      let foreign = CodexAppServer(installation: installation, scope: scope)
      do { try await foreign.attach(threadID: task.id); await foreign.close(); throw CodexBridgeError.invalidResponse }
      catch CodexBridgeError.externalOwnerUnavailable { await foreign.close() }
      await bridge.detach(threadID: task.id)
      guard await bridge.snapshot(threadID: task.id)?.ready == true else { throw CodexBridgeError.invalidResponse }
      await bridge.close()
      try await bridge.attach(threadID: task.id)
      let history = try await bridge.history(threadID: task.id)
      guard history.messages.filter({ $0.clientID == id.uuidString.lowercased() }).count == 1 else { throw CodexBridgeError.invalidResponse }
      await bridge.close()
      try write(["result": "PASS", "thread": task.id, "projectDirectory": root.path, "turn": turn,
        "binary": installation.binary.path, "node": installation.node.path,
        "verified": "real file edit, native shell check, same-message deduplication, foreign writer rejection, detach, history after runtime restart",
        "notVerified": "fresh interactive login, physical iPad, distinct WAN networks"], to: receipt)
      print("PASS: standalone runtime edited and checked the isolated project; same task survived restart")
    } catch { await bridge.close(); print("FAIL: isolated proof task \(task.id) in \(root.path), not replayed"); throw error }
  }
}
