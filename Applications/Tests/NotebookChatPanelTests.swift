import NotebookCore
import SwiftUI
import UIKit
import XCTest
@testable import Notebook

@MainActor
final class NotebookChatPanelTests: XCTestCase {
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

  private func panel(width: CGFloat, height: CGFloat, name: String, active: Bool = false, files: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-panel-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let author = UUID(), peer = UUID()
    _ = try model.store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: model.store)
    weak var receiver: NotebookChatController?
    let chat = NotebookChatController(persistence: queue, author: author) { envelope, destination in
      XCTAssertEqual(destination, peer)
      guard case .request(let query) = envelope.body else { return XCTFail("Expected a catalogue query") }
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
      guard case .catalogue = query else { return XCTFail("This view never starts or selects a task") }
      let tasks = ["Изучение высшей математики", "Сделай цветным", "Сделай цветным"].enumerated().map {
        CodexTask(id: "reference-chat-\($0.offset)", title: $0.element, cwd: "/fixture", projectID: "project")
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
    if files {
      chat.selectProject(chat.projects.first)
      var state = chat.files.window; state.sidebar = true
      await chat.files.installWindow(state, document: nil)
      await chat.files.roots()
      XCTAssertEqual(chat.files.directories.count, 1)
    }
    await chat.stop()

    let host = UIHostingController(rootView: NotebookChatPanel(chat: chat, size: .init(width: width, height: height),
      openPairing: {}, openHistory: {}, move: { _, _ in }, resize: { _, _ in }, endInteraction: {})
      .environment(model).padding(20).background(Color(.systemGroupedBackground)).preferredColorScheme(.light))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: width + 40, height: height + 40)
    window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.setNeedsLayout(); host.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.view.layoutIfNeeded()
    let inputs = descendants(host.view).filter { $0 is UITextView || $0 is UITextField }
    let input = try XCTUnwrap(inputs.first)
    XCTAssertFalse(inputs.contains(where: \.isFirstResponder), "Opening chat does not summon the keyboard or take Pencil focus")
    let frame = input.convert(input.bounds, to: host.view)
    XCTAssertTrue(host.view.bounds.contains(frame), "The composer cannot require scrolling the conversation to reach it")
    XCTAssertGreaterThan(frame.width, 120)
    XCTAssertGreaterThan(frame.minY, host.view.bounds.midY)
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
