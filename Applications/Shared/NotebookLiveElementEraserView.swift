#if os(iOS)
import NotebookCore
import Observation
import SwiftUI
import UIKit

enum NotebookLiveElementEraserEvent {
  case update(ActiveEraserStroke)
  case commit(PageInkAction)
  case cancel
  case reject(UUID)
}

/// One page-wide measured mask. Input updates the renderer's existing mutable
/// tail directly; SwiftUI observes only contact/handoff boundaries.
@MainActor @Observable
final class NotebookLiveElementEraserPresentation {
  private(set) var isActive = false
  @ObservationIgnored private weak var view: NotebookLiveElementEraserMaskView?
  @ObservationIgnored private var stroke: ActiveEraserStroke?
  @ObservationIgnored private(set) var pending: [PageInkAction] = []

  func display(_ event:NotebookLiveElementEraserEvent) {
    switch event {
    case .update(let stroke):
      self.stroke=stroke;view?.canvas.displayActiveEraser(stroke)
    case .commit(let action):
      if action.elementTargets?.isEmpty == false {
        pending.append(action);view?.canvas.commitActiveEraser(action)
      } else { view?.canvas.clearActiveAction() }
      stroke=nil
    case .cancel:
      stroke=nil;view?.canvas.clearActiveAction()
    case .reject(let id):
      pending.removeAll { $0.id == id };view?.canvas.retainErasureMaskActions(pending)
    }
    refreshActivity()
  }

  /// Called only with the current overlay's ready receipt. A mounted mask,
  /// an older frame or a saved action alone cannot retire the lifted coverage.
  func presented(_ erasures:[String:[InkElementErasure]]) {
    let count=pending.count
    pending.removeAll { action in
      (action.elementTargets ?? []).allSatisfy { target in
        erasures[target.elementID]?.contains(.init(target:target,measurements:action.samples)) == true
      }
    }
    guard count != pending.count else { return }
    view?.canvas.retainErasureMaskActions(pending);refreshActivity()
  }

  private func refreshActivity() {
    let next=stroke != nil || !pending.isEmpty
    if next != isActive { isActive=next }
  }
  fileprivate func attach(_ view:NotebookLiveElementEraserMaskView) {
    guard self.view !== view else { return }
    self.view=view;view.presentation=self
    view.canvas.retainErasureMaskActions(pending)
    if let stroke { view.canvas.displayActiveEraser(stroke) }
  }
  fileprivate func detach(_ view:NotebookLiveElementEraserMaskView) {
    if self.view === view { self.view=nil }
  }
}

struct NotebookLiveElementEraserMask:UIViewRepresentable {
  @Environment(\.scenePlaneProjection) private var projection
  let presentation:NotebookLiveElementEraserPresentation
  func makeUIView(context:Context)->NotebookLiveElementEraserMaskView {
    let view=NotebookLiveElementEraserMaskView();presentation.attach(view)
    view.projection.observe(projection);return view
  }
  func updateUIView(_ view:NotebookLiveElementEraserMaskView,context:Context) {
    presentation.attach(view);view.projection.observe(projection)
  }
  static func dismantleUIView(_ view:NotebookLiveElementEraserMaskView,coordinator:Void) {
    view.presentation?.detach(view);view.presentation=nil;view.projection.stop()
    Task { await view.canvas.finishSpatialHandoffFrames() }
  }
  func makeCoordinator() {}
}

/// The same compact geometry, tile admission and changed-tile renderer as ink.
/// There is no CoreGraphics full-prefix replay or a canvas per touched figure.
@MainActor
final class NotebookLiveElementEraserMaskView:UIView {
  weak var presentation:NotebookLiveElementEraserPresentation?
  let canvas=InkCanvasView(frame:.zero,isErasureMask:true)
  lazy var projection=PageInkProjection(host:self,canvas:canvas)
  override init(frame:CGRect) {
    super.init(frame:frame);isOpaque=false;isUserInteractionEnabled=false
    backgroundColor = .white;addSubview(canvas)
    canvas.onVisibleFrame = { [weak self] in
      self?.backgroundColor = .clear;self?.canvas.onVisibleFrame=nil
    }
  }
  @available(*,unavailable) required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
  override func layoutSubviews() { super.layoutSubviews();projection.refresh() }
  override func didMoveToWindow() { super.didMoveToWindow();projection.refresh() }
}
#endif
