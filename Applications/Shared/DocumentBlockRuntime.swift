import Foundation
import NotebookCore
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import WebKit

/// The executable identity of one document block. Physical paper cuts read or
/// mount this same viewport; snapshotting never changes its geometry or input.
@MainActor
final class DocumentBlockRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let documentID: UUID
  let program: DocumentProgramSource
  var sourceBasis: String { program.sourceBasis }
  let id = UUID()
  let resources: SceneRenderResources
  private(set) var webView: WKWebView?
  private(set) var ready = false
  private(set) var focused = false
  private(set) var value: JSONValue
  private(set) var failure: Error?
  private var lease: WebSurfaceLease?
  struct CheckpointBasis: Sendable { let version: ContentFieldVersion?; let revision: UInt64 }
  private(set) var session: ProgramSession<CheckpointBasis>?
  private var stateTransfer: NotebookProgramStateTransfer? { session?.stateTransfer }
  #if os(iOS)
  private var linkBridge: DocumentLinkActivationBridge?
  #endif
  private var linkDelivery: (id: UUID, task: Task<Void, Never>)?
  private var stateTransferFailure = false
  private var initialStateEncoding: NotebookProgramStateEncoding?
  private var startTask: Task<Void, Never>?
  private var startID: UUID?
  var pendingAdmissionID: UUID? { webView == nil ? startID : nil }
  private var requestedPriority: WebPriority?
  private var refusedAdmission: UInt64?
  private var readinessDeadline: Task<Void, Never>?
  private enum CaptureDestination: Equatable, Sendable { case cache, acceptedTurn }
  private enum CapturedFrame: Sendable { case raster(RasterLease), cut(SceneRasterCut) }
  private var captureReaders: [UUID: Task<CapturedFrame, Error>] = [:]
  private var captureQueue: [UUID] = []
  private var captureWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
  /// Reader cancellation and physical snapshot completion have distinct lives.
  /// The existing capture retains its admitted bytes and surface borrow until
  /// WebKit calls back, even when this result has already ended.
  @MainActor private final class SnapshotRequest {
    let capture: AgentSnapshotCapture
    var continuation: CheckedContinuation<AgentSnapshotImage, Error>?
    var deadline: Task<Void, Never>?
    var submitted = false
    init(reservation: RasterReservation, lease: WebSurfaceLease) {
      capture = AgentSnapshotCapture(reservation: reservation, lease: lease)
    }
    @discardableResult
    func finish(_ result: Result<AgentSnapshotImage, Error>) -> Bool {
      guard let continuation else { return false }
      self.continuation = nil; deadline?.cancel(); deadline = nil
      continuation.resume(with: result)
      return true
    }
    func cancel(_ error: Error = CancellationError()) {
      capture.cancel(); finish(.failure(error))
      if !submitted { capture.finish() }
    }
  }
  private var snapshotRequests: [UUID: SnapshotRequest] = [:]
  var snapshotSubmission: @MainActor (WKWebView, WKSnapshotConfiguration,
    @escaping @MainActor (AgentSnapshotImage?, Error?) -> Void) -> Void = { web, configuration, completion in
      web.takeSnapshot(with: configuration, completionHandler: completion)
    }
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
  var acceptedStateVersion: ContentFieldVersion? { observedStateVersion }
  private var checkpointSelection: ProgramSemanticSelection?
  private var checkpointWasCaptured = false
  private var checkpointFrozen = false
  var attentionPauseID: UUID? {
    didSet { setInteractionEnabled(attentionPauseID == nil) }
  }
  var hasFrozenFrame: Bool { checkpointFrozen && checkpointWasCaptured }
  var frozenSemanticSelection: ProgramSemanticSelection? { checkpointWasCaptured ? checkpointSelection : nil }
  private var checkpointTask: (id: UUID, task: Task<JSONValue, Error>)?
  private var retriesAfterStateBoundary = false
  var onChange: () -> Void = { }
  var onStateChange: (JSONValue) async throws -> ContentFieldVersion? = { _ in nil }
  var onStateCheckpoint: (JSONValue, ContentFieldVersion?) async throws -> ContentFieldVersion? = { _, _ in nil }
  var onStateDrained: () async -> Void = {}
  var requiresStateAcceptance = true
  var commitsEnabled = true
  var preparationPurpose: @MainActor () -> ScenePreparationPurpose = { .required }
  var onFocus: (Bool) -> Void = { _ in }
  var onLinkAdmission: (_ includingAcceptedContact: Bool) -> DocumentLinkAdmission? = { _ in nil }
  var onLink: (DocumentLinkActivation) -> Void = { _ in }
  var onMount: (WKWebView, CGSize) -> Void = { _, _ in }
  private(set) var viewportSize: CGSize
  private var viewportRevision: UInt64 = 0
  var blockWidth: Double { viewportSize.width }
  private var size: CGSize { viewportSize }

  func presents(_ value: JSONValue, version: ContentFieldVersion?) -> Bool {
    ready && failure == nil && presentedRevision == revision && appliedValue == value
      && (version.map { observedStateVersion?.includes($0) == true } ?? true)
  }

  init(documentID: UUID, program: DocumentProgramSource,
    value: JSONValue, stateVersion: ContentFieldVersion?, width: Double, height: Double,
    resources: SceneRenderResources, programStore: NotebookStore? = nil) {
    self.documentID = documentID; self.program = program
    self.value = value; appliedValue = value; observedStateVersion = stateVersion; self.resources = resources
    self.programStore = programStore
    viewportSize = .init(width: width, height: height)
    super.init()
  }

  private func setInteractionEnabled(_ enabled: Bool) {
    #if os(iOS)
      webView?.isUserInteractionEnabled = enabled
    #endif
  }

  func matches(_ program: DocumentProgramSource) -> Bool {
    self.program.id == program.id && self.program.path == program.path && sourceBasis == program.sourceBasis
      && self.program.programPackage == program.programPackage
  }

  /// Geometry belongs to TeX, not executable identity. WebKit keeps its heap,
  /// state and focused controls while the ordinary browser resize is delivered.
  func updateViewport(width: Double, height: Double) {
    guard width.isFinite, height.isFinite, width > 0, height > 0,
      abs(viewportSize.width - width) > 1 / 32 || abs(viewportSize.height - height) > 1 / 32 else { return }
    viewportSize = .init(width: width, height: height); viewportRevision &+= 1
    #if os(iOS)
    linkBridge?.publishInstallation(origin: nil, entryID: nil, host: nil, placement: nil)
    #endif
    cancelCaptures(); checkpointWasCaptured = false
    if let webView {
      webView.bounds.size = viewportSize
      webView.frame.size = viewportSize
      #if os(iOS)
      webView.setNeedsLayout(); webView.layoutIfNeeded()
      #else
      webView.needsLayout = true; webView.layoutSubtreeIfNeeded()
      #endif
    }
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
      requestedPriority = priority
      if let startID { resources.updatePendingWebPriority(startID, priority: priority) }
      return
    }
    let request = UUID(); startID = request; requestedPriority = priority
    observe("program_admission_requested")
    startTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let store = programStore else { throw SceneRenderError.snapshotPending("program_store") }
        let package = program.package
        let encoding = try await NotebookProgramStateEncoding.prepare(value, resources: resources, forHTML: true)
        guard !stopped, !Task.isCancelled, startID == request else { return }
        let acquired = try await resources.acquireDocumentProgramSurface(priority: requestedPriority ?? priority,
          documentID: documentID, blockID: program.id, purpose: preparationPurpose, requestID: request)
        guard !stopped, !Task.isCancelled, startID == request else { acquired.release(); return }
        lease = acquired; acquired.updatePriority(requestedPriority ?? priority)
        initialStateEncoding = encoding
        observe("program_admitted")
        let constructionBegan = ContinuousClock.now
        let content = WKUserContentController(); content.add(self, name: "documentProgram")
        #if os(iOS)
        let links = DocumentLinkActivationBridge(controller: content,
          admit: { [weak self] includingAcceptedContact in self?.admitLink(includingAcceptedContact: includingAcceptedContact) },
          deliver: { [weak self] activation, admission in
            self?.deliverLink(activation, admission: admission)
          }, borrow: { [weak self] in try? self?.lease?.borrow() })
        #endif
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent(); configuration.userContentController = content
        configuration.setURLSchemeHandler(programAssets, forURLScheme: NotebookProgramAssets.scheme)
        let web = WKWebView(frame: .init(origin: .zero, size: size), configuration: configuration)
        #if os(iOS)
        web.accessibilityIdentifier = "document-program-" + program.id
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.bounces = false; web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.pinchGestureRecognizer?.isEnabled = false; web.scrollView.panGestureRecognizer.isEnabled = false
        #else
        web.setAccessibilityIdentifier("document-program-" + program.id)
        web.setValue(false, forKey: "drawsBackground")
        #endif
        web.navigationDelegate = self; webView = web
        #if os(iOS)
        linkBridge = links; links.attach(web)
        #endif
        session = .init(resources: resources, web: web, lease: acquired, controller: "documentProgram",
          isCurrent: { [weak self, weak web] in
            guard let self, let web else { return false }
            return !stopped && webView === web
          })
        onMount(web, size)
        observe("program_mounted")
        // Only native construction holds the shared short allowance. Source,
        // package and initial state were accepted before entering this section.
        acquired.finishConstruction(elapsed: constructionBegan.duration(to: .now))
        let url = try programAssets.register(store: store, package: package) { try html(package: package, resourceOrigin: $0) }
        packageURL = url; initialNavigationPending = true
        web.load(URLRequest(url: url))
        readinessDeadline = Task { @MainActor [weak self, weak web] in
          do { try await Task.sleep(for: .seconds(8)) } catch { return }
          guard let self, self.webView === web, !ready, !stopped, failure == nil else { return }
          fail(SceneRenderError.snapshotPending("document_program_readiness"))
        }
        if startID == request { startID = nil; startTask = nil }
      } catch {
        guard startID == request else { return }
        startID = nil; startTask = nil
        if error as? SceneWebAdmissionError == .backgroundQueueFull {
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
    if let checkpointTask { _ = try? await checkpointTask.task.value }
    await session?.awaitCheckpoint()
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
    let expectedRevision = revision, basis = observedStateVersion
    let encoded = try await NotebookProgramStateEncoding.prepare(next, resources: resources)
    let accepted = try await encoded.send(controller: "documentProgram", revision: String(expectedRevision), in: webView)
    // A later accepted native commit wins even if WebKit's reply to the older
    // state application arrives after that commit's message.
    if accepted, !stopped, self.webView === webView, revision == expectedRevision,
      observedStateVersion == basis {
      session?.forgetCompletedCheckpoint()
      checkpointSelection = nil; checkpointWasCaptured = false; checkpointFrozen = false; attentionPauseID = nil
      value = next; appliedValue = next; observedStateVersion = stateVersion
      presentedRevision = revision; onChange()
    }
  }

  /// Suspends new commits before reading the exact explicit state. The caller
  /// must confirm persistence and window identity before allowing retirement.
  func checkpoint() async throws -> JSONValue {
    try await checkpointBoundary().value
  }

  private func performCheckpoint() async throws -> JSONValue {
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    if stateTransferFailure { try await stateTransfer?.drain() }
    if !ready {
      try await finishAcceptedBeforeReady()
      if failure != nil { finishFailedSurface(); return value }
      if !ready { return value }
    }
    let saved: JSONValue
    do { saved = try await persistCheckpoint() }
    catch {
      guard failure != nil, !stateTransferFailure else { throw error }
      try await finishAcceptedBeforeReady()
      finishFailedSurface()
      return value
    }
    if stateTransferFailure { throw failure ?? SceneRenderError.snapshotPending("program_state_transfer") }
    if failure != nil {
      // An author can fail while its captured checkpoint is being saved. Its
      // successful receipt still finishes the one retirement/Retry boundary.
      try await finishAcceptedBeforeReady()
      finishFailedSurface()
    }
    return saved
  }

  /// Navigation, an author failure and Retry join one retirement boundary.
  /// ProgramSession still owns the frozen state and its accepted writer.
  @discardableResult
  private func checkpointBoundary() -> Task<JSONValue, Error> {
    if let checkpointTask { return checkpointTask.task }
    let id = UUID()
    let task = Task { @MainActor [self] in
      defer { if checkpointTask?.id == id { checkpointTask = nil } }
      return try await performCheckpoint()
    }
    checkpointTask = (id, task)
    return task
  }

  private func finishAcceptedBeforeReady() async throws {
    let starting = startID
    startTask?.cancel()
    if let startTask { await startTask.value }
    if startID == starting { startTask = nil; startID = nil }
    if let session, !(try await session.finishAccepted()) { releaseSurface() }
  }

  private func finishFailedSurface() {
    releaseSurface()
    if retriesAfterStateBoundary, !stopped {
      retriesAfterStateBoundary = false
      failure = nil; revision = 0; presentedRevision = nil
      start(priority: .input)
    }
    onChange()
  }

  private func persistCheckpoint() async throws -> JSONValue {
    guard ready, !focused, let session else { throw CancellationError() }
    let checkpoint = try await session.checkpoint(prepare: { [self] in
      .init(version: observedStateVersion, revision: revision)
    }, basisAfterFreeze: { [self] _ in
      // The document journal acknowledges the final author commit during the
      // transport drain. Bind the frozen value to that exact accepted revision.
      .init(version: observedStateVersion, revision: revision)
    }, accepts: { [self] before, accepted in
      revision == before.revision && (observedStateVersion == before.version || observedStateVersion == accepted?.version)
    }, persist: { [self] next, basis, _ in
      let accepted = try await onStateCheckpoint(next, basis.version)
      guard accepted != nil || !requiresStateAcceptance else { throw NotebookProgramCheckpointError.superseded }
      return .init(version: accepted ?? basis.version, revision: basis.revision)
    }, didAccept: { [self] checkpoint in
      checkpointSelection = checkpoint.selection; checkpointWasCaptured = false; checkpointFrozen = true
      value = checkpoint.value; appliedValue = checkpoint.value; observedStateVersion = checkpoint.basis.version
    })
    return checkpoint.value
  }

  @discardableResult
  func resume() async -> Bool {
    guard webView != nil, let session else {
      guard !stopped else { return false }
      start(priority: requestedPriority ?? .liveProgram)
      return true
    }
    do { try await session.resume(commitsEnabled: commitsEnabled) }
    catch { setInteractionEnabled(false); onChange(); return false }
    checkpointSelection = nil; checkpointWasCaptured = false; checkpointFrozen = false; attentionPauseID = nil
    setInteractionEnabled(true)
    onChange(); return true
  }

  func blur() async {
    guard let webView else { return }
    _ = try? await NotebookProgramBridge.request("blur", script: "document.activeElement?.blur();return true;", in: webView)
  }

  func capture(sourceOffset: Double, height: Double, pixelWidth: Int,
    reservation granted: RasterReservation? = nil) async throws -> RasterLease {
    let frame = try await captureFrame(sourceOffset: sourceOffset, height: height, pixelWidth: pixelWidth,
      destination: .cache, reservation: granted)
    guard case .raster(let raster) = frame else { preconditionFailure("Cached capture returned a current cut") }
    return raster
  }

  /// An accepted turn owns temporary pixels through its final GPU borrow. It
  /// neither publishes a passive cache entry nor changes checkpoint ownership.
  func captureCurrentCut(sourceOffset: Double, height: Double, pixelWidth: Int) async throws -> SceneRasterCut {
    let frame = try await captureFrame(sourceOffset: sourceOffset, height: height, pixelWidth: pixelWidth,
      destination: .acceptedTurn)
    guard case .cut(let cut) = frame else { preconditionFailure("Current cut returned a cached raster") }
    return cut
  }

  private func captureFrame(sourceOffset: Double, height: Double, pixelWidth: Int,
    destination: CaptureDestination, reservation granted: RasterReservation? = nil) async throws -> CapturedFrame {
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    guard captureQueue.count < 4 else { throw SceneRenderError.resourceLimit }
    let operation = UUID(); captureQueue.append(operation)
    let task = Task { @MainActor [weak self] () throws -> CapturedFrame in
      guard let self else { throw CancellationError() }
      try await waitForCaptureTurn(operation)
      try Task.checkCancellation()
      guard ready, !stopped, let web = webView, let lease else {
        throw SceneRenderError.snapshotPending("document_program")
      }
      let expectedRevision = revision, expectedViewport = viewportRevision
      let rect = CGRect(x: 0, y: sourceOffset, width: size.width, height: height)
      guard size.width > 0, height > 0, CGRect(origin: .zero, size: size).contains(rect) else {
        throw DocumentSessionError.invalidLayout
      }
      #if os(iOS)
      let pixelHeight = Int(ceil(Double(pixelWidth) * height / size.width))
      let reservation = granted ?? (destination == .acceptedTurn
        ? resources.reserveCurrentWebCut(pixelSize: .init(width: pixelWidth, height: pixelHeight))
        : resources.reserveRaster(pixelWidth: pixelWidth, pixelHeight: pixelHeight, bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel))
      guard let reservation,
        resources.ownsRasterReservation(reservation, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
        throw SceneRenderError.resourceLimit
      }
      let configuration = WKSnapshotConfiguration(); configuration.rect = rect; configuration.afterScreenUpdates = true
      configuration.snapshotWidth = NSNumber(value: Double(pixelWidth) / (web.window?.screen.scale ?? 2))
      #else
      guard let geometry = MacCaptureGeometry(rect: rect, pixelWidth: pixelWidth,
        backingScale: Double(web.window?.backingScaleFactor ?? 2)),
        let bytes = SceneRenderResources.estimatedRasterBytes(pixelWidth: geometry.admissionWidth,
          pixelHeight: geometry.admissionHeight, bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel)
      else { throw SceneRenderError.resourceLimit }
      let reservation = granted ?? resources.reserveRaster(pixelWidth: geometry.admissionWidth,
        pixelHeight: geometry.admissionHeight, bytesPerPixel: SceneRenderResources.webSnapshotBytesPerPixel,
        priority: destination == .acceptedTurn ? .input : .passive)
      guard let reservation, reservation.byteCount >= bytes,
        resources.ownsRasterReservation(reservation, pixelWidth: geometry.admissionWidth,
          pixelHeight: geometry.admissionHeight) else { throw SceneRenderError.resourceLimit }
      let configuration = WKSnapshotConfiguration(); configuration.rect = geometry.snapshotRect
      configuration.snapshotWidth = NSNumber(value: geometry.snapshotWidth); configuration.afterScreenUpdates = true
      #endif
      #if os(iOS)
      let image = try await takeSnapshot(web, configuration: configuration,
        reservation: reservation, lease: lease, operation: operation)
      #else
      let normalized = try await takeNormalizedSnapshot(web, configuration: configuration, geometry: geometry,
        reservation: reservation, lease: lease, operation: operation)
      #endif
      // The callback transferred these bytes to this reader. A cancelled or
      // timed-out reader never releases a still-submitted WebKit backing.
      var transferred = false
      defer { if !transferred { reservation.release() } }
      try Task.checkCancellation()
      guard !stopped, self.webView === web, revision == expectedRevision, viewportRevision == expectedViewport else { throw CancellationError() }
      #if os(iOS)
      guard let cg = image.cgImage else { throw CancellationError() }
      let normalized = AgentSnapshotImage(cgImage: cg, scale: Double(cg.width) / size.width, orientation: .up)
      #endif
      // An offscreen executor is semantically ready before it owns pixels.
      // This callback certifies its current revision after native screen updates.
      presentedRevision = expectedRevision
      let source = SceneRasterSource.document(id: documentID, token: "program:\(program.id):\(id):\(operation)")
      if destination == .acceptedTurn {
        guard let cut = resources.currentWebCut(normalized, for: source, reservation: reservation)
        else { throw SceneRenderError.resourceLimit }
        transferred = true
        return .cut(cut)
      }
      guard let raster = resources.storeAndRetain(normalized, for: source, reservation: reservation,
        semanticSelection: checkpointSelection?.mapped(from: .init(x: 0, y: 0, width: size.width, height: size.height),
          into: .init(x: 0, y: sourceOffset, width: size.width, height: height))) else {
        throw SceneRenderError.resourceLimit
      }
      if checkpointFrozen { checkpointWasCaptured = true }
      return .raster(raster)
    }
    captureReaders[operation] = task
    defer { finishCaptureReader(operation) }
    return try await withTaskCancellationHandler {
      let frame = try await task.value
      try Task.checkCancellation()
      return frame
    } onCancel: { task.cancel() }
  }

  #if os(macOS)
  /// AppKit WebKit truncates output points before applying device scale, then
  /// paints uniformly at the larger axis scale. A short output can therefore
  /// clip an authored edge. Only this capture rectangle gains transparent
  /// margin; the live viewport and the canonical continuation remain unchanged.
  private struct MacCaptureGeometry {
    let canonical: CGRect
    let snapshotRect: CGRect
    let snapshotWidth: Double
    let nativePixels: CGSize
    let outputPixels: CGSize
    let backingScale: Double
    let admissionWidth: Int
    let admissionHeight: Int

    init?(rect: CGRect, pixelWidth: Int, backingScale: Double) {
      guard pixelWidth > 0, rect.width > 0, rect.height > 0,
        [rect.minX, rect.minY, rect.maxX, rect.maxY, backingScale].allSatisfy(\.isFinite),
        backingScale >= 1 else { return nil }
      let scale = Double(pixelWidth) / rect.width
      func makeGrid(_ capture: CGRect) -> (points: Double, pixels: CGSize)? {
        let points = ceil(capture.width * scale / backingScale)
        let height = floor(points / capture.width * capture.height)
        guard points > 0, height >= 0,
          max(points, height) * backingScale < Double(Int32.max) else { return nil }
        // Matches WK's IntSize(pointWidth, pointHeight).scale(deviceScale).
        return (points, .init(width: Double(Int(Float(points) * Float(backingScale))),
          height: Double(Int(Float(height) * Float(backingScale)))))
      }
      var capture = rect.integral
      guard var grid = makeGrid(capture) else { return nil }
      if !Self.covers(rect, in: capture, pixels: grid.pixels) {
        let margin = (backingScale + 1) / scale
        capture.size = .init(width: ceil(rect.maxX + margin) - capture.minX,
          height: ceil(rect.maxY + margin) - capture.minY)
        guard let padded = makeGrid(capture) else { return nil }
        grid = padded
      }
      guard Self.covers(rect, in: capture, pixels: grid.pixels) else { return nil }
      canonical = rect; snapshotRect = capture; snapshotWidth = grid.points
      nativePixels = grid.pixels; self.backingScale = backingScale
      outputPixels = .init(width: Double(pixelWidth), height: ceil(rect.height * scale))
      // NSImage may round its representation at the device grid once more.
      // Admit the two real backings before WK; this never changes resource caps.
      admissionWidth = Int(max(outputPixels.width, ceil(snapshotWidth * backingScale)))
      admissionHeight = Int(max(outputPixels.height,
        ceil(snapshotWidth / snapshotRect.width * snapshotRect.height * backingScale)))
    }

    private static func paintScale(_ rect: CGRect, _ pixels: CGSize) -> Double {
      Double(max(Float(pixels.width) / Float(rect.width), Float(pixels.height) / Float(rect.height)))
    }
    private static func covers(_ canonical: CGRect, in capture: CGRect, pixels: CGSize) -> Bool {
      guard pixels.width > 0, pixels.height > 0 else { return false }
      let scale = paintScale(capture, pixels)
      return CGRect(origin: .zero, size: pixels).contains(CGRect(
        x: (canonical.minX - capture.minX) * scale, y: (canonical.minY - capture.minY) * scale,
        width: canonical.width * scale, height: canonical.height * scale))
    }

    func region(in pixels: CGImage) -> CGRect? {
      guard abs(Double(pixels.width) - nativePixels.width) <= ceil(backingScale),
        abs(Double(pixels.height) - nativePixels.height) <= ceil(backingScale) else { return nil }
      let scale = Self.paintScale(snapshotRect, nativePixels)
      let sx = scale * Double(pixels.width) / nativePixels.width
      let sy = scale * Double(pixels.height) / nativePixels.height
      return .init(x: (canonical.minX - snapshotRect.minX) * sx,
        y: (canonical.minY - snapshotRect.minY) * sy, width: canonical.width * sx, height: canonical.height * sy)
    }
  }

  private func takeNormalizedSnapshot(_ web: WKWebView, configuration: WKSnapshotConfiguration,
    geometry: MacCaptureGeometry, reservation: RasterReservation, lease: WebSurfaceLease,
    operation: UUID) async throws -> NSImage {
    func readPixels() async throws -> CGImage {
      let image = try await takeSnapshot(web, configuration: configuration,
        reservation: reservation, lease: lease, operation: operation)
      guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        reservation.release(); throw SceneRenderError.resourceLimit
      }
      return pixels
    }
    // Release the NSImage capture before allocating the canonical cut. Then
    // release its CG backing before install/currentWebCut can retain GPU pixels.
    let pixels = try await readPixels()
    do {
      try Task.checkCancellation()
      let bytes = pixels.bytesPerRow.multipliedReportingOverflow(by: pixels.height)
      guard !bytes.overflow, bytes.partialValue <= reservation.byteCount / 2,
        pixels.bitsPerPixel <= SceneRenderResources.webSnapshotBytesPerPixel * 8,
        let region = geometry.region(in: pixels),
        let normalized = NSImage.normalizedSnapshot(pixels, region: region,
          pixelSize: geometry.outputPixels, logicalSize: geometry.canonical.size)
      else { throw SceneRenderError.resourceLimit }
      return normalized
    } catch { reservation.release(); throw error }
  }
  #endif

  private func waitForCaptureTurn(_ operation: UUID) async throws {
    try Task.checkCancellation()
    guard !stopped, captureQueue.contains(operation) else { throw CancellationError() }
    if captureQueue.first == operation { return }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        guard !Task.isCancelled, !stopped else { continuation.resume(throwing: CancellationError()); return }
        captureWaiters[operation] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.captureWaiters.removeValue(forKey: operation)?.resume(throwing: CancellationError())
      }
    }
  }

  private func finishCaptureReader(_ operation: UUID) {
    captureReaders[operation] = nil
    captureWaiters.removeValue(forKey: operation)?.resume(throwing: CancellationError())
    let wasFirst = captureQueue.first == operation
    captureQueue.removeAll { $0 == operation }
    // Cancelling a queued reader removes only that reader. Its successor still
    // waits for the actual first operation, rather than bypassing its snapshot.
    if wasFirst, let next = captureQueue.first {
      captureWaiters.removeValue(forKey: next)?.resume()
    }
  }

  private func takeSnapshot(_ web: WKWebView, configuration: WKSnapshotConfiguration,
    reservation: RasterReservation, lease: WebSurfaceLease, operation: UUID) async throws -> AgentSnapshotImage {
    // A cancelled reader leaves its submitted native request alive. Repeated
    // cancelled turns must respect that separate, bounded physical backlog.
    guard snapshotRequests.count < 4 else {
      reservation.release(); throw SceneRenderError.resourceLimit
    }
    let request = SnapshotRequest(reservation: reservation, lease: lease)
    snapshotRequests[operation] = request
    defer { if !request.submitted { snapshotRequests[operation] = nil } }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        request.continuation = continuation
        guard !Task.isCancelled, !stopped else { request.cancel(); return }
        request.deadline = Task { @MainActor [weak request] in
          do { try await Task.sleep(for: .seconds(8)) } catch { return }
          request?.cancel(SceneRenderError.snapshotPending("document_program_snapshot_deadline"))
        }
        request.submitted = true
        snapshotSubmission(web, configuration) { [weak self, request] image, error in
          defer { request.capture.finish(); self?.snapshotRequests[operation] = nil }
          guard !request.capture.isCancelled else { request.finish(.failure(CancellationError())); return }
          if let error { request.finish(.failure(error)); return }
          guard let image else {
            request.finish(.failure(SceneRenderError.snapshotPending("document_program_snapshot_empty"))); return
          }
          // MainActor resumes the reader after this callback. Transfer the
          // grant before ending the physical borrow; its reader validates the
          // exact runtime, state revision and viewport before publication.
          guard request.continuation != nil else { return }
          request.capture.transferReservationToCut()
          request.finish(.success(image))
        }
      }
    } onCancel: {
      Task { @MainActor in request.cancel() }
    }
  }

  private func cancelCaptures() {
    for reader in captureReaders.values { reader.cancel() }
    let waiting = captureWaiters; captureWaiters.removeAll()
    for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }
    for request in snapshotRequests.values { request.cancel() }
  }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard !stopped, message.webView === webView, let body = message.body as? [String: Any], body["runtimeID"] as? String == id.uuidString else { return }
    switch body["kind"] as? String {
    case "ready":
      guard failure == nil else { return }
      observe("program_ready")
      readinessDeadline?.cancel(); readinessDeadline = nil
      ready = true; initialStateEncoding = nil
      #if os(iOS)
      if let value = body["revision"] as? String, UInt64(value) == revision { presentedRevision = revision }
      #endif
      onChange()
    #if os(iOS)
    case "presented":
      if let value = body["revision"] as? String, let presented = UInt64(value) {
        presentedRevision = presented; onChange()
      }
    #endif
    case "stateCredit":
      guard let bytes = body["bytes"] as? Int, let web = self.webView else { return }
      stateTransfer?.requestCredit(bytes) { NotebookProgramBridge.grantStateCredit($0, controller: "documentProgram", in: web) }
    case "state":
      guard let data = try? JSONSerialization.data(withJSONObject: body["snapshot"] ?? [:]),
        let descriptor = try? JSONDecoder().decode(NotebookProgramStateTransfer.Snapshot.self, from: data),
        let web = self.webView, let stateTransfer, let borrow = try? lease?.borrow() else { return }
      let writer = onStateChange, drained = onStateDrained
      stateTransfer.receive(descriptor, retaining: borrow,
        read: { try await NotebookProgramBridge.readState($0, offset: $1, controller: "documentProgram", in: web) },
        acknowledge: { try await NotebookProgramBridge.acknowledgeState($0, controller: "documentProgram", in: web) },
        accept: { [self] next, sequence in
          value = next; appliedValue = next; revision = sequence
          if let accepted = try await writer(next) { observedStateVersion = accepted }
          else if requiresStateAcceptance { throw NotebookProgramCheckpointError.superseded }
          if !stopped { onChange() }
          await drained()
        }, onFailure: { [weak self] error in
          guard let self, !stopped, self.stateTransfer?.hasFailure == true else { return }
          // A transport deadline is not an author failure. Keep this executor
          // and every accepted revision for explicit Retry, without reloading.
          stateTransferFailure = true; failure = error
          setInteractionEnabled(false); onChange()
        })
    case "focus": focused = body["value"] as? Bool == true; onFocus(focused)
    case "link":
      // Scripted navigation keeps its internal document route. A page-world
      // boolean/runtime ID cannot confer the isolated listener's authority.
      guard message.frameInfo.isMainFrame, let href = body["href"] as? String, href.utf8.count <= 4_096,
        let admission = admitLink(includingAcceptedContact: false), let layout = admission.origin.source.layout else { return }
      let destination = layout.destination(for: href)
      if case .external = destination { return }
      deliverLink(.init(origin: admission.origin, destination: destination), admission: admission)
    case "failure": fail(SceneRenderError.snapshotPending(body["message"] as? String ?? "document_program"))
    default: break
    }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard self.webView === webView else { return }
    ready = false; focused = false; revision = 0; presentedRevision = nil; onFocus(false)
    releaseSurface(); failure = nil; start(priority: .liveProgram); onChange()
  }

  private func admitLink(includingAcceptedContact: Bool) -> DocumentLinkAdmission? {
    guard !stopped, ready, failure == nil, attentionPauseID == nil, linkDelivery == nil,
      let web = webView, web.window?.isKeyWindow == true,
      let admission = onLinkAdmission(includingAcceptedContact), admission.isCurrent() else { return nil }
    let viewport = viewportRevision
    return .init(origin: admission.origin, admittedAt: admission.admittedAt, isCurrent: { [weak self, weak web] in
      guard let self, let web, !stopped, ready, failure == nil, webView === web,
        viewportRevision == viewport, web.window?.isKeyWindow == true else { return false }
      return admission.isCurrent()
    })
  }

  #if os(iOS)
  func beginNativeLinkContact() { linkBridge?.beginNativeContact() }

  func publishLinkInstallation(origin: DocumentLinkOrigin?, entryID: UUID?, host: DocumentProgramOverlayHost?, placement: DocumentProgramPlacement?) {
    linkBridge?.publishInstallation(origin: origin, entryID: entryID, host: host, placement: placement)
  }
  #endif

  private func deliverLink(_ activation: DocumentLinkActivation, admission: DocumentLinkAdmission) {
    guard linkDelivery == nil, let web = webView, let transfer = stateTransfer else { return }
    let id = UUID()
    let task = Task { @MainActor [weak self, weak web] in
      guard let self else { return }
      defer { if linkDelivery?.id == id { linkDelivery = nil } }
      do {
        // The terminal isolated message follows this click's synchronous state
        // descriptors. Navigation cannot retire their actual accepted writer.
        try await transfer.drain()
        guard !Task.isCancelled, let web, !stopped, webView === web, stateTransfer === transfer,
          admission.admittedAt.duration(to: .now) <= .seconds(10), admission.isCurrent() else { return }
        onLink(activation)
      } catch { /* The existing state failure/Retry owner retains accepted work. */ }
    }
    linkDelivery = (id, task)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard self.webView === webView else { return }
    observe("program_navigation_finished")
  }

  private func observe(_ stage: String) {
    guard NotebookNavigationObservation.enabled else { return }
    let web = webView, window = web?.window
    #if os(iOS)
    let intersectsWindow = if let web, let window { !web.convert(web.bounds, to: window).intersection(window.bounds).isEmpty } else { false }
    #else
    let intersectsWindow = if let web, let content = window?.contentView {
      !web.convert(web.bounds, to: content).intersection(content.bounds).isEmpty
    } else { false }
    #endif
    NotebookNavigationObservation.recordDocument(stage, ownerID: id, documentID: documentID, fields: [
      "blockID": .string(program.id), "webID": web.map { .string(String(describing: ObjectIdentifier($0))) } ?? .null,
      "hasWindow": .bool(window != nil), "intersectsWindow": .bool(intersectsWindow),
      "activeWebSurfaces": .number(Double(resources.activeWebSurfaceCount)),
      "pendingWebRequests": .number(Double(resources.pendingWebRequestCount))])
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
    if stateTransferFailure, let stateTransfer {
      stateTransfer.retry()
      Task { @MainActor [weak self] in
        do {
          try await stateTransfer.drain()
          guard let self, self.stateTransfer === stateTransfer, !stopped else { return }
          stateTransferFailure = false; failure = nil
          setInteractionEnabled(attentionPauseID == nil); onChange()
        } catch { /* The same failed stage remains visible and retains its heap. */ }
      }
      return
    }
    retriesAfterStateBoundary = true
    checkpointBoundary()
  }

  func stop() { stopped = true; checkpointTask?.task.cancel(); checkpointTask = nil; startTask?.cancel(); startTask = nil; startID = nil; releaseSurface() }
  private func fail(_ error: Error) {
    failure = error; ready = false; focused = false; presentedRevision = nil
    // Preserve the handler and heap through the accepted-state boundary,
    // including a descriptor posted just before this error. The broken slot
    // is released after durability; explicit Retry then owns a fresh executor.
    checkpointBoundary()
    onFocus(false); onChange()
  }
  private func releaseSurface() {
    cancelCaptures()
    #if os(iOS)
    linkBridge?.invalidate(); linkBridge = nil
    #endif
    linkDelivery?.task.cancel(); linkDelivery = nil
    session?.invalidate(); session = nil
    stateTransferFailure = false
    checkpointSelection = nil; checkpointWasCaptured = false; checkpointFrozen = false; attentionPauseID = nil
    programAssets.revokeAll(); packageURL = nil
    readinessDeadline?.cancel(); readinessDeadline = nil
    initialNavigationPending = false
    webView?.evaluateJavaScript("void documentProgram.dispose().catch(()=>{})", completionHandler: nil)
    webView?.stopLoading(); webView?.navigationDelegate = nil
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "documentProgram")
    if let webView {
      #if os(iOS)
      var ancestor = webView.superview
      while let view = ancestor {
        if let overlay = view as? DocumentProgramOverlayHost { overlay.removeProgram(webView); break }
        ancestor = view.superview
      }
      #endif
      webView.removeFromSuperview()
    }
    webView = nil; initialStateEncoding = nil; lease?.release(); lease = nil
  }
  isolated deinit { checkpointTask?.task.cancel(); startTask?.cancel(); releaseSurface() }

  private func html(package: NotebookProgramPackage, resourceOrigin: URL) throws -> NotebookProgramAssets.Document {
    func encoded<T: Encodable>(_ value: T) throws -> String {
      String(decoding: try JSONEncoder().encode(value), as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }
    let policy = NotebookProgramAssets.policy(origin: resourceOrigin)
    let style = NotebookProgramAssets.style(package, origin: resourceOrigin)
    let entry = NotebookProgramAssets.script(package, origin: resourceOrigin)
    #if os(iOS)
    let presentationBarrier = "()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))"
    #else
    // Offscreen Mac windows may never receive display animation frames.
    // Authored readiness still runs; takeSnapshot(afterScreenUpdates: true)
    // supplies the physical pixel boundary when the requested image is captured.
    let presentationBarrier = "()=>Promise.resolve()"
    #endif
    return .init(before: """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,minimum-scale=1,maximum-scale=1,user-scalable=no">
    <meta http-equiv="Content-Security-Policy" content="\(policy)">
    <style>html,body{margin:0;min-height:100%;background:transparent;color:#171713;font-family:-apple-system,BlinkMacSystemFont,sans-serif}*{box-sizing:border-box}</style>\(style)<script>(()=>{
      \(NotebookProgramBridge.script)
      const runtimeID=\(try encoded(id.uuidString));
      const post=(kind,extra={})=>webkit.messageHandlers.documentProgram.postMessage({runtimeID,kind,...extra});
      const painted=\(presentationBarrier);
      const present=async expected=>{await painted();if(documentProgram.revision===expected)post('presented',{revision:expected})};
      const focus=()=>post('focus',{value:!!document.activeElement?.matches('input,textarea,[contenteditable=true]')});
      addEventListener('focusin',focus);addEventListener('focusout',()=>queueMicrotask(focus));
      addEventListener('click',event=>{const link=event.target.closest('a[href]');if(link&&!event.isTrusted)post('link',{href:link.getAttribute('href')})});
      addEventListener('error',event=>post('failure',{message:String(event.error || event.message)}));
      addEventListener('unhandledrejection',event=>post('failure',{message:String(event.reason)}));
      window.documentProgram=createNotebookProgram({state:\(initialStateEncoding!.htmlJSON),paint:painted,
        stateTransport:{enabled:\(commitsEnabled),credit:\(stateTransfer?.initialCredit ?? 0),
          onSnapshot:snapshot=>{post('state',{snapshot});present(snapshot.revision)},
          requestCredit:bytes=>post('stateCredit',{bytes})},
        report:(kind,message)=>{if(!['program_lifecycle_error','program_semantic_unavailable','program_state_backpressure'].includes(kind))post('failure',{message:kind+': '+message})}});
      window.notebook=documentProgram.api;
      addEventListener('load',async()=>{try{
        await document.fonts.ready;
        await Promise.all([...document.images].map(image=>image.decode()));
        const receipt=await documentProgram.start({requiresReady:true});
        post('ready',receipt);
      }catch(error){post('failure',{message:String(error)})}});
    })()</script></head><body>
    """, after: "\(entry)</body></html>")
  }
}
