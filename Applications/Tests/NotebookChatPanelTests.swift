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

  private func panel(width: CGFloat, height: CGFloat, name: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-panel-\(UUID())")
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let author = UUID(), peer = UUID()
    _ = try model.store.initializeWorkspace(actor: author, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: model.store)
    weak var receiver: NotebookChatController?
    let chat = NotebookChatController(persistence: queue, author: author) { envelope, destination in
      XCTAssertEqual(destination, peer)
      guard case .request(.catalogue) = envelope.body else { return XCTFail("This view only requests the catalogue") }
      let tasks = ["Изучение высшей математики", "Сделай цветным", "Сделай цветным"].enumerated().map {
        CodexTask(id: "reference-chat-\($0.offset)", title: $0.element, cwd: "/fixture")
      }
      receiver?.receive(.init(id: envelope.id, body: .reply(.catalogue(.init(tasks: tasks, nextCursor: nil)))), peerID: peer)
    }
    receiver = chat
    await chat.start(); chat.connect(peer); chat.expanded = true
    let deadline = ContinuousClock.now + .seconds(3)
    while chat.tasks.count != 3, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(chat.tasks.count, 3)
    await chat.stop()

    let host = UIHostingController(rootView: NotebookChatPanel(chat: chat, maximumWidth: width, maximumHeight: height)
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
