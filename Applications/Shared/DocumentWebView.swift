import NotebookCore
import SwiftUI
import WebKit

#if os(macOS)
  @MainActor
  final class DocumentSnapshotCache {
    static let shared = DocumentSnapshotCache()
    static let didChange = Notification.Name("NotebookDocumentSnapshotDidChange")
    private static let capacity = 8

    private struct Entry {
      let token: String
      let image: NSImage
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []

    func image(
      for document: DocumentDocument,
      state: DocumentStateJournal,
      pageIndex: Int
    ) -> NSImage? {
      let entry = entries[document.id]
      return entry?.token
        == Self.token(
          document: document,
          state: state,
          pageIndex: pageIndex
        )
        ? entry?.image
        : nil
    }

    func store(image: NSImage, documentID: UUID, token: String) {
      entries[documentID] = Entry(token: token, image: image)
      order.removeAll { $0 == documentID }
      order.append(documentID)
      while order.count > Self.capacity, let oldest = order.first {
        order.removeFirst()
        entries[oldest] = nil
      }
      NotificationCenter.default.post(name: Self.didChange, object: documentID)
    }

    func prepare(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int) async throws {
      if image(for: document, state: state, pageIndex: pageIndex) != nil { return }
      let ready = PageTurnReadiness { _ in }
      let coordinator = DocumentWebCoordinator(onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _,_ in }, onStateChange: { _,_ in })
      let web = DocumentWebViewFactory.make(coordinator: coordinator)
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: geometry.width, height: geometry.height),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
      defer { web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "notebook"); window.orderOut(nil); window.close() }
      coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: true,
        onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _,_ in }, onStateChange: { _,_ in })
      let deadline = ContinuousClock.now + .seconds(8)
      while image(for: document, state: state, pageIndex: pageIndex) == nil {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw DocumentPreparationError.pending }
        try await Task.sleep(for: .milliseconds(20))
      }
    }

    enum DocumentPreparationError: Error { case pending }

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

  private struct DocumentSnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
  }

  extension EnvironmentValues {
    var rendersDocumentSnapshot: Bool {
      get { self[DocumentSnapshotRenderingKey.self] }
      set { self[DocumentSnapshotRenderingKey.self] = newValue }
    }
  }
#endif

struct DocumentPageLayout: Equatable, Sendable {
  let pageCount: Int

  init(pageCount: Int) {
    self.pageCount = max(1, pageCount)
  }
}

struct DocumentWebView: View {
  #if os(macOS)
    @Environment(\.rendersDocumentSnapshot) private var rendersSnapshot
  #endif

  let document: DocumentDocument
  let state: DocumentStateJournal
  let isInteractive: Bool
  let selectedPageIndex: Int
  let capturesSnapshot: Bool
  let onRenderReady: PageTurnReadiness
  let onPageLayout: (DocumentPageLayout) -> Void
  let onSourceChange: (String, String) -> Void
  let onStateChange: (String, JSONValue) -> Void

  var body: some View {
    #if os(macOS)
      if rendersSnapshot,
        let image = DocumentSnapshotCache.shared.image(
          for: document,
          state: state,
          pageIndex: selectedPageIndex
        )
      {
        Image(nsImage: image)
          .resizable()
          .accessibilityHidden(true)
      } else {
        platformView
      }
    #else
      platformView
    #endif
  }

  private var platformView: some View {
    PlatformDocumentWebView(
      document: document,
      state: state,
      isInteractive: isInteractive,
      selectedPageIndex: selectedPageIndex,
      capturesSnapshot: capturesSnapshot,
      onRenderReady: onRenderReady,
      onPageLayout: onPageLayout,
      onSourceChange: onSourceChange,
      onStateChange: onStateChange
    )
    .accessibilityIdentifier("document-runtime")
  }
}

private struct DocumentRuntimePayload: Codable {
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
    #if os(macOS)
      renderToken = DocumentSnapshotCache.token(
        document: document,
        state: state,
        pageIndex: selectedPageIndex
      )
    #else
      renderToken =
        "\(document.contentStamp.counter)@\(document.contentStamp.actor.uuidString.lowercased())|\(state.stamp.counter)@\(state.stamp.actor.uuidString.lowercased())"
    #endif
  }
}

private struct DocumentRuntimePayloadKey: Equatable {
  let contentStamp: VersionStamp
  let stateStamp: VersionStamp
  let snapshotPageIndex: Int

  init(
    document: DocumentDocument,
    state: DocumentStateJournal,
    selectedPageIndex: Int
  ) {
    contentStamp = document.contentStamp
    stateStamp = state.stamp
    #if os(macOS)
      snapshotPageIndex = selectedPageIndex
    #else
      snapshotPageIndex = 0
    #endif
  }
}

@MainActor
private final class DocumentWebCoordinator: NSObject,
  WKNavigationDelegate,
  WKScriptMessageHandler
{
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
  #if os(macOS)
    var pendingSnapshotPayload: DocumentRuntimePayload?
  #endif

  init(
    onRenderReady: PageTurnReadiness,
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onSourceChange: @escaping (String, String) -> Void,
    onStateChange: @escaping (String, JSONValue) -> Void
  ) {
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
    onStateChange: @escaping (String, JSONValue) -> Void
  ) {
    self.onRenderReady = onRenderReady
    self.onPageLayout = onPageLayout
    self.onSourceChange = onSourceChange
    self.onStateChange = onStateChange
    let nextPageIndex = max(0, selectedPageIndex)
    let pageChanged = requestedPageIndex != nextPageIndex
    requestedPageIndex = nextPageIndex
    if pageChanged {
      pageIndexRequestID = nil
      appliedPageIndex = nil
    }
    self.capturesSnapshot = capturesSnapshot
    let nextKey = DocumentRuntimePayloadKey(
      document: document,
      state: state,
      selectedPageIndex: selectedPageIndex
    )
    if payloadKey != nextKey {
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
    #if os(macOS)
      pendingSnapshotPayload = capturesSnapshot ? payload : nil
    #endif
    applyPageIndexIfReady()
    onRenderReady(renderIsReady)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isReady = true
    applyIfReady()
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
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
    guard message.name == "notebook",
      let body = message.body as? [String: Any],
      let kind = body["kind"] as? String
    else { return }

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
      #if os(macOS)
        pendingSnapshotPayload = capturesSnapshot ? payload : nil
      #endif
      applyPageIndexIfReady()
      #if os(macOS)
        capturePendingSnapshotIfReady()
      #endif
      return
    }
    guard let blockID = body["blockID"] as? String else { return }
    switch kind {
    case "source":
      guard let source = body["source"] as? String else { return }
      onSourceChange(blockID, source)
    case "state":
      guard let value = body["value"],
        JSONSerialization.isValidJSONObject(["value": value]),
        let data = try? JSONSerialization.data(withJSONObject: value),
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
    guard isReady, let webView, let payload,
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
        guard self?.lastAppliedData == data else { return }
        self?.lastAppliedData = nil
      }
    }
  }

  private func applyPageIndexIfReady() {
    guard isReady, pageIndexRequestID == nil,
      let webView,
      let payload,
      renderedToken == payload.renderToken,
      let requestedPageIndex,
      appliedPageIndex != requestedPageIndex
    else { return }

    let value = min(max(0, requestedPageIndex), max(0, pageCount - 1))
    let requestID = UUID()
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
        guard let self else { return }
        guard pageIndexRequestID == requestID else { return }
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
        #if os(macOS)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            self?.capturePendingSnapshotIfReady()
          }
        #endif
      }
    )
  }

  private func setRenderReady(_ ready: Bool) {
    guard renderIsReady != ready else { return }
    renderIsReady = ready
    onRenderReady(ready)
  }

  #if os(macOS)
    private func capturePendingSnapshotIfReady() {
      guard capturesSnapshot, pageIndexRequestID == nil,
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
      guard let webView,
        self.payload?.renderToken == payload.renderToken
      else { return }
      guard webView.bounds.width > 1, webView.bounds.height > 1 else {
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
          self?.captureSnapshot(
            for: payload,
            remainingAttempts: remainingAttempts - 1
          )
        }
        return
      }
      let configuration = WKSnapshotConfiguration()
      configuration.afterScreenUpdates = true
      webView.takeSnapshot(with: configuration) { [weak self] image, _ in
        Task { @MainActor [weak self] in
          guard let self, let image,
            self.payload?.renderToken == payload.renderToken
          else { return }
          DocumentSnapshotCache.shared.store(
            image: image,
            documentID: payload.documentID,
            token: payload.renderToken
          )
        }
      }
    }
  #endif
}

private enum DocumentWebViewFactory {
  @MainActor
  static func make(coordinator: DocumentWebCoordinator) -> WKWebView {
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

    func makeCoordinator() -> DocumentWebCoordinator {
      DocumentWebCoordinator(
        onRenderReady: onRenderReady,
        onPageLayout: onPageLayout,
        onSourceChange: onSourceChange,
        onStateChange: onStateChange
      )
    }

    private var physicalSize: CGSize {
      let paper = WorkspaceItemGeometry.document(document.paperSize)
      return CGSize(width: paper.width, height: paper.height)
    }

    func makeUIView(context: Context) -> PhysicalWebViewport {
      PhysicalWebViewport(
        webView: DocumentWebViewFactory.make(coordinator: context.coordinator),
        contentSize: physicalSize)
    }

    func updateUIView(_ view: PhysicalWebViewport, context: Context) {
      context.coordinator.update(
        document: document,
        state: state,
        selectedPageIndex: selectedPageIndex,
        capturesSnapshot: capturesSnapshot,
        onRenderReady: onRenderReady,
        onPageLayout: onPageLayout,
        onSourceChange: onSourceChange,
        onStateChange: onStateChange
      )
      view.setContentSize(physicalSize)
      view.isUserInteractionEnabled = isInteractive
      view.accessibilityElementsHidden = !isInteractive
    }

    static func dismantleUIView(
      _ view: PhysicalWebViewport,
      coordinator: DocumentWebCoordinator
    ) {
      view.webView.configuration.userContentController.removeScriptMessageHandler(
        forName: "notebook"
      )
      view.webView.navigationDelegate = nil
      coordinator.webView = nil
    }
  }
#elseif os(macOS)
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

    func makeCoordinator() -> DocumentWebCoordinator {
      DocumentWebCoordinator(
        onRenderReady: onRenderReady,
        onPageLayout: onPageLayout,
        onSourceChange: onSourceChange,
        onStateChange: onStateChange
      )
    }

    func makeNSView(context: Context) -> WKWebView {
      DocumentWebViewFactory.make(coordinator: context.coordinator)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
      view.setAccessibilityHidden(!isInteractive)
      context.coordinator.update(
        document: document,
        state: state,
        selectedPageIndex: selectedPageIndex,
        capturesSnapshot: capturesSnapshot,
        onRenderReady: onRenderReady,
        onPageLayout: onPageLayout,
        onSourceChange: onSourceChange,
        onStateChange: onStateChange
      )
    }

    static func dismantleNSView(
      _ view: WKWebView,
      coordinator: DocumentWebCoordinator
    ) {
      view.configuration.userContentController.removeScriptMessageHandler(
        forName: "notebook"
      )
      view.navigationDelegate = nil
      coordinator.webView = nil
    }
  }
#endif
