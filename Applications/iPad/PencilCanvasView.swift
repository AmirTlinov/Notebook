import PencilKit
import SwiftUI
import TetradCore
import UIKit

struct PencilCanvasView: UIViewRepresentable {
  let pageID: UUID
  let drawingData: Data
  let penStyle: PenStyle
  let drawingTool: DrawingTool
  let onToggleTool: () -> Void
  let onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void
  let onUndo: () -> Void
  let onChange: (Data, Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onToggleTool: onToggleTool,
      onNavigate: onNavigate,
      onUndo: onUndo,
      onChange: onChange
    )
  }

  func makeUIView(context: Context) -> PKCanvasView {
    let canvas = PaperCanvasView(frame: .zero)
    canvas.delegate = context.coordinator
    canvas.drawingPolicy = .pencilOnly
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.isScrollEnabled = false
    canvas.minimumZoomScale = 1
    canvas.maximumZoomScale = 1
    canvas.bouncesZoom = false
    canvas.contentInset = .zero
    context.coordinator.attach(to: canvas)
    context.coordinator.apply(penStyle, tool: drawingTool, to: canvas)
    context.coordinator.apply(drawingData, pageID: pageID, to: canvas)
    return canvas
  }

  func updateUIView(_ canvas: PKCanvasView, context: Context) {
    context.coordinator.onToggleTool = onToggleTool
    context.coordinator.onNavigate = onNavigate
    context.coordinator.onUndo = onUndo
    context.coordinator.onChange = onChange
    context.coordinator.apply(penStyle, tool: drawingTool, to: canvas)
    context.coordinator.apply(drawingData, pageID: pageID, to: canvas)
    canvas.contentSize = canvas.bounds.size
    canvas.contentOffset = .zero
    canvas.zoomScale = 1
  }

  @MainActor
  final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    var onToggleTool: () -> Void
    var onNavigate: (_ horizontal: Bool, _ direction: Int) -> Void
    var onUndo: () -> Void
    var onChange: (Data, Bool) -> Void

    private struct ToolSession {
      let tool: DrawingTool
      let penStyle: PenStyle
      let strokeCountBefore: Int
    }

    private var pageID: UUID?
    private var appliedDrawing = PKDrawing()
    private var applying = false
    private var activeSession: ToolSession?
    private var endedSession: ToolSession?
    private var pressureStyles: [Int: PenStyle] = [:]
    private var needsSettlement = false
    private var liveTask: Task<Void, Never>?
    private var settlementTask: Task<Void, Never>?
    private var appliedPenStyle: PenStyle?
    private var appliedDrawingTool: DrawingTool?
    private var ink = PKInkingTool(.pen, color: .black, width: 2.2)
    private var pageGestures: TwoFingerPageGestureController?

    init(
      onToggleTool: @escaping () -> Void,
      onNavigate: @escaping (_ horizontal: Bool, _ direction: Int) -> Void,
      onUndo: @escaping () -> Void,
      onChange: @escaping (Data, Bool) -> Void
    ) {
      self.onToggleTool = onToggleTool
      self.onNavigate = onNavigate
      self.onUndo = onUndo
      self.onChange = onChange
    }

    func attach(to canvas: PKCanvasView) {
      canvas.addInteraction(UIPencilInteraction(delegate: self))

      let pageGestures = TwoFingerPageGestureController(
        onNavigate: { [weak self, weak canvas] horizontal, direction in
          guard let self, let canvas else { return }
          settleNow(canvas)
          onNavigate(horizontal, direction)
        },
        onUndo: { [weak self, weak canvas] in
          guard let self, let canvas else { return }
          settleNow(canvas)
          onUndo()
        }
      )
      pageGestures.install(on: canvas)
      self.pageGestures = pageGestures
    }

    func apply(_ style: PenStyle, tool: DrawingTool, to canvas: PKCanvasView) {
      let styleChanged = style != appliedPenStyle
      let toolChanged = tool != appliedDrawingTool
      guard styleChanged || toolChanged else { return }

      if styleChanged {
        appliedPenStyle = style
        ink = PKInkingTool(
          .pen,
          color: style.uiColor(alpha: style.minimumOpacity),
          width: CGFloat(style.width)
        )
      }
      appliedDrawingTool = tool
      canvas.tool = tool == .pen ? ink : PKEraserTool(.vector)
    }

    func apply(_ data: Data, pageID: UUID, to canvas: PKCanvasView) {
      let drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
      guard self.pageID != pageID || drawing != appliedDrawing else { return }

      cancelPendingWork()
      self.pageID = pageID
      appliedDrawing = drawing
      applying = true
      canvas.drawing = drawing
      canvas.contentOffset = .zero
      canvas.zoomScale = 1
      applying = false
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
      if let endedSession {
        registerPressureTargets(from: endedSession, in: canvasView.drawing)
      }
      settleNow(canvasView)
      endedSession = nil
      activeSession = ToolSession(
        tool: appliedDrawingTool ?? .pen,
        penStyle: appliedPenStyle ?? .standard,
        strokeCountBefore: canvasView.drawing.strokes.count
      )
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
      guard !applying else { return }
      let drawing = canvasView.drawing
      guard drawing != appliedDrawing else { return }

      appliedDrawing = drawing
      emitLive(drawing)
      if let endedSession {
        registerPressureTargets(from: endedSession, in: drawing)
      }
      if activeSession == nil && containsPressureManagedStroke(in: drawing) {
        needsSettlement = true
      }
      if needsSettlement && activeSession == nil {
        scheduleSettlement(on: canvasView)
      }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
      endedSession = activeSession
      if let activeSession {
        registerPressureTargets(from: activeSession, in: canvasView.drawing)
      }
      if activeSession?.tool == .eraser {
        pressureStyles = [:]
      }

      activeSession = nil
      appliedDrawing = canvasView.drawing
      needsSettlement = true
      scheduleSettlement(on: canvasView)
    }

    func pencilInteraction(
      _ interaction: UIPencilInteraction,
      didReceiveTap tap: UIPencilInteraction.Tap
    ) {
      onToggleTool()
    }

    func pencilInteraction(
      _ interaction: UIPencilInteraction,
      didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
      guard squeeze.phase == .ended else { return }
      onToggleTool()
    }

    private func emitLive(_ drawing: PKDrawing) {
      let data = drawing.dataRepresentation()
      liveTask?.cancel()
      liveTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(34))
        guard !Task.isCancelled, let self else { return }
        onChange(data, false)
      }
    }

    private func scheduleSettlement(on canvas: PKCanvasView) {
      settlementTask?.cancel()
      settlementTask = Task { [weak self, weak canvas] in
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, let self, let canvas else { return }
        settleNow(canvas)
      }
    }

    private func settleNow(_ canvas: PKCanvasView) {
      guard needsSettlement else { return }
      liveTask?.cancel()
      settlementTask?.cancel()

      let settled = PressureSensitiveInk.apply(
        pressureStyles,
        to: canvas.drawing
      )
      needsSettlement = false

      pressureStyles = pressureStyles.filter {
        settled.strokes.indices.contains($0.key)
      }

      if settled != canvas.drawing {
        applying = true
        canvas.drawing = settled
        applying = false
      }
      appliedDrawing = settled
      onChange(settled.dataRepresentation(), true)
    }

    private func cancelPendingWork() {
      liveTask?.cancel()
      settlementTask?.cancel()
      activeSession = nil
      endedSession = nil
      pressureStyles = [:]
      needsSettlement = false
    }

    private func containsPressureManagedStroke(in drawing: PKDrawing) -> Bool {
      pressureStyles.keys.contains {
        drawing.strokes.indices.contains($0)
      }
    }

    private func registerPressureTargets(
      from session: ToolSession,
      in drawing: PKDrawing
    ) {
      guard session.tool == .pen,
            session.strokeCountBefore < drawing.strokes.count
      else { return }

      for index in session.strokeCountBefore ..< drawing.strokes.count {
        if pressureStyles[index] == nil {
          needsSettlement = true
        }
        pressureStyles[index] = session.penStyle
      }
    }
  }
}

@MainActor
private final class PaperCanvasView: PKCanvasView {
  override var canBecomeFirstResponder: Bool { false }

  override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
    .none
  }

  override func canPerformAction(
    _ action: Selector,
    withSender sender: Any?
  ) -> Bool {
    false
  }

  override func buildMenu(with builder: any UIMenuBuilder) {}
}

@MainActor
private enum PressureSensitiveInk {
  static func apply(
    _ styles: [Int: PenStyle],
    to drawing: PKDrawing
  ) -> PKDrawing {
    guard !styles.isEmpty else { return drawing }

    let strokes = drawing.strokes.enumerated().map { index, stroke in
      guard let style = styles[index] else { return stroke }
      return apply(style, to: stroke)
    }
    return PKDrawing(strokes: strokes)
  }

  private static func apply(_ style: PenStyle, to stroke: PKStroke) -> PKStroke {
    let points = stroke.path.map { point in
      PKStrokePoint(
        location: point.location,
        timeOffset: point.timeOffset,
        size: point.size,
        opacity: CGFloat(
          PencilPressureOpacity.value(
            force: Double(point.force),
            minimum: style.minimumOpacity
          )
        ),
        force: point.force,
        azimuth: point.azimuth,
        altitude: point.altitude,
        secondaryScale: point.secondaryScale,
        threshold: point.threshold
      )
    }

    var adjusted = stroke
    adjusted.path = PKStrokePath(
      controlPoints: points,
      creationDate: stroke.path.creationDate
    )
    adjusted.ink = PKInk(
      stroke.ink.inkType,
      color: style.uiColor(alpha: 1)
    )
    return adjusted
  }
}

private extension PenStyle {
  func uiColor(alpha: Double) -> UIColor {
    let components = color.components
    return UIColor(
      red: CGFloat(components.red),
      green: CGFloat(components.green),
      blue: CGFloat(components.blue),
      alpha: CGFloat(alpha)
    )
  }
}
