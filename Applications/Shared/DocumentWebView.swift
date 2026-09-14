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

    func storeAndRetain(image: AgentSnapshotImage, documentID: UUID, token: String, layout: DocumentLayoutRecord,
      reservation: RasterReservation, resources: SceneRenderResources) -> RasterLease? {
      guard let raster = resources.storeAndRetain(image, for: .document(id: documentID, token: token),
        reservation: reservation, documentLayout: layout) else { return nil }
      NotificationCenter.default.post(name: Self.didChange, object: documentID)
      return raster
    }

    #if os(macOS)
    func prepare(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int,
      resources: SceneRenderResources = .shared) async throws -> RasterLease {
      let source = SceneRasterSource.document(id: document.id,
        token: Self.token(document: document, state: state, pageIndex: pageIndex))
      let requiredScale = Double(NSScreen.main?.backingScaleFactor ?? 2)
      if let lease = resources.retainRaster(for: source, minimumScale: requiredScale) { return lease }
      let ready = PageTurnReadiness { _ in }
      let coordinator = DocumentWebCoordinator(resources: resources, onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _, _ in nil })
      let host = DocumentWebHost()
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: geometry.width, height: geometry.height),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
      defer { coordinator.invalidate(); window.orderOut(nil); window.close() }
      coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: false,
        onRenderReady: ready, onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _, _ in nil })
      coordinator.mount(in: host, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: false, priority: .background)
      return try await withTaskCancellationHandler {
        // The accepted request owns this queued producer. Its bounded render
        // and capture deadlines start only after physical WebKit admission.
        try await coordinator.awaitSurfaceAdmission()
        // This one reader returns its exact canonical capture; cache presence
        // and a second automatic capture are not completion notifications.
        return try await coordinator.retainPreparedSnapshot(
          pixelWidth: Int(ceil(geometry.width * requiredScale)), force: true,
          waitsForRasterAdmission: true)
      } onCancel: {
        Task { @MainActor in coordinator.invalidate() }
      }
    }
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
  let sourceRevision: String?

  init(pageCount: Int, sourceRevision: String? = nil) {
    self.pageCount = max(1, pageCount)
    self.sourceRevision = sourceRevision
  }

  func pageCount(for sourceRevision: String) -> Int? {
    self.sourceRevision == sourceRevision ? pageCount : nil
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
  let onLinkActivation: (DocumentLinkActivation) -> DocumentLinkDestination?
  let onSourceChange: (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status
  let onStateChange: (String, JSONValue) -> ContentFieldVersion?
  var drafts: [DocumentEditingSession] = []
  var onDraftChange: (DocumentEditingSession) -> Void = { _ in }
  var onDraftDiscard: (UUID) -> Void = { _ in }
  var resources: SceneRenderResources = .shared
  var isCurrent = true
  var isVisible = true
  var isPageTurnActive = false
  var onStateCheckpoint: (String, JSONValue, ContentFieldVersion) async throws -> Bool = { _, _, _ in false }
  var measurements: DocumentPresentationRecorder? = nil

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
      onLinkActivation: { activation in
        guard let destination = onLinkActivation(activation) else { return }
        switch destination {
        case .page: break
        case .external(let url): openURL(url) { accepted in
          if !accepted { linkFailure = "Система не смогла открыть эту ссылку." }
        }
        case .unavailable(let message): linkFailure = message
        }
      }, isCurrent: isCurrent, isVisible: isVisible, isPageTurnActive: isPageTurnActive,
      onStateCheckpoint: onStateCheckpoint, measurements: measurements
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
      onPageLayout: { _ in }, onSourceChange: { _ in .targetMissing }, onStateChange: { _, _ in nil },
      resources: resources, snapshotPixelWidth: 256, onPreparationFailure: onFailure, isCurrent: false)
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

  var rasterToken: String {
    let omitsPrograms = programMode == "external" && source.layout.map { layout in
      layout.blockIDs(on: [pageIndex]).intersection(source.programIDs).isEmpty == false
    } != false
    return omitsPrograms ? "paper:" + renderToken : renderToken
  }

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

/// A blocked capture is still an owned preparation. Its healthy physical
/// source stays charged while the pool cannot fit both capture backings.
struct DocumentSnapshotRasterDemand {
  let source: SceneRasterSource
  let pixelWidth: Int
  let pixelHeight: Int
  let bytes: Int
  let admission: SceneRasterAdmission
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
  private var preparesCommonRuntime = false
  private var emptyShellDeadline: Task<Void, Never>?
  private(set) var commonRuntimeReady = false
  var onCommonRuntimeReady: () -> Void = { }
  private var requestedPriority: WebPriority?
  private weak var host: DocumentWebHost?
  private(set) var isInvalidated = false
  private(set) var acquisitionError: Error?
  private(set) var acceptsInput = false
  private var requestedInput = false
  private(set) var ownsEditing = false
  var isPresentingEditor: Bool { pixelPresentation?.kind == .editor }
  private var physicalSize = CGSize(width: 1, height: 1)
  private var generation: UInt64 = 0
  private var preparationRequestID: UUID?
  private(set) var pagePreparationTrace: DocumentPagePreparationTrace?
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
  private var preparationAdmissionGeneration: UInt64?
  private var preparationDeadlineRemaining: Duration = .seconds(8)
  private var preparationDeadlineStarted: ContinuousClock.Instant?
  private var recoveryAttempts = 0
  private var snapshotTask: Task<Void, Never>?
  private var readerTask: Task<Void, any Error>?
  private var readerTaskID: UUID?
  private var readerID: UUID?
  private var readerContinuation: CheckedContinuation<Void, any Error>?
  private var readerDeadline: Task<Void, Never>?
  private var readerCapture: DocumentSnapshotCapture?
  private var readerPreparedLease: RasterLease?
  private(set) var pendingRasterSnapshot: DocumentSnapshotRasterDemand?
  private var rasterSnapshotAdmissionGeneration: UInt64?
  private var rasterSnapshotAdmissionObserver: NSObjectProtocol?
  private var rasterSnapshotAdmissionContinuation: CheckedContinuation<RasterReservation, Error>?
  var canShareSnapshot: Bool {
    !externallyHostedPrograms && !isInvalidated && acquisitionError == nil && payload != nil && webView != nil
      && surfaceLease?.isReleased == false
  }
  var resourceOwner: SceneRenderResources { resources }
  private var fallbackSource: SceneRasterSource?
  private var snapshotPixelWidth: Int?
  private var snapshotOnlyComplete = false
  private var snapshotCaptureID: UUID?
  private var onPreparationFailure: (Error) -> Void = { _ in }
  var preservesFallback = false
  var ownsProgramState = false
  var externallyHostedPrograms = false
  var holdsEditingOwnership = false
  var onProgramReady: () -> Void = { }
  var onProgramFocus: (Bool) -> Void = { _ in }
  var onPresentationChange: () -> Void = { }
  var onBeforeRuntimeRestart: () -> Void = { }
  var onSurfaceRetirement: (WKWebView) -> Void = { _ in }

  private struct PresentationWaiter {
    let generation: UInt64
    let token: String
    let allowsEditor: Bool
    let continuation: CheckedContinuation<Void, Error>
  }
  private var presentationWaiters: [UUID: PresentationWaiter] = [:]
  var pendingPresentationRequestCount: Int { presentationWaiters.count }

  /// Wait for this exact request, not a later page that happens to be ready.
  /// Admission and execution keep their existing owners and deadlines; this
  /// subscription adds no polling loop or competing overall timeout.
  func awaitPresentation(token: String, allowsEditor: Bool = false) async throws {
    try Task.checkCancellation()
    let id = UUID(), expected = generation
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        presentationWaiters[id] = .init(generation: expected, token: token,
          allowsEditor: allowsEditor, continuation: continuation)
        resolvePresentationWaiters()
        // An admitted surface can lose its canonical receipt without starting
        // a new source frame (for example when leaving an editor). The same
        // coordinator owns that execution deadline too; admission has its own.
        if presentationWaiters[id] != nil, webView != nil { beginPreparationDeadline() }
      }
      try Task.checkCancellation()
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.presentationWaiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
      }
    }
  }

  private func resolvePresentationWaiters() {
    for (id, waiter) in presentationWaiters {
      let result: Result<Void, Error>
      if isInvalidated || waiter.generation != generation || payload?.renderToken != waiter.token {
        result = .failure(CancellationError())
      } else if let acquisitionError {
        result = .failure(acquisitionError)
      } else if hasCanonicalPixels || (waiter.allowsEditor && renderIsReady && isPresentingEditor) {
        result = .success(())
      } else if !waiter.allowsEditor && isPresentingEditor {
        result = .failure(DocumentSnapshotWait.editorActive)
      } else { continue }
      presentationWaiters.removeValue(forKey: id)?.continuation.resume(with: result)
    }
  }

  private func cancelPresentationWaiters() {
    let pending = presentationWaiters; presentationWaiters.removeAll()
    for waiter in pending.values { waiter.continuation.resume(throwing: acquisitionError ?? CancellationError()) }
  }

  var canAdoptEmptyShell: Bool {
    !isInvalidated && payload == nil && renderSession == nil && acquisitionError == nil
      && webView != nil && surfaceLease?.isReleased == false && preparesCommonRuntime
  }

  func prepareEmptyShell(in host: DocumentWebHost, lease: WebSurfaceLease) {
    precondition(!isInvalidated && payload == nil && renderSession == nil && webView == nil
      && surfaceLease == nil && acquisitionTask == nil && lease.priority == .background && !lease.isReleased)
    self.host = host; surfaceLease = lease; requestedPriority = .background
    preparesCommonRuntime = true
    host.configure(size: physicalSize, interactive: false)
    let web = DocumentWebViewFactory.make(coordinator: self, lease: lease)
    host.install(web, size: physicalSize)
    emptyShellDeadline = Task { @MainActor [weak self, weak web] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard !Task.isCancelled, let self, let web, self.webView === web,
        !isInvalidated, payload == nil, !commonRuntimeReady else { return }
      failPreparation(SceneRenderError.snapshotPending("common_runtime_startup"))
    }
  }

  func claimEmptyShell() {
    precondition(canAdoptEmptyShell)
    emptyShellDeadline?.cancel(); emptyShellDeadline = nil
    onCommonRuntimeReady = { }
  }

  func borrowSurfaceForTransfer(_ web: WKWebView) -> WebSurfaceBorrow? {
    guard !isInvalidated, webView === web else { return nil }
    return try? surfaceLease?.borrow()
  }

  /// Event routing can change while the canonical pixels and their generation
  /// stay identical (for example after the measured page count reaches SwiftUI).
  func updateInteractionCallbacks(onDraftChange: @escaping (DocumentEditingSession) -> Void,
    onDraftDiscard: @escaping (UUID) -> Void,
    onLinkActivation: @escaping (DocumentLinkActivation) -> Void) {
    self.onDraftChange = onDraftChange; self.onDraftDiscard = onDraftDiscard
    self.onLinkActivation = onLinkActivation
  }

  /// A presentation-policy update never reloads its source or touches its
  /// canonical generation. Only this coordinator projects admission to its host.
  func updateInputAdmission(in host: DocumentWebHost, isInteractive: Bool) {
    guard !isInvalidated, self.host === host else { return }
    #if os(iOS)
      holdsEditingOwnership = isInteractive || host.hasActiveContact
    #else
      holdsEditingOwnership = isInteractive
    #endif
    applyInputAdmission(isInteractive)
  }

  private func applyInputAdmission(_ isInteractive: Bool) {
    requestedInput = isInteractive
    if let payload {
      DocumentRenderRegistry.shared.setEditingOwner(documentID: payload.documentID, hostID: hostID,
        active: isInteractive || holdsEditingOwnership)
    }
    refreshInputAdmission()
  }

  /// Pixel completion cannot claim editing ownership again after its transfer.
  /// Only a native interaction-policy request changes that ownership.
  private func refreshInputAdmission() {
    let isInteractive = requestedInput
    let installed = webView.map { host?.hasCanonicalSurface($0) == true } ?? false
    // Editor pixels are a valid installed input surface too. A snapshot or a
    // loading overlay never grants access to the DOM underneath it.
    acceptsInput = isInteractive && installed && (hasCanonicalPixels || (renderIsReady && isPresentingEditor))
    host?.configure(size: physicalSize, interactive: acceptsInput)
    if isInteractive, hasCanonicalPixels, let payload, let presentation = pixelPresentation, let host, let web = webView,
      host.hasCanonicalSurface(web) {
      admittedLinkOrigin = .init(source: payload.source, state: payload.state,
        runtimeID: payload.runtimeID, generation: generation, renderToken: payload.renderToken,
        pageIndex: payload.pageIndex, presentationEpoch: presentation.epoch)
    }
    refreshLiveReceipt()
  }

  /// Native programs share the same current canonical paper origin. The
  /// program owner additionally validates its own runtime and clipped placement.
  var currentLinkOrigin: DocumentLinkOrigin? {
    guard !isInvalidated, hasCanonicalPixels, let payload, let presentation = pixelPresentation,
      let host, let web = webView, host.hasCanonicalSurface(web) else { return nil }
    return .init(source: payload.source, state: payload.state, runtimeID: payload.runtimeID,
      generation: generation, renderToken: payload.renderToken, pageIndex: payload.pageIndex,
      presentationEpoch: presentation.epoch)
  }

  #if os(iOS)
  func nativeInputIsReady(in host: DocumentWebHost) -> Bool {
    guard !isInvalidated, acceptsInput, renderIsReady, self.host === host,
      let web = webView else { return false }
    return host.hasInteractiveSurface(web)
  }
  #endif

  func offerIdleReclamation(_ reclaim: (@MainActor () -> Void)?) {
    surfaceLease?.offerIdleReclamation(reclaim)
  }

  private func beginPreparationObservation(configuredAt: TimeInterval) {
    guard let requestID = preparationRequestID, let payload else { pagePreparationTrace = nil; return }
    if let trace = pagePreparationTrace, trace.identity.requestID == requestID,
      preparationObservationIsCurrent(trace) { return }
    pagePreparationTrace = DocumentPagePreparationTrace(identity: .init(requestID: requestID, attemptID: UUID(),
      coordinatorID: hostID, documentID: payload.documentID, generation: String(generation), runtimeID: runtimeID,
      sourceKey: payload.source.message.key, stateKey: payload.state.message.key, token: payload.renderToken,
      pageIndex: payload.pageIndex, configuredAt: configuredAt))
    recordPreparation(.payloadConfiguredAt)
    if surfaceLease?.isReleased == false { recordPreparation(.admissionReusedAt) }
    if isReady { recordPreparation(.shellReusedAt) }
    if hasCanonicalPixels { recordPreparation(.canonicalReusedAt) }
  }

  private func preparationObservationIsCurrent(_ trace: DocumentPagePreparationTrace) -> Bool {
    guard !isInvalidated, let payload else { return false }
    let identity = trace.identity
    return identity.requestID == preparationRequestID && identity.generation == String(generation)
      && identity.runtimeID == runtimeID && identity.sourceKey == payload.source.message.key
      && identity.stateKey == payload.state.message.key && identity.token == payload.renderToken
      && identity.documentID == payload.documentID && identity.pageIndex == payload.pageIndex
  }

  private func recordPreparation(_ stage: DocumentPagePreparationTrace.Stage) {
    recordPreparation(stage, trace: pagePreparationTrace)
  }

  private func recordPreparation(_ stage: DocumentPagePreparationTrace.Stage, trace: DocumentPagePreparationTrace?) {
    guard let trace, pagePreparationTrace === trace, preparationObservationIsCurrent(trace) else { return }
    trace.mark(stage)
    #if os(iOS)
    if DocumentPagePreparationTrace.visibilityStages.contains(stage) {
      trace.recordNativeVisibility(preparationVisibility(), at: stage)
    }
    #endif
    if stage == .preparedPageStartAt || stage == .frameEvaluationStartAt {
      let identity = trace.identity
      // An opt-in scalar observation precedes the existing source/frame call
      // on this same WK queue. It does not request layout, pixels or readiness.
      webView?.callAsyncJavaScript("window.notebookRenderer.observePreparation(observation);",
        arguments: ["observation": ["attemptID": identity.attemptID.uuidString,
          "documentID": identity.documentID.uuidString, "runtimeID": identity.runtimeID.uuidString,
          "generation": identity.generation, "sourceKey": identity.sourceKey,
          "stateKey": identity.stateKey, "renderToken": identity.token, "pageIndex": identity.pageIndex]],
        in: nil, in: .page, completionHandler: nil)
    }
  }

  #if os(iOS)
  private func preparationVisibility() -> [String: Double] {
    guard let webView else { return ["hasWeb": 0] }
    var value: [String: Double] = ["hasWeb": 1, "hasWindow": webView.window == nil ? 0 : 1,
      "webBoundsWidth": webView.bounds.width, "webBoundsHeight": webView.bounds.height,
      "hostBoundsWidth": Double(host?.bounds.width ?? 0), "hostBoundsHeight": Double(host?.bounds.height ?? 0),
      "applicationActive": UIApplication.shared.applicationState == .active ? 1 : 0]
    let window = webView.window
    var intersection = window.map { webView.convert(webView.bounds, to: $0).intersection($0.bounds) } ?? .null
    if let window {
      let rect = webView.convert(webView.bounds, to: window)
      value.merge(["windowIsKey": window.isKeyWindow ? 1 : 0,
        "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
        "webWindowX": rect.minX, "webWindowY": rect.minY,
        "webWindowWidth": rect.width, "webWindowHeight": rect.height]) { _, new in new }
    }
    var ancestor: UIView? = webView, count = 0, hidden = 0, alpha = 1.0
    while let view = ancestor, count < 64 {
      count += 1
      if view.isHidden { hidden += 1 }
      alpha *= Double(view.alpha)
      if let window, view.clipsToBounds { intersection = intersection.intersection(view.convert(view.bounds, to: window)) }
      ancestor = view.superview
    }
    value.merge(["ancestorCount": Double(count), "ancestorWalkTruncated": ancestor == nil ? 0 : 1,
      "hiddenAncestorCount": Double(hidden), "ancestorAlphaProduct": alpha,
      "clippedIntersectionWidth": intersection.isNull ? 0 : intersection.width,
      "clippedIntersectionHeight": intersection.isNull ? 0 : intersection.height]) { _, new in new }
    // UIView model geometry is only an upper bound. This does not inspect
    // sibling occlusion, presentation layers or actual compositor display.
    return value.filter { $0.value.isFinite }
  }
  #endif

  func mount(in host: DocumentWebHost, physicalSize: CGSize, isInteractive: Bool, priority: WebPriority) {
    guard !isInvalidated else { return }
    beginPreparationObservation(configuredAt: ProcessInfo.processInfo.systemUptime)
    recordPreparation(.mountAt)
    let previousHost = self.host
    self.host = host
    if previousHost !== host, let webView {
      host.install(webView, size: physicalSize)
      previousHost?.removeSurface()
    }
    DocumentRenderRegistry.shared.mountRenderer(self, hostID: hostID)
    self.physicalSize = physicalSize
    applyInputAdmission(isInteractive)
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
    if !renderIsReady, !preservesFallback { host.showFallback(source: fallbackSource, resources: resources) }
    if webView != nil {
      surfaceLease?.updatePriority(priority); requestedPriority = priority
      if !hasCanonicalPixels && !isPresentingEditor { beginPreparationDeadline() }
      return
    }
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
    recordPreparation(.admissionRequestedAt)
    acquisitionTask = Task { [weak self] in
      do {
        let lease = try await resources.acquireWebSurface(priority: priority)
        guard let self, !Task.isCancelled, !isInvalidated, acquisitionID == id, let host = self.host else {
          lease.release(); return
        }
        acquisitionTask = nil
        surfaceLease = lease
        recordPreparation(.admittedAt)
        beginPreparationDeadline()
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

  /// Used by an exclusive headless preparation. Queue ownership is separate
  /// from its subsequent source/readback deadline; cancellation is projected
  /// to this coordinator by that preparation's cancellation handler.
  func awaitSurfaceAdmission() async throws {
    let expectedGeneration = generation, expectedAdmission = acquisitionID
    if let acquisitionTask { await acquisitionTask.value }
    try Task.checkCancellation()
    guard !isInvalidated, generation == expectedGeneration else { throw CancellationError() }
    if let acquisitionError { throw acquisitionError }
    guard acquisitionID == expectedAdmission, webView != nil, surfaceLease?.isReleased == false else {
      throw CancellationError()
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
      mount(in: host, physicalSize: physicalSize, isInteractive: requestedInput, priority: priority)
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
    pagePreparationTrace = nil; preparationRequestID = nil
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
    onPageLayout = { _ in }; onSourceChange = { _ in .targetMissing }; onStateChange = { _, _ in nil }
    onPreparationFailure = { _ in }; onLinkActivation = { _ in }
    onDraftChange = { _ in }; onDraftDiscard = { _ in }
    releaseWebSurface()
    payload = nil; renderSession = nil
    if !preservesFallback { host?.removeFallback() }
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
    onPresentationChange()
  }

  func retryPreparation() {
    guard !isInvalidated, let host, let priority = requestedPriority else { return }
    acquisitionError = nil; recoveryAttempts = 0
    onBeforeRuntimeRestart()
    if let payload { payload.source.retryPagePreparation(payload.pageIndex) }
    host.removeFailure()
    runtimeID = UUID(); payload?.runtimeID = runtimeID; payload?.drafts = Array(draftsByID.values)
    mount(in: host, physicalSize: physicalSize, isInteractive: requestedInput, priority: priority)
  }

  private func beginPreparationDeadline() {
    if preparationDeadlineGeneration != generation {
      preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
      preparationDeadlineGeneration = generation; preparationAdmissionGeneration = nil
      preparationDeadlineRemaining = .seconds(8); preparationDeadlineStarted = nil
    }
    guard preparationDeadlineTask == nil, preparationAdmissionGeneration != generation else { return }
    let expected = generation, remaining = preparationDeadlineRemaining
    preparationDeadlineStarted = .now
    preparationDeadlineTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: remaining) } catch { return }
      guard let self, !isInvalidated, generation == expected, preparationAdmissionGeneration != expected else { return }
      failPreparation(SceneRenderError.snapshotPending("document_preparation_timeout"))
    }
  }

  /// The source owner reports actual pool admission events. A queued fragment
  /// consumes none of its renderer's execution deadline; repeated waits cannot
  /// reset the eight seconds already spent executing the same generation.
  private func preparationAdmissionChanged(_ waiting: Bool, generation expected: UInt64) {
    guard !isInvalidated, generation == expected, acquisitionError == nil else { return }
    if waiting {
      guard preparationAdmissionGeneration != expected else { return }
      preparationAdmissionGeneration = expected
      if let started = preparationDeadlineStarted, preparationDeadlineTask != nil {
        preparationDeadlineRemaining = max(.zero, preparationDeadlineRemaining - started.duration(to: .now))
      }
      preparationDeadlineStarted = nil
      preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
    } else if preparationAdmissionGeneration == expected {
      preparationAdmissionGeneration = nil
      beginPreparationDeadline()
    }
  }

  func revokeEditingOwnership() {
    ownsEditing = false; payload?.editable = false
  }

  func activateEditing(drafts: [DocumentEditingSession]) {
    guard !isInvalidated, requestedInput || holdsEditingOwnership else { return }
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

  /// An idle preparation executor retains its reusable shell, but is no longer
  /// a consumer of the fragment it last painted. Mounted presentations own the
  /// remaining page demand and actual raster consumers own their pixels.
  func releasePreparedPageDemand() {
    guard hasCanonicalPixels, !requestedInput, !holdsEditingOwnership else { return }
    payload?.source.releasePage(hostID: hostID, in: nil)
  }

  private func refreshLiveReceipt() {
    guard !externallyHostedPrograms, hasCanonicalPixels, snapshotPixelWidth == nil, acceptsInput, let payload,
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
    onBeforeRuntimeRestart()
    mount(in: host, physicalSize: physicalSize, isInteractive: requestedInput, priority: priority)
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
    cancelPresentationWaiters()
    let retiringWeb = webView
    if frameEvaluationID != nil, let retiringWeb, let borrow = try? surfaceLease?.borrow() {
      // End the renderer's logical program wait before returning its executor.
      // The submitted frame and this cancellation keep their actual borrows
      // until WebKit completes; source measurement beside them is independent.
      retiringWeb.callAsyncJavaScript("window.notebookRenderer?.retirePresentation(runtimeID); return true;",
        arguments: ["runtimeID": runtimeID.uuidString], in: nil, in: .page) { _ in borrow.release() }
    }
    emptyShellDeadline?.cancel(); emptyShellDeadline = nil
    commonRuntimeReady = false; preparesCommonRuntime = false
    admittedLinkOrigin = nil; lastLinkSequence = 0
    payload?.source.releasePage(hostID: hostID, in: retiringWeb)
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
    if let retiringWeb { onSurfaceRetirement(retiringWeb) }
    surfaceLease?.release(); surfaceLease = nil
  }

  private func cancelSnapshotPreparation() {
    snapshotCaptureID = nil
    snapshotTask?.cancel(); snapshotTask = nil
    finishReader(throwing: CancellationError())
    finishRasterSnapshotAdmission(throwing: CancellationError())
    readerTaskID = nil; readerTask?.cancel(); readerTask = nil
    readerPreparedLease?.release(); readerPreparedLease = nil
  }

  isolated deinit {
    cancelPresentationWaiters()
    emptyShellDeadline?.cancel()
    payload?.source.releasePage(hostID: hostID, in: webView)
    clearSnapshotWait(); wakeSnapshotWaiters(unavailable: true)
    snapshotTask?.cancel()
    frameTask?.cancel()
    finishFrameEvaluation(throwing: CancellationError())
    DocumentRenderRegistry.shared.unmountRenderer(hostID: hostID)
    finishReader(throwing: CancellationError())
    finishRasterSnapshotAdmission(throwing: CancellationError())
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
  private var admittedLinkOrigin: DocumentLinkOrigin?
  private var lastLinkSequence: UInt64 = 0

  var capturesSnapshot = false
  var renderIsReady = false
  var onRenderReady: PageTurnReadiness
  var onPageLayout: (DocumentPageLayout) -> Void
  var onLinkActivation: (DocumentLinkActivation) -> Void = { _ in }
  var onSourceChange: (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status
  var onStateChange: (String, JSONValue) -> ContentFieldVersion?
  var pendingSnapshotPayload: DocumentRuntimePayload?
  private var preparedSnapshotLease: RasterLease?

  init(
    resources: SceneRenderResources = .shared,
    onRenderReady: PageTurnReadiness,
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onSourceChange: @escaping (DocumentSourceEdit) async throws -> DocumentSourceCommitResult.Status,
    onStateChange: @escaping (String, JSONValue) -> ContentFieldVersion?
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
    onStateChange: @escaping (String, JSONValue) -> ContentFieldVersion?,
    snapshotPixelWidth: Int? = nil,
    drafts: [DocumentEditingSession] = [],
    onDraftChange: @escaping (DocumentEditingSession) -> Void = { _ in },
    onDraftDiscard: @escaping (UUID) -> Void = { _ in },
    onPreparationFailure: @escaping (Error) -> Void = { _ in },
    onLinkActivation: @escaping (DocumentLinkActivation) -> Void = { _ in },
    preparationRequestID: UUID? = nil
  ) {
    guard !isInvalidated else { return }
    let configuredAt = preparationRequestID == nil ? 0 : ProcessInfo.processInfo.systemUptime
    defer { resolvePresentationWaiters() }
    self.preparationRequestID = preparationRequestID
    self.onRenderReady = onRenderReady
    self.onPageLayout = onPageLayout
    self.onLinkActivation = onLinkActivation
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
      let programMode = externallyHostedPrograms ? "external" : (snapshotPixelWidth == nil ? "live" : "snapshot")
    #endif
    if payload?.pageIndex != selectedPageIndex || payload?.programMode != programMode
      || payload?.source !== nextSource || payload?.state !== nextState {
      clearSnapshotWait()
      generation &+= 1
      cancelSnapshotPreparation()
      snapshotOnlyComplete = false
      acquisitionError = nil
      preparedSnapshotLease?.release(); preparedSnapshotLease = nil
      if !preservesFallback { host?.removeFallback() }
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
        if let previous = previousBlocks[block.id], let token = blockTokens[block.id],
          payload?.sourceVersions[block.id] == nextSource.message.sourceVersions[block.id], Self.sameProgram(previous, block) {
          nextTokens[block.id] = token
        } else { nextTokens[block.id] = UUID().uuidString }
      }
      blockTokens = nextTokens
      if payload?.source !== nextSource {
        payload?.source.releasePage(hostID: hostID, in: webView)
        recoveryAttempts = 0
      }
      payload = DocumentRuntimePayload(source: nextSource, state: nextState,
        editable: ownsEditing, renderToken: DocumentSnapshotCache.token(document: document, state: state, pageIndex: selectedPageIndex),
        pageIndex: selectedPageIndex, runtimeID: runtimeID, blockTokens: blockTokens,
        programMode: programMode, drafts: Array(draftsByID.values))
      beginPreparationObservation(configuredAt: configuredAt)
      sendFrameIfReady()
    } else if pageChanged {
      setRenderReady(false)
    }
    nextSource.retainPage(selectedPageIndex, hostID: hostID)
    beginPreparationObservation(configuredAt: configuredAt)
    fallbackSource = .document(id: document.id,
      token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: selectedPageIndex))
    pendingSnapshotPayload = self.capturesSnapshot && !snapshotOnlyComplete ? payload : nil
    applyPageIndexIfReady()
    onRenderReady(renderIsReady && (snapshotPixelWidth == nil || snapshotOnlyComplete))
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !isInvalidated, self.webView === webView else { return }
    isReady = true
    recordPreparation(.shellNavigationFinishedAt)
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
      recordPreparation(.shellReadyMessageAt)
      sendFrameIfReady()
      return
    }
    // The common shell owns this promise. There is no native JS invocation
    // retaining an admission while a discarded empty runtime is torn down.
    if kind == "commonRuntimeReady", preparesCommonRuntime {
      commonRuntimeReady = true
      emptyShellDeadline?.cancel(); emptyShellDeadline = nil
      onCommonRuntimeReady()
      return
    }
    if kind == "commonRuntimeFailed", preparesCommonRuntime {
      failPreparation(SceneRenderError.snapshotPending("common_runtime_startup"))
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
      guard renderIsReady, hasCanonicalPixels, let href = body["href"] as? String,
        let sequenceText = body["activationSequence"] as? String,
        let sequence = UInt64(sequenceText), sequence > lastLinkSequence,
        let receipt = try? presentation(in: body as NSDictionary, for: payload, generation: generation),
        receipt.kind == .canonical, receipt == pixelPresentation,
        let layout = payload.source.layout, let host, let web = webView,
        host.hasCanonicalSurface(web) else { return }
      let origin = DocumentLinkOrigin(source: payload.source, state: payload.state,
        runtimeID: payload.runtimeID, generation: generation, renderToken: payload.renderToken,
        pageIndex: payload.pageIndex, presentationEpoch: receipt.epoch)
      // A completed user activation belongs to the canonical surface that
      // admitted it. Ending native delivery may already have disabled NEW hits.
      // Programmatic activation never inherits that completed user admission.
      let userActivated = body["userActivated"] as? Bool == true
      if userActivated {
        guard let admittedLinkOrigin, origin.hasSamePresentation(as: admittedLinkOrigin) else { return }
      } else {
        guard acceptsInput, host.hasInteractiveSurface(web) else { return }
      }
      let destination = layout.destination(for: href)
      if case .external = destination, !userActivated { return }
      lastLinkSequence = sequence
      onLinkActivation(.init(origin: origin, destination: destination))
      return
    }
    if kind == "renderStarted" {
      guard body["runtimeID"] as? String == runtimeID.uuidString,
        body["generation"] as? String == String(generation),
        body["sourceKey"] as? String == payload.source.message.key,
        body["stateKey"] as? String == payload.state.message.key,
        body["renderToken"] as? String == payload.renderToken else { return }
      recordPreparation(.renderStartedAt)
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
      recordPreparation(.renderedAt)
      renderedToken = renderToken
      if let pageCount = (body["pageCount"] as? NSNumber)?.intValue {
        self.pageCount = max(1, pageCount)
        onPageLayout(
          DocumentPageLayout(pageCount: pageCount,
            sourceRevision: "\(payload.source.stamp.actor):\(payload.source.stamp.counter)")
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
    case "programReady":
      guard body["blockToken"] as? String == blockTokens[blockID] else { return }
      onProgramReady()
    case "programFocus":
      guard body["blockToken"] as? String == blockTokens[blockID], let focused = body["focused"] as? Bool else { return }
      onProgramFocus(focused)
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
      // Runtime state ownership exists before its first frame. Native hit
      // admission is a separate decision and cannot discard an initial commit.
      guard requestedInput || ownsProgramState, body["blockToken"] as? String == blockTokens[blockID],
        payload.blocks.contains(where: { $0.id == blockID && $0.kind == .interactive }),
        let value: JSONValue = Self.decode(body["value"]) else { return }
      _ = onStateChange(blockID, value)
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
    resolvePresentationWaiters()
    onPresentationChange()
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
    // A newer native demand must revoke an old pending image's publication
    // before the single sender can drain that decode and submit the next page.
    // The scalar fence never starts a source/render or releases its owned tail.
    webView?.evaluateJavaScript("window.notebookRenderer.requireFrame({runtimeID:'\(runtimeID.uuidString)',generation:'\(generation)'})", completionHandler: nil)
    guard frameTask == nil else { return }
    let taskID = UUID(); frameTaskID = taskID
    frameTask = Task { @MainActor [weak self] in
      defer {
        if let self, frameTaskID == taskID { frameTask = nil; frameTaskID = nil }
      }
      while let self, !Task.isCancelled, !isInvalidated, isReady, frameTaskID == taskID,
        let web = webView, let next = payload, sentGeneration != generation {
        let expected = generation
        let trace = pagePreparationTrace
        recordPreparation(.frameTaskAt, trace: trace)
        do {
          guard let lease = surfaceLease else { throw CancellationError() }
          recordPreparation(.preparedPageStartAt, trace: trace)
          let admissionChanged: (Bool) -> Void = { [weak self] waiting in
            self?.preparationAdmissionChanged(waiting, generation: expected)
          }
          let prepared = try await next.source.preparedPage(next.pageIndex, hostID: hostID, in: web, lease: lease,
            resources: resources, onAdmissionWait: admissionChanged)
          recordPreparation(.preparedPageReadyAt, trace: trace)
          let source = sentSourceKey == next.source.message.key && sentSourcePage == prepared.fragment.pageIndex
            ? nil : try await prepared.encodedMessage(resources: resources, onAdmissionWait: admissionChanged)
          recordPreparation(.pageSourceEncodedAt, trace: trace)
          defer { withExtendedLifetime(source) {} }
          let state = sentStateKey == next.state.message.key ? nil : try await next.state.encodedJSON()
          recordPreparation(.stateEncodedAt, trace: trace)
          guard !Task.isCancelled, !isInvalidated, frameTaskID == taskID, webView === web else { return }
          guard generation == expected else { continue }
          let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
          guard let current = payload else { return }
          let frame = String(decoding: try encoder.encode(current.frame(generation: expected)), as: UTF8.self)
          recordPreparation(.frameEncodedAt, trace: trace)
          var script = ""
          if let source { script += "await window.notebookRenderer.installPageSource(\(source.json));" }
          if let state { script += "window.notebookRenderer.applyState(\(state));" }
          // Keep the submitted page bytes and physical lease charged through the
          // actual serial render, including its non-cancellable image decode tail.
          script += "await window.notebookRenderer.presentPage(\(frame));"
          recordPreparation(.frameEvaluationStartAt, trace: trace)
          try await evaluateFrame(script, message: source, lease: lease, in: web)
          recordPreparation(.frameEvaluationReturnedAt, trace: trace)
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
    let trace = pagePreparationTrace
    pageIndexRequestID = requestID
    recordPreparation(.pageReceiptRequestedAt, trace: trace)
    #if os(iOS)
      let frameReadiness = snapshotPixelWidth == nil
        ? "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));" : ""
    #else
      let frameReadiness = ""
    #endif
    let script = trace == nil ? """
      window.notebookRenderer.setPageIndex(index);
      \(frameReadiness)
      return window.notebookRenderer.pageReceipt();
      """ : "return await window.notebookRenderer.observedPageReceipt(index, waitsForFrames, attemptID);"
    webView.callAsyncJavaScript(script,
      arguments: ["index": value, "waitsForFrames": !frameReadiness.isEmpty,
        "attemptID": trace?.identity.attemptID.uuidString ?? ""],
      in: nil,
      in: .page,
      completionHandler: { [weak self] result in
        guard let self, !isInvalidated, generation == expectedGeneration,
          pageIndexRequestID == requestID else { return }
        recordPreparation(.pageReceiptReturnedAt, trace: trace)
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
        if let trace, pagePreparationTrace === trace, preparationObservationIsCurrent(trace),
          let observation = receipt["preparationObservation"] as? [String: Any],
          let rawAttempt = observation["attemptID"] as? String, let attempt = UUID(uuidString: rawAttempt) {
          if let phases = observation["phasesMS"] as? [String: Double] {
            trace.recordBrowserPhases(phases, attemptID: attempt)
          }
          if let states = observation["states"] as? [String: [String: Double]] {
            trace.recordBrowserStates(states, attemptID: attempt)
          }
        }
        if receipt["layoutCanonical"] as? Bool == true {
          do {
            try DocumentRenderRegistry.shared.publish(documentID: payload.documentID, token: payload.renderToken, receipt: receipt,
              geometry: .document(payload.paper.kind))
            recordPreparation(.layoutReceiptAcceptedAt, trace: trace)
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
    defer {
      if (hasCanonicalPixels && !capturesSnapshot) || (renderIsReady && isPresentingEditor) {
        preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
      }
      resolvePresentationWaiters()
    }
    guard renderIsReady != ready else {
      refreshInputAdmission()
      if hasCanonicalPixels { recordPreparation(.canonicalReadyAt); wakeSnapshotWaiters() }
      return
    }
    renderIsReady = ready
    if hasCanonicalPixels { recordPreparation(.canonicalReadyAt); wakeSnapshotWaiters() }
    if ready, snapshotPixelWidth == nil, !preservesFallback { host?.removeFallback() }
    refreshInputAdmission()
    onRenderReady(ready && (snapshotPixelWidth == nil || snapshotOnlyComplete))
  }

  /// A thumbnail borrows pixels from the already mounted page. It neither
  /// starts that page's programs again nor revokes the page's input lease.
  func retainPreparedSnapshot(pixelWidth: Int, nativeScale: Double? = nil, force: Bool = false,
    waitsForRasterAdmission: Bool = false, reservation granted: RasterReservation? = nil) async throws -> RasterLease {
    guard let payload, !isInvalidated else { throw CancellationError() }
    let requestGeneration = generation
    let source = SceneRasterSource.document(id: payload.documentID, token: payload.rasterToken)
    let minimumScale = nativeScale ?? Self.snapshotMinimumScale(pixelWidth: pixelWidth, size: physicalSize)
    if !force, let cached = resources.retainRaster(for: source, minimumScale: minimumScale) { return cached }
    if force, let preceding = readerTask {
      try? await preceding.value
      try Task.checkCancellation()
      guard !isInvalidated, generation == requestGeneration,
        self.payload?.renderToken == payload.renderToken else { throw CancellationError() }
    }
    if readerTask == nil {
      let expectedGeneration = generation
      let taskID = UUID(); readerTaskID = taskID
      readerTask = Task { @MainActor [weak self] in
        guard let self else { throw CancellationError() }
        defer { if readerTaskID == taskID { readerTaskID = nil; readerTask = nil } }
        if !force, let cached = resources.retainRaster(for: source, minimumScale: minimumScale) {
          readerPreparedLease?.release(); readerPreparedLease = cached; return
        }
        try await awaitPresentation(token: payload.renderToken)
        guard generation == expectedGeneration else { throw CancellationError() }
        guard let size = webView?.bounds.size else { throw CancellationError() }
        guard size.width > 0, size.height > 0 else { throw SceneRenderError.resourceLimit }
        let height = Int(ceil(Double(pixelWidth) * size.height / size.width))
        let reservation: RasterReservation
        if let granted {
          guard resources.ownsRasterReservation(granted, pixelWidth: pixelWidth, pixelHeight: height) else { throw SceneRenderError.resourceLimit }
          reservation = granted
        } else {
          reservation = try await reserveSnapshot(source: source, pixelWidth: pixelWidth,
            pixelHeight: height, waitsForAdmission: waitsForRasterAdmission)
        }
        guard !Task.isCancelled, !isInvalidated, generation == expectedGeneration, let web = webView else {
          reservation.release(); throw CancellationError()
        }
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
      // Retiring a failed producer cancels its internal reader as cleanup.
      // That cleanup is not cancellation of the caller's accepted request.
      if !Task.isCancelled, !isInvalidated, generation == requestGeneration,
        let acquisitionError { throw acquisitionError }
      if !force, !isInvalidated, let retained = resources.retainRaster(for: source, minimumScale: minimumScale) { return retained }
      throw error
    }
    try Task.checkCancellation()
    guard !isInvalidated, self.payload?.renderToken == payload.renderToken,
      readerPreparedLease?.image(for: source, minimumScale: minimumScale) != nil,
      let retained = readerPreparedLease?.retainedCopy() else { throw SceneRenderError.resourceLimit }
    return retained
  }

  /// The caller owns a retained copy. Intermediate paper pixels need no second
  /// pin after a composition or physical fallback has taken ownership.
  func releasePreparedSnapshot() { readerPreparedLease?.release(); readerPreparedLease = nil }

  private func reserveSnapshot(source: SceneRasterSource, pixelWidth: Int, pixelHeight: Int,
    waitsForAdmission: Bool) async throws -> RasterReservation {
    if let reservation = resources.reserveRaster(pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel) { return reservation }
    let admission = resources.rasterAdmission
    guard waitsForAdmission,
      let bytes = SceneRenderResources.estimatedRasterBytes(pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel),
      bytes <= admission.byteLimit, bytes <= admission.passiveByteLimit, admission.countLimit > 0 else {
      throw SceneRenderError.resourceLimit
    }
    precondition(rasterSnapshotAdmissionContinuation == nil)
    return try await withCheckedThrowingContinuation { continuation in
      pendingRasterSnapshot = .init(source: source, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
        bytes: bytes, admission: admission)
      rasterSnapshotAdmissionGeneration = generation
      rasterSnapshotAdmissionContinuation = continuation
      rasterSnapshotAdmissionObserver = NotificationCenter.default.addObserver(
        forName: SceneRenderResources.didGainRasterAdmission, object: resources, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.retryRasterSnapshotAdmission() }
        }
      // Registration and the failed reservation share this actor segment.
      // No release can be lost between observing the refusal and subscribing.
    }
  }

  private func retryRasterSnapshotAdmission() {
    guard let demand = pendingRasterSnapshot else { return }
    guard !isInvalidated, generation == rasterSnapshotAdmissionGeneration,
      payload.map({ SceneRasterSource.document(id: $0.documentID, token: $0.rasterToken) }) == demand.source else {
      finishRasterSnapshotAdmission(throwing: CancellationError()); return
    }
    let current = resources.rasterAdmission, previous = demand.admission
    let improved = current.byteLimit - current.heldBytes > previous.byteLimit - previous.heldBytes
      || current.passiveByteLimit - current.pinnedBytes - current.passiveReservedBytes
        > previous.passiveByteLimit - previous.pinnedBytes - previous.passiveReservedBytes
      || current.countLimit - current.pinnedCount - current.reservedCount
        > previous.countLimit - previous.pinnedCount - previous.reservedCount
    guard improved, current.fits(additionalBytes: demand.bytes, additionalCount: 1),
      let reservation = resources.reserveRaster(pixelWidth: demand.pixelWidth, pixelHeight: demand.pixelHeight, bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel) else { return }
    let continuation = rasterSnapshotAdmissionContinuation
    clearRasterSnapshotAdmission()
    continuation?.resume(returning: reservation)
  }

  private func clearRasterSnapshotAdmission() {
    if let rasterSnapshotAdmissionObserver { NotificationCenter.default.removeObserver(rasterSnapshotAdmissionObserver) }
    rasterSnapshotAdmissionObserver = nil; pendingRasterSnapshot = nil
    rasterSnapshotAdmissionGeneration = nil; rasterSnapshotAdmissionContinuation = nil
  }

  private func finishRasterSnapshotAdmission(throwing error: Error) {
    let continuation = rasterSnapshotAdmissionContinuation
    clearRasterSnapshotAdmission()
    continuation?.resume(throwing: error)
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
              guard let layout = payload.source.layout,
                let retained = DocumentSnapshotCache.shared.storeAndRetain(image: normalized, documentID: payload.documentID,
                  token: payload.rasterToken, layout: layout, reservation: reservation, resources: resources)
              else { throw SceneRenderError.resourceLimit }
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
      // Physical page navigation belongs to UIKit. Disabling the recognizer
      // once is not a scroll policy: WebKit re-enables it after loading.
      webView.scrollView.isScrollEnabled = false
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
  private final class DocumentContactObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var changed: (Bool) -> Void = { _ in }
    private var contacts: Set<UITouch> = []
    private var contactGeneration: UInt64 = 0
    var hasContacts: Bool { !contacts.isEmpty }
    init() {
      super.init(target: nil, action: nil)
      cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false; delegate = self
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      contactGeneration &+= 1
      contacts.formUnion(touches); changed(true); state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
      contacts.subtract(touches)
      if contacts.isEmpty { state = .ended; finishAfterDelivery() }
    }
    private func finishAfterDelivery() {
      contactGeneration &+= 1
      let generation = contactGeneration
      DispatchQueue.main.async { [weak self] in
        guard let self, contacts.isEmpty, contactGeneration == generation else { return }
        changed(false)
      }
    }
    override func reset() {
      super.reset()
      if !contacts.isEmpty { contacts.removeAll(); finishAfterDelivery() }
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
  }

  @MainActor
  final class DocumentWebHost: UIView {
    let programOverlay = DocumentProgramOverlayHost()
    private var paperSize = CGSize.zero
    func installProgramOverlay() {
      if programOverlay.superview !== self {
        if let fallback { insertSubview(programOverlay, belowSubview: fallback) } else { addSubview(programOverlay) }
      }
      if let fallback { insertSubview(programOverlay, belowSubview: fallback) } else { bringSubviewToFront(programOverlay) }
      programOverlay.frame = bounds
    }
    func installPreparationHost(_ host: DocumentWebHost, size: CGSize) {
      if host.superview !== self { addSubview(host) }
      host.frame = CGRect(x: -20_000, y: 0, width: size.width, height: size.height)
    }
    private var viewport: PhysicalWebViewport?
    private var fallback: UIImageView?
    private var fallbackLease: RasterLease?
    private var fallbackSource: SceneRasterSource?
    private var failureView: UIStackView?
    private var loadingView: UIStackView?
    private var inputEnabled = false
    private let contactObserver = DocumentContactObserver()
    var onContactChange: (Bool) -> Void = { _ in }
    var onSizeChange: () -> Void = { }
    private var lastLaidOutSize = CGSize.zero
    func showFailure(_ message: String, retry: @escaping () -> Void) {
      removeLoading()
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
      isUserInteractionEnabled = true
    }
    func removeFailure() {
      failureView?.removeFromSuperview(); failureView = nil; isUserInteractionEnabled = inputEnabled
    }
    func showLoading() {
      guard loadingView == nil, failureView == nil, fallback == nil else { return }
      let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating()
      let label = UILabel(); label.text = "Подготовка страницы…"; label.font = .preferredFont(forTextStyle: .caption1)
      label.numberOfLines = 0; label.textAlignment = .center
      let stack = UIStackView(arrangedSubviews: [spinner, label]); stack.axis = .vertical; stack.spacing = 8; stack.alignment = .center
      stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack); loadingView = stack
      NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24)])
    }
    func removeLoading() { loadingView?.removeFromSuperview(); loadingView = nil }
    var hasSnapshot: Bool { fallbackLease != nil }
    var snapshotEntryID: UUID? { fallbackLease?.entryID }
    var hasVisibleSnapshot: Bool {
      guard hasSnapshot, let window else { return false }
      var visible = convert(bounds, to: window).intersection(window.bounds)
      var ancestor: UIView? = self
      while let view = ancestor {
        if view.isHidden || view.alpha <= 0.001 { return false }
        if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
        if visible.isNull || visible.isEmpty { return false }
        ancestor = view.superview
      }
      return !visible.isNull && !visible.isEmpty
    }
    /// Density follows the same native projection as the paper, including its
    /// ancestor camera transform. Local pre-camera bounds are not screen pixels.
    func projectedPixelScale(for physical: CGSize) -> Double {
      guard let window, physical.width > 0, physical.height > 0,
        !bounds.isEmpty else { return 1 }
      let fit = min(bounds.width / physical.width, bounds.height / physical.height)
      let origin = convert(CGPoint.zero, to: window)
      let horizontal = convert(CGPoint(x: physical.width * fit, y: 0), to: window)
      let vertical = convert(CGPoint(x: 0, y: physical.height * fit), to: window)
      let scale = max(hypot(horizontal.x - origin.x, horizontal.y - origin.y) / physical.width,
        hypot(vertical.x - origin.x, vertical.y - origin.y) / physical.height) * window.screen.scale
      return scale.isFinite && scale > 0 ? scale : 1
    }
    func installSnapshot(_ raster: RasterLease) {
      guard fallbackLease?.entryID != raster.entryID, let retained = raster.retainedCopy() else { return }
      removeLoading()
      removeFallback(); fallbackLease = retained; fallbackSource = raster.source
      let image = UIImageView(image: retained.image)
      image.frame = bounds; image.contentMode = .scaleToFill
      image.autoresizingMask = [.flexibleWidth, .flexibleHeight]; image.isAccessibilityElement = false
      fallback = image; addSubview(image)
    }
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
      fallback?.image = nil; fallback?.removeFromSuperview(); fallback = nil
      fallbackLease?.release(); fallbackLease = nil; fallbackSource = nil
    }
    init() {
      super.init(frame: .zero); backgroundColor = .white
      contactObserver.changed = { [weak self] active in
        guard let self else { return }
        if !active { projectInputPolicy() }
        onContactChange(active)
      }
      addGestureRecognizer(contactObserver)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }
    func install(_ web: WKWebView, size: CGSize) {
      viewport?.retire()
      let viewport = PhysicalWebViewport(webView: web, contentSize: size)
      self.viewport = viewport
      if programOverlay.superview === self { insertSubview(viewport, belowSubview: programOverlay) }
      else if let fallback { insertSubview(viewport, belowSubview: fallback) } else { addSubview(viewport) }
      setNeedsLayout()
    }
    func configure(size: CGSize, interactive: Bool) {
      paperSize = size
      viewport?.setContentSize(size)
      inputEnabled = interactive
      projectInputPolicy()
    }
    var hasActiveContact: Bool { contactObserver.hasContacts }
    private func projectInputPolicy() {
      // UIKit already owns the target of an accepted contact. Revoking that
      // subtree before its final native delivery would cancel the gesture.
      let retainsDelivery = inputEnabled || hasActiveContact
      viewport?.isUserInteractionEnabled = retainsDelivery
      viewport?.accessibilityElementsHidden = !inputEnabled
      isUserInteractionEnabled = retainsDelivery || failureView != nil
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      guard inputEnabled || failureView != nil else { return nil }
      let hit = super.hitTest(point, with: event)
      if !inputEnabled, let hit, let failureView,
        hit !== failureView && !hit.isDescendant(of: failureView) { return nil }
      return hit
    }
    func removeSurface() { viewport?.retire(); viewport = nil }
    func ownsSurface(_ web: WKWebView) -> Bool {
      guard let viewport else { return false }
      return viewport.webView === web && web.superview === viewport
    }
    func hasCanonicalSurface(_ web: WKWebView) -> Bool {
      guard ownsSurface(web), window?.isKeyWindow == true, !hasSnapshot,
        failureView == nil, loadingView == nil, !bounds.isEmpty,
        UIApplication.shared.applicationState == .active else { return false }
      var node: UIView? = web
      while let view = node {
        guard !view.isHidden, view.alpha > 0.01 else { return false }
        if view === window { return true }
        node = view.superview
      }
      return false
    }
    func hasInteractiveSurface(_ web: WKWebView) -> Bool {
      guard inputEnabled, hasCanonicalSurface(web) else { return false }
      var node: UIView? = web
      while let view = node {
        guard view.isUserInteractionEnabled, !view.isHidden, view.alpha > 0.01,
          !view.accessibilityElementsHidden else { return false }
        if view === window { return true }
        node = view.superview
      }
      return false
    }
    override func layoutSubviews() {
      super.layoutSubviews(); viewport?.frame = bounds; programOverlay.frame = bounds
      if lastLaidOutSize != bounds.size {
        lastLaidOutSize = bounds.size
        Task { @MainActor [weak self] in self?.onSizeChange() }
      }
    }
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
    let onStateChange: (String, JSONValue) -> ContentFieldVersion?
    let resources: SceneRenderResources
    var drafts: [DocumentEditingSession] = []
    var onDraftChange: (DocumentEditingSession) -> Void = { _ in }
    var onDraftDiscard: (UUID) -> Void = { _ in }
    var snapshotPixelWidth: Int? = nil
    var onPreparationFailure: (Error) -> Void = { _ in }
    var onLinkActivation: (DocumentLinkActivation) -> Void = { _ in }
    var isCurrent = true
    var isVisible = true
    var isPageTurnActive = false
    var onStateCheckpoint: (String, JSONValue, ContentFieldVersion) async throws -> Bool = { _, _, _ in false }
    var measurements: DocumentPresentationRecorder? = nil
    func makeCoordinator() -> DocumentPhysicalPageCoordinator { DocumentPhysicalPageCoordinator() }
    func makeUIView(context: Context) -> DocumentWebHost { DocumentWebHost() }
    func updateUIView(_ view: DocumentWebHost, context: Context) {
      context.coordinator.update(.init(document: document, state: state, pageIndex: selectedPageIndex,
        isCurrent: snapshotPixelWidth == nil && isCurrent, isVisible: isVisible, isInteractive: isInteractive,
        pageTurnActive: isPageTurnActive, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
        onSourceChange: onSourceChange, onStateChange: onStateChange, drafts: drafts,
        onDraftChange: onDraftChange, onDraftDiscard: onDraftDiscard, onLinkActivation: onLinkActivation,
        snapshotPixelWidth: snapshotPixelWidth, onPreparationFailure: onPreparationFailure,
        onStateCheckpoint: onStateCheckpoint, measurements: measurements), in: view, resources: resources)
    }
    static func dismantleUIView(_ view: DocumentWebHost, coordinator: DocumentPhysicalPageCoordinator) { coordinator.invalidate() }
  }
#elseif os(macOS)
  @MainActor
  final class DocumentWebHost: NSView {
    private var web: WKWebView?
    private var inputEnabled = false
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
      fallback?.image = nil; fallback?.removeFromSuperview(); fallback = nil
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
      inputEnabled = interactive
      if web?.frame.size != size { web?.setFrameSize(size) }
      web?.setAccessibilityHidden(!interactive)
    }
    func hasCanonicalSurface(_ web: WKWebView) -> Bool {
      self.web === web && web.superview === self && window != nil && !isHidden
        && !web.isHidden && !hasSnapshot && failureView == nil && !bounds.isEmpty
    }
    func hasInteractiveSurface(_ web: WKWebView) -> Bool {
      inputEnabled && hasCanonicalSurface(web)
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
    let onStateChange: (String, JSONValue) -> ContentFieldVersion?
    let resources: SceneRenderResources
    var drafts: [DocumentEditingSession] = []
    var onDraftChange: (DocumentEditingSession) -> Void = { _ in }
    var onDraftDiscard: (UUID) -> Void = { _ in }
    var snapshotPixelWidth: Int? = nil
    var onPreparationFailure: (Error) -> Void = { _ in }
    var onLinkActivation: (DocumentLinkActivation) -> Void = { _ in }
    var isCurrent = true
    var isVisible = true
    var isPageTurnActive = false
    var onStateCheckpoint: (String, JSONValue, ContentFieldVersion) async throws -> Bool = { _, _, _ in false }
    var measurements: DocumentPresentationRecorder? = nil
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
        onPreparationFailure: onPreparationFailure, onLinkActivation: onLinkActivation)
      let geometry = WorkspaceItemGeometry.document(document.paperSize)
      context.coordinator.mount(in: view, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: isInteractive, priority: snapshotPixelWidth != nil ? .visible : (isInteractive ? .currentPage : .neighbor))
    }
    static func dismantleNSView(_ view: DocumentWebHost, coordinator: DocumentWebCoordinator) { coordinator.invalidate() }
  }
#endif
