import Foundation
import NotebookCore

/// An extension of the accepted Pencil contact, not another recognizer. Only
/// hold deadlines read the stroke buffer; ordinary samples update one point.
@MainActor
final class NotebookQuickShapeSession {
  static let holdSeconds = 0.5
  static let movementTolerance = 6.0
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var anchor = SpatialPoint.zero
  private var last = SpatialPoint.zero
  private var lastMotion = 0.0
  private var scale = 1.0
  private var originalFit: NotebookQuickShapeFit?
  private var heldPoint = SpatialPoint.zero
  private(set) var fit: NotebookQuickShapeFit?
  var onPreview: ((NotebookQuickShapeFit?) -> Void)?
  private var resolve: @MainActor (NotebookQuickShapeFit) -> NotebookQuickShapeFit = { $0 }

  func begin(at point: SpatialPoint, screenScale: Double,
    resolve: @escaping @MainActor (NotebookQuickShapeFit) -> NotebookQuickShapeFit = { $0 },
    measured: @escaping @MainActor () -> [SpatialPoint]) {
    cancel()
    generation = UUID(); let generation = generation
    anchor = point; last = point; scale = screenScale
    self.resolve = resolve
    lastMotion = ProcessInfo.processInfo.systemUptime
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.generation == generation else { return }
        let remaining = Self.holdSeconds - (ProcessInfo.processInfo.systemUptime - lastMotion)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)); continue }
        let points = measured()
        guard let fit = NotebookQuickShape.recognize(points, screenScale: scale) else {
          // Retry only after a new intentional movement, not at every sample.
          let motion = lastMotion
          repeat { try? await Task.sleep(for: .seconds(Self.holdSeconds)) }
          while !Task.isCancelled && lastMotion == motion
          continue
        }
        guard !Task.isCancelled, self.generation == generation else { return }
        originalFit = fit; self.fit = self.resolve(fit); heldPoint = last
        onPreview?(self.fit); return
      }
    }
  }

  func move(to point: SpatialPoint) {
    last = point
    if let originalFit {
      if var connection = originalFit.connection {
        connection.end.point = .init(x:connection.end.point.x+point.x-heldPoint.x,y:connection.end.point.y+point.y-heldPoint.y)
        var adjusted = originalFit; adjusted.connection = connection
        fit = resolve(adjusted); onPreview?(fit); return
      }
      let frame = originalFit.frame
      let width = max(12 / scale, frame.width + 2 * (point.x - heldPoint.x))
      let height = max(12 / scale, frame.height + 2 * (point.y - heldPoint.y))
      fit = resolve(.init(frame: .init(x: frame.x + (frame.width - width) / 2,
        y: frame.y + (frame.height - height) / 2, width: width, height: height), sampleCount: originalFit.sampleCount))
      onPreview?(fit)
    } else if hypot(point.x - anchor.x, point.y - anchor.y) * scale > Self.movementTolerance {
      anchor = point; lastMotion = ProcessInfo.processInfo.systemUptime
    }
  }

  func finish() -> NotebookQuickShapeFit? { let accepted = fit; cancel(); return accepted }
  func cancel() {
    task?.cancel(); task = nil; generation = UUID(); fit = nil; originalFit = nil; resolve = { $0 }; onPreview?(nil)
  }
}
