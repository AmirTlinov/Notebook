import SwiftUI
import WebKit
import NotebookCore

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
    return entry?.token == Self.token(
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

  nonisolated static func token(
    document: DocumentDocument,
    state: DocumentStateJournal,
    pageIndex: Int
  ) -> String {
    precondition(document.id == state.id)
    precondition(pageIndex >= 0)
    return "\(document.contentStamp.counter)@\(document.contentStamp.actor.uuidString.lowercased())|\(state.stamp.counter)@\(state.stamp.actor.uuidString.lowercased())|page:\(pageIndex)"
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
  let currentPage: Int
  let stride: Double

  init(pageCount: Int, currentPage: Int, stride: Double) {
    self.pageCount = max(1, pageCount)
    self.currentPage = min(max(0, currentPage), max(1, pageCount) - 1)
    self.stride = max(1, stride)
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
  let pagePosition: Double?
  let usesExternalPaging: Bool
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
      pagePosition: pagePosition,
      usesExternalPaging: usesExternalPaging,
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

    init(_ size: DocumentPaperSize) {
      kind = size
      widthPoints = size.widthPoints
      heightPoints = size.heightPoints
      marginPoints = size.marginPoints
    }
  }

  let documentID: UUID
  let paper: Paper
  let blocks: [DocumentBlock]
  let states: [String: JSONValue]
  let editable: Bool
  let externalPaging: Bool
  let renderToken: String

  init(
    document: DocumentDocument,
    state: DocumentStateJournal,
    editable: Bool,
    selectedPageIndex: Int,
    externalPaging: Bool
  ) {
    documentID = document.id
    paper = Paper(document.paperSize)
    blocks = document.blocks
    states = Dictionary(
      uniqueKeysWithValues: state.records.map { ($0.id, $0.value) }
    )
    self.editable = editable
    self.externalPaging = externalPaging
    #if os(macOS)
      renderToken = DocumentSnapshotCache.token(
        document: document,
        state: state,
        pageIndex: selectedPageIndex
      )
    #else
      renderToken = "\(document.contentStamp.counter)@\(document.contentStamp.actor.uuidString.lowercased())|\(state.stamp.counter)@\(state.stamp.actor.uuidString.lowercased())"
    #endif
  }
}

private struct DocumentRuntimePayloadKey: Equatable {
  let contentStamp: VersionStamp
  let stateStamp: VersionStamp
  let editable: Bool
  let externalPaging: Bool
  let snapshotPageIndex: Int

  init(
    document: DocumentDocument,
    state: DocumentStateJournal,
    editable: Bool,
    externalPaging: Bool,
    selectedPageIndex: Int
  ) {
    contentStamp = document.contentStamp
    stateStamp = state.stamp
    self.editable = editable
    self.externalPaging = externalPaging
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
  var requestedPagePosition: Double?
  var appliedPagePosition: Double?
  var pagePositionUpdateIsRunning = false
  var pageStride: Double?
  var pageCount = 1
  var onPageLayout: (DocumentPageLayout) -> Void
  var onSourceChange: (String, String) -> Void
  var onStateChange: (String, JSONValue) -> Void
  #if os(macOS)
    var pendingSnapshotPayload: DocumentRuntimePayload?
  #endif

  init(
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onSourceChange: @escaping (String, String) -> Void,
    onStateChange: @escaping (String, JSONValue) -> Void
  ) {
    self.onPageLayout = onPageLayout
    self.onSourceChange = onSourceChange
    self.onStateChange = onStateChange
  }

  func update(
    document: DocumentDocument,
    state: DocumentStateJournal,
    editable: Bool,
    selectedPageIndex: Int,
    pagePosition: Double?,
    usesExternalPaging: Bool,
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onSourceChange: @escaping (String, String) -> Void,
    onStateChange: @escaping (String, JSONValue) -> Void
  ) {
    self.onPageLayout = onPageLayout
    self.onSourceChange = onSourceChange
    self.onStateChange = onStateChange
    requestedPagePosition = pagePosition
    let nextKey = DocumentRuntimePayloadKey(
      document: document,
      state: state,
      editable: editable,
      externalPaging: usesExternalPaging,
      selectedPageIndex: selectedPageIndex
    )
    if payloadKey != nextKey {
      payloadKey = nextKey
      payload = DocumentRuntimePayload(
        document: document,
        state: state,
        editable: editable,
        selectedPageIndex: selectedPageIndex,
        externalPaging: usesExternalPaging
      )
      applyIfReady()
    }
    applyPagePositionIfReady()
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
      if let pageCount = (body["pageCount"] as? NSNumber)?.intValue,
        let currentPage = (body["currentPage"] as? NSNumber)?.intValue,
        let stride = (body["stride"] as? NSNumber)?.doubleValue
      {
        pageStride = stride
        self.pageCount = max(1, pageCount)
        onPageLayout(
          DocumentPageLayout(
            pageCount: pageCount,
            currentPage: currentPage,
            stride: stride
          )
        )
      }
      appliedPagePosition = nil
      #if os(macOS)
        pendingSnapshotPayload = payload
      #endif
      applyPagePositionIfReady()
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
    guard isReady, let webView, let payload,
      let data = try? JSONEncoder().encode(payload),
      data != lastAppliedData,
      let json = String(data: data, encoding: .utf8)
    else { return }
    lastAppliedData = data
    webView.evaluateJavaScript(
      "window.notebookRenderer?.apply(\(json))"
    ) { [weak self] _, error in
      guard error != nil else { return }
      Task { @MainActor [weak self] in
        guard self?.lastAppliedData == data else { return }
        self?.lastAppliedData = nil
      }
    }
  }

  private func applyPagePositionIfReady() {
    guard isReady, !pagePositionUpdateIsRunning,
      let webView,
      let requestedPagePosition,
      requestedPagePosition.isFinite,
      appliedPagePosition.map({ abs($0 - requestedPagePosition) > 0.000_1 })
        ?? true
    else { return }

    #if os(iOS)
      if payload?.externalPaging == true, let pageStride {
        let maximum = Double(max(0, pageCount - 1))
        let value = min(max(0, requestedPagePosition), maximum)
        let edgePosition = requestedPagePosition - value
        webView.scrollView.setContentOffset(
          CGPoint(x: CGFloat(value * pageStride), y: 0),
          animated: false
        )
        webView.scrollView.transform = CGAffineTransform(
          translationX: CGFloat(-edgePosition * pageStride),
          y: 0
        )
        appliedPagePosition = requestedPagePosition
        return
      }
    #endif
    let value = max(0, requestedPagePosition)
    pagePositionUpdateIsRunning = true
    webView.evaluateJavaScript(
      "window.notebookRenderer?.setPagePosition(\(value))"
    ) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        appliedPagePosition = value
        pagePositionUpdateIsRunning = false
        applyPagePositionIfReady()
        #if os(macOS)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
            self?.capturePendingSnapshotIfReady()
          }
        #endif
      }
    }
  }

  #if os(macOS)
    private func capturePendingSnapshotIfReady() {
      guard !pagePositionUpdateIsRunning,
        let payload = pendingSnapshotPayload
      else { return }
      if let requestedPagePosition {
        guard let appliedPagePosition,
          abs(appliedPagePosition - requestedPagePosition) <= 0.000_1
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
      webView.takeSnapshot(with: nil) { [weak self] image, _ in
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
    ) ?? Bundle.main.url(
      forResource: "document-shell",
      withExtension: "html"
    ) {
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
  let pagePosition: Double?
  let usesExternalPaging: Bool
  let onPageLayout: (DocumentPageLayout) -> Void
  let onSourceChange: (String, String) -> Void
  let onStateChange: (String, JSONValue) -> Void

  func makeCoordinator() -> DocumentWebCoordinator {
    DocumentWebCoordinator(
      onPageLayout: onPageLayout,
      onSourceChange: onSourceChange,
      onStateChange: onStateChange
    )
  }

  func makeUIView(context: Context) -> WKWebView {
    DocumentWebViewFactory.make(coordinator: context.coordinator)
  }

  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.update(
      document: document,
      state: state,
      editable: isInteractive,
      selectedPageIndex: selectedPageIndex,
      pagePosition: pagePosition,
      usesExternalPaging: usesExternalPaging,
      onPageLayout: onPageLayout,
      onSourceChange: onSourceChange,
      onStateChange: onStateChange
    )
    view.isUserInteractionEnabled = isInteractive
  }

  static func dismantleUIView(
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
#elseif os(macOS)
private struct PlatformDocumentWebView: NSViewRepresentable {
  let document: DocumentDocument
  let state: DocumentStateJournal
  let isInteractive: Bool
  let selectedPageIndex: Int
  let pagePosition: Double?
  let usesExternalPaging: Bool
  let onPageLayout: (DocumentPageLayout) -> Void
  let onSourceChange: (String, String) -> Void
  let onStateChange: (String, JSONValue) -> Void

  func makeCoordinator() -> DocumentWebCoordinator {
    DocumentWebCoordinator(
      onPageLayout: onPageLayout,
      onSourceChange: onSourceChange,
      onStateChange: onStateChange
    )
  }

  func makeNSView(context: Context) -> WKWebView {
    DocumentWebViewFactory.make(coordinator: context.coordinator)
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.update(
      document: document,
      state: state,
      editable: isInteractive,
      selectedPageIndex: selectedPageIndex,
      pagePosition: pagePosition,
      usesExternalPaging: usesExternalPaging,
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
