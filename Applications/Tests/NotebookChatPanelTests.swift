import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookChatPanelTests: XCTestCase {
  func testNativeWorkShimmersOnceAndDisclosureSurvivesResizeWithoutReplayingItems() async throws {
    let coordinator = NotebookChatTranscript.Coordinator()
    let container = UIView(frame: .init(x: 0, y: 0, width: 540, height: 560))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(container); window.isHidden = false
    coordinator.mount(container)
    defer { coordinator.close(); window.isHidden = true; window.rootViewController = nil }
    let messages: [CodexMessage] = [
      .init(id: "human", turnID: "turn", clientID: nil, role: .user, text: "Проверь рисунок"),
      .init(id: "progress", turnID: "turn", clientID: nil, role: .assistant, text: "Проверяю рисунок на доске", phase: "commentary"),
      .init(id: "tool", turnID: "turn", clientID: nil, role: .assistant, text: "Читаю доску", activity: .init(kind: .tool, status: "inProgress", detail: "notebook_read_board"))]
    func conversation(busy: Bool) -> CodexConversation {
      .init(threadID: "task", revision: 1, title: "Рисунок", ready: true, busy: busy, activeTurnID: busy ? "turn" : nil,
        messages: messages, requests: [], acceptedMessages: [:], turnStatuses: [:])
    }
    let work = NotebookChatWorkStatus(conversation: conversation(busy: true), connected: true)
    coordinator.update(messages: messages, work: work, conversationID: "task")
    let deadline = ContinuousClock.now + .seconds(8)
    var rendered = false
    while !rendered, .now < deadline {
      if let web = coordinator.web { rendered = (try? await web.evaluateJavaScript("document.querySelectorAll('article').length===3")) as? Bool == true }
      if !rendered { try await Task.sleep(for: .milliseconds(30)) }
    }
    XCTAssertTrue(rendered, "The native transcript did not render")
    let web = try XCTUnwrap(coordinator.web)
    let status = try await web.evaluateJavaScript("document.querySelectorAll('.work').length===1 && document.querySelector('.work-label').textContent==='Проверяю рисунок на доске' && document.querySelectorAll('[data-running=true]').length===1") as? Bool
    XCTAssertEqual(status, true)
    _ = try await web.evaluateJavaScript("document.querySelector('.work').open=true;window.kept=document.querySelector('[data-item-id=tool]');true")
    container.frame.size.width = 340; container.layoutIfNeeded()
    coordinator.update(messages: messages, work: work, conversationID: "task")
    let retained = try await web.evaluateJavaScript("kept===document.querySelector('[data-item-id=tool]') && document.querySelectorAll('[data-item-id=tool]').length===1 && document.querySelector('.work').open") as? Bool
    XCTAssertEqual(retained, true, "Geometry must not republish, collapse details or duplicate a native item")
    let proof = XCTAttachment(image: UIGraphicsImageRenderer(bounds: container.bounds).image { _ in container.drawHierarchy(in: container.bounds, afterScreenUpdates: true) })
    proof.name = "companion-chat-pearlescent-work"; proof.lifetime = .keepAlways; add(proof)
    coordinator.update(messages: messages, work: .init(conversation: conversation(busy: false), connected: true), conversationID: "task")
    try await Task.sleep(for: .milliseconds(100))
    let finished = try await web.evaluateJavaScript("document.querySelectorAll('[data-running=true]').length===0 && document.querySelectorAll('article').length===3 && document.querySelector('.work').open") as? Bool
    XCTAssertEqual(finished, true, "Completion retires the shimmer without rewriting the conversation")
  }

  func testRecentChatsAndFixedComposerMatchReferenceWithoutTakingFocus() async throws {
    try await panel(width: 560, height: 640, name: "chat-reference-recents")
  }

  func testNarrowShortPanelKeepsComposerInsideItsOwnBounds() async throws {
    try await panel(width: 320, height: 210, name: "chat-reference-compact")
  }

  func testActiveProjectsShowNativeWorkWithoutCreatingAConversation() async throws {
    try await panel(width: 560, height: 640, name: "chat-active-projects", active: true)
  }

  func testFilesShareThePanelOnTheRightWithAReadableComposer() async throws {
    try await panel(width: 560, height: 640, name: "chat-files-right", files: true)
    try await panel(width: 420, height: 360, name: "chat-files-right-compact", files: true)
  }

  func testNativeApprovalKeepsItsChoicesAndAccessLevelBesideTheConversation() async throws {
    try await panel(width: 560, height: 760, name: "chat-tool-approval", approval: true)
    try await panel(width: 420, height: 600, name: "chat-tool-approval-compact", approval: true)
    try await panel(width: 560, height: 640, name: "chat-tool-approval-files", files: true, approval: true)
  }

  private func panel(width: CGFloat, height: CGFloat, name: String, active: Bool = false, files: Bool = false, approval: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-panel-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let author = UUID(), peer = UUID()
    let taskIDs = (0..<3).map { _ in UUID().uuidString.lowercased() }
    let messages: [CodexMessage] = [
      .init(id: "human", turnID: "turn", clientID: nil, role: .user, text: "Посмотри рисунок на доске и помоги разобраться с формулой."),
      .init(id: "answer", turnID: "turn", clientID: nil, role: .assistant, text: "Открою рисунок, чтобы обсудить именно ваш пример."),
      .init(id: "tool", turnID: "turn", clientID: nil, role: .assistant, text: "Чтение доски", activity: .init(kind: .tool, status: "inProgress", detail: "notebook_read_board"))]
    _ = try model.store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: model.store)
    weak var receiver: NotebookChatController?
    let chat = NotebookChatController(persistence: queue, author: author) { envelope, destination in
      XCTAssertEqual(destination, peer)
      guard case .request(let query) = envelope.body else { return XCTFail("Expected a catalogue query") }
      if case .run = query {
        receiver?.receive(.init(id: envelope.id, body: .reply(.run(.init(record: nil)))), peerID: peer); return
      }
      if case .models = query {
        receiver?.receive(.init(id: envelope.id, body: .reply(.models([.init(id: "fixture", name: "Fixture", efforts: ["low", "high"], defaultEffort: "low")]))), peerID: peer); return
      }
      if case .projects = query {
        receiver?.receive(.init(id: envelope.id, body: .reply(.projects(.init(projects: [.init(id: "project", name: "Notebook", roots: ["/fixture"])], nextCursor: nil)))), peerID: peer); return
      }
      if case .activity(let ids) = query {
        receiver?.receive(.init(id: envelope.id, body: .reply(.activity(ids.map { .init(id: $0, status: active ? .running : .idle, summary: active ? "Проверяю сохранение и работу чата на iPad" : nil) }))), peerID: peer); return
      }
      if case .file(.directory) = query {
        receiver?.receive(.init(id: envelope.id, body: .reply(.file(.directory(.init(entries: [
          .init(name: "Sources", kind: .directory), .init(name: "Package.swift", kind: .file),
          .init(name: "README.md", kind: .file)], next: nil))))), peerID: peer); return
      }
      if case .history = query {
        receiver?.receive(.init(id: envelope.id, body: .reply(.history(.init(messages: messages, nextCursor: nil)))), peerID: peer); return
      }
      if case .conversation(let thread) = query {
        let request = CodexUserRequest(nativeID: .number(4), method: "mcpServer/elicitation/request", turnID: "turn", parameters: .object([
          "mode": .string("form"), "serverName": .string("notebook"),
          "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
          "_meta": .object(["codex_approval_kind": .string("mcp_tool_call"), "tool_title": .string("Прочитать выбранный участок доски"), "persist": .array([.string("session"), .string("always")])])]))
        let value = CodexConversation(threadID: thread, revision: 1, title: "Обсуждение рисунка", ready: true, busy: true, activeTurnID: "turn", messages: messages, requests: [request], acceptedMessages: [:], turnStatuses: [:],
          access: .init(profileID: CodexAccessMode.workspace.rawValue, approvalPolicy: .string("on-request"), available: CodexAccessMode.allCases), model: .init(model: "fixture", effort: "high"), contextUsage: .init(used: 193000, window: 258000))
        receiver?.receive(.init(id: envelope.id, body: .reply(.conversation(value))), peerID: peer); return
      }
      guard case .catalogue = query else { return XCTFail("This view never starts or selects a task: \(query)") }
      let tasks = ["Изучение высшей математики", "Сделай цветным", "Сделай цветным"].enumerated().map {
        CodexTask(id: taskIDs[$0.offset], title: $0.element, cwd: "/fixture", projectID: "project")
      }
      receiver?.receive(.init(id: envelope.id, body: .reply(.catalogue(.init(tasks: tasks, nextCursor: nil)))), peerID: peer)
    }
    receiver = chat
    await chat.start(); await chat.connect(peer); chat.expanded = true
    let deadline = ContinuousClock.now + .seconds(3)
    while (chat.tasks.count != 3 || chat.activities.count != 3 || chat.projects.count != 1), .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(chat.tasks.count, 3)
    XCTAssertEqual(chat.activities.count, 3)
    XCTAssertEqual(chat.projects.count, 1)
    let selectedTask = try XCTUnwrap(chat.tasks.first)
    if active {
      chat.browse(.projects); chat.toggleProject(chat.projects[0])
      let deadline = ContinuousClock.now + .seconds(3)
      while chat.catalogues[.project("project")]?.loaded != true, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertEqual(chat.catalogues[.project("project")]?.tasks.count, 3)
    }
    if files {
      chat.selectProject(chat.projects.first)
      var state = chat.files.window; state.sidebar = true
      await chat.files.installWindow(state, document: nil)
      await chat.files.roots()
      XCTAssertEqual(chat.files.directories.count, 1)
    }
    if approval {
      chat.select(selectedTask)
      let deadline = ContinuousClock.now + .seconds(3)
      while chat.conversation == nil, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
      XCTAssertEqual(chat.conversation?.requests.first?.approvalDecisions, [.allowOnce, .allowSession, .allowAlways, .decline])
      XCTAssertEqual(chat.conversation?.access?.mode, .workspace)
    }
    await chat.stop()

    let host = UIHostingController(rootView: NotebookChatPanel(chat: chat, size: .init(width: width, height: height),
      openPairing: {}, openHistory: {}, move: { _, _ in }, resize: { _, _, _ in }, endInteraction: {})
      .environment(model).padding(20).background(Color(.systemGroupedBackground)).preferredColorScheme(.light))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: width + 40, height: height + 40)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.view.layoutIfNeeded()
    if approval {
      let deadline = ContinuousClock.now + .seconds(8)
      var visible = false
      while !visible, .now < deadline {
        if let web = descendants(host.view).compactMap({ $0 as? WKWebView }).first {
          visible = (try? await web.evaluateJavaScript("document.querySelectorAll('article').length === 3")) as? Bool == true
        }
        if !visible { try await Task.sleep(for: .milliseconds(50)) }
      }
      XCTAssertTrue(visible, "The actual mounted transcript must finish rendering before its screenshot")
      try await Task.sleep(for: .milliseconds(100))
    }
    let inputs = descendants(host.view).filter { $0 is UITextView || $0 is UITextField }
    let input = try XCTUnwrap(inputs.first)
    XCTAssertFalse(inputs.contains(where: \.isFirstResponder), "Opening chat does not summon the keyboard or take Pencil focus")
    let frame = input.convert(input.bounds, to: host.view)
    XCTAssertTrue(host.view.bounds.contains(frame), "The composer cannot require scrolling the conversation to reach it")
    XCTAssertGreaterThan(frame.width, 120)
    XCTAssertGreaterThan(frame.minY, 64, "The full-width editor stays below the header even in a short panel")
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
    }
    let proof = XCTAttachment(image: image); proof.name = name; proof.lifetime = .keepAlways; add(proof)
    let saved = await queue.flush(); XCTAssertTrue(saved)
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
