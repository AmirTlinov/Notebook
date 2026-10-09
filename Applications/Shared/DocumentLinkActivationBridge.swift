#if os(iOS)
import Foundation
import NotebookCore
import WebKit

/// One isolated listener for one executable WebKit. The page world has no
/// external-open handler; native admission captures the installed origin.
@MainActor
final class DocumentLinkActivationBridge: NSObject, WKScriptMessageHandler {
  private static let world = WKContentWorld.world(name: "Notebook.DocumentLinkActivation")
  private static let handler = "documentLinkActivation"
  private weak var controller: WKUserContentController?
  private weak var webView: WKWebView?
  private let admit: @MainActor (_ includingAcceptedContact: Bool) -> DocumentLinkAdmission?
  private let deliver: @MainActor (DocumentLinkActivation, DocumentLinkAdmission) -> Void
  private let borrow: @MainActor () -> WebSurfaceBorrow?
  private var lastSequence: UInt64 = 0
  private struct Pending {
    let sequence: UInt64
    let admission: DocumentLinkAdmission
    let destination: DocumentLinkDestination
  }
  private var pending: Pending?
  // UIKit admits the contact before WebKit dispatches its pointer event. Keep
  // this single receipt through touch-up and delayed WebProcess IPC, never a
  // coordinate that could later be replayed against a different installation.
  private var nativePointerAdmission: DocumentLinkAdmission?
  @MainActor private struct Installation {
    let token = UUID()
    let origin: DocumentLinkOrigin
    let entryID: UUID
    let host: ObjectIdentifier
    let rect: CGRect
    let offset: CGFloat
    let size: CGSize
    func matches(_ origin: DocumentLinkOrigin, entryID: UUID, host: DocumentProgramOverlayHost, placement: DocumentProgramPlacement) -> Bool {
      self.origin.hasSamePresentation(as: origin) && self.entryID == entryID && self.host == ObjectIdentifier(host)
        && rect == placement.rect && offset == placement.sourceOffset && size == placement.fullSize
    }
  }
  private var installation: Installation?
  private var publishedInstallation: UUID?
  private var publishingInstallation = false

  init(controller: WKUserContentController,
    admit: @escaping @MainActor (_ includingAcceptedContact: Bool) -> DocumentLinkAdmission?,
    deliver: @escaping @MainActor (DocumentLinkActivation, DocumentLinkAdmission) -> Void,
    borrow: @escaping @MainActor () -> WebSurfaceBorrow?) {
    self.controller = controller; self.admit = admit; self.deliver = deliver; self.borrow = borrow
    super.init()
    controller.add(self, contentWorld: Self.world, name: Self.handler)
    controller.addUserScript(.init(source: Self.script, injectionTime: .atDocumentStart,
      forMainFrameOnly: true, in: Self.world))
  }

  func attach(_ webView: WKWebView) { self.webView = webView }

  func beginNativeContact() {
    pending = nil
    nativePointerAdmission = admit(true)
  }

  /// Correlation with already installed pixels, never input authority. A new
  /// native installation revokes the old cut before WebKit can see its token.
  func publishInstallation(origin: DocumentLinkOrigin?, entryID: UUID?, host: DocumentProgramOverlayHost?, placement: DocumentProgramPlacement?) {
    guard let origin, let entryID, let host, let placement, placement.webView === webView else {
      installation = nil; pending = nil; nativePointerAdmission = nil
      return
    }
    if installation?.matches(origin, entryID: entryID, host: host, placement: placement) != true {
      installation = .init(origin: origin, entryID: entryID, host: ObjectIdentifier(host), rect: placement.rect,
        offset: placement.sourceOffset, size: placement.fullSize)
      pending = nil; nativePointerAdmission = nil
    }
    publishCurrentInstallation()
  }

  private func publishCurrentInstallation() {
    guard !publishingInstallation, let installation, publishedInstallation != installation.token,
      let webView, let borrowed = borrow() else { return }
    publishingInstallation = true
    let token = installation.token
    webView.callAsyncJavaScript("return window.notebookInstallLinkOrigin(token);",
      arguments: ["token": token.uuidString], in: nil, in: Self.world) { [weak self, borrowed] result in
        borrowed.release()
        guard let self else { return }
        publishingInstallation = false
        if case .success(let value) = result, value as? String == token.uuidString { publishedInstallation = token }
        // Coalesce actual owner changes during this physical call. A failure
        // waits for the next existing installation event, never a timer retry.
        if self.installation?.token != token { publishCurrentInstallation() }
      }
  }

  func invalidate() {
    pending = nil; nativePointerAdmission = nil; installation = nil
    controller?.removeScriptMessageHandler(forName: Self.handler, contentWorld: Self.world)
    controller = nil; webView = nil
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard controller === self.controller, message.name == Self.handler, message.world === Self.world,
      message.frameInfo.isMainFrame, let webView, message.webView === webView,
      let body = message.body as? [String: Any], let kind = body["kind"] as? String,
      let text = body["sequence"] as? String, text.utf8.count <= 20,
      let sequence = UInt64(text), sequence > 0 else { return }
    switch kind {
    case "begin":
      guard sequence > lastSequence else { return }
      lastSequence = sequence; pending = nil
      // Both clocks belong to this device. The isolated realm supplies the
      // UA event time, not a renewed deadline at delayed IPC receipt. A wall
      // clock disagreement refuses the activation; expiry stays monotonic.
      let receivedAt = ContinuousClock.now
      guard let capturedAt = body["capturedAt"] as? Double, capturedAt.isFinite else { return }
      let age = Date().timeIntervalSince1970 - capturedAt / 1_000
      guard age.isFinite, (0...10).contains(age), let installation else { return }
      let admission: DocumentLinkAdmission?
      switch body["contact"] as? String {
      case "pointer":
        guard body["installation"] as? String == installation.token.uuidString,
          let accepted = nativePointerAdmission, accepted.origin.hasSamePresentation(as: installation.origin) else { return }
        admission = accepted; nativePointerAdmission = nil
      case "key", "accessibility":
        guard body["installation"] as? String == installation.token.uuidString,
          let current = admit(false), current.origin.hasSamePresentation(as: installation.origin) else { return }
        admission = current
      default: return
      }
      guard let href = body["href"] as? String, href.utf8.count <= 4_096,
        let admission, admission.admittedAt.duration(to: .now) <= .seconds(10),
        admission.isCurrent(), let layout = admission.origin.source.layout else { return }
      let token = installation.token
      pending = .init(sequence: sequence, admission: .init(origin: admission.origin,
        admittedAt: min(admission.admittedAt, receivedAt.advanced(by: .seconds(-age))), isCurrent: { [weak self] in
          self?.installation?.token == token && admission.isCurrent()
        }),
        destination: layout.destination(for: href))
    case "cancel":
      if pending?.sequence == sequence { pending = nil }
    case "activate":
      guard let accepted = pending, accepted.sequence == sequence else { return }
      pending = nil
      guard accepted.admission.admittedAt.duration(to: .now) <= .seconds(10),
        accepted.admission.isCurrent() else { return }
      deliver(.admitted(origin: accepted.admission.origin, destination: accepted.destination,
        admittedAt: accepted.admission.admittedAt, isCurrent: accepted.admission.isCurrent), accepted.admission)
    default: break
    }
  }

  /// This realm has its own intrinsics. No function, nonce or authority flag is
  /// placed in the author's global object or DOM. Capture precedes author code.
  private static let script = #"""
  (()=>{
    'use strict';
    const post=message=>webkit.messageHandlers.documentLinkActivation.postMessage(message);
    let sequence=0,pending=null,installation=null;
    const linkAt=event=>{
      const target=event.target;
      return target instanceof Element ? target.closest('a[href]') : null;
    };
    const cancel=()=>{
      if(pending){
        if(pending.terminal!==undefined)clearTimeout(pending.terminal);
        post({kind:'cancel',sequence:pending.sequence});
      }
      pending=null;
    };
    Object.defineProperty(window,'notebookInstallLinkOrigin',{value:token=>{
      if(token===undefined||token===installation)return installation;
      if(pending?.kind!=='pointer')cancel();
      installation=token;
      return installation;
    }});
    const begin=(link,kind,event)=>{
      cancel();
      const href=link?.getAttribute('href');
      const capturedAt=performance.timeOrigin+event.timeStamp;
      if(typeof href!=='string'||href.length>4096||!Number.isFinite(capturedAt)||sequence>=Number.MAX_SAFE_INTEGER)return;
      pending={link,kind,sequence:String(++sequence),began:performance.now(),
        pointer:event.pointerId,x:event.clientX,y:event.clientY,released:false};
      post({kind:'begin',sequence:pending.sequence,contact:kind,href,installation,capturedAt});
    };
    addEventListener('pointerdown',event=>{
      if(!event.isTrusted)return;
      if(!event.isPrimary||event.button!==0){cancel();return;}
      const link=linkAt(event);
      if(link)begin(link,'pointer',event);else cancel();
    },true);
    addEventListener('pointermove',event=>{
      if(!event.isTrusted||pending?.kind!=='pointer'||pending.pointer!==event.pointerId)return;
      if(Math.hypot(event.clientX-pending.x,event.clientY-pending.y)>12)cancel();
    },true);
    addEventListener('pointerup',event=>{
      if(!event.isTrusted||pending?.kind!=='pointer')return;
      if(pending.pointer!==event.pointerId||linkAt(event)!==pending.link){cancel();return;}
      pending.released=true;
    },true);
    addEventListener('pointercancel',event=>{if(event.isTrusted)cancel();},true);
    addEventListener('keydown',event=>{
      if(!event.isTrusted)return;
      if(event.key!=='Enter'||event.repeat){cancel();return;}
      const link=linkAt(event);
      if(link)begin(link,'key',event);else cancel();
    },true);
    addEventListener('keyup',event=>{
      if(event.isTrusted&&pending?.kind==='key'&&pending.terminal===undefined)cancel();
    },true);
    addEventListener('click',event=>{
      const link=linkAt(event);
      if(!link)return;
      if(!event.isTrusted)return;
      // A platform accessibility activation has no pointer/key sequence. Its
      // earliest trusted callback captures the destination before page code.
      if(!pending&&event.detail===0)begin(link,'accessibility',event);
      const accepted=pending;
      if(accepted?.terminal!==undefined)return;
      if(!accepted||accepted.link!==link||!link.isConnected||performance.now()-accepted.began>10000
        ||(accepted.kind==='pointer'&&!accepted.released)){cancel();return;}
      // Author handlers can accept state in this dispatch. Their descriptors
      // precede the next task's terminal message; a microtask can run between
      // real UI event listeners. Native then joins that same state owner.
      accepted.terminal=setTimeout(()=>{
        if(pending!==accepted)return;
        if(event.defaultPrevented){cancel();return;}
        pending=null;
        post({kind:'activate',sequence:accepted.sequence});
      },0);
    },true);
    // The native navigation delegate refuses WK loads. Author listeners keep
    // their event's original default state and may cancel the native action.
    addEventListener('blur',event=>{if(event.target===window)cancel();},true);
    addEventListener('pagehide',cancel,true);
    addEventListener('visibilitychange',()=>{if(document.hidden)cancel();},true);
  })();
  """#
}
#endif
