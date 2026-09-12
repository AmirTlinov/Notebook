import SwiftUI
import UIKit

/// Finger selection observes the existing scene without an overlay that can
/// intercept Pencil. Movement before the hold belongs to the camera; after
/// the hold it moves an artifact or describes an empty-paper region.
/// A second finger or Pencil cancels selection.
struct NotebookSelectionGesture: UIViewRepresentable {
  let inputGate: NotebookInputGate
  let onPreview: (CGRect?) -> Void
  let onPoint: (CGPoint, CGPoint, Bool, Int) -> Void
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
    context.coordinator.recognizer.onPreview = onPreview
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
      guard touch.type == .direct, let anchor,
        gate?.permitsSceneContact(at: touch.location(in: anchor.window)) == true,
        sceneReceives(touch, inside: anchor) else { return false }
      var view = touch.view
      recognizer.permitsHold = true
      while let current = view {
        if current is UIControl || current is UITextView { return false }
        // A closed notebook already owns its lift-and-move gesture.
        if let cover = current as? NotebookInteractionTouchView, cover.permitsManipulation { recognizer.permitsHold = false }
        view = current.superview
      }
      return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  }
}

/// Frozen callbacks bind one finger to its original owner and coordinate scale.
/// ElementEditingSession still owns selection and the unsaved translation.
struct SceneSelectionLift {
  let begin: () -> Void
  let change: (CGPoint) -> Void
  let end: (CGPoint) -> Void
  let cancel: () -> Void
}

final class SceneSelectionRecognizer: UIGestureRecognizer {
  var onPreview: ((CGRect?) -> Void)?
  var onPoint: ((CGPoint, CGPoint, Bool, Int) -> Void)?
  var onLift: ((CGPoint) -> SceneSelectionLift?)?
  private var lift: SceneSelectionLift?
  weak var coordinateView: UIView?
  var gate: NotebookInputGate?
  var permitsHold = true
  private var touch: UITouch?
  private var start = CGPoint.zero
  private var held = false
  private var revision: UInt64?
  private var hold: Task<Void, Never>?
  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
  }
  convenience init() { self.init(target: nil, action: nil) }
  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
  func cancelSelection() {
    hold?.cancel(); hold = nil; touch = nil
    if held { held = false; lift?.cancel(); onPreview?(nil) }
    lift = nil
    if state == .possible { state = .failed }
    else if state == .began || state == .changed { state = .cancelled }
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard touch == nil, touches.count == 1,
      event.allTouches?.filter({ $0.phase != .ended && $0.phase != .cancelled }).count ?? 1 == 1,
      let first = touches.first, first.type == .direct, let revision = gate?.beginFingerSequence() else { cancelSelection(); return }
    touch = first; start = first.location(in: coordinateView); self.revision = revision
    if permitsHold {
      lift = onLift?(start)
      let delay = lift == nil ? 0.35 : NotebookInteractionTouchView.liftDelay
      hold = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard let self, state == .possible, gate?.acceptsFingerSequence(revision) == true else { return }
        held = true; state = .began
        if let lift { lift.begin() }
        else { onPreview?(CGRect(origin: start, size: .init(width: 1, height: 1))) }
      }
    }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch, touches.contains(touch), let revision, gate?.acceptsFingerSequence(revision) == true else { cancelSelection(); return }
    let end = touch.location(in: coordinateView)
    guard held else {
      let tolerance = lift == nil ? 8 : NotebookInteractionTouchView.movementTolerance
      if hypot(end.x - start.x, end.y - start.y) > tolerance { cancelSelection() }
      return
    }
    state = .changed
    if let lift { lift.change(CGPoint(x: end.x - start.x, y: end.y - start.y)); return }
    onPreview?(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: max(1, abs(end.x - start.x)), height: max(1, abs(end.y - start.y))))
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    hold?.cancel(); hold = nil
    guard let touch, touches.contains(touch), let revision, gate?.acceptsFingerSequence(revision) == true else { cancelSelection(); return }
    let end = touch.location(in: coordinateView)
    self.touch = nil
    if held, let lift {
      self.lift = nil; held = false
      lift.end(CGPoint(x: end.x - start.x, y: end.y - start.y))
    } else {
      if held { onPreview?(nil) }
      onPoint?(start, end, held, touch.tapCount)
      held = false; lift = nil
    }
    state = .ended
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { cancelSelection() }
  override func reset() { super.reset(); hold?.cancel(); hold = nil; touch = nil; revision = nil; if held { held = false; lift?.cancel(); onPreview?(nil) }; lift = nil }
}

/// A window-backed display link supplies an opportunity to inspect the current
/// scene. Its callback is scheduling evidence, not a compositor presentation ACK.
struct NotebookDisplayConfirmation: UIViewRepresentable {
  let onFrame: () -> Void
  func makeUIView(context: Context) -> DisplayConfirmationView { DisplayConfirmationView() }
  func updateUIView(_ view: DisplayConfirmationView, context: Context) { view.onFrame = onFrame }
  static func dismantleUIView(_ view: DisplayConfirmationView, coordinator: ()) { view.stop() }
}

final class DisplayConfirmationView: UIView {
  var onFrame: (() -> Void)?
  private var link: CADisplayLink?
  private var frames = 0
  override func didMoveToWindow() {
    super.didMoveToWindow(); stop()
    guard window != nil else { return }
    let link = CADisplayLink(target:self,selector:#selector(displayFrame))
    link.preferredFrameRateRange = .init(minimum:4,maximum:4,preferred:4)
    link.add(to:.main,forMode:.common); self.link = link
  }
  func stop() { link?.invalidate(); link = nil; frames = 0 }
  @objc private func displayFrame() {
    guard window?.isKeyWindow == true, UIApplication.shared.applicationState == .active else { frames = 0; return }
    frames += 1
    if frames >= 2 { onFrame?() }
  }
}
