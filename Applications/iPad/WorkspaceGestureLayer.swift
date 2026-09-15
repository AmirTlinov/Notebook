import SwiftUI
import UIKit

/// A physical interactive program opts in explicitly. A WK paper host does
/// not: the WebKit class alone says nothing about the contact's scene owner.
@MainActor
protocol NotebookSceneFingerInputOwner: AnyObject {
  func sceneFingerOwner(at point: CGPoint) -> NotebookInputGate.FingerContactOwner?
}

@MainActor
enum NotebookSceneFingerRouting {
  static func owner(of view: UIView?, at point: CGPoint? = nil) -> NotebookInputGate.FingerContactOwner {
    var current = view
    while let candidate = current {
      if let owner = candidate as? NotebookSceneFingerInputOwner,
        let resolved = owner.sceneFingerOwner(at: point.map { candidate.convert($0, from: view) }
          ?? CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)) {
        return resolved
      }
      if candidate is UIControl || candidate is UITextView {
        return .nativeInput(ObjectIdentifier(candidate))
      }
      if let scroll = candidate as? UIScrollView,
        scroll.isScrollEnabled, scroll.panGestureRecognizer.isEnabled {
        return .nativeInput(ObjectIdentifier(scroll))
      }
      current = candidate.superview
    }
    return .scene
  }

  static func owner(of touch: UITouch, gate: NotebookInputGate) -> NotebookInputGate.FingerContactOwner {
    gate.fingerContactOwner(for: ObjectIdentifier(touch)) { owner(of: touch.view, at: touch.location(in: touch.view)) }
  }
}

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
    private var cameraIsActive = false

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
      cameraIsActive = false
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
        updateCamera(recognizer)
      case .changed
      where recognizer.intent == .magnification
        || recognizer.intent == .navigation:
        updateCamera(recognizer)
      case .ended:
        repeatTask?.cancel()
        repeatTask = nil
        switch recognizer.intent {
        case .tap:
          onUndo()
        case .navigation:
          updateCamera(recognizer)
          finishCamera(recognizer)
        case .magnification:
          updateCamera(recognizer)
          finishCamera(recognizer)
        case .hold, .undecided:
          break
        }
        cameraIsActive = false
      case .cancelled, .failed:
        repeatTask?.cancel()
        repeatTask = nil
        if cameraIsActive {
          onCamera(.cancelled)
        }
        cameraIsActive = false
      default:
        break
      }
    }

    private func updateCamera(_ recognizer: TwoFingerPaperGestureRecognizer) {
      repeatTask?.cancel(); repeatTask = nil
      if !cameraIsActive {
        cameraIsActive = true
        onCamera(.began(centroid: recognizer.startCentroidValue,
          isOpeningApproach: recognizer.intent == .magnification && recognizer.isOpeningApproach))
      }
      onCamera(.changed(scale: recognizer.magnification, velocity: recognizer.magnificationVelocity,
        elapsed: recognizer.gestureElapsed, centroid: recognizer.centroid))
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
      guard inputGate.permitsSceneContact(at: touch.location(in: sceneView.window), kind: .finger),
        sceneReceives(touch, inside: sceneView) else { return false }
      let owner = NotebookSceneFingerRouting.owner(of: touch, gate: inputGate)
      // The passive observer still follows native input for admission and
      // persistence. The camera cannot take that owner's first or later finger.
      return gestureRecognizer === contactObserver || owner.permitsSceneNavigation
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
func sceneReceives(_ touch: UITouch, inside anchor: UIView) -> Bool {
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

  isolated deinit {
    gate.endFingerContacts(contacts)
    gate.endContact(source: source)
  }

  func use(_ next: NotebookInputGate) {
    guard gate !== next else { return }
    if !contacts.isEmpty {
      gate.transferFingerContacts(contacts, to: next)
      gate.endContact(source: source); next.beginContact(source: source)
    }
    gate = next
  }

  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    for touch in touches {
      _ = NotebookSceneFingerRouting.owner(of: touch, gate: gate)
      NotebookInteractionDiagnostics.contact(touch, phase: "began")
    }
    gate.notifyAcceptedContact()
    contacts.formUnion(touches.map(ObjectIdentifier.init))
    gate.beginContact(source: source)
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    for touch in touches { NotebookInteractionDiagnostics.contact(touch, phase: "ended") }
    end(touches)
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    for touch in touches { NotebookInteractionDiagnostics.contact(touch, phase: "cancelled") }
    end(touches)
  }
  private func end(_ touches: Set<UITouch>) {
    let ended = Set(touches.map(ObjectIdentifier.init))
    gate.endFingerContacts(ended)
    contacts.subtract(ended)
    if contacts.isEmpty { finish(); state = .failed }
  }
  func finish() {
    NotebookInteractionDiagnostics.abandon(contacts)
    gate.endFingerContacts(contacts)
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
    private let inputSource = UUID()
    private var panRevision: UInt64?
    private var tapRevision: UInt64?
    private var panIsActive = false
    private var panTouchdown: CGPoint?
    private var panRecognitionOffset = CGPoint.zero
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
      pan.cancelsTouchesInView = true
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
      panTouchdown = nil
      panRecognitionOffset = .zero
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
      let measured = pan.translation(in: sceneView)
      if pan.state == .began, let panTouchdown {
        let point = pan.location(in: sceneView)
        // UIKit may start accumulated translation only after its recognition
        // threshold. Retain that first travel once, then use its continuous
        // measurement; a later second finger cannot replace the origin.
        panRecognitionOffset = .init(x: point.x - panTouchdown.x - measured.x,
          y: point.y - panTouchdown.y - measured.y)
      }
      receivePan(state: pan.state, translation: .init(x: measured.x + panRecognitionOffset.x,
        y: measured.y + panRecognitionOffset.y))
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
        panTouchdown = nil
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
      guard let revision = inputGate.beginFingerSequence() else { return false }
      guard inputGate.permitsSceneContact(at: touch.location(in: sceneView.window), kind: .finger),
        sceneReceives(touch, inside: sceneView) else { return false }
      let owner = NotebookSceneFingerRouting.owner(of: touch, gate: inputGate)
      guard owner.permitsSceneNavigation else { return false }
      let point = touch.location(in: sceneView)
      let isFreeBoard = !itemFrames.contains(where: { $0.contains(point) })
      if gestureRecognizer === pan {
        if !panIsActive, gestureRecognizer.numberOfTouches == 0 {
          panRevision = revision
          panTouchdown = point
          panRecognitionOffset = .zero
          startingCover = touch.view as? NotebookInteractionTouchView
        }
        // The actual native owner has already admitted this contact to the
        // scene. A passive drawing's rectangle cannot take it back merely
        // because it is an element rather than empty board. Covers still
        // arbitrate their pending hold in gestureRecognizerShouldBegin.
        return true
      }
      tapRevision = revision
      return isFreeBoard && owner == .scene
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
  let ownerIsAvailable: () -> Bool
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
    view.onTap = onTap
    view.onLiftChanged = onLiftChanged
    view.onTranslationChanged = onTranslationChanged
    view.onTranslationEnded = onTranslationEnded
    view.onCancelled = onCancelled
    view.updateOwnerAvailability(ownerIsAvailable)
  }

  static func dismantleUIView(
    _ view: NotebookInteractionTouchView,
    coordinator: Void
  ) {
    view.updateOwnerAvailability { false }
  }
}

@MainActor
final class NotebookInteractionTouchView: UIView {
  static let liftDelay: TimeInterval = 0.18
  static let movementTolerance: CGFloat = 18

  var onTap: (CGPoint, Int) -> Void = { _, _ in }
  var onLiftChanged: (Bool) -> Void = { _ in }
  var onTranslationChanged: (CGSize) -> Void = { _ in }
  var onTranslationEnded: (CGSize) -> Void = { _ in }
  var onCancelled: () -> Void = {}
  var passthroughFrames: [CGRect] = []
  private var ownerIsAvailable: () -> Bool = { true }

  private weak var activeTouch: UITouch?
  private var startPoint = CGPoint.zero
  private var latestTranslation = CGSize.zero
  private var maximumTravel: CGFloat = 0
  private var liftWorkItem: DispatchWorkItem?
  private var isLifted = false
  private var hasLiftedDuringContact = false
  private var contactGeneration = 0
  private var deferredLiftCancellation: (() -> Void)?
  private var inputGate: NotebookInputGate
  private let inputSource = UUID()
  private var fingerGeneration: UInt64?
  private struct ContactCallbacks {
    let tap: (CGPoint, Int) -> Void
    let liftChanged: (Bool) -> Void
    let translationChanged: (CGSize) -> Void
    let translationEnded: (CGSize) -> Void
    let cancelled: () -> Void
  }
  private var contactCallbacks: ContactCallbacks?

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
    guard ownerIsAvailable() else { return }
    inputGate.registerFingerCancellation(source: inputSource) { [weak self] in
      self?.cancelInteraction()
    }
  }

  isolated deinit { inputGate.unregisterFingerCancellation(source: inputSource) }

  /// This predicate describes the installed physical owner, not preparation of
  /// another scene. A retired owner cancels its contact; rendering work cannot.
  func updateOwnerAvailability(_ isAvailable: @escaping () -> Bool) {
    ownerIsAvailable = isAvailable
    if isAvailable() { registerCancellation() }
    else {
      inputGate.unregisterFingerCancellation(source: inputSource)
      cancelInteraction(deferCallbacks: true)
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
    let directTouches = touches.filter { $0.type == .direct }
    if activeTouch != nil {
      if !directTouches.isEmpty { cancelInteraction() }
      return
    }
    guard ownerIsAvailable(), let generation = inputGate.beginFingerSequence(),
      directTouches.count == 1, let touch = directTouches.first else { return }
    activeTouch = touch
    fingerGeneration = generation
    contactCallbacks = .init(tap: onTap, liftChanged: onLiftChanged,
      translationChanged: onTranslationChanged, translationEnded: onTranslationEnded,
      cancelled: onCancelled)
    startPoint = touch.location(in: window)
    latestTranslation = .zero
    maximumTravel = 0
    contactGeneration += 1
    hasLiftedDuringContact = false
    scheduleLift()
  }

  override func touchesMoved(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    flushLiftCancellation()
    guard ownerIsAvailable(), let fingerGeneration, inputGate.acceptsFingerSequence(fingerGeneration) else {
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
    if isLifted { contactCallbacks?.translationChanged(latestTranslation) }
  }

  override func touchesEnded(
    _ touches: Set<UITouch>,
    with event: UIEvent?
  ) {
    guard ownerIsAvailable(), let fingerGeneration, inputGate.acceptsFingerSequence(fingerGeneration) else {
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
        contactGeneration == generation, ownerIsAvailable(),
        let fingerGeneration, inputGate.acceptsFingerSequence(fingerGeneration),
        maximumTravel <= Self.movementTolerance
      else { return }
      isLifted = true
      hasLiftedDuringContact = true
      contactCallbacks?.liftChanged(true)
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
    let callbacks = contactCallbacks
    let wasLifted = isLifted
    let translation = latestTranslation
    let wasTap =
      acceptTap && !hasLiftedDuringContact
      && maximumTravel <= Self.movementTolerance
    liftWorkItem?.cancel()
    liftWorkItem = nil
    activeTouch = nil
    fingerGeneration = nil
    contactCallbacks = nil
    latestTranslation = .zero
    maximumTravel = 0
    isLifted = false
    hasLiftedDuringContact = false
    contactGeneration += 1

    if wasLifted {
      if acceptTap {
        callbacks?.translationEnded(translation)
        callbacks?.liftChanged(false)
      } else {
        if let callbacks { enqueueLiftCancellation(callbacks) }
      }
    }
    if !deferCallbacks { flushLiftCancellation() }
    if wasTap {
      callbacks?.tap(tapLocation, tapCount)
    }
  }

  private func enqueueLiftCancellation(_ callbacks: ContactCallbacks) {
    guard deferredLiftCancellation == nil else { return }
    deferredLiftCancellation = {
      callbacks.cancelled()
      callbacks.liftChanged(false)
    }
    DispatchQueue.main.async { self.flushLiftCancellation() }
  }

  private func flushLiftCancellation() {
    let cancellation = deferredLiftCancellation
    deferredLiftCancellation = nil
    cancellation?()
  }
}
