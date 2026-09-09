import SwiftUI
import UIKit

struct WorkspaceGestureLayer: UIViewRepresentable {
  let isEnabled: Bool
  let defersHorizontalMotionToPageTurn: Bool
  let inputGate: NotebookInputGate
  let onCamera: (WorkspaceMagnificationPhase) -> Void
  let onUndo: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      defersHorizontalMotionToPageTurn: defersHorizontalMotionToPageTurn,
      isEnabled: isEnabled,
      inputGate: inputGate,
      onCamera: onCamera,
      onUndo: onUndo
    )
  }

  func makeUIView(context: Context) -> GestureAnchorView {
    let view = GestureAnchorView()
    view.isUserInteractionEnabled = false
    view.onWindowChange = { [weak coordinator = context.coordinator, weak view] window in
      guard let coordinator, let view else { return }
      coordinator.install(on: window, inside: view)
    }
    return view
  }

  func updateUIView(_ view: GestureAnchorView, context: Context) {
    context.coordinator.onCamera = onCamera
    context.coordinator.onUndo = onUndo
    context.coordinator.defersHorizontalMotionToPageTurn =
      defersHorizontalMotionToPageTurn
    context.coordinator.isEnabled = isEnabled
    context.coordinator.inputGate = inputGate
    if let window = view.window {
      context.coordinator.install(on: window, inside: view)
    }
  }

  static func dismantleUIView(_ view: GestureAnchorView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var defersHorizontalMotionToPageTurn: Bool {
      didSet {
        recognizer?.defersHorizontalMotionToPageTurn =
          defersHorizontalMotionToPageTurn
      }
    }
    var isEnabled: Bool {
      didSet {
        if oldValue != isEnabled { recognizer?.isEnabled = isEnabled }
      }
    }
    var onCamera: (WorkspaceMagnificationPhase) -> Void
    var onUndo: () -> Void
    var inputGate: NotebookInputGate {
      didSet {
        recognizer?.inputGate = inputGate
        contactObserver?.use(inputGate)
      }
    }

    private weak var hostView: UIView?
    private weak var sceneView: UIView?
    private var recognizer: TwoFingerPaperGestureRecognizer?
    private var contactObserver: NotebookContactObserver?
    private var repeatTask: Task<Void, Never>?

    init(
      defersHorizontalMotionToPageTurn: Bool,
      isEnabled: Bool,
      inputGate: NotebookInputGate,
      onCamera: @escaping (WorkspaceMagnificationPhase) -> Void,
      onUndo: @escaping () -> Void
    ) {
      self.defersHorizontalMotionToPageTurn =
        defersHorizontalMotionToPageTurn
      self.isEnabled = isEnabled
      self.inputGate = inputGate
      self.onCamera = onCamera
      self.onUndo = onUndo
    }

    func install(on hostView: UIView?, inside sceneView: UIView) {
      guard let hostView else {
        uninstall()
        return
      }
      guard self.hostView !== hostView || self.sceneView !== sceneView else {
        return
      }
      uninstall()
      let recognizer = TwoFingerPaperGestureRecognizer(
        target: self,
        action: #selector(handle)
      )
      recognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      recognizer.cancelsTouchesInView = true
      recognizer.delaysTouchesBegan = false
      recognizer.delaysTouchesEnded = false
      recognizer.defersHorizontalMotionToPageTurn =
        defersHorizontalMotionToPageTurn
      recognizer.inputGate = inputGate
      recognizer.isEnabled = isEnabled
      recognizer.delegate = self
      hostView.addGestureRecognizer(recognizer)
      let observer = NotebookContactObserver(gate: inputGate)
      observer.delegate = self
      hostView.addGestureRecognizer(observer)
      self.hostView = hostView
      self.sceneView = sceneView
      self.recognizer = recognizer
      contactObserver = observer
    }

    func uninstall() {
      repeatTask?.cancel()
      repeatTask = nil
      if let recognizer { hostView?.removeGestureRecognizer(recognizer) }
      if let contactObserver {
        contactObserver.finish()
        hostView?.removeGestureRecognizer(contactObserver)
      }
      contactObserver = nil
      recognizer = nil
      hostView = nil
      sceneView = nil
    }

    @objc private func handle(_ recognizer: TwoFingerPaperGestureRecognizer) {
      switch recognizer.state {
      case .began where recognizer.intent == .hold:
        onUndo()
        startRepeating()
      case .began
      where recognizer.intent == .magnification
        || recognizer.intent == .navigation:
        repeatTask?.cancel()
        onCamera(
          .began(
            centroid: recognizer.startCentroidValue,
            isOpeningApproach: recognizer.intent == .magnification
              && recognizer.isOpeningApproach
          )
        )
        onCamera(
          .changed(
            scale: recognizer.magnification,
            velocity: recognizer.magnificationVelocity,
            elapsed: recognizer.gestureElapsed,
            centroid: recognizer.centroid
          )
        )
      case .changed
      where recognizer.intent == .magnification
        || recognizer.intent == .navigation:
        onCamera(
          .changed(
            scale: recognizer.magnification,
            velocity: recognizer.magnificationVelocity,
            elapsed: recognizer.gestureElapsed,
            centroid: recognizer.centroid
          )
        )
      case .ended:
        repeatTask?.cancel()
        repeatTask = nil
        switch recognizer.intent {
        case .tap:
          onUndo()
        case .navigation:
          finishCamera(recognizer)
        case .magnification:
          finishCamera(recognizer)
        case .hold, .undecided:
          break
        }
      case .cancelled, .failed:
        repeatTask?.cancel()
        repeatTask = nil
        if recognizer.intent == .magnification
          || recognizer.intent == .navigation
        {
          onCamera(.cancelled)
        }
      default:
        break
      }
    }

    private func startRepeating() {
      repeatTask?.cancel()
      repeatTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(95))
          guard !Task.isCancelled, let self, recognizer?.permitsUndoRepetition == true else { return }
          onUndo()
        }
      }
    }

    private func finishCamera(_ recognizer: TwoFingerPaperGestureRecognizer) {
      onCamera(
        .ended(
          scale: recognizer.magnification,
          velocity: recognizer.magnificationVelocity,
          elapsed: recognizer.gestureElapsed,
          centroid: recognizer.centroid
        )
      )
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldReceive touch: UITouch
    ) -> Bool {
      guard let sceneView else { return false }
      return inputGate.permitsSceneContact(at: touch.location(in: sceneView.window))
        && sceneReceives(touch, inside: sceneView)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

/// Window-level recognizers span embedded paper/WebKit hosts, but a presented
/// UIKit menu or sheet has its own input owner even when it overlaps the board.
@MainActor
private func sceneReceives(_ touch: UITouch, inside anchor: UIView) -> Bool {
  guard anchor.window != nil, anchor.bounds.contains(touch.location(in: anchor)) else { return false }
  guard let source = touch.view else { return true }
  var responder: UIResponder? = anchor
  while let current = responder {
    if let controller = current as? UIViewController {
      return source.isDescendant(of: controller.view)
    }
    responder = current.next
  }
  return false
}

/// The existing window gesture owner observes contact lifetime independently
/// of which gesture wins. It never delays, cancels, or claims the touch.
@MainActor
final class NotebookContactObserver: UIGestureRecognizer {
  private let source = UUID()
  private var contacts: Set<ObjectIdentifier> = []
  private var gate: NotebookInputGate

  init(gate: NotebookInputGate) {
    self.gate = gate
    super.init(target: nil, action: nil)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  func use(_ next: NotebookInputGate) {
    guard gate !== next else { return }
    if !contacts.isEmpty { gate.endContact(source: source); next.beginContact(source: source) }
    gate = next
  }

  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    contacts.formUnion(touches.map(ObjectIdentifier.init))
    gate.beginContact(source: source)
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }
  private func end(_ touches: Set<UITouch>) {
    contacts.subtract(touches.map(ObjectIdentifier.init))
    if contacts.isEmpty { finish(); state = .failed }
  }
  func finish() {
    contacts.removeAll()
    gate.endContact(source: source)
  }
  override func reset() { super.reset(); finish() }
}

@MainActor
final class GestureAnchorView: UIView {
  var onWindowChange: ((UIWindow?) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onWindowChange?(window)
  }
}

struct BoardPanView: UIViewRepresentable {
  let isEnabled: Bool
  let itemFrames: [CGRect]
  let inputGate: NotebookInputGate
  let onTap: () -> Void
  let onBegan: () -> Void
  let onChanged: (CGPoint) -> Void
  let onEnded: (CGPoint) -> Void
  let onCancelled: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isEnabled: isEnabled,
      itemFrames: itemFrames,
      inputGate: inputGate,
      onTap: onTap,
      onBegan: onBegan,
      onChanged: onChanged,
      onEnded: onEnded,
      onCancelled: onCancelled
    )
  }

  func makeUIView(context: Context) -> GestureAnchorView {
    let view = GestureAnchorView()
    view.isUserInteractionEnabled = false
    view.onWindowChange = { [weak coordinator = context.coordinator, weak view] window in
      guard let coordinator, let view else { return }
      coordinator.install(on: window, inside: view)
    }
    return view
  }

  func updateUIView(_ view: GestureAnchorView, context: Context) {
    context.coordinator.isEnabled = isEnabled
    context.coordinator.itemFrames = itemFrames
    context.coordinator.inputGate = inputGate
    context.coordinator.onTap = onTap
    context.coordinator.onBegan = onBegan
    context.coordinator.onChanged = onChanged
    context.coordinator.onEnded = onEnded
    context.coordinator.onCancelled = onCancelled
    if let window = view.window {
      context.coordinator.install(on: window, inside: view)
    }
  }

  static func dismantleUIView(
    _ view: GestureAnchorView,
    coordinator: Coordinator
  ) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isEnabled: Bool {
      didSet {
        guard oldValue != isEnabled else { return }
        // UIKit can send its cancellation target synchronously from this
        // setter inside updateUIView. End native ownership before disabling
        // the recognizer; publish the SwiftUI completion after that update.
        if !isEnabled { cancelFingerSequence(deferCallbacks: true) }
        pan?.isEnabled = isEnabled
        tap?.isEnabled = isEnabled
      }
    }
    var itemFrames: [CGRect]
    var inputGate: NotebookInputGate {
      didSet {
        guard oldValue !== inputGate else { return }
        oldValue.unregisterFingerCancellation(source: inputSource)
        cancelFingerSequence(deferCallbacks: true)
        if hostView != nil { registerCancellation() }
      }
    }
    var onTap: () -> Void
    var onBegan: () -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    private weak var hostView: UIView?
    private weak var sceneView: UIView?
    private var pan: UIPanGestureRecognizer?
    private var tap: UITapGestureRecognizer?
    private weak var startingCover: NotebookInteractionTouchView?
    private var panOrigin = CGPoint.zero
    private let inputSource = UUID()
    private var panRevision: UInt64?
    private var tapRevision: UInt64?
    private var panIsActive = false
    private var deferredPanCancellation: (() -> Void)?

    init(
      isEnabled: Bool,
      itemFrames: [CGRect],
      inputGate: NotebookInputGate,
      onTap: @escaping () -> Void,
      onBegan: @escaping () -> Void,
      onChanged: @escaping (CGPoint) -> Void,
      onEnded: @escaping (CGPoint) -> Void,
      onCancelled: @escaping () -> Void
    ) {
      self.isEnabled = isEnabled
      self.itemFrames = itemFrames
      self.inputGate = inputGate
      self.onTap = onTap
      self.onBegan = onBegan
      self.onChanged = onChanged
      self.onEnded = onEnded
      self.onCancelled = onCancelled
    }

    func install(on hostView: UIView?, inside sceneView: UIView) {
      guard let hostView else {
        uninstall()
        return
      }
      guard self.hostView !== hostView || self.sceneView !== sceneView else {
        return
      }
      uninstall()
      let pan = UIPanGestureRecognizer(
        target: self,
        action: #selector(handle)
      )
      pan.minimumNumberOfTouches = 1
      pan.maximumNumberOfTouches = 1
      pan.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      pan.cancelsTouchesInView = false
      pan.delegate = self
      pan.isEnabled = isEnabled
      let tap = UITapGestureRecognizer(
        target: self,
        action: #selector(handleTap)
      )
      tap.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      tap.cancelsTouchesInView = false
      tap.delaysTouchesBegan = false
      tap.delaysTouchesEnded = false
      tap.delegate = self
      tap.isEnabled = isEnabled
      hostView.addGestureRecognizer(pan)
      hostView.addGestureRecognizer(tap)
      self.hostView = hostView
      self.sceneView = sceneView
      self.pan = pan
      self.tap = tap
      registerCancellation()
    }

    func uninstall() {
      inputGate.unregisterFingerCancellation(source: inputSource)
      cancelFingerSequence(deferCallbacks: true)
      if let pan { hostView?.removeGestureRecognizer(pan) }
      if let tap { hostView?.removeGestureRecognizer(tap) }
      pan = nil
      tap = nil
      startingCover = nil
      hostView = nil
      sceneView = nil
    }

    private func registerCancellation() {
      inputGate.registerFingerCancellation(source: inputSource) { [weak self] in
        self?.flushPanCancellation()
        self?.cancelFingerSequence()
      }
    }

    private func cancelFingerSequence(deferCallbacks: Bool = false) {
      panRevision = nil
      tapRevision = nil
      if panIsActive {
        panIsActive = false
        if deferCallbacks {
          let cancellation = onCancelled
          deferredPanCancellation = cancellation
          DispatchQueue.main.async { self.flushPanCancellation() }
        } else {
          onCancelled()
        }
      }
      if let pan, pan.state == .began || pan.state == .changed {
        pan.isEnabled = false
        pan.isEnabled = isEnabled
      }
    }

    private func flushPanCancellation() {
      let cancellation = deferredPanCancellation
      deferredPanCancellation = nil
      cancellation?()
    }

    @objc func handle(_ pan: UIPanGestureRecognizer) {
      let point = pan.location(in: sceneView)
      // The touch-down point also includes UIKit's recognition travel.
      let translation = CGPoint(x: point.x - panOrigin.x, y: point.y - panOrigin.y)
      receivePan(state: pan.state, translation: translation)
    }

    func receivePan(state: UIGestureRecognizer.State, translation: CGPoint) {
      guard let panRevision, inputGate.acceptsFingerSequence(panRevision) else {
        cancelFingerSequence()
        return
      }
      switch state {
      case .began:
        panIsActive = true
        onBegan()
        onChanged(translation)
      case .changed:
        guard panIsActive else { return }
        onChanged(translation)
      case .ended:
        guard panIsActive else { return }
        panIsActive = false
        self.panRevision = nil
        onEnded(translation)
      case .cancelled, .failed:
        cancelFingerSequence()
      default:
        break
      }
    }

    @objc private func handleTap() {
      guard let revision = tapRevision, inputGate.acceptsFingerSequence(revision) else { return }
      tapRevision = nil
      onTap()
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldReceive touch: UITouch
    ) -> Bool {
      guard isEnabled, let sceneView, sceneView.window != nil else { return false }
      // A following contact must not be cleared by the previous pan's queued
      // completion, even if disable and re-enable preceded the next run loop.
      flushPanCancellation()
      guard let revision = inputGate.beginFingerSequence(), !Self.ownsInteractiveInput(touch.view) else { return false }
      guard inputGate.permitsSceneContact(at: touch.location(in: sceneView.window)),
        sceneReceives(touch, inside: sceneView) else { return false }
      let point = touch.location(in: sceneView)
      let isFreeBoard = !itemFrames.contains(where: { $0.contains(point) })
      if gestureRecognizer === pan {
        panRevision = revision
        panOrigin = point
        startingCover = touch.view as? NotebookInteractionTouchView
        // The cover's direct-touch surface can hand motion to the camera.
        // Its passthrough editors and interactive content keep their own input.
        return startingCover != nil || isFreeBoard
      }
      tapRevision = revision
      return isFreeBoard
    }

    static func ownsInteractiveInput(_ view: UIView?) -> Bool {
      var current = view
      while let candidate = current {
        if candidate is UIControl || candidate is UITextView || candidate is UIScrollView { return true }
        current = candidate.superview
      }
      return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      let revision = gestureRecognizer === pan ? panRevision : tapRevision
      guard let revision, inputGate.acceptsFingerSequence(revision) else { return false }
      guard gestureRecognizer === pan, let startingCover else { return true }
      return startingCover.yieldToCameraPan()
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

/// One direct-touch owner for a closed notebook. UIKit owns tap cadence and
/// reports `UITouch.tapCount`; this view owns pickup and movement from the same
/// finger stream. Pencil touches remain owned by the window-level spatial ink
/// recognizer.
struct NotebookInteractionView: UIViewRepresentable {
  let inputGate: NotebookInputGate
  let permitsManipulation: Bool
  let canBeginContact: () -> Bool
  let passthroughFrames: [CGRect]
  let onTap: (CGPoint, Int) -> Void
  let onLiftChanged: (Bool) -> Void
  let onTranslationChanged: (CGSize) -> Void
  let onTranslationEnded: (CGSize) -> Void
  let onCancelled: () -> Void

  func makeUIView(context: Context) -> NotebookInteractionTouchView {
    let view = NotebookInteractionTouchView(inputGate: inputGate)
    view.backgroundColor = .clear
    view.isMultipleTouchEnabled = true
    view.accessibilityElementsHidden = true
    return view
  }

  func updateUIView(
    _ view: NotebookInteractionTouchView,
    context: Context
  ) {
    view.passthroughFrames = passthroughFrames
    view.useInputGate(inputGate)
    view.canBeginContact = canBeginContact
    view.onTap = onTap
    view.onLiftChanged = onLiftChanged
    view.onTranslationChanged = onTranslationChanged
    view.onTranslationEnded = onTranslationEnded
    view.onCancelled = onCancelled
    view.setPermitsManipulation(permitsManipulation)
  }

  static func dismantleUIView(
    _ view: NotebookInteractionTouchView,
    coordinator: Void
  ) {
    view.cancelInteraction(deferCallbacks: true)
  }
}

@MainActor
final class NotebookInteractionTouchView: UIView {
  private static let liftDelay: TimeInterval = 0.18
  private static let movementTolerance: CGFloat = 18

  var onTap: (CGPoint, Int) -> Void = { _, _ in }
  var canBeginContact: () -> Bool = { true }
  var onLiftChanged: (Bool) -> Void = { _ in }
  var onTranslationChanged: (CGSize) -> Void = { _ in }
  var onTranslationEnded: (CGSize) -> Void = { _ in }
  var onCancelled: () -> Void = {}
  var passthroughFrames: [CGRect] = []
  private(set) var permitsManipulation = true

  private weak var activeTouch: UITouch?
  private var startPoint = CGPoint.zero
  private var latestTranslation = CGSize.zero
  private var maximumTravel: CGFloat = 0
  private var liftWorkItem: DispatchWorkItem?
  private var isLifted = false
  private var manipulationAllowedForContact = false
  private var hasLiftedDuringContact = false
  private var contactGeneration = 0
  private var deferredLiftCancellation: (() -> Void)?
  private var inputGate: NotebookInputGate
  private let inputSource = UUID()
  private var fingerGeneration: UInt64?

  init(inputGate: NotebookInputGate) {
    self.inputGate = inputGate
    super.init(frame: .zero)
    registerCancellation()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(inputGate:)") }

  func useInputGate(_ next: NotebookInputGate) {
    guard inputGate !== next else { return }
    inputGate.unregisterFingerCancellation(source: inputSource)
    cancelInteraction(deferCallbacks: true)
    inputGate = next
    registerCancellation()
  }

  private func registerCancellation() {
    inputGate.registerFingerCancellation(source: inputSource) { [weak self] in
      self?.cancelInteraction()
    }
  }

  isolated deinit { inputGate.unregisterFingerCancellation(source: inputSource) }

  /// Admission can close during a SwiftUI update. Release native ownership now,
  /// but notify the SwiftUI gesture owner only after that update has completed.
  func setPermitsManipulation(_ permitted: Bool) {
    permitsManipulation = permitted
    guard !permitted else { return }
    manipulationAllowedForContact = false
    liftWorkItem?.cancel()
    liftWorkItem = nil
    if isLifted {
      isLifted = false
      enqueueLiftCancellation()
    }
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    super.point(inside: point, with: event)
      && !passthroughFrames.contains(where: { $0.contains(point) })
  }

  override func touchesBegan(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    flushLiftCancellation()
    guard canBeginContact(), let generation = inputGate.beginFingerSequence() else { return }
    let directTouches = touches.filter { $0.type == .direct }
    guard activeTouch == nil, directTouches.count == 1,
      let touch = directTouches.first
    else {
      if !directTouches.isEmpty { cancelInteraction() }
      return
    }
    activeTouch = touch
    fingerGeneration = generation
    startPoint = touch.location(in: window)
    latestTranslation = .zero
    maximumTravel = 0
    contactGeneration += 1
    hasLiftedDuringContact = false
    manipulationAllowedForContact = permitsManipulation
    if manipulationAllowedForContact { scheduleLift() }
  }

  override func touchesMoved(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    flushLiftCancellation()
    guard let fingerGeneration, inputGate.acceptsFingerSequence(fingerGeneration) else {
      cancelInteraction(); return
    }
    guard let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else { return }
    let point = activeTouch.location(in: window)
    latestTranslation = CGSize(
      width: point.x - startPoint.x,
      height: point.y - startPoint.y
    )
    maximumTravel = max(
      maximumTravel,
      hypot(latestTranslation.width, latestTranslation.height)
    )
    if !isLifted, maximumTravel > Self.movementTolerance {
      liftWorkItem?.cancel()
      liftWorkItem = nil
    }
    if isLifted { onTranslationChanged(latestTranslation) }
  }

  override func touchesEnded(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    guard let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else { return }
    let point = activeTouch.location(in: window)
    latestTranslation = CGSize(
      width: point.x - startPoint.x,
      height: point.y - startPoint.y
    )
    maximumTravel = max(
      maximumTravel,
      hypot(latestTranslation.width, latestTranslation.height)
    )
    finishInteraction(
      acceptTap: true,
      tapLocation: activeTouch.location(in: self),
      tapCount: activeTouch.tapCount
    )
  }

  override func touchesCancelled(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    guard let activeTouch,
      touches.contains(where: { $0 === activeTouch })
    else { return }
    cancelInteraction()
  }

  func cancelInteraction(deferCallbacks: Bool = false) {
    finishInteraction(
      acceptTap: false, tapLocation: .zero, tapCount: 0,
      deferCallbacks: deferCallbacks
    )
  }

  /// Movement takes the pending finger from this cover; a completed hold keeps
  /// the same finger here until the item is dropped.
  func yieldToCameraPan() -> Bool {
    guard activeTouch != nil, !isLifted else { return false }
    cancelInteraction()
    return true
  }

  private func scheduleLift() {
    liftWorkItem?.cancel()
    let generation = contactGeneration
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, activeTouch != nil,
        contactGeneration == generation, manipulationAllowedForContact,
        let fingerGeneration, inputGate.acceptsFingerSequence(fingerGeneration),
        permitsManipulation,
        maximumTravel <= Self.movementTolerance
      else { return }
      isLifted = true
      hasLiftedDuringContact = true
      onLiftChanged(true)
    }
    liftWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.liftDelay,
      execute: workItem
    )
  }

  private func finishInteraction(
    acceptTap: Bool,
    tapLocation: CGPoint,
    tapCount: Int,
    deferCallbacks: Bool = false
  ) {
    let wasLifted = isLifted
    let translation = latestTranslation
    let wasTap =
      acceptTap && !hasLiftedDuringContact
      && maximumTravel <= Self.movementTolerance
    liftWorkItem?.cancel()
    liftWorkItem = nil
    activeTouch = nil
    fingerGeneration = nil
    latestTranslation = .zero
    maximumTravel = 0
    isLifted = false
    manipulationAllowedForContact = false
    hasLiftedDuringContact = false
    contactGeneration += 1

    if wasLifted {
      if acceptTap {
        onTranslationEnded(translation)
        onLiftChanged(false)
      } else {
        enqueueLiftCancellation()
      }
    }
    if !deferCallbacks { flushLiftCancellation() }
    if wasTap {
      onTap(tapLocation, tapCount)
    }
  }

  private func enqueueLiftCancellation() {
    guard deferredLiftCancellation == nil else { return }
    let cancelled = onCancelled
    let liftChanged = onLiftChanged
    deferredLiftCancellation = {
      cancelled()
      liftChanged(false)
    }
    DispatchQueue.main.async { self.flushLiftCancellation() }
  }

  private func flushLiftCancellation() {
    let cancellation = deferredLiftCancellation
    deferredLiftCancellation = nil
    cancellation?()
  }
}
