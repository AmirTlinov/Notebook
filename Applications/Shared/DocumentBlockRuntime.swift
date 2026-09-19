#if os(iOS)
import Foundation
import NotebookCore
import Observation
import UIKit
import WebKit

/// The executable identity of one document block. Physical paper cuts read or
/// mount this same viewport; snapshotting never changes its geometry or input.
@MainActor
final class DocumentBlockRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let documentID: UUID
  let block: DocumentBlock
  let sourceVersion: ContentFieldVersion
  let id = UUID()
  let resources: SceneRenderResources
  private(set) var webView: WKWebView?
  private(set) var ready = false
  private(set) var focused = false
  private(set) var value: JSONValue
  private(set) var failure: Error?
  private var lease: WebSurfaceLease?
  private var startTask: Task<Void, Never>?
  private var startID: UUID?
  private var requestedPriority: WebPriority?
  private var refusedAdmission: UInt64?
  private var readinessDeadline: Task<Void, Never>?
  private var captureTask: Task<RasterLease, Error>?
  private var captureID: UUID?
  private var queuedCaptures = 0
  private var stopped = false
  // A separate nonpersistent data store isolates every program. This base URL
  // supplies a secure browser origin without performing a network navigation.
  private let origin = URL(string: "https://document.notebook.invalid/")!
  private let programAssets = NotebookProgramAssets()
  private let programStore: NotebookStore?
  private var packageURL: URL?
  private var initialNavigationPending = false
  private var revision: UInt64 = 0
  private var presentedRevision: UInt64?
  private var appliedValue: JSONValue
  private var observedStateVersion: ContentFieldVersion?
  private var checkpointSelection: ProgramSemanticSelection?
  private var checkpointWasCaptured = false
  private var checkpointFrozen = false
  var attentionPauseID: UUID? {
    didSet { webView?.isUserInteractionEnabled = attentionPauseID == nil }
  }
  var hasFrozenFrame: Bool { checkpointFrozen && checkpointWasCaptured }
  var frozenSemanticSelection: ProgramSemanticSelection? { checkpointWasCaptured ? checkpointSelection : nil }
  private var checkpointTask: Task<JSONValue, Error>?
  var onChange: () -> Void = { }
  var onStateChange: (JSONValue) -> ContentFieldVersion? = { _ in nil }
  var onStateCheckpoint: (JSONValue, ContentFieldVersion?) async throws -> ContentFieldVersion? = { _, _ in nil }
  var requiresStateAcceptance = true
  var onFocus: (Bool) -> Void = { _ in }
  var onLink: (String) -> Void = { _ in }
  var onMount: (WKWebView, CGSize) -> Void = { _, _ in }
  private let size: CGSize
  var blockWidth: Double { size.width }

  func presents(_ value: JSONValue, version: ContentFieldVersion?) -> Bool {
    ready && failure == nil && presentedRevision == revision && appliedValue == value
      && (version.map { observedStateVersion?.includes($0) == true } ?? true)
  }

  init(documentID: UUID, block: DocumentBlock, sourceVersion: ContentFieldVersion,
    value: JSONValue, stateVersion: ContentFieldVersion?, width: Double, resources: SceneRenderResources, programStore: NotebookStore? = nil) {
    self.documentID = documentID; self.block = block; self.sourceVersion = sourceVersion
    self.value = value; appliedValue = value; observedStateVersion = stateVersion; self.resources = resources
    self.programStore = programStore
    size = .init(width: width, height: block.height)
    super.init()
  }

  func matches(_ block: DocumentBlock, sourceVersion: ContentFieldVersion, width: Double) -> Bool {
    self.sourceVersion == sourceVersion && self.block == block && abs(size.width - width) < 1 / 32
  }

  func offerReturnReclamation(_ reclaim: (@MainActor () -> Void)?) {
    if reclaim != nil { lease?.updatePriority(.neighbor); requestedPriority = .neighbor }
    lease?.offerIdleReclamation(reclaim)
  }

  func cancelReturnReclamation() { lease?.cancelIdleReclamation() }

  func start(priority: WebPriority) {
    guard !stopped else { return }
    if let lease { lease.updatePriority(priority); requestedPriority = priority; return }
    guard failure == nil else { return }
    if refusedAdmission == resources.webAdmissionGeneration { requestedPriority = priority; return }
    refusedAdmission = nil
    if startTask != nil {
      guard requestedPriority != priority else { return }
      startTask?.cancel(); startTask = nil
    }
    let request = UUID(); startID = request; requestedPriority = priority
    startTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let acquired = try await resources.acquireDocumentProgramSurface(priority: priority,
          documentID: documentID, blockID: block.id)
        guard !stopped, !Task.isCancelled, startID == request else { acquired.release(); return }
        lease = acquired
        let content = WKUserContentController(); content.add(self, name: "documentProgram")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent(); configuration.userContentController = content
        configuration.setURLSchemeHandler(programAssets, forURLScheme: NotebookProgramAssets.scheme)
        let web = WKWebView(frame: .init(origin: .zero, size: size), configuration: configuration)
        web.accessibilityIdentifier = "document-program-" + block.id
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.bounces = false; web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.pinchGestureRecognizer?.isEnabled = false; web.scrollView.panGestureRecognizer.isEnabled = false
        web.navigationDelegate = self; webView = web; onMount(web, size)
        if let hash = block.programPackage {
          guard let store = programStore else { throw SceneRenderError.snapshotPending("program_store") }
          let package = try await Task.detached(priority: .userInitiated) { try store.readProgramPackage(hash) }.value
          guard !stopped, !Task.isCancelled, startID == request, webView === web else { return }
          let url = try programAssets.register(store: store, package: package) { try html(package: package, resourceOrigin: $0) }
          packageURL = url; initialNavigationPending = true
          web.load(URLRequest(url: url))
        } else {
          let document = try html()
          initialNavigationPending = true
          web.loadHTMLString(document.before + block.html + document.after, baseURL: origin)
        }
        readinessDeadline = Task { @MainActor [weak self, weak web] in
          do { try await Task.sleep(for: .seconds(8)) } catch { return }
          guard let self, self.webView === web, !ready, !stopped, failure == nil else { return }
          fail(SceneRenderError.snapshotPending("document_program_readiness"))
        }
        if startID == request { startID = nil; startTask = nil }
      } catch {
        guard startID == request else { return }
        startID = nil; startTask = nil
        if error as? SceneRenderError == .resourceLimit {
          refusedAdmission = resources.webAdmissionGeneration
          withObservationTracking { _ = resources.webAdmissionGeneration } onChange: { [weak self] in
            Task { @MainActor [weak self] in
              guard let self, !stopped, let requestedPriority else { return }
              start(priority: requestedPriority)
            }
          }
        } else if !(error is CancellationError) { fail(error) }
      }
    }
  }

  func apply(_ next: JSONValue, stateVersion: ContentFieldVersion?) async throws {
    // Persistence publishes the checkpoint back through the document owner.
    // Let that same transaction accept its value before deciding whether this
    // is a newer external edit that must release the held frame.
    if let checkpointTask { _ = try? await checkpointTask.value }
    guard !Task.isCancelled, !stopped, let stateVersion, stateVersion != observedStateVersion else { return }
    if let observedStateVersion,
      observedStateVersion.includes(stateVersion), !stateVersion.includes(observedStateVersion) { return }
    if next == appliedValue { observedStateVersion = stateVersion; return }
    if attentionPauseID != nil {
      await resume()
      guard !Task.isCancelled, !stopped, stateVersion != observedStateVersion else { return }
      if let observedStateVersion,
        observedStateVersion.includes(stateVersion), !stateVersion.includes(observedStateVersion) { return }
    }
    guard ready, let webView, let lease else { return }
    let borrow = try lease.borrow(); defer { borrow.release() }
    let data = try JSONEncoder().encode(next)
    let argument = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    let expectedRevision = revision, basis = observedStateVersion
    let accepted = try await webView.callAsyncJavaScript("return await window.documentProgram.apply(value,revision);", arguments: ["value": argument, "revision": String(expectedRevision)], in: nil, contentWorld: .page)
    // A later accepted native commit wins even if WebKit's reply to the older
    // state application arrives after that commit's message.
    if accepted as? Bool == true, !stopped, self.webView === webView, revision == expectedRevision,
      observedStateVersion == basis {
      checkpointSelection = nil; checkpointWasCaptured = false; checkpointFrozen = false; attentionPauseID = nil
      value = next; appliedValue = next; observedStateVersion = stateVersion
      presentedRevision = revision; onChange()
    }
  }

  /// Suspends new commits before reading the exact explicit state. The caller
  /// must confirm persistence and window identity before allowing retirement.
  func checkpoint() async throws -> JSONValue {
    if let checkpointTask { return try await checkpointTask.value }
    let task = Task { @MainActor [self] in try await persistCheckpoint() }
    checkpointTask = task
    defer { checkpointTask = nil }
    return try await task.value
  }

  private func persistCheckpoint() async throws -> JSONValue {
    guard ready, !focused, let webView, let lease else { throw CancellationError() }
    let borrow = try lease.borrow(); defer { borrow.release() }
    let basis = observedStateVersion, expectedRevision = revision
    let next = try await NotebookProgramBridge.lifecycle("checkpoint", controller: "documentProgram", in: webView)
    guard !stopped, self.webView === webView, !Task.isCancelled,
      observedStateVersion == basis, revision == expectedRevision else { throw CancellationError() }
    guard let accepted = try await onStateCheckpoint(next, basis) else {
      throw NotebookProgramCheckpointError.superseded
    }
    guard !stopped, self.webView === webView, !Task.isCancelled, revision == expectedRevision,
      observedStateVersion == basis || observedStateVersion == accepted else { throw CancellationError() }
    let selected = await NotebookProgramBridge.semanticSelection(controller: "documentProgram", in: webView)
    guard !stopped, self.webView === webView, !Task.isCancelled, revision == expectedRevision,
      observedStateVersion == basis || observedStateVersion == accepted else { throw CancellationError() }
    checkpointSelection = selected; checkpointWasCaptured = false; checkpointFrozen = true
    value = next; appliedValue = next; observedStateVersion = accepted
    return next
  }

  func resume() async {
    checkpointSelection = nil; checkpointWasCaptured = false; checkpointFrozen = false; attentionPauseID = nil
    if let webView { _ = try? await NotebookProgramBridge.lifecycle("resume", controller: "documentProgram", in: webView) }
    onChange()
  }

  func blur() async { _ = try? await webView?.evaluateJavaScript("document.activeElement?.blur();true") }

  func capture(sourceOffset: Double, height: Double, pixelWidth: Int,
    reservation granted: RasterReservation? = nil) async throws -> RasterLease {
    guard queuedCaptures < 4 else { throw SceneRenderError.resourceLimit }
    queuedCaptures += 1
    let preceding = captureTask, operation = UUID()
    let task = Task { @MainActor [weak self] () throws -> RasterLease in
      if let preceding { _ = try? await preceding.value }
      try Task.checkCancellation()
      guard let self, ready, !stopped, let web = webView, let lease else {
        throw SceneRenderError.snapshotPending("document_program")
      }
      let expectedRevision = revision
      let rect = CGRect(x: 0, y: sourceOffset, width: size.width, height: height)
      guard size.width > 0, height > 0, CGRect(origin: .zero, size: size).contains(rect) else {
        throw DocumentSessionError.invalidLayout
      }
      let pixelHeight = Int(ceil(Double(pixelWidth) * height / size.width))
      guard let reservation = granted ?? resources.reserveRaster(pixelWidth: pixelWidth, pixelHeight: pixelHeight),
        resources.ownsRasterReservation(reservation, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else { throw SceneRenderError.resourceLimit }
      let borrow = try lease.borrow()
      defer { borrow.release(); reservation.release() }
      let configuration = WKSnapshotConfiguration(); configuration.rect = rect; configuration.afterScreenUpdates = true
      configuration.snapshotWidth = NSNumber(value: Double(pixelWidth) / (web.window?.screen.scale ?? 2))
      let image = try await web.takeSnapshot(configuration: configuration)
      guard !stopped, self.webView === web, revision == expectedRevision,
        let cg = image.cgImage else { throw CancellationError() }
      let normalized = UIImage(cgImage: cg, scale: Double(cg.width) / size.width, orientation: .up)
      let source = SceneRasterSource.document(id: documentID, token: "program:\(block.id):\(id):\(operation)")
      guard let raster = resources.storeAndRetain(normalized, for: source, reservation: reservation,
        semanticSelection: checkpointSelection?.mapped(from: .init(x: 0, y: 0, width: size.width, height: size.height),
          into: .init(x: 0, y: sourceOffset, width: size.width, height: height))) else { throw SceneRenderError.resourceLimit }
      if checkpointFrozen { checkpointWasCaptured = true }
      return raster
    }
    captureTask = task; captureID = operation
    defer {
      queuedCaptures -= 1
      if captureID == operation { captureTask = nil; captureID = nil }
    }
    return try await task.value
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard !stopped, message.webView === webView, let body = message.body as? [String: Any], body["runtimeID"] as? String == id.uuidString else { return }
    switch body["kind"] as? String {
    case "ready":
      guard failure == nil else { return }
      readinessDeadline?.cancel(); readinessDeadline = nil
      ready = true
      if let value = body["revision"] as? String, UInt64(value) == revision { presentedRevision = revision }
      onChange()
    case "presented":
      if let value = body["revision"] as? String, UInt64(value) == revision {
        presentedRevision = revision; onChange()
      }
    case "state":
      guard let data = try? JSONSerialization.data(withJSONObject: body["value"] ?? NSNull(), options: [.fragmentsAllowed]),
        let next = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
      value = next; appliedValue = next; revision &+= 1
      if let accepted = onStateChange(next) { observedStateVersion = accepted }
      else if requiresStateAcceptance {
        fail(SceneRenderError.snapshotPending("document_state_not_accepted"))
      }
    case "focus": focused = body["value"] as? Bool == true; onFocus(focused)
    case "link": if body["userActivated"] as? Bool == true, let href = body["href"] as? String { onLink(href) }
    case "failure": fail(SceneRenderError.snapshotPending(body["message"] as? String ?? "document_program"))
    default: break
    }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard self.webView === webView else { return }
    ready = false; focused = false; revision = 0; presentedRevision = nil; onFocus(false)
    releaseSurface(); failure = nil; start(priority: .liveProgram); onChange()
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    let url = navigationAction.request.url
    let initial = self.webView === webView && initialNavigationPending
      && navigationAction.navigationType == .other && (url == (packageURL ?? origin) || url?.absoluteString == "about:blank")
    if initial { initialNavigationPending = false }
    decisionHandler(initial ? .allow : .cancel)
  }

  func retry() {
    guard failure != nil else { return }
    ready = false; failure = nil; revision = 0; presentedRevision = nil; releaseSurface(); start(priority: .input)
  }

  func stop() { stopped = true; checkpointTask?.cancel(); checkpointTask = nil; startTask?.cancel(); startTask = nil; startID = nil; releaseSurface() }
  private func fail(_ error: Error) {
    failure = error; ready = false; focused = false; presentedRevision = nil
    // A failed program keeps its accepted explicit state, not a broken slot
    // which could starve every healthy neighbour. Retry owns a fresh executor.
    releaseSurface(); onFocus(false); onChange()
  }
  private func releaseSurface() {
    checkpointSelection = nil; checkpointWasCaptured = false; checkpointFrozen = false; attentionPauseID = nil
    programAssets.revokeAll(); packageURL = nil
    readinessDeadline?.cancel(); readinessDeadline = nil
    initialNavigationPending = false
    webView?.evaluateJavaScript("void documentProgram.dispose().catch(()=>{})", completionHandler: nil)
    webView?.stopLoading(); webView?.navigationDelegate = nil
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "documentProgram")
    if let webView {
      var ancestor = webView.superview
      while let view = ancestor {
        if let overlay = view as? DocumentProgramOverlayHost { overlay.removeProgram(webView); break }
        ancestor = view.superview
      }
      webView.removeFromSuperview()
    }
    webView = nil; lease?.release(); lease = nil
  }
  isolated deinit { startTask?.cancel(); releaseSurface() }

  private func html(package: NotebookProgramPackage? = nil, resourceOrigin: URL? = nil) throws -> NotebookProgramAssets.Document {
    func encoded<T: Encodable>(_ value: T) throws -> String {
      String(decoding: try JSONEncoder().encode(value), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }
    let css = block.css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
    let policy = resourceOrigin.map(NotebookProgramAssets.policy) ?? "default-src 'none';img-src data: blob:;style-src 'unsafe-inline';script-src 'unsafe-inline';font-src data:;media-src data: blob:;connect-src 'none';form-action 'none';base-uri 'none';object-src 'none'"
    let style = package.flatMap { package in resourceOrigin.map { NotebookProgramAssets.style(package, origin: $0) } } ?? ""
    let entry = package.flatMap { package in resourceOrigin.map { NotebookProgramAssets.script(package, origin: $0) } } ?? ""
    let inline = package == nil ? "addEventListener('DOMContentLoaded',()=>{try{const script=document.createElement('script');script.textContent=\(try encoded(block.javaScript));document.body.append(script)}catch(error){post('failure',{message:String(error)})}});" : ""
    return .init(before: """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,minimum-scale=1,maximum-scale=1,user-scalable=no">
    <meta http-equiv="Content-Security-Policy" content="\(policy)">
    <style>html,body{margin:0;min-height:100%;background:transparent;color:#171713;font-family:-apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}\(css)</style>\(style)<script>(()=>{
      \(NotebookProgramBridge.script)
      const runtimeID=\(try encoded(id.uuidString));
      const post=(kind,extra={})=>webkit.messageHandlers.documentProgram.postMessage({runtimeID,kind,...extra});
      const painted=()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
      const present=async expected=>{await painted();if(documentProgram.revision===expected)post('presented',{revision:expected})};
      const focus=()=>post('focus',{value:!!document.activeElement?.matches('input,textarea,[contenteditable=true]')});
      addEventListener('focusin',focus);addEventListener('focusout',()=>queueMicrotask(focus));
      addEventListener('click',event=>{const link=event.target.closest('a[href]');if(!link)return;event.preventDefault();post('link',{href:link.getAttribute('href'),userActivated:event.isTrusted})});
      addEventListener('error',event=>post('failure',{message:String(event.error || event.message)}));
      addEventListener('unhandledrejection',event=>post('failure',{message:String(event.reason)}));
      window.documentProgram=createNotebookProgram({state:\(try encoded(value)),paint:painted,
        onCommit:(value,revision)=>{post('state',{value,revision});present(revision)},
        report:(kind,message)=>{if(!['program_lifecycle_error','program_semantic_unavailable'].includes(kind))post('failure',{message:kind+': '+message})}});
      window.notebook=documentProgram.api;
      addEventListener('load',async()=>{try{
        await document.fonts.ready;
        await Promise.all([...document.images].map(image=>image.decode()));
        const receipt=await documentProgram.start({requiresReady:\(block.programPackage != nil || !block.javaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || block.html.localizedCaseInsensitiveContains("<script"))});
        post('ready',receipt);
      }catch(error){post('failure',{message:String(error)})}});
      \(inline)
    })()</script></head><body>
    """, after: "\(entry)</body></html>")
  }
}
#endif
