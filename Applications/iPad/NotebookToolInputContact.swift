import NotebookCore
import UIKit

/// The existing window recognizers hand non-ink contacts here. This adapter
/// freezes a coordinate transform and paints only disposable gesture feedback.
/// Authored previews still use the ordinary native-graphic scene plane.
@MainActor
final class NotebookToolInputContact {
  private let controller: NotebookDrawingToolController
  private let gate: NotebookInputGate
  private let id: UUID
  private let sourceID = UUID()
  private let toOwner: (CGPoint) -> SpatialPoint
  private let toFeedback: (CGPoint) -> CGPoint
  private let feedback = CAShapeLayer()
  private let tool: DrawingTool
  private let duration: Double
  private var points: [CGPoint] = []
  private var path = UIBezierPath()
  private var finished = false
  var onFinish: (() -> Void)?

  init?(controller: NotebookDrawingToolController, gate: NotebookInputGate, view: UIView,
    address: NotebookToolAddress, point: CGPoint, screenScale: Double, viewScale: Double? = nil,
    toOwner: @escaping (CGPoint) -> SpatialPoint) {
    guard controller.begin(at:toOwner(point),address:address,screenScale:screenScale), let contact = controller.contact else { return nil }
    self.controller = controller; self.gate = gate; self.toOwner = toOwner; id = contact.id
    // Ink sits below covers. Disposable contact feedback belongs above the
    // composed scene, never inside that ink plane. Freeze the same admitted
    // view geometry as input; the gate prevents camera changes until lift.
    let host = view.window ?? view
    let zero = view.convert(CGPoint.zero,to:host)
    let x = view.convert(CGPoint(x:1,y:0),to:host), y = view.convert(CGPoint(x:0,y:1),to:host)
    let transform = CGAffineTransform(a:x.x-zero.x,b:x.y-zero.y,c:y.x-zero.x,d:y.y-zero.y,tx:zero.x,ty:zero.y)
    toFeedback = { $0.applying(transform) }
    tool = contact.tool; duration = contact.settings.laserDuration
    guard gate.beginPencilAction(source:sourceID) else { controller.cancel(); return nil }
    controller.onContactCancellation = { [weak self] in self?.finish(cancelled:true) }
    gate.registerPageFinisher(source:sourceID) { [weak self] _, completion in
      self?.finish(cancelled:true); completion()
    }
    feedback.fillColor = UIColor.clear.cgColor
    let color = contact.settings.laserColor.components
    feedback.strokeColor = tool == .laser ? UIColor(red:color.red,green:color.green,blue:color.blue,alpha:1).cgColor : UIColor.systemBlue.cgColor
    let feedbackScale = view.window == nil ? max(viewScale ?? screenScale,0.001) : 1
    feedback.name = "notebook-tool-feedback"
    feedback.lineWidth = (tool == .laser ? 4 : 1.5) / feedbackScale
    feedback.lineCap = .round; feedback.lineJoin = .round
    if tool == .lasso { feedback.lineDashPattern = [5/feedbackScale,3/feedbackScale].map(NSNumber.init(value:)) }
    feedback.actions = ["path":NSNull(),"opacity":NSNull()]
    host.layer.addSublayer(feedback)
    let feedbackPoint = toFeedback(point)
    points = [feedbackPoint]
    path.move(to:feedbackPoint)
    if tool == .laser { path.addLine(to:.init(x:feedbackPoint.x+0.01,y:feedbackPoint.y)) }
    feedback.path = path.cgPath
  }

  func move(to point: CGPoint) {
    guard !finished else { return }
    guard controller.contact?.id == id else { finish(cancelled:true); return }
    controller.move(to:toOwner(point))
    if tool == .laser || tool == .lasso {
      let point = toFeedback(point)
      guard let last = points.last, hypot(point.x-last.x,point.y-last.y) >= 1 else { return }
      points.append(point)
      if points.count > 4096 {
        points = points.enumerated().filter { $0.offset % 2 == 0 || $0.offset == points.count-1 }.map(\.element)
        path = UIBezierPath(); path.move(to:points[0])
        for point in points.dropFirst() { path.addLine(to:point) }
      } else { path.addLine(to:point) }
      feedback.path = path.cgPath
    }
  }

  func finish(cancelled: Bool = false) {
    guard !finished else { return }; finished = true
    onFinish?(); onFinish = nil
    defer { gate.unregisterPageFinisher(source:sourceID); gate.endPencilAction(source:sourceID) }
    if controller.contact?.id == id {
      if cancelled { controller.cancel() } else { controller.finish() }
    }
    if tool == .laser, !cancelled {
      let fade = CABasicAnimation(keyPath:"opacity")
      fade.fromValue = 1; fade.toValue = 0; fade.duration = duration
      feedback.opacity = 0; feedback.add(fade,forKey:"fade")
      let layer = feedback
      DispatchQueue.main.asyncAfter(deadline:.now()+duration) { layer.removeFromSuperlayer() }
    } else { feedback.removeFromSuperlayer() }
  }
}
