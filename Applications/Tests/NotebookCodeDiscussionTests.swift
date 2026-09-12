import XCTest
import SwiftUI
import WebKit
import NotebookCore
@testable import Notebook

@MainActor final class NotebookCodeDiscussionTests: XCTestCase {
  func testPrependingHistoryKeepsTheVisibleNativeItemAndAttachmentLabelsAreNotMarkup() async throws {
    let owner = NotebookChatTranscript.Coordinator(), container = UIView(frame: .init(x: 0, y: 0, width: 560, height: 320))
    func message(_ i: Int) -> CodexMessage { .init(id: "m\(i)", turnID: "turn", clientID: nil, role: .assistant,
      text: "Message \(i)\n\nA paragraph to read without losing this position.") }
    let latest = (20..<40).map(message)
    owner.update(messages: latest, conversationID: "first"); owner.mount(container)
    defer { owner.close() }
    let deadline = ContinuousClock.now + .seconds(5)
    while !owner.ready, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let web = try XCTUnwrap(owner.web)
    _ = try await web.callAsyncJavaScript("await window.showMessages(json, 'first')", arguments: ["json": owner.json], in: nil, contentWorld: .page)
    _ = try await web.evaluateJavaScript("scrollTo(0,document.querySelector('[data-item-id=\"m27\"]').offsetTop+12)")
    let before = try await web.evaluateJavaScript("document.querySelector('[data-item-id=\"m27\"]').getBoundingClientRect().top") as? Double
    let attachment = CodexMessage(id: "user-file", turnID: "next", clientID: nil, role: .user, text: "Добавь диктовку рядом с разговором.", attachments: ["code_image.png", "<script>bad()</script>.swift"])
    let updated = (0..<20).map(message) + latest + [attachment]
    owner.update(messages: updated, conversationID: "first")
    _ = try await web.callAsyncJavaScript("await window.showMessages(json, 'first')", arguments: ["json": owner.json], in: nil, contentWorld: .page)
    // Native publication and this awaited display coalesce through one renderer.
    try await Task.sleep(for: .milliseconds(100))
    let after = try await web.evaluateJavaScript("document.querySelector('[data-item-id=\"m27\"]').getBoundingClientRect().top") as? Double
    XCTAssertEqual(try XCTUnwrap(before), try XCTUnwrap(after), accuracy: 1)
    let labels = try await web.evaluateJavaScript("[...document.querySelectorAll('.attachment')].map(x=>x.textContent)") as? [String]
    XCTAssertEqual(labels, attachment.attachments)
    let scripts = try await web.evaluateJavaScript("document.querySelectorAll('article script').length") as? Int
    XCTAssertEqual(scripts, 0)
    _ = try await web.callAsyncJavaScript("await window.showMessages(json, 'second')", arguments: ["json": owner.json], in: nil, contentWorld: .page)
    let bottom = try await web.evaluateJavaScript("Math.abs(scrollY+innerHeight-document.documentElement.scrollHeight)<2") as? Bool
    XCTAssertEqual(bottom, true, "Choosing a different conversation starts at its newest message")
  }

  func testSelectedNativeCodeBecomesFrozenChatAttentionAndLinksOnlyScrollTheDocument() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = NotebookAppModel(store: .init(root: root), startsNearbySync: false)
    retainNotebookUntilTeardown(model, removing: root)
    let host = UIHostingController(rootView: NotebookRootView().environment(model))
    let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    window.frame = .init(x: 0, y: 0, width: 834, height: 1194); window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    await model.start(pageSize: .init(width: 834, height: 1194))
    let files = try XCTUnwrap(model.chat?.files)
    let file = NotebookFileAddress(computer: UUID(), project: "demo", root: "/project", path: "study.py")
    let source = (0..<240).map { "value\($0) = \($0) * 2" }.joined(separator: "\n")
    try model.store.saveFileDraft(.init(address: file, text: source))
    await files.open(file); try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
    let text = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NotebookCodeTextView }.first)
    text.selectedRange = (source as NSString).range(of: "value120 = 120 * 2")
    let fragment = try XCTUnwrap(files.captureSelection?())
    XCTAssertTrue(fragment.text.contains("value120")); XCTAssertFalse(fragment.text.contains("value0 ="))
    let before = model.presence
    await model.discussCode(fragment)?.value
    let question = try XCTUnwrap(model.agentQuestion), reference = try XCTUnwrap(question.references.first)
    let attention = try XCTUnwrap(model.store.attentionEvidence(contextID: question.contextID, referenceID: reference.id))
    XCTAssertEqual(attention.payload["code"]?["text"], .string(fragment.text))
    let image = try XCTUnwrap(attention.image)
    let shot = XCTAttachment(data: image.png, uniformTypeIdentifier: "public.png"); shot.name = "code-frozen-textkit-material"; shot.lifetime = .keepAlways; add(shot)
    let thread = UUID(), reply = CodexMessage(id: UUID().uuidString, turnID: UUID().uuidString, clientID: nil,
      role: .assistant, text: "Умножение на два удваивает значение.")
    model.saveChatExplanation(reply, thread: thread.uuidString, computer: file.computer)
    let persisted = await model.finishPendingPersistence(); XCTAssertTrue(persisted)
    let saved = try XCTUnwrap(model.store.sharedContexts().contexts.flatMap(\.entries).first { $0.text?.contains(reply.text) == true })
    XCTAssertTrue(saved.text?.contains(NotebookCodeLink.conversation(computer: file.computer, thread: thread).url.absoluteString) == true)
    XCTAssertTrue(saved.references.isEmpty, "An unrelated reply cannot silently acquire the current selected material")
    model.chat?.expanded = false
    model.openNotebookLink(NotebookCodeLink.file(file, line: 210).url)
    try await Task.sleep(for: .milliseconds(120)); host.view.layoutIfNeeded()
    XCTAssertGreaterThan(text.contentOffset.y, 500)
    model.openNotebookLink(NotebookCodeLink.fragment(fragment.id).url)
    try await Task.sleep(for: .milliseconds(150)); host.view.layoutIfNeeded()
    XCTAssertEqual(text.selectedRange.location, fragment.utf16Offset)
    XCTAssertEqual(model.presence, before)
    files.edit("changed completely", address: file, selection: 0, scroll: 0)
    model.openNotebookLink(NotebookCodeLink.fragment(fragment.id).url)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(files.notes.reviewed, fragment)
    XCTAssertEqual(model.presence, before)
    XCTAssertEqual(try model.store.attentionEvidence(contextID: question.contextID, referenceID: reference.id), attention)
    files.notes.reviewed = nil
  }

  func testPreservedCodeImageIncludesActualNativeInk() async throws {
    let actor = UUID(), file = NotebookFileAddress(computer: UUID(), project: "demo", root: "/code", path: "answer.py")
    let fragment = NotebookCodeFragment(file: file, sourceHash: String(repeating: "a", count: 64), utf16Offset: 0,
      text: "answer = 2 + 2\nprint(answer)\n", width: 600, height: 220, fontSize: 15, stamp: .init(counter: 1, actor: actor))
    let action = SpatialInkAction(tool: .pen, spans: [.init(surface: .codeFragment(fragment.id), samples: [
      .init(point: .init(x: 50, y: 100), timeOffset: 0, width: 8, opacity: 1, force: 1, azimuth: 0, altitude: 1),
      .init(point: .init(x: 330, y: 100), timeOffset: 0.2, width: 8, opacity: 1, force: 1, azimuth: 0, altitude: 1)
    ])], stamp: .init(counter: 2, actor: actor))
    let annotation = NotebookCodeAnnotation(fragment: fragment, ink: .init(actions: [action], stamp: action.stamp))
    let value = try await NotebookCodeImageRenderer.render(annotation, reference: annotation.reference())
    let shot = XCTAttachment(data: value.png, uniformTypeIdentifier: "public.png"); shot.name = "code-pinned-native-ink"; shot.lifetime = .keepAlways; add(shot)
    let blank = NotebookCodeAnnotation(fragment: fragment, ink: .init(stamp: fragment.stamp))
    let clean = try await NotebookCodeImageRenderer.render(blank, reference: blank.reference())
    XCTAssertNotEqual(value.sha256, clean.sha256)
  }

  func testLiveWebTranscriptOffersOnlyClickNavigationAndSavesTheActualMessage() async throws {
    let id = UUID(), link = NotebookCodeLink.fragment(id).url
    var navigated: URL?, saved: CodexMessage?
    let message = CodexMessage(id: "answer", turnID: UUID().uuidString, clientID: nil, role: .assistant,
      text: "[Рассмотренный код](\(link.absoluteString))\n\n<script>bad()</script>")
    let owner = NotebookChatTranscript.Coordinator()
    owner.openLink = { navigated = $0 }; owner.saveExplanation = { saved = $0 }
    let container = UIView(frame: .init(x: 0, y: 0, width: 560, height: 480))
    owner.update(messages: [message]); owner.mount(container)
    defer { owner.close() }
    let deadline = ContinuousClock.now + .seconds(4)
    while !owner.ready, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let web = try XCTUnwrap(owner.web)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(navigated); XCTAssertNil(saved)
    let href = try await web.evaluateJavaScript("document.querySelector('article a').getAttribute('href')") as? String
    XCTAssertEqual(href, link.absoluteString)
    let rawSaveControl = try await web.evaluateJavaScript("""
      (() => { const button = document.querySelector('.save-answer'), frame = button.getBoundingClientRect();
        return { text: button.textContent, label: button.getAttribute('aria-label'),
          icon: button.querySelectorAll('svg[aria-hidden="true"]').length,
          width: frame.width, height: frame.height }; })()
      """)
    let saveControl = try XCTUnwrap(rawSaveControl as? [String: Any])
    XCTAssertEqual(saveControl["text"] as? String, "", "The note action is an icon, not another line of text")
    XCTAssertEqual(saveControl["label"] as? String, "Сохранить ответ в заметках")
    XCTAssertEqual(saveControl["icon"] as? Int, 1)
    XCTAssertEqual(saveControl["width"] as? Double, 44)
    XCTAssertEqual(saveControl["height"] as? Double, 44)
    _ = try await web.evaluateJavaScript("document.querySelector('article a').click()")
    _ = try await web.evaluateJavaScript("document.querySelector('.save-answer').click()")
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(navigated, link); XCTAssertEqual(saved, message)
    let scripts = try await web.evaluateJavaScript("document.querySelectorAll('article script').length") as? Int
    XCTAssertEqual(scripts, 0)
  }
  private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
