import NotebookCore
import NotebookTypesetter
import Observation
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
      resources: SceneRenderResources = .shared, programStore: NotebookStore? = nil, isolationID: UUID? = nil, pixelWidth: Int? = nil,
      purpose: @escaping @MainActor () -> ScenePreparationPurpose = { .required }) async throws -> RasterLease {
      try Task.checkCancellation()
      guard resources.allowsOptionalPreparation || purpose() == .required else { throw CancellationError() }
      let source = SceneRasterSource.document(id: document.id,
        token: Self.token(document: document, state: state, pageIndex: pageIndex))
      let geometry = DocumentRenderRegistry.shared.geometry(document: document, pageIndex: pageIndex)
      let requiredScale = pixelWidth.map { Double($0) / geometry.width } ?? Double(NSScreen.main?.backingScaleFactor ?? 2)
      if isolationID == nil, let lease = resources.retainRaster(for: source, minimumScale: requiredScale) { return lease }
      return try await withPreparedPage(document: document, state: state, pageIndex: pageIndex, resources: resources,
        programStore: programStore, isolationID: isolationID, purpose: purpose) { coordinator in
          try await coordinator.retainPreparedSnapshot(pixelWidth: pixelWidth ?? Int(ceil((coordinator.layout?.paper(on: pageIndex).surfaceWidth ?? geometry.width) * requiredScale)), force: true, waitsForRasterAdmission: true)
        }
    }

    func withPreparedPage<T>(document: DocumentDocument, state: DocumentStateJournal, pageIndex: Int,
      resources: SceneRenderResources, programStore: NotebookStore?, isolationID: UUID?,
      renderSession: DocumentRenderSession? = nil,
      purpose: @escaping @MainActor () -> ScenePreparationPurpose = { .required },
      operation: (DocumentPageRaster) async throws -> T) async throws -> T {
      let page = DocumentPageRaster(document: document, state: state, pageIndex: pageIndex,
        resources: resources, programStore: programStore, isolationID: isolationID,
        renderSession: renderSession, purpose: purpose)
      defer { page.close() }
      return try await withTaskCancellationHandler {
        try await page.prepare()
        return try await operation(page)
      } onCancel: { Task { @MainActor in page.close() } }
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

#if os(iOS)
struct DocumentPageView: View {
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
    PlatformDocumentPageView(
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
    PlatformDocumentPageView(document: document, state: state, isInteractive: false,
      selectedPageIndex: pageIndex, capturesSnapshot: true, onRenderReady: onRenderReady,
      onPageLayout: { _ in }, onStateChange: { _, _ in nil },
      resources: resources, snapshotPixelWidth: 256, onPreparationFailure: onFailure, isCurrent: false, programStore: model?.store)
      .accessibilityHidden(true)
  }
}

#endif

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
  final class DocumentPageHost: PageTurnOutputParkingHost {
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
    private weak var paperInteraction: DocumentPaperInteractionView?
    func ownsPaper(_ paper: DocumentPaperView) -> Bool {
      retainedPaper === paper && paper.superview === self
    }
    func hasCanonicalPaper(_ paper: DocumentPaperView) -> Bool {
      guard ownsPaper(paper), window?.isKeyWindow == true, !hasSnapshot,
        failureView == nil, loadingView == nil, hasCanonicalPaperProjection,
        UIApplication.shared.applicationState == .active else { return false }
      var ancestor: UIView? = paper
      while let view = ancestor {
        guard !view.isHidden, view.alpha > 0.01 else { return false }
        if view === window { return true }
        ancestor = view.superview
      }
      return false
    }
    func installPaperInteraction(_ interaction: DocumentPaperInteractionView) {
      if paperInteraction !== interaction { paperInteraction?.removeFromSuperview() }
      if let previous = interaction.superview as? DocumentPageHost, previous !== self {
        previous.removePaperInteraction(ownedBy: interaction)
      }
      paperInteraction = interaction
      if interaction.superview !== self {
        if programOverlay.superview === self { insertSubview(interaction, belowSubview: programOverlay) }
        else if let fallback { insertSubview(interaction, belowSubview: fallback) }
        else { addSubview(interaction) }
      }
      projectRetainedPaper()
    }
    func removePaperInteraction(ownedBy interaction: DocumentPaperInteractionView) {
      guard paperInteraction === interaction else { return }
      interaction.removeFromSuperview(); paperInteraction = nil
    }
    func installPaper(_ paper: DocumentPaperView) {
      revokeCurrentOutput()
      if let previous = paper.superview as? DocumentPageHost, previous !== self {
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
      paperInteraction?.frame = paper.frame
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
    func installPreparationHost(_ host: DocumentPageHost, size: CGSize) {
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
        let previous = projection.superview as? DocumentPageHost, previous.viewport === projection {
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
      paperInteraction?.isUserInteractionEnabled = retainsDelivery
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
      paperInteraction?.removeFromSuperview(); paperInteraction = nil
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

  private struct PlatformDocumentPageView: UIViewRepresentable {
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
    func makeUIView(context: Context) -> DocumentPageHost { DocumentPageHost() }
    func updateUIView(_ view: DocumentPageHost, context: Context) {
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
    static func dismantleUIView(_ view: DocumentPageHost, coordinator: DocumentPhysicalPageCoordinator) { coordinator.invalidate() }
  }
#endif
