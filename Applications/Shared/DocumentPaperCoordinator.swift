#if os(iOS)
import Foundation
import NotebookCore
import NotebookTypesetter
import UIKit

/// One physical print cut. Preparation borrows the document's immutable PDF;
/// installation publishes its pixels and native interaction metadata together.
@MainActor
final class DocumentPaperCoordinator {
  struct Payload {
    let source: DocumentSourceSnapshot
    let state: DocumentStateSnapshot
    let pageIndex: Int
    let runtimeID: UUID
    var documentID: UUID { source.document.id }
    var renderToken: String {
      DocumentSnapshotCache.paperToken(sourceRevision: source.stamp.revision, pageIndex: pageIndex)
    }
  }
  let view = DocumentPaperView()
  private let interaction = DocumentPaperInteractionView()
  private let resources: SceneRenderResources
  private let renderSession: DocumentRenderSession
  private let id = UUID()
  private var generation: UInt64 = 0
  private weak var host: DocumentPageHost?
  private var prepared: DocumentPreparedPage?
  private var preparation: Task<Void, Never>?
  private var pixelWidth = 1024
  private var priority = NotebookTypesetter.Priority.current
  private var purpose: @MainActor () -> ScenePreparationPurpose = { .required }
  private var requestedInput = false
  private var onPageLayout: (DocumentPageLayout) -> Void = { _ in }
  private var onPreparationFailure: (Error) -> Void = { _ in }
  private var onLinkActivation: (DocumentLinkActivation) -> Void = { _ in }
  private var reclamationOwner: UUID?
  private var idleReclamation: (@MainActor () -> Void)?
  private struct Waiter {
    let generation: UInt64
    let token: String
    let continuation: CheckedContinuation<Void, Error>
  }
  private var waiters: [UUID: Waiter] = [:]
  var pendingPresentationRequestCount: Int { waiters.count }
  private(set) var payload: Payload?
  private(set) var acquisitionError: Error?
  private(set) var isInvalidated = false
  private(set) var pagePreparationTrace: DocumentPagePreparationTrace?
  var programStore: NotebookStore?
  var preservesFallback = false
  var onPaperReady: () -> Void = { }
  var onPresentationChange: () -> Void = { }
  var onLinkAdmission: (DocumentLinkOrigin) -> DocumentLinkAdmission? = { _ in nil }
  var isCurrentPresentation: () -> Bool = { false }

  init(resources: SceneRenderResources, renderSession: DocumentRenderSession) {
    self.resources = resources; self.renderSession = renderSession
    interaction.isReadablePresentation = { [weak self] in
      guard let self, !isInvalidated, isCurrentPresentation(), let host,
        host.ownsPaper(view), !host.hasSnapshot, host.hasCanonicalPaperProjection,
        interaction.superview === host, view.raster != nil,
        host.window?.isKeyWindow == true, UIApplication.shared.applicationState == .active else { return false }
      return SceneSourceVisibility.isVisible(view)
    }
    reclamationOwner = resources.registerReclamationOwner { [weak self] in
      guard let self, let reclaim = idleReclamation, !requestedInput,
        host?.hasActiveContact != true, let raster = view.raster else { return [] }
      return [.init(id: id, bytes: raster.accountedByteCount, rasterCount: 0, value: .unused,
        distance: 0, restorationMilliseconds: 1, release: { reclaim(); return nil })]
    }
  }

  var paperIsReady: Bool {
    guard !isInvalidated, let payload, let prepared, let raster = view.raster else { return false }
    return raster.sourceKey == payload.source.message.key
      && raster.page.pageIndex == min(max(0, payload.pageIndex), max(0, (payload.source.layout?.pageCount ?? 1) - 1))
      && prepared.printed.artifact === raster.page.artifact
  }
  var hasCanonicalPixels: Bool { paperIsReady && interaction.generation == generation }
  var installedPaper: DocumentPaperRaster? { paperIsReady ? view.raster : nil }
  var retainsPreviousPrint: Bool { view.raster != nil && !paperIsReady }
  var isMounted: Bool { host?.ownsPaper(view) == true }

  func update(document: DocumentDocument, state: DocumentStateJournal, selectedPageIndex: Int,
    onPageLayout: @escaping (DocumentPageLayout) -> Void, paperPreparationPixelWidth: Int = 1024,
    onPreparationFailure: @escaping (Error) -> Void, onLinkActivation: @escaping (DocumentLinkActivation) -> Void,
    preparationRequestID: UUID?) {
    guard !isInvalidated else { return }
    self.onPageLayout = onPageLayout; self.onPreparationFailure = onPreparationFailure
    self.onLinkActivation = onLinkActivation
    let source = renderSession.source(document, store: programStore), width = max(1, paperPreparationPixelWidth)
    let changed = payload?.source !== source || payload?.pageIndex != selectedPageIndex || pixelWidth != width
    if changed {
      preparation?.cancel(); preparation = nil
      payload?.source.releasePage(hostID: id, in: nil, retiring: true)
      generation &+= 1; acquisitionError = nil; prepared = nil; pixelWidth = width
      payload = .init(source: source, state: renderSession.state(records: []),
        pageIndex: selectedPageIndex, runtimeID: id)
      interaction.admitsInput = false
      resolveWaiters()
    }
    source.retainPage(selectedPageIndex, hostID: id)
    if let requestID = preparationRequestID, let payload,
      pagePreparationTrace?.identity.requestID != requestID || changed {
      pagePreparationTrace = .init(identity: .init(requestID: requestID, attemptID: UUID(),
        coordinatorID: id, documentID: document.id, generation: String(generation), runtimeID: id,
        sourceKey: source.message.key, stateKey: payload.state.message.key,
        token: DocumentSnapshotCache.token(document: document, state: state, pageIndex: selectedPageIndex),
        pageIndex: selectedPageIndex, configuredAt: ProcessInfo.processInfo.systemUptime))
      pagePreparationTrace?.mark(.payloadConfiguredAt)
      if hasCanonicalPixels { pagePreparationTrace?.mark(.canonicalReusedAt) }
    }
    refreshInput()
    if changed || !paperIsReady { prepare() }
  }

  func mount(in host: DocumentPageHost, physicalSize: CGSize, isInteractive: Bool, priority: WebPriority,
    purpose: @escaping @MainActor () -> ScenePreparationPurpose = { .required }) {
    guard !isInvalidated else { return }
    if self.host !== host {
      self.host?.removePaperInteraction(ownedBy: interaction)
      self.host?.removePaper(ownedBy: view)
    }
    self.host = host; requestedInput = isInteractive; self.purpose = purpose
    self.priority = priority == .currentPage || priority == .input ? .current : .anticipated
    payload?.source.promotePreparation(to: self.priority)
    host.configure(size: physicalSize, interactive: false)
    pagePreparationTrace?.mark(.mountAt)
    if let prepared, paperIsReady { install(prepared) }
    else {
      // A last good print remains readable while its successor is prepared.
      if view.raster != nil { host.installPaper(view) }
      prepare()
    }
  }

  private func prepare() {
    guard preparation == nil, !isInvalidated, acquisitionError == nil, let payload else { return }
    let expected = generation, trace = pagePreparationTrace
    preparation = Task { @MainActor [weak self] in
      guard let self else { return }
      var resumesRequiredPreparation = false
      defer {
        if generation == expected {
          preparation = nil
          if resumesRequiredPreparation { prepare() }
        }
      }
      do {
        if let old = view.raster, !SceneSourceVisibility.isVisible(view),
          old.page.pageIndex != payload.pageIndex || old.image.width < pixelWidth {
          view.clear()
        }
        trace?.mark(.preparedPageStartAt)
        let page = try await payload.source.preparedPage(payload.pageIndex, hostID: id, resources: resources,
          priority: priority, onLayoutChanged: { [weak self] layout in
            guard let self, !isInvalidated, generation == expected else { return }
            onPageLayout(.init(pageCount: layout.pageCount,
              sourceRevision: "\(payload.source.stamp.actor):\(payload.source.stamp.counter)", record: layout))
          })
        try Task.checkCancellation()
        if let layout = payload.source.layout {
          onPageLayout(.init(pageCount: layout.pageCount,
            sourceRevision: "\(payload.source.stamp.actor):\(payload.source.stamp.counter)", record: layout))
        }
        trace?.mark(.preparedPageReadyAt)
        let raster: DocumentPaperRaster
        if let old = view.raster, old.page.pageIndex == page.printed.pageIndex,
          old.page.artifact.pixelIdentity == page.printed.artifact.pixelIdentity, old.image.width >= pixelWidth {
          raster = old.rebound(page: page.printed, sourceKey: payload.source.message.key)
        } else {
          raster = try await DocumentPaperRaster.prepare(page: page.printed, sourceKey: payload.source.message.key,
            pixelWidth: pixelWidth, resources: resources, purpose: { [weak self] in self?.purpose() ?? .optional }, waits: { _ in })
        }
        try Task.checkCancellation()
        guard !isInvalidated, generation == expected else { return }
        try DocumentRenderRegistry.shared.publishNative(source: payload.source, token: payload.renderToken, pageIndex: page.printed.pageIndex,
          diagnostics: page.printed.artifact.diagnostics.map {
            .init(kind: $0.severity, fileID: $0.fileID, path: $0.path, line: $0.line, message: $0.message)
          }, programs: payload.source.programIDs.sorted().map {
            .init(instanceID: $0, sourceBasis: payload.source.program($0)?.sourceBasis,
              status: payload.source.programFailures[$0] == nil ? .notChecked : .failed)
          })
        prepared = page
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.install(raster, resources: resources, purpose: { [weak self] in self?.purpose() ?? .optional })
        interaction.configure(page: page, source: payload.source, generation: expected,
          admit: { [weak self] in
            guard let self, generation == expected, let origin = admittedOrigin() else { return nil }
            return onLinkAdmission(origin)
          },
          activateLink: { [weak self] href, admission in self?.activateLink(href, admission: admission) },
          activateSource: { [weak self] fileID, point in self?.activateSource(fileID, point: point) })
        install(page)
        CATransaction.commit()
        trace?.mark(.paperInstalledAt); trace?.mark(.canonicalReadyAt)
        resolveWaiters(); onPaperReady(); onPresentationChange()
      } catch {
        guard !isInvalidated, generation == expected, !Task.isCancelled else { return }
        acquisitionError = error; refreshInput(); onPresentationChange()
        if error is CancellationError, purpose() == .required {
          acquisitionError = nil; resumesRequiredPreparation = true
          return
        }
        resolveWaiters(); onPreparationFailure(error)
      }
    }
  }

  private func install(_ page: DocumentPreparedPage) {
    guard let host else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    host.configure(size: page.size, interactive: false)
    host.installPaper(view); host.installPaperInteraction(interaction)
    if !preservesFallback { host.removeFallback() }
    refreshInput()
    CATransaction.commit()
  }

  func updateInteractionCallbacks(onLinkActivation: @escaping (DocumentLinkActivation) -> Void) { self.onLinkActivation = onLinkActivation }
  func updateInputAdmission(in host: DocumentPageHost, isInteractive: Bool) {
    guard self.host === host, !isInvalidated else { return }
    requestedInput = isInteractive; refreshInput()
  }
  func releaseInputOwnership() { requestedInput = false; refreshInput() }
  func parkForReturn() { releaseInputOwnership() }
  private func refreshInput() {
    guard let host else { return }
    let ready = requestedInput && hasCanonicalPixels && host.hasCanonicalPaper(view)
    interaction.admitsInput = ready
    if let payload {
      let geometry = payload.source.layout?.paper(on: payload.pageIndex).geometry
        ?? retainedGeometry(on: payload.pageIndex) ?? .uncompiledDocument
      host.configure(size: .init(width: geometry.width, height: geometry.height), interactive: ready)
    }
  }
  func nativeInputIsReady(in host: DocumentPageHost) -> Bool {
    self.host === host && requestedInput && hasCanonicalPixels && interaction.admitsInput && host.hasCanonicalPaper(view)
  }
  private func admittedOrigin() -> DocumentLinkOrigin? {
    guard requestedInput, interaction.admitsInput else { return nil }
    return currentLinkOrigin
  }
  var currentLinkOrigin: DocumentLinkOrigin? {
    guard hasCanonicalPixels, let payload, installedPaper?.page.pageIndex == payload.pageIndex,
      host?.hasCanonicalPaper(view) == true else { return nil }
    return .init(source: payload.source, state: payload.state, runtimeID: id, generation: generation,
      renderToken: payload.renderToken, pageIndex: payload.pageIndex, presentationEpoch: generation)
  }
  func resolveLink(_ href: String, origin: DocumentLinkOrigin, deliver: (DocumentLinkActivation) -> Void) {
    guard let current = currentLinkOrigin, current.hasSamePresentation(as: origin), let layout = origin.source.layout else { return }
    deliver(.init(origin: origin, destination: layout.destination(for: href)))
  }
  private func activateLink(_ href: String, admission: DocumentLinkAdmission) {
    guard admission.admittedAt.duration(to: .now) <= .seconds(10), admission.isCurrent(),
      let current = currentLinkOrigin, current.hasSamePresentation(as: admission.origin),
      let layout = admission.origin.source.layout else { return }
    onLinkActivation(.admitted(origin: admission.origin, destination: layout.destination(for: href),
      admittedAt: admission.admittedAt, isCurrent: admission.isCurrent))
  }
  private func activateSource(_ fileID: String, point: CGPoint) {
    guard admittedOrigin() != nil, let payload,
      let file = payload.source.document.files.first(where: { $0.id == fileID && $0.isText }) else { return }
    let offset = payload.source.sourceOffset(fileID: fileID, pageIndex: payload.pageIndex, x: Double(point.x), y: Double(point.y)) ?? 0
    NotificationCenter.default.post(name: DocumentSourceRequest.notification,
      object: DocumentSourceRequest(documentID: payload.documentID, file: file,
        version: payload.source.document.fileVersion(fileID: fileID), offset: offset))
  }

  func awaitPaperReady(token: String) async throws {
    try Task.checkCancellation()
    let reader = UUID(), expected = generation
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters[reader] = .init(generation: expected, token: token, continuation: continuation)
        resolveWaiters()
      }
      try Task.checkCancellation()
    } onCancel: { Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: reader)?.continuation.resume(throwing: CancellationError()) } }
  }
  func awaitPresentation(token: String) async throws { try await awaitPaperReady(token: token) }
  private func resolveWaiters() {
    for (id, waiter) in waiters {
      if isInvalidated || waiter.generation != generation || waiter.token != payload?.renderToken {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
      } else if let acquisitionError {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: acquisitionError)
      } else if hasCanonicalPixels { waiters.removeValue(forKey: id)?.continuation.resume() }
    }
  }
  func retainedGeometry(on pageIndex: Int) -> WorkspaceItemGeometry? {
    guard let pages = view.raster?.page.artifact.pages, !pages.isEmpty else { return nil }
    let page = pages[min(max(0, pageIndex), pages.count - 1)]
    return .document(widthPoints: page.width, heightPoints: page.height)
  }
  func releasePreparedPageDemand() { if !requestedInput { payload?.source.releasePage(hostID: id, in: nil) } }
  func offerIdleReclamation(_ reclaim: (@MainActor () -> Void)?) { idleReclamation = reclaim; resources.reclamationOffersChanged() }
  func retryPreparation() {
    if let payload { payload.source.retryPagePreparation(payload.pageIndex) }
    acquisitionError = nil; prepare()
  }
  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true; preparation?.cancel(); preparation = nil; resolveWaiters()
    payload?.source.releasePage(hostID: id, in: nil, retiring: true)
    host?.removePaperInteraction(ownedBy: interaction); host?.removePaper(ownedBy: view)
    view.clear(); prepared = nil; idleReclamation = nil
    if let reclamationOwner { resources.unregisterReclamationOwner(reclamationOwner); self.reclamationOwner = nil }
  }
  isolated deinit { invalidate() }
}
#endif
