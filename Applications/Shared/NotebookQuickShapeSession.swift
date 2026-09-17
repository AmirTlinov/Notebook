import Foundation
import NotebookCore

/// An extension of the accepted Pencil contact, not another recognizer. Only
/// hold deadlines read the stroke buffer; ordinary samples update one point.
@MainActor
final class NotebookQuickShapeSession {
  static let holdSeconds = 0.5
  static let movementTolerance = 6.0
  static let sequenceSeconds = 3.0
  private struct RecentStroke {
    let id: UUID
    let points: [SpatialPoint]
    let finishedAt: TimeInterval
  }
  private var recent: [RecentStroke] = []
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
    endContact()
    expireSequence()
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
        var candidate: NotebookQuickShapeFit?
        // Only consecutive, fresh, same-surface contacts participate. Prefer
        // the smallest complete compound shape; never search the notebook.
        for index in recent.indices {
          let count = index + 1
          let source = Array(recent.suffix(count))
          if var fit = NotebookQuickShape.recognize(strokes: source.map(\.points)+[points], screenScale: scale) {
            fit.precedingStrokeIDs = source.map(\.id); candidate = fit; break
          }
        }
        if candidate == nil { candidate = NotebookQuickShape.recognize(points, screenScale: scale) }
        guard let fit = candidate else {
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
      var adjusted = originalFit
      adjusted.frame = .init(x: frame.x + (frame.width - width) / 2,
        y: frame.y + (frame.height - height) / 2, width: width, height: height)
      adjusted.resolvedLayout = nil
      fit = resolve(adjusted)
      onPreview?(fit)
    } else if hypot(point.x - anchor.x, point.y - anchor.y) * scale > Self.movementTolerance {
      anchor = point; lastMotion = ProcessInfo.processInfo.systemUptime
    }
  }

  func remember(_ id: UUID, points: [SpatialPoint]) {
    guard points.count >= 2, points.count <= 8192 else { recent.removeAll(); return }
    let now = ProcessInfo.processInfo.systemUptime
    expireSequence()
    recent.append(.init(id:id,points:points,finishedAt:now))
    recent = Array(recent.suffix(3))
  }
  private func expireSequence() {
    if let last = recent.last, ProcessInfo.processInfo.systemUptime - last.finishedAt > Self.sequenceSeconds {
      recent.removeAll()
    }
  }
  func finish() -> NotebookQuickShapeFit? {
    let accepted = fit
    endContact()
    if accepted != nil { recent.removeAll() }
    return accepted
  }
  func cancel() { endContact(); recent.removeAll() }
  func endContact() {
    task?.cancel(); task = nil; generation = UUID(); fit = nil; originalFit = nil; resolve = { $0 }; onPreview?(nil)
  }
}
