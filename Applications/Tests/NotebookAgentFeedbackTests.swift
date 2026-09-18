import NotebookCore
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Notebook

@MainActor final class NotebookAgentFeedbackTests: XCTestCase {
  private let target = CollaborationTarget(kind:.board,id:UUID())
  private func subject(_ id: String = "shape", revision: String = "source") -> NotebookAgentFeedbackChange.Subject {
    .init(reference:.init(target:target,elementID:id,revision:revision),expected:.init(target:target,revision:revision))
  }
  private func action(_ id: UUID = UUID(), element: String = "shape") throws -> NotebookActionReadModel {
    let operation = CollaborationOperation(kind:.updateElement,target:target,id:element,values:[:])
    let receipt = try JSONValue.object(["id":.string(id.uuidString),
      "action":try .encode(CollaborationAction(id:id,summary:"change",expected:[],operations:[operation])),
      "createdAt":.number(0),"revisions":.array([]),"changes":.array([]),"author":.string("agent")]).decode(CollaborationReceipt.self)
    return try .init(receipt)
  }
  private func change(_ action: NotebookActionReadModel, subject: NotebookAgentFeedbackChange.Subject? = nil) -> NotebookAgentFeedbackChange {
    .init(actionID:action.id,version:action.actionVersion,contextID:action.action.resolvedContextID,subjects:[subject ?? self.subject()])
  }

  func testReceiptDoesNotStartTheClockAndOffscreenResultsNeverReplay() throws {
    let owner = NotebookAgentFeedback(); defer { owner.stop() }
    let start = Date(), first = try action()
    owner.receive(actions:[],changes:[],now:start)
    owner.receive(actions:[first],changes:[change(first)],now:start)
    XCTAssertTrue(owner.episodes.isEmpty)
    owner.presented(ready:[],offscreen:[],now:start.addingTimeInterval(12))
    XCTAssertTrue(owner.episodes.isEmpty,"Slow WebKit does not spend visible feedback time")
    owner.presented(ready:[subject().key],offscreen:[],now:start.addingTimeInterval(12))
    XCTAssertEqual(owner.episodes[subject().key]?.startedAt,start.addingTimeInterval(12))
    owner.expire(now:start.addingTimeInterval(15))
    XCTAssertTrue(owner.episodes.isEmpty)
    let hidden = try action(element:"hidden"), hiddenSubject = subject("hidden")
    owner.receive(actions:[first,hidden],changes:[change(hidden,subject:hiddenSubject)],now:start.addingTimeInterval(16))
    owner.presented(ready:[],offscreen:[hiddenSubject.key],now:start.addingTimeInterval(16))
    owner.presented(ready:[hiddenSubject.key],offscreen:[],now:start.addingTimeInterval(17))
    XCTAssertTrue(owner.episodes.isEmpty)
  }

  func testSeriesCoalescesWithoutRestartAndHistoryIsSilent() throws {
    let owner = NotebookAgentFeedback(); defer { owner.stop() }
    let now = Date(), history = try action(), first = try action(), second = try action()
    owner.receive(actions:[history],changes:[change(history)],now:now)
    XCTAssertTrue(owner.pendingSubjects.isEmpty)
    owner.receive(actions:[history,first],changes:[change(first)],now:now)
    owner.presented(ready:[subject().key],offscreen:[],now:now)
    owner.receive(actions:[history,first,second],changes:[change(second)],now:now.addingTimeInterval(0.7))
    owner.presented(ready:[subject().key],offscreen:[],now:now.addingTimeInterval(0.7))
    XCTAssertEqual(owner.episodes.count,1)
    XCTAssertEqual(owner.episodes[subject().key]?.startedAt,now)
    XCTAssertEqual(owner.episodes[subject().key]?.endsAt,now.addingTimeInterval(0.7+NotebookAgentFeedback.resultDuration))
    owner.stop()
    owner.receive(actions:[history,first,second],changes:[],now:now.addingTimeInterval(1))
    owner.presented(ready:[subject().key],offscreen:[],now:now.addingTimeInterval(1))
    XCTAssertTrue(owner.episodes.isEmpty,"Foreground/remount does not replay consumed actions")
  }

  func testUnrelatedOwnerRevisionRebindsTheProofButNotTheAnimationClock() throws {
    let owner = NotebookAgentFeedback(); defer { owner.stop() }
    let now = Date(), action = try action()
    owner.receive(actions:[],changes:[],now:now)
    owner.receive(actions:[action],changes:[change(action)],now:now)
    owner.presented(ready:[subject().key],offscreen:[],now:now)
    let advanced = subject(revision:"owner-advanced")
    owner.receive(actions:[action],changes:[change(action,subject:advanced)],now:now.addingTimeInterval(1))
    XCTAssertEqual(owner.episodes[advanced.key]?.subject,advanced)
    XCTAssertEqual(owner.episodes[advanced.key]?.startedAt,now)
    XCTAssertEqual(owner.episodes[advanced.key]?.endsAt,now.addingTimeInterval(NotebookAgentFeedback.resultDuration))
  }

  func testExplicitAttentionUsesSameMaterialAndClearHasNoCameraOrSelectionOwner() {
    let owner = NotebookAgentFeedback(); defer { owner.stop() }
    let id = UUID()
    owner.setAttention([subject()],id:id)
    XCTAssertTrue(owner.episodes.isEmpty)
    owner.presented(ready:[subject().key],offscreen:[])
    XCTAssertEqual(owner.attentionID,id)
    XCTAssertEqual(owner.episodes[subject().key]?.isAttention,true)
    owner.clearAttention()
    XCTAssertTrue(owner.episodes.isEmpty)
    XCTAssertNil(owner.attentionID)
  }

  func testAttentionPlayerWaitsForInstalledMaterialAndCancellationClearsIt() async throws {
    let player = NotebookPresentationPlayer(), device = UUID(), session = UUID(), peer = UUID()
    let view = NotebookPresentationView(deviceID:device,sessionID:session,sequence:1)
    var moved = 0, stopped = 0, clears = 0, receipts: [NotebookPresentationReceipt] = []
    player.currentView = { (device,.init(sessionID:session,sequence:1,phase:.settled,
      presence:.init(mode:.board,camera:.init(),viewport:.init(x:834,y:1194)))) }
    player.isInputActive = { false }
    player.moveCamera = { _,_ in moved += 1; return true }
    player.stopCamera = { stopped += 1 }
    player.clearAttention = { clears += 1 }
    player.reply = { receipt,_ in receipts.append(receipt) }
    player.receive(.play(.init(id:UUID(),view:view,steps:[.init(duration:3,attention:[subject().reference])]),expiresAt:Date().addingTimeInterval(5)),peer:peer)
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertFalse(receipts.contains { $0.status == .playing })
    player.rendered(try XCTUnwrap(player.stage?.id),material:.attention)
    try await Task.sleep(for:.milliseconds(80))
    XCTAssertTrue(receipts.contains { $0.status == .playing })
    XCTAssertEqual(moved,0)
    player.interrupt("human_input")
    XCTAssertEqual(clears,1)
    XCTAssertEqual(stopped,0,"Attention-only cannot interrupt the human camera")
    XCTAssertNil(player.stage)
    XCTAssertEqual(receipts.last?.status,.interrupted)
  }

  func testPhysicalMaterialHasInkAndFillLanesAndExpiresWithoutARemountFlash() async throws {
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let host = UIHostingController(rootView:AnyView(EmptyView()))
    window.overrideUserInterfaceStyle = .light; window.rootViewController = host; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    let bounds = CGRect(x:0,y:0,width:700,height:760)
    let graphics: [NotebookGraphic] = [
      .init(shape:.triangle,style:.init(strokeWidth:3,fill:.init(red:0.98,green:0.97,blue:0.95)),label:"Идея"),
      .init(shape:.ellipse,style:.init(strokeWidth:3,fill:.init(red:0.98,green:0.97,blue:0.95))),
      .init(shape:.rectangle,style:.init(strokeWidth:3),label:"Без заливки"),
      .init(shape:.connector,style:.init(strokeWidth:4),label:"Связь",connection:.init(start:.init(point:.init(x:0,y:80)),end:.init(point:.init(x:260,y:10)),bend:25))]
    let surfaces = graphics.enumerated().map { i,g in
      let frame = PageRect(x:0,y:0,width:260,height:170)
      let layout = NotebookGraphicGraph([.init(id:"shape",graphic:g,frame:frame,surface:.page(UUID()),shown:true)]).resolve("shape").layout!
      return NotebookAgentFeedbackSurface(rect:.init(x:Double(30+i%2*340),y:Double(140+i/2*250),width:layout.frame.width,height:layout.frame.height),graphic:g,layout:layout)
    }
    let start = Date()
    func render(_ age: Double, reduced: Bool = false, covered: Bool = false) async throws -> UIImage {
      host.rootView = AnyView(ZStack(alignment:.topLeading) {
        Color.white
        Text("Внимание и результат").font(.system(size:32,weight:.semibold)).position(x:340,y:65)
        ForEach(Array(surfaces.enumerated()),id:\.offset) { i,original in
          let surface = covered ? NotebookAgentFeedbackSurface(rect:original.rect,graphic:original.graphic,layout:original.layout,occluders:[.init(rect:original.rect,isSurface:true)]) : original
          NotebookGraphicView(graphic:graphics[i],layout:surface.layout)
            .frame(width:surface.rect.width,height:surface.rect.height).position(x:surface.rect.midX,y:surface.rect.midY)
          NotebookAgentFeedbackMaterial(surface:surface,episode:.init(subject:self.subject(String(i)),startedAt:start,
            endsAt:start.addingTimeInterval(NotebookAgentFeedback.resultDuration),isAttention:false),date:start.addingTimeInterval(age),reduceMotion:reduced)
        }
      }.frame(width:bounds.width,height:bounds.height,alignment:.topLeading)
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).ignoresSafeArea())
      try await Task.sleep(for:.milliseconds(100)); host.view.layoutIfNeeded()
      return UIGraphicsImageRenderer(bounds:host.view.bounds).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
    }
    let before = try await render(-1), lit = try await render(1.15), expired = try await render(3)
    for (name,image) in [("feedback-before",before),("feedback-shimmer-mesh",lit),("feedback-expired",expired)] {
      let attachment = XCTAttachment(image:image); attachment.name=name; attachment.lifetime = .keepAlways; add(attachment)
    }
    XCTAssertEqual(before.pngData(),expired.pngData())
    XCTAssertNotEqual(before.pngData(),lit.pngData())
    let covered = try await render(1.15,covered:true)
    XCTAssertEqual(before.pngData(),covered.pngData(),"A later opaque source cannot reveal agent light through itself")
    let stillA = try await render(0.4,reduced:true), stillB = try await render(1.4,reduced:true)
    XCTAssertEqual(stillA.pngData(),stillB.pngData())
  }
  func testWebMaterialPreservesDOMAndCanonicalSnapshot() async throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource:"agent-feedback",withExtension:"js",subdirectory:"WebResources"))
    let script = try String(contentsOf:url,encoding:.utf8)
    let web = WKWebView(frame:.init(x:0,y:0,width:600,height:500))
    let window = UIWindow(windowScene:try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
    let controller = UIViewController(); controller.view.addSubview(web)
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { web.stopLoading(); window.isHidden = true; window.rootViewController = nil }
    web.loadHTMLString("""
      <meta name="viewport" content="width=device-width,initial-scale=1"><style>
      body{background:white;color:black;font:24px Georgia} .block{position:relative}svg{width:300px;height:80px}
      </style><div id="document"><section class="block" data-block-id="words"><h1>Живое объяснение</h1>
      <p>Текст <b>остаётся</b> текстом.</p><svg viewBox="0 0 300 80"><path d="M0 40 Q100 0 290 40" fill="none" stroke="black" stroke-width="3"/></svg></section>
      <section class="block interactive" data-block-id="program"><button id="button" onclick="this.dataset.clicks=String(+(this.dataset.clicks||0)+1)">Кнопка</button></section></div>
      <script>\(script)</script><script>window.originalButton=document.getElementById('button');window.feedbackReady=true</script>
      """,baseURL:nil)
    let deadline = ContinuousClock.now + .seconds(5)
    while (try? await web.evaluateJavaScript("window.feedbackReady===true") as? Bool) != true,
      ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(20)) }
    let geometry = try await web.evaluateJavaScript("document.querySelector('#document').getBoundingClientRect().height") as? Double
    func snapshot() async throws -> UIImage {
      try await withCheckedThrowingContinuation { continuation in
        web.takeSnapshot(with:nil) { image,error in
          if let image { continuation.resume(returning:image) } else { continuation.resume(throwing:error ?? NSError(domain:"snapshot",code:1)) }
        }
      }
    }
    let plain = try await snapshot()
    _ = try await web.evaluateJavaScript("window.notebookAgentFeedback.update([{start:Date.now()-1000,end:Date.now()+2000,attention:false}])")
    let sameButton = try await web.evaluateJavaScript("document.getElementById('button')===window.originalButton") as? Bool
    XCTAssertEqual(sameButton,true)
    let sameGeometry = try await web.evaluateJavaScript("document.querySelector('#document').getBoundingClientRect().height") as? Double
    XCTAssertEqual(sameGeometry,geometry)
    _ = try await web.evaluateJavaScript("document.getElementById('button').click()")
    let clicks = try await web.evaluateJavaScript("document.getElementById('button').dataset.clicks") as? String
    XCTAssertEqual(clicks,"1")
    _ = try await web.evaluateJavaScript("window.notebookAgentFeedback.suspend()")
    let canonical = try await snapshot()
    XCTAssertEqual(plain.pngData(),canonical.pngData(),"Transient feedback cannot enter a content snapshot")
    _ = try await web.evaluateJavaScript("window.notebookAgentFeedback.resume();window.notebookAgentFeedback.clear()")
    let remnants = try await web.evaluateJavaScript("document.querySelectorAll('[data-nb-feedback-ink],[data-nb-feedback-surface],linearGradient[id^=nb-feedback]').length") as? Int
    XCTAssertEqual(remnants,0)
  }

}
