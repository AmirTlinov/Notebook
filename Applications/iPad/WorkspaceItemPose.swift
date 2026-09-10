import NotebookCore
import SwiftUI
import UIKit

/// The result of the existing placement command, not another placement owner.
/// A stack retains its Core presentation rule while the published cohort catches up.
struct WorkspaceItemPoseDestination: Equatable {
  let center: WorldPoint
  let stack: WorkspaceItemStack?
  let versions: [String: ContentFieldVersion]

  init?(itemID: UUID, before: BoardDocument, after: BoardDocument) {
    let free = after.placement(of: itemID), stack = after.stack(containing: itemID)
    guard free != nil || stack != nil else { return nil }
    var prefixes = ["freeItems/\(itemID.uuidString.lowercased())/"]
    for id in Set([before.stack(containing: itemID)?.id, stack?.id].compactMap { $0 }) {
      prefixes.append("stacks/\(id.uuidString.lowercased())/")
    }
    let previous = before.collaboration?.fields ?? [:], current = after.collaboration?.fields ?? [:]
    let keys = prefixes.flatMap { prefix in ["center", "zIndex", "stamp", "exists", "itemIDs"].map { prefix + $0 } }
    versions = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
      guard let value = current[key], previous[key] != value else { return nil }
      return (key, value)
    })
    guard !versions.isEmpty else { return nil }
    center = stack?.center ?? free!.center
    self.stack = stack
  }

  func isObserved(in board: BoardDocument?) -> Bool {
    guard let fields = board?.collaboration?.fields else { return false }
    return versions.allSatisfy { key, value in fields[key]?.includes(value) == true }
  }

  func center(itemID: UUID, presence: SessionPresence) -> WorldPoint {
    stack.flatMap {
      WorkspaceItemStackPresentation.boardCenter(of: itemID, in: $0,
        cameraScale: presence.camera.scale, viewport: presence.viewport)
    } ?? center
  }
}

/// Environment access does not retain the hosting controller through its own content.
@MainActor
final class WorkspaceItemPoseHandle {
  weak var owner: WorkspaceItemPoseController?
}

private struct WorkspaceItemPoseKey: EnvironmentKey {
  static let defaultValue: WorkspaceItemPoseHandle? = nil
}
extension EnvironmentValues {
  var workspaceItemPose: WorkspaceItemPoseHandle? {
    get { self[WorkspaceItemPoseKey.self] }
    set { self[WorkspaceItemPoseKey.self] = newValue }
  }
}

/// One native ancestor carries the complete physical item, including its ink.
/// SwiftUI supplies content and placement; only this controller animates its pose.
struct WorkspaceItemPose<Content: View>: UIViewControllerRepresentable {
  @Environment(NotebookAppModel.self) private var model
  @Environment(\.scenePlaneProjection) private var projection
  @Environment(\.workspaceSceneFrame) private var frame
  @Environment(\.sceneComposition) private var composition
  let rendered: RenderedWorkspaceItem
  let camera: SpatialCamera
  let viewport: SpatialPoint
  let boardID: UUID
  let liftRank: Double?
  let registry: SpatialInkSurfaceRegistry
  let onLiftChanged: (Bool) -> Void
  let onDrop: (WorldPoint) -> WorkspaceItemPoseDestination?
  @ViewBuilder let content: () -> Content

  func makeUIViewController(context: Context) -> WorkspaceItemPoseController {
    WorkspaceItemPoseController()
  }

  func updateUIViewController(_ controller: WorkspaceItemPoseController, context: Context) {
    let cohort = composition.cohort
    controller.bindSceneLifecycle(to: model)
    controller.update(rendered: rendered, camera: camera, viewport: viewport, boardID: boardID,
      cohortID: cohort?.id, cohortRevision: cohort?.plan.revision, sourceBoard: frame?.index.board(id: boardID), publishedLiftRank: liftRank, projection: projection,
      registry: registry, inputGate: model.inputGate, onLiftChanged: onLiftChanged, onDrop: onDrop,
      content: AnyView(content().environment(model)
        .environment(\.scenePlaneProjection, projection)
        .environment(\.workspaceSceneFrame, frame)
        .environment(\.sceneComposition, composition)
        .environment(\.workspaceItemPose, controller.handle)))
  }

  static func dismantleUIViewController(_ controller: WorkspaceItemPoseController, coordinator: ()) {
    controller.uninstall()
  }
}

@MainActor
final class WorkspaceItemPoseController: UIViewController, NotebookScenePresentationOwner {
  struct Pose: Equatable {
    let center: CGPoint
    let transform: CGAffineTransform
  }

  let handle = WorkspaceItemPoseHandle()
  private var host: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(EmptyView()))
  private weak var sceneModel: NotebookAppModel?
  private weak var registry: SpatialInkSurfaceRegistry?
  private weak var inputGate: NotebookInputGate?
  private var projection: ScenePlaneProjection?
  private var rendered: RenderedWorkspaceItem?
  private var camera = SpatialCamera()
  private var viewport = SpatialPoint(x: 1, y: 1)
  private(set) var boardID: UUID?
  private(set) var cohortID: UUID?
  private(set) var cohortRevision: UInt64?
  private(set) var retiredAtRevision: UInt64?
  private var publishedLiftRank: Double?
  private var publishedLift: Bool { publishedLiftRank != nil }
  private var wantsLift = false
  var isManipulating: Bool { wantsLift }
  private var awaitsLiftPublication = false
  private(set) var isEngaged = false
  private var translation = CGSize.zero
  private var pendingDestination: WorkspaceItemPoseDestination?
  private var onLiftChanged: (Bool) -> Void = { _ in }
  private var onDrop: (WorldPoint) -> WorkspaceItemPoseDestination? = { _ in nil }
  private let activityID = UUID()
  private var ownsActivity = false
  private var generation: UInt64 = 0
  private var leaseCount = 0
  private(set) var animator: UIViewPropertyAnimator?
  private var animationStart: Pose?
  private var installed = false
  private var retired = false
  private(set) var isContentReleased = false
  private var lifetime: UInt64 = 0
  private var deferredUpdate: (() -> Void)?
  private var isReleasingPose = false
  var contentView: UIView {
    if let host { return host.view }
    precondition(isContentReleased, "Only a terminal pose has no content host")
    return view
  }
  var surfaceID: SurfaceID? { rendered.map { .cover($0.id) } }

  func bindSceneLifecycle(to model: NotebookAppModel) {
    guard !retired, sceneModel !== model else { return }
    sceneModel?.unregisterScenePresentation(self)
    sceneModel = model
    model.registerScenePresentation(self)
  }

  override func loadView() {
    let container = WorkspaceItemPoseContainer()
    container.backgroundColor = .clear
    container.isOpaque = false
    container.clipsToBounds = false
    view = container
    guard let host else { return }
    host.view.backgroundColor = .clear
    host.view.isOpaque = false
    host.view.clipsToBounds = false
    host.safeAreaRegions = []
    addChild(host)
    view.addSubview(host.view)
    host.didMove(toParent: self)
    container.body = host.view
    handle.owner = self
  }

  func update(rendered: RenderedWorkspaceItem, camera: SpatialCamera, viewport: SpatialPoint,
    boardID: UUID, cohortID: UUID?, cohortRevision: UInt64?, sourceBoard: BoardDocument?, publishedLiftRank: Double?, projection: ScenePlaneProjection?,
    registry: SpatialInkSurfaceRegistry, inputGate: NotebookInputGate,
    onLiftChanged: @escaping (Bool) -> Void,
    onDrop: @escaping (WorldPoint) -> WorkspaceItemPoseDestination?, content: AnyView) {
    guard !retired else { return }
    if let retiredAtRevision {
      guard let cohortRevision, cohortRevision >= retiredAtRevision,
        sourceBoard?.itemIDs.contains(rendered.id) == true else { return }
      // A later complete canonical cut may legitimately restore this identity.
      // An old camera-only cohort cannot revive the removed physical owner.
      self.retiredAtRevision = nil
    }
    if leaseCount > 0 {
      let lifetime = lifetime
      deferredUpdate = { [weak self] in
        guard let self, self.lifetime == lifetime, !self.retired else { return }
        self.update(rendered: rendered, camera: camera, viewport: viewport, boardID: boardID,
          cohortID: cohortID, cohortRevision: cohortRevision, sourceBoard: sourceBoard, publishedLiftRank: publishedLiftRank, projection: projection, registry: registry,
          inputGate: inputGate, onLiftChanged: onLiftChanged, onDrop: onDrop, content: content)
      }
      return
    }
    loadViewIfNeeded()
    guard let host else { return }
    if self.rendered != nil, self.rendered?.id != rendered.id || self.boardID != boardID { detach() }
    let oldCamera = self.camera, oldViewport = self.viewport, previousTarget = targetPose
    self.rendered = rendered; self.camera = camera; self.viewport = viewport
    self.boardID = boardID; self.cohortID = cohortID; self.cohortRevision = cohortRevision; self.projection = projection
    self.onLiftChanged = onLiftChanged; self.onDrop = onDrop
    if self.registry !== registry {
      if let surfaceID { self.registry?.unregisterPose(self, for: surfaceID) }
      self.registry = registry
    }
    if self.inputGate !== inputGate {
      if ownsActivity { self.inputGate?.endContact(source: activityID); inputGate.beginContact(source: activityID) }
      self.inputGate = inputGate
    }
    let acceptedRank = isEngaged ? publishedLiftRank : nil
    let liftChanged = self.publishedLift != (acceptedRank != nil)
    self.publishedLiftRank = acceptedRank
    host.rootView = content
    host.view.bounds = .init(x: 0, y: 0, width: rendered.geometry.width, height: rendered.geometry.height)
    view.bounds = .init(x: 0, y: 0, width: viewport.x, height: viewport.y)
    if pendingDestination?.isObserved(in: sourceBoard) == true { pendingDestination = nil }
    registry.registerPose(self, for: .cover(rendered.id))
    if !installed {
      installed = true
      install(targetPose)
    } else if !isReleasingPose {
      if awaitsLiftPublication && acceptedRank != nil {
        awaitsLiftPublication = false
        animateToTarget()
      } else if liftChanged { animateToTarget() }
      else if animator == nil { install(targetPose); finishEngagementIfPossible(deferred: true) }
      else if oldCamera != camera || oldViewport != viewport || previousTarget != targetPose {
        // Camera rebasing changes the coordinate system, not the animation owner.
        retargetAnimation()
      }
    }
  }

  func beginLift() {
    guard installed, retiredAtRevision == nil, leaseCount == 0, inputGate?.hasActivePencil != true, !wantsLift else { return }
    stopAtPresentation()
    wantsLift = true; awaitsLiftPublication = true; translation = .zero
    beginActivity()
    isEngaged = true
    onLiftChanged(true)
    // The SwiftUI rank and the native lift start in the same published update.
    // Before that update a Pencil contact still captures the resting body.
  }

  func changeTranslation(_ value: CGSize) {
    guard wantsLift, leaseCount == 0, inputGate?.hasActivePencil != true else { return }
    let delta = CGSize(width: value.width - translation.width, height: value.height - translation.height)
    let remaining = animator.map { max(0, $0.duration * (1 - $0.fractionComplete)) }
    translation = value
    if publishedLift {
      stopAtPresentation()
      guard let pose = presentationPose else { return }
      let ratio = camera.scale / currentPresence.camera.scale
      // Drag follows the measured finger delta immediately. Only the remaining
      // lift spring resumes; movement never jumps to its not-yet-presented end.
      install(.init(center: .init(x: pose.center.x + delta.width * ratio,
        y: pose.center.y + delta.height * ratio), transform: pose.transform))
      if let remaining, remaining > 0 { animateToTarget(duration: remaining) }
    }
  }

  func endTranslation(_ value: CGSize) {
    guard wantsLift, leaseCount == 0 else { return }
    translation = value
    if let rendered, hypot(value.width, value.height) >= 2 {
      let base = pendingDestination?.center(itemID: rendered.id, presence: currentPresence) ?? rendered.center
      if let center = base.addressOffset(x: value.width / currentPresence.camera.scale,
        y: value.height / currentPresence.camera.scale) {
        pendingDestination = onDrop(center)
      }
    }
    wantsLift = false; awaitsLiftPublication = false; translation = .zero
    animateToTarget()
  }

  func cancelManipulation() {
    wantsLift = false; awaitsLiftPublication = false; translation = .zero
    // A lease owns the installed pose until the accepted ink tail is installed.
    // Cancellation changes only the destination, never the measured coordinate system.
    guard leaseCount == 0 else { return }
    animateToTarget()
  }

  func screenSurface(in coordinateView: UIView) -> SpatialScreenSurface? {
    guard installed, let rendered, let host, let pose = presentationPose,
      view.window != nil, view.window === coordinateView.window else { return nil }
    func convert(_ p: CGPoint) -> CGPoint {
      let local = CGPoint(x: p.x - host.view.bounds.midX, y: p.y - host.view.bounds.midY).applying(pose.transform)
      return view.convert(.init(x: local.x + pose.center.x, y: local.y + pose.center.y), to: coordinateView)
    }
    let origin = convert(.zero), x = convert(.init(x: 1, y: 0)), y = convert(.init(x: 0, y: 1))
    let matrix = CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
      c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y)
    guard matrix.isFiniteAndInvertible else { return nil }
    return .init(id: .cover(rendered.id), localBounds: host.view.bounds, localToScreen: matrix,
      zIndex: rendered.zIndex, liftRank: publishedLiftRank)
  }

  func acquirePose(in coordinateView: UIView) -> WorkspaceItemPoseLease? {
    guard screenSurface(in: coordinateView) != nil else { return nil }
    if leaseCount == 0 {
      stopAtPresentation()
      if isEngaged && !publishedLift {
        // The requested SwiftUI rank has not been installed. Retract it in
        // this same event, before a queued pass can raise an unfrozen body.
        wantsLift = false; awaitsLiftPublication = false; translation = .zero; isEngaged = false
        onLiftChanged(false)
      }
    }
    leaseCount += 1
    guard let surface = screenSurface(in: coordinateView) else { releasePose(lifetime: lifetime); return nil }
    return WorkspaceItemPoseLease(owner: self, surface: surface, lifetime: lifetime)
  }

  fileprivate func releasePose(lifetime: UInt64) {
    guard leaseCount > 0 else { return }
    leaseCount -= 1
    if retired { releaseRetiredContentIfPossible(); return }
    if leaseCount == 0, self.lifetime == lifetime, !retired {
      isReleasingPose = true
      let update = deferredUpdate; deferredUpdate = nil; update?()
      isReleasingPose = false
      if installed, retiredAtRevision == nil { animateToTarget() }
    }
  }

  func retirePhysicalOwner(through revision: UInt64) {
    guard (cohortRevision ?? 0) <= revision else { return }
    retiredAtRevision = max(retiredAtRevision ?? 0, revision)
    deferredUpdate = nil
    wantsLift = false; awaitsLiftPublication = false; translation = .zero; pendingDestination = nil
    stopAtPresentation()
    // Keep the shown native body and painter rank until its old cohort leaves.
    // Pins and new input exclude this exact SQL-confirmed owner, not its peers.
  }

  func uninstall() {
    guard !retired else { return }
    retired = true
    sceneModel?.unregisterScenePresentation(self)
    sceneModel = nil
    detach()
    releaseRetiredContentIfPossible()
  }

  /// A Pencil lease can outlive UIKit unmount while its accepted tail finishes.
  /// That same body remains owned until the last lease, but not until a cached
  /// controller happens to deallocate. Late updates cannot revive this host.
  private func releaseRetiredContentIfPossible() {
    guard retired, leaseCount == 0, !isContentReleased else { return }
    isContentReleased = true
    if let host {
      host.rootView = AnyView(EmptyView())
      // The last accepted contact has ended. Process the empty value in this
      // hosting view so its cached DisplayList cannot retain retired paint after
      // UIKit keeps or detaches the controller without scheduling another frame.
      if host.isViewLoaded {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
      }
      if host.parent != nil { host.willMove(toParent: nil) }
      if host.isViewLoaded { host.view.removeFromSuperview() }
      host.removeFromParent()
      // SwiftUI's focus bridge can retain this controller from the old hosting
      // view. A terminal owner no longer owns that host in the opposite direction.
      self.host = nil
    }
    onLiftChanged = { _ in }; onDrop = { _ in nil }
    projection = nil; rendered = nil; boardID = nil; cohortRevision = nil
    publishedLiftRank = nil; handle.owner = nil
  }

  private func detach() {
    lifetime &+= 1; deferredUpdate = nil
    let registry = registry, surface = surfaceID
    if let surfaceID { registry?.unregisterPose(self, for: surfaceID) }
    self.registry = nil; cohortID = nil; installed = false
    stopAtPresentation()
    wantsLift = false; awaitsLiftPublication = false; translation = .zero; pendingDestination = nil
    endActivity()
    if isEngaged {
      isEngaged = false
      let callback = onLiftChanged, generation = generation
      DispatchQueue.main.async { [weak self, weak registry] in
        guard self.map({ $0.generation == generation && !$0.isEngaged }) ?? true,
          surface.flatMap({ registry?.pose(for: $0) })?.isEngaged != true else { return }
        callback(false)
      }
    }
  }

  private var currentPresence: SessionPresence {
    projection?.current ?? .init(boardID: boardID ?? WorkspaceRoot.boardID,
      mode: .board, camera: camera, viewport: viewport)
  }

  private var targetPose: Pose {
    guard let rendered else { return .init(center: .zero, transform: .identity) }
    let center = pendingDestination?.center(itemID: rendered.id, presence: currentPresence) ?? rendered.center
    let screen = camera.worldToScreen(center, viewport: viewport)
    let lift = wantsLift && publishedLift
    let ratio = camera.scale / currentPresence.camera.scale
    return .init(center: .init(x: screen.x + translation.width * ratio,
      y: screen.y + translation.height * ratio - (lift ? 8 : 0)),
      transform: CGAffineTransform(rotationAngle: lift ? -.pi / 300 : 0)
        .scaledBy(x: camera.scale * (lift ? 1.035 : 1), y: camera.scale * (lift ? 1.035 : 1)))
  }

  private var presentationPose: Pose? {
    guard let host else { return nil }
    if let layer = host.view.layer.presentation() {
      return .init(center: layer.position, transform: layer.affineTransform())
    }
    // A newly scheduled animation has not presented its model destination yet.
    return animationStart ?? .init(center: host.view.center, transform: host.view.transform)
  }

  private func install(_ pose: Pose) {
    guard let host else { return }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    host.view.center = pose.center; host.view.transform = pose.transform
    CATransaction.commit()
  }

  private func stopAtPresentation() {
    let pose = presentationPose
    generation &+= 1
    animator?.stopAnimation(true); animator = nil; animationStart = nil
    if let pose { install(pose) }
    endActivity()
  }

  private func retargetAnimation() { stopAtPresentation(); animateToTarget() }

  private func animateToTarget(duration: TimeInterval = 0.18) {
    guard installed, retiredAtRevision == nil, leaseCount == 0, let host else { return }
    stopAtPresentation()
    let target = targetPose
    let start = Pose(center: host.view.center, transform: host.view.transform)
    guard start != target else { finishEngagementIfPossible(deferred: true); return }
    animationStart = start
    let generation = self.generation
    let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.82) {
      self.host?.view.center = target.center
      self.host?.view.transform = target.transform
    }
    self.animator = animator
    beginActivity()
    animator.addCompletion { [weak self] _ in
      guard let self, self.generation == generation, leaseCount == 0 else { return }
      self.animator = nil; animationStart = nil
      install(target); endActivity()
      finishEngagementIfPossible(deferred: false)
    }
    animator.startAnimation()
  }

  private func finishEngagementIfPossible(deferred: Bool) {
    guard isEngaged, retiredAtRevision == nil, !wantsLift, leaseCount == 0, animator == nil, pendingDestination == nil else { return }
    let generation = self.generation, callback = onLiftChanged
    if deferred {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == generation, isEngaged,
          !wantsLift, leaseCount == 0, animator == nil, pendingDestination == nil else { return }
        isEngaged = false
        callback(false)
      }
    } else { isEngaged = false; callback(false) }
  }

  private func beginActivity() {
    if !ownsActivity { ownsActivity = true; inputGate?.beginContact(source: activityID) }
  }
  private func endActivity() {
    if ownsActivity { ownsActivity = false; inputGate?.endContact(source: activityID) }
  }
}

@MainActor
final class WorkspaceItemPoseLease {
  let surface: SpatialScreenSurface
  private var owner: WorkspaceItemPoseController?
  private let lifetime: UInt64
  fileprivate init(owner: WorkspaceItemPoseController, surface: SpatialScreenSurface, lifetime: UInt64) {
    self.owner = owner; self.surface = surface; self.lifetime = lifetime
  }
  func release() { let owner = owner; self.owner = nil; owner?.releasePose(lifetime: lifetime) }
  isolated deinit { release() }
}

private final class WorkspaceItemPoseContainer: UIView {
  weak var body: UIView?
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard let body else { return nil }
    return body.hitTest(convert(point, to: body), with: event)
  }
}
