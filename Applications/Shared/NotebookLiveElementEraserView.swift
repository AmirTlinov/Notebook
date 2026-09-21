#if os(iOS)
import NotebookCore
import Observation
import SwiftUI
import UIKit

/// Device-local presentation state for one physical page. The moving eraser
/// talks straight to one lightweight Core Graphics mask; it never publishes
/// sample prefixes through SwiftUI and does not allocate another MTKView.
@MainActor @Observable
final class NotebookLiveElementEraserPresentation {
  private(set) var isActive = false
  @ObservationIgnored private weak var view: NotebookLiveElementEraserMaskView?
  @ObservationIgnored private var stroke: ActiveEraserStroke?

  func display(_ stroke: ActiveEraserStroke?) {
    self.stroke = stroke
    if isActive != (stroke != nil) { isActive = stroke != nil }
    view?.display(stroke)
  }

  fileprivate func attach(_ view:NotebookLiveElementEraserMaskView) {
    self.view=view;view.presentation=self;view.display(stroke)
  }
  fileprivate func detach(_ view:NotebookLiveElementEraserMaskView) {
    if self.view === view { self.view=nil }
  }
}

struct NotebookLiveElementEraserMask:UIViewRepresentable {
  let presentation:NotebookLiveElementEraserPresentation
  func makeUIView(context:Context)->NotebookLiveElementEraserMaskView {
    let view=NotebookLiveElementEraserMaskView();presentation.attach(view);return view
  }
  func updateUIView(_ view:NotebookLiveElementEraserMaskView,context:Context) {
    presentation.attach(view)
  }
  static func dismantleUIView(_ view:NotebookLiveElementEraserMaskView,
    coordinator:Void) { view.presentation?.detach(view);view.presentation=nil }
  func makeCoordinator() {}
}

/// A full page mask is one coalesced Core Graphics backing, rather than a
/// CAMetalLayer with drawable and MSAA pools. Work is proportional only to the
/// current contact; the retained page and element tree are never traversed.
@MainActor
final class NotebookLiveElementEraserMaskView:UIView {
  weak var presentation:NotebookLiveElementEraserPresentation?
  private var stroke:ActiveEraserStroke?
  private var revision:UInt64?
  private var samples:[SpatialInkSample]=[]

  override init(frame:CGRect) {
    super.init(frame:frame);isOpaque=false;isUserInteractionEnabled=false
    contentMode = .redraw;backgroundColor = .clear
  }
  @available(*,unavailable) required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }

  func display(_ stroke:ActiveEraserStroke?) {
    guard let stroke else {
      self.stroke=nil;revision=nil;samples.removeAll(keepingCapacity:true);setNeedsDisplay();return
    }
    let start = self.stroke === stroke ? stroke.changedStart(after:revision) : 0
    if start != .max {
      if start < samples.count { samples.removeSubrange(start...) }
      if start < stroke.measured.count {
        samples.append(contentsOf:stroke.measured.decoded(in:start..<stroke.measured.count))
      }
      setNeedsDisplay()
    }
    self.stroke=stroke;revision=stroke.revision
  }

  override func draw(_ rect:CGRect) {
    guard let context=UIGraphicsGetCurrentContext() else { return }
    context.setBlendMode(.copy);context.setFillColor(UIColor.white.cgColor);context.fill(bounds)
    guard let stroke,!samples.isEmpty else { return }
    let projection=stroke.projection
    func projected(_ sample:SpatialInkSample)->(CGPoint,CGFloat) {
      let point=projection.origin.flatMap { origin in sample.worldPoint.map { origin.delta(to:$0) } } ?? sample.point
      return (.init(x:point.x*projection.scale+projection.offset.x,
        y:point.y*projection.scale+projection.offset.y),
        max(0.5,sample.width*abs(projection.scale)))
    }
    context.setBlendMode(.clear);context.setLineCap(.round);context.setLineJoin(.round)
    var previous=projected(samples[0])
    context.fillEllipse(in:.init(x:previous.0.x-previous.1/2,y:previous.0.y-previous.1/2,
      width:previous.1,height:previous.1))
    for sample in samples.dropFirst() {
      let next=projected(sample)
      context.beginPath();context.move(to:previous.0);context.addLine(to:next.0)
      context.setLineWidth(max(previous.1,next.1));context.strokePath()
      previous=next
    }
  }
}
#endif
