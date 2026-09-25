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
  private let toFeedback: (SpatialPoint) -> CGPoint
  private let feedback = CAShapeLayer()
  private let tool: DrawingTool
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
    let a=toOwner(.zero),b=toOwner(.init(x:1,y:0)),c=toOwner(.init(x:0,y:1))
    let ownerToView=CGAffineTransform(a:b.x-a.x,b:b.y-a.y,c:c.x-a.x,d:c.y-a.y,tx:a.x,ty:a.y).inverted()
    toFeedback = { CGPoint(x:$0.x,y:$0.y).applying(ownerToView).applying(transform) }
    tool = contact.tool
    guard gate.beginPencilAction(source:sourceID) else { controller.cancel(); return nil }
    controller.onContactCancellation = { [weak self] in self?.finish(cancelled:true) }
    gate.registerPageFinisher(source:sourceID) { [weak self] _, completion in
      self?.finish(cancelled:true); completion()
    }
    feedback.fillColor = UIColor.clear.cgColor
    feedback.strokeColor = UIColor.systemBlue.cgColor
    let feedbackScale = view.window == nil ? max(viewScale ?? screenScale,0.001) : 1
    feedback.name = "notebook-tool-feedback"
    feedback.lineWidth = 1.5 / feedbackScale
    feedback.lineCap = .round; feedback.lineJoin = .round
    if tool == .lasso { feedback.lineDashPattern = [5/feedbackScale,3/feedbackScale].map(NSNumber.init(value:)) }
    feedback.actions = ["path":NSNull(),"opacity":NSNull()]
    if tool == .lasso { host.layer.addSublayer(feedback) }
    let feedbackPoint = toFeedback(toOwner(point))
    path.move(to:feedbackPoint)
    feedback.path = path.cgPath
  }

  func move(to point: CGPoint) {
    guard !finished else { return }
    guard controller.contact?.id == id else { finish(cancelled:true); return }
    guard let accepted=controller.move(to:toOwner(point)) else { return }
    if tool == .lasso {
      path.addLine(to:toFeedback(accepted))
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
    feedback.removeFromSuperlayer()
  }
}
