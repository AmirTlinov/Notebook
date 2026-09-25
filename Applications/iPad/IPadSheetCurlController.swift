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
  struct CaptureTiming {
    let began, ended: TimeInterval
    let pixels: Int
  }
  /// Optional timing at the actual capture owner, never a second render path.
  var onCaptureMeasured: ((CaptureTiming) -> Void)?
  private(set) var page: UIViewController?
  let pan = UIPanGestureRecognizer()
  private let curl = SheetCurlMetalView(frame: .zero)
  private var panDirection: Direction?
  private var motion: Motion?
  private struct Motion {
    let id: UUID
    let source: UIViewController, target: UIViewController
    var image: CGImage?
    let direction: Direction
    let completion: ((Bool) -> Void)?
    let gesture: Bool
    var progress: Double = 0
    var presentation: (progress: Double, sequence: Int, readiness: NotebookMetalFrameReadiness)?
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
    configureCurl()
    view.addSubview(curl)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    for child in children { child.view.frame = view.bounds }
    curl.frame = view.bounds
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
      if let completion { Task { @MainActor in completion(true) } }
      return
    }
    do {
      try begin(source: source, target: target, direction: direction, gesture: false, completion: completion)
      animate(to: 1)
    } catch { onFailure(error); completion?(false) }
  }

  private func begin(source: UIViewController, target: UIViewController, direction: Direction,
    gesture: Bool, completion: ((Bool) -> Void)?) throws {
    prepare(target)
    guard view.bounds.width > 0, view.bounds.height > 0 else { throw SceneRenderError.snapshotPending("page_bounds") }
    let id = UUID()
    motion = .init(id: id, source: source, target: target, direction: direction,
      completion: completion, gesture: gesture)
    // Snapshot outside both input dispatch and UIKit's update callbacks. A
    // fresh snapshot inside either stack can recursively update UIKit and lose
    // later contacts. The snapshot itself requests current layers; a queue hop
    // is not being treated as evidence that an old cached raster is current.
    // Live paper stays in front while the same motion retains finger progress.
    let sheet = direction == .forward ? source : target
    sheet.view.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in self?.captureCurrentSource(for: id) }
  }

  private func captureCurrentSource(for id: UUID) {
    guard let motion, motion.id == id else { return }
    do {
      let sheet = motion.direction == .forward ? motion.source : motion.target
      let began = onCaptureMeasured == nil ? nil : CACurrentMediaTime()
      let (image, reservation) = try capture(sheet.view)
      if let began { onCaptureMeasured?(.init(began: began, ended: CACurrentMediaTime(), pixels: image.width * image.height)) }
      guard var current = self.motion, current.id == id else { return }
      current.image = image; self.motion = current
      curl.frameLease = reservation
      curl.prepareDrawable(size: .init(width: image.width, height: image.height))
      curl.isHidden = false
      view.bringSubviewToFront(motion.source.view)
      render(current.progress)
      curl.animatesContinuously = current.animation != nil
    } catch {
      onFailure(error)
      finish(completed: false)
    }
  }

  private func capture(_ sheet: UIView) throws -> (CGImage, RasterReservation) {
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { throw SceneRenderError.snapshotPending("page_bounds") }
    // A fitted sheet can be much larger than its on-screen projection. Capture
    // its displayed density, not a full-resolution offscreen page on every swipe.
    let origin = view.convert(CGPoint.zero, to: view.window)
    let x = view.convert(CGPoint(x: size.width, y: 0), to: view.window)
    let y = view.convert(CGPoint(x: 0, y: size.height), to: view.window)
    let projection = max(hypot(x.x-origin.x, x.y-origin.y)/size.width,
      hypot(y.x-origin.x, y.y-origin.y)/size.height)
    let scale = min(projection * (view.window?.screen.scale ?? 2), sqrt(4_000_000 / (size.width*size.height)))
    // The accepted gesture owns one image and the bounded drawable pool. This is transient
    // input backing, not a speculative cache entry competing with its own pages.
    let width = Int(ceil(size.width*scale)), height = Int(ceil(size.height*scale))
    // Keep UIKit's native pixels through capture. Converting the full
    // window to SDR here blocks input; Core Image already resolves the curl
    // into its BGRA8 output. Admit the eight-byte source and two four-byte
    // drawable rows, including their alignment, before taking the snapshot.
    let imageBytes = ((width * 8 + 63) / 64) * 64 * height
    let drawableBytes = ((width * 4 + 255) / 256) * 256 * height
    guard let reservation = SceneRenderResources.shared.reserveDerivedBytes(imageBytes + drawableBytes * curl.drawableCount,
      priority: .input) else { throw SceneRenderError.resourceLimit }
    let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
    format.preferredRange = .automatic
    var captured = false
    let snapshot = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      captured = sheet.drawHierarchy(in: sheet.bounds, afterScreenUpdates: true)
    }
    guard captured, let image = snapshot.cgImage else { throw SceneRenderError.snapshotPending("page_capture") }
    guard image.bytesPerRow * image.height <= imageBytes else { throw SceneRenderError.resourceLimit }
    return (image, reservation)
  }

  private func render(_ progress: Double) {
    guard var motion else { return }
    motion.progress = min(max(0, progress), 1); self.motion = motion
    guard let image = motion.image else { return }
    curl.update(cover: image,
      // First present the source's unchanged surface above its live paper.
      // A newly exposed Metal layer can miss its first presentation even when
      // its writes are scheduled. Until a real receipt, never expose the next
      // leaf under that still-empty layer. Once primed, the retained drawable
      // protects the underlay while subsequent frames are being composed.
      progress: motion.direction == .forward ? (motion.presentation == nil ? 0 : motion.progress)
        : (motion.presentation == nil ? 1 : 1-motion.progress),
      backsideColor: .document, cornerRadius: 0,
      layout: .init(sheetSize: view.bounds.size, clipsToSheet: true))
  }

  private func frameReady(_ image: CGImage, progress: Double, sequence: Int, readiness: NotebookMetalFrameReadiness) {
    guard readiness.isReady, var motion, motion.image === image else { return }
    if let previous = motion.presentation {
      guard sequence > previous.sequence else { return }
      if let time = readiness.presentedTime,
        let oldTime = previous.readiness.presentedTime, time <= oldTime { return }
    }
    let first = motion.presentation == nil
    let shown = motion.direction == .forward ? progress : 1-progress
    motion.presentation = (shown, sequence, readiness)
    if first, var animation = motion.animation {
      // Preparation is not visible animation time. Catching up to an old
      // command timestamp can skip the entire curl on a dense real page.
      animation.start = readiness.presentedTime ?? CACurrentMediaTime()
      motion.animation = animation
    }
    self.motion = motion
    if first { render(motion.progress) }
    finishPresentedEndpoint()
  }

  private func finishPresentedEndpoint() {
    guard let motion, let terminal = motion.terminal, motion.presentation?.progress == terminal else { return }
    finish(completed: terminal == 1, presented: true)
  }

  private func animate(to target: Double) {
    guard var motion else { return }
    // A held finger can already have presented the exact endpoint. Releasing
    // it accepts that receipt; waiting for a duplicate frame would deadlock
    // because the renderer correctly does not redraw an unchanged image.
    if motion.progress == target {
      motion.animation = nil; motion.terminal = target; self.motion = motion
      curl.animatesContinuously = false
      finishPresentedEndpoint()
      return
    }
    motion.animation = (CACurrentMediaTime(), motion.progress, target, max(0.1, 0.32*abs(target-motion.progress)))
    motion.terminal = nil; self.motion = motion
    curl.animatesContinuously = motion.image != nil
  }

  private func advanceAnimation(at timestamp: Double) {
    // Begin timed bending only after the source surface is on screen. Direct
    // finger progress is retained independently by render(), including a lift
    // that arrives while preparation is still pending.
    guard let motion, motion.presentation != nil, let animation = motion.animation else { return }
    let fraction = min(1, max(0, (timestamp-animation.start)/animation.duration))
    let eased = fraction*fraction*(3-2*fraction)
    if fraction == 1 { self.motion?.terminal = animation.to }
    render(fraction == 1 ? animation.to : animation.from+(animation.to-animation.from)*eased)
    if fraction == 1 { curl.animatesContinuously = false; finishPresentedEndpoint() }
  }

  private func finish(completed: Bool, notify: Bool = true, presented: Bool = false) {
    guard let motion else { return }
    self.motion = nil
    page = completed ? motion.target : motion.source
    view.bringSubviewToFront(page!.view)
    curl.isHidden = true; curl.releaseSource(presented: presented)
    if notify {
      motion.completion?(completed)
      if motion.gesture { didTurn(motion.source, completed) }
    } else { motion.completion?(false) }
  }

  func cancelMotion(notify: Bool = true) { if motion != nil { finish(completed: false, notify: notify) } }
  isolated deinit { curl.releaseSource() }

  /// Warm pans and a cold contact whose neighbour becomes ready use the same
  /// motion owner. The admission recognizer keeps that original contact.
  @discardableResult
  func beginInteractiveTurn(direction: Direction) -> Bool {
    guard motion == nil, let page, let target = neighbor(page, direction), willTurn(target) else { return false }
    do {
      try begin(source: page, target: target, direction: direction, gesture: true, completion: nil)
      return true
    } catch { onFailure(error); didTurn(page, false); return false }
  }

  func updateInteractiveTurn(translation: CGFloat) {
    guard let motion, motion.gesture else { return }
    let sign = motion.direction == .forward ? -1.0 : 1.0
    render(translation * sign / max(1, view.bounds.width))
  }

  func endInteractiveTurn(completed: Bool) {
    guard motion?.gesture == true else { return }
    animate(to: completed ? 1 : 0)
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    panDirection = nil
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
      motion == nil, let page else { return false }
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
    // The layer stays mounted behind idle paper. No drawable or display clock
    // is acquired until motion starts, and only that motion can reveal it.
    curl.isHidden = true
    curl.isUserInteractionEnabled = false
    curl.enableSetNeedsDisplay = false
    curl.onDisplayUpdate = { [weak self] timestamp in self?.advanceAnimation(at: timestamp) }
    curl.permitsFrameSubmission = { [weak self] in self?.motion != nil }
    curl.onFrameReady = { [weak self] image, progress, sequence, readiness in
      self?.frameReady(image, progress: progress, sequence: sequence, readiness: readiness)
    }
    curl.onWillPresentFrame = { [weak self] image, progress in
      guard let self, let motion, motion.image === image else { return }
      let sheet = motion.direction == .forward ? motion.source : motion.target
      let beneath = motion.direction == .forward ? motion.target : motion.source
      // At the flat endpoint the live sheet must already be beneath its frozen
      // pixels. Retiring the Metal clock can otherwise expose the old source
      // for one compositor frame before finish()'s layer changes reach screen.
      view.bringSubviewToFront((progress == 0 ? sheet : beneath).view)
      view.bringSubviewToFront(curl)
    }
  }

  @objc private func panned(_ pan: UIPanGestureRecognizer) {
    switch pan.state {
    case .began:
      guard let direction = panDirection else { return }
      beginInteractiveTurn(direction: direction)
    case .changed:
      updateInteractiveTurn(translation: pan.translation(in: view).x)
    case .ended, .cancelled, .failed:
      panDirection = nil
      guard let motion, motion.gesture else { return }
      let sign: CGFloat = motion.direction == .forward ? -1 : 1
      let velocity = pan.velocity(in: view.window).x * sign
      let travel = pan.translation(in: view.window).x * sign
      let completed = pan.state == .ended
        && (travel >= Self.minimumGestureTravel || velocity > 300) && velocity > -300
      endInteractiveTurn(completed: completed)
    default: break
    }
  }
}
