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
    let frame: InkCanvasView.PreparedSpatialFrame?
    let journal: SpatialInkJournal
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
  func install() throws {
    guard !registry.sceneInkIsStopped,
      updates.allSatisfy({ $0.owner.canvas.spatialSourceGeneration == $0.generation
        && !registry.hasActiveAction(on: $0.owner.surface) && !registry.hasContact(on: $0.owner.surface)
        && ($0.frame?.isValid ?? true) }) else { throw CancellationError() }
    try registry.installSceneAllocationPriorities(rootBoardID: rootBoardID, focusedCoverID: focusedCoverID)
    for update in updates {
      if let frame = update.frame {
        update.owner.canvas.installSpatialFrame(frame, journal: update.journal, surface: update.owner.surface)
      }
    }
    updates.removeAll(); isInstalled = true
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
  private var preparedCamera: SpatialCamera
  private var serial: UInt64 = 0
  private struct WeakMount {
    weak var view: SpatialInkPhysicalMountView?
    let serial: UInt64
  }

  init(surface: SurfaceID, size: SpatialPoint, camera: SpatialCamera,
    registry: SpatialInkSurfaceRegistry, resources: SceneRenderResources,
    displayScale: Double, physical: ScenePhysicalOwnerLease) {
    self.surface = surface; self.registry = registry; preparedCamera = camera; self.physical = physical
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
      selected.bindCanvas(canvas)
      canvas.project(camera: surface.kind == .board ? selected.camera : nil,
        viewport: .init(x: canvas.bounds.width, y: canvas.bounds.height))
    } else {
      registry.parkSceneCanvas(canvas)
      canvas.project(camera: surface.kind == .board ? preparedCamera : nil,
        viewport: .init(x: canvas.bounds.width, y: canvas.bounds.height))
    }
  }
  func prepareNew(mesh: SpatialInkMesh, journal: SpatialInkJournal) {
    canvas.applySpatial(mesh); canvas.installSpatialSource(journal, on: surface)
    if mesh.batches.contains(where: { !$0.vertices.isEmpty }) { registry?.parkSceneCanvas(canvas) }
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
class SpatialInkPhysicalMountView: UIView {
  let mountID = UUID()
  private(set) var inkView: InkCanvasView?
  private var lease: SpatialInkSceneLease?
  private var owner: SpatialInkPhysicalOwner?
  private(set) var camera = SpatialCamera()
  private(set) var isActive = false
  private(set) var boardID: UUID?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false; isOpaque = false; backgroundColor = .clear; clipsToBounds = true
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

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
    self.lease = lease; self.camera = camera; isActive = active; self.boardID = boardID
    next?.mount(self)
  }
  func unmount() {
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
  override func didMoveToWindow() { super.didMoveToWindow(); owner?.refreshMount() }
}

struct SpatialBoardInkView: UIViewRepresentable {
  private weak var nativeInk: SpatialInkSceneLease?
  let boardID: UUID
  let camera: SpatialCamera

  init(cohort: SceneCompositionCohort, boardID: UUID, camera: SpatialCamera) {
    nativeInk = cohort.nativeInk; self.boardID = boardID; self.camera = camera
  }

  func makeUIView(context: Context) -> SpatialInkPhysicalMountView { .init(frame: .zero) }
  func updateUIView(_ view: SpatialInkPhysicalMountView, context: Context) {
    // Cached SwiftUI configuration is not a second owner of the physical ink.
    guard let nativeInk else { return }
    view.update(lease: nativeInk, surface: .board(boardID), boardID: boardID, camera: camera, active: false)
  }
  static func dismantleUIView(_ view: SpatialInkPhysicalMountView, coordinator: ()) { view.unmount() }
}
