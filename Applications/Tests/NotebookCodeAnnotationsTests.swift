import XCTest
import SwiftUI
import NotebookCore
@testable import Notebook

@MainActor
final class NotebookCodeAnnotationsTests: XCTestCase {
  func testDirectoryContinuationDoesNotSkipNotesAfterAnOptimisticContact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID()
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let file = NotebookFileAddress(computer: UUID(), project: "demo", root: "/code", path: "hello.py")
    for i in 0..<65 {
      let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!
      try store.captureCodeFragment(.init(id: id, file: file, sourceHash: NotebookFileVersion.hash(Data("code".utf8)),
        utf16Offset: 0, text: "code", width: 600, height: 500, fontSize: 15, stamp: .init(counter: 1, actor: actor)))
    }
    let notes = NotebookCodeAnnotations(persistence: .init(store: store), author: actor)
    await notes.select(file); XCTAssertEqual(notes.fragments.count, 64)
    let fragment = try XCTUnwrap(notes.reserve(file: file, source: "new", offset: 0, text: "new", width: 600, height: 500, fontSize: 15))
    notes.accept(.init(id: UUID(), tool: .pen, samples: [.init(point: .init(x: 10, y: 20), timeOffset: 0, width: 2, opacity: 1, force: 1, azimuth: 0, altitude: 1)]), fragment: fragment, originY: 0)
    let saved = await notes.flush(); XCTAssertTrue(saved)
    await notes.refresh(); await notes.refresh(more: true)
    XCTAssertEqual(notes.fragments.count, 66)
    XCTAssertFalse(notes.hasMore)
  }
  func testAcceptedContactSurvivesFileSwitchAndOwnUndoKeepsAgentInk() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-notes-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NotebookStore(root: root), actor = UUID(), source = "answer = 2 + 2\nprint(answer)\n"
    _ = try store.initializeWorkspace(actor: actor, pageSize: .init(width: 834, height: 1194))
    let queue = NotebookPersistenceQueue(store: store), notes = NotebookCodeAnnotations(persistence: queue, author: actor)
    let file = NotebookFileAddress(computer: UUID(), project: "demo", root: "/code", path: "hello.py")
    await notes.select(file)
    let fragment = try XCTUnwrap(notes.reserve(file: file, source: source, offset: 0, text: source, width: 600, height: 500, fontSize: 15))
    let id = UUID()
    let measured = PageInkAction(id: id, tool: .pen, samples: [.init(point: .init(x: 30, y: 40), timeOffset: 0, width: 3, opacity: 1, force: 1, azimuth: 0, altitude: 1)])
    notes.accept(measured, fragment: fragment, originY: 100)
    XCTAssertFalse(notes.contactActive)
    let flushed = await notes.flush(); XCTAssertTrue(flushed)
    let first = try XCTUnwrap(store.codeAnnotation(fragment.id))
    XCTAssertEqual(first.ink.actions[0].spans[0].samples[0].point.y, 140)
    let agentID = UUID(), target = CollaborationTarget(kind: .codeFragment, id: fragment.id)
    _ = try store.applyCollaborationAction(.init(summary: "Пометка агента", expected: [.init(target: target,
      revision: fragment.stamp.revision, inkRevision: first.ink.stamp.revision)], operations: [
      .init(kind: .appendInkStroke, target: target, id: agentID.uuidString, values: ["points": .array([.object(["x": .number(80), "y": .number(140)])])])
    ]), actor: UUID())
    notes.show([fragment.id]); await notes.refresh()
    notes.undo(); let undone = await notes.flush(); XCTAssertTrue(undone)
    let result = try XCTUnwrap(store.codeAnnotation(fragment.id))
    XCTAssertFalse(try XCTUnwrap(result.ink.actions.first { $0.id == id }).isActive)
    XCTAssertTrue(try XCTUnwrap(result.ink.actions.first { $0.id == agentID }).isActive)
    let restored = NotebookCodeAnnotations(persistence: queue, author: actor)
    await restored.select(file)
    XCTAssertEqual(restored.fragments, [fragment])
    await restored.select(file.child("other")); XCTAssertTrue(restored.fragments.isEmpty)
    XCTAssertEqual(try store.codeFragment(fragment.id), fragment)
  }

  func testMountedCodePencilFreezesMaterialAndWidthChangeKeepsOriginalReview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-pencil-" + UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let host = UIHostingController(rootView: NotebookRootView().environment(model))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194); window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await model.start(pageSize: .init(width: 834, height: 1194))
    let files = try XCTUnwrap(model.chat?.files)
    let file = NotebookFileAddress(computer: UUID(), project: "demo", root: "/demo", path: "hello.py")
    let source = (0..<120).map { "result\($0) = \($0) + 2" }.joined(separator: "\n")
    try model.store.saveFileDraft(.init(address: file, text: source))
    let camera = model.presence
    await files.open(file); try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
    let text = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NotebookCodeTextView }.first)
    let ink = try XCTUnwrap(text.ink)
    XCTAssertEqual(ink.overlay.frame.size, text.bounds.size)
    XCTAssertTrue(ink.overlay.paper.touchView.onActionWillBegin?() == true)
    XCTAssertTrue(model.inputGate.hasActivePencil && files.notes.contactActive)
    files.edit("wrong", address: file, selection: 0, scroll: 0)
    XCTAssertEqual(files.document?.text, source)
    let id = UUID()
    ink.overlay.paper.touchView.onDrawingMutation?(.init(id: id, tool: .pen, samples: [
      .init(point: .init(x: 350, y: 100), timeOffset: 0, width: 10, opacity: 1, force: 1, azimuth: 0, altitude: 1),
      .init(point: .init(x: 480, y: 100), timeOffset: 0.1, width: 10, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ]))
    XCTAssertFalse(model.inputGate.hasActivePencil)
    let saved = await model.finishPendingPersistence(); XCTAssertTrue(saved)
    let fragment = try XCTUnwrap(files.notes.fragments.first)
    XCTAssertEqual(fragment.range(in: source)?.location, 0)
    text.setContentOffset(.init(x: 0, y: 100), animated: false); text.layoutIfNeeded()
    XCTAssertEqual(ink.overlay.frame.origin.y, 100)
    XCTAssertEqual(model.presence, camera)
    XCTAssertEqual(try model.store.codeAnnotation(fragment.id)?.ink.actions.first?.id, id)
    files.edit("# prefix\n" + source, address: file, selection: 0, scroll: 100)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(fragment.range(in: files.document!.text)?.location, 9)
    let oldWidth = fragment.width
    text.frame.size.width = 500; text.setNeedsLayout(); text.layoutIfNeeded()
    XCTAssertEqual(files.notes.fragments.first?.width, oldWidth)
    XCTAssertEqual(files.notes.fragments.first?.text, fragment.text)
    XCTAssertEqual(model.presence, camera)
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
    let attachment = XCTAttachment(image: image); attachment.name = "code-review-keeps-original-material"; attachment.lifetime = .keepAlways; add(attachment)
    files.close(); try await Task.sleep(for: .milliseconds(80)); XCTAssertEqual(model.presence, camera)
  }
  private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
