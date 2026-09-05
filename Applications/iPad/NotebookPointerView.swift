import SwiftUI
import UIKit

/// One direct contact points. A second contact returns ownership to the
/// window's existing camera recognizer before a reference is committed.
struct NotebookPointerView: UIViewRepresentable {
  let onPreview: (CGRect?) -> Void
  let onPoint: (CGPoint, CGPoint) -> Void
  func makeUIView(context: Context) -> PointerTouchView { PointerTouchView() }
  func updateUIView(_ view: PointerTouchView, context: Context) {
    view.pointer.onPreview = onPreview; view.pointer.onPoint = onPoint
  }
}

final class PointerTouchView: UIView, UIGestureRecognizerDelegate {
  let pointer = PointerContactRecognizer()
  override init(frame: CGRect) {
    super.init(frame:frame)
    isMultipleTouchEnabled = true
    pointer.delegate = self
    addGestureRecognizer(pointer)
    accessibilityIdentifier = "shared-pointer-surface"
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

final class PointerContactRecognizer: UIGestureRecognizer {
  var onPreview: ((CGRect?) -> Void)?
  var onPoint: ((CGPoint,CGPoint) -> Void)?
  private var touch: UITouch?
  private var start = CGPoint.zero
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard touch == nil, touches.count == 1, event.allTouches?.filter({$0.phase != .ended && $0.phase != .cancelled}).count == 1,
      let first = touches.first else { state = .cancelled; onPreview?(nil); return }
    touch = first; start = first.location(in:view); state = .began
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch, touches.contains(touch) else { return }
    let end = touch.location(in:view)
    state = .changed
    onPreview?(.init(x:min(start.x,end.x),y:min(start.y,end.y),width:max(1,abs(end.x-start.x)),height:max(1,abs(end.y-start.y))))
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch, touches.contains(touch), state != .cancelled else { return }
    onPoint?(start,touch.location(in:view)); onPreview?(nil); state = .ended
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { onPreview?(nil); state = .cancelled }
  override func reset() { super.reset(); touch = nil; onPreview?(nil) }
}

/// A window-backed display link supplies a physical frame boundary. Only a
/// foreground, attached scene can confirm that its matching region was shown.
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
