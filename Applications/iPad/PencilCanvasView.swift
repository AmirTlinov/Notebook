import PencilKit
import SwiftUI
import UIKit

struct PencilCanvasView: UIViewRepresentable {
  let pageID: UUID
  let drawingData: Data
  let onChange: (Data, Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onChange: onChange)
  }

  func makeUIView(context: Context) -> PKCanvasView {
    let canvas = PKCanvasView(frame: .zero)
    canvas.delegate = context.coordinator
    canvas.drawingPolicy = .pencilOnly
    canvas.tool = PKInkingTool(.pen, color: .black, width: 2.2)
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.isScrollEnabled = false
    canvas.minimumZoomScale = 1
    canvas.maximumZoomScale = 1
    canvas.bouncesZoom = false
    canvas.contentInset = .zero
    context.coordinator.attach(to: canvas)
    context.coordinator.apply(drawingData, pageID: pageID, to: canvas)
    return canvas
  }

  func updateUIView(_ canvas: PKCanvasView, context: Context) {
    context.coordinator.onChange = onChange
    context.coordinator.apply(drawingData, pageID: pageID, to: canvas)
    canvas.contentSize = canvas.bounds.size
    canvas.contentOffset = .zero
    canvas.zoomScale = 1
  }

  @MainActor
  final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    var onChange: (Data, Bool) -> Void

    private weak var canvas: PKCanvasView?
    private var pageID: UUID?
    private var appliedDrawing = PKDrawing()
    private var applying = false
    private var liveTask: Task<Void, Never>?
    private let ink = PKInkingTool(.pen, color: .black, width: 2.2)

    init(onChange: @escaping (Data, Bool) -> Void) {
      self.onChange = onChange
    }

    func attach(to canvas: PKCanvasView) {
      self.canvas = canvas
      canvas.addInteraction(UIPencilInteraction(delegate: self))
    }

    func apply(_ data: Data, pageID: UUID, to canvas: PKCanvasView) {
      let drawing = (try? PKDrawing(data: data)) ?? PKDrawing()
      guard self.pageID != pageID || drawing != appliedDrawing else { return }
      liveTask?.cancel()
      self.pageID = pageID
      appliedDrawing = drawing
      applying = true
      canvas.drawing = drawing
      canvas.contentOffset = .zero
      canvas.zoomScale = 1
      applying = false
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
      guard !applying else { return }
      let drawing = canvasView.drawing
      guard drawing != appliedDrawing else { return }
      appliedDrawing = drawing
      let data = drawing.dataRepresentation()
      liveTask?.cancel()
      liveTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(34))
        guard !Task.isCancelled, let self else { return }
        onChange(data, false)
      }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
      liveTask?.cancel()
      appliedDrawing = canvasView.drawing
      let data = appliedDrawing.dataRepresentation()
      onChange(data, true)
    }

    func pencilInteraction(
      _ interaction: UIPencilInteraction,
      didReceiveTap tap: UIPencilInteraction.Tap
    ) {
      toggleEraser()
    }

    func pencilInteraction(
      _ interaction: UIPencilInteraction,
      didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
      guard squeeze.phase == .ended else { return }
      toggleEraser()
    }

    private func toggleEraser() {
      guard let canvas else { return }
      canvas.tool = canvas.tool is PKEraserTool ? ink : PKEraserTool(.vector)
    }
  }
}
