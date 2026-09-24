import NotebookCore
import SwiftUI
import UIKit

struct NotebookGuideControl: UIViewRepresentable {
  let model: NotebookAppModel
  let guide: NotebookDrawingGuide
  let origin: CGPoint
  let scale: Double
  func makeUIView(context: Context) -> NotebookGuideView { .init(model:model) }
  func updateUIView(_ view: NotebookGuideView, context: Context) {
    view.guide = guide; view.origin = origin; view.scale = scale; view.setNeedsDisplay()
  }
  static func dismantleUIView(_ view: NotebookGuideView, coordinator: ()) { view.uninstall() }
}

/// Finger-only control regions. Pencil always reaches the existing ink sampler.
final class NotebookGuideView: UIControl {
  private unowned let model: NotebookAppModel
  private let source = UUID()
  var guide: NotebookDrawingGuide?
  var origin = CGPoint.zero
  var scale = 1.0
  private var initial: NotebookDrawingGuide?
  private enum Handle { case move, rotation, opening, radius }
  private var handle = Handle.move
  private var angularOffset = 0.0

  init(model: NotebookAppModel) {
    self.model = model; super.init(frame:.zero)
    backgroundColor = .clear; isOpaque = false
    let pan = NotebookGuidePan(target:self,action:#selector(pan(_:)))
    pan.allowedTouchTypes = [NSNumber(value:UITouch.TouchType.direct.rawValue)]
    pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
    isAccessibilityElement = true; accessibilityIdentifier = "physical-guide"
    model.inputGate.registerControlRegion(source:source) { [weak self] point,kind in
      guard let self, kind == .finger, window != nil else { return false }
      return self.point(inside:convert(point,from:window),with:nil)
    }
    model.inputGate.registerFingerCancellation(source:source) { [weak self] in
      guard let self else { return }
      if let initial { model.drawingTools.updateGuide(initial) }; initial = nil
      for recognizer in gestureRecognizers ?? [] { recognizer.isEnabled = false; recognizer.isEnabled = true }
      model.inputGate.endContact(source:source)
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func uninstall() {
    model.inputGate.unregisterFingerCancellation(source:source)
    model.inputGate.unregisterControlRegion(source:source); model.inputGate.endContact(source:source)
  }
  override var accessibilityLabel: String? {
    get { guide?.kind.title } set {}
  }
  override var accessibilityValue: String? {
    get { guide.map { String(format:"x %.1f y %.1f angle %.1f radius %.1f opening %.1f",$0.start.x,$0.start.y,$0.angle,$0.length,$0.openingAngle) } }
    set {}
  }
  override var accessibilityFrame: CGRect {
    get {
      guard let guide else { return .zero }
      let center = center(guide), radius = guide.length*scale
      let bounds: CGRect
      if guide.kind == .ruler {
        let local=CGRect(x:-22,y:-22,width:radius+44,height:PhysicalPaper.pointsPerCentimeter*0.8*scale+44)
        bounds=local.applying(CGAffineTransform(rotationAngle:guide.angle * .pi/180)).offsetBy(dx:center.x,dy:center.y)
      } else { bounds=CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2) }
      return UIAccessibility.convertToScreenCoordinates(bounds,in:self)
    }
    set {}
  }
  private func center(_ guide: NotebookDrawingGuide) -> CGPoint {
    .init(x:origin.x+guide.start.x*scale,y:origin.y+guide.start.y*scale)
  }
  private func endpoint(_ guide: NotebookDrawingGuide, angle: Double) -> CGPoint {
    let c=center(guide), a=angle * .pi/180
    return .init(x:c.x+guide.length*scale*cos(a),y:c.y+guide.length*scale*sin(a))
  }
  private func distance(_ a: CGPoint,_ b: CGPoint) -> Double { hypot(a.x-b.x,a.y-b.y) }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    guard event?.allTouches?.contains(where:{ $0.type == .pencil }) != true, let guide else { return false }
    let c=center(guide), dx=point.x-c.x, dy=point.y-c.y, angle=guide.angle * .pi/180
    let x=dx*cos(angle)+dy*sin(angle), y = -dx*sin(angle)+dy*cos(angle)
    if guide.kind == .ruler {
      return CGRect(x:-22,y:-22,width:guide.length*scale+44,height:PhysicalPaper.pointsPerCentimeter*0.8*scale+44).contains(.init(x:x,y:y))
    }
    if distance(point,c) < 24 || distance(point,endpoint(guide,angle:guide.angle)) < 24 { return true }
    if guide.kind == .protractor {
      if distance(point,endpoint(guide,angle:guide.angle+guide.openingAngle)) < 24 { return true }
      return y >= -18 && hypot(x,y) <= guide.length*scale+18
    }
    return abs(hypot(x,y)-guide.length*scale) < 18
  }
  @objc private func pan(_ gesture: NotebookGuidePan) {
    switch gesture.state {
    case .began:
      guard let guide, !model.inputGate.hasActivePencil, model.inputGate.beginFingerSequence() != nil else {
        gesture.isEnabled = false; gesture.isEnabled = true; return
      }
      initial = guide; handle = .move
      let p=gesture.contactOrigin, c=center(guide)
      if guide.kind == .protractor && distance(p,endpoint(guide,angle:guide.angle+guide.openingAngle)) < 24 { handle = .opening }
      else if distance(p,endpoint(guide,angle:guide.angle)) < 24 { handle = guide.kind == .compass ? .radius : .rotation }
      angularOffset = atan2(p.y-c.y,p.x-c.x)*180 / .pi-guide.angle
      model.inputGate.beginContact(source:source)
    case .changed, .ended:
      guard var next = initial else { return }
      let point=gesture.location(in:self), c=center(next)
      let angle=atan2(point.y-c.y,point.x-c.x)*180 / .pi
      switch handle {
      case .move:
        next.start = .init(x:next.start.x+(point.x-gesture.contactOrigin.x)/scale,
          y:next.start.y+(point.y-gesture.contactOrigin.y)/scale)
      case .rotation: next.angle = (angle-angularOffset+540).truncatingRemainder(dividingBy:360)-180
      case .opening: next.openingAngle = min(180,max(0.1,(angle-next.angle+360).truncatingRemainder(dividingBy:360)))
      case .radius:
        next.length = max(PhysicalPaper.pointsPerCentimeter/10,distance(point,c)/scale)
        next.angle = angle
      }
      model.drawingTools.updateGuide(next,persistsPreferences:gesture.state == .ended)
      if gesture.state == .ended { initial = nil; model.inputGate.endContact(source:source) }
    case .cancelled, .failed:
      if let initial { model.drawingTools.updateGuide(initial) }; initial = nil
      model.inputGate.endContact(source:source)
    default: break
    }
  }
  override func draw(_ rect: CGRect) {
    guard let guide, let context=UIGraphicsGetCurrentContext() else { return }
    let c=center(guide), cm=PhysicalPaper.pointsPerCentimeter*scale, length=guide.length*scale
    context.saveGState(); defer { context.restoreGState() }
    context.translateBy(x:c.x,y:c.y); context.rotate(by:guide.angle * .pi/180)
    context.setStrokeColor(UIColor.label.withAlphaComponent(0.65).cgColor); context.setLineWidth(1)
    context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.14).cgColor)
    func text(_ value: String, at point: CGPoint) {
      (value as NSString).draw(at:point,withAttributes:[.font:UIFont.monospacedDigitSystemFont(ofSize:12,weight:.medium),.foregroundColor:UIColor.label])
    }
    func line(_ a: CGPoint,_ b: CGPoint) { context.move(to:a); context.addLine(to:b); context.strokePath() }
    func knob(_ point: CGPoint) {
      context.setFillColor(UIColor.secondaryLabel.cgColor)
      context.fillEllipse(in:.init(x:point.x-6,y:point.y-6,width:12,height:12))
    }
    switch guide.kind {
    case .ruler:
      let height=cm*0.8
      context.fill(CGRect(x:0,y:0,width:length,height:height)); context.stroke(CGRect(x:0,y:0,width:length,height:height))
      let millimeters=min(10000,Int(guide.length/PhysicalPaper.pointsPerCentimeter*10))
      for mm in 0...millimeters {
        let x=Double(mm)*cm/10, tick=mm%10 == 0 ? 0.35 : mm%5 == 0 ? 0.24 : 0.13
        line(.init(x:x,y:0),.init(x:x,y:cm*tick))
        if mm%10 == 0 { text("\(mm/10)",at:.init(x:x+2,y:cm*0.4)) }
      }
      text(String(format:"%.1f°",guide.angle),at:.init(x:length/2-18,y:height+5))
      knob(.init(x:length,y:0))
    case .protractor:
      context.move(to:.zero); context.addArc(center:.zero,radius:length,startAngle:0,endAngle:.pi,clockwise:false)
      context.closePath(); context.drawPath(using:.fillStroke)
      for degree in stride(from:0,through:180,by:5) {
        let a=Double(degree) * .pi/180, tick=degree%10 == 0 ? 12.0 : 6.0
        line(.init(x:length*cos(a),y:length*sin(a)),.init(x:(length-tick)*cos(a),y:(length-tick)*sin(a)))
        if degree%30 == 0 { text("\(degree)",at:.init(x:(length-28)*cos(a)-8,y:(length-28)*sin(a)-6)) }
      }
      let a=guide.openingAngle * .pi/180, end=CGPoint(x:length*cos(a),y:length*sin(a))
      line(.zero,.init(x:length,y:0)); line(.zero,end)
      text(String(format:"%.1f°",guide.openingAngle),at:.init(x:12,y:16))
      knob(end); knob(.init(x:length,y:0)); knob(.zero)
    case .compass:
      context.setLineDash(phase:0,lengths:[4,4]); context.strokeEllipse(in:.init(x:-length,y:-length,width:length*2,height:length*2))
      context.setLineDash(phase:0,lengths:[]); line(.zero,.init(x:length,y:0))
      text(String(format:"r %.1f см",guide.length/PhysicalPaper.pointsPerCentimeter),at:.init(x:12,y:12))
      knob(.zero); knob(.init(x:length,y:0))
    }
  }
}

private final class NotebookGuidePan: UIPanGestureRecognizer {
  private(set) var contactOrigin = CGPoint.zero
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch=touches.first { contactOrigin = touch.location(in:view) }
    super.touchesBegan(touches,with:event)
  }
}
