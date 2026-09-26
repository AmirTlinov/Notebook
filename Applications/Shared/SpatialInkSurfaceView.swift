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
  private final class WeakCanvas {
    weak var view:InkCanvasView?
    #if os(iOS)
    weak var pose:WorkspaceItemPoseController?
    #endif
  }
  private var canvases:[SurfaceID:WeakCanvas]=[:]
  #if os(iOS)
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
    private var installedSceneSurfaces: Set<SurfaceID> = []
    private var sceneResources: SceneRenderResources?
    private var installedRootBoardID: UUID?
    private var installedFocusedCoverID: UUID?
    private var preparingSceneInk: UUID?
    private var sceneInkWaiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?
    private(set) var sceneInkIsStopped = false
    var registeredPhysicalInkOwnerCount: Int { physicalInkOwners.count }
    private(set) var activeBoardInkID: UUID?
    private(set) var activeBoardInkMount: UUID?

    func hasActiveAction(on surface: SurfaceID) -> Bool { activeSurfaces.contains(surface) }
    func hasContact(on surface: SurfaceID) -> Bool { retainedCanvases[surface] != nil }

    @discardableResult
    func activateBoardInk(_ id: UUID, mount: UUID) -> Bool {
      guard !sceneInkIsStopped, installedSceneSurfaces.contains(.board(id)), setSceneAllocationPriorities(rootBoardID: id,
        focusedCoverID: id == installedRootBoardID ? installedFocusedCoverID : nil) else { return false }
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
    func installSceneAllocationPriorities(rootBoardID: UUID, focusedCoverID: UUID?, surfaces: Set<SurfaceID>) throws {
      guard setSceneAllocationPriorities(rootBoardID: rootBoardID, focusedCoverID: focusedCoverID, surfaces: surfaces)
      else { throw SceneRenderError.resourceLimit }
      installedSceneSurfaces = surfaces
      installedRootBoardID = rootBoardID
      installedFocusedCoverID = focusedCoverID
    }

    private func setSceneAllocationPriorities(rootBoardID: UUID, focusedCoverID: UUID?, surfaces: Set<SurfaceID>? = nil) -> Bool {
      guard let sceneResources else { return physicalInkOwners.isEmpty }
      var priorities: [ScenePhysicalOwner: SceneAllocationPriority] = [:]
      // Mounted updates govern only the installed cohort. They cannot demote
      // an incoming input canvas during an await, or reclassify retiring input
      // before replacement makes its release possible. Those actual bytes stay
      // charged to their existing role until their last physical lease ends.
      for surface in surfaces ?? installedSceneSurfaces {
        guard let owner = physicalInkOwners[surface]?.owner else { continue }
        // An open physical paper is the next Pencil owner even between
        // contacts. Its existing backing must not consume the passive budget
        // a document needs to prepare that very paper's visible content.
        let focused = focusedCoverID.map { surface == .cover($0) } ?? false
        priorities[owner.resourceIdentity] = surface == .board(rootBoardID) || focused || activeSurfaces.contains(surface) ? .input : .passive
      }
      return sceneResources.updatePhysicalPriorities(priorities)
    }

    /// Only actual native ink allocations consume physical permits. Raster-only
    /// elements do not. Every required canvas is ready before the candidate may
    /// replace the old cohort; refusal cannot publish a cover with missing ink.
    func prepareSceneInk(plan: SceneCompositionPlan, frame: WorkspaceSceneFrame,
      liveData: SceneCompositionLiveData, resources: SceneRenderResources,
      displayScale: Double, refinesDetails: Bool = true) async throws -> SpatialInkSceneLease {
      let preparation = try await acquireSceneInkPreparation()
      defer { releaseSceneInkPreparation(preparation) }
      // The paint plan may remain installed across a native-only refill.
      // Its admitted owners stay fixed; their backing follows this request's
      // current camera, never the old paint basis.
      guard !sceneInkIsStopped, let root = frame.presences[plan.rootBoardID] else { throw CancellationError() }
      guard sceneResources == nil || sceneResources === resources else { throw SceneRenderError.resourceLimit }
      sceneResources = resources
      physicalInkOwners = physicalInkOwners.filter { $0.value.owner != nil }
      let focusedCoverID = root.focusedItemID.flatMap { id in
        frame.workset(boardID: plan.rootBoardID).items.first { $0.id == id && $0.item.kind != .board }?.id
      }
      // The same physical canvas covers the current screen and its portal at
      // handoff. A different orientation is an ordinary staged layout change,
      // not an extra screen's worth of native backing reserved by every board.
      let projected = BoardPortalProjection.renderViewport(viewport: root.viewport)
      // The aspect calculation can round its limiting side down by one ULP
      // (834 * (512 / 834) < 512). Backing must contain the requested crop,
      // not make contact admission forgive an actually smaller native extent.
      let boardSize = InkCanvasView.sceneBackingSize(viewport: .init(
        x: max(root.viewport.x, projected.x), y: max(root.viewport.y, projected.y)), displayScale: displayScale)
      var requested: [(SurfaceID, SpatialPoint, SpatialCamera, SpatialPoint)] = []
      for id in plan.inkBoardIDs.sorted() {
        guard let presence = frame.presences[id] else { throw SceneRenderError.snapshotPending("native_ink_source") }
        requested.append((.board(id), boardSize, presence.camera, presence.viewport))
      }
      for live in plan.liveOwners {
        guard case .item(let id) = live.id,
          let item = frame.workset(boardID: live.plane.boardID).items.first(where: { $0.id == id }) else { continue }
        let size = SpatialPoint(x: item.geometry.width, y: item.geometry.height)
        requested.append((.cover(id), size, .init(), size))
      }
      var owners: [SurfaceID: SpatialInkPhysicalOwner] = [:]
      var updates: [SpatialInkSceneLease.Update] = []
      var created: [SpatialInkPhysicalOwner] = []
      do {
        for (surface, size, camera, viewport) in requested {
          try Task.checkCancellation()
          let previous = physicalInkOwners[surface]?.owner
          let installed = previous?.canvas.installedSpatialSource
          let generation = previous?.canvas.spatialSourceGeneration ?? 0
          let journal = liveData.ink
          let ordered=liveData.orderedInk[surface] ?? .init()
          let suppressed = liveData.suppressedInkIDs.isEmpty ? Set<UUID>() : liveData.suppressedInkIDs.intersection(
            journal.actions.filter { $0.spans.contains { $0.surface == surface } }.map(\.id))
          let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let source = try installed?.reconciled(with: journal)
              ?? SpatialInkJournal(actions: journal.actions.filter { $0.spans.contains { $0.surface == surface } }, stamp: journal.stamp)
            // Baseline IDs prove the addressed read behind a capture, not
            // paint. An echoed tail or another equal window must not rebuild
            // the same mesh solely because that provenance moved to SQL.
            let unchanged = try installed?.referenceInk().actions == NotebookReferenceInk(surface: surface, actions: source.actions).actions
              && installed?.suppressedInkIDs == suppressed
            let mesh = unchanged ? nil : try SpatialInkMesh.prepare(surface: surface, journal: source, suppressedInkIDs: suppressed)
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
            let focused = focusedCoverID.map { surface == .cover($0) } ?? false
            let priority: SceneAllocationPriority = surface == .board(plan.rootBoardID) || focused ? .input : .passive
            let admission = resources.reservePhysicalOwners([identity], priority: priority)
            owner = .init(surface: surface, size: size, camera: camera,
              registry: self, resources: resources, displayScale: displayScale, physical: admission)
            created.append(owner)
            physicalInkOwners[surface] = WeakOwner(owner)
          }
          owners[surface] = owner
          let staged: InkCanvasView.PreparedFrame?
          if previous == nil || prepared.1 != nil || owner.canvas.orderedInkPlan != ordered || owner.canvas.needsSpatialTarget(size: size, displayScale: displayScale)
            || (surface.kind == .board && owner.needsProjection(camera: camera,
              viewport: viewport, refinesDetails: refinesDetails)) {
            staged = try await owner.canvas.prepareFrame(.spatial(prepared.1,size:size,displayScale:displayScale,camera:surface.kind == .board ? camera : nil,ordered:ordered))
          }
          else { staged = nil }
          updates.append(.init(owner: owner, generation: owner.canvas.spatialSourceGeneration,
            frame: staged, journal: prepared.0, suppressedInkIDs: suppressed))
        }
        try Task.checkCancellation()
        return .init(registry: self, rootBoardID: plan.rootBoardID, focusedCoverID: focusedCoverID,
          owners: owners, updates: updates)
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
      installedSceneSurfaces.removeAll()
      installedRootBoardID = nil; sceneResources = nil
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
        if let root = activeBoardInkID ?? installedRootBoardID {
          _ = setSceneAllocationPriorities(rootBoardID: root,
            focusedCoverID: root == installedRootBoardID ? installedFocusedCoverID : nil)
        }
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

  func register(_ view:InkCanvasView,for surface:SurfaceID) {
    let entry=canvases[surface] ?? WeakCanvas();entry.view=view;canvases[surface]=entry
    #if os(iOS)
    if !activeSurfaces.contains(surface),let layers=deferredLayers.removeValue(forKey:surface) {
      install(layers,on:surface,in:view)
    }
    #endif
  }
  func unregister(_ view:InkCanvasView,for surface:SurfaceID) {
    guard canvases[surface]?.view === view else {return}
    canvases[surface]?.view=nil
    #if os(iOS)
    if canvases[surface]?.pose != nil {return}
    #endif
    canvases.removeValue(forKey:surface)
  }
  func canvas(for surface:SurfaceID)->InkCanvasView? {
    #if os(iOS)
    if let retained=retainedCanvases[surface] {return retained.view}
    #endif
    if let view=canvases[surface]?.view {return view}
    #if os(iOS)
    if canvases[surface]?.pose != nil {return nil}
    #endif
    canvases.removeValue(forKey:surface);return nil
  }
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
  @Environment(NotebookAppModel.self) private var model
  let surface: SurfaceID
  let journal: SpatialInkJournal?
  var ordered:NotebookOrderedInkPlan = .init()
  var camera: SpatialCamera? = nil
  var viewport: SpatialPoint? = nil

  @MainActor final class Coordinator {
    let mesh=SpatialInkMeshPreparation()
    private var task:Task<Void,Never>?
    private var generation=UUID()
    private var prepared:SpatialInkMesh?
    private var source:SpatialInkJournal?
    private var sourcePending=false
    private var plan=NotebookOrderedInkPlan()
    private var projection:SpatialCamera?
    private var size=SpatialPoint.zero
    private var scale:Double=1
    private var surface:SurfaceID?
    private weak var registry:SpatialInkSurfaceRegistry?
    private weak var canvas:InkCanvasView?

    func update(_ view:InkCanvasView,surface:SurfaceID,journal:SpatialInkJournal?,ordered:NotebookOrderedInkPlan,
      camera:SpatialCamera?,viewport:SpatialPoint,registry:SpatialInkSurfaceRegistry) {
      if let previous=self.surface,previous != surface {self.registry?.unregister(view,for:previous)}
      self.registry=registry;canvas=view;registry.register(view,for:surface)
      let scale=view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 1
      let changed=plan != ordered || projection != camera || size != viewport || self.scale != scale
      plan=ordered;projection=camera;size=viewport;self.scale=scale;self.surface=surface
      if changed,task != nil {generation=UUID();task?.cancel();task=nil}
      view.project(camera:camera,viewport:viewport)
      _=mesh.update(surface:surface,journal:journal) { [weak self,weak view] next,source in
        guard let self,let view,self.surface == surface else {return}
        if let next {prepared=next};self.source=source;sourcePending=true
        generation=UUID();task?.cancel();task=nil
        installIfNeeded(view)
      }
      installIfNeeded(view)
    }
    private func installIfNeeded(_ view:InkCanvasView) {
      guard task == nil,let surface,size.x>0,size.y>0,
        sourcePending || plan != view.orderedInkPlan else {return}
      guard source != nil || plan == .init() else {return}
      // The established raw-only path remains free of ordered staging on
      // camera motion. A represented contact replaces one whole physical frame.
      if plan == .init(),view.orderedInkPlan == .init() {
        if let prepared {view.applySpatial(prepared)} else {view.finishSpatialPreparation()}
        view.installSpatialSource(source,on:surface,suppressedInkIDs:plan.suppressedInkIDs)
        view.updateOrderedInk(plan);prepared=nil;sourcePending=false;return
      }
      let id=UUID();generation=id
      let plan=plan,prepared=prepared,source=source,size=size,scale=scale,camera=projection
      task=Task { [weak self,weak view] in
        guard let self,let view else {return}
        defer {if generation == id {task=nil}}
        do {
          let frame=try await view.prepareFrame(.spatial(prepared,size:size,displayScale:scale,camera:camera,ordered:plan))
          try Task.checkCancellation()
          guard generation == id,frame.isValid else {frame.cancel();return}
          view.installPreparedFrame(frame,spatialSource:source.map { .init(surface:surface,journal:$0,suppressedInkIDs:plan.suppressedInkIDs) })
          self.prepared=nil;sourcePending=false
        } catch { /* The next ordinary update retries; the displayed frame remains whole. */ }
      }
    }
    func cancel() {
      generation=UUID();task?.cancel();task=nil;mesh.cancel();prepared=nil;source=nil
      if let canvas,let surface {registry?.unregister(canvas,for:surface)}
      registry=nil;canvas=nil
    }
    isolated deinit {task?.cancel()}
  }
  func makeCoordinator() -> Coordinator {Coordinator()}
  func makeNSView(context: Context) -> InkCanvasView {InkCanvasView(frame:.zero)}
  func updateNSView(_ view: InkCanvasView, context: Context) {
    context.coordinator.update(view,surface:surface,journal:journal,ordered:ordered,camera:camera,
      viewport:viewport ?? .init(x:view.bounds.width,y:view.bounds.height),registry:model.compositionTiles.surfaceRegistry)
  }
  static func dismantleNSView(_ view:InkCanvasView,coordinator:Coordinator) {
    coordinator.cancel();Task {await view.finishSpatialHandoffFrames()}
  }
}

#endif
