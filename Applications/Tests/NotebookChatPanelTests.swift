import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookChatPanelTests: XCTestCase {
  func testTerminalTurnStatusOwnsTheHeadingAfterAToolHasCompleted() async throws {
    let coordinator = NotebookChatTranscript.Coordinator()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive })
    let previous = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
    window.frame = CGRect(x: 0, y: 0, width: 540, height: 560)
    window.rootViewController = root; window.makeKeyAndVisible(); window.layoutIfNeeded()
    coordinator.mount(root.view)
    defer { coordinator.close(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    let messages: [CodexMessage] = [
      .init(id: "comment", turnID: "turn", clientID: nil, role: .assistant,
        text: "Продолжаю наблюдение", phase: "commentary"),
      .init(id: "tool", turnID: "turn", clientID: nil, role: .assistant,
        text: "Публичная операция принята", activity: .init(kind: .tool, status: "completed", detail: "notebook_execute"))]
    func heading(_ title: String) async throws {
      let deadline = ContinuousClock.now + .seconds(8)
      while .now < deadline {
        if let web = coordinator.web,
          (try? await web.evaluateJavaScript("document.querySelector('.work-label')?.textContent")) as? String == title { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTFail("The actual transcript did not show \(title)")
    }
    coordinator.update(messages: messages, conversationID: "task")
    try await heading("Работа Codex · 1 действие")
    let web = try XCTUnwrap(coordinator.web)
    XCTAssertTrue(web.isOpaque)
    XCTAssertEqual(root.view.backgroundColor,UIColor(NotebookChrome.surface))
    XCTAssertEqual(web.backgroundColor,UIColor(NotebookChrome.surface))
    XCTAssertEqual(web.scrollView.backgroundColor,UIColor(NotebookChrome.surface))
    _ = try await web.evaluateJavaScript("document.querySelector('.work').open=true;true")
    // Messages and active-work state are identical. Only the native terminal
    // status changes; a completed tool must not mask the interrupted turn.
    coordinator.update(messages: messages, turnStatuses: ["turn": "interrupted", "older": "completed"], conversationID: "task")
    try await heading("Остановлено · 1 действие")
    let stopped = try await web.evaluateJavaScript("document.querySelector('.work').open && document.querySelectorAll('article').length===2 && document.querySelectorAll('[data-running=true]').length===0") as? Bool
    XCTAssertEqual(stopped, true)
    _ = try await web.evaluateJavaScript("window.kept=document.querySelector('[data-item-id=tool]');true")
    coordinator.update(messages: messages, turnStatuses: ["older": "completed", "turn": "interrupted"], conversationID: "task")
    try await Task.sleep(for: .milliseconds(100))
    let retained = try await web.evaluateJavaScript("window.kept===document.querySelector('[data-item-id=tool]')") as? Bool
    XCTAssertEqual(retained, true, "Dictionary order is not a new terminal state")
    try await attachInstalledWindow(window, web: web)
    coordinator.update(messages: messages, turnStatuses: ["turn": "failed"], conversationID: "task")
    try await heading("Есть ошибка · 1 действие")
    coordinator.update(messages: messages, turnStatuses: ["turn": "completed"], conversationID: "task")
    try await heading("Выполнено · 1 действие")
  }

  func testNativeWorkShimmersOnceAndDisclosureSurvivesResizeWithoutReplayingItems() async throws {
    let coordinator = NotebookChatTranscript.Coordinator()
    let container = UIView(frame: .init(x: 0, y: 0, width: 540, height: 560))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }, "The capture fixture needs the foreground app scene")
    let previousKeyWindow = scene.keyWindow
    let window = UIWindow(windowScene: scene), root = UIViewController()
    window.frame = container.frame
    root.view = container; window.rootViewController = root
    window.makeKeyAndVisible(); window.layoutIfNeeded(); container.layoutIfNeeded()
    coordinator.mount(container)
    defer {
      coordinator.close(); window.isHidden = true; window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    let messages: [CodexMessage] = [
      .init(id: "human", turnID: "turn", clientID: nil, role: .user, text: "Проверь рисунок"),
      .init(id: "progress", turnID: "turn", clientID: nil, role: .assistant, text: "Проверяю рисунок на доске", phase: "commentary"),
      .init(id: "tool", turnID: "turn", clientID: nil, role: .assistant, text: "Читаю доску", activity: .init(kind: .tool, status: "inProgress", detail: "notebook_read_board"))]
    func conversation(busy: Bool) -> CodexConversation {
      .init(threadID: "task", generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Рисунок", ready: true, busy: busy, activeTurnID: busy ? "turn" : nil,
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
    XCTAssertTrue(web.isOpaque)
    XCTAssertEqual(container.backgroundColor,UIColor(NotebookChrome.surface))
    XCTAssertEqual(web.backgroundColor,UIColor(NotebookChrome.surface))
    XCTAssertEqual(web.scrollView.backgroundColor,UIColor(NotebookChrome.surface))
    let status = try await web.evaluateJavaScript("document.querySelectorAll('.work').length===1 && document.querySelector('.work-label').textContent==='Проверяю рисунок на доске' && document.querySelectorAll('[data-running=true]').length===1") as? Bool
    XCTAssertEqual(status, true)
    _ = try await web.evaluateJavaScript("document.querySelector('.work').open=true;window.kept=document.querySelector('[data-item-id=tool]');true")
    window.frame.size.width = 340; window.setNeedsLayout(); window.layoutIfNeeded(); container.layoutIfNeeded()
    XCTAssertEqual(container.bounds.size, CGSize(width: 340, height: 560))
    coordinator.update(messages: messages, work: work, conversationID: "task")
    let retained = try await web.evaluateJavaScript("kept===document.querySelector('[data-item-id=tool]') && document.querySelectorAll('[data-item-id=tool]').length===1 && document.querySelector('.work').open") as? Bool
    XCTAssertEqual(retained, true, "Geometry must not republish, collapse details or duplicate a native item")
    try await attachInstalledWindow(window, web: web)
    coordinator.update(messages: messages, work: .init(conversation: conversation(busy: false), connected: true), conversationID: "task")
    try await Task.sleep(for: .milliseconds(100))
    let finished = try await web.evaluateJavaScript("document.querySelectorAll('[data-running=true]').length===0 && document.querySelectorAll('article').length===3 && document.querySelector('.work').open") as? Bool
    XCTAssertEqual(finished, true, "Completion retires the shimmer without rewriting the conversation")
  }

  private func attachInstalledWindow(_ window: UIWindow, web: WKWebView) async throws {
    XCTAssertTrue(window.isKeyWindow); XCTAssertFalse(window.isHidden)
    XCTAssertTrue(web.window === window); XCTAssertFalse(web.isHidden); XCTAssertGreaterThan(web.alpha, 0)
    let deadline = ContinuousClock.now + .seconds(8)
    let format = UIGraphicsImageRendererFormat(); format.preferredRange = .standard
    var captured: UIImage?, drawn = false, nonempty = false, attempts = 0
    repeat {
      window.setNeedsLayout(); window.layoutIfNeeded(); window.rootViewController?.view.layoutIfNeeded()
      let frame = web.convert(web.bounds, to: window)
      XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
      XCTAssertTrue(window.bounds.contains(frame), "Capture must contain the installed native transcript")
      attempts += 1
      let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
        drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      captured = image
      nonempty = Self.hasNonuniformVisiblePixels(image)
      if drawn && nonempty { break }
      if .now < deadline { try await Task.sleep(for: .milliseconds(30)) }
    } while .now < deadline
    let proof = XCTAttachment(image: try XCTUnwrap(captured))
    proof.name = "chat-transcript-installed-window-work"; proof.lifetime = .keepAlways; add(proof)
    let geometry = XCTAttachment(string: "window=\(window.frame) root=\(String(describing: window.rootViewController?.view.frame)) web=\(web.convert(web.bounds, to: window)) attempts=\(attempts) drawHierarchy=\(drawn) nonempty=\(nonempty)")
    geometry.name = "chat-transcript-window-capture-geometry"; geometry.lifetime = .keepAlways; add(geometry)
    XCTAssertTrue(drawn, "UIKit must complete the actual window hierarchy capture")
    XCTAssertTrue(nonempty, "A transparent or uniform plane is not transcript image evidence")
  }

  private static func hasNonuniformVisiblePixels(_ image: UIImage) -> Bool {
    guard let source = image.cgImage else { return false }
    let width = source.width, height = source.height
    guard width > 0, height > 0, width * height <= 16_000_000 else { return false }
    // Decode the captured bytes for inspection only. This buffer is never an
    // attachment or a replacement image; no background or pixels are added.
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
      let values = bytes.bindMemory(to: UInt8.self)
      var first: UInt32?, differs = false, visible = false
      for offset in stride(from: 0, to: values.count, by: 4) {
        let rgba = UInt32(values[offset]) << 24 | UInt32(values[offset + 1]) << 16
          | UInt32(values[offset + 2]) << 8 | UInt32(values[offset + 3])
        if let first { differs = differs || first != rgba } else { first = rgba }
        visible = visible || values[offset + 3] != 0
        if differs && visible { return true }
      }
      return false
    }
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
        let request = CodexUserRequest(nativeID: .number(4), generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, method: "mcpServer/elicitation/request", turnID: "turn", parameters: .object([
          "mode": .string("form"), "serverName": .string("notebook"),
          "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
          "_meta": .object(["codex_approval_kind": .string("mcp_tool_call"), "tool_title": .string("Прочитать выбранный участок доски"), "persist": .array([.string("session"), .string("always")])])]))
        let value = CodexConversation(threadID: thread, generation: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!, revision: 1, title: "Обсуждение рисунка", ready: true, busy: true, activeTurnID: "turn", messages: messages, requests: [request], acceptedMessages: [:], turnStatuses: [:],
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
      openDevices: {}, openHistory: {}, companion: .init(frame: .zero, controls: .zero, cards: .zero),
      onCompanionControlsSize: { _ in }, move: { _, _ in }, resize: { _, _, _ in }, endInteraction: {})
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
    XCTAssertGreaterThan(frame.width, width - 80, "Files never borrow the composer's width")
    if files {
      for _ in 0..<2 {
        chat.files.toggleSidebar()
        try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        XCTAssertTrue(descendants(host.view).contains(where: { $0 === input }), "The existing editor keeps its identity")
        let changed = input.convert(input.bounds, to: host.view)
        XCTAssertEqual(changed.minX, frame.minX, accuracy: 0.5)
        XCTAssertEqual(changed.minY, frame.minY, accuracy: 0.5)
        XCTAssertEqual(changed.width, frame.width, accuracy: 0.5)
        XCTAssertEqual(changed.height, frame.height, accuracy: 0.5)
      }
    }
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
