import XCTest
import SwiftUI
import NotebookCore
import NotebookCodex
@testable import Notebook

/// Explicit, isolated live acceptance. This never changes installed Notebook
/// data or global MCP configuration; it creates one clearly named native task.
@MainActor final class NotebookCodexStandaloneTests: XCTestCase {
  func testLocalMacPresentationUsesHostJournalForRealCodeCheckAndNotebookMaterial() async throws {
    guard ProcessInfo.processInfo.environment["NOTEBOOK_TEST_NATIVE_CODEX"] == "1" else { throw XCTSkip("Explicit live Codex acceptance required") }
    let run = UUID(), actor = UUID()
    let root = URL(fileURLWithPath: "/tmp/nb183/" + run.uuidString.lowercased())
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = NotebookStore(root: root.appendingPathComponent("workspace"))
    let header = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let config = NotebookAcceptanceConfiguration(version: 1, runID: run, workspaceID: header.workspaceID, actorID: actor,
      role: .mac, bundleID: "com.amirtlinov.notebook.mac.acceptance", sourceRevision: String(repeating: "0", count: 40),
      root: root.path, socket: root.appendingPathComponent("ipc.sock").path, codexDirectory: project.path)
    let preferences = try XCTUnwrap(UserDefaults(suiteName: config.defaultsSuite))
    preferences.set(actor.uuidString, forKey: "notebook.actor-id")
    let model = NotebookAppModel(store: store, startsNearbySync: false, commandSocketURL: URL(fileURLWithPath: config.socket!),
      preferences: preferences, acceptance: config)
    await model.start(pageSize: .init(width: 834, height: 1194))
    let chat = NotebookMacCodexPresentation(model: model)
    let presentation = Task { await chat.run() }
    do {
      if case .account(let state) = try await model.localCodexQuery(.account(.read)), state.account == nil {
        throw XCTSkip("Existing official account required; this test never logs the user in or out")
      }
      await chat.submit(.create(title: "GUI-183 isolated Mac presentation proof"))
      try await wait(seconds: 30) { chat.threadID != nil }
      let thread = try XCTUnwrap(chat.threadID)
      await chat.submit(.setAccess(threadID: thread, mode: .workspace))
      let setting = try XCTUnwrap(chat.jobs.first?.id)
      try await wait(seconds: 20) { chat.jobs.first(where: { $0.id == setting })?.isTerminal == true }
      XCTAssertEqual(chat.jobs.first(where: { $0.id == setting })?.state, .accepted)
      let text = """
      This is an isolated acceptance project and an isolated empty Notebook workspace. Do not access any other project.
      Create proof.txt containing exactly GUI-183 plus a newline in the current directory.
      Run /usr/bin/python3 -c 'from pathlib import Path; assert Path("proof.txt").read_text() == "GUI-183\\n"; print("GUI-183-CHECK-PASSED")'.
      Then use the Notebook MCP notebook_execute tool to create a document titled GUI-183 remote proof containing the actual check result.
      Read nb.help('operation/createDocument') and use the returned public API example with fresh nb.board({}) basis.
      Do not create any other material. Finish with the actual check result and document title.
      """
      chat.draft = text
      await chat.submit(.send(threadID: thread, text: text, context: ""))
      let submission = try XCTUnwrap(chat.jobs.first?.input)
      XCTAssertEqual(chat.draft, "")
      let deadline = ContinuousClock.now + .seconds(150)
      var state: CodexConversation?
      var answered = Set<String>()
      while .now < deadline {
        if case .conversation(let value) = try await model.localCodexQuery(.conversation(threadID: thread)) {
          state = value
          for request in value.requests where !answered.contains(request.id) {
            let data = try JSONEncoder().encode(request)
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "native-notebook-approval"; attachment.lifetime = .keepAlways; add(attachment)
            // Only the two public tools of this isolated socket are authorized.
            // No file/shell/network/global grants, and no remembered permission.
            let messages = ["notebook_context", "notebook_execute"].map { "Allow the notebook MCP server to run tool \"\($0)\"?" }
            guard request.isToolApproval, request.parameters["threadId"] == .string(thread),
              request.parameters["serverName"] == .string("notebook"),
              messages.contains(where: { request.parameters["message"] == .string($0) }) else { throw CodexBridgeError.unsupportedRequest }
            let action = NotebookChatAction.respond(threadID: thread, request: request, decision: .allowOnce)
            let input = NotebookChatInput(id: try XCTUnwrap(action.controlID(author: actor)), author: actor, action: action)
            let first = try await model.localCodexQuery(.job(input))
            let replay = try await model.localCodexQuery(.job(input))
            guard case .job(let a) = first, case .job(let b) = replay else { throw CodexBridgeError.invalidResponse }
            XCTAssertEqual(a.id, b.id); answered.insert(request.id)
          }
          if let turn = value.acceptedMessages[submission.id.uuidString.lowercased()], value.turnStatuses[turn] == "completed" { break }
        }
        try await Task.sleep(for: .milliseconds(300))
      }
      let final = try XCTUnwrap(state), turn = try XCTUnwrap(final.acceptedMessages[submission.id.uuidString.lowercased()])
      XCTAssertEqual(final.turnStatuses[turn], "completed")
      XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("proof.txt"), encoding: .utf8), "GUI-183\n")
      let material = try XCTUnwrap(try store.loadIndex().items.first { $0.kind == .document && $0.title == "GUI-183 remote proof" })
      // Same journal identity is shared by the local window and remote sidecar.
      let duplicate = try await model.localCodexQuery(.job(submission))
      guard case .job(let job) = duplicate else { throw CodexBridgeError.invalidResponse }
      XCTAssertEqual(job.id, submission.id)
      XCTAssertEqual(job.result, .turn(turn))
      let evidence = XCTAttachment(string: "thread=\(thread)\nturn=\(turn)\ncommand=\(submission.id)\ndocument=\(material.id)\nproject=\(project.path)\n")
      evidence.name = "gui183-local-native-proof"; evidence.lifetime = .keepAlways; add(evidence)
      let view = NSHostingView(rootView: NotebookMacCodexView(model: model))
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = view; window.orderBack(nil)
      defer { window.orderOut(nil) }
      try await Task.sleep(for: .seconds(2))
      view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let visual = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: view.bounds.size))
      visual.name = "gui183-mac-task-window"; visual.lifetime = .keepAlways; add(visual)
      presentation.cancel(); await presentation.value
      _ = await model.shutdown(); await model.codexHost?.shutdown()
      preferences.removePersistentDomain(forName: config.defaultsSuite)
      // Retain only this opt-in run's isolated artifacts for inspectable evidence.
    } catch {
      presentation.cancel(); await presentation.value
      _ = await model.shutdown(); await model.codexHost?.shutdown()
      preferences.removePersistentDomain(forName: config.defaultsSuite)
      throw error
    }
  }

  private func wait(seconds: Int, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition(), .now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    guard condition() else { throw CodexBridgeError.timeout }
  }
}
