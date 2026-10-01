import UIKit

/// One bounded stack of mounted sheets and one physical curl. Turning changes
/// z-order, never the live hosting controller's parent or SwiftUI lifetime.
@MainActor
final class IPadSheetCurlController: UIViewController, UIGestureRecognizerDelegate {
  enum Direction { case forward, reverse }
  static let minimumGestureTravel: CGFloat = 44
  static func completesGesture(travel: CGFloat, velocity: CGFloat, ended: Bool) -> Bool {
    ended && (travel >= minimumGestureTravel || velocity > 300) && velocity > -300
  }
  var neighbor: (UIViewController, Direction) -> UIViewController? = { _, _ in nil }
  var willTurn: (UIViewController) -> Bool = { _ in false }
  /// Observation of the owner-resolved result; it never chooses a landing.
  var didTurn: (UIViewController, Bool) -> Void = { _, _ in }
  var beginOperation: (UIViewController, UIViewController, Bool, ((Bool) -> Void)?) -> UUID? = { _, _, _, _ in nil }
  var resolveOperation: (UUID, PageTurnOutcome, Bool, Bool) -> Void = { _, _, _, _ in }
  var didAcceptTurn: (UIViewController) -> Void = { _ in }
  var onFailure: (Error) -> Void = { _ in }
  var acquireSheetFrame: @MainActor @Sendable (UIViewController) async throws -> PageTurnFrame = { _ in throw SceneRenderError.snapshotPending("page_frame_owner") }
  var isSheetReadyForCapture: (UIViewController) -> Bool = { _ in true }
  var isSheetPresented: (UIViewController) -> Bool = { _ in true }
  var onStageLiveSheet: (UIViewController) -> Void = { _ in }
  #if DEBUG
  var diagnosticStagedSheet: String? { motion?.stagedLanding?.view.accessibilityIdentifier }
  var diagnosticMotionDescription: String {
    guard let motion else { return "motion=nil,submitted=\(curl.submittedFrameCount)" }
    return "operation=\(motion.id),frame=\(motion.frame != nil),progress=\(motion.progress),terminal=\(String(describing: motion.terminal)),presentation=\(String(describing: motion.presentation)),animation=\(String(describing: motion.animation)),contact=\(motion.contact != nil),staged=\(motion.stagedLanding?.view.accessibilityIdentifier ?? "nil"),submitted=\(curl.submittedFrameCount),continuous=\(curl.animatesContinuously),curlHidden=\(curl.isHidden),window=\(curl.window != nil)"
  }
  #endif
  struct FrameAcquisitionTiming {
    let operationID: UUID
    let began, ended: TimeInterval
    let pixels: Int
  }
  /// Optional timing at the owner that borrows the exact immutable frame pair.
  var onFramesAcquired: ((FrameAcquisitionTiming) -> Void)?
  private(set) var page: UIViewController?
  /// The installed page supplies its own opaque, clipped paper backdrop.
  /// Arbitrary native pages retain the ordinary revoked-visibility path.
  var idleOutputHost: (UIViewController) -> PageTurnOutputParkingHost? = { _ in nil }
  let pan = UIPanGestureRecognizer()
  private let curl = SheetCurlMetalView(frame: .zero)
  private var panDirection: Direction?
  private var motion: Motion?
  /// Install this identity before running a borrower. An already prepared
  /// pair may finish (or be cancelled by a callback) before Task.immediate
  /// returns its handle; neither outcome may leave a task in the next turn.
  @MainActor private final class FrameAcquisition {
    private var task: Task<Void, Never>?
    private var finished = false
    private(set) var isCancelled = false
    func attach(_ task: Task<Void, Never>) {
      if finished { task.cancel() } else { self.task = task }
    }
    func finish() { finished = true; task = nil }
    func cancel() { isCancelled = true; task?.cancel(); finish() }
  }
  private var frameAcquisition: FrameAcquisition?
  private var lastIntentTime: Double?
  private var inputCadence = Double.infinity
  private var continuedContact: Contact?
  private struct Contact {
    let initial, origin, initialTilt, began: Double
    let direction: Direction
  }
  /// A new contact can wait for this accepted landing, including cancellation
  /// back to the source. The page container must not guess from its old index.
  var settlingPage: UIViewController? {
    guard let motion, let endpoint = motion.contact?.origin ?? motion.animation?.to ?? motion.terminal else { return nil }
    return endpoint == 1 ? motion.target : motion.source
  }
  func containsInActiveTurn(_ controller: UIViewController) -> Bool {
    guard let motion else { return false }
    return motion.source === controller || motion.target === controller
  }

  private struct Motion {
    let id: UUID
    let source: UIViewController, target: UIViewController
    let size: CGSize
    var frame: PageTurnFrame?
    var firstFrameSequence: Int?
    let direction: Direction
    let gesture: Bool
    var readinessGeneration: UInt64 = 0
    var progress: Double = 0
    var anchor = 1.0
    var tilt = 0.0
    var contact: Contact?
    var presentation: (progress: Double, sequence: Int, readiness: NotebookMetalFrameReadiness)?
    var animation: (start: Double?, from: Double, to: Double, duration: Double, tilt: Double)?
    var terminal: Double?
    var stagedLanding: UIViewController?
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
    if let motion, motion.size != view.bounds.size { cancelMotion() }
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

  /// Install the owner's initial page after replacing or retiring a directory.
  /// There is no source/target transition to admit in this lifecycle boundary.
  func install(_ target: UIViewController) {
    cancelMotion(outcome: .superseded, notify: false); prepare(target)
    page = target; view.bringSubviewToFront(target.view)
  }

  func show(_ target: UIViewController, direction: Direction, animated: Bool, completion: ((Bool) -> Void)? = nil) {
    loadViewIfNeeded()
    cancelMotion(outcome: .superseded)
    prepare(target)
    guard let source = page, source !== target else {
      page = target; view.bringSubviewToFront(target.view)
      completion?(true)
      return
    }
    let bends = animated && !UIAccessibility.isReduceMotionEnabled && SceneSourceVisibility.isVisible(view)
    do {
      let id = try begin(source: source, target: target, direction: direction, gesture: false,
        preparesFrames: bends, completion: completion)
      guard motion?.id == id else { return }
      if bends { animate(to: 1) } else { finish(completed: true) }
    } catch { onFailure(error); completion?(false) }
  }

  private func begin(source: UIViewController, target: UIViewController, direction: Direction,
    gesture: Bool, preparesFrames: Bool = true, completion: ((Bool) -> Void)?) throws -> UUID {
    prepare(target)
    guard !preparesFrames || (view.bounds.width > 0 && view.bounds.height > 0) else {
      throw SceneRenderError.snapshotPending("page_bounds")
    }
    guard let id = beginOperation(source, target, gesture, completion) else {
      throw PageTurnMaterialUnavailable.changed
    }
    motion = .init(id: id, source: source, target: target, size: view.bounds.size, direction: direction,
      gesture: gesture)
    // Material owners submit their accepted borrows in this admission event.
    // Live paper stays in front while the same motion awaits their pixels and
    // retains the finger progress; capture completion never manufactures readiness.
    if gesture {
      motion?.contact = continuedContact ?? .init(initial: 0, origin: 0, initialTilt: 0,
        began: CACurrentMediaTime(), direction: direction)
      continuedContact = nil
    }
    guard preparesFrames, !UIAccessibility.isReduceMotionEnabled else { return id }
    acquireCurrentFrames(for: id)
    return id
  }

  /// Readiness belongs to the mounted page. A dirty source retains this
  /// motion/finger instead of capturing old Metal pixels or polling a timer.
  func sheetReadinessDidChange(_ sheet: UIViewController) {
    guard var motion, motion.source === sheet || motion.target === sheet else { return }
    if motion.frame != nil {
      // Keep the frozen pair while new live material prepares. Its flat frame
      // can retire only when the actual landing host is ready again.
      finishPresentedEndpoint(); return
    }
    motion.readinessGeneration &+= 1
    self.motion = motion
    let id = motion.id
    acquireCurrentFrames(for: id)
  }

  private func acquireCurrentFrames(for id: UUID) {
    guard let motion, motion.id == id, motion.frame == nil, frameAcquisition == nil,
      isSheetReadyForCapture(motion.source), isSheetReadyForCapture(motion.target) else { return }
    let acquisition = FrameAcquisition()
    frameAcquisition = acquisition
    let task = Task.immediate { @MainActor [weak self] in
      guard let self else { return }
      defer {
        acquisition.finish()
        if frameAcquisition === acquisition { frameAcquisition = nil }
      }
      do {
        let began = CACurrentMediaTime()
        // Both admitted owners live on this actor. Start their borrows here,
        // without sending each child through the generic pool and back before
        // its first WebKit/GPU submission. The structured pair still cancels
        // and drains together if either owner fails or motion is replaced.
        let acquire = acquireSheetFrame
        let sourcePage = motion.source, targetPage = motion.target
        let readSource: @MainActor @Sendable () async throws -> (isSource: Bool, frame: PageTurnFrame) = {
          guard !acquisition.isCancelled else { throw CancellationError() }
          return (true, try await acquire(sourcePage))
        }
        let readTarget: @MainActor @Sendable () async throws -> (isSource: Bool, frame: PageTurnFrame) = {
          guard !acquisition.isCancelled else { throw CancellationError() }
          return (false, try await acquire(targetPage))
        }
        let (source, target) = try await withThrowingTaskGroup(of: (isSource: Bool, frame: PageTurnFrame).self) { group in
          group.addImmediateTask(operation: readSource)
          group.addImmediateTask(operation: readTarget)
          var source: PageTurnFrame?, target: PageTurnFrame?
          while let result = try await group.next() {
            if result.isSource { source = result.frame } else { target = result.frame }
          }
          guard let source, let target else { throw PageTurnMaterialUnavailable.changed }
          return (source, target)
        }
        try await SheetCurlGPU.shared.preparePage()
        try Task.checkCancellation()
        guard !acquisition.isCancelled, var current = self.motion, current.id == id else { return }
        // Each owner delivered an immutable accepted cut. Subsequent live
        // publications cannot invalidate this already admitted physical pair.
        let leaf = motion.direction == .forward ? source : target
        let base = motion.direction == .forward ? target : source
        let width = leaf.texture.width, height = leaf.texture.height
        try curl.preparePages(leaf: leaf, base: base, operationID: id)
        current.frame = leaf; current.firstFrameSequence = curl.submittedFrameCount; self.motion = current
        onFramesAcquired?(.init(operationID: id, began: began, ended: CACurrentMediaTime(), pixels: width * height * 2))
        guard self.motion?.id == id else { return }
        render(current.progress); curl.animatesContinuously = current.animation != nil
      } catch is PageTurnMaterialUnavailable {
        guard !Task.isCancelled, let current = self.motion, current.id == id else { return }
        awaitCurrentMaterial(id: id, attemptedGeneration: motion.readinessGeneration,
          currentGeneration: current.readinessGeneration)
      } catch {
        guard !Task.isCancelled, self.motion?.id == id else { return }
        if error is CancellationError, let current = self.motion,
          current.readinessGeneration != motion.readinessGeneration {
          awaitCurrentMaterial(id: id, attemptedGeneration: motion.readinessGeneration,
            currentGeneration: current.readinessGeneration)
          return
        }
        if case SceneRenderError.resourceLimit = error, SceneRenderResources.shared.pendingReclamationCount > 0 {
          await SceneRenderResources.shared.finishPendingReclamations()
          guard !Task.isCancelled, self.motion?.id == id else { return }
          frameAcquisition = nil
          DispatchQueue.main.async { [weak self] in self?.acquireCurrentFrames(for: id) }
          return
        }
        onFailure(error)
        if self.motion?.id == id { finish(completed: false, outcome: .failed) }
      }
    }
    acquisition.attach(task)
  }

  private func awaitCurrentMaterial(id: UUID, attemptedGeneration: UInt64, currentGeneration: UInt64) {
    frameAcquisition = nil
    // Only an owner's explicit source revocation parks this accepted turn.
    // WebKit timeout, nil image and GPU failures retain the visible Retry path.
    // An edge received during acquisition could not start a second borrower.
    // Consume it once. With no new edge, the mounted owner's next readiness
    // publication resumes this same motion; there is no retry timer or loop.
    if currentGeneration != attemptedGeneration {
      DispatchQueue.main.async { [weak self] in self?.acquireCurrentFrames(for: id) }
    }
  }

  private func render(_ progress: Double) {
    guard var motion else { return }
    motion.progress = min(max(0, progress), 1)
    if motion.stagedLanding != nil, motion.progress != motion.terminal {
      motion.stagedLanding = nil; view.bringSubviewToFront(curl)
      curl.pageHierarchyDidChange()
    }
    self.motion = motion
    guard motion.frame != nil else { return }
    curl.updatePage(progress: motion.direction == .forward ? motion.progress : 1-motion.progress,
      anchor: motion.anchor, tilt: motion.tilt,
      layout: .init(sheetSize: view.bounds.size, clipsToSheet: true))
  }

  private func frameReady(_ image: PageTurnFrame, progress: Double, sequence: Int, readiness: NotebookMetalFrameReadiness) {
    guard readiness.isReady, var motion, motion.frame === image,
      let firstSequence = motion.firstFrameSequence, sequence >= firstSequence else { return }
    if let previous = motion.presentation {
      guard sequence > previous.sequence else { return }
      // Distinct drawables can share one OS display timestamp. Sequence owns
      // their order; the timestamp only rejects a receipt from an older frame.
      if let time = readiness.presentedTime,
        let oldTime = previous.readiness.presentedTime, time < oldTime { return }
    }
    let shown = motion.direction == .forward ? progress : 1-progress
    motion.presentation = (shown, sequence, readiness)
    self.motion = motion
    finishPresentedEndpoint()
  }

  private func finishPresentedEndpoint() {
    guard var motion, let terminal = motion.terminal, motion.progress == terminal,
      motion.presentation?.progress == terminal,
      motion.presentation?.sequence == curl.submittedFrameCount - 1 else { return }
    let landing = terminal == 1 ? motion.target : motion.source
    guard isSheetPresented(landing) else {
      guard motion.stagedLanding == nil, isSheetReadyForCapture(landing) else { return }
      // The frozen endpoint has actually appeared. Expose its current GPU-ready
      // live host so that it can earn its own OS receipt; an opaque curl above
      // it would make that receipt a prerequisite for its own visibility.
      // Keep the accepted pair and input gate until that receipt arrives.
      motion.stagedLanding = landing; self.motion = motion
      view.bringSubviewToFront(landing.view)
      curl.pageHierarchyDidChange()
      onStageLiveSheet(landing)
      return
    }
    finish(completed: terminal == 1, presented: true)
  }

  static func settlementDuration(distance: Double, velocity: Double, strokeSpeed: Double,
    inputDuration: Double, cadence: Double) -> Double {
    let speed = max(4, (distance < 0 ? -1 : 1)*velocity, strokeSpeed)
    return max(0, min(0.32, 2*abs(distance)/speed, inputDuration, cadence))
  }

  private func animate(to target: Double, velocity: Double = 0, strokeSpeed: Double = 0,
    inputDuration: Double = .infinity) {
    guard var motion else { return }
    if motion.stagedLanding != nil, motion.terminal != target {
      motion.stagedLanding = nil; view.bringSubviewToFront(curl)
      curl.pageHierarchyDidChange()
    }
    motion.contact = nil
    // Cancelling before capture changes no displayed pixels. Do not snapshot,
    // upload or wait for a fake Metal receipt for the still-live source.
    if target == 0, motion.frame == nil {
      self.motion = motion; finish(completed: false); return
    }
    if UIAccessibility.isReduceMotionEnabled { self.motion = motion; finish(completed: target == 1); return }
    // A previous burst cannot shorten cancellation after a new long hold.
    // Cadence expires continuously with elapsed input time, without a timeout
    // or a minimum animation duration imposed on a fresh fast swipe.
    let cadence = max(inputCadence, lastIntentTime.map { CACurrentMediaTime()-$0 } ?? .infinity)
    let duration = Self.settlementDuration(distance: target-motion.progress, velocity: velocity,
      strokeSpeed: strokeSpeed, inputDuration: inputDuration, cadence: cadence)
    if motion.progress == target || duration == 0 {
      motion.animation = nil; motion.terminal = target; self.motion = motion
      render(target); curl.animatesContinuously = false
      finishPresentedEndpoint(); return
    }
    motion.animation = (nil, motion.progress, target, duration, motion.tilt)
    motion.terminal = nil; self.motion = motion
    curl.animatesContinuously = motion.frame != nil
  }

  /// A new intent shortens the remaining travel to its input cadence, not an
  /// arbitrary 2× playback rate. Readiness callbacks never manufacture intent.
  func noteNavigationIntent(at now: Double = CACurrentMediaTime()) {
    inputCadence = lastIntentTime.map { max(0, now-$0) } ?? .infinity
    lastIntentTime = now
    guard var motion, motion.contact == nil, let animation = motion.animation else { return }
    let duration = min(animation.duration, inputCadence)
    motion.animation = (nil, motion.progress, animation.to, duration, motion.tilt)
    self.motion = motion
  }

  func retargetSettlement(to page: UIViewController) {
    guard let motion, motion.contact == nil else { return }
    let endpoint: Double
    if page === motion.source { endpoint = 0 }
    else if page === motion.target { endpoint = 1 }
    else { return } // Another pair starts only after this one is flat.
    if (motion.animation?.to ?? motion.terminal) != endpoint { animate(to: endpoint) }
  }

  private func advanceAnimation(at timestamp: Double) {
    guard var motion, motion.frame != nil, var animation = motion.animation else { return }
    let frameDuration = 1/Double(view.window?.screen.maximumFramesPerSecond ?? 60)
    if animation.duration < frameDuration, animation.start != nil, motion.presentation == nil { return }
    if animation.start == nil {
      // Even an intent faster than one refresh gets one curved image before
      // its endpoint, without a fixed-duration animation or a flat primer.
      animation.start = timestamp - min(animation.duration/2,
        frameDuration)
      motion.animation = animation
    }
    let fraction = animation.duration == 0 ? 1 : min(1, max(0, (timestamp-animation.start!)/animation.duration))
    let eased = fraction*(2-fraction)
    motion.tilt = animation.tilt*(1-fraction)
    if fraction == 1 { motion.terminal = animation.to }
    self.motion = motion
    render(fraction == 1 ? animation.to : animation.from+(animation.to-animation.from)*eased)
    if fraction == 1 { curl.animatesContinuously = false; finishPresentedEndpoint() }
  }

  /// An admitted contact grabs the existing pair without rebuilding either image.
  @discardableResult
  func grabSettlement(direction: Direction) -> Bool {
    guard var motion, motion.contact == nil, let origin = motion.animation?.to ?? motion.terminal else { return false }
    // The update scheduler can already have encoded a future animation pose.
    // Contact starts on the last OS-presented sheet, or the still-live source
    // before any curl was shown. A merely prepared pose cannot move the finger.
    if let pose = curl.presentedPagePose {
      motion.progress = motion.direction == .forward ? pose.progress : 1-pose.progress
      motion.anchor = pose.anchor; motion.tilt = pose.tilt
    } else { motion.progress = 0; motion.tilt = 0 }
    motion.contact = .init(initial: motion.progress, origin: origin, initialTilt: motion.tilt,
      began: CACurrentMediaTime(), direction: direction)
    if motion.stagedLanding != nil {
      motion.stagedLanding = nil; view.bringSubviewToFront(curl)
      curl.pageHierarchyDidChange()
    }
    motion.animation = nil; motion.terminal = nil
    self.motion = motion; curl.animatesContinuously = false
    // Replace an uncommitted early frame. An already published CA frame still
    // earns its own receipt; rendering this held pose never claims to revoke it.
    render(motion.progress)
    return true
  }

  private func finish(completed: Bool, outcome: PageTurnOutcome? = nil, notify: Bool = true, presented: Bool = false) {
    guard let motion else { return }
    // The executor reports a physical endpoint or interruption. Only the page
    // operation owner can install its landing and release the accepted pair.
    resolveOperation(motion.id, outcome ?? (completed ? .completed : .cancelled), presented, notify)
  }

  func resolveMotion(_ id: UUID, completed: Bool, presented: Bool) {
    guard let motion, motion.id == id else { return }
    self.motion = nil
    frameAcquisition?.cancel(); frameAcquisition = nil
    if presented, let contact = motion.contact {
      // The previous accepted turn reached its flat boundary under a new held
      // contact. Shift the same continuous coordinate into the next pair.
      continuedContact = .init(initial: completed ? contact.initial-1 : -contact.initial,
        origin: 0, initialTilt: contact.initialTilt, began: contact.began, direction: contact.direction)
    }
    page = completed ? motion.target : motion.source
    view.bringSubviewToFront(page!.view)
    view.sendSubviewToBack(curl)
    let host = presented ? page.flatMap(idleOutputHost) : nil
    curl.releaseSource(presented: presented,
      idleOutputHost: host?.window === view.window ? host : nil)
  }

  func cancelMotion(outcome: PageTurnOutcome = .cancelled, notify: Bool = true) {
    continuedContact = nil
    if motion != nil { finish(completed: false, outcome: outcome, notify: notify) }
    else if outcome == .cancelled { curl.releaseSource() }
  }
  isolated deinit { frameAcquisition?.cancel(); curl.releaseSource() }

  /// Warm pans and a cold contact whose neighbour becomes ready use the same
  /// motion owner. The admission recognizer keeps that original contact.
  @discardableResult
  func beginInteractiveTurn(direction: Direction, target: UIViewController? = nil) -> Bool {
    guard motion == nil, let page, let target = target ?? neighbor(page, direction), willTurn(target) else { return false }
    do {
      let id = try begin(source: page, target: target, direction: direction, gesture: true, completion: nil)
      return motion?.id == id
    } catch { onFailure(error); return false }
  }

  func updateInteractiveTurn(translation: CGFloat, verticalTranslation: CGFloat = 0) {
    guard var motion, let contact = motion.contact else { return }
    let sign = motion.direction == .forward ? -1.0 : 1.0
    let delta = translation * sign / max(1, view.bounds.width), travel = min(abs(delta), 1)
    motion.tilt = min(0.45, max(-0.45, contact.initialTilt + verticalTranslation/max(1, view.bounds.width)))
    let position = contact.initial*(1-travel) + contact.origin*travel + delta
    if contact.origin == 1, contact.direction == motion.direction, position >= 1 { motion.terminal = 1 }
    else if contact.origin == 0, contact.direction != motion.direction, position <= 0 { motion.terminal = 0 }
    else { motion.terminal = nil }
    self.motion = motion
    render(position)
    finishPresentedEndpoint()
  }

  func endInteractiveTurn(completed: Bool, velocity: CGFloat = 0, travel: CGFloat = 0,
    duration: Double? = nil, recordsIntent: Bool = true) {
    continuedContact = nil
    guard let motion, let contact = motion.contact else { return }
    let target = completed ? (contact.direction == motion.direction ? 1.0 : 0.0) : contact.origin
    if completed, recordsIntent {
      noteNavigationIntent()
      didAcceptTurn(target == 1 ? motion.target : motion.source)
    }
    let sign = motion.direction == .forward ? -1.0 : 1.0
    let interval = duration ?? max(0, CACurrentMediaTime()-contact.began)
    let strokeSpeed = interval > 0 ? abs(travel)/max(1, view.bounds.width)/interval : 0
    animate(to: target, velocity: velocity*sign/max(1, view.bounds.width), strokeSpeed: strokeSpeed,
      inputDuration: completed && travel != 0 ? interval : .infinity)
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
    // Prepared pixels do not expose a layer. Its first scheduled frame and
    // exposure publish in the same UIKit update as every subsequent curl frame.
    curl.isHidden = true
    curl.isUserInteractionEnabled = false
    curl.enableSetNeedsDisplay = false
    curl.onDisplayUpdate = { [weak self] timestamp in self?.advanceAnimation(at: timestamp) }
    curl.permitsFrameSubmission = { [weak self] in self?.motion != nil }
    curl.onPageFrameWillPresent = { [weak self] id in
      guard let self, self.motion?.id == id else { return }
      self.view.bringSubviewToFront(self.curl)
      self.curl.pageHierarchyDidChange()
    }
    curl.onPageDetached = { [weak self] in self?.cancelMotion() }
    curl.onPageRenderFailure = { [weak self] error in
      guard let self, let id = self.motion?.id else { return }
      self.onFailure(error)
      if self.motion?.id == id { self.finish(completed: false, outcome: .failed) }
    }
    curl.onPageFrameReady = { [weak self] image, progress, sequence, readiness in
      self?.frameReady(image, progress: progress, sequence: sequence, readiness: readiness)
    }
  }

  @objc private func panned(_ pan: UIPanGestureRecognizer) {
    switch pan.state {
    case .began:
      guard let direction = panDirection else { return }
      if beginInteractiveTurn(direction: direction) {
        motion?.anchor = pan.location(in: view).y/max(1, view.bounds.width)
      }
    case .changed:
      let translation = pan.translation(in: view)
      updateInteractiveTurn(translation: translation.x, verticalTranslation: translation.y)
    case .ended, .cancelled, .failed:
      panDirection = nil
      guard let motion, motion.gesture else { return }
      let sign: CGFloat = motion.direction == .forward ? -1 : 1
      let velocity = pan.velocity(in: view.window).x * sign
      let travel = pan.translation(in: view.window).x * sign
      let completed = Self.completesGesture(travel: travel, velocity: velocity, ended: pan.state == .ended)
      endInteractiveTurn(completed: completed, velocity: pan.velocity(in: view).x,
        travel: pan.translation(in: view).x)
    default: break
    }
  }
}
