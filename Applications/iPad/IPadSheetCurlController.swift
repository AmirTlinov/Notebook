import UIKit

/// One bounded stack of mounted sheets and one physical curl. Turning changes
/// z-order, never the live hosting controller's parent or SwiftUI lifetime.
@MainActor
final class IPadSheetCurlController: UIViewController, UIGestureRecognizerDelegate {
  enum Direction { case forward, reverse }
  static let minimumGestureTravel: CGFloat = 44
  var neighbor: (UIViewController, Direction) -> UIViewController? = { _, _ in nil }
  var willTurn: (UIViewController) -> Bool = { _ in false }
  var didTurn: (UIViewController, Bool) -> Void = { _, _ in }
  var onFailure: (Error) -> Void = { _ in }
  private(set) var page: UIViewController?
  let pan = UIPanGestureRecognizer()
  private var curl = SheetCurlMetalView(frame: .zero)
  private var panDirection: Direction?
  private let poster = UIImageView()
  private var motion: Motion?
  private struct Motion {
    let source: UIViewController, target: UIViewController
    let image: CGImage
    let direction: Direction
    let completion: ((Bool) -> Void)?
    let gesture: Bool
    var progress: Double = 0
    var firstPresented = false
    var animation: (start: Double, from: Double, to: Double, duration: Double)?
    var terminal: Double?
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear; view.isOpaque = false; view.clipsToBounds = true
    pan.addTarget(self, action: #selector(panned))
    pan.delegate = self; pan.maximumNumberOfTouches = 2
    pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    view.addGestureRecognizer(pan)
    poster.isUserInteractionEnabled = false; poster.isHidden = true
    configureCurl()
    view.addSubview(poster); view.addSubview(curl)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    for child in children { child.view.frame = view.bounds }
    curl.frame = view.bounds; poster.frame = view.bounds
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated); cancelMotion()
  }

  func prepare(_ controller: UIViewController) {
    loadViewIfNeeded()
    guard controller.parent !== self else { return }
    precondition(controller.parent == nil, "A sheet has one stable native owner")
    addChild(controller)
    view.insertSubview(controller.view, at: 0)
    controller.view.frame = view.bounds
    controller.didMove(toParent: self)
  }

  func retire(_ controller: UIViewController) {
    guard controller.parent === self else { return }
    controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
  }

  func show(_ target: UIViewController, direction: Direction, animated: Bool, completion: ((Bool) -> Void)? = nil) {
    loadViewIfNeeded()
    cancelMotion()
    prepare(target)
    guard animated, let source = page, source !== target, SceneSourceVisibility.isVisible(view) else {
      page = target; view.bringSubviewToFront(target.view)
      view.bringSubviewToFront(curl)
      if let completion { Task { @MainActor in completion(true) } }
      return
    }
    do {
      let startedAt = CACurrentMediaTime()
      try begin(source: source, target: target, direction: direction, gesture: false, completion: completion)
      animate(to: 1, startedAt: startedAt)
    } catch { onFailure(error); completion?(false) }
  }

  private func begin(source: UIViewController, target: UIViewController, direction: Direction,
    gesture: Bool, completion: ((Bool) -> Void)?) throws {
    prepare(target)
    let sheet = direction == .forward ? source : target
    sheet.view.layoutIfNeeded()
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { throw SceneRenderError.snapshotPending("page_bounds") }
    let scale = min(view.window?.screen.scale ?? 2, sqrt(4_000_000 / (size.width*size.height)))
    // The accepted gesture owns one image and the bounded drawable pool. This is transient
    // input backing, not a speculative cache entry competing with its own pages.
    let pixels = Int(ceil(size.width*scale)) * Int(ceil(size.height*scale))
    guard let reservation = SceneRenderResources.shared.reserveDerivedBytes(pixels * 4 * (1 + curl.drawableCount),
      priority: .input) else { throw SceneRenderError.resourceLimit }
    let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
    var captured = false
    let snapshot = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      captured = sheet.view.drawHierarchy(in: sheet.view.bounds, afterScreenUpdates: false)
    }
    guard captured, let image = snapshot.cgImage else { throw SceneRenderError.snapshotPending("page_capture") }
    curl.frameLease = reservation
    curl.prepareDrawable(size: .init(width: image.width, height: image.height))
    motion = .init(source: source, target: target, image: image, direction: direction,
      completion: completion, gesture: gesture)
    // The old page stays visible until the first submitted curl reaches display.
    // A new Metal drawable is not allowed to flash its empty previous contents.
    view.bringSubviewToFront((direction == .forward ? target : source).view)
    if direction == .forward { poster.image = snapshot; poster.isHidden = false; view.bringSubviewToFront(poster) }
    curl.isHidden = false; view.bringSubviewToFront(curl)
    render(0)
  }

  private func render(_ progress: Double) {
    guard var motion else { return }
    motion.progress = min(max(0, progress), 1); self.motion = motion
    curl.update(cover: motion.image,
      progress: motion.direction == .forward ? motion.progress : 1-motion.progress,
      backsideColor: .document, cornerRadius: 0,
      layout: .init(sheetSize: view.bounds.size, clipsToSheet: true))
  }

  private func presented(_ image: CGImage, progress: Double, at timestamp: TimeInterval) {
    guard timestamp.isFinite, timestamp > 0, var motion, motion.image === image else { return }
    if !motion.firstPresented {
      motion.firstPresented = true
      self.motion = motion; poster.isHidden = true; poster.image = nil
    }
    let shown = motion.direction == .forward ? progress : 1-progress
    if let terminal = motion.terminal, abs(shown-terminal) < 0.000_001 { finish(completed: terminal == 1, presented: true) }
  }

  private func animate(to target: Double, startedAt: Double = CACurrentMediaTime()) {
    guard var motion else { return }
    motion.animation = (startedAt, motion.progress, target, max(0.1, 0.32*abs(target-motion.progress)))
    motion.terminal = nil; self.motion = motion
    curl.animatesContinuously = true
  }

  private func advanceAnimation(at timestamp: Double) {
    // The visible source/poster already supplies continuity. Waiting for its
    // unchanged first GPU frame before advancing added two display intervals
    // of dead time to every command. The curve follows the command's clock;
    // only its terminal presentation may confirm the new page.
    guard let motion, let animation = motion.animation else { return }
    let fraction = min(1, max(0, (timestamp-animation.start)/animation.duration))
    let eased = fraction*fraction*(3-2*fraction)
    if fraction == 1 { self.motion?.terminal = animation.to }
    render(animation.from+(animation.to-animation.from)*eased)
    if fraction == 1 { curl.animatesContinuously = false }
  }

  private func finish(completed: Bool, notify: Bool = true, presented: Bool = false) {
    guard let motion else { return }
    self.motion = nil
    page = completed ? motion.target : motion.source
    view.bringSubviewToFront(page!.view)
    curl.isHidden = true; curl.releaseSource(presented: presented); curl.removeFromSuperview()
    // A new sheet never inherits the preceding turn's last Metal drawable.
    // The shared device/filter stays warm; only its finite presentation retires.
    curl = SheetCurlMetalView(frame: view.bounds); configureCurl(); view.addSubview(curl)
    poster.isHidden = true; poster.image = nil
    if notify {
      motion.completion?(completed)
      if motion.gesture { didTurn(motion.source, completed) }
    } else { motion.completion?(false) }
  }

  func cancelMotion(notify: Bool = true) { if motion != nil { finish(completed: false, notify: notify) } }
  isolated deinit { curl.releaseSource() }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    panDirection = nil
    guard motion == nil, let page else { return false }
    let translation = pan.translation(in: view)
    guard abs(translation.x) > abs(translation.y) else { return false }
    let direction: Direction = translation.x < 0 ? .forward : .reverse
    guard neighbor(page, direction) != nil else { return false }
    // UIPan resets translation between shouldBegin and the began action.
    // Keep the admitted direction; zero is not a request to turn backwards.
    panDirection = direction
    return true
  }

  private func configureCurl() {
    // The empty transparent layer is already part of the displayed scene.
    // First input must not wait for a second CA transaction to unhide/mount it.
    // No drawable or display clock is acquired until motion actually starts.
    curl.isUserInteractionEnabled = false
    curl.enableSetNeedsDisplay = false
    curl.onDisplayUpdate = { [weak self] timestamp in self?.advanceAnimation(at: timestamp) }
    curl.permitsFrameSubmission = { [weak self] in self?.motion != nil }
    curl.onFramePresented = { [weak self] image, progress, timestamp in
      self?.presented(image, progress: progress, at: timestamp)
    }
  }

  @objc private func panned(_ pan: UIPanGestureRecognizer) {
    switch pan.state {
    case .began:
      guard let page, let direction = panDirection else { return }
      guard let target = neighbor(page, direction), willTurn(target) else { return }
      do { try begin(source: page, target: target, direction: direction, gesture: true, completion: nil) }
      catch { onFailure(error); didTurn(page, false) }
    case .changed:
      guard let motion, motion.gesture else { return }
      let sign = motion.direction == .forward ? -1.0 : 1.0
      render(pan.translation(in: view).x * sign / max(1, view.bounds.width))
    case .ended, .cancelled, .failed:
      panDirection = nil
      guard let motion, motion.gesture else { return }
      let sign: CGFloat = motion.direction == .forward ? -1 : 1
      let velocity = pan.velocity(in: view.window).x * sign
      let travel = pan.translation(in: view.window).x * sign
      let completed = pan.state == .ended
        && (travel >= Self.minimumGestureTravel || velocity > 300) && velocity > -300
      animate(to: completed ? 1 : 0)
    default: break
    }
  }
}
