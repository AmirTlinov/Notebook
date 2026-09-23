import CoreImage
import NotebookCore
import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// The one visual owner of a cover while a notebook or document opens.
///
/// The board camera owns `progress`. This surface turns that same value into a
/// reversible Core Image page curl, so a pinch can move the cover in either
/// direction without handing the gesture to a second animation.
struct CoverOpeningSurface<Cover: View>: View {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.sceneComposition) private var composition
  @Environment(\.displayScale) private var displayScale
  #if os(iOS)
    @Environment(\.workspaceItemPose) private var pose
  #endif

  let ownerID: UUID
  let progress: Double
  let revision: CoverRenderingRevision
  let backsideColor: CoverBacksideColor
  let preparesCoverMotion: Bool
  let cover: Cover

  init(
    ownerID: UUID,
    progress: Double,
    revision: CoverRenderingRevision,
    backsideColor: CoverBacksideColor,
    preparesCoverMotion: Bool,
    @ViewBuilder cover: () -> Cover
  ) {
    self.ownerID = ownerID
    self.progress = progress
    self.revision = revision
    self.backsideColor = backsideColor
    self.preparesCoverMotion = preparesCoverMotion
    self.cover = cover()
  }

  var body: some View {
    // Observe eligibility here, then recheck its live owner when deferred work
    // runs: a contact can begin before SwiftUI delivers the next view update.
    let permitsPreparation = model.permitsBackgroundPreparation
    return PlatformCoverOpeningSurface(
      ownerID: ownerID,
      progress: progress,
      revision: revision,
      backsideColor: backsideColor,
      preparesCoverMotion: preparesCoverMotion,
      canPrepare: { permitsPreparation && model.permitsBackgroundPreparation },
      cornerRadius: revision.geometry.cornerRadius,
      cover: hostedCover
    )
    .allowsHitTesting(progress < CoverOpeningPhysics.liveCoverLimit)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("cover-opening-surface")
    .accessibilityValue(
      "Обложка \(Int((CoverOpeningPhysics.clamped(progress) * 100).rounded()))%"
    )
  }

  private var hostedCover: AnyView {
    // A new hosting controller is a new SwiftUI environment root. Keep the
    // existing scene and physical pose owners across this native boundary;
    // otherwise covers fall back to uncoordinated elements and omit their ink.
    let inherited = cover.environment(model)
      .environment(\.sceneComposition, composition)
      .environment(\.displayScale, displayScale)
    #if os(iOS)
      return AnyView(inherited.environment(\.workspaceItemPose, pose))
    #else
      return AnyView(inherited)
    #endif
  }
}

struct CoverRenderingRevision: Equatable {
  struct ElementRevision: Equatable {
    let id: String
    let stamp: VersionStamp
  }

  struct InkRevision: Equatable {
    let id: UUID
    let stamp: VersionStamp
    let stateStamp: VersionStamp
  }

  let title: String
  let geometry: WorkspaceItemGeometry
  let elements: [ElementRevision]
  let ink: [InkRevision]

  init(
    item: WorkspaceItem,
    geometry: WorkspaceItemGeometry,
    elements: [SpatialElement],
    journal: SpatialInkJournal?
  ) {
    title = item.title
    self.geometry = geometry
    self.elements = elements.map {
      ElementRevision(id: $0.id, stamp: $0.stamp)
    }
    let surface = SurfaceID.cover(item.id)
    ink =
      journal?.actions.compactMap { action in
        guard action.spans.contains(where: { $0.surface == surface }) else {
          return nil
        }
        return InkRevision(
          id: action.id,
          stamp: action.stamp,
          stateStamp: action.stateStamp
        )
      } ?? []
  }
}

struct CoverBacksideColor: Equatable {
  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat

  static let document = CoverBacksideColor(
    red: 0.978,
    green: 0.972,
    blue: 0.942
  )

  var ciColor: CIColor {
    CIColor(red: red, green: green, blue: blue, alpha: 1)
  }
}

enum CoverOpeningPhysics {
  static let endpointTolerance = 0.001
  static let liveCoverLimit = 0.001
  static let warmCoverOpacity: CGFloat = 0.001
  static let curlRadiusRatio = 0.075
  static let shadowHandoffProgress = 0.08
  static let systemShadowSize: Float = 0
  static let systemShadowAmount: Float = 0

  static func clamped(_ progress: Double) -> Double {
    min(max(progress, 0), 1)
  }

  static func isClosed(_ progress: Double) -> Bool {
    clamped(progress) <= endpointTolerance
  }

  static func isOpen(_ progress: Double) -> Bool {
    clamped(progress) >= 1 - endpointTolerance
  }

  static func curlRadius(for extent: CGRect) -> Float {
    Float(max(1, min(extent.width, extent.height) * curlRadiusRatio))
  }

  /// The resting card shadow belongs to the board. Once the cover starts
  /// bending, Core Image's own lighting describes the sheet instead. A short
  /// smooth handoff prevents both renderers from outlining the same rectangle.
  static func restingShadowVisibility(_ progress: Double) -> Double {
    let handoff = min(
      clamped(progress) / shadowHandoffProgress,
      1
    )
    let eased = handoff * handoff * (3 - 2 * handoff)
    return 1 - eased
  }
}

/// Keeps one frozen cover for one physical curl. Content that arrives while
/// the sheet is moving waits for an endpoint instead of replacing pixels in
/// the person's hand halfway through the gesture.
struct CoverSnapshotLifecycle {
  private(set) var progress = 0.0
  private(set) var revision: CoverRenderingRevision?
  private(set) var capturedCover: CGImage?

  private var ownerID: UUID?
  private var capturedRevision: CoverRenderingRevision?

  var needsCurrentSnapshot: Bool {
    capturedCover == nil || capturedRevision != revision
  }

  mutating func update(
    ownerID: UUID,
    progress: Double,
    revision: CoverRenderingRevision
  ) {
    let resolvedProgress = CoverOpeningPhysics.clamped(progress)
    let ownerChanged = self.ownerID != ownerID
    if ownerChanged {
      self.ownerID = ownerID
      clearCapture()
    }

    self.revision = revision
    self.progress = resolvedProgress
  }

  var isTransitioning: Bool {
    !CoverOpeningPhysics.isClosed(progress) && !CoverOpeningPhysics.isOpen(progress)
  }

  mutating func settleAtClosedEndpoint(keepingPreparedSnapshot: Bool) {
    guard keepingPreparedSnapshot, capturedRevision == revision else {
      clearCapture()
      return
    }
  }

  mutating func settleAtOpenEndpoint() {
    guard capturedRevision != revision else { return }
    clearCapture()
  }

  mutating func storeCapturedCover(_ image: CGImage?) {
    capturedCover = image
    capturedRevision = image == nil ? nil : revision
  }

  private mutating func clearCapture() {
    capturedCover = nil
    capturedRevision = nil
  }
}

#if os(iOS)
  private struct PlatformCoverOpeningSurface: UIViewControllerRepresentable {
    @Environment(NotebookAppModel.self) private var model
    let ownerID: UUID
    let progress: Double
    let revision: CoverRenderingRevision
    let backsideColor: CoverBacksideColor
    let preparesCoverMotion: Bool
    let canPrepare: @MainActor () -> Bool
    let cornerRadius: CGFloat
    let cover: AnyView

    func makeUIViewController(context: Context) -> IPadCoverOpeningController {
      IPadCoverOpeningController()
    }

    func updateUIViewController(
      _ controller: IPadCoverOpeningController,
      context: Context
    ) {
      controller.bind(to: model, itemID: ownerID)
      controller.update(
        ownerID: ownerID,
        progress: progress,
        revision: revision,
        backsideColor: backsideColor,
        preparesCoverMotion: preparesCoverMotion,
        canPrepare: canPrepare,
        cornerRadius: cornerRadius,
        cover: cover
      )
    }

    static func dismantleUIViewController(_ controller: IPadCoverOpeningController, coordinator: ()) {
      controller.uninstallPresentation()
    }
  }

  @MainActor
  final class IPadCoverOpeningController: UIViewController {
    private let coverHost = CoverPaintHostingController(rootView: AnyView(EmptyView()))
    private weak var model: NotebookAppModel?
    private var presentationItemID: UUID?
    private var installedRevision: CoverRenderingRevision?
    private var hasInstalledLayout = false
    // Visibility belongs to the wrapper so the captured hosting layer keeps
    // fully opaque pixels while the live cover rests behind the open page.
    private let coverVisibilityView = UIView()
    private let curlView = SheetCurlMetalView(frame: .zero)

    var submittedCurlFrameCount: Int { curlView.submittedFrameCount }
    private(set) var capturedCoverCount = 0
    private var captureScheduled = false
    private var lifecycle = CoverSnapshotLifecycle()
    private var backsideColor = CoverBacksideColor.document
    private var preparesCoverMotion = false
    private var canPrepare: @MainActor () -> Bool = { false }
    private var cornerRadius: CGFloat = 0

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .clear
      view.isOpaque = false
      view.clipsToBounds = false

      addChild(coverHost)
      coverHost.view.backgroundColor = .clear
      coverHost.view.isOpaque = false
      coverHost.safeAreaRegions = []
      coverHost.didLayout = { [weak self] in
        guard let self else { return }
        installedRevision = lifecycle.revision; hasInstalledLayout = true
      }
      coverVisibilityView.backgroundColor = .clear
      coverVisibilityView.isOpaque = false
      view.addSubview(coverVisibilityView)
      coverVisibilityView.addSubview(coverHost.view)
      coverHost.didMove(toParent: self)

      curlView.isHidden = true
      curlView.permitsFrameSubmission = { [weak self] in
        guard let self else { return false }
        return lifecycle.isTransitioning || (preparesCoverMotion && canPrepare())
      }
      view.addSubview(curlView)
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      renderCurrentState()
    }

    func update(
      ownerID: UUID,
      progress: Double,
      revision: CoverRenderingRevision,
      backsideColor: CoverBacksideColor,
      preparesCoverMotion: Bool,
      canPrepare: @escaping @MainActor () -> Bool,
      cornerRadius: CGFloat,
      cover: AnyView
    ) {
      if lifecycle.revision != revision { hasInstalledLayout = false; installedRevision = nil }
      lifecycle.update(
        ownerID: ownerID,
        progress: progress,
        revision: revision
      )
      coverHost.rootView = cover
      self.backsideColor = backsideColor
      self.preparesCoverMotion = preparesCoverMotion
      self.canPrepare = canPrepare
      self.cornerRadius = cornerRadius

      guard isViewLoaded else { return }
      view.setNeedsLayout()
      renderCurrentState()
    }

    func bind(to model: NotebookAppModel, itemID: UUID) {
      guard self.model !== model || presentationItemID != itemID else { return }
      uninstallPresentation()
      self.model = model; presentationItemID = itemID
      model.coverPresentations.register(self, itemID: itemID)
    }

    func uninstallPresentation() {
      if let presentationItemID { model?.coverPresentations.remove(self, itemID: presentationItemID) }
      model = nil; presentationItemID = nil; hasInstalledLayout = false; installedRevision = nil
    }

    /// Only the existing live subtree can fix Send-time pixels. Curl snapshots
    /// and cache preparation are separate consumers and cannot supply this proof.
    func capturePresented(expected: NotebookCoverPresentedSources, region: PageRect,
      resources: SceneRenderResources) throws -> NotebookSubmittedPixels? {
      if let failure = presentationFailure(expected: expected) { throw SceneRenderError.snapshotPending(failure) }
      return try NotebookSubmittedPixels.capture(view: coverHost.view,
        physicalSize: .init(width: expected.revision.geometry.width, height: expected.revision.geometry.height),
        region: region, resources: resources)
    }

    func presentationFailure(expected: NotebookCoverPresentedSources) -> String? {
      guard let model, let itemID = presentationItemID, isViewLoaded, view.window != nil else { return "cover_owner_unavailable" }
      guard model.presencePhase == .settled, let presence = model.presence,
        presence.boardID == expected.boardID,
        (presence.focusedItemID != itemID || CoverOpeningPhysics.isClosed(presence.openProgress)),
        CoverOpeningPhysics.isClosed(lifecycle.progress) else { return "cover_is_moving" }
      guard NotebookCoverPresentedSources.current(model: model, itemID: itemID, boardID: expected.boardID) == expected,
        lifecycle.revision == expected.revision else { return "cover_source_changed" }
      guard hasInstalledLayout, installedRevision == expected.revision,
        coverHost.view.window === view.window, coverHost.view.superview === coverVisibilityView,
        coverHost.view.frame == view.bounds, coverVisibilityView.frame == view.bounds,
        !coverVisibilityView.isHidden, coverVisibilityView.alpha == 1,
        CATransform3DIsIdentity(coverHost.view.layer.transform) else { return "cover_layout_pending" }
      var ancestor: UIView? = coverHost.view
      while let node = ancestor {
        if node.isHidden || node.alpha <= 0.001 { return "cover_hidden" }
        ancestor = node.superview
      }
      guard let cohort = model.compositionTiles.published else { return "cover_scene_unavailable" }
      for element in model.presentedCoverElements(cohort: cohort, boardID: expected.boardID, itemID: itemID)
        where element.kind != .nativeText {
        let address = SceneSourceAddress(plane: .cover(boardID: expected.boardID, itemID: itemID), elementID: element.id)
        guard cohort.hasInstalledPixels(for: address), let receipt = cohort.sourceReceipts[address], receipt.hasCurrentPixels,
          SceneRasterSource.agent(receipt.demand.source) == .agent(agentElementSnapshotSource(element)) else { return "cover_element_pending" }
      }
      let registry = model.compositionTiles.surfaceRegistry, surface = SurfaceID.cover(itemID)
      guard !registry.hasActiveAction(on: surface), !registry.hasContact(on: surface) else { return "cover_ink_contact" }
      if let inkRevision = expected.installedInkRevision {
        guard let canvas = registry.canvas(for: surface) else { return "cover_ink_owner_unavailable" }
        guard canvas.isDescendant(of: coverHost.view) else { return "cover_ink_detached:\(type(of: canvas.superview))" }
        guard canvas.window === view.window else { return "cover_ink_other_window" }
        guard !canvas.isHidden, canvas.alpha > 0.001 else { return "cover_ink_hidden" }
        guard canvas.isStableFramePresented else { return "cover_ink_frame_pending" }
        guard canvas.installedSpatialSource?.journalRevision == inkRevision else { return "cover_ink_source_changed" }
      } else if !expected.revision.ink.isEmpty { return "cover_ink_unavailable" }
      return nil
    }

    private func renderCurrentState() {
      guard let curlLayout = layoutSurfaces() else { return }
      if CoverOpeningPhysics.isClosed(lifecycle.progress) {
        lifecycle.settleAtClosedEndpoint(
          keepingPreparedSnapshot: preparesCoverMotion
        )
        resetCoverHostGeometry()
        coverVisibilityView.isHidden = false
        coverVisibilityView.alpha = 1
        coverHost.view.isUserInteractionEnabled = true
        prepareRestingCoverIfNeeded()
        return
      }
      if CoverOpeningPhysics.isOpen(lifecycle.progress) {
        lifecycle.settleAtOpenEndpoint()
        resetCoverHostGeometry()
        // Keep the live cover in the render tree while the page is open. It is
        // visually absent, but Metal/WebKit can still produce a current frame
        // if the next pinch starts by closing the sheet.
        coverVisibilityView.isHidden = false
        coverVisibilityView.alpha = CoverOpeningPhysics.warmCoverOpacity
        coverHost.view.isUserInteractionEnabled = false
        prepareRestingCoverIfNeeded()
        return
      }

      if lifecycle.capturedCover == nil {
        scheduleCapture()
      }
      guard let capturedCover = lifecycle.capturedCover else {
        showLiveCoverUntilSnapshotIsReady()
        return
      }

      coverVisibilityView.isHidden = true
      coverHost.view.isUserInteractionEnabled = false
      curlView.isHidden = false
      curlView.alpha = 1
      curlView.update(
        cover: capturedCover,
        progress: lifecycle.progress,
        backsideColor: backsideColor,
        cornerRadius: cornerRadius,
        layout: curlLayout
      )
    }

    private func layoutSurfaces() -> SheetCurlLayout? {
      guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
      coverVisibilityView.frame = view.bounds
      if coverHost.view.frame != view.bounds {
        hasInstalledLayout = false
        coverHost.view.frame = view.bounds
      }
      let layout = SheetCurlLayout(sheetSize: view.bounds.size)
      if curlView.frame != layout.canvasFrameAroundSheet {
        curlView.frame = layout.canvasFrameAroundSheet
      }
      return layout
    }

    private func prepareRestingCoverIfNeeded() {
      // The live cover/paper owns the endpoint. An almost transparent Metal
      // layer is not an offscreen executor: its unpresented drawables can fill
      // the display pool and block the document's MainActor for a second.
      // Keep the snapshot and shared CI program warm, not a fake screen frame.
      curlView.isHidden = true
      guard preparesCoverMotion, canPrepare() else { return }
      if lifecycle.needsCurrentSnapshot { scheduleCapture() }
    }

    // A deferred frame lets the attached hosting tree commit its first content.
    // InkCanvasView confirms its own GPU frame before the curl freezes those
    // pixels. Pending ink yields a frame between attempts while the cover is live.
    private var needsCaptureNow: Bool {
      if lifecycle.isTransitioning { return lifecycle.capturedCover == nil }
      return preparesCoverMotion && canPrepare() && lifecycle.needsCurrentSnapshot
    }

    private func scheduleCapture() {
      guard !captureScheduled, view.window != nil, needsCaptureNow else { return }
      captureScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1 / 60) { [weak self] in
        guard let self else { return }
        self.captureScheduled = false
        guard self.view.window != nil, self.needsCaptureNow else { return }
        self.lifecycle.storeCapturedCover(self.captureCover())
        self.renderCurrentState()
      }
    }

    private func captureCover() -> CGImage? {
      guard view.window != nil else { return nil }
      resetCoverHostGeometry()
      let wasHidden = coverVisibilityView.isHidden
      let previousAlpha = coverVisibilityView.alpha
      coverVisibilityView.isHidden = false
      coverVisibilityView.alpha = 1
      defer {
        coverVisibilityView.alpha = previousAlpha
        coverVisibilityView.isHidden = wasHidden
      }
      coverHost.view.frame = view.bounds
      coverHost.view.setNeedsLayout()
      coverHost.view.layoutIfNeeded()
      guard inkFramesAreReady(in: coverHost.view) else { return nil }

      let format = UIGraphicsImageRendererFormat.preferred()
      format.opaque = false
      format.scale =
        view.window?.screen.scale
        ?? max(view.traitCollection.displayScale, 1)
      let renderer = UIGraphicsImageRenderer(bounds: coverHost.view.bounds, format: format)
      let image = renderer.image { _ in
        coverHost.view.drawHierarchy(
          in: coverHost.view.bounds,
          afterScreenUpdates: true
        )
      }
      if image.cgImage != nil { capturedCoverCount += 1 }
      return image.cgImage
    }

    private func inkFramesAreReady(in view: UIView) -> Bool {
      if let canvas = view as? InkCanvasView {
        return canvas.isStableFramePresented
      }
      return view.subviews.allSatisfy { inkFramesAreReady(in: $0) }
    }

    private func resetCoverHostGeometry() {
      coverHost.view.layer.transform = CATransform3DIdentity
      coverHost.view.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      coverHost.view.layer.position = CGPoint(
        x: view.bounds.midX,
        y: view.bounds.midY
      )
    }

    private func showLiveCoverUntilSnapshotIsReady() {
      resetCoverHostGeometry()
      coverVisibilityView.isHidden = false
      coverVisibilityView.alpha = 1
      coverHost.view.isUserInteractionEnabled = false
      curlView.isHidden = true
    }
  }

  @MainActor
  private final class CoverPaintHostingController: UIHostingController<AnyView> {
    var didLayout: () -> Void = { }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); didLayout() }
  }
#elseif os(macOS)
  private struct PlatformCoverOpeningSurface: NSViewRepresentable {
    let ownerID: UUID
    let progress: Double
    let revision: CoverRenderingRevision
    let backsideColor: CoverBacksideColor
    let preparesCoverMotion: Bool
    let canPrepare: @MainActor () -> Bool
    let cornerRadius: CGFloat
    let cover: AnyView

    func makeNSView(context: Context) -> MacCoverOpeningView {
      MacCoverOpeningView(frame: .zero)
    }

    func updateNSView(_ view: MacCoverOpeningView, context: Context) {
      view.update(
        ownerID: ownerID,
        progress: progress,
        revision: revision,
        backsideColor: backsideColor,
        preparesCoverMotion: preparesCoverMotion,
        canPrepare: canPrepare,
        cornerRadius: cornerRadius,
        cover: cover
      )
    }
  }

  @MainActor
  private final class MacCoverOpeningView: NSView {
    private let coverHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let curlView = SheetCurlMetalView(frame: .zero)

    private var lifecycle = CoverSnapshotLifecycle()
    private var backsideColor = CoverBacksideColor.document
    private var preparesCoverMotion = false
    private var canPrepare: @MainActor () -> Bool = { false }
    private var cornerRadius: CGFloat = 0

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      wantsLayer = true
      layer?.backgroundColor = NSColor.clear.cgColor
      layer?.masksToBounds = false
      coverHost.wantsLayer = true
      coverHost.layer?.backgroundColor = NSColor.clear.cgColor
      addSubview(coverHost)
      curlView.isHidden = true
      curlView.permitsFrameSubmission = { [weak self] in
        guard let self else { return false }
        return lifecycle.isTransitioning || (preparesCoverMotion && canPrepare())
      }
      addSubview(curlView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func layout() {
      super.layout()
      renderCurrentState()
    }

    func update(
      ownerID: UUID,
      progress: Double,
      revision: CoverRenderingRevision,
      backsideColor: CoverBacksideColor,
      preparesCoverMotion: Bool,
      canPrepare: @escaping @MainActor () -> Bool,
      cornerRadius: CGFloat,
      cover: AnyView
    ) {
      lifecycle.update(
        ownerID: ownerID,
        progress: progress,
        revision: revision
      )
      coverHost.rootView = cover
      self.backsideColor = backsideColor
      self.preparesCoverMotion = preparesCoverMotion
      self.canPrepare = canPrepare
      self.cornerRadius = cornerRadius

      needsLayout = true
      renderCurrentState()
    }

    private func renderCurrentState() {
      guard let curlLayout = layoutSurfaces() else { return }
      if CoverOpeningPhysics.isClosed(lifecycle.progress) {
        lifecycle.settleAtClosedEndpoint(
          keepingPreparedSnapshot: preparesCoverMotion
        )
        resetCoverHostGeometry()
        coverHost.isHidden = false
        coverHost.alphaValue = 1
        prepareRestingCoverIfNeeded()
        return
      }
      if CoverOpeningPhysics.isOpen(lifecycle.progress) {
        lifecycle.settleAtOpenEndpoint()
        resetCoverHostGeometry()
        coverHost.isHidden = false
        coverHost.alphaValue = CoverOpeningPhysics.warmCoverOpacity
        prepareRestingCoverIfNeeded()
        return
      }

      if lifecycle.capturedCover == nil {
        lifecycle.storeCapturedCover(captureCover())
      }
      guard let capturedCover = lifecycle.capturedCover else {
        showLiveCoverUntilSnapshotIsReady()
        return
      }

      coverHost.isHidden = true
      curlView.isHidden = false
      curlView.alphaValue = 1
      curlView.update(
        cover: capturedCover,
        progress: lifecycle.progress,
        backsideColor: backsideColor,
        cornerRadius: cornerRadius,
        layout: curlLayout
      )
    }

    private func layoutSurfaces() -> SheetCurlLayout? {
      guard bounds.width > 0, bounds.height > 0 else { return nil }
      if coverHost.frame != bounds {
        coverHost.frame = bounds
      }
      let layout = SheetCurlLayout(sheetSize: bounds.size)
      if curlView.frame != layout.canvasFrameAroundSheet {
        curlView.frame = layout.canvasFrameAroundSheet
      }
      return layout
    }

    private func prepareRestingCoverIfNeeded() {
      curlView.isHidden = true
      guard preparesCoverMotion, canPrepare() else { return }
      if lifecycle.needsCurrentSnapshot {
        lifecycle.storeCapturedCover(captureCover())
      }
    }

    private func captureCover() -> CGImage? {
      resetCoverHostGeometry()
      let wasHidden = coverHost.isHidden
      let previousAlpha = coverHost.alphaValue
      coverHost.isHidden = false
      coverHost.alphaValue = 1
      coverHost.frame = bounds
      coverHost.layoutSubtreeIfNeeded()
      guard
        let representation = coverHost.bitmapImageRepForCachingDisplay(
          in: coverHost.bounds
        )
      else {
        coverHost.alphaValue = previousAlpha
        coverHost.isHidden = wasHidden
        return nil
      }
      coverHost.cacheDisplay(in: coverHost.bounds, to: representation)
      coverHost.alphaValue = previousAlpha
      coverHost.isHidden = wasHidden
      return representation.cgImage
    }

    private func resetCoverHostGeometry() {
      coverHost.layer?.transform = CATransform3DIdentity
      coverHost.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      coverHost.layer?.position = CGPoint(
        x: bounds.midX,
        y: bounds.midY
      )
    }

    private func showLiveCoverUntilSnapshotIsReady() {
      resetCoverHostGeometry()
      coverHost.isHidden = false
      coverHost.alphaValue = 1
      curlView.isHidden = true
    }
  }
#endif
