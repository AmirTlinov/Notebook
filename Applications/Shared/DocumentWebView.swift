import NotebookCore
import SwiftUI
import WebKit

@MainActor
final class DocumentSnapshotCache {
    static let shared = DocumentSnapshotCache()
    static let didChange = Notification.Name("NotebookDocumentSnapshotDidChange")
    func image(for document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int, minimumScale: Double = 0) -> AgentSnapshotImage? {
      SceneRenderResources.shared.image(for: .document(id: document.id,
        token: Self.token(document: document, state: state, pageIndex: pageIndex)), minimumScale: minimumScale)
    }

    @discardableResult
    func store(image: AgentSnapshotImage, documentID: UUID, token: String, reservation: RasterReservation? = nil,
      resources: SceneRenderResources = .shared) -> Bool {
      if resources.store(image, for: .document(id: documentID, token: token), reservation: reservation) {
        NotificationCenter.default.post(name: Self.didChange, object: documentID)
        return true
      }
      return false
    }

    #if os(macOS)
    func prepare(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int) async throws -> RasterLease {
      let source = SceneRasterSource.document(id: document.id,
        token: Self.token(document: document, state: state, pageIndex: pageIndex))
      let requiredScale = Double(NSScreen.main?.backingScaleFactor ?? 2)
      if let lease = SceneRenderResources.shared.retainRaster(for: source, minimumScale: requiredScale) { return lease }
      let ready = PageTurnReadiness { _ in }
      let coordinator = DocumentWebCoordinator(onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _,_ in }, onStateChange: { _,_ in })
      let host = DocumentWebHost()
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: geometry.width, height: geometry.height),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
      defer { coordinator.invalidate(); window.orderOut(nil); window.close() }
      coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: true,
        onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _,_ in }, onStateChange: { _,_ in })
      coordinator.mount(in: host, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: false, priority: .background)
      let deadline = ContinuousClock.now + .seconds(8)
      while true {
        try Task.checkCancellation()
        if let lease = SceneRenderResources.shared.retainRaster(for: source, minimumScale: requiredScale) { return lease }
        if let error = coordinator.acquisitionError { throw error }
        guard ContinuousClock.now < deadline else { throw DocumentPreparationError.pending }
        try await Task.sleep(for: .milliseconds(20))
      }
    }

    enum DocumentPreparationError: Error { case pending }
    #endif

    nonisolated static func token(
      document: DocumentDocument,
      state: DocumentStateJournal,
      pageIndex: Int
    ) -> String {
      precondition(document.id == state.id)
      precondition(pageIndex >= 0)
      return
        "\(document.contentStamp.counter)@\(document.contentStamp.actor.uuidString.lowercased())|\(state.stamp.counter)@\(state.stamp.actor.uuidString.lowercased())|page:\(pageIndex)"
    }
  }

struct DocumentPageLayout: Equatable, Sendable {
  let pageCount: Int

  init(pageCount: Int) {
    self.pageCount = max(1, pageCount)
  }
}

struct DocumentWebView: View {
  let document: DocumentDocument
  let state: DocumentStateJournal
  let isInteractive: Bool
  let selectedPageIndex: Int
  let capturesSnapshot: Bool
  let onRenderReady: PageTurnReadiness
  let onPageLayout: (DocumentPageLayout) -> Void
  let onSourceChange: (String, String) -> Void
  let onStateChange: (String, JSONValue) -> Void
  var resources: SceneRenderResources = .shared

  var body: some View {
    PlatformDocumentWebView(
      document: document,
      state: state,
      isInteractive: isInteractive,
      selectedPageIndex: selectedPageIndex,
      capturesSnapshot: capturesSnapshot,
      onRenderReady: onRenderReady,
      onPageLayout: onPageLayout,
      onSourceChange: onSourceChange,
      onStateChange: onStateChange,
      resources: resources
    )
    .accessibilityIdentifier("document-runtime")
  }
}

/// A page preview uses the document renderer once, then owns only its exact
/// source/page raster. It never competes indefinitely with live curl pages.
struct DocumentThumbnailView: View {
  let document: DocumentDocument
  let state: DocumentStateJournal
  let pageIndex: Int
  let onRenderReady: PageTurnReadiness
  var resources: SceneRenderResources = .shared
  var onFailure: (Error) -> Void = { _ in }

  var body: some View {
    PlatformDocumentWebView(document: document, state: state, isInteractive: false,
      selectedPageIndex: pageIndex, capturesSnapshot: true, onRenderReady: onRenderReady,
      onPageLayout: { _ in }, onSourceChange: { _,_ in }, onStateChange: { _,_ in },
      resources: resources, snapshotPixelWidth: 256, onPreparationFailure: onFailure)
      .accessibilityHidden(true)
  }
}

struct DocumentRuntimePayload: Codable {
  struct Paper: Codable {
    let kind: DocumentPaperSize
    let widthPoints: Double
    let heightPoints: Double
    let marginPoints: Double
    let cornerRadiusRatio: Double

    init(_ size: DocumentPaperSize) {
      kind = size
      widthPoints = size.widthPoints
      heightPoints = size.heightPoints
      marginPoints = size.marginPoints
      let geometry = WorkspaceItemGeometry.document(size)
      cornerRadiusRatio = geometry.cornerRadius / geometry.width
    }
  }

  let documentID: UUID
  let paper: Paper
  let blocks: [DocumentBlock]
  let states: [String: JSONValue]
  let editable: Bool
  let renderToken: String

  init(
    document: DocumentDocument,
    state: DocumentStateJournal,
    editable: Bool,
    selectedPageIndex: Int
  ) {
    documentID = document.id
    paper = Paper(document.paperSize)
    blocks = document.blocks
    states = Dictionary(
      uniqueKeysWithValues: state.records.map { ($0.id, $0.value) }
    )
    self.editable = editable
    renderToken = DocumentSnapshotCache.token(document: document, state: state, pageIndex: selectedPageIndex)
  }
}

struct DocumentRuntimePayloadKey: Equatable {
  let documentID: UUID
  let contentStamp: VersionStamp
  let stateStamp: VersionStamp
  let snapshotPageIndex: Int

  init(
    document: DocumentDocument,
    state: DocumentStateJournal,
    selectedPageIndex: Int
  ) {
    documentID = document.id
    contentStamp = document.contentStamp
    stateStamp = state.stamp
    snapshotPageIndex = selectedPageIndex
  }
}

@MainActor
final class DocumentWebCoordinator: NSObject,
  WKNavigationDelegate,
  WKScriptMessageHandler
{
  private let resources: SceneRenderResources
  private var surfaceLease: WebSurfaceLease?
  private var acquisitionTask: Task<Void, Never>?
  private var acquisitionID: UUID?
  private var requestedPriority: WebPriority?
  private weak var host: DocumentWebHost?
  private(set) var isInvalidated = false
  private(set) var acquisitionError: Error?
  private(set) var acceptsInput = false
  private var physicalSize = CGSize(width: 1, height: 1)
  private var generation: UInt64 = 0
  private var fallbackSource: SceneRasterSource?
  private var snapshotPixelWidth: Int?
  private var snapshotOnlyComplete = false
  private var snapshotCaptureID: UUID?
  private var onPreparationFailure: (Error) -> Void = { _ in }

  func mount(in host: DocumentWebHost, physicalSize: CGSize, isInteractive: Bool, priority: WebPriority) {
    guard !isInvalidated else { return }
    self.host = host
    self.physicalSize = physicalSize
    acceptsInput = isInteractive
    host.configure(size: physicalSize, interactive: isInteractive)
    if let snapshotPixelWidth, host.showFallback(source: fallbackSource, resources: resources,
      minimumScale: Double(snapshotPixelWidth) / max(1, physicalSize.width)) {
      snapshotOnlyComplete = true
      acquisitionError = nil
      releaseWebSurface()
      setRenderReady(true)
      onRenderReady(true)
      return
    }
    if snapshotPixelWidth != nil, let acquisitionError {
      onPreparationFailure(acquisitionError)
      return
    }
    if !renderIsReady { host.showFallback(source: fallbackSource, resources: resources) }
    if webView != nil { surfaceLease?.updatePriority(priority); requestedPriority = priority; return }
    guard acquisitionTask == nil || requestedPriority != priority else { return }
    acquisitionTask?.cancel()
    let id = UUID()
    acquisitionID = id
    requestedPriority = priority
    acquisitionError = nil
    onRenderReady(false)
    let resources = resources
    acquisitionTask = Task { [weak self] in
      do {
        let lease = try await resources.acquireWebSurface(priority: priority)
        guard let self, !Task.isCancelled, !isInvalidated, acquisitionID == id, let host = self.host else {
          lease.release(); return
        }
        acquisitionTask = nil
        surfaceLease = lease
        let web = DocumentWebViewFactory.make(coordinator: self, lease: lease)
        host.install(web, size: self.physicalSize)
        host.configure(size: self.physicalSize, interactive: acceptsInput)
      } catch {
        guard let self, !isInvalidated, acquisitionID == id else { return }
        acquisitionTask = nil
        failPreparation(error)
      }
    }
  }

  /// The resource and all callbacks belong to this one mounted lifetime.
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    generation &+= 1
    acquisitionID = nil
    acquisitionTask?.cancel(); acquisitionTask = nil
    acceptsInput = false
    isReady = false
    renderIsReady = false
    pageIndexRequestID = nil
    pendingSnapshotPayload = nil
    snapshotCaptureID = nil
    preparedSnapshotLease?.release(); preparedSnapshotLease = nil
    onRenderReady(false)
    onRenderReady = .init { _ in }
    onPageLayout = { _ in }; onSourceChange = { _,_ in }; onStateChange = { _,_ in }
    onPreparationFailure = { _ in }
    releaseWebSurface()
    host?.removeFallback()
  }

  private func failPreparation(_ error: Error) {
    guard !isInvalidated else { return }
    acquisitionError = error
    if snapshotPixelWidth != nil {
      releaseWebSurface()
      setRenderReady(false)
      onRenderReady(false)
    }
    onPreparationFailure(error)
  }

  private func releaseWebSurface() {
    acquisitionID = nil
    acquisitionTask?.cancel(); acquisitionTask = nil
    snapshotCaptureID = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
    webView?.navigationDelegate = nil
    host?.removeSurface()
    webView = nil
    isReady = false
    lastAppliedData = nil
    renderedToken = nil
    appliedPageIndex = nil
    pageIndexRequestID = nil
    surfaceLease?.release(); surfaceLease = nil
  }

  isolated deinit {
    acquisitionTask?.cancel()
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
    webView?.navigationDelegate = nil
    surfaceLease?.release()
    preparedSnapshotLease?.release()
  }

  weak var webView: WKWebView?
  var isReady = false
  var payload: DocumentRuntimePayload?
  var payloadKey: DocumentRuntimePayloadKey?
  var lastAppliedData: Data?
  var requestedPageIndex: Int?
  var appliedPageIndex: Int?
  var pageIndexRequestID: UUID?
  var renderedToken: String?
  var pageCount = 1
  var capturesSnapshot = false
  var renderIsReady = false
  var onRenderReady: PageTurnReadiness
  var onPageLayout: (DocumentPageLayout) -> Void
  var onSourceChange: (String, String) -> Void
  var onStateChange: (String, JSONValue) -> Void
  var pendingSnapshotPayload: DocumentRuntimePayload?
  private var preparedSnapshotLease: RasterLease?

  init(
    resources: SceneRenderResources = .shared,
    onRenderReady: PageTurnReadiness,
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onSourceChange: @escaping (String, String) -> Void,
    onStateChange: @escaping (String, JSONValue) -> Void
  ) {
    self.resources = resources
    self.onRenderReady = onRenderReady
    self.onPageLayout = onPageLayout
    self.onSourceChange = onSourceChange
    self.onStateChange = onStateChange
  }

  func update(
    document: DocumentDocument,
    state: DocumentStateJournal,
    selectedPageIndex: Int,
    capturesSnapshot: Bool,
    onRenderReady: PageTurnReadiness,
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onSourceChange: @escaping (String, String) -> Void,
    onStateChange: @escaping (String, JSONValue) -> Void,
    snapshotPixelWidth: Int? = nil,
    onPreparationFailure: @escaping (Error) -> Void = { _ in }
  ) {
    guard !isInvalidated else { return }
    self.onRenderReady = onRenderReady
    self.onPageLayout = onPageLayout
    self.onSourceChange = onSourceChange
    self.onStateChange = onStateChange
    self.snapshotPixelWidth = snapshotPixelWidth.map { min(256, max(1, $0)) }
    self.onPreparationFailure = onPreparationFailure
    let nextPageIndex = max(0, selectedPageIndex)
    let pageChanged = requestedPageIndex != nextPageIndex
    requestedPageIndex = nextPageIndex
    if pageChanged {
      pageIndexRequestID = nil
      appliedPageIndex = nil
    }
    #if os(macOS)
      self.capturesSnapshot = capturesSnapshot
    #else
      // Live iPad pages belong to the curl. Only explicit previews prepare a
      // raster; landing a page must not start an unrelated full-size capture.
      self.capturesSnapshot = capturesSnapshot && snapshotPixelWidth != nil
    #endif
    let nextKey = DocumentRuntimePayloadKey(
      document: document,
      state: state,
      selectedPageIndex: selectedPageIndex
    )
    if payloadKey != nextKey {
      generation &+= 1
      snapshotCaptureID = nil
      snapshotOnlyComplete = false
      acquisitionError = nil
      preparedSnapshotLease?.release(); preparedSnapshotLease = nil
      host?.removeFallback()
      setRenderReady(false)
      pageIndexRequestID = nil
      appliedPageIndex = nil
      renderedToken = nil
      pageCount = 1
      payloadKey = nextKey
      payload = DocumentRuntimePayload(
        document: document,
        state: state,
        editable: true,
        selectedPageIndex: selectedPageIndex
      )
      applyIfReady()
    } else if pageChanged {
      setRenderReady(false)
    }
    fallbackSource = .document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: selectedPageIndex))
    pendingSnapshotPayload = self.capturesSnapshot && !snapshotOnlyComplete ? payload : nil
    applyPageIndexIfReady()
    onRenderReady(renderIsReady && (snapshotPixelWidth == nil || snapshotOnlyComplete))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !isInvalidated, self.webView === webView else { return }
    isReady = true
    applyIfReady()
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard !isInvalidated, self.webView === webView, let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(
      url.isFileURL || url.scheme == "about" ? .allow : .cancel
    )
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "notebook", let source = message.webView,
      let body = message.body as? [String: Any] else { return }
    receive(body: body, from: source)
  }

  func receive(body: [String: Any], from source: WKWebView) {
    guard !isInvalidated, source === webView, let kind = body["kind"] as? String else { return }

    if kind == "ready" {
      isReady = true
      applyIfReady()
      return
    }
    guard let documentID = body["documentID"] as? String,
      let payload,
      documentID.caseInsensitiveCompare(payload.documentID.uuidString) == .orderedSame
    else { return }
    if kind == "rendered" {
      guard let renderToken = body["renderToken"] as? String,
        renderToken == payload.renderToken
      else { return }
      renderedToken = renderToken
      if let pageCount = (body["pageCount"] as? NSNumber)?.intValue {
        self.pageCount = max(1, pageCount)
        onPageLayout(
          DocumentPageLayout(pageCount: pageCount)
        )
      }
      appliedPageIndex = nil
      pendingSnapshotPayload = capturesSnapshot ? payload : nil
      applyPageIndexIfReady()
      #if os(macOS)
        capturePendingSnapshotIfReady()
      #endif
      return
    }
    // A current interactive block may commit during its initial execution,
    // before pagination presents the first frame. Frame readiness is not write
    // authority; this exact active runtime, owner and token are.
    guard acceptsInput,
      body["renderToken"] as? String == payload.renderToken,
      let blockID = body["blockID"] as? String,
      payload.blocks.contains(where: { $0.id == blockID }) else { return }
    switch kind {
    case "source":
      guard let source = body["source"] as? String else { return }
      onSourceChange(blockID, source)
    case "state":
      guard let value = body["value"],
        JSONSerialization.isValidJSONObject(["value": value]),
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
      else { return }
      onStateChange(blockID, decoded)
    default:
      return
    }
  }

  private func applyIfReady() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard !isInvalidated, isReady, let webView, let payload,
      let data = try? encoder.encode(payload),
      data != lastAppliedData,
      let json = String(data: data, encoding: .utf8)
    else { return }
    lastAppliedData = data
    // Completion belongs to the rendered receipt; evaluating the JavaScript
    // Promise itself produces an unsupported-result error in WebKit.
    webView.evaluateJavaScript(
      "void window.notebookRenderer.apply(\(json))"
    ) { [weak self] _, error in
      guard error != nil else { return }
      Task { @MainActor [weak self] in
        guard let self, !isInvalidated, lastAppliedData == data else { return }
        lastAppliedData = nil
      }
    }
  }

  private func applyPageIndexIfReady() {
    guard !isInvalidated, isReady, pageIndexRequestID == nil,
      let webView,
      let payload,
      renderedToken == payload.renderToken,
      let requestedPageIndex,
      appliedPageIndex != requestedPageIndex
    else { return }

    let value = min(max(0, requestedPageIndex), max(0, pageCount - 1))
    let requestID = UUID()
    let expectedGeneration = generation
    let expectedDocumentID = payload.documentID.uuidString
    let expectedRenderToken = payload.renderToken
    pageIndexRequestID = requestID
    webView.callAsyncJavaScript(
      """
      window.notebookRenderer.setPageIndex(index);
      await new Promise(resolve => requestAnimationFrame(
        () => requestAnimationFrame(resolve)
      ));
      return window.notebookRenderer.pageReceipt();
      """,
      arguments: ["index": value],
      in: nil,
      in: .page,
      completionHandler: { [weak self] result in
        guard let self, !isInvalidated, generation == expectedGeneration,
          pageIndexRequestID == requestID else { return }
        pageIndexRequestID = nil
        guard case .success(let rawReceipt) = result,
          let receipt = rawReceipt as? NSDictionary,
          let receiptDocumentID = receipt["documentID"] as? String,
          receiptDocumentID.caseInsensitiveCompare(expectedDocumentID)
            == .orderedSame,
          let receiptRenderToken = receipt["renderToken"] as? String,
          receiptRenderToken == expectedRenderToken,
          let receiptPage = (receipt["pageIndex"] as? NSNumber)?.intValue,
          receiptPage == value
        else {
          appliedPageIndex = nil
          setRenderReady(false)
          return
        }
        DocumentRenderRegistry.shared.publish(documentID: payload.documentID, token: payload.renderToken, receipt: receipt,
          geometry: .document(payload.paper.kind))
        appliedPageIndex = receiptPage
        setRenderReady(requestedPageIndex == receiptPage)
        applyPageIndexIfReady()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
          self?.capturePendingSnapshotIfReady()
        }
      }
    )
  }

  private func setRenderReady(_ ready: Bool) {
    guard !isInvalidated, renderIsReady != ready else { return }
    renderIsReady = ready
    if ready, snapshotPixelWidth == nil { host?.removeFallback() }
    onRenderReady(ready && (snapshotPixelWidth == nil || snapshotOnlyComplete))
  }

    private func capturePendingSnapshotIfReady() {
      guard !isInvalidated, capturesSnapshot, !snapshotOnlyComplete, snapshotCaptureID == nil, pageIndexRequestID == nil,
        let payload = pendingSnapshotPayload
      else { return }
      if let requestedPageIndex {
        guard appliedPageIndex == requestedPageIndex
        else { return }
      }
      pendingSnapshotPayload = nil
      captureSnapshot(for: payload)
    }

    private func captureSnapshot(
      for payload: DocumentRuntimePayload,
      remainingAttempts: Int = 4
    ) {
      guard !isInvalidated, let webView,
        self.payload?.documentID == payload.documentID,
        self.payload?.renderToken == payload.renderToken
      else { return }
      guard webView.bounds.width > 1, webView.bounds.height > 1 else {
        guard remainingAttempts > 0 else {
          failPreparation(SceneRenderError.snapshotPending(payload.documentID.uuidString)); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
          self?.captureSnapshot(
            for: payload,
            remainingAttempts: remainingAttempts - 1
          )
        }
        return
      }
      #if os(iOS)
        let scale = webView.window?.screen.scale ?? 2
      #else
        let scale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
      #endif
      let physicalSize = webView.bounds.size
      let pixelsWide = snapshotPixelWidth ?? Int(ceil(physicalSize.width * scale))
      let pixelsHigh = Int(ceil(Double(pixelsWide) * physicalSize.height / physicalSize.width))
      guard let reservation = resources.reserveRaster(pixelWidth: pixelsWide, pixelHeight: pixelsHigh) else {
        failPreparation(SceneRenderError.resourceLimit)
        return
      }
      let snapshotGeneration = generation, captureID = UUID()
      snapshotCaptureID = captureID
      let configuration = WKSnapshotConfiguration()
      configuration.afterScreenUpdates = true
      if snapshotPixelWidth != nil { configuration.snapshotWidth = NSNumber(value: Double(pixelsWide) / scale) }
      webView.takeSnapshot(with: configuration) { [weak self] image, _ in
        Task { @MainActor [weak self] in
          defer { reservation.release() }
          guard let self, !isInvalidated, generation == snapshotGeneration, snapshotCaptureID == captureID,
            self.payload?.documentID == payload.documentID,
            self.payload?.renderToken == payload.renderToken
          else { return }
          snapshotCaptureID = nil
          guard let image else { failPreparation(SceneRenderError.snapshotPending(payload.documentID.uuidString)); return }
          // The cache scale is relative to physical paper, not the tiny native
          // image view. A thumbnail can never satisfy an exact export request.
          #if os(iOS)
            guard let cgImage = image.cgImage else { failPreparation(SceneRenderError.resourceLimit); return }
            let rasterScale = snapshotPixelWidth == nil ? scale : Double(cgImage.width) / physicalSize.width
            let normalized = UIImage(cgImage: cgImage, scale: rasterScale, orientation: .up)
          #else
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
              failPreparation(SceneRenderError.resourceLimit); return
            }
            let rasterScale = snapshotPixelWidth == nil ? scale : Double(cgImage.width) / physicalSize.width
            image.size = .init(width: Double(cgImage.width) / rasterScale, height: Double(cgImage.height) / rasterScale)
            let normalized = image
          #endif
          let source = SceneRasterSource.document(id: payload.documentID, token: payload.renderToken)
          if !DocumentSnapshotCache.shared.store(image: normalized, documentID: payload.documentID,
            token: payload.renderToken, reservation: reservation, resources: resources) {
            failPreparation(SceneRenderError.resourceLimit)
          } else if snapshotPixelWidth != nil {
            guard host?.showFallback(source: source, resources: resources) == true else {
              failPreparation(SceneRenderError.resourceLimit); return
            }
            snapshotOnlyComplete = true
            releaseWebSurface()
            onRenderReady(true)
          } else if requestedPriority == .background {
            preparedSnapshotLease?.release()
            preparedSnapshotLease = resources.retainRaster(for: source)
          }
        }
      }
    }
}

private enum DocumentWebViewFactory {
  @MainActor
  static func make(coordinator: DocumentWebCoordinator, lease: WebSurfaceLease) -> WKWebView {
    precondition(!lease.isReleased)
    let content = WKUserContentController()
    content.add(coordinator, name: "notebook")
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = content
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true

    let webView = WKWebView(frame: .zero, configuration: configuration)
    coordinator.webView = webView
    webView.navigationDelegate = coordinator
    #if os(iOS)
      webView.isOpaque = false
      webView.backgroundColor = .clear
      webView.scrollView.backgroundColor = .clear
      webView.scrollView.bounces = false
      webView.scrollView.contentInsetAdjustmentBehavior = .never
      webView.scrollView.pinchGestureRecognizer?.isEnabled = false
      webView.scrollView.panGestureRecognizer.isEnabled = false
    #elseif os(macOS)
      webView.allowsMagnification = false
    #endif

    if let shellURL = Bundle.main.url(
      forResource: "document-shell",
      withExtension: "html",
      subdirectory: "WebResources"
    )
      ?? Bundle.main.url(
        forResource: "document-shell",
        withExtension: "html"
      )
    {
      webView.loadFileURL(
        shellURL,
        allowingReadAccessTo: shellURL.deletingLastPathComponent()
      )
    } else {
      webView.loadHTMLString(
        "<html><body>Document runtime is missing.</body></html>",
        baseURL: nil
      )
    }
    return webView
  }
}

#if os(iOS)
  @MainActor
  final class DocumentWebHost: UIView {
    private var viewport: PhysicalWebViewport?
    private var fallback: UIImageView?
    private var fallbackLease: RasterLease?
    private var fallbackSource: SceneRasterSource?
    var hasSnapshot: Bool { fallbackLease != nil }
    @discardableResult
    func showFallback(source: SceneRasterSource?, resources: SceneRenderResources, minimumScale: Double = 0) -> Bool {
      if let source, fallbackSource == source, let fallbackLease, fallbackLease.pixelScale >= minimumScale { return true }
      removeFallback()
      guard let source, let lease = resources.retainRaster(for: source, minimumScale: minimumScale) else { return false }
      fallbackSource = source; fallbackLease = lease
      let imageView = UIImageView(image: lease.image)
      imageView.frame = bounds; imageView.contentMode = .scaleToFill
      imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      imageView.isAccessibilityElement = false
      fallback = imageView; addSubview(imageView)
      return true
    }
    func removeFallback() {
      fallback?.removeFromSuperview(); fallback = nil
      fallbackLease?.release(); fallbackLease = nil; fallbackSource = nil
    }
    init() { super.init(frame: .zero); backgroundColor = .white }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func install(_ web: WKWebView, size: CGSize) {
      let viewport = PhysicalWebViewport(webView: web, contentSize: size)
      self.viewport = viewport
      if let fallback { insertSubview(viewport, belowSubview: fallback) } else { addSubview(viewport) }
      setNeedsLayout()
    }
    func configure(size: CGSize, interactive: Bool) {
      viewport?.setContentSize(size)
      isUserInteractionEnabled = interactive
      accessibilityElementsHidden = !interactive
    }
    func removeSurface() { viewport?.removeFromSuperview(); viewport = nil }
    override func layoutSubviews() { super.layoutSubviews(); viewport?.frame = bounds }
  }

  private struct PlatformDocumentWebView: UIViewRepresentable {
    let document: DocumentDocument
    let state: DocumentStateJournal
    let isInteractive: Bool
    let selectedPageIndex: Int
    let capturesSnapshot: Bool
    let onRenderReady: PageTurnReadiness
    let onPageLayout: (DocumentPageLayout) -> Void
    let onSourceChange: (String, String) -> Void
    let onStateChange: (String, JSONValue) -> Void
    let resources: SceneRenderResources
    var snapshotPixelWidth: Int? = nil
    var onPreparationFailure: (Error) -> Void = { _ in }
    func makeCoordinator() -> DocumentWebCoordinator {
      DocumentWebCoordinator(resources: resources, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange)
    }
    func makeUIView(context: Context) -> DocumentWebHost { DocumentWebHost() }
    func updateUIView(_ view: DocumentWebHost, context: Context) {
      context.coordinator.update(document: document, state: state, selectedPageIndex: selectedPageIndex,
        capturesSnapshot: capturesSnapshot, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange, snapshotPixelWidth: snapshotPixelWidth,
        onPreparationFailure: onPreparationFailure)
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      context.coordinator.mount(in: view, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: isInteractive, priority: snapshotPixelWidth != nil ? .visible : (isInteractive ? .currentPage : .neighbor))
    }
    static func dismantleUIView(_ view: DocumentWebHost, coordinator: DocumentWebCoordinator) { coordinator.invalidate() }
  }
#elseif os(macOS)
  @MainActor
  final class DocumentWebHost: NSView {
    private var web: WKWebView?
    private var fallback: NSImageView?
    private var fallbackLease: RasterLease?
    private var fallbackSource: SceneRasterSource?
    var hasSnapshot: Bool { fallbackLease != nil }
    @discardableResult
    func showFallback(source: SceneRasterSource?, resources: SceneRenderResources, minimumScale: Double = 0) -> Bool {
      if let source, fallbackSource == source, let fallbackLease, fallbackLease.pixelScale >= minimumScale { return true }
      removeFallback()
      guard let source, let lease = resources.retainRaster(for: source, minimumScale: minimumScale) else { return false }
      fallbackSource = source; fallbackLease = lease
      let imageView = NSImageView(frame: bounds)
      imageView.image = lease.image; imageView.imageScaling = .scaleAxesIndependently
      imageView.autoresizingMask = [.width, .height]
      imageView.setAccessibilityHidden(true)
      fallback = imageView; addSubview(imageView)
      return true
    }
    func removeFallback() {
      fallback?.removeFromSuperview(); fallback = nil
      fallbackLease?.release(); fallbackLease = nil; fallbackSource = nil
    }
    init() { super.init(frame: .zero); wantsLayer = true; layer?.backgroundColor = NSColor.white.cgColor }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func install(_ web: WKWebView, size: CGSize) {
      self.web = web; addSubview(web, positioned: .below, relativeTo: fallback)
      web.frame = bounds; web.autoresizingMask = [.width, .height]
    }
    func configure(size: CGSize, interactive: Bool) { web?.setAccessibilityHidden(!interactive) }
    func removeSurface() { web?.removeFromSuperview(); web = nil }
  }

  private struct PlatformDocumentWebView: NSViewRepresentable {
    let document: DocumentDocument
    let state: DocumentStateJournal
    let isInteractive: Bool
    let selectedPageIndex: Int
    let capturesSnapshot: Bool
    let onRenderReady: PageTurnReadiness
    let onPageLayout: (DocumentPageLayout) -> Void
    let onSourceChange: (String, String) -> Void
    let onStateChange: (String, JSONValue) -> Void
    let resources: SceneRenderResources
    var snapshotPixelWidth: Int? = nil
    var onPreparationFailure: (Error) -> Void = { _ in }
    func makeCoordinator() -> DocumentWebCoordinator {
      DocumentWebCoordinator(resources: resources, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange)
    }
    func makeNSView(context: Context) -> DocumentWebHost { DocumentWebHost() }
    func updateNSView(_ view: DocumentWebHost, context: Context) {
      context.coordinator.update(document: document, state: state, selectedPageIndex: selectedPageIndex,
        capturesSnapshot: capturesSnapshot, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange, snapshotPixelWidth: snapshotPixelWidth,
        onPreparationFailure: onPreparationFailure)
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      context.coordinator.mount(in: view, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: isInteractive, priority: snapshotPixelWidth != nil ? .visible : (isInteractive ? .currentPage : .neighbor))
    }
    static func dismantleNSView(_ view: DocumentWebHost, coordinator: DocumentWebCoordinator) { coordinator.invalidate() }
  }
#endif
