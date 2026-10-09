import NotebookCore
import NotebookTypesetter
import Observation
import SwiftUI
import WebKit

#if os(macOS)
private struct MacDocumentDisplayScaleKey: EnvironmentKey {
  static let defaultValue = 1.0
}
extension EnvironmentValues {
  var macDocumentDisplayScale: Double {
    get { self[MacDocumentDisplayScaleKey.self] }
    set { self[MacDocumentDisplayScaleKey.self] = newValue }
  }
}
#endif

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
      resources: SceneRenderResources = .shared, programStore: NotebookStore? = nil, isolationID: UUID? = nil, pixelWidth: Int? = nil,
      purpose: @escaping @MainActor () -> ScenePreparationPurpose = { .required }) async throws -> RasterLease {
      try Task.checkCancellation()
      guard resources.allowsOptionalPreparation || purpose() == .required else { throw CancellationError() }
      let source = SceneRasterSource.document(id: document.id,
        token: Self.token(document: document, state: state, pageIndex: pageIndex))
      let geometry = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: pageIndex)
      let requiredScale = pixelWidth.map { Double($0) / geometry.width } ?? Double(NSScreen.main?.backingScaleFactor ?? 2)
      if isolationID == nil, let lease = resources.retainRaster(for: source, minimumScale: requiredScale) { return lease }
      if isolationID == nil, let producer = DocumentRenderRegistry.shared.rasterProducer(documentID: document.id,
        token: Self.token(document: document, state: state, pageIndex: pageIndex), resources: resources, excluding: UUID()) {
        return try await producer.retainPreparedSnapshot(pixelWidth: Int(ceil(DocumentRenderRegistry.shared.geometry(document: document, pageIndex: pageIndex).width * requiredScale)), force: true,
          purpose: purpose)
      }
      return try await withPreparedPage(document: document, state: state, pageIndex: pageIndex, resources: resources,
        programStore: programStore, isolationID: isolationID, purpose: purpose) { coordinator in
          try await coordinator.retainPreparedSnapshot(pixelWidth: pixelWidth ?? Int(ceil(geometry.width * requiredScale)), force: true, waitsForRasterAdmission: true,
            purpose: purpose)
        }
    }

    func withPreparedPage<T>(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int,
      resources: SceneRenderResources, programStore: NotebookStore?, isolationID: UUID?,
      renderSession: DocumentRenderSession? = nil,
      purpose: @escaping @MainActor () -> ScenePreparationPurpose = { .required },
      operation: (DocumentWebCoordinator) async throws -> T) async throws -> T {
      try Task.checkCancellation()
      guard resources.allowsOptionalPreparation || purpose() == .required else { throw CancellationError() }
      let geometry = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: pageIndex)
      let ready = PageTurnReadiness { _ in }
      let coordinator = DocumentWebCoordinator(resources: resources, renderSession: renderSession, printPriority: .export,
        onRenderReady: ready, onPageLayout: { _ in }, onStateChange: { _, _ in nil })
      let claim = DocumentSnapshotClaim(purpose: purpose)
      coordinator.headlessClaim = claim
      coordinator.programStore = programStore; coordinator.exportSnapshotID = isolationID
      let host = DocumentWebHost()
      let window = NSWindow(contentRect: .init(x: -20_000, y: -20_000, width: geometry.width, height: geometry.height),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
      defer { coordinator.invalidate(); window.orderOut(nil); window.close() }
      coordinator.update(document: document, state: state, selectedPageIndex: pageIndex, capturesSnapshot: false,
        onRenderReady: ready, onPageLayout: { _ in },  onStateChange: { _, _ in nil })
      coordinator.mount(in: host, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: false, priority: .background, purpose: purpose)
      return try await withTaskCancellationHandler {
        // The accepted request owns this queued producer. Its bounded render
        // and capture deadlines start only after physical WebKit admission.
        try await coordinator.awaitSurfaceAdmission()
        // This one reader returns its exact canonical capture; cache presence
        // and a second automatic capture are not completion notifications.
        try Task.checkCancellation()
        let value = try await operation(coordinator)
        try Task.checkCancellation()
        return value
      } onCancel: {
        claim.cancel()
        Task { @MainActor in coordinator.cancelHeadlessPreparation() }
      }
    }
    #endif

    static func token(
      document: DocumentDocument,
      state: DocumentStateJournal,
      pageIndex: Int
    ) -> String {
      precondition(document.id == state.id)
      precondition(pageIndex >= 0)
      let ids = DocumentRenderRegistry.shared.programIDs(document: document, pageIndex: pageIndex)
        ?? Set(state.records.map(\.id))
      return compositeToken(sourceRevision: document.contentStamp.revision, records: state.records, pageIndex: pageIndex, programIDs: ids)
    }

    nonisolated static func paperToken(sourceRevision: String, pageIndex: Int) -> String {
      "\(sourceRevision)|page:\(pageIndex)"
    }

    nonisolated static func compositeToken(sourceRevision: String, records: [DocumentStateRecord], pageIndex: Int, programIDs: Set<String>) -> String {
      let dependencies = records.filter { programIDs.contains($0.id) }.map {
        "\($0.id.utf8.count):\($0.id)=\($0.stamp.revision)"
      }.joined(separator: "|")
      let paper = paperToken(sourceRevision: sourceRevision, pageIndex: pageIndex)
      return dependencies.isEmpty ? paper : paper + "|programs:" + dependencies
    }
  }

struct DocumentPageLayout: Equatable, Sendable {
  let pageCount: Int
  let sourceRevision: String?
  let record: DocumentLayoutRecord?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.pageCount == rhs.pageCount
      && lhs.sourceRevision == rhs.sourceRevision && lhs.record === rhs.record
  }

  @MainActor init(pageCount: Int, sourceRevision: String? = nil, record: DocumentLayoutRecord? = nil) {
    self.pageCount = max(1, pageCount)
    self.sourceRevision = sourceRevision
    self.record = record
  }

  func pageCount(for sourceRevision: String) -> Int? {
    self.sourceRevision == sourceRevision ? pageCount : nil
  }
}

struct DocumentWebView: View {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  @Environment(\.openURL) private var openURL
  @Environment(\.documentPaperVisible) private var paperVisible
  @State private var linkFailure: String?
  let document: DocumentDocument
  let state: DocumentStateJournal
  let isInteractive: Bool
  let selectedPageIndex: Int
  let capturesSnapshot: Bool
  let onRenderReady: PageTurnReadiness
  let onPageLayout: (DocumentPageLayout) -> Void
  let onLinkActivation: (DocumentLinkActivation) -> DocumentLinkDestination?
  let onStateChange: (DocumentProgramSource, JSONValue) async throws -> ContentFieldVersion?
  var resources: SceneRenderResources = .shared
  var isCurrent = true
  var isVisible = true
  var isPageTurnActive = false
  var onStateCheckpoint: (String, JSONValue, DocumentProgramSource, ContentFieldVersion?) async throws -> ContentFieldVersion? = { _, _, _, _ in nil }
  var measurements: DocumentPresentationRecorder? = nil

  var body: some View {
    PlatformDocumentWebView(
      document: document,
      state: state,
      isInteractive: isInteractive && paperVisible,
      selectedPageIndex: selectedPageIndex,
      capturesSnapshot: capturesSnapshot,
      onRenderReady: onRenderReady,
      onPageLayout: onPageLayout,
      onStateChange: onStateChange,
      resources: resources,
      onLinkActivation: { activation in
        guard let destination = onLinkActivation(activation) else { return }
        switch destination {
        case .page: break
        case .external(let url): openURL(url) { accepted in
          if !accepted { linkFailure = "Система не смогла открыть эту ссылку." }
        }
        case .unavailable(let message): linkFailure = message
        }
      }, isCurrent: isCurrent, isVisible: isVisible && paperVisible, isPageTurnActive: isPageTurnActive,
      onStateCheckpoint: onStateCheckpoint, onStateDrained: { await model?.drainAcceptedProgramWrites() }, measurements: measurements, programStore: model?.store
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
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  let document: DocumentDocument
  let state: DocumentStateJournal
  let pageIndex: Int
  let onRenderReady: PageTurnReadiness
  var resources: SceneRenderResources = .shared
  var onFailure: (Error) -> Void = { _ in }

  var body: some View {
    PlatformDocumentWebView(document: document, state: state, isInteractive: false,
      selectedPageIndex: pageIndex, capturesSnapshot: true, onRenderReady: onRenderReady,
      onPageLayout: { _ in }, onStateChange: { _, _ in nil },
      resources: resources, snapshotPixelWidth: 256, onPreparationFailure: onFailure, isCurrent: false, programStore: model?.store)
      .accessibilityHidden(true)
  }
}

@MainActor
struct DocumentRuntimePayload {
  let source: DocumentSourceSnapshot
  var state: DocumentStateSnapshot
  var documentID: UUID { source.message.documentID }
  var paper: DocumentPaperLayout { source.paper(on: pageIndex) }
  var programs: [DocumentProgramSource] { source.programs }
  var states: [String: JSONValue] { state.message.states }
  var sourceBases: [String: String] { Dictionary(uniqueKeysWithValues: programs.map { ($0.id, $0.sourceBasis) }) }
  var editable: Bool
  let renderToken: String
  let pageIndex: Int
  var runtimeID: UUID
  var blockTokens: [String: String]
  let programMode: String

  var rasterToken: String {
    let omitsPrograms = programMode == "external" && source.programIDs(on: pageIndex).map { !$0.isEmpty } != false
    return omitsPrograms ? "paper:" + renderToken : compositeToken
  }

  var compositeToken: String {
    let ids = source.programIDs(on: pageIndex) ?? source.programIDs
    return DocumentSnapshotCache.compositeToken(sourceRevision: source.stamp.revision, records: state.records,
      pageIndex: pageIndex, programIDs: ids)
  }

  func frame(generation: UInt64, programURLs: [String: String] = [:], programsVisible: Bool = true, programStateCredit: [String: Int] = [:]) -> DocumentRuntimeFrame {
    .init(documentID: documentID, generation: String(generation), sourceKey: source.message.key, stateKey: state.message.key,
      editable: editable, renderToken: renderToken, pageIndex: pageIndex, runtimeID: runtimeID,
      blockTokens: blockTokens, programMode: programMode, programURLs: programURLs, programsVisible: programsVisible, programStateCredit: programStateCredit)
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
  var programURLs: [String: String] = [:]
  var programsVisible = true
  var programStateCredit: [String: Int] = [:]
}

private struct DocumentPixelPresentation: Equatable, Sendable {
  enum Kind: String, Sendable { case canonical, preparing }
  let epoch: UInt64
  let kind: Kind
  init?(_ receipt: NSDictionary) {
    guard let value = receipt["presentationEpoch"] as? String, let epoch = UInt64(value),
      let value = receipt["presentationKind"] as? String, let kind = Kind(rawValue: value) else { return nil }
    self.epoch = epoch; self.kind = kind
  }
}

enum DocumentSnapshotWait: Error, Equatable {
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
  private var requestedPreparationPurpose: @MainActor () -> ScenePreparationPurpose = { .required }
  fileprivate var headlessClaim: DocumentSnapshotClaim?
  // Accepted headless snapshots keep export intent while their WebKit surface
  // waits in the background pool. Ordinary mounted pages follow their host.
  private let fixedPrintPriority: NotebookTypesetter.Priority?
  private func printPriority(for priority: WebPriority?) -> NotebookTypesetter.Priority {
    if let fixedPrintPriority { return fixedPrintPriority }
    return priority == .currentPage || priority == .input || priority == .liveProgram ? .current : .anticipated
  }
  private weak var host: DocumentWebHost?
  private(set) var isInvalidated = false
  private(set) var acquisitionError: Error?
  private enum PreparationFailure { case native, interaction }
  private var preparationFailure: PreparationFailure?
  private var retainsNativePreparation: Bool { !isInvalidated && preparationFailure == .interaction }
  private(set) var acceptsInput = false
  private var requestedInput = false
  private(set) var ownsEditing = false
  private var physicalSize = CGSize(width: 1, height: 1)
  private var generation: UInt64 = 0
  private var preparationRequestID: UUID?
  private(set) var pagePreparationTrace: DocumentPagePreparationTrace?
  private(set) var renderSession: DocumentRenderSession?
  private var frameTask: Task<Void, Never>?
  private var sourcePreparationSubscriber: Task<DocumentPreparedPage, Error>?
  private var sourcePreparationGeneration: UInt64?
  private var sourcePreparationID: UUID?
  private var focusedProgramID: String?
  private var frameTaskID: UUID?
  private var shellContinuation: CheckedContinuation<Void, Error>?
  private var frameEvaluationID: UUID?
  private var frameContinuation: CheckedContinuation<Void, Error>?
  private let printedView = DocumentPaperView()
  // The physical owner can prepare a thumbnail at its actual requested width
  // without turning this reusable paper executor into a snapshot-only owner.
  private var paperPreparationPixelWidth = 1024
  private var printedSourceMatches: Bool {
    guard let raster = printedView.raster, let payload else { return false }
    return raster.sourceKey == payload.source.message.key && raster.page.pageIndex == min(payload.pageIndex, max(0, pageCount-1))
  }
  private var paperGeneration: UInt64?
  var paperIsReady: Bool { !isInvalidated && paperGeneration == generation && printedSourceMatches }
  var interactionIsReady: Bool {
    renderIsReady && layoutAccepted && pixelPresentation?.kind == .canonical
      && canonicalPixelEpoch != nil && canonicalPixelEpoch == pixelPresentation?.epoch
  }
  var onPaperReady: () -> Void = {}
  private var sentSourcePage: Int?
  private var sentSourceKey: String?
  private var sentStateKey: String?
  private var sentGeneration: UInt64?
  private var layoutAccepted = false
  private var pixelPresentation: DocumentPixelPresentation?
  private var canonicalPixelEpoch: UInt64?
  var hasCanonicalPixels: Bool {
    paperIsReady && interactionIsReady
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
  let programAssets = NotebookProgramAssets()
  var programStore: NotebookStore?
  // Export uses the same admission budget, but neither reads nor overwrites a
  // live raster with an equal journal token and later uncommitted pixels.
  var exportSnapshotID: UUID?
  private func snapshotToken(_ payload: DocumentRuntimePayload) -> String {
    payload.rasterToken + (exportSnapshotID.map { "|export:" + $0.uuidString.lowercased() } ?? "")
  }
  private var programURLs: [String: (token: String, url: URL)] = [:]
  private var programInitialStates: [String: NotebookProgramStateEncoding] = [:]
  private var programStateTransfers: [String: (token: String, owner: NotebookProgramStateTransfer)] = [:]
  private var preparationDeadlineTask: Task<Void, Never>?
  private var preparationDeadlineGeneration: UInt64?
  private var programStartupDeadlineGeneration: UInt64?
  private var preparationAdmissionGeneration: UInt64?
  private var preparationDeadlineRemaining: Duration = .seconds(8)
  private var preparationDeadlineStarted: ContinuousClock.Instant?
  private var recoveryAttempts = 0
  private var snapshotTask: Task<Void, Never>?
  private var readerTask: Task<Void, any Error>?
  private var readerTaskID: UUID?
  private var readerAdmission: DocumentSnapshotAdmission?
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
    fixedPrintPriority == nil && !externallyHostedPrograms && !isInvalidated && acquisitionError == nil && payload != nil && webView != nil
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

  private enum PresentationRequirement: Equatable { case nativePaper, canonical }
  private struct PresentationWaiter {
    let generation: UInt64
    let token: String
    let requirement: PresentationRequirement
    let continuation: CheckedContinuation<Void, Error>
  }
  private var presentationWaiters: [UUID: PresentationWaiter] = [:]
  var pendingPresentationRequestCount: Int { presentationWaiters.count }
  var pendingSurfaceRequestID: UUID? { acquisitionTask == nil ? nil : acquisitionID }

  /// Wait for this exact request, not a later page that happens to be ready.
  /// Admission and execution keep their existing owners and deadlines; this
  /// subscription adds no polling loop or competing overall timeout.
  func awaitPresentation(token: String) async throws {
    try await awaitPresentation(token: token, requirement: .canonical)
  }

  /// Native PDF pixels and transparent DOM interaction share the same source
  /// generation, but a physical cut does not borrow that DOM's receipt.
  func awaitPaperReady(token: String) async throws {
    try await awaitPresentation(token: token, requirement: .nativePaper)
  }

  private func awaitPresentation(token: String, requirement: PresentationRequirement) async throws {
    try Task.checkCancellation()
    let id = UUID(), expected = generation
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        presentationWaiters[id] = .init(generation: expected, token: token, requirement: requirement,
          continuation: continuation)
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
      } else if let acquisitionError, waiter.requirement == .canonical || !retainsNativePreparation {
        result = .failure(acquisitionError)
      } else if (waiter.requirement == .nativePaper ? paperIsReady : hasCanonicalPixels) {
        result = .success(())

      } else { continue }
      presentationWaiters.removeValue(forKey: id)?.continuation.resume(with: result)
    }
  }

  private func cancelPresentationWaiters(keepingNativePreparation: Bool = false) {
    for (id, waiter) in presentationWaiters {
      if keepingNativePreparation, waiter.requirement == .nativePaper { continue }
      presentationWaiters.removeValue(forKey: id)?.continuation.resume(throwing: acquisitionError ?? CancellationError())
    }
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
    host.install(web, size: physicalSize); host.installPaper(printedView)
    emptyShellDeadline = Task { @MainActor [weak self, weak web] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard !Task.isCancelled, let self, let web, self.webView === web,
        !isInvalidated, payload == nil, !commonRuntimeReady else { return }
      failPreparation(SceneRenderError.snapshotPending("common_runtime_startup"), scope: .interaction)
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
  func updateInteractionCallbacks(



    onLinkActivation: @escaping (DocumentLinkActivation) -> Void) {
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

  /// The page owner calls this after the real handoff, even when UIKit has
  /// already detached the old host. An idle shell cannot remain an input owner.
  func releaseInputOwnership() {
    holdsEditingOwnership = false
    applyInputAdmission(false)
  }

  /// The model retains one return surface in the same WebKit pool. Parking
  /// changes scheduling priority, not its DOM, source, editor or scroll state.
  func parkForReturn() {
    releaseInputOwnership()
    surfaceLease?.updatePriority(.neighbor); requestedPriority = .neighbor
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
    // Only the installed canonical source admits input. A loading overlay
    // never grants access to the transparent interaction layer underneath it.
    acceptsInput = isInteractive && installed && hasCanonicalPixels
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
    if isReady, stage == .preparedPageStartAt || stage == .frameEvaluationStartAt {
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

  func mount(in host: DocumentWebHost, physicalSize: CGSize, isInteractive: Bool, priority: WebPriority,
    purpose: @escaping @MainActor () -> ScenePreparationPurpose = { .required }) {
    guard !isInvalidated, headlessClaim?.isCancelled != true else { return }
    requestedPreparationPurpose = purpose
    // A mounted neighbour may already be waiting for its shared source. Its
    // new current demand reaches that operation even when no host is rebuilt.
    payload?.source.promotePreparation(to: printPriority(for: priority))
    beginPreparationObservation(configuredAt: ProcessInfo.processInfo.systemUptime)
    recordPreparation(.mountAt)
    let previousHost = self.host
    self.host = host
    if let webView, previousHost !== host || !host.ownsSurface(webView) {
      host.install(webView, size: physicalSize); host.installPaper(printedView)
      if previousHost !== host { previousHost?.removeSurface(ownedBy: webView) }
    } else if webView == nil, paperIsReady { host.installPaper(printedView) }
    DocumentRenderRegistry.shared.mountRenderer(self, hostID: hostID)
    self.physicalSize = physicalSize
    applyInputAdmission(isInteractive)
    if let snapshotPixelWidth, host.showFallback(source: fallbackSource, resources: resources,
      minimumScale: Self.snapshotMinimumScale(pixelWidth: snapshotPixelWidth, size: physicalSize)) {
      snapshotOnlyComplete = true
      acquisitionError = nil; preparationFailure = nil
      releaseWebSurface()
      setRenderReady(true)
      onRenderReady(true)
      return
    }
    if waitingForCanonicalSnapshot { return }
    let resumingPreparation = acquisitionError is CancellationError
    if resumingPreparation {
      guard resources.allowsOptionalPreparation || requestedPreparationPurpose() == .required else { return }
      acquisitionError = nil; preparationFailure = nil
    }
    if let acquisitionError {
      onPreparationFailure(acquisitionError)
      return
    }
    if !renderIsReady, !preservesFallback { host.showFallback(source: fallbackSource, resources: resources) }
    if webView != nil {
      surfaceLease?.updatePriority(priority); requestedPriority = priority
      refreshInputAdmission()
      if !hasCanonicalPixels { beginPreparationDeadline() }
      if resumingPreparation { prepareAndSendFrame() }
      return
    }
    if acquisitionTask != nil {
      if requestedPriority != priority {
        requestedPriority = priority
        if let acquisitionID { resources.updatePendingWebPriority(acquisitionID, priority: priority) }
      }
      if resumingPreparation { prepareNativePaper() }
      return
    }
    guard resources.allowsOptionalPreparation || requestedPreparationPurpose() == .required else {
      requestedPriority = priority; withdrawPreparation(); return
    }
    if let snapshotPixelWidth, acquisitionTask == nil, let payload,
      let producer = DocumentRenderRegistry.shared.rasterProducer(documentID: payload.documentID,
        token: payload.rasterToken, resources: resources, excluding: hostID) {
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
          else if error is CancellationError { withdrawPreparation() }
          else { failPreparation(error, scope: .interaction) }
        }
      }
      return
    }
    let id = UUID()
    acquisitionID = id
    requestedPriority = priority
    acquisitionError = nil; preparationFailure = nil
    onRenderReady(false)
    let resources = resources
    recordPreparation(.admissionRequestedAt)
    // The physical page already owns its accepted source and native host.
    // Its PDF does not need the queued transparent interaction executor.
    prepareNativePaper()
    acquisitionTask = Task { [weak self] in
      do {
        guard let priority = self?.requestedPriority, self?.headlessClaim?.isCancelled != true else { return }
        let lease = try await resources.acquireWebSurface(priority: priority, constructsView: true,
          purpose: { [weak self] in self?.requestedPreparationPurpose() ?? .optional }, requestID: id)
        guard let self, !Task.isCancelled, !isInvalidated, headlessClaim?.isCancelled != true, acquisitionID == id, let host = self.host else {
          lease.release(); return
        }
        acquisitionTask = nil
        lease.updatePriority(requestedPriority ?? priority)
        surfaceLease = lease
        recordPreparation(.admittedAt)
        beginPreparationDeadline()
        let web = DocumentWebViewFactory.make(coordinator: self, lease: lease)
        host.install(web, size: self.physicalSize); host.installPaper(self.printedView)
        host.configure(size: self.physicalSize, interactive: acceptsInput)
        prepareAndSendFrame()
      } catch {
        guard let self, !Task.isCancelled, !isInvalidated, acquisitionID == id else { return }
        acquisitionTask = nil
        if error is CancellationError { withdrawPreparation() }
        else { failPreparation(error, scope: .interaction) }
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
      mount(in: host, physicalSize: physicalSize, isInteractive: requestedInput, priority: priority,
        purpose: requestedPreparationPurpose)
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
    programVisibilityTask?.cancel(); programVisibilityTask = nil
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
    onPageLayout = { _ in }; onStateChange = { _, _ in nil }
    onPreparationFailure = { _ in }; onLinkActivation = { _ in }
    releaseWebSurface()
    payload = nil; renderSession = nil
    if !preservesFallback { host?.removeFallback() }
  }

  /// An exclusive headless caller owns this coordinator, but a physical
  /// snapshot already submitted must finish its charged readback first.
  fileprivate func cancelHeadlessPreparation() {
    guard readerAdmission?.submitted != true else { return }
    invalidate()
  }

  private func failPreparation(_ error: Error, scope: PreparationFailure) {
    guard !isInvalidated else { return }
    acquisitionError = error; preparationFailure = scope
    preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
    setRenderReady(false)
    // A TeX error keeps the last installed page. A failed shell still retires
    // its admitted program state through the ordinary transfer owner.
    let hasLastGoodPrint = scope == .native && error is NotebookTypesetterError && printedView.raster != nil
    if hasLastGoodPrint {
      // A source typo ends this generation's requests, while the healthy
      // interaction executor and previous pixels remain for source repair.
      cancelPresentationWaiters()
    } else { finishProgramSurface() }
    let message = hasLastGoodPrint
      ? "Ошибка LaTeX. Исходник сохранён; показана предыдущая сборка."
      : "Не удалось подготовить страницу. Исходник сохранён."
    host?.showFailure(message) { [weak self] in
      self?.retryPreparation()
    }
    onPreparationFailure(error)
    onPresentationChange()
  }

  /// A revoked optional queue place has no terminal source failure. Its owner
  /// resumes this same source on normal pressure or an accepted page demand.
  private func withdrawPreparation() {
    acquisitionError = CancellationError(); preparationFailure = nil
    preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
    resolvePresentationWaiters()
    onPresentationChange()
  }

  func retryPreparation() {
    guard !isInvalidated, host != nil, requestedPriority != nil else { return }
    if preparationFailure == .native, webView != nil,
      acquisitionError.map({ $0 is NotebookTypesetterError }) == true {
      restartPreparation()
      return
    }
    programPreparationRetryRequested = true
    retryAcceptedProgramTransfers()
    finishProgramSurface()
  }

  private func restartPreparation() {
    guard !isInvalidated, let host, let priority = requestedPriority else { return }
    programPreparationRetryRequested = false
    let retryNativePreparation = preparationFailure == .native
    acquisitionError = nil; preparationFailure = nil; recoveryAttempts = 0
    if retryNativePreparation, let payload {
      sourcePreparationSubscriber?.cancel(); sourcePreparationSubscriber = nil
      sourcePreparationGeneration = nil; sourcePreparationID = nil
      payload.source.retryPagePreparation(payload.pageIndex)
    }
    host.removeFailure()
    if webView != nil {
      prepareAndSendFrame()
    } else {
      onBeforeRuntimeRestart()
      runtimeID = UUID(); payload?.runtimeID = runtimeID
      mount(in: host, physicalSize: physicalSize, isInteractive: requestedInput, priority: priority,
        purpose: requestedPreparationPurpose)
    }
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
      failPreparation(SceneRenderError.snapshotPending("document_preparation_timeout"), scope: .interaction)
    }
  }

  /// The source owner reports actual pool admission events. A queued fragment
  /// consumes none of its renderer's execution deadline; repeated waits cannot
  /// reset the execution time already spent by the same generation.
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
    webView?.evaluateJavaScript("window.notebookRenderer?.setEditingEnabled(false)", completionHandler: nil)
  }

  func activateEditing() {
    guard !isInvalidated, requestedInput || holdsEditingOwnership else { return }
    ownsEditing = true; payload?.editable = true
    webView?.evaluateJavaScript("window.notebookRenderer?.setEditingEnabled(true)", completionHandler: nil)
  }

  @MainActor private final class ProgramCheckpointWrite {
    let token: String
    let source: DocumentProgramSource
    let state: ContentFieldVersion?
    let descriptor: JSONValue
    var retryRequested = false
    var snapshot: NotebookProgramStateTransfer.Checkpoint?
    var hasWritten = false
    var receipt: ContentFieldVersion?
    var task: Task<ContentFieldVersion?, Error>?
    init(token: String, source: DocumentProgramSource, state: ContentFieldVersion?, descriptor: JSONValue) {
      self.token = token; self.source = source; self.state = state; self.descriptor = descriptor
    }
  }
  private var programCheckpointWrites: [String: ProgramCheckpointWrite] = [:]
  private var programCheckpointTask: Task<Bool, Never>?
  private var programRetirementTask: Task<Void, Never>?
  private var programRetirementRequested = false
  private var programPreparationRetryRequested = false
  private var programVisibilityTask: Task<Void, Never>?
  private(set) var programsVisible = true
  private var programResumeBlocked = false

  /// Presentation changes keep the same program owner, but stop its author
  /// before saving. A rapid return waits for that durable checkpoint.
  func setProgramsVisible(_ visible: Bool) {
    guard programsVisible != visible else { return }
    programsVisible = visible; programResumeBlocked = true
    reconcileProgramVisibility()
  }

  private func reconcileProgramVisibility() {
    guard !isInvalidated, isReady, requestedInput || ownsProgramState, programVisibilityTask == nil else { return }
    programVisibilityTask = Task { @MainActor [self] in
      defer { programVisibilityTask = nil }
      repeat {
        let visible = programsVisible
        guard let webView, !isInvalidated else { return }
        do {
          _ = try await NotebookProgramBridge.request("program_visibility",
            script: "await notebookRenderer.setProgramsVisible(visible);return true;",
            arguments: ["visible": visible], in: webView)
        } catch {
          failProgramTransfer(error)
          return
        }
        guard await checkpointPrograms(resume: false) else {
          onRenderReady.failed(.init(kind: .preparationFailed,
            message: "Состояние программы ещё не сохранено. Она приостановлена; повторите запись.",
            retry: { [weak self] in
              self?.retryAcceptedProgramTransfers(); self?.reconcileProgramVisibility()
            }))
          return
        }
        if visible, programsVisible {
          programResumeBlocked = false
          guard await resumePrograms() else { return }
          onRenderReady(renderIsReady)
        }
        if programsVisible == visible { return }
      } while !isInvalidated
    }
  }

  private func persistProgramCheckpoint(_ id: String, snapshot descriptor: JSONValue,
    token: String, source: DocumentProgramSource, state: ContentFieldVersion?, in web: WKWebView) async throws -> ContentFieldVersion? {
    let write: ProgramCheckpointWrite
    if let pending = programCheckpointWrites[id], pending.token == token, pending.source == source, pending.state == state {
      if let task = pending.task { return try await task.value }
      write = pending
    } else {
      write = .init(token: token, source: source, state: state, descriptor: descriptor)
      programCheckpointWrites[id] = write
    }
    let transfer = programStateTransfer(id, token: token)
    let task = Task { @MainActor [self] in
      if write.snapshot == nil {
        write.snapshot = try await transfer.checkpoint(NotebookProgramBridge.stateSnapshot(descriptor)) { revision, offset in
          guard case .string(let text) = try await Self.programStateRequest(blockID: id, token: token, operation: "notebook-snapshot",
            argument: .object(["revision": .string(revision), "offset": .number(Double(offset))]), in: web) else {
            throw SceneRenderError.snapshotPending("program_state_window")
          }
          return text
        }
      }
      guard let snapshot = write.snapshot else { throw CancellationError() }
      if !write.hasWritten {
        write.receipt = try await onStateCheckpoint(id, snapshot.value, source, state)
        write.hasWritten = true
      }
      // Retry resumes only the failed writer/ACK stage. The frozen value and
      // its admission survive an I/O failure without another transfer copy.
      if let accepted = write.receipt, !isInvalidated, blockTokens[id] == token,
        installedPrograms[id]?.sourceBasis == source.sourceBasis, webView === web {
        let basisJSON = try canonicalDocumentJSON(state), versionJSON = try canonicalDocumentJSON(accepted)
        _ = try await NotebookProgramBridge.request("checkpoint_ack",
          script: "notebookRenderer.acknowledgeProgramCheckpoint(block,token,JSON.parse(basis),JSON.parse(version));return true;",
          arguments: ["block": id, "token": token, "basis": basisJSON, "version": versionJSON], in: web)
      }
      return write.receipt
    }
    write.task = task
    do {
      let accepted = try await task.value
      if programCheckpointWrites[id] === write { programCheckpointWrites[id] = nil }
      write.task = nil; write.snapshot?.release(); write.snapshot = nil
      return accepted
    } catch {
      write.task = nil
      throw error
    }
  }

  func checkpointFocusedProgram(resume: Bool) async -> Bool {
    guard let blockID = focusedProgramID, let token = blockTokens[blockID], let web = webView else { return true }
    let accepted = await checkpointProgramsOnce(blockID: blockID)
    guard accepted else { return false }
    if resume, blockTokens[blockID] == token {
      do { _ = try await NotebookProgramBridge.request("resumeProgram",
        script: "return await notebookRenderer.resumeProgram(blockID);", arguments: ["blockID": blockID], in: web) }
      catch { return false }
    }
    return true
  }

  func checkpointPrograms(resume: Bool) async -> Bool {
    let task: Task<Bool, Never>
    if let pending = programCheckpointTask { task = pending }
    else {
      task = Task { @MainActor [self] in await checkpointProgramsOnce() }
      programCheckpointTask = task
    }
    let accepted = await task.value; programCheckpointTask = nil
    if resume { return await resumePrograms() && accepted }
    return accepted
  }

  private func checkpointProgramsOnce(blockID: String? = nil) async -> Bool {
    guard !isInvalidated, isReady, requestedInput || ownsProgramState, let webView, let before = payload,
      before.programMode != "external", !installedPrograms.isEmpty else { return true }
    do {
      let operation = acquisitionError == nil ? "checkpointPrograms" : "finishAcceptedPrograms"
      let result: JSONValue
      if let blockID {
        result = try await NotebookProgramBridge.request("checkpointFocusedProgram",
          script: "return await notebookRenderer.checkpointProgram(blockID);", arguments: ["blockID": blockID], in: webView)
      } else { result = try await NotebookProgramBridge.lifecycle(operation, controller: "notebookRenderer", in: webView) }
      guard case .array(let checkpoints) = result, !isInvalidated, payload?.runtimeID == before.runtimeID else { return false }
      var accepted = true
      for checkpoint in checkpoints {
        guard case .string(let id) = checkpoint["blockID"], case .string(let token) = checkpoint["token"],
          token == blockTokens[id], let version = before.source.program(id),
          installedPrograms[id]?.sourceBasis == version.sourceBasis else { accepted = false; continue }
        let transfer = programStateTransfer(id, token: token)
        if checkpoint["acceptedOnly"] == .bool(true) {
          try await transfer.drain()
          if let pending = programCheckpointWrites[id] {
            guard pending.task != nil || pending.retryRequested else { accepted = false; continue }
            pending.retryRequested = false
            if try await persistProgramCheckpoint(id, snapshot: pending.descriptor, token: token,
              source: pending.source, state: pending.state, in: webView) == nil { accepted = false }
          }
          continue
        }
        guard let snapshot = checkpoint["snapshot"], let basis = checkpoint["stateVersion"] else { accepted = false; continue }
        let stateVersion = basis == .null ? nil : try basis.decode(ContentFieldVersion.self)
        if try await persistProgramCheckpoint(id, snapshot: snapshot, token: token,
          source: version, state: stateVersion, in: webView) == nil { accepted = false }
      }
      return accepted
    } catch { return false }
  }

  private func failProgramTransfer(_ error: Error) {
    onPreparationFailure(error)
    // A broken author already has the preparation Retry. Transport alone does
    // not authorize replacing a healthy heap or replaying its startup code.
    guard acquisitionError == nil else { return }
    programResumeBlocked = true
    onRenderReady.failed(.init(kind: .preparationFailed,
      message: "Состояние программы ещё не сохранено. Повторите запись.",
      retry: { [weak self] in
        guard let self else { return }
        retryAcceptedProgramTransfers()
        if programRetirementRequested { finishProgramSurface() }
        else { reconcileProgramVisibility() }
      }))
  }

  private func retryAcceptedProgramTransfers() {
    for entry in programStateTransfers.values { entry.owner.retry() }
    for write in programCheckpointWrites.values { write.retryRequested = true }
  }

  func retireAfterProgramCheckpoint() {
    guard !isInvalidated else { return }
    if programRetirementRequested { retryAcceptedProgramTransfers() }
    programRetirementRequested = true
    if let web = webView { DocumentRenderRegistry.shared.retainRetiringProgram(self, web: web, hostID: hostID) }
    finishProgramSurface()
  }

  /// One boundary owns close and error teardown. Readiness and rendering may
  /// fail while an already admitted descriptor is still crossing WebKit IPC.
  private func finishProgramSurface() {
    guard !isInvalidated, programRetirementTask == nil else { return }
    guard isReady, requestedInput || ownsProgramState, payload?.programMode != "external",
      payload?.source.programIDs.isEmpty == false, webView != nil else {
      if programRetirementRequested { invalidate() }
      else {
        releaseWebSurface()
        if programPreparationRetryRequested { restartPreparation() }
      }
      return
    }
    programRetirementTask = Task { @MainActor [self] in
      defer { programRetirementTask = nil }
      if await checkpointPrograms(resume: false) {
        if programRetirementRequested { invalidate() }
        else {
          releaseWebSurface()
          // Only an explicit UI Retry authorizes a new executor. A successful
          // transport retry alone merely finishes the previous accepted state.
          if programPreparationRetryRequested { restartPreparation() }
        }
      } else {
        programPreparationRetryRequested = false
        onPreparationFailure(SceneRenderError.snapshotPending("document_state_checkpoint_not_accepted"))
      }
    }
  }

  @discardableResult
  func resumePrograms() async -> Bool {
    guard !isInvalidated, isReady, programsVisible, !programResumeBlocked,
      programCheckpointWrites.isEmpty, !programStateTransfers.values.contains(where: { $0.owner.hasPendingCheckpoint }),
      let webView else { return false }
    do { _ = try await NotebookProgramBridge.lifecycle("resumePrograms", controller: "notebookRenderer", in: webView); return true }
    catch {
      programResumeBlocked = true
      onRenderReady.failed(.init(kind: .preparationFailed,
        message: "Программа не возобновилась. Повторите продолжение.",
        retry: { [weak self] in self?.reconcileProgramVisibility() }))
      return false
    }
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
    DocumentRenderRegistry.shared.publishLive(documentID: payload.documentID, token: payload.compositeToken,
      pageIndex: pageIndex, hostID: hostID, generation: generation,
      paper: { [weak self] in self?.installedPaper }) { [weak self] _ in
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
    preparationFailure = .interaction
    releaseWebSurface()
    guard recoveryAttempts < 2, let host, let priority = requestedPriority else {
      failPreparation(SceneRenderError.snapshotPending("web_process_terminated"), scope: .interaction); return
    }
    recoveryAttempts += 1; acquisitionError = nil; preparationFailure = nil
    runtimeID = UUID(); payload?.runtimeID = runtimeID
    onBeforeRuntimeRestart()
    mount(in: host, physicalSize: physicalSize, isInteractive: requestedInput, priority: priority,
      purpose: requestedPreparationPurpose)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    guard !isInvalidated, self.webView === webView else { return }
    failPreparation(error, scope: .interaction)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
    guard !isInvalidated, self.webView === webView else { return }
    failPreparation(error, scope: .interaction)
  }

  private func releaseWebSurface() {
    programAssets.revokeAll(); programURLs.removeAll(); installedPrograms.removeAll(); programIdentities.removeAll(); focusedProgramID = nil
    for entry in programStateTransfers.values { entry.owner.revoke() }
    programStateTransfers.removeAll(); programCheckpointWrites.removeAll(); programInitialStates.removeAll()
    cancelPresentationWaiters(keepingNativePreparation: retainsNativePreparation)
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
    if !retainsNativePreparation { payload?.source.releasePage(hostID: hostID, in: retiringWeb) }
    revokeLiveReceipt()
    clearSnapshotWait(); wakeSnapshotWaiters(unavailable: true)
    cancelSnapshotPreparation()
    preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
    acquisitionID = nil
    acquisitionTask?.cancel(); acquisitionTask = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "notebook")
    webView?.navigationDelegate = nil
    let preservesAcceptedPaper = retainsNativePreparation || (acquisitionError != nil && !isInvalidated
      && (paperIsReady || (preparationFailure == .native && printedView.raster != nil
        && acquisitionError.map { $0 is NotebookTypesetterError } == true)))
    if let retiringWeb { host?.removeSurface(ownedBy: retiringWeb, preservingPaper: preservesAcceptedPaper ? printedView : nil) }
    else if !preservesAcceptedPaper { host?.removePaper(ownedBy: printedView) }
    if !preservesAcceptedPaper { printedView.clear(); paperGeneration = nil }
    webView = nil
    isReady = false
    if !retainsNativePreparation {
      sourcePreparationSubscriber?.cancel(); sourcePreparationSubscriber = nil
      sourcePreparationGeneration = nil; sourcePreparationID = nil
    } else if sourcePreparationSubscriber == nil { sourcePreparationGeneration = nil; sourcePreparationID = nil }
    frameTaskID = nil; frameTask?.cancel(); frameTask = nil
    finishShellWait(throwing: CancellationError())
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
    readerAdmission?.retire()
    finishReader(throwing: CancellationError())
    finishRasterSnapshotAdmission(throwing: CancellationError())
    // The exact reader clears its own handle after it acknowledges cancellation.
    // A successor cannot replace a still-draining snapshot job.
    readerTask?.cancel()
    readerPreparedLease?.release(); readerPreparedLease = nil
  }

  isolated deinit {
    cancelPresentationWaiters()
    emptyShellDeadline?.cancel()
    payload?.source.releasePage(hostID: hostID, in: webView)
    clearSnapshotWait(); wakeSnapshotWaiters(unavailable: true)
    snapshotTask?.cancel()
    sourcePreparationSubscriber?.cancel(); sourcePreparationSubscriber = nil
    sourcePreparationGeneration = nil; sourcePreparationID = nil
    frameTask?.cancel()
    finishShellWait(throwing: CancellationError())
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

  func retainedGeometry(on pageIndex: Int) -> WorkspaceItemGeometry? {
    guard let raster = printedView.raster else { return nil }
    let pages = raster.page.artifact.pages
    guard !pages.isEmpty else { return nil }
    let page = pages[min(max(0, pageIndex), pages.count - 1)]
    return .document(widthPoints: page.width, heightPoints: page.height)
  }
  var retainsPreviousPrint: Bool { printedView.raster != nil && !printedSourceMatches }
  var installedPaper: DocumentPaperRaster? { paperIsReady ? printedView.raster : nil }

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
  var onStateChange: (DocumentProgramSource, JSONValue) async throws -> ContentFieldVersion?
  var onStateCheckpoint: (String, JSONValue, DocumentProgramSource, ContentFieldVersion?) async throws -> ContentFieldVersion? = { _, _, _, _ in nil }
  var onStateDrained: () async -> Void = {}
  var pendingSnapshotPayload: DocumentRuntimePayload?
  private var preparedSnapshotLease: RasterLease?

  init(
    resources: SceneRenderResources = .shared,
    renderSession: DocumentRenderSession? = nil,
    printPriority: NotebookTypesetter.Priority? = nil,
    onRenderReady: PageTurnReadiness,
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onStateChange: @escaping (DocumentProgramSource, JSONValue) async throws -> ContentFieldVersion?
  ) {
    self.resources = resources; self.renderSession = renderSession; self.fixedPrintPriority = printPriority
    self.onRenderReady = onRenderReady
    self.onPageLayout = onPageLayout
    self.onStateChange = onStateChange
  }

  func update(
    document: DocumentDocument,
    state: DocumentStateJournal,
    selectedPageIndex: Int,
    capturesSnapshot: Bool,
    onRenderReady: PageTurnReadiness,
    onPageLayout: @escaping (DocumentPageLayout) -> Void,
    onStateChange: @escaping (DocumentProgramSource, JSONValue) async throws -> ContentFieldVersion?,
    snapshotPixelWidth: Int? = nil,
    paperPreparationPixelWidth: Int = 1024,
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
    self.onStateChange = onStateChange
    self.snapshotPixelWidth = snapshotPixelWidth.map { min(256, max(1, $0)) }
    let paperWidth = self.snapshotPixelWidth ?? max(1, paperPreparationPixelWidth)
    let paperWidthChanged = self.paperPreparationPixelWidth != paperWidth
    self.paperPreparationPixelWidth = paperWidth
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
    let nextSource = renderSession.source(document, store: programStore)
    let stateIDs = externallyHostedPrograms ? [] : (nextSource.programIDs(on: selectedPageIndex) ?? Set(state.records.map(\.id)))
    let records = state.records.filter { stateIDs.contains($0.id) }
    // A first frame may predate measurement. Keep its immutable packet when
    // only records outside this physical page changed; they cannot affect it.
    let nextState: DocumentStateSnapshot
    if let previous = payload?.state, previous.message.documentID == document.id,
      previous.records.filter({ stateIDs.contains($0.id) }) == records { nextState = previous }
    else { nextState = renderSession.state(records: records) }
    #if os(macOS)
      let programMode = capturesSnapshot ? "headless" : "live"
    #else
      let programMode = externallyHostedPrograms ? "external" : (snapshotPixelWidth == nil ? "live" : "snapshot")
    #endif
    if payload?.pageIndex != selectedPageIndex || payload?.programMode != programMode
      || payload?.source !== nextSource || payload?.state !== nextState || paperWidthChanged {
      clearSnapshotWait()
      generation &+= 1
      sourcePreparationSubscriber?.cancel(); sourcePreparationSubscriber = nil
      sourcePreparationGeneration = nil; sourcePreparationID = nil
      cancelSnapshotPreparation()
      snapshotOnlyComplete = false
      acquisitionError = nil; preparationFailure = nil
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
      }
      if payload?.source !== nextSource {
        payload?.source.releasePage(hostID: hostID, in: webView)
        recoveryAttempts = 0
      }
      payload = DocumentRuntimePayload(source: nextSource, state: nextState,
        editable: ownsEditing, renderToken: DocumentSnapshotCache.paperToken(sourceRevision: document.contentStamp.revision, pageIndex: selectedPageIndex),
        pageIndex: selectedPageIndex, runtimeID: runtimeID, blockTokens: blockTokens, programMode: programMode)
      beginPreparationObservation(configuredAt: configuredAt)
      prepareAndSendFrame()
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
    finishShellWait()
    if !programsVisible { reconcileProgramVisibility() }
    recordPreparation(.shellNavigationFinishedAt)
    prepareAndSendFrame()
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
      (url.isFileURL && navigationAction.targetFrame?.isMainFrame == true) || url.scheme == "about"
        || (navigationAction.targetFrame?.isMainFrame == false && navigationAction.navigationType == .other
          && programURLs.values.contains(where: { $0.url == url })) ? .allow : .cancel
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
      finishShellWait()
      if !programsVisible { reconcileProgramVisibility() }
      recordPreparation(.shellReadyMessageAt)
      prepareAndSendFrame()
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
      failPreparation(SceneRenderError.snapshotPending("common_runtime_startup"), scope: .interaction)
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
      resolveLink(href, origin: origin, deliver: onLinkActivation)
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
      setRenderReady(false)
      if !externallyHostedPrograms, !payload.programs.isEmpty, programStartupDeadlineGeneration != generation {
        // A failed iframe has its own eight-second startup deadline. Leave time
        // for that addressed failure and the valid PDF to reach the same receipt.
        preparationDeadlineTask?.cancel(); preparationDeadlineTask = nil
        preparationDeadlineGeneration = generation; programStartupDeadlineGeneration = generation
        preparationDeadlineRemaining = .seconds(10); preparationDeadlineStarted = nil
      }
      beginPreparationDeadline()
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
        self.pageCount = max(1, payload.source.layout?.pageCount ?? pageCount)
        onPageLayout(
          DocumentPageLayout(pageCount: self.pageCount,
            sourceRevision: "\(payload.source.stamp.actor):\(payload.source.stamp.counter)", record: payload.source.layout)
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
      var diagnostics = DocumentRenderingFailure.diagnostics(in: body as NSDictionary)
      if diagnostics.isEmpty { diagnostics = [.init(kind: "render_error", elementID: body["blockID"] as? String,
        message: body["message"] as? String ?? "Не удалось подготовить страницу.")] }
      failPreparation(DocumentRenderingFailure(diagnostics: diagnostics, buildID: payload.source.layout?.buildID,
        programs: DocumentRenderRegistry.programChecks(in: body as NSDictionary, source: payload.source, pageIndex: payload.pageIndex)), scope: .interaction)
      return
    }
    guard body["runtimeID"] as? String == runtimeID.uuidString,
      let blockID = body["blockID"] as? String else { return }
    switch kind {
    case "requestSource":
      guard ownsEditing, renderIsReady, printedSourceMatches,
        body["sourceKey"] as? String == payload.source.message.key,
        body["pageIndex"] as? Int == payload.pageIndex,
        let x = body["x"] as? Double, let y = body["y"] as? Double,
        let file = payload.source.document.files.first(where: { $0.id == blockID && $0.isText }) else { return }
      let offset = payload.source.sourceOffset(fileID: blockID, pageIndex: payload.pageIndex, x: x, y: y) ?? 0
      NotificationCenter.default.post(name: DocumentSourceRequest.notification,
        object: DocumentSourceRequest(documentID: payload.documentID, file: file, version: payload.source.document.fileVersion(fileID: file.id), offset: offset))
    case "programReady":
      if let id = body["blockID"] as? String, body["blockToken"] as? String == blockTokens[id] { programInitialStates[id] = nil }
      guard body["blockToken"] as? String == blockTokens[blockID] else { return }
      onProgramReady()
    case "programFocus":
      guard body["blockToken"] as? String == blockTokens[blockID], let focused = body["focused"] as? Bool else { return }
      if focused { focusedProgramID = blockID } else if focusedProgramID == blockID { focusedProgramID = nil }
      onProgramFocus(focused)
    case "programRetry":
      guard requestedInput || ownsProgramState, !programRetirementRequested,
        let token = body["blockToken"] as? String, token == blockTokens[blockID],
        let source = installedPrograms[blockID], payload.source.program(blockID)?.sourceBasis == source.sourceBasis else { return }
      Task { @MainActor [self] in
        do {
          // The shell first closes and drains accepted commits. Native admission
          // owns the replacement token, credit and revision sequence together.
          try await programStateTransfers[blockID]?.owner.drain()
          guard !isInvalidated, !programRetirementRequested, blockTokens[blockID] == token,
            self.payload?.source.program(blockID)?.sourceBasis == source.sourceBasis else { return }
          programStateTransfers.removeValue(forKey: blockID)?.owner.revoke()
          programCheckpointWrites[blockID] = nil
          if let previous = programURLs.removeValue(forKey: blockID) { programAssets.revoke(previous.url) }
          programInitialStates[blockID] = nil
          blockTokens[blockID] = UUID().uuidString; self.payload?.blockTokens = blockTokens
          generation &+= 1
          cancelSnapshotPreparation(); snapshotOnlyComplete = false
          preparedSnapshotLease?.release(); preparedSnapshotLease = nil
          setRenderReady(false)
          prepareAndSendFrame()
        } catch { failProgramTransfer(error) }
      }
    case "programCheckpoint":
      guard requestedInput || ownsProgramState, let token = body["blockToken"] as? String, token == blockTokens[blockID],
        let source = installedPrograms[blockID], let snapshot: JSONValue = Self.decode(body["snapshot"]),
        let basis: JSONValue = Self.decode(body["stateVersion"]), let web = webView else { return }
      let stateVersion = basis == .null ? nil : try? basis.decode(ContentFieldVersion.self)
      guard basis == .null || stateVersion != nil else { return }
      Task { @MainActor [self] in
        do {
          _ = try await persistProgramCheckpoint(blockID, snapshot: snapshot, token: token,
            source: source, state: stateVersion, in: web)
        } catch { failProgramTransfer(error) }
      }
    case "stateCredit":
      guard let token = body["blockToken"] as? String, token == blockTokens[blockID],
        let bytes = body["bytes"] as? Int, let web = webView else { return }
      programStateTransfer(blockID, token: token).requestCredit(bytes) { bytes in
        Task { _ = try? await Self.programStateRequest(blockID: blockID, token: token,
          operation: "notebook-state-credit", argument: .number(Double(bytes)), in: web) }
      }
    case "state":
      guard let token = body["blockToken"] as? String, token == blockTokens[blockID],
        let program = installedPrograms[blockID],
        let descriptor: NotebookProgramStateTransfer.Snapshot = Self.decode(body["snapshot"]),
        let web = webView, let borrow = borrowSurfaceForTransfer(web) else { return }
      let writer = onStateChange, drained = onStateDrained, ownsState = requestedInput || ownsProgramState
      var receipt: ContentFieldVersion?
      programStateTransfer(blockID, token: token).receive(descriptor, retaining: borrow,
        read: { revision, offset in
          guard case .string(let text) = try await Self.programStateRequest(blockID: blockID, token: token, operation: "notebook-snapshot",
            argument: .object(["revision": .string(revision), "offset": .number(Double(offset))]), in: web) else {
            throw SceneRenderError.snapshotPending("program_state_window")
          }
          return text
        }, acknowledge: { revision in
          let encoded = try receipt.map(canonicalDocumentJSON) ?? "null"
          _ = try await NotebookProgramBridge.request("state_basis_ack",
            script: "notebookRenderer.acknowledgeProgramState(block,token,revision,JSON.parse(version),localOnly);return true;",
            arguments: ["block": blockID, "token": token, "revision": revision, "version": encoded, "localOnly": !ownsState], in: web)
          _ = try await Self.programStateRequest(blockID: blockID, token: token, operation: "notebook-snapshot-ack",
            argument: .string(revision), in: web)
        }, accept: { value, _ in
          if ownsState {
            receipt = try await writer(program, value)
            guard receipt != nil else { throw SceneRenderError.snapshotPending("document_state_not_accepted") }
            await drained()
          }
        }, onFailure: { [weak self] in self?.failProgramTransfer($0) })
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
      finishReader(throwing: DocumentSnapshotWait.presentationChanged)
    }
  }

  // Descriptors belong to installed executors, not a pending TeX compile.
  // SQL still checks their file basis against the latest authoritative files.
  private var installedPrograms: [String: DocumentProgramSource] = [:]
  private var programIdentities: [String: String] = [:]
  private func refreshProgramTokens(_ programs: [DocumentProgramSource]) {
    let identities = Dictionary(uniqueKeysWithValues: programs.map { ($0.id, $0.sourceBasis) })
    let nextTokens = Dictionary(uniqueKeysWithValues: programs.map { program in
      (program.id, programIdentities[program.id] == program.sourceBasis ? (blockTokens[program.id] ?? UUID().uuidString) : UUID().uuidString)
    })
    for (id, entry) in programStateTransfers where nextTokens[id] != entry.token {
      entry.owner.revoke(); programStateTransfers[id] = nil; programCheckpointWrites[id] = nil
    }
    for (id, entry) in programURLs where nextTokens[id] != entry.token {
      programAssets.revoke(entry.url); programURLs[id] = nil; programInitialStates[id] = nil
    }
    programIdentities = identities; installedPrograms = Dictionary(uniqueKeysWithValues: programs.map { ($0.id, $0) }); blockTokens = nextTokens
    payload?.blockTokens = nextTokens
  }

  private func programPackages(_ payload: DocumentRuntimePayload) -> [String: NotebookProgramPackage] {
    guard payload.programMode != "external" else { return [:] }
    let visible = payload.source.programIDs(on: payload.pageIndex) ?? payload.source.programIDs
    return Dictionary(uniqueKeysWithValues: payload.programs.compactMap { block in
      guard visible.contains(block.id), programURLs[block.id] == nil else { return nil }
      return (block.id, block.package)
    })
  }

  private func programStateTransfer(_ blockID: String, token: String) -> NotebookProgramStateTransfer {
    if let entry = programStateTransfers[blockID], entry.token == token { return entry.owner }
    let owner = NotebookProgramStateTransfer(resources: resources)
    programStateTransfers[blockID] = (token, owner)
    return owner
  }

  private func programStateCredits(_ payload: DocumentRuntimePayload) -> [String: Int] {
    guard payload.programMode != "external" else { return [:] }
    let ids = payload.source.programIDs(on: payload.pageIndex) ?? payload.source.programIDs
    return Dictionary(uniqueKeysWithValues: ids.compactMap { id in
      blockTokens[id].map { (id, programStateTransfer(id, token: $0).initialCredit) }
    })
  }

  private static func programStateRequest(blockID: String, token: String, operation: String,
    argument: JSONValue, in web: WKWebView) async throws -> JSONValue {
    let json = try canonicalDocumentJSON(argument)
    return try await NotebookProgramBridge.request(operation,
      script: "return await notebookRenderer.transferProgramState(block,token,operation,JSON.parse(argument));",
      arguments: ["block": blockID, "token": token, "operation": operation, "argument": json], in: web)
  }

  // The state is admitted/encoded off the input actor. Recheck the exact
  // payload before registration so a newer projection cannot seed an old heap.
  private func registerPrograms(_ packages: [String: NotebookProgramPackage], payload: DocumentRuntimePayload) async throws -> [String: String] {
    if let store = programStore {
      var prepared: [(block: DocumentProgramSource, package: NotebookProgramPackage,
        token: String, state: NotebookProgramStateEncoding)] = []
      for block in payload.programs {
        guard let package = packages[block.id], let token = blockTokens[block.id], programURLs[block.id] == nil else { continue }
        let state = try await NotebookProgramStateEncoding.prepare(payload.states[block.id] ?? block.initialState, resources: resources, forHTML: true)
        guard !Task.isCancelled, self.payload?.state === payload.state, blockTokens[block.id] == token else { throw CancellationError() }
        prepared.append((block, package, token, state))
      }
      // Initial buffers must all fit before future commits reserve the free
      // capacity. Otherwise the first iframe's unused credit can block the
      // next encoding before presentPage has mounted either program.
      guard !Task.isCancelled, self.payload?.state === payload.state,
        prepared.allSatisfy({ blockTokens[$0.block.id] == $0.token }) else { throw CancellationError() }
      for (block, package, token, state) in prepared {
        let url = try programAssets.register(store: store, package: package) { origin in
          try NotebookProgramBridge.document(program: block, stateJSON: state.htmlJSON,
            token: token, package: package, origin: origin, stateCredit: programStateTransfer(block.id, token: token).initialCredit)
        }
        programURLs[block.id] = (token, url); programInitialStates[block.id] = state
      }
    }
    return programURLs.mapValues { $0.url.absoluteString }
  }

  private func finishShellWait(throwing error: Error? = nil) {
    let continuation = shellContinuation; shellContinuation = nil
    if let error { continuation?.resume(throwing: error) }
    else { continuation?.resume() }
  }

  /// Native paper can advance while the single WebKit sender drains an older
  /// transparent interaction frame. Both jobs borrow the same immutable source
  /// preparation; only this generation may install its physical paper.
  private func prepareNativePaper() {
    guard !isInvalidated, headlessClaim?.isCancelled != true, acquisitionError == nil || retainsNativePreparation, let request = payload, host != nil,
      sourcePreparationGeneration != generation else { return }
    guard resources.allowsOptionalPreparation || requestedPreparationPurpose() == .required else { return }
    sourcePreparationSubscriber?.cancel()
    let expected = generation, trace = pagePreparationTrace, preparationID = UUID()
    sourcePreparationGeneration = expected; sourcePreparationID = preparationID
    sourcePreparationSubscriber = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      do {
        try Task.checkCancellation()
        guard !isInvalidated, headlessClaim?.isCancelled != true, generation == expected, sourcePreparationID == preparationID, host != nil,
          payload?.source === request.source else { throw CancellationError() }
        guard resources.allowsOptionalPreparation || requestedPreparationPurpose() == .required else { throw CancellationError() }
        // Only hidden passive paper has transferred its pixels to a picture.
        // Current paper keeps its last good print through a failed replacement.
        if let retained = printedView.raster,
          retained.page.pageIndex != request.pageIndex || retained.image.width != paperPreparationPixelWidth,
          requestedPriority != .currentPage, !SceneSourceVisibility.isVisible(printedView) {
          printedView.clear()
        }
        recordPreparation(.preparedPageStartAt, trace: trace)
        let admissionChanged: (Bool) -> Void = { [weak self] waiting in
          self?.preparationAdmissionChanged(waiting, generation: expected)
        }
        admissionChanged(true)
        let prepared = try await request.source.preparedPage(request.pageIndex, hostID: hostID,
          resources: resources, priority: printPriority(for: requestedPriority),
          onAdmissionWait: admissionChanged, onLayoutChanged: { [weak self, weak source = request.source] layout in
            guard let self, let source, payload?.source === source, hasCanonicalPixels else { return }
            pageCount = layout.pageCount
            webView?.callAsyncJavaScript("window.notebookRenderer.acceptSourceExtent(key, count); return true;",
              arguments: ["key": source.message.key, "count": layout.pageCount], in: nil, in: .page, completionHandler: nil)
            onPageLayout(.init(pageCount: layout.pageCount,
              sourceRevision: "\(source.stamp.actor):\(source.stamp.counter)", record: layout))
          })
        admissionChanged(false)
        try Task.checkCancellation()
        guard !isInvalidated, headlessClaim?.isCancelled != true, generation == expected, sourcePreparationID == preparationID, host != nil,
          payload?.source === request.source else { throw CancellationError() }
        guard resources.allowsOptionalPreparation || requestedPreparationPurpose() == .required else { throw CancellationError() }
        physicalSize = .init(width: prepared.fragment.width, height: prepared.fragment.height)
        host?.configure(size: physicalSize, interactive: acceptsInput)
        let paper: DocumentPaperRaster
        if let installed = printedView.raster, installed.page.artifact.pixelIdentity == prepared.printed.artifact.pixelIdentity,
          installed.page.pageIndex == prepared.fragment.pageIndex,
          installed.image.width >= paperPreparationPixelWidth {
          paper = installed.rebound(page: prepared.printed, sourceKey: request.source.message.key)
        } else {
          paper = try await DocumentPaperRaster.prepare(page: prepared.printed, sourceKey: request.source.message.key,
            pixelWidth: paperPreparationPixelWidth, resources: resources,
            purpose: { [weak self] in self?.requestedPreparationPurpose() ?? .optional }, waits: admissionChanged)
        }
        recordPreparation(.preparedPageReadyAt, trace: trace)
        try Task.checkCancellation()
        guard !isInvalidated, headlessClaim?.isCancelled != true, generation == expected, sourcePreparationID == preparationID, host != nil,
          payload?.source === request.source else { throw CancellationError() }
        pageCount = request.source.layout?.pageCount ?? pageCount
        printedView.install(paper, resources: resources,
          purpose: { [weak self] in self?.requestedPreparationPurpose() ?? .optional })
        host?.installPaper(printedView); paperGeneration = expected
        recordPreparation(.paperInstalledAt, trace: trace)
        refreshInputAdmission()
        if let layout = request.source.layout {
          onPageLayout(.init(pageCount: layout.pageCount,
            sourceRevision: "\(request.source.stamp.actor):\(request.source.stamp.counter)", record: layout))
        }
        resolvePresentationWaiters()
        onPaperReady()
        return prepared
      } catch {
        // A replaced/retired job cannot fail the current source or resume its
        // waiters. Current native failure must also finish readers while an old
        // shell call is still draining.
        if !Task.isCancelled, !isInvalidated, generation == expected, sourcePreparationID == preparationID,
          payload?.source === request.source {
          if error is CancellationError {
            sourcePreparationGeneration = nil; sourcePreparationSubscriber = nil; sourcePreparationID = nil
            withdrawPreparation()
          } else { failPreparation(error, scope: .native) }
        }
        throw error
      }
    }
  }

  private func prepareAndSendFrame() {
    guard !isInvalidated, host != nil, payload != nil,
      sentGeneration != generation else { return }
    prepareNativePaper()
    guard webView != nil else { return }
    // A latest frame needs its own deadline even while the single sender is
    // still encoding or evaluating its predecessor.
    beginPreparationDeadline()
    // A newer native demand must revoke an old pending image's publication
    // before the single sender can drain that decode and submit the next page.
    // The scalar fence never starts a source/render or releases its owned tail.
    if isReady {
      webView?.evaluateJavaScript("window.notebookRenderer.requireFrame({runtimeID:'\(runtimeID.uuidString)',generation:'\(generation)'})", completionHandler: nil)
    }
    guard frameTask == nil else { return }
    let taskID = UUID(); frameTaskID = taskID
    frameTask = Task { @MainActor [weak self] in
      defer {
        if let self, frameTaskID == taskID { frameTask = nil; frameTaskID = nil }
      }
      while let self, !Task.isCancelled, !isInvalidated, frameTaskID == taskID,
        let web = webView, var next = payload, sentGeneration != generation {
        let expected = generation
        let trace = pagePreparationTrace
        recordPreparation(.frameTaskAt, trace: trace)
        var nativePreparationID: UUID?
        do {
          guard let lease = surfaceLease else { throw CancellationError() }
          prepareNativePaper()
          guard let subscriber = sourcePreparationSubscriber, let preparationID = sourcePreparationID,
            sourcePreparationGeneration == expected else {
            throw CancellationError()
          }
          nativePreparationID = preparationID
          let prepared = try await subscriber.value
          try Task.checkCancellation()
          guard !isInvalidated, frameTaskID == taskID, webView === web else { return }
          guard generation == expected, payload?.source === next.source else { continue }
          guard sourcePreparationID == preparationID else { continue }
          // The sender now owns this packet through its real JS callback. The
          // coordinator need not retain another completed preparation task.
          sourcePreparationSubscriber = nil
          let admissionChanged: (Bool) -> Void = { [weak self] waiting in
            self?.preparationAdmissionChanged(waiting, generation: expected)
          }
          if next.programMode != "external" { try await next.source.preparePrograms(on: [next.pageIndex]) }
          guard generation == expected else { continue }
          if let ids = next.source.programIDs(on: next.pageIndex), next.programMode != "external" {
            let local = next.state.records.filter { ids.contains($0.id) }
            if local.count != next.state.records.count, let renderSession {
              next.state = renderSession.state(records: local)
              payload?.state = next.state; pendingSnapshotPayload?.state = next.state
            }
          }
          refreshProgramTokens(next.programs)
          let source = sentSourceKey == next.source.message.key && sentSourcePage == prepared.fragment.pageIndex
            ? nil : try await prepared.encodedMessage(resources: resources, programs: next.programs, failures: next.source.programFailures, externalPrograms: next.programMode == "external", onAdmissionWait: admissionChanged)
          recordPreparation(.pageSourceEncodedAt, trace: trace)
          defer { withExtendedLifetime(source) {} }
          let state = sentStateKey == next.state.message.key ? nil : try await next.state.encodedState(resources: resources)
          recordPreparation(.stateEncodedAt, trace: trace)
          let packages = programPackages(next)
          guard !Task.isCancelled, !isInvalidated, frameTaskID == taskID, webView === web else { return }
          // Native preparation has already installed this exact generation.
          // Only its transparent interaction packet waits for the shell here.
          if !isReady {
            try await withCheckedThrowingContinuation { shellContinuation = $0 }
          }
          guard !Task.isCancelled, !isInvalidated, frameTaskID == taskID, webView === web else { return }
          guard generation == expected else { continue }
          let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
          guard let current = payload else { return }
          let programURLs = try await registerPrograms(packages, payload: current)
          guard !Task.isCancelled, generation == expected else { continue }
          let frame = String(decoding: try encoder.encode(current.frame(generation: expected, programURLs: programURLs, programsVisible: programsVisible, programStateCredit: programStateCredits(current))), as: UTF8.self)
          recordPreparation(.frameEncodedAt, trace: trace)
          var script = ""
          if let source { script += "await window.notebookRenderer.installPageSource(\(source.json));" }
          if let state {
            guard try await state.send(controller: "notebookRenderer", in: web) else { throw CancellationError() }
            guard !Task.isCancelled, generation == expected else { continue }
          }
          // Keep the submitted page bytes and physical lease charged through the
          // actual serial render, including its non-cancellable image decode tail.
          script += "await window.notebookRenderer.presentPage(\(frame));"
          recordPreparation(.frameEvaluationStartAt, trace: trace)
          try await evaluateFrame(script, message: source, lease: lease, in: web)
          recordPreparation(.frameEvaluationReturnedAt, trace: trace)
          guard !Task.isCancelled, !isInvalidated, frameTaskID == taskID, webView === web else { return }
          guard generation == expected else { continue }
          if layoutAccepted, canonicalPixelEpoch != nil, canonicalPixelEpoch == pixelPresentation?.epoch { setRenderReady(true); capturePendingSnapshotIfReady() }
          sentSourceKey = next.source.message.key; sentSourcePage = prepared.fragment.pageIndex; sentStateKey = next.state.message.key; sentGeneration = expected
        } catch {
          guard !Task.isCancelled, !isInvalidated, frameTaskID == taskID, generation == expected else { continue }
          if let nativePreparationID, sourcePreparationID != nativePreparationID {
            // A withdrawn optional subscriber may finish after a required
            // remount starts its successor in this same source generation.
            // Its result belongs to that retired attempt; the single sender
            // continues with the already admitted successor.
            if acquisitionError == nil { continue }
            return
          }
          // The native job already publishes its own failure independently of
          // this sender. Only a failure from the remaining JS work is new here.
          if acquisitionError == nil {
            if error is CancellationError, !resources.allowsOptionalPreparation,
              requestedPreparationPurpose() == .optional { withdrawPreparation() }
            else { failPreparation(error, scope: .interaction) }
          }
          return
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
    // The receipt describes the prepared source and hit geometry. Native paper
    // installation owns pixel/input readiness; animation callbacks prove neither.
    let script = trace == nil ? """
      window.notebookRenderer.setPageIndex(index);
      return window.notebookRenderer.pageReceipt();
      """ : "return window.notebookRenderer.observedPageReceipt(index, attemptID);"
    webView.callAsyncJavaScript(script,
      arguments: ["index": value, "attemptID": trace?.identity.attemptID.uuidString ?? ""],
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
            try DocumentRenderRegistry.shared.publish(documentID: payload.documentID, token: payload.renderToken, source: payload.source, receipt: receipt,
              geometry: payload.paper.geometry)
            recordPreparation(.layoutReceiptAcceptedAt, trace: trace)
            layoutAccepted = true
          } catch { failPreparation(error, scope: .interaction); return }
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

  func resolveLink(_ href: String, origin: DocumentLinkOrigin,
    deliver: @escaping (DocumentLinkActivation) -> Void) {
    guard let layout = origin.source.layout else { return }
    deliver(.init(origin: origin, destination: layout.destination(for: href)))
  }

  private func setRenderReady(_ requested: Bool) {
    guard !isInvalidated else { return }
    let ready = requested && printedSourceMatches
    defer {
      if hasCanonicalPixels && !capturesSnapshot {
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

  /// Only an isolated export executor may request an authored representation.
  func exportSVG(program: DocumentProgramSource, state: JSONValue) async throws -> String {
    guard exportSnapshotID != nil, let before = payload, !isInvalidated else { throw CancellationError() }
    try await awaitPresentation(token: before.renderToken)
    guard let webView, !isInvalidated, payload?.renderToken == before.renderToken else { throw CancellationError() }
    let result = try await NotebookProgramBridge.lifecycle("exportProgram", controller: "notebookRenderer",
      argument: .object(["format": .string("svg"), "blockID": .string(program.id), "state": state]), in: webView)
    guard !isInvalidated, payload?.renderToken == before.renderToken, case .string(let svg) = result else { throw CancellationError() }
    try NotebookExportSVG.validate(Data(svg.utf8))
    return svg
  }

  func retainPreparedSnapshot(pixelWidth: Int, nativeScale: Double? = nil, force: Bool = false,
    waitsForRasterAdmission: Bool = false, reservation granted: RasterReservation? = nil, videoFrame: (blockID: String, time: Double)? = nil,
    purpose: (@MainActor () -> ScenePreparationPurpose)? = nil) async throws -> RasterLease {
    let callerPurpose: @MainActor () -> ScenePreparationPurpose = purpose ?? { [weak self] in
      self?.requestedPreparationPurpose() ?? .optional
    }
    let claim = DocumentSnapshotClaim(purpose: callerPurpose)
    return try await withTaskCancellationHandler {
      defer { claim.admission?.remove(claim) }
      try Task.checkCancellation()
      guard resources.allowsOptionalPreparation || callerPurpose() == .required else { throw CancellationError() }
      let raster = try await retainPreparedSnapshot(pixelWidth: pixelWidth, nativeScale: nativeScale, force: force,
        waitsForRasterAdmission: waitsForRasterAdmission, reservation: granted, videoFrame: videoFrame, claim: claim)
      guard !Task.isCancelled, !claim.isCancelled else { raster.release(); throw CancellationError() }
      return raster
    } onCancel: {
      claim.cancel()
      Task { @MainActor [weak self] in
        if let admission = claim.admission { self?.withdrawSnapshotIfUnneeded(admission) }
      }
    }
  }

  private func retainPreparedSnapshot(pixelWidth: Int, nativeScale: Double?, force: Bool,
    waitsForRasterAdmission: Bool, reservation granted: RasterReservation?, videoFrame: (blockID: String, time: Double)?,
    claim: DocumentSnapshotClaim) async throws -> RasterLease {
    guard let payload, !isInvalidated else { throw CancellationError() }
    let requestGeneration = generation
    // Only measured page membership can name a composite image. Before that
    // point no exact page-state cache lookup exists, so join canonical readiness.
    if payload.source.layout == nil {
      try await awaitPresentation(token: payload.renderToken)
      try Task.checkCancellation()
      guard generation == requestGeneration else { throw CancellationError() }
    }
    let source = SceneRasterSource.document(id: payload.documentID, token: snapshotToken(payload))
    let minimumScale = nativeScale ?? Self.snapshotMinimumScale(pixelWidth: pixelWidth, size: physicalSize)
    if !force, let cached = resources.retainRaster(for: source, minimumScale: minimumScale) { return cached }
    if let preceding = readerTask, let admission = readerAdmission, force || admission.withdrawn {
      // Force still requires a fresh capture, but its required demand protects
      // the shared predecessor while this caller joins its actual drain.
      if !admission.withdrawn { try admission.add(claim) }
      try? await preceding.value
      admission.remove(claim)
      try Task.checkCancellation()
      guard !isInvalidated, generation == requestGeneration,
        self.payload?.renderToken == payload.renderToken else { throw CancellationError() }
    }
    if readerTask == nil {
      let expectedGeneration = generation
      let taskID = UUID()
      let admission = DocumentSnapshotAdmission(resources: resources)
      try admission.add(claim)
      readerTaskID = taskID
      readerAdmission = admission
      readerTask = Task { @MainActor [weak self] in
        guard let self else { throw CancellationError() }
        defer {
          if readerTaskID == taskID { readerTaskID = nil; readerTask = nil; readerAdmission = nil }
        }
        try admission.requireCapture(resources: resources)
        if !force, let cached = resources.retainRaster(for: source, minimumScale: minimumScale) {
          readerPreparedLease?.release(); readerPreparedLease = cached; return
        }
        try await awaitPresentation(token: payload.renderToken)
        try admission.requireCapture(resources: resources)
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
            pixelHeight: height, waitsForAdmission: waitsForRasterAdmission, admission: admission)
        }
        guard !Task.isCancelled, admission.permitsCapture(resources: resources), !isInvalidated, generation == expectedGeneration, let web = webView else {
          reservation.release(); throw CancellationError()
        }
        if exportSnapshotID != nil {
          do {
            let ids = payload.source.programIDs(on: payload.pageIndex) ?? payload.source.programIDs
            if let videoFrame, !ids.contains(videoFrame.blockID) { throw CollaborationError("export_block_missing", "Программы нет на выбранной странице видео.") }
            for block in payload.programs where ids.contains(block.id) {
              var request: [String: JSONValue] = ["format": .string("raster"), "blockID": .string(block.id),
                "state": payload.states[block.id] ?? block.initialState, "pixelRatio": .number(Double(pixelWidth) / size.width)]
              if let videoFrame, videoFrame.blockID == block.id { request["time"] = .number(videoFrame.time) }
              _ = try await NotebookProgramBridge.lifecycle("exportProgram", controller: "notebookRenderer", argument: .object(request), in: web)
              try admission.requireCapture(resources: resources)
            }
            guard !Task.isCancelled, !isInvalidated, generation == expectedGeneration else { throw CancellationError() }
          } catch { reservation.release(); throw error }
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
            pixelWidth: pixelWidth, size: size, scale: scale, nativeScale: nativeScale, admission: admission)
        }
      }
      observeSnapshotAdmission(admission)
    } else if let admission = readerAdmission {
      try admission.add(claim)
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

  private func observeSnapshotAdmission(_ admission: DocumentSnapshotAdmission) {
    _ = withObservationTracking { resources.optionalPreparationGeneration } onChange: { [weak self, weak admission] in
      MainActor.assumeIsolated {
        if let admission { self?.withdrawSnapshotIfUnneeded(admission) }
      }
    }
  }

  private func withdrawSnapshotIfUnneeded(_ admission: DocumentSnapshotAdmission) {
    guard readerAdmission === admission, admission.withdrawIfUnneeded(resources: resources) else { return }
    // Only this unsubmitted optional read retires. The mounted source and any
    // required borrower keep their existing physical producer and input fences.
    readerTask?.cancel()
    finishRasterSnapshotAdmission(throwing: CancellationError())
    finishReader(throwing: CancellationError())
  }

  /// The caller owns a retained copy. Intermediate paper pixels need no second
  /// pin after a composition or physical fallback has taken ownership.
  func releasePreparedSnapshot() { readerPreparedLease?.release(); readerPreparedLease = nil }

  private func reserveSnapshot(source: SceneRasterSource, pixelWidth: Int, pixelHeight: Int,
    waitsForAdmission: Bool, admission: DocumentSnapshotAdmission) async throws -> RasterReservation {
    try admission.requireCapture(resources: resources)
    if let reservation = resources.reserveRaster(pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel) { return reservation }
    let capacity = resources.rasterAdmission
    guard waitsForAdmission,
      let bytes = SceneRenderResources.estimatedRasterBytes(pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel),
      bytes <= capacity.byteLimit, bytes <= capacity.passiveByteLimit, capacity.countLimit > 0 else {
      throw SceneRenderError.resourceLimit
    }
    precondition(rasterSnapshotAdmissionContinuation == nil)
    return try await withCheckedThrowingContinuation { continuation in
      pendingRasterSnapshot = .init(source: source, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
        bytes: bytes, admission: capacity)
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
    guard readerAdmission?.permitsCapture(resources: resources) == true else {
      finishRasterSnapshotAdmission(throwing: CancellationError()); return
    }
    guard !isInvalidated, generation == rasterSnapshotAdmissionGeneration,
      payload.map({ SceneRasterSource.document(id: $0.documentID, token: snapshotToken($0)) }) == demand.source else {
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
  /// name the same canonical presentation, including its installation epoch.
  private func beginCanonicalSnapshot(id: UUID, capture: DocumentSnapshotCapture,
    payload: DocumentRuntimePayload, generation expected: UInt64,
    pixelWidth: Int, size: CGSize, scale: Double, nativeScale: Double?, admission: DocumentSnapshotAdmission) {
    guard let web = webView else { finishReader(throwing: CancellationError()); return }
    web.evaluateJavaScript("window.notebookRenderer.presentationReceipt()") { [weak self, capture] raw, error in
      guard let self, readerID == id else {
        capture.cancel(); return
      }
      do {
        if let error { throw error }
        let before = try canonicalSnapshotPresentation(raw, payload: payload, generation: expected)
        guard let web = webView else { throw CancellationError() }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        if nativeScale == nil { configuration.snapshotWidth = NSNumber(value: Double(pixelWidth) / scale) }
        try admission.submit(resources: resources)
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
              guard before == after, let image = capture.image, capture.reservation != nil else {
                throw DocumentSnapshotWait.presentationChanged
              }
              #if os(iOS)
                guard let overlay = image.cgImage else { throw SceneRenderError.resourceLimit }
              #else
                guard let overlay = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw SceneRenderError.resourceLimit }
              #endif
              guard let paper = printedView.raster?.page, printedSourceMatches else { throw DocumentSnapshotWait.presentationChanged }
              capture.submit() // Retain both accounted backings through the native draw tail.
              Task { @MainActor [weak self, capture] in
                var received = false
                do {
                  // WebKit may round its overlay down by one pixel. The native
                  // paper keeps the integral width already admitted for this
                  // request, so its density can satisfy the same waiting reader.
                  let cg = try await paper.image(width: pixelWidth, overlay: overlay)
                  #if os(iOS)
                    let normalized = UIImage(cgImage: cg, scale: nativeScale ?? Double(cg.width) / size.width, orientation: .up)
                  #else
                    let outputSize = nativeScale.map { CGSize(width: Double(cg.width) / $0, height: Double(cg.height) / $0) } ?? size
                    // The CGImage initializer re-rasterizes to logical points
                    // on AppKit. Keep the admitted pixels and their density.
                    let representation = NSBitmapImageRep(cgImage: cg)
                    representation.size = outputSize
                    let normalized = NSImage(size: outputSize)
                    normalized.addRepresentation(representation)
                  #endif
                  received = true
                  guard capture.receive(normalized) else { return }
                  guard let self, readerID == id else { capture.cancel(); return }
                  let final: DocumentPixelPresentation = try await withCheckedThrowingContinuation { continuation in
                    web.evaluateJavaScript("window.notebookRenderer.presentationReceipt()") { raw, error in
                      do {
                        if let error { throw error }
                        continuation.resume(returning: try self.canonicalSnapshotPresentation(raw, payload: payload, generation: expected))
                      } catch { continuation.resume(throwing: error) }
                    }
                  }
                  guard before == final,
                    let reservation = capture.reservation, let layout = payload.source.layout
                  else { throw DocumentSnapshotWait.presentationChanged }
                  guard let retained = DocumentSnapshotCache.shared.storeAndRetain(image: normalized, documentID: payload.documentID,
                    token: snapshotToken(payload), layout: layout, reservation: reservation, resources: resources)
                  else { throw SceneRenderError.resourceLimit }
                  readerPreparedLease?.release(); readerPreparedLease = retained; finishReader()
                } catch {
                  if !received { _ = capture.receive(nil) }
                  capture.cancel()
                  if self?.readerID == id { self?.finishReader(throwing: error) }
                }
              }
            } catch { finishReader(throwing: error) }
          }
        }
      } catch {
        finishReader(throwing: error)
      }
    }
  }

  private func canonicalSnapshotPresentation(_ raw: Any?, payload: DocumentRuntimePayload,
    generation expected: UInt64) throws -> DocumentPixelPresentation {
    guard !isInvalidated, generation == expected else { throw CancellationError() }
    let value = try presentation(in: raw, for: payload, generation: expected)
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
        } else { failPreparation(error, scope: .interaction) }
      }
    }
  }

}

private enum DocumentWebViewFactory {
  @MainActor
  static func make(coordinator: DocumentWebCoordinator, lease: WebSurfaceLease) -> WKWebView {
    precondition(!lease.isReleased)
    let constructionBegan = ContinuousClock.now
    let content = WKUserContentController()
    content.add(coordinator, name: "notebook")
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = content
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.setURLSchemeHandler(coordinator.programAssets, forURLScheme: NotebookProgramAssets.scheme)

    let webView = WKWebView(frame: .zero, configuration: configuration)
    coordinator.webView = webView
    webView.navigationDelegate = coordinator
    webView.underPageBackgroundColor = .clear
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
      // The canonical paper is a native sibling below this interaction layer.
      // underPageBackgroundColor alone leaves WebKit's page backing opaque.
      webView.setValue(false, forKey: "drawsBackground")
      webView.allowsMagnification = false
      // Paper moves with the scene, not with the window's titlebar inset.
      // WebKit ignores an unchanged zero before disabling automatic insets;
      // establish explicit ownership before this unmounted view can paint.
      webView.obscuredContentInsets = NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 0)
      webView.obscuredContentInsets = NSEdgeInsets()
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
    lease.finishConstruction(elapsed: constructionBegan.duration(to: .now))
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
  final class DocumentWebHost: PageTurnOutputParkingHost {
    private weak var outputReadiness: PageTurnReadiness?
    private struct OutputPresentation: Equatable {
      let documentID: UUID
      let paperToken: String
      let token: String
    }
    private var outputPresentation: OutputPresentation?
    func bindOutputReadiness(_ input: DocumentPagePresentation) {
      guard input.snapshotPixelWidth == nil else { releaseOutputReadiness(); return }
      let presentation = OutputPresentation(documentID: input.document.id,
        paperToken: input.paperToken, token: input.token)
      if outputReadiness !== input.onRenderReady || outputPresentation != presentation {
        revokeCurrentOutput()
        if outputReadiness?.idleOutputHost === self { outputReadiness?.idleOutputHost = nil }
      }
      outputReadiness = input.onRenderReady; outputPresentation = presentation
      if !input.onRenderReady.isRetired { input.onRenderReady.idleOutputHost = self }
    }
    private func releaseOutputReadiness() {
      revokeCurrentOutput()
      if outputReadiness?.idleOutputHost === self { outputReadiness?.idleOutputHost = nil }
      outputReadiness = nil; outputPresentation = nil
    }
    /// Only the installed opaque native print covers an idle output. WebKit's
    /// transparent interaction viewport alone cannot lend this background.
    override var canParkOutput: Bool {
      guard let outputReadiness, !outputReadiness.isRetired,
        outputReadiness.idleOutputHost === self, let outputPresentation,
        !hasSnapshot, failureView == nil, loadingView == nil,
        hasCanonicalPaperProjection else { return false }
      let paper: DocumentPaperView?
      if let viewport { paper = viewport.subviews.compactMap { $0 as? DocumentPaperView }.first }
      else { paper = retainedPaper }
      guard let paper, let raster = paper.raster,
        raster.page.artifact.document.id == outputPresentation.documentID,
        DocumentSnapshotCache.paperToken(sourceRevision: raster.page.artifact.document.contentStamp.revision,
          pageIndex: raster.page.pageIndex) == outputPresentation.paperToken,
        raster.page.pageIndex == outputReadiness.pageIndex else { return false }
      var ancestor: UIView? = paper
      while let view = ancestor, view !== self {
        guard !view.isHidden, view.alpha == 1 else { return false }
        ancestor = view.superview
      }
      return ancestor === self && super.canParkOutput
    }
    private weak var retainedPaper: DocumentPaperView?
    func installPaper(_ paper: DocumentPaperView) {
      revokeCurrentOutput()
      if let previous = paper.superview as? DocumentWebHost, previous !== self {
        previous.removePaper(ownedBy: paper)
      }
      if let viewport {
        retainedPaper = nil
        viewport.installBackground(paper)
      } else {
        if retainedPaper !== paper { retainedPaper?.removeFromSuperview() }
        paper.transform = .identity
        if paper.superview !== self { insertSubview(paper, at: 0) }
        retainedPaper = paper; projectRetainedPaper()
      }
      publishProjectionChange()
    }
    func removePaper(ownedBy paper: DocumentPaperView) {
      guard retainedPaper === paper else { return }
      revokeCurrentOutput()
      if paper.superview === self { paper.removeFromSuperview() }
      retainedPaper = nil
      publishProjectionChange()
    }
    private func projectRetainedPaper() {
      guard let paper = retainedPaper, paper.superview === self,
        paperSize.width > 0, paperSize.height > 0 else { return }
      let scale = min(bounds.width/paperSize.width, bounds.height/paperSize.height)
      paper.frame = CGRect(x: bounds.midX-paperSize.width*scale/2, y: bounds.midY-paperSize.height*scale/2,
        width: paperSize.width*scale, height: paperSize.height*scale)
      paper.refine()
    }
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
    var onWindowChange: () -> Void = { }
    private var presentationCallbackOwner: UUID?
    func claimPresentationCallbacks(for owner: UUID) { presentationCallbackOwner = owner }
    func releasePresentationCallbacks(for owner: UUID) {
      guard presentationCallbackOwner == owner else { return }
      presentationCallbackOwner = nil
      releaseOutputReadiness()
      // Accepted native contacts keep their terminal route. Size/window
      // observations end with this presentation; delivery ends at touch-up.
      onSizeChange = { }; onWindowChange = { }
    }
    private var lastLaidOutSize = CGSize.zero
    private var lastCanonicalProjection = false
    func showFailure(_ message: String, retry: @escaping () -> Void) {
      revokeCurrentOutput()
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
      revokeCurrentOutput()
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
    /// A source receipt alone cannot admit a PDF stretched into the previous
    /// scene cohort's placeholder rectangle. Geometry belongs to this physical
    /// host; camera projection must preserve the canonical paper's two axes.
    var hasCanonicalPaperProjection: Bool {
      guard paperSize.width > 0, paperSize.height > 0, !bounds.isEmpty, let window else { return false }
      let origin = convert(bounds.origin, to: window)
      let horizontal = convert(CGPoint(x: bounds.maxX, y: bounds.minY), to: window)
      let vertical = convert(CGPoint(x: bounds.minX, y: bounds.maxY), to: window)
      let scaleX = hypot(horizontal.x - origin.x, horizontal.y - origin.y) / paperSize.width
      let scaleY = hypot(vertical.x - origin.x, vertical.y - origin.y) / paperSize.height
      guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return false }
      guard abs(scaleX - scaleY) * max(paperSize.width, paperSize.height) <= 1 / window.screen.scale else { return false }
      let frames: [CGRect]
      if let viewport, let web = viewport.webView {
        guard web.bounds.size == paperSize else { return false }
        frames = [web.convert(web.bounds, to: self)] + viewport.subviews.compactMap { view in
          (view as? DocumentPaperView).map { $0.convert($0.bounds, to: self) }
        }
      } else if let paper = retainedPaper, paper.superview === self, paper.raster != nil {
        frames = [paper.convert(paper.bounds, to: self)]
      } else { return false }
      let tolerance = 1 / (window.screen.scale * max(scaleX, scaleY))
      return frames.allSatisfy { frame in
        abs(frame.minX - bounds.minX) <= tolerance && abs(frame.minY - bounds.minY) <= tolerance
          && abs(frame.width - bounds.width) <= tolerance && abs(frame.height - bounds.height) <= tolerance
      }
    }
    private func publishProjectionChange() {
      let installed = hasCanonicalPaperProjection
      if !installed { revokeCurrentOutput() }
      guard installed != lastCanonicalProjection else { return }
      lastCanonicalProjection = installed
      Task { @MainActor [weak self] in self?.onSizeChange() }
    }
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
      revokeCurrentOutput()
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
      revokeCurrentOutput()
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
      if ownsSurface(web) { viewport?.setContentSize(size); return }
      removeSurface()
      let incoming: PhysicalWebViewport
      if let projection = web.superview as? PhysicalWebViewport,
        let previous = projection.superview as? DocumentWebHost, previous.viewport === projection {
        // Transfer the physical subtree, not WebKit through an unattached new
        // wrapper. Its canonical bounds and window remain continuous; retiring
        // the departed host can no longer detach the incoming owner's surface.
        previous.revokeCurrentOutput()
        previous.viewport = nil
        incoming = projection
        incoming.setContentSize(size)
      } else { incoming = PhysicalWebViewport(webView: web, contentSize: size) }
      viewport = incoming
      incoming.onInstalled = { [weak self] in self?.publishProjectionChange() }
      let viewport = incoming
      if programOverlay.superview === self { insertSubview(viewport, belowSubview: programOverlay) }
      else if let fallback { insertSubview(viewport, belowSubview: fallback) } else { addSubview(viewport) }
      setNeedsLayout()
    }
    func configure(size: CGSize, interactive: Bool) {
      if paperSize != size { revokeCurrentOutput() }
      paperSize = size
      viewport?.setContentSize(size)
      projectRetainedPaper()
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
    func removeSurface() {
      revokeCurrentOutput()
      viewport?.retire(); viewport?.removeFromSuperview(); viewport = nil
      if let paper = retainedPaper, paper.superview === self { paper.removeFromSuperview() }
      retainedPaper = nil
    }
    func removeSurface(ownedBy web: WKWebView, preservingPaper paper: DocumentPaperView? = nil) {
      // A page handoff can replace this host before the old coordinator is
      // reused or reclaimed. Its historical host pointer owns no newer paper.
      guard viewport?.webView === web else { return }
      // A failed transparent shell ends its interaction lease, not the exact
      // native print already installed by this physical page owner.
      removeSurface()
      if let paper {
        paper.transform = .identity
        insertSubview(paper, at: 0); retainedPaper = paper; projectRetainedPaper()
      }
    }
    func ownsSurface(_ web: WKWebView) -> Bool {
      guard let viewport else { return false }
      return viewport.webView === web && web.superview === viewport
    }
    func hasCanonicalSurface(_ web: WKWebView) -> Bool {
      guard ownsSurface(web), window?.isKeyWindow == true, !hasSnapshot,
        failureView == nil, loadingView == nil, hasCanonicalPaperProjection,
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
      projectRetainedPaper()
      if lastLaidOutSize != bounds.size {
        lastLaidOutSize = bounds.size
        Task { @MainActor [weak self] in self?.onSizeChange() }
      }
      publishProjectionChange()
    }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      Task { @MainActor [weak self] in self?.onWindowChange() }
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
    let onStateChange: (DocumentProgramSource, JSONValue) async throws -> ContentFieldVersion?
    let resources: SceneRenderResources
    var snapshotPixelWidth: Int? = nil
    var onPreparationFailure: (Error) -> Void = { _ in }
    var onLinkActivation: (DocumentLinkActivation) -> Void = { _ in }
    var isCurrent = true
    var isVisible = true
    var isPageTurnActive = false
    var onStateCheckpoint: (String, JSONValue, DocumentProgramSource, ContentFieldVersion?) async throws -> ContentFieldVersion? = { _, _, _, _ in nil }
    var onStateDrained: () async -> Void = {}
    var measurements: DocumentPresentationRecorder? = nil
    var programStore: NotebookStore? = nil
    func makeCoordinator() -> DocumentPhysicalPageCoordinator { DocumentPhysicalPageCoordinator() }
    func makeUIView(context: Context) -> DocumentWebHost { DocumentWebHost() }
    func updateUIView(_ view: DocumentWebHost, context: Context) {
      let presentation = DocumentPagePresentation(document: document, state: state, pageIndex: selectedPageIndex,
        isCurrent: snapshotPixelWidth == nil && isCurrent, isVisible: isVisible, isInteractive: isInteractive,
        pageTurnActive: isPageTurnActive, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
         onStateChange: onStateChange,
          onLinkActivation: onLinkActivation,
        snapshotPixelWidth: snapshotPixelWidth, onPreparationFailure: onPreparationFailure,
        onStateCheckpoint: onStateCheckpoint, onStateDrained: onStateDrained, measurements: measurements, programStore: programStore)
      context.coordinator.update(presentation, in: view, resources: resources)
      view.bindOutputReadiness(presentation)
    }
    static func dismantleUIView(_ view: DocumentWebHost, coordinator: DocumentPhysicalPageCoordinator) { coordinator.invalidate() }
  }
#elseif os(macOS)
  @MainActor
  final class DocumentWebHost: NSView {
    private var canonicalSize = CGSize(width: 1, height: 1)
    private var projectionScale = 1.0
    func setProjectionScale(_ scale: Double) {
      guard scale.isFinite, scale > 0, scale != projectionScale else { return }
      projectionScale = scale; projectSurface()
    }
    private func projectSurface() {
      guard web != nil || paper != nil else { return }
      let size = CGSize(width: canonicalSize.width * projectionScale, height: canonicalSize.height * projectionScale)
      // The reading owner supplies a screen-point frame. Do not mutate this
      // representable's bounds from AppKit layout: SwiftUI owns that geometry.
      // WebKit alone projects its canonical CSS viewport through pageZoom.
      let rect = CGRect(origin: .zero, size: size)
      if web?.frame != rect { web?.frame = rect }
      if web?.pageZoom != CGFloat(projectionScale) { web?.pageZoom = projectionScale }
      if paper?.frame != rect { paper?.frame = rect; paper?.refine() }
    }
    private weak var paper: DocumentPaperView?
    func installPaper(_ paper: DocumentPaperView) {
      if let previous = paper.superview as? DocumentWebHost, previous !== self {
        previous.removePaper(ownedBy: paper)
      }
      self.paper = paper
      if paper.superview !== self { addSubview(paper, positioned: .below, relativeTo: web) }
      projectSurface(); paper.refine()
    }
    func removePaper(ownedBy paper: DocumentPaperView) {
      guard self.paper === paper else { return }
      if paper.superview === self { paper.removeFromSuperview() }
      self.paper = nil
    }
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
      canonicalSize = size; web.autoresizingMask = []; projectSurface()
    }
    func configure(size: CGSize, interactive: Bool) {
      inputEnabled = interactive
      canonicalSize = size; projectSurface()
      web?.setAccessibilityHidden(!interactive)
    }
    func ownsSurface(_ web: WKWebView) -> Bool { self.web === web && web.superview === self }
    func hasCanonicalSurface(_ web: WKWebView) -> Bool {
      ownsSurface(web) && window != nil && !isHidden
        && !web.isHidden && !hasSnapshot && failureView == nil && !bounds.isEmpty
    }
    func hasInteractiveSurface(_ web: WKWebView) -> Bool {
      inputEnabled && hasCanonicalSurface(web)
    }
    func removeSurface() {
      if let web, web.superview === self { web.removeFromSuperview() }
      if let paper, paper.superview === self { paper.removeFromSuperview() }
      paper = nil; web = nil
    }
    func removeSurface(ownedBy expected: WKWebView, preservingPaper retained: DocumentPaperView? = nil) {
      guard web === expected else { return }
      if let retained {
        if expected.superview === self { expected.removeFromSuperview() }
        web = nil; paper = retained
      } else { removeSurface() }
    }
  }

  private struct PlatformDocumentWebView: NSViewRepresentable {
    @Environment(\.macDocumentDisplayScale) private var projectionScale
    let document: DocumentDocument
    let state: DocumentStateJournal
    let isInteractive: Bool
    let selectedPageIndex: Int
    let capturesSnapshot: Bool
    let onRenderReady: PageTurnReadiness
    let onPageLayout: (DocumentPageLayout) -> Void
    let onStateChange: (DocumentProgramSource, JSONValue) async throws -> ContentFieldVersion?
    let resources: SceneRenderResources
    var snapshotPixelWidth: Int? = nil
    var onPreparationFailure: (Error) -> Void = { _ in }
    var onLinkActivation: (DocumentLinkActivation) -> Void = { _ in }
    var isCurrent = true
    var isVisible = true
    var isPageTurnActive = false
    var onStateCheckpoint: (String, JSONValue, DocumentProgramSource, ContentFieldVersion?) async throws -> ContentFieldVersion? = { _, _, _, _ in nil }
    var onStateDrained: () async -> Void = {}
    var measurements: DocumentPresentationRecorder? = nil
    var programStore: NotebookStore? = nil
    func makeCoordinator() -> DocumentWebCoordinator {
      DocumentWebCoordinator(resources: resources, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
         onStateChange: onStateChange)
    }
    func makeNSView(context: Context) -> DocumentWebHost { DocumentWebHost() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DocumentWebHost, context: Context) -> CGSize? {
      let size = context.coordinator.payload?.source.layout?.paper(on: selectedPageIndex).geometry
        ?? context.coordinator.retainedGeometry(on: selectedPageIndex)
        ?? DocumentRenderRegistry.shared.geometry(document: document, pageIndex: selectedPageIndex)
      // Native paper owns the extent, never WebKit's intrinsic content size.
      return proposal.replacingUnspecifiedDimensions(by: .init(width: size.width, height: size.height))
    }
    func updateNSView(_ view: DocumentWebHost, context: Context) {
      // The prepared paper and its host share the anchor's scale. Native
      // camera motion already projects anchor → current until settlement.
      view.setProjectionScale(projectionScale)
      context.coordinator.programStore = programStore
      context.coordinator.ownsProgramState = snapshotPixelWidth == nil
      context.coordinator.setProgramsVisible(isVisible)
      context.coordinator.onStateCheckpoint = onStateCheckpoint
      context.coordinator.onStateDrained = onStateDrained
      context.coordinator.update(document: document, state: state, selectedPageIndex: selectedPageIndex,
        capturesSnapshot: capturesSnapshot, onRenderReady: onRenderReady, onPageLayout: onPageLayout,
         onStateChange: onStateChange, snapshotPixelWidth: snapshotPixelWidth,
        onPreparationFailure: onPreparationFailure, onLinkActivation: onLinkActivation)
      let geometry = context.coordinator.payload?.source.layout?.paper(on: selectedPageIndex).geometry
        ?? context.coordinator.retainedGeometry(on: selectedPageIndex)
        ?? DocumentRenderRegistry.shared.geometry(document: document, pageIndex: selectedPageIndex)
      context.coordinator.mount(in: view, physicalSize: .init(width: geometry.width, height: geometry.height),
        isInteractive: isInteractive, priority: snapshotPixelWidth != nil ? .visible : (isCurrent ? .currentPage : .neighbor))
    }
    static func dismantleNSView(_ view: DocumentWebHost, coordinator: DocumentWebCoordinator) { coordinator.retireAfterProgramCheckpoint() }
  }
#endif
