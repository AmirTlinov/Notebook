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

  func testDelayedBundledMathCannotRestoreThePreviousThreadThroughTheCoordinator() async throws {
    let coordinator = NotebookChatTranscript.Coordinator()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive })
    let previous = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
    window.frame = CGRect(x: 0, y: 0, width: 540, height: 560)
    window.rootViewController = root; window.makeKeyAndVisible(); window.layoutIfNeeded()
    coordinator.mount(root.view)
    defer { coordinator.close(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

    func waitForTranscript(_ expression: String, _ reason: String) async throws {
      let deadline = ContinuousClock.now + .seconds(15)
      while .now < deadline {
        if coordinator.ready, let web = coordinator.web,
          (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw NSError(domain: "NotebookChatPanelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    coordinator.update(messages: [], conversationID: "old-thread")
    try await waitForTranscript("typeof window.updateMessages==='function' && typeof MathJax.typesetPromise==='function'",
      "The mounted bundled transcript did not load")
    let web = try XCTUnwrap(coordinator.web)
    XCTAssertTrue(web.window === window)
    XCTAssertTrue(web.url?.isFileURL == true)
    XCTAssertEqual(web.url?.lastPathComponent, "chat-shell.html")
    _ = try await web.evaluateJavaScript("""
      window.chatMathReady=false;
      MathJax.startup.promise.then(()=>{window.chatMathReady=true;});true
      """)
    try await waitForTranscript("window.chatMathReady===true", "The actual bundled MathJax did not become ready")
    _ = try await web.evaluateJavaScript("""
      window.heldChatMath={started:false,finished:false};
      const actualTypeset=MathJax.typesetPromise.bind(MathJax);
      const gate=new Promise(resolve=>{window.heldChatMath.release=resolve;});
      let first=true;
      MathJax.typesetPromise=async nodes=>{
        const held=first;first=false;
        if(held){window.heldChatMath.started=true;await gate;}
        const result=await actualTypeset(nodes);
        if(held)window.heldChatMath.finished=true;
        return result;
      };true
      """)
    let old = CodexMessage(id: "answer", turnID: "old-turn", clientID: nil, role: .assistant,
      text: "Old thread: $x^2=1$")
    coordinator.update(messages: [old], conversationID: "old-thread")
    try await waitForTranscript("window.heldChatMath.started && document.querySelectorAll('.math-stage').length===1",
      "The old thread never entered the controlled actual typeset await")
    _ = try await web.evaluateJavaScript("window.oldChatArticle=document.querySelector('#messages [data-item-id=answer]');true")

    // Reuse the server message ID across threads. Native acceptance must cross
    // its WebKit await while the old math owner still holds its prepared clone.
    let current = CodexMessage(id: "answer", turnID: "new-turn", clientID: nil, role: .assistant,
      text: "Current thread: **keep this text** [Reference](https://example.com/current).")
    coordinator.update(messages: [current], conversationID: "new-thread")
    try await waitForTranscript("""
      shownConversation==='new-thread' && !window.heldChatMath.finished
        && document.querySelector('#messages [data-item-id=answer]')!==window.oldChatArticle
        && document.querySelector('#messages .content')?.textContent.includes('Current thread: keep this text')
      """, "The new plain thread was blocked by the previous thread's math await")
    let selected = try await web.evaluateJavaScript("""
      window.currentChatArticle=document.querySelector('#messages [data-item-id=answer]');
      window.currentChatLink=window.currentChatArticle.querySelector('a');
      window.currentChatText=window.currentChatArticle.querySelector('strong').firstChild;
      window.currentChatLink.focus();
      getSelection().setBaseAndExtent(window.currentChatText,0,window.currentChatText,window.currentChatText.length);
      document.activeElement===window.currentChatLink && getSelection().toString()==='keep this text'
      """) as? Bool
    XCTAssertEqual(selected, true, "The current thread must own a real WebKit focus and prose selection before release")
    _ = try await web.evaluateJavaScript("window.heldChatMath.release();true")
    try await waitForTranscript("window.heldChatMath.finished && mathRendering===null && document.querySelectorAll('.math-stage').length===0",
      "The released real MathJax batch did not drain")
    let preserved = try await web.evaluateJavaScript("""
      shownConversation==='new-thread' && document.querySelectorAll('#messages article').length===1
        && document.querySelector('#messages [data-item-id=answer]')===window.currentChatArticle
        && !document.getElementById('messages').textContent.includes('Old thread')
        && document.querySelectorAll('#messages mjx-container').length===0
        && document.activeElement===window.currentChatLink
        && getSelection().toString()==='keep this text' && getSelection().anchorNode===window.currentChatText
        && Array.from(MathJax.startup.document.math).length===0
      """) as? Bool
    XCTAssertEqual(preserved, true, "Late old-thread completion must leave the new article, focus and selection intact")

    let formula = CodexMessage(id: "current-formula", turnID: "new-turn", clientID: nil, role: .assistant,
      text: "Current formula: $z^2+9$")
    coordinator.update(messages: [current, formula], conversationID: "new-thread")
    try await waitForTranscript("""
      mathRendering===null && document.querySelectorAll('#messages mjx-container').length===1
        && document.querySelector('#messages [data-item-id=current-formula] mjx-assistive-mml math')?.textContent==='z2+9'
      """, "The current thread did not render its formula through the same bundled engine")
    let final = try await web.evaluateJavaScript("""
      (()=>{
        const svg=document.querySelector('#messages [data-item-id=current-formula] mjx-container svg');
        const frame=svg.getBoundingClientRect();
        return document.querySelectorAll('#messages article').length===2 && frame.width>0 && frame.height>0
          && document.querySelector('#messages [data-item-id=answer]')===window.currentChatArticle
          && document.activeElement===window.currentChatLink && getSelection().toString()==='keep this text'
          && document.querySelectorAll('.math-stage,[data-mml-node=merror]').length===0
          && Array.from(MathJax.startup.document.math).length===0;
      })()
      """) as? Bool
    XCTAssertEqual(final, true)
    XCTAssertTrue(coordinator.web === web, "A thread switch must use the mounted transcript's existing physical owner")
    try await attachInstalledWindow(window, web: web)
  }

  func testWebContentProcessDeathRecoversReadingAndRetryPublishesOnlyTheLatestThread() async throws {
    let coordinator = NotebookChatTranscript.Coordinator(), bodies = NotebookChatBodyWindow()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive })
    let previous = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
    window.frame = CGRect(x: 0, y: 0, width: 540, height: 560)
    window.rootViewController = root; window.makeKeyAndVisible(); window.layoutIfNeeded()
    coordinator.mount(root.view)
    defer { coordinator.close(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    func until(_ reason: String, _ condition: () async -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(15)
      while .now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw NSError(domain: "NotebookChatPanelTests", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    let messages = (0..<30).map { CodexMessage(id: "row-\($0)", turnID: "old-turn", clientID: nil,
      role: .assistant, text: "Reading row \($0). " + String(repeating: "The current conversation remains readable. ", count: 12)) }
    var initialBytes = 0
    for message in messages { initialBytes += try XCTUnwrap(CodexMessageTransfer.encodedByteCount(message)) }
    var initialCredit: NotebookChatBodyWindow.Credit? = try XCTUnwrap(bodies.reserve(initialBytes))
    weak let initialBodyCredit = initialCredit
    var actions = 0
    coordinator.loadEarlier = { actions += 1 }; coordinator.loadMessage = { _ in actions += 1 }
    coordinator.openLink = { _ in actions += 1 }; coordinator.saveExplanation = { _ in actions += 1 }
    coordinator.update(messages: messages, bodyCredits: [try XCTUnwrap(initialCredit)], conversationID: "reading-thread")
    initialCredit = nil
    try await until("The actual current thread did not settle") {
      guard coordinator.ready, !coordinator.publicationIsPending, let web = coordinator.web else { return false }
      return (try? await web.evaluateJavaScript("shownConversation==='reading-thread' && document.querySelectorAll('#messages article').length===30")) as? Bool == true
    }
    let web = try XCTUnwrap(coordinator.web), leaseID = try XCTUnwrap(coordinator.lease).id
    let firstNavigation = try XCTUnwrap(coordinator.navigation)
    // These WebKit SPI are confined to this native fixture. An injected delegate
    // callback would not establish process death or replacement of the JS realm.
    let pidSelector = NSSelectorFromString("_webProcessIdentifier"), killSelector = NSSelectorFromString("_killWebContentProcess")
    guard web.responds(to: pidSelector), web.responds(to: killSelector) else {
      throw XCTSkip("This installed WebKit does not expose the test-only process termination SPI")
    }
    typealias ProcessID = @convention(c) (AnyObject, Selector) -> Int32
    typealias KillProcess = @convention(c) (AnyObject, Selector) -> Void
    let processID = unsafeBitCast(try XCTUnwrap(web.method(for: pidSelector)), to: ProcessID.self)
    let killProcess = unsafeBitCast(try XCTUnwrap(web.method(for: killSelector)), to: KillProcess.self)
    let firstPID = processID(web, pidSelector)
    XCTAssertGreaterThan(firstPID, 0)
    XCTAssertTrue(web.navigationDelegate === coordinator)
    _ = try await web.evaluateJavaScript("window.beforeChatProcessDeath='original-realm';true")
    XCTAssertGreaterThan(web.scrollView.contentSize.height, 1_000)
    web.scrollView.setContentOffset(.init(x: 0, y: 240), animated: true)
    try await until("The actual native reading scroll did not produce a settled receipt") {
      guard let offset = coordinator.settledReadingOffset else { return false }
      return abs(web.scrollView.contentOffset.y - 240) <= 1 && abs(offset - 240) <= 1
    }
    killProcess(web, killSelector)
    // Do not evaluate JavaScript while waiting for the delegate: doing so could
    // launch a process independently of the production recovery route.
    try await until("Actual WK termination did not start a new navigation") {
      coordinator.navigation != nil && coordinator.navigation !== firstNavigation
    }
    try await until("The recovered realm did not replay the current accepted transcript") {
      guard coordinator.ready, !coordinator.publicationIsPending else { return false }
      return (try? await web.evaluateJavaScript("typeof window.beforeChatProcessDeath==='undefined' && shownConversation==='reading-thread' && document.querySelectorAll('#messages article').length===30")) as? Bool == true
    }
    try await until("The exact settled reading cut lost its native scroll position") {
      guard let offset = coordinator.settledReadingOffset else { return false }
      return abs(web.scrollView.contentOffset.y - 240) <= 1 && abs(offset - 240) <= 1
    }
    let secondPID = processID(web, pidSelector), secondNavigation = try XCTUnwrap(coordinator.navigation)
    XCTAssertGreaterThan(secondPID, 0); XCTAssertNotEqual(secondPID, firstPID)
    XCTAssertTrue(coordinator.web === web); XCTAssertEqual(coordinator.lease?.id, leaseID)
    XCTAssertTrue(web.navigationDelegate === coordinator)

    _ = try await web.evaluateJavaScript("""
      window.heldChatDeathPublication={entered:false};
      const actualUpdate=window.updateMessages;
      const gate=new Promise(resolve=>{window.heldChatDeathPublication.release=resolve;});
      window.updateMessages=async update=>{
        if(update.upserts.some(value=>value.text.startsWith('Held before process death.'))){
          window.heldChatDeathPublication.entered=true;await gate;
        }
        return actualUpdate(update);
      };true
      """)
    let pending = CodexMessage(id: "row-0", turnID: "old-turn", clientID: nil, role: .assistant,
      text: "Held before process death. " + String(repeating: "Submitted body stays charged. ", count: 400)).identifyingContent()
    let pendingBytes = try XCTUnwrap(CodexMessageTransfer.encodedByteCount(pending))
    var pendingCredit: NotebookChatBodyWindow.Credit? = try XCTUnwrap(bodies.reserve(pendingBytes))
    weak let pendingBodyCredit = pendingCredit
    coordinator.update(messages: [pending], bodyCredits: [try XCTUnwrap(pendingCredit)], conversationID: "reading-thread")
    pendingCredit = nil
    try await until("The real awaited publication was not held before process death") {
      guard coordinator.publicationIsPending else { return false }
      return (try? await web.evaluateJavaScript("window.heldChatDeathPublication.entered")) as? Bool == true
    }
    let newer = CodexMessage(id: "row-0", turnID: "old-turn", clientID: nil, role: .assistant,
      text: "Newer desired before process death. " + String(repeating: "Only the newest accepted revision may recover. ", count: 400)).identifyingContent()
    let newerBytes = try XCTUnwrap(CodexMessageTransfer.encodedByteCount(newer))
    var newerCredit: NotebookChatBodyWindow.Credit? = try XCTUnwrap(bodies.reserve(newerBytes))
    weak let newerBodyCredit = newerCredit
    coordinator.update(messages: [newer], bodyCredits: [try XCTUnwrap(newerCredit)], conversationID: "reading-thread")
    newerCredit = nil
    XCTAssertTrue(coordinator.publicationIsPending)
    XCTAssertNil(coordinator.settledReadingOffset, "A newer desired cut cannot reuse the former settled reading receipt")
    XCTAssertNotNil(initialBodyCredit); XCTAssertNotNil(pendingBodyCredit)
    XCTAssertEqual(bodies.retainedBytes, initialBytes + pendingBytes + newerBytes,
      "The real held callback must retain its submitted and previously published bodies after desired advances")
    killProcess(web, killSelector)
    try await until("A repeated process failure did not expose bounded native Retry") {
      !coordinator.ready && self.chatRetryButton(in: root.view) != nil
    }
    XCTAssertTrue(coordinator.navigation === secondNavigation, "A repeated failure cannot start an automatic reload loop")
    coordinator.update(messages: [.init(id: "row-0", turnID: "new-turn", clientID: nil, role: .assistant,
      text: "Superseded replacement")], conversationID: "latest-thread")
    let latest = CodexMessage(id: "row-0", turnID: "new-turn", clientID: nil, role: .assistant,
      text: "Latest replacement. " + String(repeating: "Read only the latest thread revision. ", count: 400))
    let latestBytes = try XCTUnwrap(CodexMessageTransfer.encodedByteCount(latest))
    var latestCredit: NotebookChatBodyWindow.Credit? = try XCTUnwrap(bodies.reserve(latestBytes))
    coordinator.update(messages: [latest], bodyCredits: [try XCTUnwrap(latestCredit)], conversationID: "latest-thread")
    latestCredit = nil
    try XCTUnwrap(chatRetryButton(in: root.view)).sendActions(for: .touchUpInside)
    try await until("Retry did not publish the latest desired thread in a fresh realm") {
      guard coordinator.ready, !coordinator.publicationIsPending else { return false }
      return (try? await web.evaluateJavaScript("typeof window.heldChatDeathPublication==='undefined' && shownConversation==='latest-thread' && document.querySelectorAll('#messages article').length===1 && document.getElementById('messages').textContent.includes('Latest replacement.') && !document.getElementById('messages').textContent.includes('Superseded replacement') && !document.getElementById('messages').textContent.includes('Held before process death.') && !document.getElementById('messages').textContent.includes('Newer desired before process death.') && !document.getElementById('messages').textContent.includes('Reading row') && getSelection().toString()===''")) as? Bool == true
    }
    try await until("The terminated realm's actual callback did not drain its retired body owners") {
      initialBodyCredit == nil && pendingBodyCredit == nil && newerBodyCredit == nil
    }
    XCTAssertEqual(bodies.retainedBytes, latestBytes, "An old physical callback cannot release the successor's body credit")
    let thirdPID = processID(web, pidSelector)
    XCTAssertGreaterThan(thirdPID, 0); XCTAssertNotEqual(thirdPID, secondPID)
    XCTAssertTrue(coordinator.navigation !== secondNavigation)
    XCTAssertTrue(coordinator.web === web); XCTAssertEqual(coordinator.lease?.id, leaseID)
    XCTAssertNil(chatRetryButton(in: root.view)); XCTAssertEqual(actions, 0, "Replaying a view cannot invoke conversation actions")
    try await until("An old reading receipt scrolled the replacement thread") {
      let scroll = web.scrollView
      return abs(scroll.contentOffset.y - max(-scroll.adjustedContentInset.top,
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)) <= 1
    }
    try await attachInstalledWindow(window, web: web)
  }

  func testFailedPublicationKeepsItsBodiesAndRetryCanPublishTheLatestExcerpt() async throws {
    let coordinator = NotebookChatTranscript.Coordinator(), bodies = NotebookChatBodyWindow()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive })
    let previous = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
    window.frame = CGRect(x: 0, y: 0, width: 540, height: 560)
    window.rootViewController = root; window.makeKeyAndVisible(); window.layoutIfNeeded()
    coordinator.mount(root.view)
    defer { coordinator.close(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    func until(_ reason: String, _ condition: () async -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(10)
      while .now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      throw NSError(domain: "NotebookChatPanelTests", code: 3, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    let fixed = CodexMessage(id: "fixed", turnID: "turn", clientID: nil, role: .assistant,
      text: "**Preserved selection** [Reference](https://example.com/reference)").identifyingContent()
    let initial = CodexMessage(id: "answer", turnID: "turn", clientID: nil, role: .assistant,
      text: "Initial body").identifyingContent()
    let pending = CodexMessage(id: "partial-only", turnID: "turn", clientID: nil, role: .assistant,
      text: "Pending body. " + String(repeating: "Partially published text. ", count: 400)).identifyingContent()
    let latest = CodexMessage(id: "answer", turnID: "new-turn", clientID: nil, role: .assistant,
      text: String(repeating: "Retained full text. ", count: 800) + "FULL_BODY_END").identifyingContent()
    let fixedBytes = try XCTUnwrap(CodexMessageTransfer.encodedByteCount(fixed))
    let initialBytes = try XCTUnwrap(CodexMessageTransfer.encodedByteCount(initial))
    let pendingBytes = try XCTUnwrap(CodexMessageTransfer.encodedByteCount(pending))
    let latestBytes = try XCTUnwrap(CodexMessageTransfer.encodedByteCount(latest))
    let fixedCredit = try XCTUnwrap(bodies.reserve(fixedBytes))
    var initialCredit: NotebookChatBodyWindow.Credit? = try XCTUnwrap(bodies.reserve(initialBytes))
    weak let initialBodyCredit = initialCredit
    coordinator.update(messages: [fixed, initial], bodyCredits: [fixedCredit, try XCTUnwrap(initialCredit)], conversationID: "old-thread")
    initialCredit = nil
    try await until("The initial credited body did not settle") {
      guard coordinator.ready, !coordinator.publicationIsPending, let web = coordinator.web else { return false }
      return (try? await web.evaluateJavaScript("document.querySelectorAll('#messages article').length===2")) as? Bool == true
    }
    let web = try XCTUnwrap(coordinator.web), navigation = try XCTUnwrap(coordinator.navigation)
    let selected = try await web.evaluateJavaScript("""
      window.fixedChatArticle=document.querySelector('#messages [data-item-id=fixed]');
      window.fixedChatLink=window.fixedChatArticle.querySelector('a');
      const text=window.fixedChatArticle.querySelector('strong').firstChild;
      window.fixedChatLink.focus();getSelection().setBaseAndExtent(text,0,text,text.length);
      window.failedChatPublication={entered:false};
      const actualUpdate=window.updateMessages;
      const gate=new Promise(resolve=>{window.failedChatPublication.release=resolve;});
      window.updateMessages=async update=>{
        if(update.upserts.some(value=>value.text.startsWith('Pending body.'))){
          window.failedChatPublication.entered=true;await gate;await actualUpdate(update);
          throw new Error('Controlled publication failure after actual DOM mutation');
        }
        return actualUpdate(update);
      };
      getSelection().toString()==='Preserved selection'
      """) as? Bool
    XCTAssertEqual(selected, true)
    var pendingCredit: NotebookChatBodyWindow.Credit? = try XCTUnwrap(bodies.reserve(pendingBytes))
    coordinator.update(messages: [fixed, initial, pending], bodyCredits: [fixedCredit, try XCTUnwrap(initialBodyCredit), try XCTUnwrap(pendingCredit)], conversationID: "old-thread")
    pendingCredit = nil
    try await until("The real awaited WK publication was not held") {
      (try? await web.evaluateJavaScript("window.failedChatPublication.entered")) as? Bool == true
    }
    var latestCredit: NotebookChatBodyWindow.Credit? = try XCTUnwrap(bodies.reserve(latestBytes))
    coordinator.update(messages: [fixed, latest], bodyCredits: [fixedCredit, try XCTUnwrap(latestCredit)], conversationID: "new-thread")
    XCTAssertTrue(coordinator.publicationIsPending)
    XCTAssertEqual(bodies.retainedBytes, fixedBytes + initialBytes + pendingBytes + latestBytes,
      "The submitted old body and acknowledged DOM body remain charged through the actual callback")
    _ = try await web.evaluateJavaScript("window.failedChatPublication.release();true")
    try await until("A semantic publication failure did not leave an explicit Retry") {
      !coordinator.publicationIsPending && self.chatRetryButton(in: root.view) != nil
    }
    XCTAssertTrue(coordinator.ready); XCTAssertTrue(coordinator.navigation === navigation)
    XCTAssertTrue(coordinator.web === web)
    XCTAssertEqual(bodies.retainedBytes, fixedBytes + initialBytes + pendingBytes + latestBytes,
      "Partial DOM mutation must retain both possible body owners after the failed callback")
    let preserved = try await web.evaluateJavaScript("""
      shownConversation==='old-thread' && messagesByID.has('partial-only') && document.getElementById('messages').textContent.includes('Pending body.')
        && document.querySelector('#messages [data-item-id=fixed]')===window.fixedChatArticle
        && document.activeElement===window.fixedChatLink && getSelection().toString()==='Preserved selection'
      """) as? Bool
    XCTAssertEqual(preserved, true, "A script exception must preserve the live document, focus and unaffected selection")
    // Returning to the last ACK is not a no-op after a partially applied script.
    // Retry must repair the actual DOM even though that basis equals `sent`.
    coordinator.update(messages: [fixed, initial], bodyCredits: [fixedCredit, try XCTUnwrap(initialBodyCredit)], conversationID: "old-thread")
    try XCTUnwrap(chatRetryButton(in: root.view)).sendActions(for: .touchUpInside)
    try await until("Retry mistook the last ACK for an unchanged partially mutated DOM") {
      guard !coordinator.publicationIsPending else { return false }
      return (try? await web.evaluateJavaScript("shownConversation==='old-thread' && !messagesByID.has('partial-only') && document.getElementById('messages').textContent.includes('Initial body') && !document.getElementById('messages').textContent.includes('Pending body.') && document.querySelector('#messages [data-item-id=fixed]')===window.fixedChatArticle && document.activeElement===window.fixedChatLink && getSelection().toString()==='Preserved selection'")) as? Bool == true
    }
    XCTAssertTrue(coordinator.navigation === navigation, "Semantic Retry uses the live document")
    XCTAssertNil(chatRetryButton(in: root.view))
    XCTAssertEqual(bodies.retainedBytes, fixedBytes + initialBytes + latestBytes)
    coordinator.update(messages: [fixed, latest], bodyCredits: [fixedCredit, try XCTUnwrap(latestCredit)], conversationID: "new-thread")
    try await until("The current thread did not replace the successfully repaired DOM") {
      guard !coordinator.publicationIsPending else { return false }
      return (try? await web.evaluateJavaScript("shownConversation==='new-thread' && document.getElementById('messages').textContent.includes('FULL_BODY_END')")) as? Bool == true
    }
    XCTAssertEqual(bodies.retainedBytes, fixedBytes + latestBytes)
    let flagged = CodexMessage(id: latest.id, turnID: latest.turnID, clientID: latest.clientID, role: latest.role,
      text: latest.text, isTruncated: true, contentRevision: latest.contentRevision)
    coordinator.update(messages: [fixed, flagged], bodyCredits: [fixedCredit, try XCTUnwrap(latestCredit)], conversationID: "new-thread")
    try await until("The pending revision did not expose its actual full-body loading state") {
      guard !coordinator.publicationIsPending else { return false }
      return (try? await web.evaluateJavaScript("messagesByID.get('answer').isTruncated && document.getElementById('messages').textContent.includes('FULL_BODY_END')")) as? Bool == true
    }
    // Both headers have the same immutable revision and isTruncated value.
    // Eviction changes the actual display shape and must reach the real WK.
    coordinator.update(messages: [fixed, flagged.preview()], bodyCredits: [fixedCredit], conversationID: "new-thread")
    latestCredit = nil
    try await until("The excerpt ACK left an uncharged full body in WebKit") {
      guard !coordinator.publicationIsPending else { return false }
      return (try? await web.evaluateJavaScript("messagesByID.get('answer').isTruncated && !document.getElementById('messages').textContent.includes('FULL_BODY_END') && document.querySelector('#messages [data-item-id=answer] .content').textContent.length<3000")) as? Bool == true
    }
    XCTAssertEqual(bodies.retainedBytes, fixedBytes)
  }

  private func chatRetryButton(in view: UIView) -> UIButton? {
    if let button = view as? UIButton, button.accessibilityIdentifier == "notebook-chat-retry" { return button }
    return view.subviews.lazy.compactMap { self.chatRetryButton(in: $0) }.first
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
      companion: .init(frame: .zero, controls: .zero, cards: .zero),
      move: { _, _ in }, resize: { _, _, _ in }, endInteraction: {})
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
