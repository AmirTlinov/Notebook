import NotebookCore
import SwiftUI
import UIKit

struct NotebookRulerControl: UIViewRepresentable {
  let model: NotebookAppModel
  let ruler: NotebookRuler
  let origin: CGPoint
  let scale: Double
  func makeUIView(context: Context) -> NotebookRulerView { .init(model:model) }
  func updateUIView(_ view: NotebookRulerView, context: Context) { view.ruler = ruler; view.origin = origin; view.scale = scale; view.setNeedsDisplay() }
  static func dismantleUIView(_ view: NotebookRulerView, coordinator: ()) { view.uninstall() }
}

/// Finger-only control regions leave Pencil with the existing scene sampler.
/// The pan edits the controller's one ruler pose; it never navigates the camera.
final class NotebookRulerView: UIControl {
  private unowned let model: NotebookAppModel
  private let source = UUID()
  var ruler: NotebookRuler?
  var origin = CGPoint.zero
  var scale = 1.0
  private var initial: NotebookRuler?
  private var rotating = false
  private var rotationOffset = 0.0
  init(model: NotebookAppModel) {
    self.model = model; super.init(frame:.zero)
    backgroundColor = .clear; isOpaque = false
    let pan = NotebookRulerPan(target:self,action:#selector(pan(_:)))
    pan.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue)]
    pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
    isAccessibilityElement = true
    accessibilityLabel = "Линейка: 1 сантиметр — 2 клетки"; accessibilityIdentifier = "physical-ruler"
    model.inputGate.registerControlRegion(source:source) { [weak self] point,kind in
      guard let self, kind == .finger, window != nil else { return false }
      return self.point(inside:convert(point,from:window),with:nil)
    }
    model.inputGate.registerFingerCancellation(source:source) { [weak self] in
      guard let self else { return }
      if let initial { model.drawingTools.ruler = initial }; initial = nil
      for recognizer in gestureRecognizers ?? [] { recognizer.isEnabled = false; recognizer.isEnabled = true }
      model.inputGate.endContact(source:source)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func uninstall() { model.inputGate.unregisterFingerCancellation(source:source); model.inputGate.unregisterControlRegion(source:source); model.inputGate.endContact(source:source) }
  override var accessibilityValue: String? {
    get { ruler.map { String(format:"x %.1f y %.1f angle %.1f",$0.start.x,$0.start.y,$0.angle) } }
    set {}
  }
  override var accessibilityFrame: CGRect {
    get {
      guard let ruler else { return .zero }
      let s = start(ruler), angle = ruler.angle * .pi/180
      let local = CGRect(x:0,y:0,width:ruler.length*scale,height:PhysicalPaper.pointsPerCentimeter*0.8*scale)
      let box = local.applying(.init(rotationAngle:angle)).offsetBy(dx:s.x,dy:s.y)
      return UIAccessibility.convertToScreenCoordinates(box,in:self)
    }
    set {}
  }
  private func start(_ ruler: NotebookRuler) -> CGPoint { .init(x:origin.x+ruler.start.x*scale,y:origin.y+ruler.start.y*scale) }
  private func local(_ point: CGPoint, _ ruler: NotebookRuler) -> CGPoint {
    let s = start(ruler), a = ruler.angle * .pi/180, x = point.x-s.x, y = point.y-s.y
    return .init(x:x*cos(a)+y*sin(a),y:-x*sin(a)+y*cos(a))
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard event?.allTouches?.contains(where:{ $0.type == .pencil }) != true, let ruler else { return false }
    let p = local(point,ruler), height = PhysicalPaper.pointsPerCentimeter*0.8*scale
    return CGRect(x:-12,y:-12,width:ruler.length*scale+24,height:height+24).contains(p)
  }
  @objc private func pan(_ gesture: NotebookRulerPan) {
    switch gesture.state {
    case .began:
      guard let ruler, model.inputGate.beginFingerSequence() != nil else { gesture.isEnabled = false; gesture.isEnabled = true; return }
      initial = ruler
      let p = local(gesture.contactOrigin,ruler)
      rotating = abs(p.x-ruler.length*scale) < 28
      let s = start(ruler)
      rotationOffset = atan2(gesture.contactOrigin.y-s.y,gesture.contactOrigin.x-s.x)-ruler.angle * .pi/180
      model.inputGate.beginContact(source:source)
    case .changed, .ended:
      guard var next = initial else { return }
      if rotating {
        let p = gesture.location(in:self), s = start(next)
        next.angle = (atan2(p.y-s.y,p.x-s.x)-rotationOffset)*180 / .pi
        next.angle = (next.angle+540).truncatingRemainder(dividingBy:360)-180
      } else {
        let point = gesture.location(in:self)
        let delta = CGPoint(x:point.x-gesture.contactOrigin.x,y:point.y-gesture.contactOrigin.y)
        next.start = .init(x:next.start.x+delta.x/scale,y:next.start.y+delta.y/scale)
      }
      model.drawingTools.ruler = next
      model.drawingToolSettings.rulerAngle = next.angle
      if gesture.state == .ended { initial = nil; model.inputGate.endContact(source:source) }
    case .cancelled, .failed:
      if let initial { model.drawingTools.ruler = initial }; initial = nil; model.inputGate.endContact(source:source)
    default: break
    }
  }
  override func draw(_ rect: CGRect) {
    guard let ruler, let context = UIGraphicsGetCurrentContext() else { return }
    let s = start(ruler), cm = PhysicalPaper.pointsPerCentimeter*scale, length = ruler.length*scale, height = cm*0.8
    context.saveGState(); defer { context.restoreGState() }
    context.translateBy(x:s.x,y:s.y); context.rotate(by:ruler.angle * .pi/180)
    context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.18).cgColor)
    context.fill(CGRect(x:0,y:0,width:length,height:height))
    context.setStrokeColor(UIColor.label.withAlphaComponent(0.8).cgColor); context.setLineWidth(max(0.5,scale))
    context.stroke(CGRect(x:0,y:0,width:length,height:height))
    for millimeter in 0...Int(ruler.length/PhysicalPaper.pointsPerCentimeter*10) {
      let x = Double(millimeter)*cm/10
      let tick = millimeter%10 == 0 ? 0.35 : millimeter%5 == 0 ? 0.24 : 0.13
      context.move(to:.init(x:x,y:0)); context.addLine(to:.init(x:x,y:cm*tick)); context.strokePath()
      if millimeter%10 == 0 {
        let text = "\(millimeter/10)" as NSString
        text.draw(at:.init(x:x+2*scale,y:cm*0.4),withAttributes:[.font:UIFont.monospacedDigitSystemFont(ofSize:12*scale,weight:.medium),.foregroundColor:UIColor.label])
      }
    }
    context.setFillColor(UIColor.systemBlue.cgColor)
    context.fillEllipse(in:.init(x:length-7,y:height/2-7,width:14,height:14))
  }
}

/// Keep the physical touchdown, not the point at which UIKit crosses its pan
/// recognition threshold. Otherwise every move loses the first eight points.
private final class NotebookRulerPan: UIPanGestureRecognizer {
  private(set) var contactOrigin = CGPoint.zero
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { contactOrigin = touch.location(in:view) }
    super.touchesBegan(touches,with:event)
  }
}
