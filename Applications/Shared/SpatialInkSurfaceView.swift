import PencilKit
import SwiftUI
import NotebookCore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Connects the window-level Pencil recognizer to the Metal canvas carried by
/// each physical surface. The registry routes samples; it never draws them.
@MainActor
final class SpatialInkSurfaceRegistry {
  #if os(iOS)
    private final class WeakCanvas {
      weak var view: InkCanvasView?
      weak var pose: WorkspaceItemPoseController?

      init(_ view: InkCanvasView? = nil) {
        self.view = view
      }
    }

    private var canvases: [SurfaceID: WeakCanvas] = [:]
    private var retainedCanvases: [SurfaceID: (view: InkCanvasView, count: Int)] = [:]
    private var activeSurfaces: Set<SurfaceID> = []
    private struct PreparedSource {
      let mesh: SpatialInkMesh?
      let journal: SpatialInkJournal?
    }
    private var deferredLayers: [SurfaceID: PreparedSource] = [:]
    private final class WeakOwner {
      weak var owner: SpatialInkPhysicalOwner?
      init(_ owner: SpatialInkPhysicalOwner) { self.owner = owner }
    }
    private var physicalInkOwners: [SurfaceID: WeakOwner] = [:]
    private var sceneResources: SceneRenderResources?
    private var installedRootBoardID: UUID?
    private var preparingSceneInk: UUID?
    private var sceneInkWaiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    private var inkParking: UIWindow?
    private(set) var sceneInkIsStopped = false
    var registeredPhysicalInkOwnerCount: Int { physicalInkOwners.count }
    private(set) var activeBoardInkID: UUID?
    private(set) var activeBoardInkMount: UUID?

    func hasActiveAction(on surface: SurfaceID) -> Bool { activeSurfaces.contains(surface) }
    func hasContact(on surface: SurfaceID) -> Bool { retainedCanvases[surface] != nil }

    @discardableResult
    func activateBoardInk(_ id: UUID, mount: UUID) -> Bool {
      guard !sceneInkIsStopped, setSceneAllocationPriorities(rootBoardID: id) else { return false }
      let changed = activeBoardInkID != id || activeBoardInkMount != mount
      activeBoardInkID = id; activeBoardInkMount = mount
      if changed { for entry in physicalInkOwners.values { entry.owner?.refreshMount() } }
      return true
    }
    func deactivateBoardInk(mount: UUID) {
      guard activeBoardInkMount == mount else { return }
      activeBoardInkID = nil; activeBoardInkMount = nil
      for entry in physicalInkOwners.values { entry.owner?.refreshMount() }
    }

    /// One atomic role exchange for already allocated resources. It does not
    /// walk geometry, revoke an accepted contact or temporarily charge both
    /// boards as passive during a native parent/child transfer.
    func installSceneAllocationPriorities(rootBoardID: UUID) throws {
      guard setSceneAllocationPriorities(rootBoardID: rootBoardID)
      else { throw SceneRenderError.resourceLimit }
      installedRootBoardID = rootBoardID
    }

    private func setSceneAllocationPriorities(rootBoardID: UUID) -> Bool {
      guard let sceneResources else { return physicalInkOwners.isEmpty }
      var priorities: [ScenePhysicalOwner: SceneAllocationPriority] = [:]
      for (surface, entry) in physicalInkOwners {
        guard let owner = entry.owner else { continue }
        priorities[owner.resourceIdentity] = surface == .board(rootBoardID) || activeSurfaces.contains(surface) ? .input : .passive
      }
      return sceneResources.updatePhysicalPriorities(priorities)
    }

    func parkSceneCanvas(_ canvas: InkCanvasView) {
      guard !sceneInkIsStopped else { return }
      guard canvas.hasSpatialInkGeometry else { canvas.removeFromSuperview(); return }
      if inkParking == nil {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .first(where: { $0.activationState == .foregroundActive }) else { return }
        let window = NotebookPreparationWindow(windowScene: scene)
        let host = UIViewController()
        host.view.backgroundColor = .clear; host.view.isUserInteractionEnabled = false
        host.view.accessibilityElementsHidden = true
        window.rootViewController = host
        window.frame = .init(x: -20_000 - canvas.bounds.width, y: -20_000 - canvas.bounds.height,
          width: canvas.bounds.width, height: canvas.bounds.height)
        window.isUserInteractionEnabled = false; window.isHidden = false
        inkParking = window
      }
      if let host = inkParking?.rootViewController?.view, canvas.superview !== host {
        host.addSubview(canvas); canvas.center = .init(x: canvas.bounds.midX, y: canvas.bounds.midY)
      }
    }

    /// Only actual native ink allocations consume physical permits. Raster-only
    /// elements do not. Every required canvas is ready before the candidate may
    /// replace the old cohort; refusal cannot publish a cover with missing ink.
    func prepareSceneInk(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame,
      liveData: SceneCompositionLiveData, resources: SceneRenderResources,
      displayScale: Double) async throws -> SpatialInkSceneLease {
      let preparation = try await acquireSceneInkPreparation()
      defer { releaseSceneInkPreparation(preparation) }
      guard !sceneInkIsStopped, let root = plan.presentations[.board(plan.rootBoardID)] else { throw CancellationError() }
      guard sceneResources == nil || sceneResources === resources else { throw SceneRenderError.resourceLimit }
      sceneResources = resources
      physicalInkOwners = physicalInkOwners.filter { $0.value.owner != nil }
      let side = max(root.viewport.x, root.viewport.y)
      let projected = BoardPortalProjection.renderViewport(viewport: .init(x: side, y: side))
      // The aspect calculation can round its limiting side down by one ULP
      // (834 * (512 / 834) < 512). Backing must contain the requested crop,
      // not make contact admission forgive an actually smaller native extent.
      let boardSize = SpatialPoint(x: max(side, projected.x), y: max(side, projected.y))
      var requested: [(SurfaceID, SpatialPoint, SpatialCamera)] = []
      for id in plan.inkBoardIDs.sorted() {
        guard let presence = plan.presentations[.board(id)] else { throw SceneRenderError.snapshotPending("native_ink_source") }
        requested.append((.board(id), boardSize, presence.camera))
      }
      for live in plan.liveOwners {
        guard case .item(let id) = live.id,
          let item = frame.workset(boardID: live.plane.boardID).items.first(where: { $0.id == id }) else { continue }
        requested.append((.cover(id), .init(x: item.geometry.width, y: item.geometry.height), .init()))
      }
      var owners: [SurfaceID: SpatialInkPhysicalOwner] = [:]
      var updates: [SpatialInkSceneLease.Update] = []
      var created: [SpatialInkPhysicalOwner] = []
      do {
        for (surface, size, camera) in requested {
          try Task.checkCancellation()
          let previous = physicalInkOwners[surface]?.owner
          let installed = previous?.canvas.installedSpatialSource
          let generation = previous?.canvas.spatialSourceGeneration ?? 0
          let journal = liveData.ink
          let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let source = try installed?.reconciled(with: journal)
              ?? SpatialInkJournal(actions: journal.actions.filter { $0.spans.contains { $0.surface == surface } }, stamp: journal.stamp)
            let unchanged = try installed?.referenceInk() == NotebookReferenceInk(surface: surface, actions: source.actions)
            let mesh = unchanged ? nil : try SpatialInkMesh.prepare(surface: surface, journal: source)
            try Task.checkCancellation()
            return (source, mesh)
          }
          let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
          try Task.checkCancellation()
          guard !sceneInkIsStopped, physicalInkOwners[surface]?.owner === previous,
            (previous?.canvas.spatialSourceGeneration ?? 0) == generation, !activeSurfaces.contains(surface) else { throw CancellationError() }
          let owner: SpatialInkPhysicalOwner
          if let previous { owner = previous }
          else {
            guard let id = surface.ownerID else { throw SceneRenderError.snapshotPending("native_ink_identity") }
            let identity: ScenePhysicalOwner = surface.kind == .board ? .boardInk(id) : .item(id)
            let inputBoard = activeBoardInkID ?? installedRootBoardID ?? plan.rootBoardID
            let priority: SceneAllocationPriority = surface == .board(inputBoard) ? .input : .passive
            guard let admission = resources.reservePhysicalOwners([identity], priority: priority) else { throw SceneRenderError.resourceLimit }
            owner = .init(surface: surface, size: size, camera: camera,
              registry: self, resources: resources, displayScale: displayScale, physical: admission)
            created.append(owner)
            physicalInkOwners[surface] = WeakOwner(owner)
            owner.prepareNew(mesh: prepared.1 ?? .init(batches: []), journal: prepared.0)
            let deadline = ContinuousClock.now + .seconds(5)
            while !owner.canvas.isStableFramePresented {
              try Task.checkCancellation()
              if let failure = owner.canvas.renderFailure { throw failure }
              guard !sceneInkIsStopped, ContinuousClock.now < deadline else { throw SceneRenderError.snapshotPending("native_ink_frame") }
              try await Task.sleep(for: .milliseconds(5))
            }
          }
          owners[surface] = owner
          let staged: InkCanvasView.PreparedSpatialFrame?
          if previous != nil, prepared.1 != nil || owner.canvas.needsSpatialTarget(size: size, displayScale: displayScale) {
            staged = try await owner.canvas.prepareSpatialFrame(prepared.1, size: size, displayScale: displayScale)
          }
          else { staged = nil }
          updates.append(.init(owner: owner, generation: owner.canvas.spatialSourceGeneration,
            frame: staged, journal: prepared.0))
        }
        try Task.checkCancellation()
        return .init(registry: self, rootBoardID: plan.rootBoardID, owners: owners, updates: updates)
      } catch {
        updates.removeAll()
        // A cancelled first frame cannot release its accounting before Metal
        // completes, nor can the next candidate reuse a half-stopped owner.
        // Existing displayed owners are deliberately absent from this list.
        for owner in created {
          await owner.stop()
          if physicalInkOwners[owner.surface]?.owner === owner { physicalInkOwners[owner.surface] = nil }
        }
        throw error
      }
    }

    private func acquireSceneInkPreparation() async throws -> UUID {
      try Task.checkCancellation()
      guard !sceneInkIsStopped else { throw CancellationError() }
      let id = UUID()
      if preparingSceneInk == nil { preparingSceneInk = id; return id }
      let acquired = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          guard !Task.isCancelled else { continuation.resume(returning: false); return }
          // There is one scene producer. A newer requested cohort replaces its
          // still-waiting candidate, never the prepared/shown physical owner.
          sceneInkWaiter?.continuation.resume(returning: false)
          sceneInkWaiter = (id, continuation)
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          guard self?.sceneInkWaiter?.id == id else { return }
          self?.sceneInkWaiter?.continuation.resume(returning: false)
          self?.sceneInkWaiter = nil
        }
      }
      guard acquired else { throw CancellationError() }
      return id
    }

    private func releaseSceneInkPreparation(_ id: UUID) {
      guard preparingSceneInk == id else { return }
      let next = sceneInkWaiter; sceneInkWaiter = nil
      preparingSceneInk = next?.id
      next?.continuation.resume(returning: true)
    }

    func stopSceneInk() async {
      sceneInkIsStopped = true
      sceneInkWaiter?.continuation.resume(returning: false); sceneInkWaiter = nil
      activeBoardInkID = nil; activeBoardInkMount = nil
      let owners = physicalInkOwners.values.compactMap(\.owner)
      for owner in owners { await owner.stop() }
      physicalInkOwners.removeAll()
      installedRootBoardID = nil; sceneResources = nil
      inkParking?.isHidden = true; inkParking?.rootViewController = nil; inkParking = nil
    }

    func register(_ view: InkCanvasView, for surface: SurfaceID) {
      canvases = canvases.filter { $0.value.view != nil || $0.value.pose != nil }
      let entry = canvases[surface] ?? WeakCanvas()
      entry.view = view; canvases[surface] = entry
      if !activeSurfaces.contains(surface),
        let layers = deferredLayers.removeValue(forKey: surface)
      {
        install(layers, on: surface, in: view)
      }
    }

    func unregister(_ view: InkCanvasView, for surface: SurfaceID) {
      guard canvases[surface]?.view === view else { return }
      canvases[surface]?.view = nil
      if canvases[surface]?.pose == nil { canvases.removeValue(forKey: surface) }
    }

    func canvas(for surface: SurfaceID) -> InkCanvasView? {
      if let retained = retainedCanvases[surface] { return retained.view }
      guard let view = canvases[surface]?.view else {
        if canvases[surface]?.pose == nil { canvases.removeValue(forKey: surface) }
        return nil
      }
      return view
    }

    func registerPose(_ pose: WorkspaceItemPoseController, for surface: SurfaceID) {
      let entry = canvases[surface] ?? WeakCanvas()
      entry.pose = pose; canvases[surface] = entry
    }

    func unregisterPose(_ pose: WorkspaceItemPoseController, for surface: SurfaceID) {
      guard canvases[surface]?.pose === pose else { return }
      canvases[surface]?.pose = nil
      if canvases[surface]?.view == nil { canvases[surface] = nil }
    }

    func pose(for surface: SurfaceID) -> WorkspaceItemPoseController? { canvases[surface]?.pose }

    func retirePhysicalOwner(_ id: UUID, on boardID: UUID, through revision: UInt64) {
      guard let pose = pose(for: .cover(id)), pose.boardID == boardID else { return }
      pose.retirePhysicalOwner(through: revision)
    }

    func isRetired(_ surface: SurfaceID) -> Bool { pose(for: surface)?.retiredAtRevision != nil }

    /// The existing physical registration is retained, not looked up again after
    /// every sample. A late replacement/unregister cannot redirect accepted ink.
    func acquireContact(on surface: SurfaceID, in coordinateView: UIView) -> ContactLease? {
      let pose = canvases[surface]?.pose
      let poseLease = pose?.acquirePose(in: coordinateView)
      if pose != nil && poseLease == nil { return nil }
      let canvas = canvas(for: surface)
      if let canvas {
        let count = retainedCanvases[surface]?.count ?? 0
        retainedCanvases[surface] = (canvas, count + 1)
      }
      return ContactLease(registry: self, surface: surface, canvas: canvas, pose: poseLease)
    }

    private func releaseContact(on surface: SurfaceID, canvas: InkCanvasView?) {
      guard let canvas, let retained = retainedCanvases[surface], retained.view === canvas else { return }
      if retained.count == 1 {
        retainedCanvases[surface] = nil
        physicalInkOwners[surface]?.owner?.refreshMount()
      }
      else { retainedCanvases[surface] = (canvas, retained.count - 1) }
    }

    @MainActor
    final class ContactLease {
      let canvas: InkCanvasView?
      let pose: WorkspaceItemPoseLease?
      private weak var registry: SpatialInkSurfaceRegistry?
      private let surface: SurfaceID
      fileprivate init(registry: SpatialInkSurfaceRegistry, surface: SurfaceID,
        canvas: InkCanvasView?, pose: WorkspaceItemPoseLease?) {
        self.registry = registry; self.surface = surface; self.canvas = canvas; self.pose = pose
      }
      func release() {
        registry?.releaseContact(on: surface, canvas: canvas); registry = nil
        pose?.release()
      }
      isolated deinit { release() }
    }

    func installedSource(on surface: SurfaceID) -> SpatialInkInstalledSource? {
      guard !activeSurfaces.contains(surface), let source = canvas(for: surface)?.installedSpatialSource,
        source.surface == surface else { return nil }
      return source
    }

    func installedSources() -> [SurfaceID: SpatialInkInstalledSource] {
      var result: [SurfaceID: SpatialInkInstalledSource] = [:]
      for surface in Array(canvases.keys) {
        if let source = installedSource(on: surface) { result[surface] = source }
      }
      return result
    }

    func beginAction(on surface: SurfaceID) {
      if let owner = physicalInkOwners[surface]?.owner {
        // Promotion releases passive pressure; it cannot revoke a previous
        // lease or require a sample walk on the first Pencil event.
        _ = sceneResources?.updatePhysicalPriorities([owner.resourceIdentity: .input])
      }
      if activeSurfaces.insert(surface).inserted { canvas(for: surface)?.beginSpatialAction() }
    }

    func finishAction(on surface: SurfaceID, keepingCommittedMesh: Bool, committedAction: SpatialInkAction? = nil) {
      activeSurfaces.remove(surface)
      canvas(for: surface)?.finishSpatialAction(keepingCommittedMesh: keepingCommittedMesh)
      defer {
        // A newly accepted tail is not discarded if its passive role cannot
        // yet fit beside the old picture. The next whole cohort retries this
        // reclassification; actual bytes remain in the same total ledger.
        if let root = activeBoardInkID ?? installedRootBoardID { _ = setSceneAllocationPriorities(rootBoardID: root) }
      }
      if keepingCommittedMesh {
        if let committedAction { canvas(for: surface)?.appendInstalledSpatialAction(committedAction) }
        deferredLayers.removeValue(forKey: surface)
        return
      }
      guard let layers = deferredLayers.removeValue(forKey: surface),
        let view = canvas(for: surface)
      else { return }
      install(layers, on: surface, in: view)
    }

    func applyStable(
      _ layers: SpatialInkMesh?,
      source: SpatialInkJournal?,
      to surface: SurfaceID,
      in view: InkCanvasView? = nil
    ) {
      if activeSurfaces.contains(surface) {
        deferredLayers[surface] = .init(mesh: layers, journal: source)
        return
      }
      if let view = view ?? canvas(for: surface) { install(.init(mesh: layers, journal: source), on: surface, in: view) }
    }

    private func install(_ prepared: PreparedSource, on surface: SurfaceID, in view: InkCanvasView) {
      if let mesh = prepared.mesh { view.applySpatial(mesh) } else { view.finishSpatialPreparation() }
      view.installSpatialSource(prepared.journal, on: surface)
    }
  #endif
}

#if os(iOS)
/// A cover mounts the native ink already admitted and prepared by its cohort.
/// No new canvas, mesh, or GPU allocation starts from a SwiftUI update.
struct SpatialInkSurfaceView: UIViewRepresentable {
  let surface: SurfaceID
  private weak var nativeInk: SpatialInkSceneLease?
  let boardID: UUID
  let isActive: Bool

  init(surface: SurfaceID, cohort: SceneCompositionCohort, boardID: UUID, isActive: Bool) {
    self.surface = surface; nativeInk = cohort.nativeInk
    self.boardID = boardID; self.isActive = isActive
  }

  func makeUIView(context: Context) -> SpatialInkPhysicalMountView { .init(frame: .zero) }
  func updateUIView(_ view: SpatialInkPhysicalMountView, context: Context) {
    // SwiftUI can cache this configuration after dismantle. Only the real
    // mounted UIView owns the lease; an expired update cannot replace its owner.
    guard let nativeInk else { return }
    view.update(lease: nativeInk, surface: surface, boardID: boardID, camera: .init(), active: isActive)
  }
  static func dismantleUIView(_ view: SpatialInkPhysicalMountView, coordinator: ()) { view.unmount() }
}
#elseif os(macOS)
struct SpatialInkSurfaceView: NSViewRepresentable {
  let surface: SurfaceID
  let journal: SpatialInkJournal?
  var camera: SpatialCamera? = nil
  var viewport: SpatialPoint? = nil

  func makeCoordinator() -> SpatialInkMeshPreparation { SpatialInkMeshPreparation() }
  func makeNSView(context: Context) -> InkCanvasView { InkCanvasView(frame: .zero) }
  func updateNSView(_ view: InkCanvasView, context: Context) {
    view.project(camera: camera, viewport: viewport ?? .init(x: view.bounds.width, y: view.bounds.height))
    let pending = context.coordinator.update(surface: surface, journal: journal) { [weak view] mesh, source in
      if let mesh { view?.applySpatial(mesh) } else { view?.finishSpatialPreparation() }
      view?.installSpatialSource(source, on: surface)
    }
    if pending { view.prepareForDrawing() }
  }
  static func dismantleNSView(_ view: InkCanvasView, coordinator: SpatialInkMeshPreparation) { coordinator.cancel() }
}

#endif
