#if os(iOS)
import NotebookCore
import SwiftUI
import UIKit

/// One native subtree owns the painted workspace. Input, attention marks and
/// application controls are siblings, so they cannot enter a source-region PNG.
struct NotebookWorkspacePresentation<Content: View>: UIViewControllerRepresentable {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.sceneComposition) private var composition
  let presence: SessionPresence
  let cohort: SceneCompositionCohort?
  let preparation: NotebookWorkspaceCompositionRequest
  let prepare: @MainActor () -> Void
  @ViewBuilder let content: () -> Content

  func makeUIViewController(context: Context) -> NotebookWorkspacePresentationController {
    NotebookWorkspacePresentationController()
  }
  func updateUIViewController(_ controller: NotebookWorkspacePresentationController, context: Context) {
    controller.update(model: model, presence: presence, cohort: cohort, preparation: preparation, prepare: prepare,
      // Only application dependencies cross this hosting boundary. Copying
      // EnvironmentValues wholesale also copies SwiftUI's private platform/
      // accessibility host state and hides this second tree from its window.
      content: AnyView(content().environment(model).environment(\.sceneComposition, composition)))
  }
  static func dismantleUIViewController(_ controller: NotebookWorkspacePresentationController, coordinator: ()) {
    controller.uninstall()
  }
}

/// The finite inputs of one requested composition, independent of the native
/// hosting update that delivers them to its single preparation task.
@MainActor
struct NotebookWorkspaceCompositionRequest: Equatable {
  /// Preparation admits the destination body, not its future camera window.
  /// Same-board motion keeps the ordinary bounded coverage of the actual view;
  /// another board has different world coordinates and retains its own demand.
  static func preparationPresence(target: SessionPresence?, visible: SessionPresence) -> SessionPresence {
    guard let target else { return visible }
    guard target.boardID == visible.boardID else { return target }
    return .init(boardID: target.boardID, mode: target.mode, camera: visible.camera,
      viewport: visible.viewport, focusedItemID: target.focusedItemID,
      openProgress: target.openProgress, documentPageIndex: target.documentPageIndex,
      selectedItemID: target.selectedItemID, notebookPageID: target.notebookPageID)
  }

  let presence: SessionPresence
  let generation: UUID?
  let publication: UInt64
  let revision: UInt64?
  let pinned: Set<WorkspaceSpatialID>
  let itemOwners: [UUID: UUID]
  let permitsPreparation: Bool
  let refinesDetails: Bool
  let groupPoses: [SceneCompositionPlane:[String:NotebookElementPlacement.Source]]
}

@MainActor
struct NotebookWorkspacePresentedSources: Equatable {
  let workspace: WorkspaceIndex
  let hierarchy: BoardHierarchy
  let staticInk: VersionStamp
  let installedInk: [SurfaceID: String]

  static func current(model: NotebookAppModel, cohort: SceneCompositionCohort) -> Self {
    .init(workspace: model.presentedWorkspace(cohort: cohort), hierarchy: model.presentedHierarchy(cohort: cohort),
      staticInk: cohort.liveData.ink.stamp,
      installedInk: model.compositionTiles.surfaceRegistry.installedSources().mapValues(\.journalRevision))
  }
}

/// A layout acknowledges actual content generations, not the collaboration
/// read epoch. All fields are constant-size or bounded by physical admission;
/// moving the camera must never project every stored item or board element.
@MainActor
private struct NotebookWorkspaceContentIdentity: Equatable {
  let geometryID: UUID
  let sourceRevision: UInt64
  let workspaceStamp: VersionStamp?
  let hierarchyStamp: VersionStamp?
  let inkStamp: VersionStamp?
  let indexGeneration: UInt64
  let publicationGeneration: UInt64
  let deletingOwners: Set<UUID>

  static func current(model: NotebookAppModel, cohort: SceneCompositionCohort) -> Self {
    var owners: Set<UUID> = [cohort.plan.rootBoardID]
    for owner in cohort.plan.liveOwners {
      owners.insert(owner.plane.boardID)
      if let id = owner.plane.coverID { owners.insert(id) }
      if case .item(let id) = owner.id { owners.insert(id) }
    }
    return .init(geometryID: cohort.geometryID, sourceRevision: cohort.plan.revision,
      workspaceStamp: model.workspace?.stamp, hierarchyStamp: model.boardHierarchy?.stamp,
      inkStamp: model.spatialInk?.stamp, indexGeneration: model.sceneIndexGeneration,
      publicationGeneration: model.scenePublicationGeneration,
      deletingOwners: Set(owners.filter { model.isItemBeingDeleted($0) }))
  }
}

@MainActor
final class NotebookWorkspacePresentationRegistry {
  private weak var owner: NotebookWorkspacePresentationController?
  func register(_ owner: NotebookWorkspacePresentationController) { self.owner = owner }
  func remove(_ owner: NotebookWorkspacePresentationController) { if self.owner === owner { self.owner = nil } }

  func capture(fragment: NotebookAttentionSelection.Fragment, expectedSources: NotebookWorkspacePresentedSources,
    resources: SceneRenderResources) throws -> NotebookSubmittedPixels? {
    try owner?.capture(fragment: fragment, expectedSources: expectedSources, resources: resources)
  }

  func captureFailure(fragment: NotebookAttentionSelection.Fragment, expectedSources: NotebookWorkspacePresentedSources) -> String? {
    guard let owner else { return "workspace_owner_unavailable" }
    return owner.captureFailure(fragment: fragment, expectedSources: expectedSources)
  }
}

@MainActor
final class NotebookWorkspacePresentationController: UIViewController, NotebookScenePresentationOwner {
  private weak var model: NotebookAppModel?
  private var host: NotebookPaintHostingController?
  private var presence: SessionPresence?
  private weak var cohort: SceneCompositionCohort?
  private var installedContent: NotebookWorkspaceContentIdentity?
  private var hasInstalledLayout = false
  private var retired = false
  private var preparationRequest: NotebookWorkspaceCompositionRequest?
  private var pendingPreparation: (@MainActor () -> Void)?
  private var preparationTask: Task<Void, Never>?

  override func loadView() {
    view = UIView(); view.backgroundColor = .clear; view.isOpaque = false
    view.clipsToBounds = true
    let host = NotebookPaintHostingController(rootView: AnyView(EmptyView()))
    host.safeAreaRegions = []; host.view.backgroundColor = .clear; host.view.isOpaque = false
    host.didLayout = { [weak self] in self?.hasInstalledLayout = true }
    self.host = host
    addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    host?.view.frame = view.bounds
  }

  func update(model: NotebookAppModel, presence: SessionPresence, cohort: SceneCompositionCohort?,
    preparation: NotebookWorkspaceCompositionRequest, prepare: @escaping @MainActor () -> Void, content: AnyView) {
    guard !retired else { return }
    loadViewIfNeeded()
    if self.model !== model {
      cancelPreparation()
      self.model?.workspacePresentations.remove(self)
      self.model?.unregisterScenePresentation(self)
      self.model = model; model.workspacePresentations.register(self); model.registerScenePresentation(self)
    }
    let contentIdentity = cohort.map { NotebookWorkspaceContentIdentity.current(model: model, cohort: $0) }
    let contentChanged = installedContent != contentIdentity
    if self.presence != presence || contentChanged { hasInstalledLayout = false }
    self.presence = presence; self.cohort = cohort; installedContent = contentIdentity
    view.accessibilityIdentifier = model.documentMeasurements.enabled ? "workspace-scene-state" : nil
    view.accessibilityValue = model.scenePreparationDiagnostic
    host?.rootView = content
    host?.view.setNeedsLayout()
    // A ready content cut must cross this hosting boundary in the same native
    // update, not wait another frame before the camera planes even see it.
    // Ordinary camera samples still update projection without forcing layout.
    if contentChanged { host?.view.layoutIfNeeded() }
    schedulePreparation(preparation, perform: prepare)
  }

  private func schedulePreparation(_ request: NotebookWorkspaceCompositionRequest,
    perform: @escaping @MainActor () -> Void) {
    guard preparationRequest != request else { return }
    preparationRequest = request
    pendingPreparation = perform
    guard preparationTask == nil else { return }
    // Native updates replace one pending request. Unlike a SwiftUI task-id
    // callback, publishing its result cannot suppress the next update this frame.
    preparationTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled, let self, !retired else { return }
      preparationTask = nil
      let perform = pendingPreparation
      pendingPreparation = nil
      perform?()
    }
  }

  private func cancelPreparation() {
    preparationTask?.cancel(); preparationTask = nil
    pendingPreparation = nil; preparationRequest = nil
  }

  func capture(fragment: NotebookAttentionSelection.Fragment, expectedSources: NotebookWorkspacePresentedSources,
    resources: SceneRenderResources) throws -> NotebookSubmittedPixels? {
    if let failure = captureFailure(fragment: fragment, expectedSources: expectedSources) {
      throw SceneRenderError.snapshotPending(failure)
    }
    guard let presence, let host else { return nil }
    let topLeft = presence.camera.screenToWorld(.zero, viewport: presence.viewport)
    let origin = (fragment.worldOrigin ?? .zero).delta(to: topLeft)
    return try NotebookSubmittedPixels.capture(view: host.view,
      physicalSize: .init(width: presence.viewport.x / presence.camera.scale, height: presence.viewport.y / presence.camera.scale),
      region: fragment.region, resources: resources, sourceOrigin: .init(x: origin.x, y: origin.y))
  }

  func captureFailure(fragment: NotebookAttentionSelection.Fragment, expectedSources: NotebookWorkspacePresentedSources) -> String? {
    guard !retired, let model, let host else { return "workspace_owner_unavailable" }
    guard hasInstalledLayout else { return "workspace_layout_pending" }
    guard fragment.target.kind == .board, fragment.elementID == nil else { return "workspace_region_unsupported" }
    guard model.presencePhase == .settled, let presence, presence.mode == .board,
      fragment.target.id == presence.boardID, model.presence == presence else { return "workspace_camera_changed" }
    guard let cohort, cohort === model.compositionTiles.published, cohort.isPaintInstalled else { return "workspace_paint_pending" }
    guard installedContent == NotebookWorkspaceContentIdentity.current(model: model, cohort: cohort) else { return "workspace_content_not_installed" }
    // Full frozen-source comparison belongs to explicit capture/readiness,
    // never updateUIViewController during camera motion.
    let current = NotebookWorkspacePresentedSources.current(model: model, cohort: cohort)
    guard current.workspace == expectedSources.workspace else { return "workspace_source_changed" }
    guard current.hierarchy == expectedSources.hierarchy else { return "workspace_placement_changed" }
    guard current.staticInk == expectedSources.staticInk,
      current.installedInk == expectedSources.installedInk else { return "workspace_ink_changed" }
    guard host.view.window != nil, view.bounds.width == presence.viewport.x,
      view.bounds.height == presence.viewport.y else { return "workspace_viewport_not_installed" }
    return nil
  }

  func uninstall() {
    guard !retired else { return }
    retired = true; hasInstalledLayout = false; presence = nil; cohort = nil; installedContent = nil
    cancelPreparation()
    model?.workspacePresentations.remove(self); model?.unregisterScenePresentation(self); model = nil
    host?.didLayout = { }
    host?.willMove(toParent: nil); host?.view.removeFromSuperview(); host?.removeFromParent(); host = nil
  }
}

@MainActor
private final class NotebookPaintHostingController: UIHostingController<AnyView> {
  var didLayout: () -> Void = { }
  override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); didLayout() }
}
#endif
