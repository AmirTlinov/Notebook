#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// Device-local presentation state for one physical page. Durable element
/// targets still belong to the accepted ink action; this owner only prevents
/// live Pencil samples from fanning out through the whole SwiftUI overlay.
@MainActor @Observable
final class NotebookLiveElementEraserPresentation {
  private(set) var isActive = false
  @ObservationIgnored private weak var canvas: InkCanvasView?
  @ObservationIgnored private var stroke: ActiveEraserStroke?

  func display(_ stroke: ActiveEraserStroke?) {
    self.stroke = stroke
    if isActive != (stroke != nil) { isActive = stroke != nil }
    if let stroke { canvas?.displayActiveEraser(stroke) }
    else { canvas?.clearActiveAction() }
  }

  fileprivate func attach(_ canvas: InkCanvasView) {
    self.canvas = canvas
    if let stroke { canvas.displayActiveEraser(stroke) }
  }

  fileprivate func detach(_ canvas: InkCanvasView) {
    if self.canvas === canvas { self.canvas = nil }
  }
}

struct NotebookLiveElementEraserMask: UIViewRepresentable {
  @Environment(\.scenePlaneProjection) private var sceneProjection
  typealias Coordinator = Void
  let presentation: NotebookLiveElementEraserPresentation

  func makeUIView(context: Context) -> NotebookLiveElementEraserContainer {
    let view = NotebookLiveElementEraserContainer()
    view.presentation = presentation
    view.inkProjection.observe(sceneProjection)
    presentation.attach(view.canvas)
    return view
  }

  func updateUIView(_ view: NotebookLiveElementEraserContainer,context: Context) {
    view.presentation = presentation
    view.inkProjection.observe(sceneProjection)
    presentation.attach(view.canvas)
  }

  static func dismantleUIView(_ view:NotebookLiveElementEraserContainer,
    coordinator:Void) {
    view.presentation?.detach(view.canvas)
    view.inkProjection.stop()
    view.presentation = nil
  }

  func makeCoordinator() {}
}

@MainActor
final class NotebookLiveElementEraserContainer: UIView {
  let canvas = InkCanvasView(frame:.zero)
  lazy var inkProjection = PageInkProjection(host:self,canvas:canvas)
  weak var presentation: NotebookLiveElementEraserPresentation?

  override init(frame:CGRect) {
    super.init(frame:frame)
    isUserInteractionEnabled = false; backgroundColor = .clear; isOpaque = false
    canvas.configureLiveElementEraserMask()
    addSubview(canvas)
  }

  @available(*,unavailable)
  required init?(coder:NSCoder) { fatalError("init(coder:) is unavailable") }

  override func layoutSubviews() {
    super.layoutSubviews()
    inkProjection.refresh()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    inkProjection.refresh()
  }
}
#endif
