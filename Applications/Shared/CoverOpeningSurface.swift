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
    @Environment(\.scenePlaneProjection) private var projection
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
    _ = SceneRenderResources.shared.optionalPreparationGeneration
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
      return AnyView(inherited.environment(\.workspaceItemPose, pose)
        .environment(\.scenePlaneProjection, projection))
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
typealias CoverSnapshotLifecycle = CoverSnapshotState<CGImage>

struct CoverSnapshotState<Frame> {
  enum Endpoint { case closed, open }
  private(set) var progress = 0.0
  private(set) var lastSettledEndpoint = Endpoint.closed
  private(set) var revision: CoverRenderingRevision?
  private(set) var capturedCover: Frame?

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
      lastSettledEndpoint = .closed
      clearCapture()
    }

    if CoverOpeningPhysics.isClosed(resolvedProgress) { lastSettledEndpoint = .closed }
    else if CoverOpeningPhysics.isOpen(resolvedProgress) { lastSettledEndpoint = .open }

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

  mutating func storeCapturedCover(_ image: Frame?, revision: CoverRenderingRevision? = nil) {
    capturedCover = image
    capturedRevision = image == nil ? nil : (revision ?? self.revision)
  }

  private mutating func clearCapture() {
    capturedCover = nil
    capturedRevision = nil
  }
}

#if os(iOS)
  private struct PlatformCoverOpeningSurface: UIViewControllerRepresentable {
    @Environment(NotebookAppModel.self) private var model
    @Environment(\.sceneComposition) private var composition
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
        compositionID: composition.id,
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
  final class IPadCoverOpeningController: UIViewController, SceneNativeCameraOwner {
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
    // Tests can supply their physical material explicitly. Production has one
    // canonical compositor path and no hierarchy-capture fallback.
    var prepareMaterial: (@MainActor (UUID, CoverRenderingRevision, Double) async throws -> PageTurnFrame)?
    private var materialTask: Task<Void, Never>?
    private var materialRequest: UUID?
    private var materialDemand = UUID()
    private var failedMaterialDemand: UUID?
    private var failedMaterialAdmission: SceneRasterAdmission?
    private var parkedMaterialDemand: UUID?
    private var reclamationOwner: UUID?
    private var preparationWasAllowed = false
    private var materialOwnerID: UUID?
    private var materialCohortID: UUID?
    private var awaitsDrawableAdmission = false
    private var hasLivePrograms = false
    private var capturedMaterialIsEphemeral = false
    private var resourceObservers: [NSObjectProtocol] = []
    private var lifecycle = CoverSnapshotState<PageTurnFrame>()
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
        return lifecycle.isTransitioning || (preparesCoverMotion && canPrepare()
          && SceneRenderResources.shared.allowsOptionalPreparation)
      }
      curlView.onCoverRenderingReady = { [weak self] in self?.renderCurrentState() }
      curlView.onCoverRenderFailure = { [weak self] _ in
        guard let self else { return }
        failedMaterialDemand = materialDemand
        awaitsDrawableAdmission = false
        curlView.releaseSource()
        showEndpointUntilSnapshotIsReady()
        model?.showCue("Не удалось подготовить перелистывание обложки")
      }
      view.addSubview(curlView)
      // Only passive material survives at rest; accepted input cuts end with
      // their motion and are still borrowed by any submitted GPU command.
      reclamationOwner = SceneRenderResources.shared.registerReclamationOwner { [weak self] in
        guard let self, !lifecycle.isTransitioning, let frame = lifecycle.capturedCover else { return [] }
        let id = frame.id
        return [.init(id: id, bytes: frame.byteCount, rasterCount: 1, value: .unused,
          distance: 1, restorationMilliseconds: 8, release: { [weak self] in
            guard let self, !lifecycle.isTransitioning, lifecycle.capturedCover?.id == id else { return nil }
            lifecycle.storeCapturedCover(nil); parkedMaterialDemand = materialDemand
            return nil
          })]
      }
      resourceObservers.append(NotificationCenter.default.addObserver(forName: SceneRenderResources.didChange,
        object: nil, queue: .main) { [weak self] note in
          let id = note.object as? String
          Task { @MainActor [weak self] in
            guard let self, let id, lifecycle.revision?.elements.contains(where: { $0.id == id }) == true else { return }
            materialInputsChanged()
          }
        })
      resourceObservers.append(NotificationCenter.default.addObserver(forName: SceneRenderResources.didGainRasterAdmission,
        object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in
            guard let self else { return }
            if awaitsDrawableAdmission { renderCurrentState() }
            else if materialAdmissionImproved { materialInputsChanged() }
          }
        })
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      renderCurrentState()
    }

    func update(
      ownerID: UUID,
      compositionID: UUID? = nil,
      progress: Double,
      revision: CoverRenderingRevision,
      backsideColor: CoverBacksideColor,
      preparesCoverMotion: Bool,
      canPrepare: @escaping @MainActor () -> Bool,
      cornerRadius: CGFloat,
      cover: AnyView
    ) {
      let ownerChanged = materialOwnerID != ownerID
      let contentChanged = ownerChanged || lifecycle.revision != revision
      // The environment identifies the content crossing this hosting boundary.
      // A model publication can precede it: consuming that future ID here would
      // suppress the later installation and leave source receipts on an old cohort.
      let cohortChanged = materialCohortID != compositionID
      materialCohortID = compositionID
      if contentChanged || cohortChanged { hasInstalledLayout = false; installedRevision = nil }
      let wasTransitioning = lifecycle.isTransitioning
      let current = model?.presence
      let nativeProgress = current.map { $0.focusedItemID == ownerID ? $0.openProgress : 0 } ?? progress
      lifecycle.update(ownerID: ownerID, progress: nativeProgress, revision: revision)
      materialOwnerID = ownerID
      if contentChanged {
        if ownerChanged || !wasTransitioning { cancelMaterial() }
        materialDemand = UUID(); failedMaterialDemand = nil
        if let model, let index = model.sceneIndex, let boardID = index.ownerBoard(itemID: ownerID) {
          hasLivePrograms = index.coverElements(itemID: ownerID, boardID: boardID).contains { agentElementSnapshotSource($0).requiresLiveRuntime }
        }
      } else if cohortChanged, materialTask == nil, lifecycle.capturedCover == nil {
        // Cohort readiness may unblock this cover. An unrelated cohort does
        // not invalidate already prepared pixels with the same local source.
        materialDemand = UUID(); failedMaterialDemand = nil
      }
      if wasTransitioning, !lifecycle.isTransitioning { cancelMaterial() }
      if !wasTransitioning, lifecycle.isTransitioning {
        materialDemand = UUID(); failedMaterialDemand = nil
        if hasLivePrograms { cancelMaterial(); lifecycle.storeCapturedCover(nil) }
      }
      if contentChanged || cohortChanged { coverHost.rootView = cover }
      self.backsideColor = backsideColor
      self.preparesCoverMotion = preparesCoverMotion
      self.canPrepare = canPrepare
      self.cornerRadius = cornerRadius
      let preparationAllowed = preparesCoverMotion && canPrepare()
        && SceneRenderResources.shared.allowsOptionalPreparation
      if preparationAllowed, !preparationWasAllowed { materialDemand = UUID(); failedMaterialDemand = nil }
      preparationWasAllowed = preparationAllowed
      if !preparationAllowed, !lifecycle.isTransitioning { cancelMaterial() }

      guard isViewLoaded else { return }
      view.setNeedsLayout()
      renderCurrentState()
    }

    func bind(to model: NotebookAppModel, itemID: UUID) {
      guard self.model !== model || presentationItemID != itemID else { return }
      uninstallPresentation()
      self.model = model; presentationItemID = itemID
      model.coverPresentations.register(self, itemID: itemID)
      model.nativeCameraProjection.register(self)
    }

    func projectSceneCamera(_ presence: SessionPresence) {
      guard let itemID = presentationItemID, let revision = lifecycle.revision else { return }
      let wasTransitioning = lifecycle.isTransitioning
      lifecycle.update(ownerID: itemID, progress: presence.focusedItemID == itemID ? presence.openProgress : 0, revision: revision)
      if wasTransitioning, !lifecycle.isTransitioning { cancelMaterial() }
      if !wasTransitioning, lifecycle.isTransitioning {
        materialDemand = UUID(); failedMaterialDemand = nil
        if hasLivePrograms { cancelMaterial(); lifecycle.storeCapturedCover(nil) }
      }
      if wasTransitioning != lifecycle.isTransitioning { SceneRenderResources.shared.reclamationOffersChanged() }
      if isViewLoaded { renderCurrentState() }
    }

    func uninstallPresentation() {
      model?.nativeCameraProjection.remove(self)
      if let presentationItemID { model?.coverPresentations.remove(self, itemID: presentationItemID) }
      model = nil; presentationItemID = nil; hasInstalledLayout = false; installedRevision = nil
      preparesCoverMotion = false
      canPrepare = { false }
      cancelMaterial(); lifecycle.storeCapturedCover(nil)
      capturedMaterialIsEphemeral = false
      materialCohortID = nil; awaitsDrawableAdmission = false
      curlView.releaseSource()
    }

    isolated deinit {
      materialTask?.cancel()
      for observer in resourceObservers { NotificationCenter.default.removeObserver(observer) }
      if let reclamationOwner { SceneRenderResources.shared.unregisterReclamationOwner(reclamationOwner) }
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
      prepareCoverProgramIfNeeded()
      if CoverOpeningPhysics.isClosed(lifecycle.progress) {
        discardEphemeralMaterial()
        lifecycle.settleAtClosedEndpoint(
          keepingPreparedSnapshot: preparesCoverMotion
        )
        awaitsDrawableAdmission = false; curlView.releaseSource()
        resetCoverHostGeometry()
        coverVisibilityView.isHidden = false
        coverVisibilityView.alpha = 1
        coverHost.view.isUserInteractionEnabled = true
        prepareRestingCoverIfNeeded()
        return
      }
      if CoverOpeningPhysics.isOpen(lifecycle.progress) {
        discardEphemeralMaterial()
        lifecycle.settleAtOpenEndpoint()
        cancelMaterial(); awaitsDrawableAdmission = false; curlView.releaseSource()
        resetCoverHostGeometry()
        // Keep the live cover in the render tree while the page is open. It is
        // visually absent, but Metal/WebKit can still produce a current frame
        // if the next pinch starts by closing the sheet.
        coverVisibilityView.isHidden = false
        coverVisibilityView.alpha = CoverOpeningPhysics.warmCoverOpacity
        coverHost.view.isUserInteractionEnabled = false
        // Passive prepared material may remain. A new current cut belongs to
        // actual closing, not work behind the open paper.
        curlView.isHidden = true
        return
      }

      if lifecycle.capturedCover == nil {
        requestMaterial()
      }
      guard let capturedCover = lifecycle.capturedCover else {
        showEndpointUntilSnapshotIsReady()
        return
      }
      guard curlView.prepareCoverRendering() else {
        showEndpointUntilSnapshotIsReady()
        return
      }

      if curlView.frameLease == nil {
        let scale = max(view.window?.screen.scale ?? view.traitCollection.displayScale, 1)
        let width = Int(ceil(curlView.bounds.width * scale)), height = Int(ceil(curlView.bounds.height * scale))
        guard let lease = SceneRenderResources.shared.reserveRaster(pixelWidth: width, pixelHeight: height,
          backingCount: curlView.drawableCount, priority: .input)
        else { awaitsDrawableAdmission = true; showEndpointUntilSnapshotIsReady(); return }
        awaitsDrawableAdmission = false; curlView.frameLease = lease
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
      guard preparesCoverMotion, !hasLivePrograms, canPrepare(),
        SceneRenderResources.shared.allowsOptionalPreparation else { return }
      if lifecycle.needsCurrentSnapshot { requestMaterial() }
    }

    private func prepareCoverProgramIfNeeded() {
      guard let ownerID = materialOwnerID, let revision = lifecycle.revision,
        let window = view.window, !window.isHidden,
        preparesCoverMotion, canPrepare(), SceneRenderResources.shared.allowsOptionalPreparation else { return }
      var ancestor: UIView? = view
      while let node = ancestor {
        guard !node.isHidden, node.alpha > 0.001 else { return }
        ancestor = node.superview
      }
      // This is the mounted owner's body-free capability demand. An initially
      // open cover still takes its current material only after closing begins.
      // Recheck the source after the live preparation permission callback.
      guard materialOwnerID == ownerID, lifecycle.revision == revision,
        preparesCoverMotion, view.window === window, !window.isHidden else { return }
      SheetCurlGPU.shared.requestCoverPreparation()
    }

    private var needsMaterialNow: Bool {
      guard let window = view.window, !window.isHidden else { return false }
      if lifecycle.isTransitioning { return lifecycle.capturedCover == nil }
      return CoverOpeningPhysics.isClosed(lifecycle.progress)
        && preparesCoverMotion && !hasLivePrograms && canPrepare()
        && SceneRenderResources.shared.allowsOptionalPreparation && lifecycle.needsCurrentSnapshot
    }

    private func cancelMaterial() {
      materialRequest = nil; materialTask?.cancel(); materialTask = nil
    }

    private func discardEphemeralMaterial() {
      guard capturedMaterialIsEphemeral else { return }
      lifecycle.storeCapturedCover(nil); capturedMaterialIsEphemeral = false
    }

    private func materialInputsChanged() {
      // Accepted motion keeps its exact cut. Completion of that motion admits
      // a successor; a pending cut retries only on an owner event, not a timer.
      guard materialTask == nil, !(lifecycle.isTransitioning && lifecycle.capturedCover != nil) else { return }
      materialDemand = UUID(); failedMaterialDemand = nil; failedMaterialAdmission = nil
      if !lifecycle.isTransitioning { lifecycle.storeCapturedCover(nil) }
      if isViewLoaded { renderCurrentState() }
    }

    private var materialAdmissionImproved: Bool {
      guard failedMaterialDemand != nil, let old = failedMaterialAdmission else { return false }
      let current = SceneRenderResources.shared.rasterAdmission
      return current.byteLimit - current.heldBytes > old.byteLimit - old.heldBytes
        || current.passiveByteLimit - current.pinnedBytes - current.passiveReservedBytes
          > old.passiveByteLimit - old.pinnedBytes - old.passiveReservedBytes
        || current.countLimit - current.pinnedCount - current.reservedCount
          > old.countLimit - old.pinnedCount - old.reservedCount
    }

    private func requestMaterial() {
      guard materialTask == nil, failedMaterialDemand != materialDemand, parkedMaterialDemand != materialDemand, needsMaterialNow,
        let ownerID = materialOwnerID, let revision = lifecycle.revision else { return }
      let id = UUID(), demand = materialDemand
      let priority: SceneAllocationPriority = lifecycle.isTransitioning ? .input : .passive
      materialRequest = id
      let density = Double(max(view.window?.screen.scale ?? view.traitCollection.displayScale, 1))
      let scale = min(density, sqrt(4_000_000 / (revision.geometry.width * revision.geometry.height)))
      materialTask = Task { @MainActor [weak self] in
        guard let self else { return }
        defer {
          if materialRequest == id { materialTask = nil; materialRequest = nil }
        }
        do {
          // The task boundary admits later owner cancellation before work.
          try Task.checkCancellation()
          guard needsMaterialNow else { throw CancellationError() }
          // This accepted cover cut needs the curl program on its next
          // moving frame. Prepare it alongside the cut, without adding it
          // to unrelated interior-page GPU initialization or borrowing.
          SheetCurlGPU.shared.requestCoverPreparation()
          let material: PageTurnFrame
          if let prepareMaterial { material = try await prepareMaterial(ownerID, revision, scale) }
          else { material = try await prepareCoverMaterial(ownerID: ownerID, revision: revision, scale: scale, priority: priority) }
          try Task.checkCancellation()
          guard materialRequest == id, materialOwnerID == ownerID, needsMaterialNow else { return }
          lifecycle.storeCapturedCover(material, revision: revision)
          capturedMaterialIsEphemeral = priority == .input
          capturedCoverCount += 1
          materialTask = nil; materialRequest = nil; failedMaterialDemand = nil; failedMaterialAdmission = nil; parkedMaterialDemand = nil
          SceneRenderResources.shared.reclamationOffersChanged()
          renderCurrentState()
        } catch {
          guard materialRequest == id else { return }
          materialTask = nil; materialRequest = nil; failedMaterialDemand = demand
          failedMaterialAdmission = error as? SceneRenderError == .resourceLimit ? SceneRenderResources.shared.rasterAdmission : nil
        }
      }
    }

    private func prepareCoverMaterial(ownerID: UUID, revision: CoverRenderingRevision, scale: Double,
      priority: SceneAllocationPriority) async throws -> PageTurnFrame {
      guard let model, let cohort = model.compositionTiles.published,
        let boardID = cohort.frame.index.ownerBoard(itemID: ownerID) else {
        throw SceneRenderError.snapshotPending("cover_material_owner")
      }
      // These are bounded values of the installed live scene. No store scan or
      // extra WebKit executor is started by a physical cover gesture.
      let workspace = model.presentedWorkspace(cohort: cohort)
      let hierarchy = model.presentedHierarchy(cohort: cohort)
      var paperSizes = cohort.frame.index.documentPaperSizes
      paperSizes[ownerID] = revision.geometry
      let index = WorkspaceSceneIndex(workspace: workspace, hierarchy: hierarchy,
        paperSizes: paperSizes, reusing: cohort.frame.index)
      let journal = model.renderingInk(on: .cover(ownerID), fallback: cohort.liveData.ink) ?? cohort.liveData.ink
      guard let item = workspace.item(id: ownerID),
        CoverRenderingRevision(item: item, geometry: revision.geometry,
          elements: index.coverElements(itemID: ownerID, boardID: boardID), journal: model.spatialInk) == revision else {
        throw SceneRenderError.snapshotPending("cover_material_revision")
      }
      let source = SceneCompositionSource(index: index, hierarchy: hierarchy, journal: journal)
      let plane = SceneCompositionPlane.cover(boardID: boardID, itemID: ownerID)
      let rasters = cohort.sourceRasters.filter { $0.key.plane == plane }.compactMapValues { $0.retainedCopy() }
      let cuts = priority == .input
        ? try await Self.captureCoverCuts(elements: index.coverElements(itemID: ownerID, boardID: boardID), plane: plane)
        : [:]
      let renderer = SceneCompositionRenderer(source: source, usesPreparedSources: true,
        installedSources: rasters, temporarySources: cuts,
        permitsPreparation: { [weak self] in self?.needsMaterialNow == true })
      let pixels = try await renderer.renderCoverImage(itemID: ownerID, boardID: boardID, scale: scale, priority: priority)
      let size = CGSize(width: revision.geometry.width, height: revision.geometry.height)
      return try await PageTurnFrame.compose(size: size, scale: scale,
        images: [.init(image: pixels.image, frame: CGRect(origin: .zero, size: size))],
        priority: priority,
        purpose: { [weak self] in self?.lifecycle.isTransitioning == true ? .required : .optional },
        retaining: [pixels])
    }

    private static func captureCoverCuts(elements: [SpatialElement], plane: SceneCompositionPlane) async throws -> [SceneSourceAddress: SceneRasterCut] {
      var seen = Set<String>()
      let sources = try elements.map(agentElementSnapshotSource).filter { source in
        guard source.requiresLiveRuntime, seen.insert(source.id).inserted else { return false }
        return try AgentWebCoordinator.currentInstallation(
          focus: .board(boardID: plane.boardID, elementID: source.id), element: source)?.isInstalled == true
      }
      let capture: @MainActor @Sendable (AgentElement) async throws -> (SceneSourceAddress, SceneRasterCut?) = { source in
        try Task.checkCancellation()
        let cut = try await AgentWebCoordinator.captureCurrentCut(
          focus: .board(boardID: plane.boardID, elementID: source.id), element: source)
        return (.init(plane: plane, elementID: source.id), cut)
      }
      return try await withThrowingTaskGroup(of: (SceneSourceAddress, SceneRasterCut?).self) { group in
        var result: [SceneSourceAddress: SceneRasterCut] = [:]
        // All originals remain retained through the canonical cover painter,
        // so serial waves cannot lower their final admitted physical footprint.
        // Each existing executor still reserves its full bytes before submit.
        for source in sources { group.addTask { try await capture(source) } }
        while let (address, cut) = try await group.next() {
          if let cut { result[address] = cut }
        }
        return result
      }
    }

    private func resetCoverHostGeometry() {
      coverHost.view.layer.transform = CATransform3DIdentity
      coverHost.view.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      coverHost.view.layer.position = CGPoint(
        x: view.bounds.midX,
        y: view.bounds.midY
      )
    }

    private func showEndpointUntilSnapshotIsReady() {
      resetCoverHostGeometry()
      coverVisibilityView.isHidden = false
      coverVisibilityView.alpha = lifecycle.lastSettledEndpoint == .open
        ? CoverOpeningPhysics.warmCoverOpacity : 1
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
        return lifecycle.isTransitioning || (preparesCoverMotion && canPrepare()
          && SceneRenderResources.shared.allowsOptionalPreparation)
      }
      curlView.onCoverRenderingReady = { [weak self] in self?.renderCurrentState() }
      curlView.onCoverRenderFailure = { [weak self] _ in
        guard let self else { return }
        curlView.releaseSource()
        showEndpointUntilSnapshotIsReady()
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
        curlView.releaseSource()
        resetCoverHostGeometry()
        coverHost.isHidden = false
        coverHost.alphaValue = 1
        prepareRestingCoverIfNeeded()
        return
      }
      if CoverOpeningPhysics.isOpen(lifecycle.progress) {
        lifecycle.settleAtOpenEndpoint()
        curlView.releaseSource()
        resetCoverHostGeometry()
        coverHost.isHidden = false
        coverHost.alphaValue = CoverOpeningPhysics.warmCoverOpacity
        curlView.isHidden = true
        return
      }

      if lifecycle.capturedCover == nil {
        lifecycle.storeCapturedCover(captureCover())
      }
      guard let capturedCover = lifecycle.capturedCover else {
        showEndpointUntilSnapshotIsReady()
        return
      }
      guard curlView.prepareCoverRendering() else {
        showEndpointUntilSnapshotIsReady()
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
      guard preparesCoverMotion, canPrepare(), SceneRenderResources.shared.allowsOptionalPreparation else { return }
      if lifecycle.needsCurrentSnapshot {
        SheetCurlGPU.shared.requestCoverPreparation()
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

    private func showEndpointUntilSnapshotIsReady() {
      resetCoverHostGeometry()
      coverHost.isHidden = false
      coverHost.alphaValue = lifecycle.lastSettledEndpoint == .open
        ? CoverOpeningPhysics.warmCoverOpacity : 1
      curlView.isHidden = true
    }
  }
#endif
