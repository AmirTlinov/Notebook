import XCTest
import WebKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Notebook

@MainActor
final class NotebookChatRenderingTests: XCTestCase {
  func testOfflineMarkdownMathAndUntrustedTextShareOneDocument() async throws {
    let root = try XCTUnwrap(Bundle.main.url(forResource: "WebResources", withExtension: nil))
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 350, height: 400), configuration: configuration)
    #if os(iOS)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene), controller = UIViewController()
    window.rootViewController = controller; controller.view.addSubview(web); window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    #else
    let window = NSWindow(contentRect: web.frame.offsetBy(dx: -20_000, dy: -20_000), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
    defer { window.orderOut(nil); window.close() }
    #endif
    web.loadFileURL(root.appendingPathComponent("chat-shell.html"), allowingReadAccessTo: root)
    defer { web.stopLoading() }
    let deadline = ContinuousClock.now + .seconds(15)
    var ready = false
    while !ready, .now < deadline {
      ready = (try? await web.evaluateJavaScript("typeof window.updateMessages === 'function'")) as? Bool == true
      if !ready { try await Task.sleep(for: .milliseconds(50)) }
    }
    XCTAssertTrue(ready)

    _ = try await web.evaluateJavaScript("""
      window.fixturePrevious=[];
      window.fixtureMessages=async json=>{
        const messages=JSON.parse(json).map((m,i)=>({...m,id:m.id||'fixture-'+i}));
        const previous=new Map(window.fixturePrevious.map(m=>[m.id,m]));
        await window.updateMessages({conversation:'fixture',reset:false,order:messages.map(m=>m.id),
          upserts:messages.filter(m=>JSON.stringify(previous.get(m.id))!==JSON.stringify(m)),
          removed:window.fixturePrevious.filter(m=>!messages.some(n=>n.id===m.id)).map(m=>m.id),work:null,turnStatuses:{},focus:null});
        window.fixturePrevious=messages;
      };true
      """)
    let source = #"**Формула** \(x^2 + y^2 = 1\), $\frac{1}{2}$"# + "\n\n" + #"\[\int_0^1 x\,dx = \frac12\]"#
      + "\n\n<script>window.notebookInjected=true</script><img src='https://example.invalid/leak'>"
    let data = try JSONSerialization.data(withJSONObject: [["role":"assistant","text":source]])
    _ = try await web.callAsyncJavaScript("await window.fixtureMessages(json)", arguments: ["json":String(decoding:data,as:UTF8.self)], in:nil, contentWorld:.page)
    let count = try await web.evaluateJavaScript("document.querySelectorAll('mjx-container').length") as? Int
    XCTAssertEqual(count, 3)
    let unsafe = try await web.evaluateJavaScript("Boolean(window.notebookInjected) || document.querySelectorAll('img,main script').length > 0") as? Bool
    XCTAssertEqual(unsafe, false)
    let errors = try await web.evaluateJavaScript("document.querySelectorAll('[data-mml-node=merror]').length") as? Int
    XCTAssertEqual(errors, 0)
    let update = #"[{"role":"user","text":"Покажи формулу"},{"role":"assistant","text":"Готово: $2+2=4$"}]"#
    _ = try await web.callAsyncJavaScript("await window.fixtureMessages(json)", arguments: ["json":update], in:nil, contentWorld:.page)
    let articles = try await web.evaluateJavaScript("document.querySelectorAll('article').length") as? Int
    XCTAssertEqual(articles, 2, "Updates replace the bounded display, not the canonical conversation")
    let style = try await web.evaluateJavaScript("""
      (() => {
        const user=document.querySelector('article[data-role=user] .content');
        const assistant=document.querySelector('article[data-role=assistant] .content');
        return {font:getComputedStyle(document.body).fontSize,
          bodyBackground:getComputedStyle(document.body).backgroundColor,
          pageBackground:getComputedStyle(document.documentElement).backgroundColor,
          userBackground:getComputedStyle(user).backgroundColor,
          userRadius:getComputedStyle(user).borderRadius,
          assistantBackground:getComputedStyle(assistant).backgroundColor,
          labels:[...document.querySelectorAll('.role')].map(x=>x.textContent),
          overflow:document.documentElement.scrollWidth>innerWidth};
      })()
      """) as? [String: Any]
    XCTAssertEqual(style?["font"] as? String, "15px")
    XCTAssertEqual(style?["bodyBackground"] as? String,"rgb(252, 252, 250)")
    XCTAssertEqual(style?["pageBackground"] as? String,"rgb(252, 252, 250)")
    XCTAssertEqual(style?["userBackground"] as? String, "rgb(234, 243, 253)")
    XCTAssertEqual(style?["userRadius"] as? String, "20px")
    XCTAssertEqual(style?["assistantBackground"] as? String, "rgba(0, 0, 0, 0)")
    XCTAssertEqual(style?["labels"] as? [String], ["Вы", "Codex"], "Quiet styling retains accessible speaker names")
    XCTAssertEqual(style?["overflow"] as? Bool, false)

    let activity = #"[{"id":"native-command","role":"assistant","text":"Выполняется команда · swift test","activity":{"kind":"command","status":"inProgress","detail":"<script>window.executed = true</script>"}},{"id":"native-compaction","role":"assistant","text":"Контекст сжат","activity":{"kind":"compaction"}}]"#
    _ = try await web.callAsyncJavaScript("await window.fixtureMessages(json)", arguments: ["json": activity], in: nil, contentWorld: .page)
    let folded = try await web.evaluateJavaScript("document.querySelector('details.work')?.open === false") as? Bool
    XCTAssertEqual(folded, true, "Consecutive native actions start as one quiet, expandable row")
    _ = try await web.evaluateJavaScript("document.querySelector('details').open = true")
    _ = try await web.callAsyncJavaScript("await window.fixtureMessages(json)", arguments: ["json": activity], in: nil, contentWorld: .page)
    let actions = try await web.evaluateJavaScript("""
      ({rows:document.querySelectorAll('[data-kind=activity]').length,
        expanded:document.querySelector('details').open,
        nativeID:document.querySelector('article').dataset.itemId,
        icons:[...document.querySelectorAll('article .activity-icon')].map(x=>x.dataset.icon),
        marker:getComputedStyle(document.querySelector('article summary')).listStyleType,
        unsafe:!!window.executed || !!document.querySelector('article script'),
        inactiveButtons:document.querySelectorAll('[data-kind=activity] details').length})
      """) as? [String: Any]
    XCTAssertEqual(actions?["rows"] as? Int, 2)
    XCTAssertEqual(actions?["expanded"] as? Bool, true, "A streamed update preserves the human's expanded native item")
    XCTAssertEqual(actions?["nativeID"] as? String, "native-command")
    XCTAssertEqual(actions?["icons"] as? [String], ["command", "compaction"], "Each native action carries its semantic icon, not a play triangle")
    XCTAssertEqual(actions?["marker"] as? String, "none")
    XCTAssertEqual(actions?["unsafe"] as? Bool, false, "A command's text is not HTML or a new instruction")
    XCTAssertEqual(actions?["inactiveButtons"] as? Int, 1, "Events without details do not pretend to expand")
    let longText = String(repeating: "Материал для обсуждения. ", count: 80)
    let longMessage = try JSONSerialization.data(withJSONObject: [["id": "long", "role": "user", "text": longText]])
    _ = try await web.callAsyncJavaScript("await window.fixtureMessages(json)", arguments: ["json": String(decoding: longMessage, as: UTF8.self)], in: nil, contentWorld: .page)
    let longState = try await web.evaluateJavaScript("({folded:document.querySelector('details.long-message')?.open === false, text:[...document.querySelector('details.long-message').children].filter(x=>x.tagName!=='SUMMARY').map(x=>x.textContent).join('')})") as? [String: Any]
    XCTAssertEqual(longState?["folded"] as? Bool, true)
    XCTAssertEqual((longState?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), longText.trimmingCharacters(in: .whitespacesAndNewlines), "Folding preserves the native message instead of guessing which text to discard")
    _ = try await web.callAsyncJavaScript("""
      window.parseCount=0;window.typesetCounts=[];
      marked.use({hooks:{preprocess(markdown){window.parseCount++;return markdown;}}});
      const typeset=MathJax.typesetPromise.bind(MathJax);MathJax.typesetPromise=nodes=>{window.typesetCounts.push(nodes.length);return typeset(nodes)};
      window.many=Array.from({length:128},(_,i)=>({id:'many-'+i,role:'assistant',text:'Message '+i}));
      await window.fixtureMessages(JSON.stringify(window.many));window.retained=document.querySelector('[data-item-id="many-0"]');
      window.parseCount=0;window.typesetCounts=[];
      window.changedArticle=document.querySelector('[data-item-id="many-127"]');
      const text=window.changedArticle.querySelector('.content p').firstChild;
      window.getSelection().setBaseAndExtent(text,0,text,7);
      window.selectionBefore=window.getSelection().toString();
      window.many[127].text+=' changed';await window.fixtureMessages(JSON.stringify(window.many));
      """, arguments: [:], in: nil, contentWorld: .page)
    let delta = try await web.evaluateJavaScript("({parses:window.parseCount,typesets:window.typesetCounts,retained:window.retained===document.querySelector('[data-item-id=\"many-0\"]')})") as? [String: Any]
    XCTAssertEqual(delta?["parses"] as? Int, 1)
    XCTAssertEqual(delta?["typesets"] as? [Int], [1])
    XCTAssertEqual(delta?["retained"] as? Bool, true)
    let beforeSelection = try await web.evaluateJavaScript("window.selectionBefore") as? String
    XCTAssertEqual(beforeSelection, "Message", "The WebKit selection exists before streaming")
    let selection = try await web.evaluateJavaScript("window.getSelection().toString()") as? String
    XCTAssertEqual(selection, "Message")
    let retainedChanged = try await web.evaluateJavaScript("window.changedArticle===document.querySelector('[data-item-id=\"many-127\"]')") as? Bool
    XCTAssertEqual(retainedChanged, true)
    _ = try await web.callAsyncJavaScript("await window.updateMessages({conversation:'fixture',reset:false,order:window.many.map(m=>m.id),upserts:[],removed:[],work:{turnID:'working',title:'Working',running:true},turnStatuses:{},focus:null})", arguments: [:], in: nil, contentWorld: .page)
    let countAfterStatus = try await web.evaluateJavaScript("window.parseCount") as? Int
    XCTAssertEqual(countAfterStatus, 1, "Status does not parse transcript bodies")

  }
}
