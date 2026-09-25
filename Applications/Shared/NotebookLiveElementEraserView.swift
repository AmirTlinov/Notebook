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
  case accepted(PreparedPageInkChange)
  case reconciled(UUID, VersionStamp, PageInkDrawing)
}

/// One page-wide measured mask. Input updates the renderer's existing mutable
/// tail directly; SwiftUI observes only contact/handoff boundaries.
@MainActor @Observable
final class NotebookLiveElementEraserPresentation {
  private(set) var isActive = false
  @ObservationIgnored private weak var view: NotebookLiveElementEraserMaskView?
  @ObservationIgnored private var stroke: ActiveEraserStroke?
  @ObservationIgnored private(set) var pending: [PageInkAction] = []
  @ObservationIgnored private var pageID: UUID?
  @ObservationIgnored private var acceptedStamp: VersionStamp?
  @ObservationIgnored private var pendingStamps: [UUID: VersionStamp] = [:]

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
      pending.removeAll { $0.id == id };pendingStamps[id]=nil
      view?.canvas.retainErasureMaskActions(pending)
    case .accepted(let change):
      guard pageID != change.pageID || (acceptedStamp.map({ change.stamp >= $0 }) ?? true) else { return }
      reconcile(pageID:change.pageID,stamp:change.stamp,drawing:change.drawing)
      let ids:Set<UUID>
      switch change.mutation {
      case .append(let action): ids=[action.id]
      case .setActive(let changed,_): ids=changed
      }
      for id in ids {
        guard let action=change.drawing.action(id:id),action.isActive,
          action.elementTargets?.isEmpty == false else { continue }
        if let index=pending.firstIndex(where: { $0.id == id }) { pending[index]=action }
        else { pending.append(action) }
        pendingStamps[id]=change.stamp
      }
      view?.canvas.retainErasureMaskActions(pending)
    case .reconciled(let pageID,let stamp,let drawing):
      reconcile(pageID:pageID,stamp:stamp,drawing:drawing)
      view?.canvas.retainErasureMaskActions(pending)
    }
    refreshActivity()
  }

  private func reconcile(pageID:UUID,stamp:VersionStamp,drawing:PageInkDrawing) {
    if let current=self.pageID,current != pageID { pending=[];pendingStamps=[:] }
    guard self.pageID != pageID || (acceptedStamp.map({ stamp >= $0 }) ?? true) else { return }
    self.pageID=pageID;acceptedStamp=stamp
    pending=pending.compactMap { previous in
      guard let action=drawing.action(id:previous.id),action.isActive else {
        pendingStamps[previous.id]=nil;return nil
      }
      pendingStamps[action.id]=action.stateStamp ?? pendingStamps[action.id] ?? stamp
      return action
    }
  }

  /// A source-checked installed receipt may retire active coverage. A newer
  /// accepted inverse already removed it; absence is not an eternal second gate.
  func presented(_ receipt:PageElementErasurePresentation) {
    guard receipt.pageID == pageID else { return }
    let count=pending.count
    pending.removeAll { action in
      guard let stamp=pendingStamps[action.id],receipt.stamp >= stamp else { return false }
      let shown=(action.elementTargets ?? []).allSatisfy { target in
        receipt.erasures[target.elementID]?.contains(.init(target:target,measurements:action.samples)) == true
      }
      if shown { pendingStamps[action.id]=nil }
      return shown
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
    // Neutral white and its first cut are one renderer transaction. Clearing a
    // separate host background after the presentation callback adds a frame.
    backgroundColor = .clear;addSubview(canvas)
  }
  @available(*,unavailable) required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }
  override func layoutSubviews() { super.layoutSubviews();projection.refresh() }
  override func didMoveToWindow() { super.didMoveToWindow();projection.refresh() }
}
#endif
