import SwiftUI
import UIKit

/// Finger selection observes the existing scene without an overlay that can
/// intercept Pencil. Selected material moves directly; other material must be
/// picked up with a quiet hold. Motion before pickup belongs to navigation.
/// A second finger or Pencil cancels selection.
struct NotebookSelectionGesture: UIViewRepresentable {
  let inputGate: NotebookInputGate
  let onPoint: (CGPoint, Int) -> Void
  let onLift: (CGPoint) -> SceneSelectionLift?
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> GestureAnchorView {
    let view = GestureAnchorView(); view.isUserInteractionEnabled = false
    view.onWindowChange = { [weak coordinator = context.coordinator, weak view] _ in
      if let view { coordinator?.install(view) }
    }
    return view
  }
  func updateUIView(_ view: GestureAnchorView, context: Context) {
    context.coordinator.gate = inputGate
    context.coordinator.recognizer.onPoint = onPoint
    context.coordinator.recognizer.onLift = onLift
    context.coordinator.install(view)
  }
  static func dismantleUIView(_ view: GestureAnchorView, coordinator: Coordinator) { coordinator.uninstall() }

  @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    let recognizer = SceneSelectionRecognizer()
    var gate: NotebookInputGate?
    private weak var anchor: UIView?
    private weak var window: UIWindow?
    private let source = UUID()
    func install(_ view: UIView) {
      guard window !== view.window || anchor !== view else { return }
      uninstall(); anchor = view; window = view.window
      recognizer.coordinateView = view; recognizer.gate = gate; recognizer.delegate = self
      window?.addGestureRecognizer(recognizer)
      gate?.registerFingerCancellation(source: source) { [weak recognizer] in recognizer?.cancelSelection() }
    }
    func uninstall() {
      recognizer.cancelSelection(); window?.removeGestureRecognizer(recognizer)
      gate?.unregisterFingerCancellation(source: source); window = nil; anchor = nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard touch.type == .direct, let anchor, let gate,
        gate.permitsSceneContact(at: touch.location(in: anchor.window), kind: .finger),
        sceneReceives(touch, inside: anchor) else { return false }
      var view = touch.view
      while let current = view {
        // A closed notebook owns this whole contact, including tap and lift.
        if current is NotebookInteractionTouchView { return false }
        view = current.superview
      }
      // A link keeps its native tap, but its containing material can still be
      // lifted. Actual controls retain input; neither reparenting nor a later
      // hit test can change this accepted contact's owner.
      return NotebookSceneFingerRouting.owner(of: touch, gate: gate).permitsSceneNavigation
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
      !recognizer.canPrevent(other)
    }
  }
}

/// Frozen callbacks bind one finger to its original owner and coordinate scale.
/// NotebookSelectionSession owns the current target and unsaved translation.
struct SceneSelectionLift {
  var requiresHold = false
  let begin: () -> Void
  let change: (CGPoint) -> Void
  let end: (CGPoint) -> Void
  let cancel: () -> Void
}

final class SceneSelectionRecognizer: UIGestureRecognizer {
  var onPoint: ((CGPoint, Int) -> Void)?
  var onLift: ((CGPoint) -> SceneSelectionLift?)?
  private var lift: SceneSelectionLift?
  weak var coordinateView: UIView?
  var gate: NotebookInputGate?
  private var touch: UITouch?
  private var start = CGPoint.zero
  private var windowStart = CGPoint.zero
  private var dragging = false
  private var nativeTapOwner: ObjectIdentifier?
  private var revision: UInt64?
  private var holdTask: Task<Void, Never>?
  private static let pickupDelay = Duration.milliseconds(250)
  private static let movementThreshold: CGFloat = 4
  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
  }
  convenience init() { self.init(target: nil, action: nil) }
  isolated deinit { holdTask?.cancel() }
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
    if lift != nil, state == .began || state == .changed,
      let scope = view, let other = preventedGestureRecognizer.view,
      other !== scope, other.isDescendant(of: scope) {
      // Native content owns the contact before a system page curl can begin.
      // The window's Pencil, contact and two-finger observers remain independent.
      return true
    }
    // A successful lift owns this link's whole contact, including WebKit's
    // recognizers, not just touches delivered to WKContentView. Other runtime
    // controls and the window's camera/Pencil observers are not competitors.
    guard dragging, let nativeTapOwner else { return false }
    var view = preventedGestureRecognizer.view
    while let current = view {
      if ObjectIdentifier(current) == nativeTapOwner { return true }
      view = current.superview
    }
    return false
  }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  func cancelSelection() {
    holdTask?.cancel(); holdTask = nil
    touch = nil
    if dragging { dragging = false; lift?.cancel() }
    lift = nil
    if state == .possible { state = .failed }
    else if state == .began || state == .changed { state = .cancelled }
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard touch == nil, touches.count == 1,
      event.allTouches?.filter({ $0.phase != .ended && $0.phase != .cancelled }).count ?? 1 == 1,
      let first = touches.first, first.type == .direct, let revision = gate?.beginFingerSequence() else { cancelSelection(); return }
    touch = first; start = first.location(in: coordinateView); self.revision = revision
    // The SwiftUI anchor can move while the keyboard or a menu is dismissed.
    // Physical displacement belongs to the stationary window, not that layout.
    windowStart = first.location(in:view)
    if let gate, case .webLink(let owner) = NotebookSceneFingerRouting.owner(of: first, gate: gate) {
      nativeTapOwner = owner
    } else { nativeTapOwner = nil }
    guard gate?.permitsObjectPickup == true else { cancelSelection(); return }
    lift = onLift?(start)
    // A native link keeps its tap until this material is actually picked up.
    cancelsTouchesInView = nativeTapOwner != nil
    if nativeTapOwner != nil && lift == nil { cancelSelection(); return }
    if lift?.requiresHold == true {
      holdTask = Task { [weak self] in
        do { try await Task.sleep(for: Self.pickupDelay) } catch { return }
        guard !Task.isCancelled, let self, let touch = self.touch else { return }
        let point = touch.location(in: self.view)
        guard hypot(point.x - self.windowStart.x, point.y - self.windowStart.y) < Self.movementThreshold else {
          self.cancelSelection(); return
        }
        self.beginLift()
      }
    } else if lift != nil {
      gate?.claimSceneObjectContact(ObjectIdentifier(first))
      if nativeTapOwner == nil { state = .began }
    }
  }
  private func beginLift() {
    guard !dragging, let touch, let lift, let revision,
      gate?.acceptsFingerSequence(revision) == true, gate?.permitsObjectPickup == true else {
      cancelSelection(); return
    }
    holdTask?.cancel(); holdTask = nil
    gate?.claimSceneObjectContact(ObjectIdentifier(touch))
    dragging = true
    if state == .possible { state = .began }
    lift.begin()
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch, touches.contains(touch), let revision, gate?.acceptsFingerSequence(revision) == true,
      gate?.permitsObjectPickup == true else { cancelSelection(); return }
    let point = touch.location(in:view)
    let delta = CGPoint(x:point.x-windowStart.x,y:point.y-windowStart.y)
    if !dragging, hypot(delta.x,delta.y) >= Self.movementThreshold {
      guard let lift, !lift.requiresHold else { cancelSelection(); return }
      beginLift()
    }
    guard dragging else { return }
    state = .changed
    lift?.change(delta)
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch, touches.contains(touch), let revision, gate?.acceptsFingerSequence(revision) == true,
      gate?.permitsObjectPickup == true else { cancelSelection(); return }
    holdTask?.cancel(); holdTask = nil
    let end = touch.location(in: coordinateView)
    let point = touch.location(in: view)
    if !dragging, hypot(point.x - windowStart.x, point.y - windowStart.y) >= Self.movementThreshold {
      cancelSelection(); return
    }
    self.touch = nil
    if dragging, let lift {
      self.lift = nil; dragging = false
      lift.end(CGPoint(x:point.x-windowStart.x,y:point.y-windowStart.y))
    } else if nativeTapOwner != nil {
      self.lift = nil; state = .failed; return
    } else {
      onPoint?(end, touch.tapCount)
      dragging = false; lift = nil
    }
    state = .ended
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancelSelection() }
  override func reset() { super.reset(); holdTask?.cancel(); holdTask = nil; touch = nil; revision = nil; nativeTapOwner = nil; cancelsTouchesInView = false; if dragging { dragging = false; lift?.cancel() }; lift = nil }
}

/// A window-backed display link supplies an opportunity to inspect the current
/// scene. Its callback is scheduling evidence, not a compositor presentation ACK.
struct NotebookDisplayConfirmation: UIViewRepresentable {
  // Read by the SwiftUI caller, not only inside a later display callback.
  // Completing metadata preparation must wake the already idle scene too.
  var preparedSource: UInt64? = nil
  let onFrame: () -> Bool
  func makeUIView(context: Context) -> DisplayConfirmationView { DisplayConfirmationView() }
  func updateUIView(_ view: DisplayConfirmationView, context: Context) {
    view.onFrame = onFrame; view.preparedSource = preparedSource
  }
  static func dismantleUIView(_ view: DisplayConfirmationView, coordinator: ()) { view.stop() }
}

final class DisplayConfirmationView: UIView {
  var preparedSource: UInt64? {
    didSet { if preparedSource != oldValue { useFastCadence(true) } }
  }
  // A source publication wakes this same clock immediately. Once that source
  // is confirmed (or no current visible result is pending), keep idle work low.
  var onFrame: (() -> Bool)? { didSet { useFastCadence(true) } }
  private var link: CADisplayLink?
  private var frames = 0
  private var fastCadence = true
  override func didMoveToWindow() {
    super.didMoveToWindow(); stop()
    guard window != nil else { return }
    let link = CADisplayLink(target:self,selector:#selector(displayFrame))
    link.preferredFrameRateRange = .init(minimum:30,maximum:60,preferred:60)
    fastCadence = true
    link.add(to:.main,forMode:.common); self.link = link
  }
  func stop() { link?.invalidate(); link = nil; frames = 0 }
  private func useFastCadence(_ fast: Bool) {
    guard fastCadence != fast else { return }
    fastCadence = fast
    link?.preferredFrameRateRange = fast ? .init(minimum:30,maximum:60,preferred:60)
      : .init(minimum:4,maximum:4,preferred:4)
  }
  @objc private func displayFrame() {
    guard window?.isKeyWindow == true, UIApplication.shared.applicationState == .active else {
      frames = 0; useFastCadence(false); return
    }
    frames += 1
    if frames >= 2 { useFastCadence(onFrame?() ?? false) }
  }
}
