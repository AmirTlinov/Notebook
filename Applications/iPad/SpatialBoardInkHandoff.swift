import NotebookCore
import SwiftUI
import UIKit

/// A cohort keeps the physical boards it excluded from its static painter.
/// Preparation is private; install validates every source generation before
/// changing any displayed canvas in the same main-actor publication turn.
@MainActor
final class SpatialInkSceneLease {
  struct Update {
    let owner: SpatialInkPhysicalOwner
    let generation: UInt64
    let frame: InkCanvasView.PreparedFrame?
    let journal: SpatialInkJournal
    var suppressedInkIDs: Set<UUID> = []
    var coverVisibleRegion: CGRect?
  }
  let registry: SpatialInkSurfaceRegistry
  let rootBoardID: UUID
  let focusedCoverID: UUID?
  let owners: [SurfaceID: SpatialInkPhysicalOwner]
  private var updates: [Update]
  private(set) var isInstalled = false
  init(registry: SpatialInkSurfaceRegistry, rootBoardID: UUID, focusedCoverID: UUID?, owners: [SurfaceID: SpatialInkPhysicalOwner],
    updates: [Update]) {
    self.registry = registry; self.rootBoardID = rootBoardID; self.owners = owners; self.updates = updates
    self.focusedCoverID = focusedCoverID
  }
  func install(projecting currentFrame: WorkspaceSceneFrame? = nil) throws {
    guard !registry.sceneInkIsStopped,
      updates.allSatisfy({ update in
        update.owner.canvas.spatialSourceGeneration == update.generation
          && (update.frame?.isValid ?? true)
      }) else {
      // A superseded source/preparation cannot keep a staging slot. Revocation
      // retains submitted buffers and drawables until their GPU completion.
      for update in updates { update.frame?.cancel() }
      throw CancellationError()
    }
    // A retained contact can outlive its last sample. It postpones this valid
    // candidate without revoking it; the same caller may install after release.
    guard updates.allSatisfy({
      !registry.hasActiveAction(on: $0.owner.surface) && !registry.hasContact(on: $0.owner.surface)
    }) else { throw CancellationError() }
    guard updates.allSatisfy({ update in
        // Native motion can reverse while the private GPU candidate prepares.
        // Keep the shown crop until a candidate covers the current destination;
        // the same scene producer already holds the latest pending demand.
        let projection: SpatialInkCoverProjection?
        if update.owner.surface.kind == .cover, let id = update.owner.surface.ownerID, let currentFrame {
          // Coverage is in paper coordinates; display density does not change
          // this witness. The latest scene request also covers camera reversal.
          projection = registry.coverProjection(itemID: id, frame: currentFrame, displayScale: 1)
        } else { projection = registry.movingCoverProjection(on: update.owner.surface) }
        guard let visible = projection?.visible ?? update.coverVisibleRegion else { return true }
        if let frame = update.frame { return frame.containsSpatialRegion(visible) }
        return visible.isEmpty || update.owner.canvas.spatialBackingRegion?.contains(visible) == true
      }) else {
      // This candidate is obsolete, not waiting for a retained contact. Clear
      // its staging IDs now; revoke keeps submitted resources until GPU drain.
      for update in updates { update.frame?.cancel() }
      throw CancellationError()
    }
    try registry.installSceneAllocationPriorities(rootBoardID: rootBoardID, focusedCoverID: focusedCoverID,
      surfaces: Set(owners.keys))
    // A new GPU basis and the native projection of those pixels are one
    // transaction. Camera motion itself only transforms the installed basis.
    CATransaction.begin(); CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for update in updates {
      if let frame = update.frame {
        update.owner.canvas.installPreparedFrame(frame,spatialSource:.init(surface:update.owner.surface,journal:update.journal,suppressedInkIDs:update.suppressedInkIDs))
        update.owner.refreshMount()
      }
    }
    updates.removeAll(); isInstalled = true
  }

  isolated deinit {
    // GPU completion retains PreparedFrame, not this lease. Abandoning a
    // candidate must free its staging slot immediately while submitted GPU
    // resources remain charged until their existing completion callback.
    for update in updates { update.frame?.cancel() }
  }

  func containsProjectionWindows(presence: SessionPresence, frame: WorkspaceSceneFrame,
    displayScale: Double, refinesDetails: Bool) -> Bool {
    for (surface, owner) in owners {
      guard let id = surface.ownerID else { return false }
      let density: Double
      if surface.kind == .board {
        guard let current = id == presence.boardID ? presence : frame.presences[id] else { return false }
        if owner.needsProjection(camera: current.camera, viewport: current.viewport,
          refinesDetails: refinesDetails) { return false }
        density = displayScale
      } else {
        guard let projection = registry.coverProjection(itemID: id, frame: frame, displayScale: displayScale),
          owner.canvas.containsSpatialRegion(projection.visible) else { return false }
        density = projection.density
      }
      if owner.canvas.needsSpatialDensity(density, refinesDetails: refinesDetails) { return false }
    }
    return true
  }
  /// Observe the native layer transactions, not the earlier GPU-ready result.
  /// No frame, drawable or cohort is retained after the last callback fires.
  func afterPresentationTransaction(_ completion: @escaping @MainActor () -> Void) {
    precondition(!isInstalled, "Register before publishing the prepared cohort")
    let frames = updates.compactMap(\.frame)
    guard !frames.isEmpty else { completion(); return }
    var remaining = frames.count
    for frame in frames {
      frame.afterPresentationTransaction {
        remaining -= 1
        if remaining == 0 { completion() }
      }
    }
  }
}

/// Paper coordinates remain fixed while the existing tile pools cover a finite
/// projected window. The camera chooses density and coverage together.
struct SpatialInkCoverProjection {
  let size: SpatialPoint
  let density: Double
  let visible: CGRect

  init(surface: SpatialScreenSurface, viewport: CGRect, displayScale: Double) {
    size = .init(x: surface.localBounds.width, y: surface.localBounds.height)
    density = surface.screenScale * displayScale
    let intersection = viewport.applying(surface.localToScreen.inverted()).intersection(surface.localBounds)
    visible = intersection.isNull ? .zero : intersection
  }

  init?(itemID: UUID, frame: WorkspaceSceneFrame, displayScale: Double) {
    guard let boardID = frame.index.ownerBoard(itemID: itemID),
      let presence = frame.presences[boardID], let scale = frame.pixelScales[boardID],
      let item = frame.workset(boardID: boardID).items.first(where: { $0.id == itemID }) else { return nil }
    size = item.geometry.size
    density = scale * displayScale
    let topLeft = presence.camera.screenToWorld(.zero, viewport: presence.viewport)
    let offset = item.center.delta(to: topLeft)
    let window = CGRect(x: offset.x + size.x / 2, y: offset.y + size.y / 2,
      width: presence.viewport.x / presence.camera.scale, height: presence.viewport.y / presence.camera.scale)
    let intersection = window.intersection(CGRect(x: 0, y: 0, width: size.x, height: size.y))
    visible = intersection.isNull ? .zero : intersection
  }

  @MainActor var backingRegion: CGRect {
    guard !visible.isEmpty else { return .zero }
    let extent = InkCanvasView.sceneBackingSize(viewport: .init(x: visible.width, y: visible.height), displayScale: density)
    let width = min(size.x, extent.x), height = min(size.y, extent.y)
    return .init(x: max(0, min(size.x - width, visible.midX - width / 2)),
      y: max(0, min(size.y - height, visible.midY - height / 2)), width: width, height: height)
  }
}

@MainActor
final class SpatialInkPhysicalOwner {
  let surface: SurfaceID
  let canvas: InkCanvasView
  private let retention: SpatialInkCanvasRetention
  private let physical: ScenePhysicalOwnerLease
  var resourceIdentity: ScenePhysicalOwner {
    // Every native canvas owns exactly one physical surface, admitted before
    // construction. This is the same identity used by its byte reservations.
    physical.owners.first!
  }
  private weak var registry: SpatialInkSurfaceRegistry?
  private var mounts: [UUID: WeakMount] = [:]
  private weak var currentMount: SpatialInkPhysicalMountView?
  private var serial: UInt64 = 0
  private struct WeakMount {
    weak var view: SpatialInkPhysicalMountView?
    let serial: UInt64
  }

  init(surface: SurfaceID, size: SpatialPoint, camera: SpatialCamera,
    registry: SpatialInkSurfaceRegistry, resources: SceneRenderResources,
    displayScale: Double, physical: ScenePhysicalOwnerLease) {
    self.surface = surface; self.registry = registry; self.physical = physical
    canvas = InkCanvasView(frame: .init(x: 0, y: 0, width: size.x, height: size.y), resources: resources)
    retention = canvas.retainForSpatialHandoff(displayScale: displayScale)
    canvas.holdPhysicalAdmission(physical)
    canvas.project(camera: surface.kind == .board ? camera : nil, viewport: size)
    registry.register(canvas, for: surface)
  }

  func mount(_ view: SpatialInkPhysicalMountView) {
    if mounts[view.mountID]?.view !== view { serial &+= 1; mounts[view.mountID] = .init(view: view, serial: serial) }
    refreshMount()
  }
  func unmount(_ view: SpatialInkPhysicalMountView) {
    guard mounts[view.mountID]?.view === view else { return }
    mounts[view.mountID] = nil
    if currentMount === view { currentMount = nil; view.unbindCanvas(canvas) }
    refreshMount()
  }
  func refreshMount() {
    guard let registry, !registry.sceneInkIsStopped,
      !registry.hasActiveAction(on: surface), !registry.hasContact(on: surface) else { return }
    mounts = mounts.filter { $0.value.view != nil }
    let selected = mounts.values.filter { entry in
      guard let view = entry.view, view.window != nil else { return false }
      if surface.kind == .cover { return view.isActive || view.boardID != registry.activeBoardInkID }
      return view.isActive ? registry.activeBoardInkMount == view.mountID && registry.activeBoardInkID == surface.ownerID
        : registry.activeBoardInkID != surface.ownerID
    }.max { left, right in
      if left.view?.isActive != right.view?.isActive { return left.view?.isActive != true }
      return left.serial < right.serial
    }?.view
    if currentMount !== selected {
      currentMount?.unbindCanvas(canvas); currentMount = selected
    }
    if let selected {
      CATransaction.begin(); CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      selected.bindCanvas(canvas)
      if surface.kind == .board, let basis = canvas.spatialCamera, let id = surface.ownerID {
        let anchor = SessionPresence(boardID: id, mode: .board, camera: basis, viewport: canvas.spatialViewport)
        let current = SessionPresence(boardID: id, mode: .board, camera: selected.camera,
          viewport: .init(x: selected.bounds.width, y: selected.bounds.height))
        let projection = SceneCameraProjection(anchor: anchor, current: current)
        canvas.transform = CGAffineTransform(scaleX: projection.scale, y: projection.scale)
        canvas.center = .init(x: anchor.viewport.x / 2 * projection.scale + projection.translation.x,
          y: anchor.viewport.y / 2 * projection.scale + projection.translation.y)
      } else {
        canvas.transform = .identity
        canvas.center = .init(x: selected.bounds.midX, y: selected.bounds.midY)
      }
    } else {
      CATransaction.begin(); CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      canvas.transform = .identity
      // Private frames no longer need a hidden window/display loop. The
      // existing handoff retention keeps this owner's buffers until remount.
      canvas.removeFromSuperview()
    }
  }

  /// Refill the existing finite backing before its edge reaches the viewport.
  /// Settlement refines density, not translation: input already maps through
  /// the installed basis. This demand uses the one scene producer.
  func needsProjection(camera: SpatialCamera, viewport: SpatialPoint, refinesDetails: Bool) -> Bool {
    guard surface.kind == .board, let basis = canvas.spatialCamera, let id = surface.ownerID else { return false }
    if camera.scale > basis.scale * (refinesDetails ? 1 + 1e-9 : sqrt(2.0)) { return true }
    let anchor = SessionPresence(boardID: id, mode: .board, camera: basis, viewport: canvas.spatialViewport)
    let current = SessionPresence(boardID: id, mode: .board, camera: camera, viewport: viewport)
    let projection = SceneCameraProjection(anchor: anchor, current: current)
    let backing = CGRect(x: projection.translation.x, y: projection.translation.y,
      width: canvas.bounds.width * projection.scale, height: canvas.bounds.height * projection.scale)
    // A small demand margin spends no additional bytes; it starts the next
    // ordinary cohort while the already allocated overscan is still visible.
    // The long edge can exactly fill an existing backing. Do not repeatedly
    // request an impossible margin after installing that same finite extent.
    let marginX = min(64, max(0, backing.width - viewport.x) / 4)
    let marginY = min(64, max(0, backing.height - viewport.y) / 4)
    let wanted = CGRect(x: -marginX, y: -marginY,
      width: viewport.x + marginX * 2, height: viewport.y + marginY * 2)
    return !backing.contains(wanted)
  }
  func stop() async {
    await canvas.finishSpatialHandoffFrames()
    currentMount?.unbindCanvas(canvas); currentMount = nil; mounts.removeAll()
    canvas.removeFromSuperview()
    retention.release(); canvas.releasePhysicalAdmission(); physical.release()
  }
  isolated deinit {
    registry?.unregister(canvas, for: surface)
    canvas.removeFromSuperview(); retention.release()
    // Submitted commands retain this lease until their completion, even when
    // the last displayed/candidate owner is released.
    canvas.releasePhysicalAdmission()
  }
}

/// A mount has no input recognizer and never creates or prepares a canvas.
/// The registry chooses one physical parent; stale portal/update callbacks
/// cannot steal the active board from the current window-level input owner.
@MainActor
class SpatialInkPhysicalMountView: UIView, SceneNativeCameraOwner {
  let mountID = UUID()
  private(set) var inkView: InkCanvasView?
  private var lease: SpatialInkSceneLease?
  private var owner: SpatialInkPhysicalOwner?
  private weak var cameraProjection: SceneNativeCameraProjection?
  private var cameraIsRegistered = false
  var onCameraProjection: ((SessionPresence) -> Void)?
  private(set) var camera = SpatialCamera()
  private(set) var isActive = false
  private(set) var boardID: UUID?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false; isOpaque = false; backgroundColor = .clear; clipsToBounds = true
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func bindCameraProjection(to projection: SceneNativeCameraProjection?) {
    if cameraProjection !== projection {
      cameraProjection?.remove(self)
      cameraIsRegistered = false
      cameraProjection = projection
    }
    registerCameraIfMounted()
  }

  func currentCameraPresence(for boardID: UUID) -> SessionPresence? {
    cameraProjection?.current(for: boardID)
  }

  private func registerCameraIfMounted() {
    let shouldRegister = window != nil && owner?.surface.kind == .board
    if shouldRegister && !cameraIsRegistered, let cameraProjection {
      cameraIsRegistered = true
      cameraProjection.register(self)
    } else if !shouldRegister && cameraIsRegistered {
      cameraProjection?.remove(self)
      cameraIsRegistered = false
    }
  }

  func projectSceneCamera(_ presence: SessionPresence) {
    guard window != nil, boardID == presence.boardID,
      owner?.surface == .board(presence.boardID) else { return }
    camera = presence.camera
    // The input coordinator receives the same sample before accepting another
    // Pencil contact. Its already accepted ContactGeometry remains frozen.
    onCameraProjection?(presence)
    owner?.refreshMount()
  }

  func update(lease: SpatialInkSceneLease?, surface: SurfaceID, boardID: UUID, camera: SpatialCamera, active: Bool) {
    let next = lease?.isInstalled == true ? lease?.owners[surface] : nil
    if active, surface.kind == .board, let lease, next != nil,
      !lease.registry.activateBoardInk(boardID, mount: mountID) { return }
    if owner !== next {
      if isActive, owner?.surface.kind == .board,
        !(active && surface.kind == .board && next != nil && self.lease?.registry === lease?.registry) {
        self.lease?.registry.deactivateBoardInk(mount: mountID)
      }
      owner?.unmount(self); owner = next
    }
    self.lease = lease
    self.camera = surface == .board(boardID)
      ? currentCameraPresence(for: boardID)?.camera ?? camera : camera
    isActive = active; self.boardID = boardID
    next?.mount(self)
    registerCameraIfMounted()
  }
  func unmount() {
    cameraProjection?.remove(self)
    cameraIsRegistered = false
    if isActive, owner?.surface.kind == .board { lease?.registry.deactivateBoardInk(mount: mountID) }
    owner?.unmount(self); owner = nil; lease = nil
  }
  fileprivate func bindCanvas(_ canvas: InkCanvasView) {
    inkView = canvas
    if canvas.superview !== self { addSubview(canvas) }
    canvas.center = .init(x: bounds.midX, y: bounds.midY)
  }
  fileprivate func unbindCanvas(_ canvas: InkCanvasView) {
    if inkView === canvas { inkView = nil }
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    // Layout does not own the installed contact transform. The physical owner
    // defers this latest mount geometry until its final routing lease releases.
    owner?.refreshMount()
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    registerCameraIfMounted()
    owner?.refreshMount()
  }
}

struct SpatialBoardInkView: UIViewRepresentable {
  @Environment(NotebookAppModel.self) private var model: NotebookAppModel?
  private weak var nativeInk: SpatialInkSceneLease?
  let boardID: UUID
  let camera: SpatialCamera

  init(cohort: SceneCompositionCohort, boardID: UUID, camera: SpatialCamera) {
    nativeInk = cohort.nativeInk; self.boardID = boardID; self.camera = camera
  }

  func makeUIView(context: Context) -> SpatialInkPhysicalMountView { .init(frame: .zero) }
  func updateUIView(_ view: SpatialInkPhysicalMountView, context: Context) {
    view.bindCameraProjection(to: model?.nativeCameraProjection)
    // Cached SwiftUI configuration is not a second owner of the physical ink.
    guard let nativeInk else { return }
    view.update(lease: nativeInk, surface: .board(boardID), boardID: boardID, camera: camera, active: false)
  }
  static func dismantleUIView(_ view: SpatialInkPhysicalMountView, coordinator: ()) { view.unmount() }
}
