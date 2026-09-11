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
    func store(image: AgentSnapshotImage, documentID: UUID, token: String, layout: DocumentLayoutRecord, reservation: RasterReservation? = nil,
      resources: SceneRenderResources = .shared) -> Bool {
      if resources.store(image, for: .document(id: documentID, token: token), reservation: reservation, documentLayout: layout) {
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
      let coordinator = DocumentWebCoordinator(onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _,_ in })
      let host = DocumentWebHost()
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: geometry.width, height: geometry.height),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
      defer { coordinator.invalidate(); window.orderOut(nil); window.close() }
      coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: true,
        onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _,_ in })
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
  @Environment(\.openURL) private var openURL
  @State private var linkFailure: String?
  let document: DocumentDocument
  let state: DocumentStateJournal
  let isInteractive: Bool
  let selectedPageIndex: Int
  let capturesSnapshot: Bool
  let onRenderReady: PageTurnReadiness
  let onPageLayout: (DocumentPageLayout) -> Void
  let onPageNavigation: (Int) -> Void
  let onSourceChange: (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status
  let onStateChange: (String, JSONValue) -> Void
  var drafts: [DocumentEditingSession] = []
  var onDraftChange: (DocumentEditingSession) -> Void = { _ in }
  var onDraftDiscard: (UUID) -> Void = { _ in }
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
      resources: resources, drafts: drafts, onDraftChange: onDraftChange, onDraftDiscard: onDraftDiscard,
      onLinkNavigation: { destination in
        switch destination {
        case .page(let index): onPageNavigation(index)
        case .external(let url): openURL(url) { accepted in
          if !accepted { linkFailure = "Система не смогла открыть эту ссылку." }
        }
        case .unavailable(let message): linkFailure = message
        }
      }
    )
    .accessibilityIdentifier("document-runtime")
    .alert("Ссылка недоступна", isPresented: Binding(get: { linkFailure != nil }, set: { if !$0 { linkFailure = nil } })) {
      Button("Понятно", role: .cancel) { linkFailure = nil }
    } message: { Text(linkFailure ?? "") }
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
      onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _,_ in },
      resources: resources, snapshotPixelWidth: 256, onPreparationFailure: onFailure)
      .accessibilityHidden(true)
  }
}

@MainActor
struct DocumentRuntimePayload {
  let source: DocumentSourceSnapshot
  let state: DocumentStateSnapshot
  var documentID: UUID { source.message.documentID }
  var paper: DocumentPaperLayout { source.message.paper }
  var blocks: [DocumentBlock] { source.message.blocks }
  var states: [String: JSONValue] { state.message.states }
  var sourceVersions: [String: ContentFieldVersion] { source.message.sourceVersions }
  var editable: Bool
  let renderToken: String
  let pageIndex: Int
  var runtimeID: UUID
  let blockTokens: [String: String]
  let programMode: String
  var drafts: [DocumentEditingSession]

  func frame(generation: UInt64) -> DocumentRuntimeFrame {
    .init(documentID: documentID, generation: String(generation), sourceKey: source.message.key, stateKey: state.message.key,
      editable: editable, renderToken: renderToken, pageIndex: pageIndex, runtimeID: runtimeID,
      blockTokens: blockTokens, programMode: programMode, drafts: drafts)
  }
}

struct DocumentRuntimeFrame: Encodable {
  let documentID: UUID
  let generation: String
  let sourceKey: String
  let stateKey: String
  let editable: Bool
  let renderToken: String
  let pageIndex: Int
  let runtimeID: UUID
  let blockTokens: [String: String]
  let programMode: String
  let drafts: [DocumentEditingSession]
}

private struct DocumentPixelPresentation: Equatable {
  enum Kind: String { case canonical, editor, preparing }
  let epoch: UInt64
  let kind: Kind
  init?(_ receipt: NSDictionary) {
    guard let value = receipt["presentationEpoch"] as? String, let epoch = UInt64(value),
      let value = receipt["presentationKind"] as? String, let kind = Kind(rawValue: value) else { return nil }
    self.epoch = epoch; self.kind = kind
  }
}

enum DocumentSnapshotWait: Error, Equatable {
  case editorActive
  case presentationChanged
}

/// A submitted WebKit capture owns its backing until WebKit returns, even if
/// its reader has already timed out, changed presentation, or been unmounted.
@MainActor
final class DocumentSnapshotCapture {
  private(set) var reservation: RasterReservation?
  private(set) var image: AgentSnapshotImage?
  private var submitted = false
  private var cancelled = false
  init(reservation: RasterReservation) { self.reservation = reservation }
  func submit() {
    precondition(!submitted && !cancelled && reservation != nil)
    submitted = true
  }
  /// The callback owns this capture independently from the coordinator. A
  /// stale callback still reaches this method and releases its own backing.
  func receive(_ image: AgentSnapshotImage?) -> Bool {
    precondition(submitted)
    submitted = false
    if cancelled { release(); return false }
    self.image = image
    return true
  }
  func cancel() {
    cancelled = true
    if !submitted { release() }
  }
  private func release() {
    image = nil
    reservation?.release(); reservation = nil
  }
  isolated deinit { reservation?.release() }
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
  private(set) var ownsEditing = false
  private var physicalSize = CGSize(width: 1, height: 1)
  private var generation: UInt64 = 0
  private(set) var renderSession: DocumentRenderSession?
  private var frameTask: Task<Void, Never>?
  private var frameTaskID: UUID?
  private var frameEvaluationID: UUID?
  private var frameContinuation: CheckedContinuation<Void, Error>?
  private var sentSourcePage: Int?
  private var sentSourceKey: String?
  private var sentStateKey: String?
  private var sentGeneration: UInt64?
  private var layoutAccepted = false
  private var pixelPresentation: DocumentPixelPresentation?
  private var canonicalPixelEpoch: UInt64?
  var hasCanonicalPixels: Bool {
    renderIsReady && layoutAccepted && pixelPresentation?.kind == .canonical
      && canonicalPixelEpoch != nil && canonicalPixelEpoch == pixelPresentation?.epoch
  }
  private struct CanonicalSnapshotWaiter {
    let afterEpoch: UInt64?
    let resume: () -> Void
  }
  private var canonicalSnapshotWaiters: [UUID: CanonicalSnapshotWaiter] = [:]
  private weak var waitingSnapshotProducer: DocumentWebCoordinator?
  private var snapshotWaitID: UUID?
  private(set) var waitingForCanonicalSnapshot = false
  private let hostID = UUID()
  private var runtimeID = UUID()
  private var blockTokens: [String: String] = [:]
  private var draftsByID: [UUID: DocumentEditingSession] = [:]
  private var onDraftChange: (DocumentEditingSession) -> Void = { _ in }
  private var onDraftDiscard: (UUID) -> Void = { _ in }
  private var preparationDeadlineTask: Task<Void, Never>?
  private var preparationDeadlineGeneration: UInt64?
  private var recoveryAttempts = 0
  private var snapshotTask: Task<Void, Never>?
  private var readerTask: Task<Void, any Error>?
  private var readerTaskID: UUID?
  private var readerID: UUID?
  private var readerContinuation: CheckedContinuation<Void, any Error>?
  private var readerDeadline: Task<Void, Never>?
  private var readerCapture: DocumentSnapshotCapture?
  private var readerPreparedLease: RasterLease?
  var canShareSnapshot: Bool {
    !isInvalidated && acquisitionError == nil && payload != nil && webView != nil
      && surfaceLease?.isReleased == false
  }
  var resourceOwner: SceneRenderResources { resources }
  private var fallbackSource: SceneRasterSource?
  private var snapshotPixelWidth: Int?
  private var snapshotOnlyComplete = false
  private var snapshotCaptureID: UUID?
  private var onPreparationFailure: (Error) -> Void = { _ in }

  func mount(in host: DocumentWebHost, physicalSize: CGSize, isInteractive: Bool, priority: WebPriority) {
    guard !isInvalidated else { return }
    self.host = host
    DocumentRenderRegistry.shared.mountRenderer(self, hostID: hostID)
    self.physicalSize = physicalSize
    acceptsInput = isInteractive
    if let payload {
      DocumentRenderRegistry.shared.setEditingOwner(documentID: payload.documentID, hostID: hostID, active: isInteractive)
    }
    host.configure(size: physicalSize, interactive: isInteractive)
    refreshLiveReceipt()
    if let snapshotPixelWidth, host.showFallback(source: fallbackSource, resources: resources,
      minimumScale: Self.snapshotMinimumScale(pixelWidth: snapshotPixelWidth, size: physicalSize)) {
      snapshotOnlyComplete = true
      acquisitionError = nil
      releaseWebSurface()
      setRenderReady(true)
      onRenderReady(true)
      return
    }
    if waitingForCanonicalSnapshot { return }
    if let acquisitionError {
      onPreparationFailure(acquisitionError)
      return
    }
    if !renderIsReady { host.showFallback(source: fallbackSource, resources: resources) }
    if webView != nil { surfaceLease?.updatePriority(priority); requestedPriority = priority; return }
    if let snapshotPixelWidth, acquisitionTask == nil, let payload,
      let producer = DocumentRenderRegistry.shared.rasterProducer(documentID: payload.documentID,
        token: payload.renderToken, resources: resources, excluding: hostID) {
      let id = UUID(); acquisitionID = id; requestedPriority = priority
      let attemptedEpoch = producer.canonicalPixelEpoch
      acquisitionTask = Task { @MainActor [weak self] in
        do {
          let raster = try await producer.retainPreparedSnapshot(pixelWidth: snapshotPixelWidth)
          defer { raster.release() }
          guard let self, !Task.isCancelled, !isInvalidated, acquisitionID == id else { return }
          acquisitionTask = nil
          guard host.showFallback(source: fallbackSource, resources: resources) else { throw SceneRenderError.resourceLimit }
          snapshotOnlyComplete = true
          onRenderReady(true)
        } catch {
          guard let self, !Task.isCancelled, !isInvalidated, acquisitionID == id else { return }
          acquisitionTask = nil
          if error is DocumentSnapshotWait { waitForCanonicalSnapshot(from: producer, after: attemptedEpoch) }
          else { failPreparation(error) }
        }
      }
      return
    }
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

  private func waitForCanonicalSnapshot(from producer: DocumentWebCoordinator, after epoch: UInt64?) {
    clearSnapshotWait()
    let id = UUID(); snapshotWaitID = id
    waitingForCanonicalSnapshot = true; waitingSnapshotProducer = producer
    let expected = generation
    producer.canonicalSnapshotWaiters[hostID] = .init(afterEpoch: epoch) { [weak self] in
      guard let self, snapshotWaitID == id, generation == expected else { return }
      clearSnapshotWait()
      guard !isInvalidated, let host, let priority = requestedPriority else { return }
      mount(in: host, physicalSize: physicalSize, isInteractive: acceptsInput, priority: priority)
    }
    if producer.hasCanonicalPixels || producer.isInvalidated || producer.acquisitionError != nil {
      producer.wakeSnapshotWaiters(unavailable: producer.isInvalidated || producer.acquisitionError != nil)
    }
  }

  private func clearSnapshotWait() {
    waitingSnapshotProducer?.canonicalSnapshotWaiters[hostID] = nil
    waitingSnapshotProducer = nil; snapshotWaitID = nil; waitingForCanonicalSnapshot = false
  }

  private func wakeSnapshotWaiters(unavailable: Bool = false) {
    let resumed = canonicalSnapshotWaiters.filter { _, waiter in
      unavailable || (hasCanonicalPixels && waiter.afterEpoch != canonicalPixelEpoch)
    }
    for (id, waiter) in resumed {
      canonicalSnapshotWaiters[id] = nil
      Task { @MainActor in waiter.resume() }
    }
  }

  /// The resource and all callbacks belong to this one mounted lifetime.
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    generation &+= 1
    DocumentRenderRegistry.shared.unmountRenderer(hostID: hostID)
    revokeLiveReceipt()
    preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
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
    onPageLayout = { _ in }; onSourceChange = { _ in .targetMissing }; onStateChange = { _,_ in }
    onPreparationFailure = { _ in }; onLinkNavigation = { _ in }
    onDraftChange = { _ in }; onDraftDiscard = { _ in }
    releaseWebSurface()
    payload = nil; renderSession = nil
    host?.removeFallback()
  }

  private func failPreparation(_ error: Error) {
    guard !isInvalidated else { return }
    acquisitionError = error
    preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
    setRenderReady(false)
    releaseWebSurface()
    host?.showFailure("Не удалось подготовить страницу. Ваш черновик сохранён.") { [weak self] in
      self?.retryPreparation()
    }
    onPreparationFailure(error)
  }

  private func retryPreparation() {
    guard !isInvalidated, let host, let priority = requestedPriority else { return }
    acquisitionError = nil; recoveryAttempts = 0
    payload?.source.retryPagePreparation()
    host.removeFailure()
    runtimeID = UUID(); payload?.runtimeID = runtimeID; payload?.drafts = Array(draftsByID.values)
    mount(in: host, physicalSize: physicalSize, isInteractive: acceptsInput, priority: priority)
  }

  private func beginPreparationDeadline() {
    guard preparationDeadlineTask == nil || preparationDeadlineGeneration != generation else { return }
    preparationDeadlineTask?.cancel()
    let expected = generation
    preparationDeadlineGeneration = expected
    preparationDeadlineTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard let self, !isInvalidated, generation == expected else { return }
      failPreparation(SceneRenderError.snapshotPending("document_preparation_timeout"))
    }
  }

  func revokeEditingOwnership() {
    ownsEditing = false; payload?.editable = false
  }

  func activateEditing(drafts: [DocumentEditingSession]) {
    guard !isInvalidated, acceptsInput else { return }
    for draft in drafts where draft.edit.documentID == payload?.documentID
      && !DocumentRenderRegistry.shared.isDraftFinished(documentID: draft.edit.documentID, sessionID: draft.id) {
      if draftsByID[draft.id].map({ $0.edit.sequence < draft.edit.sequence }) ?? true { draftsByID[draft.id] = draft }
    }
    ownsEditing = true; payload?.editable = true; payload?.drafts = Array(draftsByID.values)
    guard isReady, let webView, let data = try? JSONEncoder().encode(Array(draftsByID.values)),
      let drafts = try? JSONSerialization.jsonObject(with: data) else { return }
    webView.callAsyncJavaScript("window.notebookRenderer.setEditingEnabled(true, drafts); return true;",
      arguments: ["drafts": drafts], in: nil, in: .page, completionHandler: nil)
  }

  func flushEditingDraft() async {
    guard let webView, isReady else { return }
    let expectedRuntime = runtimeID
    let result: DocumentEditingSession? = await withCheckedContinuation { continuation in
      var completed = false
      let deadline = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard !completed else { return }; completed = true
        continuation.resume(returning: nil)
      }
      webView.evaluateJavaScript("window.notebookRenderer.setEditingEnabled(false)") { value, _ in
        guard !completed else { return }; completed = true; deadline.cancel()
        continuation.resume(returning: Self.decode(value))
      }
    }
    guard !isInvalidated, runtimeID == expectedRuntime,
      let draft = result, draft.edit.documentID == payload?.documentID else { return }
    acceptDraft(draft)
  }

  private func acceptDraft(_ draft: DocumentEditingSession) {
    if draftsByID[draft.id].map({ $0.edit.sequence >= draft.edit.sequence }) == true { return }
    guard DocumentRenderRegistry.shared.recordDraft(draft) else { return }
    draftsByID[draft.id] = draft
    onDraftChange(draft)
  }

  func removeEditingDraft(_ sessionID: UUID) {
    draftsByID[sessionID] = nil
    payload?.drafts.removeAll { $0.id == sessionID }
  }

  func completeSourceEdit(_ edit: DocumentSourceEdit, status: String) {
    guard !isInvalidated, payload?.documentID == edit.documentID, let webView else { return }
    webView.callAsyncJavaScript("window.notebookRenderer.completeSourceEdit(result); return true;",
      arguments: ["result": ["sessionID": edit.sessionID.uuidString, "sequence": edit.sequence, "status": status]],
      in: nil, in: .page, completionHandler: nil)
  }

  private func revokeLiveReceipt() {
    DocumentRenderRegistry.shared.revokeLive(hostID: hostID, through: generation)
  }

  private func refreshLiveReceipt() {
    guard hasCanonicalPixels, snapshotPixelWidth == nil, acceptsInput, let payload,
      appliedPageIndex == requestedPageIndex, let pageIndex = appliedPageIndex else { revokeLiveReceipt(); return }
    DocumentRenderRegistry.shared.publishLive(documentID: payload.documentID, token: payload.renderToken,
      pageIndex: pageIndex, hostID: hostID, generation: generation) { [weak self] in
        guard let self, !isInvalidated, hasCanonicalPixels, acceptsInput, let host else { return false }
        #if os(iOS)
          return host.window?.isKeyWindow == true && UIApplication.shared.applicationState == .active && !host.isHidden
        #else
          // The Mac is a render/sync helper, never the human's document surface.
          return false
        #endif
      }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard !isInvalidated, self.webView === webView else { return }
    setRenderReady(false)
    releaseWebSurface()
    guard recoveryAttempts < 2, let host, let priority = requestedPriority else {
      failPreparation(SceneRenderError.snapshotPending("web_process_terminated")); return
    }
    recoveryAttempts += 1; generation &+= 1
    runtimeID = UUID(); payload?.runtimeID = runtimeID; payload?.drafts = Array(draftsByID.values)
    mount(in: host, physicalSize: physicalSize, isInteractive: acceptsInput, priority: priority)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    guard !isInvalidated, self.webView === webView else { return }
    failPreparation(error)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
    guard !isInvalidated, self.webView === webView else { return }
    failPreparation(error)
  }

  private func releaseWebSurface() {
    revokeLiveReceipt()
    clearSnapshotWait(); wakeSnapshotWaiters(unavailable: true)
    cancelSnapshotPreparation()
    preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
    acquisitionID = nil
    acquisitionTask?.cancel(); acquisitionTask = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
    webView?.navigationDelegate = nil
    host?.removeSurface()
    webView = nil
    isReady = false
    frameTaskID = nil; frameTask?.cancel(); frameTask = nil
    finishFrameEvaluation(throwing: CancellationError())
    sentSourceKey = nil; sentSourcePage = nil; sentStateKey = nil; sentGeneration = nil; layoutAccepted = false
    pixelPresentation = nil; canonicalPixelEpoch = nil
    renderedToken = nil
    appliedPageIndex = nil
    pageIndexRequestID = nil
    surfaceLease?.release(); surfaceLease = nil
  }

  private func cancelSnapshotPreparation() {
    snapshotCaptureID = nil
    snapshotTask?.cancel(); snapshotTask = nil
    finishReader(throwing: CancellationError())
    readerTaskID = nil; readerTask?.cancel(); readerTask = nil
    readerPreparedLease?.release(); readerPreparedLease = nil
  }

  isolated deinit {
    clearSnapshotWait(); wakeSnapshotWaiters(unavailable: true)
    snapshotTask?.cancel()
    frameTask?.cancel()
    finishFrameEvaluation(throwing: CancellationError())
    DocumentRenderRegistry.shared.unmountRenderer(hostID: hostID)
    finishReader(throwing: CancellationError())
    readerTask?.cancel()
    revokeLiveReceipt()
    preparationDeadlineTask?.cancel()
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
  var requestedPageIndex: Int?
  var appliedPageIndex: Int?
  var pageIndexRequestID: UUID?
  var renderedToken: String?
  var pageCount = 1
  var capturesSnapshot = false
  var renderIsReady = false
  var onRenderReady: PageTurnReadiness
  var onPageLayout: (DocumentPageLayout) -> Void
  var onLinkNavigation: (DocumentLinkDestination) -> Void = { _ in }
  var onSourceChange: (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status
  var onStateChange: (String, JSONValue) -> Void
  var pendingSnapshotPayload: DocumentRuntimePayload?
  private var preparedSnapshotLease: RasterLease?

  init(
    resources: SceneRenderResources = .shared,
    onRenderReady: PageTurnReadiness,
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onSourceChange: @escaping (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status,
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
    onSourceChange: @escaping (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status,
    onStateChange: @escaping (String, JSONValue) -> Void,
    snapshotPixelWidth: Int? = nil,
    drafts: [DocumentEditingSession] = [],
    onDraftChange: @escaping (DocumentEditingSession) -> Void = { _ in },
    onDraftDiscard: @escaping (UUID) -> Void = { _ in },
    onPreparationFailure: @escaping (Error) -> Void = { _ in },
    onLinkNavigation: @escaping (DocumentLinkDestination) -> Void = { _ in }
  ) {
    guard !isInvalidated else { return }
    self.onRenderReady = onRenderReady
    self.onPageLayout = onPageLayout
    self.onLinkNavigation = onLinkNavigation
    self.onSourceChange = onSourceChange
    self.onStateChange = onStateChange
    self.onDraftChange = onDraftChange; self.onDraftDiscard = onDraftDiscard
    for draft in drafts where draft.edit.documentID == document.id {
      guard DocumentRenderRegistry.shared.recordDraft(draft) else { continue }
      if draftsByID[draft.id].map({ $0.edit.sequence < draft.edit.sequence }) ?? true { draftsByID[draft.id] = draft }
    }
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
    if renderSession?.documentID != document.id {
      renderSession = DocumentRenderRegistry.shared.session(documentID: document.id, resources: resources)
    }
    guard let renderSession else { return }
    let nextSource = renderSession.source(document), nextState = renderSession.state(state)
    #if os(macOS)
      let programMode = capturesSnapshot ? "headless" : "live"
    #else
      let programMode = snapshotPixelWidth == nil ? "live" : "snapshot"
    #endif
    if payload?.pageIndex != selectedPageIndex || payload?.programMode != programMode
      || payload?.source !== nextSource || payload?.state !== nextState {
      clearSnapshotWait()
      generation &+= 1
      cancelSnapshotPreparation()
      snapshotOnlyComplete = false
      acquisitionError = nil
      preparedSnapshotLease?.release(); preparedSnapshotLease = nil
      host?.removeFallback()
      setRenderReady(false)
      pageIndexRequestID = nil
      appliedPageIndex = nil
      renderedToken = nil
      layoutAccepted = false
      canonicalPixelEpoch = nil
      if payload?.documentID != document.id {
        pageCount = 1; blockTokens = [:]
        draftsByID = Dictionary(uniqueKeysWithValues: drafts.filter { $0.edit.documentID == document.id }.map { ($0.id, $0) })
      }
      // A state echo visits each program once. Searching both arrays for each
      // block made four live pages repeat quadratic work on the input actor.
      let previousBlocks = Dictionary((payload?.blocks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var nextTokens: [String: String] = [:]
      nextTokens.reserveCapacity(document.blocks.count)
      for block in document.blocks {
        if let previous = previousBlocks[block.id], let token = blockTokens[block.id], Self.sameProgram(previous, block) {
          nextTokens[block.id] = token
        } else { nextTokens[block.id] = UUID().uuidString }
      }
      blockTokens = nextTokens
      if payload?.source !== nextSource { recoveryAttempts = 0 }
      payload = DocumentRuntimePayload(source: nextSource, state: nextState,
        editable: ownsEditing, renderToken: DocumentSnapshotCache.token(document: document, state: state, pageIndex: selectedPageIndex),
        pageIndex: selectedPageIndex, runtimeID: runtimeID, blockTokens: blockTokens,
        programMode: programMode, drafts: Array(draftsByID.values))
      sendFrameIfReady()
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
    sendFrameIfReady()
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
    if navigationAction.navigationType == .linkActivated { decisionHandler(.cancel); return }
    decisionHandler(
      url.isFileURL || url.scheme == "about" ? .allow : .cancel
    )
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == "notebook", message.frameInfo.isMainFrame, let source = message.webView,
      let body = message.body as? [String: Any] else { return }
    receive(body: body, from: source)
  }

  func receive(body: [String: Any], from source: WKWebView) {
    guard !isInvalidated, source === webView, let kind = body["kind"] as? String else { return }

    if kind == "ready" {
      isReady = true
      sendFrameIfReady()
      return
    }
    guard let documentID = body["documentID"] as? String,
      let payload,
      documentID.caseInsensitiveCompare(payload.documentID.uuidString) == .orderedSame
    else { return }
    if kind == "presentationChanged" {
      guard let presentation = try? presentation(in: body as NSDictionary, for: payload,
        generation: generation, requiresPage: false) else { return }
      observePresentation(presentation)
      return
    }
    if kind == "link" {
      guard acceptsInput, renderIsReady, let href = body["href"] as? String,
        let receipt = try? presentation(in: body as NSDictionary, for: payload, generation: generation),
        receipt.kind == .canonical, receipt == pixelPresentation, let layout = payload.source.layout
      else { return }
      let destination = layout.destination(for: href)
      // A passive fragment or a programmatic external click cannot launch an app.
      if case .external = destination, body["userActivated"] as? Bool != true { return }
      onLinkNavigation(destination)
      return
    }
    if kind == "renderStarted" {
      guard body["runtimeID"] as? String == runtimeID.uuidString,
        body["generation"] as? String == String(generation),
        body["sourceKey"] as? String == payload.source.message.key,
        body["stateKey"] as? String == payload.state.message.key,
        body["renderToken"] as? String == payload.renderToken else { return }
      layoutAccepted = false; canonicalPixelEpoch = nil
      renderedToken = nil; appliedPageIndex = nil; pageIndexRequestID = nil
      setRenderReady(false); beginPreparationDeadline()
      return
    }
    if kind == "rendered" {
      guard let renderToken = body["renderToken"] as? String,
        body["runtimeID"] as? String == runtimeID.uuidString,
        body["generation"] as? String == String(generation),
        body["sourceKey"] as? String == payload.source.message.key,
        body["stateKey"] as? String == payload.state.message.key,
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
    if kind == "renderFailed" {
      guard body["renderToken"] as? String == payload.renderToken,
        body["runtimeID"] as? String == runtimeID.uuidString,
        body["generation"] as? String == String(generation),
        body["sourceKey"] as? String == payload.source.message.key,
        body["stateKey"] as? String == payload.state.message.key else { return }
      failPreparation(SceneRenderError.snapshotPending(body["message"] as? String ?? payload.documentID.uuidString))
      return
    }
    guard body["runtimeID"] as? String == runtimeID.uuidString,
      let blockID = body["blockID"] as? String else { return }
    switch kind {
    case "draft":
      guard let draft: DocumentEditingSession = Self.decode(body["session"]),
        draft.edit.documentID == payload.documentID, draft.edit.blockID == blockID,
        ownsEditing else { return }
      acceptDraft(draft)
    case "discardDraft":
      guard let raw = body["sessionID"] as? String, let id = UUID(uuidString: raw), draftsByID[id] != nil else { return }
      draftsByID[id] = nil
      DocumentRenderRegistry.shared.removeDraft(documentID: payload.documentID, sessionID: id)
      onDraftDiscard(id)
    case "source":
      guard let edit: DocumentSourceEdit = Self.decode(body["edit"]),
        edit.documentID == payload.documentID, edit.blockID == blockID,
        ownsEditing || draftsByID[edit.sessionID] != nil else { return }
      DocumentRenderRegistry.shared.commitSource(edit, using: onSourceChange)
    case "state":
      guard acceptsInput, body["blockToken"] as? String == blockTokens[blockID],
        payload.blocks.contains(where: { $0.id == blockID && $0.kind == .interactive }),
        let value: JSONValue = Self.decode(body["value"]) else { return }
      onStateChange(blockID, value)
    default: return
    }
  }

  private static func decode<T: Decodable>(_ value: Any?) -> T? {
    guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private func presentation(in raw: Any?, for payload: DocumentRuntimePayload, generation: UInt64,
    requiresPage: Bool = true) throws -> DocumentPixelPresentation {
    guard let value = raw as? NSDictionary,
      let documentID = value["documentID"] as? String,
      documentID.caseInsensitiveCompare(payload.documentID.uuidString) == .orderedSame,
      value["runtimeID"] as? String == payload.runtimeID.uuidString,
      value["generation"] as? String == String(generation),
      value["sourceKey"] as? String == payload.source.message.key,
      value["stateKey"] as? String == payload.state.message.key,
      value["renderToken"] as? String == payload.renderToken,
      !requiresPage || (value["pageIndex"] as? Int) == appliedPageIndex,
      let presentation = DocumentPixelPresentation(value) else { throw DocumentSnapshotWait.presentationChanged }
    return presentation
  }

  private func observePresentation(_ value: DocumentPixelPresentation) {
    if let previous = pixelPresentation {
      guard value.epoch > previous.epoch else { return }
    }
    pixelPresentation = value; canonicalPixelEpoch = nil
    refreshLiveReceipt()
    if readerID != nil {
      finishReader(throwing: value.kind == .editor ? DocumentSnapshotWait.editorActive : .presentationChanged)
    }
  }

  private static func sameProgram(_ left: DocumentBlock, _ right: DocumentBlock) -> Bool {
    left.id == right.id && left.kind == right.kind && left.source == right.source && left.html == right.html
      && left.css == right.css && left.javaScript == right.javaScript
  }

  private func sendFrameIfReady() {
    guard !isInvalidated, isReady, webView != nil, payload != nil,
      sentGeneration != generation else { return }
    // A latest frame needs its own deadline even while the single sender is
    // still encoding or evaluating its predecessor.
    beginPreparationDeadline()
    guard frameTask == nil else { return }
    let taskID = UUID(); frameTaskID = taskID
    frameTask = Task { @MainActor [weak self] in
      defer {
        if let self, frameTaskID == taskID { frameTask = nil; frameTaskID = nil }
      }
      while let self, !Task.isCancelled, !isInvalidated, isReady, frameTaskID == taskID,
        let web = webView, let next = payload, sentGeneration != generation {
        let expected = generation
        do {
          guard let lease = surfaceLease else { throw CancellationError() }
          let prepared = try await next.source.preparedPage(next.pageIndex, in: web, lease: lease, resources: resources)
          let source = sentSourceKey == next.source.message.key && sentSourcePage == prepared.fragment.pageIndex
            ? nil : try await prepared.encodedMessage(resources: resources)
          defer { withExtendedLifetime(source) {} }
          let state = sentStateKey == next.state.message.key ? nil : try await next.state.encodedJSON()
          guard !Task.isCancelled, !isInvalidated, frameTaskID == taskID, webView === web else { return }
          guard generation == expected else { continue }
          let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
          guard let current = payload else { return }
          let frame = String(decoding: try encoder.encode(current.frame(generation: expected)), as: UTF8.self)
          var script = ""
          if let source { script += "await window.notebookRenderer.installPageSource(\(source.json));" }
          if let state { script += "window.notebookRenderer.applyState(\(state));" }
          script += "void window.notebookRenderer.presentPage(\(frame));"
          try await evaluateFrame(script, message: source, lease: lease, in: web)
          guard !Task.isCancelled, !isInvalidated, frameTaskID == taskID, webView === web else { return }
          sentSourceKey = next.source.message.key; sentSourcePage = prepared.fragment.pageIndex; sentStateKey = next.state.message.key; sentGeneration = expected
        } catch {
          guard !Task.isCancelled, !isInvalidated, frameTaskID == taskID, generation == expected else { continue }
          failPreparation(error); return
        }
      }
    }
  }

  private func evaluateFrame(_ script: String, message: DocumentPageMessage?, lease: WebSurfaceLease, in web: WKWebView) async throws {
    let borrow = try lease.borrow()
    try await withCheckedThrowingContinuation { continuation in
      let id = UUID(); frameEvaluationID = id; frameContinuation = continuation
      web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self, message, borrow] result in
        defer { borrow.release(); withExtendedLifetime(message) {} }
        if case .failure(let error) = result { self?.finishFrameEvaluation(id: id, throwing: error) }
        else { self?.finishFrameEvaluation(id: id) }
      }
    }
  }

  private func finishFrameEvaluation(id: UUID? = nil, throwing error: Error? = nil) {
    if let id, frameEvaluationID != id { return }
    frameEvaluationID = nil
    let continuation = frameContinuation; frameContinuation = nil
    if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
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
    #if os(iOS)
      let frameReadiness = snapshotPixelWidth == nil
        ? "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));" : ""
    #else
      let frameReadiness = ""
    #endif
    webView.callAsyncJavaScript(
      """
      window.notebookRenderer.setPageIndex(index);
      \(frameReadiness)
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
          receipt["generation"] as? String == String(expectedGeneration),
          receipt["sourceKey"] as? String == payload.source.message.key,
          receipt["stateKey"] as? String == payload.state.message.key,
          let receiptPage = (receipt["pageIndex"] as? NSNumber)?.intValue,
          receiptPage == value
        else {
          appliedPageIndex = nil
          setRenderReady(false)
          return
        }
        if receipt["layoutCanonical"] as? Bool == true {
          do {
            try DocumentRenderRegistry.shared.publish(documentID: payload.documentID, token: payload.renderToken, receipt: receipt,
              geometry: .document(payload.paper.kind))
            layoutAccepted = true
          } catch { failPreparation(error); return }
        } else { layoutAccepted = false }
        appliedPageIndex = receiptPage
        if let presentation = try? presentation(in: receipt, for: payload, generation: expectedGeneration) {
          observePresentation(presentation)
          canonicalPixelEpoch = presentation.kind == .canonical && pixelPresentation == presentation ? presentation.epoch : nil
        } else { canonicalPixelEpoch = nil }
        setRenderReady(requestedPageIndex == receiptPage)
        applyPageIndexIfReady()
        capturePendingSnapshotIfReady()
      }
    )
  }

  private func setRenderReady(_ ready: Bool) {
    guard !isInvalidated else { return }
    guard renderIsReady != ready else {
      refreshLiveReceipt()
      if hasCanonicalPixels { wakeSnapshotWaiters() }
      return
    }
    renderIsReady = ready
    refreshLiveReceipt()
    if hasCanonicalPixels { wakeSnapshotWaiters() }
    if ready, !capturesSnapshot || pixelPresentation?.kind == .editor {
      preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
    }
    if ready, snapshotPixelWidth == nil { host?.removeFallback() }
    onRenderReady(ready && (snapshotPixelWidth == nil || snapshotOnlyComplete))
  }

  /// A thumbnail borrows pixels from the already mounted page. It neither
  /// starts that page's programs again nor revokes the page's input lease.
  func retainPreparedSnapshot(pixelWidth: Int, nativeScale: Double? = nil) async throws -> RasterLease {
    guard let payload, !isInvalidated else { throw CancellationError() }
    let source = SceneRasterSource.document(id: payload.documentID, token: payload.renderToken)
    let minimumScale = nativeScale ?? Self.snapshotMinimumScale(pixelWidth: pixelWidth, size: physicalSize)
    if let cached = resources.retainRaster(for: source, minimumScale: minimumScale) { return cached }
    if readerTask == nil {
      let expectedGeneration = generation
      let taskID = UUID(); readerTaskID = taskID
      readerTask = Task { @MainActor [weak self] in
        guard let self else { throw CancellationError() }
        defer { if readerTaskID == taskID { readerTaskID = nil; readerTask = nil } }
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
          try Task.checkCancellation()
          guard !isInvalidated, generation == expectedGeneration else { throw CancellationError() }
          if let cached = resources.retainRaster(for: source, minimumScale: minimumScale) {
            readerPreparedLease?.release(); readerPreparedLease = cached; return
          }
          if let acquisitionError { throw acquisitionError }
          if pixelPresentation?.kind == .editor { throw DocumentSnapshotWait.editorActive }
          if hasCanonicalPixels, webView != nil { break }
          guard ContinuousClock.now < deadline else { throw SceneRenderError.snapshotPending("document_snapshot_producer") }
          try await Task.sleep(for: .milliseconds(20))
        }
        guard let web = webView else { throw CancellationError() }
        let size = web.bounds.size
        guard size.width > 0, size.height > 0,
          let reservation = resources.reserveRaster(pixelWidth: pixelWidth,
            pixelHeight: Int(ceil(Double(pixelWidth) * size.height / size.width))) else { throw SceneRenderError.resourceLimit }
        #if os(iOS)
          let scale = web.window?.screen.scale ?? 2
        #else
          let scale = web.window?.backingScaleFactor ?? 2
        #endif
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
          let capture = DocumentSnapshotCapture(reservation: reservation)
          readerID = id; readerContinuation = continuation; readerCapture = capture
          readerDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, readerID == id else { return }
            finishReader(throwing: SceneRenderError.snapshotPending("document_snapshot_timeout"))
          }
          beginCanonicalSnapshot(id: id, capture: capture, payload: payload, generation: expectedGeneration,
            pixelWidth: pixelWidth, size: size, scale: scale, nativeScale: nativeScale)
        }
      }
    }
    do { try await readerTask?.value }
    catch {
      if !isInvalidated, let retained = resources.retainRaster(for: source, minimumScale: minimumScale) { return retained }
      throw error
    }
    try Task.checkCancellation()
    guard !isInvalidated, self.payload?.renderToken == payload.renderToken,
      let retained = resources.retainRaster(for: source, minimumScale: minimumScale) else { throw SceneRenderError.resourceLimit }
    return retained
  }

  /// The image remains reserved and private until both actual WebKit receipts
  /// name the same canonical presentation. An open/close cycle changes epoch
  /// even if it returns to the same source and no textarea remains afterward.
  private func beginCanonicalSnapshot(id: UUID, capture: DocumentSnapshotCapture,
    payload: DocumentRuntimePayload, generation expected: UInt64,
    pixelWidth: Int, size: CGSize, scale: Double, nativeScale: Double?) {
    guard let web = webView else { finishReader(throwing: CancellationError()); return }
    web.evaluateJavaScript("window.notebookRenderer.presentationReceipt()") { [weak self, capture] raw, error in
      guard let self, readerID == id else { capture.cancel(); return }
      do {
        if let error { throw error }
        let before = try canonicalSnapshotPresentation(raw, payload: payload, generation: expected)
        guard let web = webView else { throw CancellationError() }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        if nativeScale == nil { configuration.snapshotWidth = NSNumber(value: Double(pixelWidth) / scale) }
        capture.submit()
        web.takeSnapshot(with: configuration) { [weak self, capture] image, error in
          guard capture.receive(image) else { return }
          guard let self, readerID == id else { capture.cancel(); return }
          if let error { finishReader(throwing: error); return }
          guard image != nil, let web = webView else {
            finishReader(throwing: SceneRenderError.snapshotPending("document_snapshot_empty")); return
          }
          web.evaluateJavaScript("window.notebookRenderer.presentationReceipt()") { [weak self, capture] raw, error in
            guard let self, readerID == id else { capture.cancel(); return }
            do {
              if let error { throw error }
              let after = try canonicalSnapshotPresentation(raw, payload: payload, generation: expected)
              guard before == after, let image = capture.image, let reservation = capture.reservation else {
                throw DocumentSnapshotWait.presentationChanged
              }
              #if os(iOS)
                guard let cg = image.cgImage else { throw SceneRenderError.resourceLimit }
                let normalized = UIImage(cgImage: cg, scale: nativeScale ?? Double(cg.width) / size.width, orientation: .up)
              #else
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw SceneRenderError.resourceLimit }
                let outputSize = nativeScale.map { CGSize(width: Double(cg.width) / $0, height: Double(cg.height) / $0) } ?? size
                let normalized = NSImage(cgImage: cg, size: outputSize)
              #endif
              let source = SceneRasterSource.document(id: payload.documentID, token: payload.renderToken)
              guard let layout = payload.source.layout,
                DocumentSnapshotCache.shared.store(image: normalized, documentID: payload.documentID,
                token: payload.renderToken, layout: layout, reservation: reservation, resources: resources),
                let retained = resources.retainRaster(for: source,
                  minimumScale: nativeScale ?? Self.snapshotMinimumScale(pixelWidth: pixelWidth, size: size)) else { throw SceneRenderError.resourceLimit }
              readerPreparedLease?.release(); readerPreparedLease = retained
              finishReader()
            } catch { finishReader(throwing: error) }
          }
        }
      } catch { finishReader(throwing: error) }
    }
  }

  private func canonicalSnapshotPresentation(_ raw: Any?, payload: DocumentRuntimePayload,
    generation expected: UInt64) throws -> DocumentPixelPresentation {
    guard !isInvalidated, generation == expected else { throw CancellationError() }
    let value = try presentation(in: raw, for: payload, generation: expected)
    guard value.kind != .editor else { throw DocumentSnapshotWait.editorActive }
    guard hasCanonicalPixels, value.kind == .canonical, value == pixelPresentation,
      value.epoch == canonicalPixelEpoch else { throw DocumentSnapshotWait.presentationChanged }
    return value
  }

  private func finishReader(throwing error: (any Error)? = nil) {
    readerID = nil
    readerCapture?.cancel(); readerCapture = nil
    readerDeadline?.cancel(); readerDeadline = nil
    let continuation = readerContinuation; readerContinuation = nil
    if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
  }

  /// A preview is capped at its declared width. Admission uses both integral
  /// pixel axes: WebKit rounds the derived height down, not to a fractional pixel.
  private static func snapshotMinimumScale(pixelWidth: Int, size: CGSize) -> Double {
    guard size.width > 0, size.height > 0 else { return 0 }
    let height = max(1, floor(Double(pixelWidth) * size.height / size.width))
    return min(Double(pixelWidth) / size.width, height / size.height)
  }

  private func capturePendingSnapshotIfReady() {
    guard !isInvalidated, capturesSnapshot, !snapshotOnlyComplete, snapshotTask == nil,
      hasCanonicalPixels, pageIndexRequestID == nil, appliedPageIndex == requestedPageIndex,
      let payload = pendingSnapshotPayload, let web = webView else { return }
    let physicalSize = web.bounds.size
    guard physicalSize.width > 1, physicalSize.height > 1 else { return }
    #if os(iOS)
      let scale = web.window?.screen.scale ?? 2
    #else
      let scale = web.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    #endif
    let pixelWidth = snapshotPixelWidth ?? Int(ceil(physicalSize.width * scale))
    let expected = generation, id = UUID(), attemptedEpoch = canonicalPixelEpoch
    snapshotCaptureID = id; pendingSnapshotPayload = nil
    snapshotTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if snapshotCaptureID == id {
          snapshotCaptureID = nil; snapshotTask = nil
          // Closing may finish its canonical frame before this task receives
          // the rejected old image. Only a newer epoch earns another attempt.
          if pendingSnapshotPayload != nil, canonicalPixelEpoch != attemptedEpoch {
            capturePendingSnapshotIfReady()
          }
        }
      }
      do {
        let raster = try await retainPreparedSnapshot(pixelWidth: pixelWidth, nativeScale: snapshotPixelWidth == nil ? scale : nil)
        defer { raster.release() }
        guard !Task.isCancelled, !isInvalidated, generation == expected, snapshotCaptureID == id else { return }
        preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
        if snapshotPixelWidth != nil {
          guard host?.showFallback(source: fallbackSource, resources: resources) == true else { throw SceneRenderError.resourceLimit }
          snapshotOnlyComplete = true
          releaseWebSurface()
          onRenderReady(true)
        } else if requestedPriority == .background {
          preparedSnapshotLease?.release()
          preparedSnapshotLease = resources.retainRaster(for: raster.source)
        }
      } catch {
        guard !Task.isCancelled, !isInvalidated, generation == expected, snapshotCaptureID == id else { return }
        if error is DocumentSnapshotWait {
          // The editor keeps input and its WebKit. A canonical completion will
          // retry this capture without treating intentional editing as failure.
          pendingSnapshotPayload = payload
          preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
        } else { failPreparation(error) }
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
    private var failureView: UIStackView?
    func showFailure(_ message: String, retry: @escaping () -> Void) {
      removeFailure()
      let label = UILabel(); label.text = message; label.numberOfLines = 0; label.textAlignment = .center
      label.font = .preferredFont(forTextStyle: .caption1)
      let button = UIButton(configuration: .bordered(), primaryAction: UIAction(title: "Повторить") { _ in retry() })
      let stack = UIStackView(arrangedSubviews: [label, button]); stack.axis = .vertical; stack.spacing = 8
      stack.backgroundColor = .secondarySystemBackground; stack.layer.cornerRadius = 12
      stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack); failureView = stack
      NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24)])
    }
    func removeFailure() { failureView?.removeFromSuperview(); failureView = nil }
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
    let onSourceChange: (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status
    let onStateChange: (String, JSONValue) -> Void
    let resources: SceneRenderResources
    var drafts: [DocumentEditingSession] = []
    var onDraftChange: (DocumentEditingSession) -> Void = { _ in }
    var onDraftDiscard: (UUID) -> Void = { _ in }
    var snapshotPixelWidth: Int? = nil
    var onPreparationFailure: (Error) -> Void = { _ in }
    var onLinkNavigation: (DocumentLinkDestination) -> Void = { _ in }
    func makeCoordinator() -> DocumentWebCoordinator {
      DocumentWebCoordinator(resources: resources, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange)
    }
    func makeUIView(context: Context) -> DocumentWebHost { DocumentWebHost() }
    func updateUIView(_ view: DocumentWebHost, context: Context) {
      context.coordinator.update(document: document, state: state, selectedPageIndex: selectedPageIndex,
        capturesSnapshot: capturesSnapshot, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange, snapshotPixelWidth: snapshotPixelWidth,
        drafts: drafts, onDraftChange: onDraftChange, onDraftDiscard: onDraftDiscard,
        onPreparationFailure: onPreparationFailure, onLinkNavigation: onLinkNavigation)
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
    private var failureView: NSStackView?
    private var retryAction: (() -> Void)?
    func showFailure(_ message: String, retry: @escaping () -> Void) {
      removeFailure(); retryAction = retry
      let label = NSTextField(wrappingLabelWithString: message); label.alignment = .center
      let button = NSButton(title: "Повторить", target: self, action: #selector(retryPreparation))
      let stack = NSStackView(views: [label, button]); stack.orientation = .vertical; stack.spacing = 8
      stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack); failureView = stack
      NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 300)])
    }
    @objc private func retryPreparation() { retryAction?() }
    func removeFailure() { failureView?.removeFromSuperview(); failureView = nil; retryAction = nil }
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
      // NSWindow rounds its content size to points. Paper, pagination and
      // snapshot density belong to this canonical viewport, not that rounding.
      web.frame = .init(origin: .zero, size: size); web.autoresizingMask = []
    }
    func configure(size: CGSize, interactive: Bool) {
      if web?.frame.size != size { web?.setFrameSize(size) }
      web?.setAccessibilityHidden(!interactive)
    }
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
    let onSourceChange: (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status
    let onStateChange: (String, JSONValue) -> Void
    let resources: SceneRenderResources
    var drafts: [DocumentEditingSession] = []
    var onDraftChange: (DocumentEditingSession) -> Void = { _ in }
    var onDraftDiscard: (UUID) -> Void = { _ in }
    var snapshotPixelWidth: Int? = nil
    var onPreparationFailure: (Error) -> Void = { _ in }
    var onLinkNavigation: (DocumentLinkDestination) -> Void = { _ in }
    func makeCoordinator() -> DocumentWebCoordinator {
      DocumentWebCoordinator(resources: resources, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange)
    }
    func makeNSView(context: Context) -> DocumentWebHost { DocumentWebHost() }
    func updateNSView(_ view: DocumentWebHost, context: Context) {
      context.coordinator.update(document: document, state: state, selectedPageIndex: selectedPageIndex,
        capturesSnapshot: capturesSnapshot, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange, snapshotPixelWidth: snapshotPixelWidth,
        drafts: drafts, onDraftChange: onDraftChange, onDraftDiscard: onDraftDiscard,
        onPreparationFailure: onPreparationFailure, onLinkNavigation: onLinkNavigation)
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      context.coordinator.mount(in: view, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: isInteractive, priority: snapshotPixelWidth != nil ? .visible : (isInteractive ? .currentPage : .neighbor))
    }
    static func dismantleNSView(_ view: DocumentWebHost, coordinator: DocumentWebCoordinator) { coordinator.invalidate() }
  }
#endif
