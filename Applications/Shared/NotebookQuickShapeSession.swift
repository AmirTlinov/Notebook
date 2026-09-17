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
  var onChange: ((NotebookQuickShapeFit?) -> Void)?
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
        onChange?(self.fit); return
      }
    }
  }

  func move(to point: SpatialPoint) {
    guard point.x.isFinite, point.y.isFinite else { return }
    last = point
    if let originalFit {
      fit = resolve(Self.adjusted(originalFit, heldAt: heldPoint, to: point, screenScale: scale))
      onChange?(fit)
    } else if hypot(point.x - anchor.x, point.y - anchor.y) * scale > Self.movementTolerance {
      anchor = point; lastMotion = ProcessInfo.processInfo.systemUptime
    }
  }

  /// Hold grabs the nearby edge/corner (or connector terminal), once. That
  /// handle follows the Pencil 1:1; the opposite edge stays where it was drawn.
  /// Always derive from the held fit, so clamp/reversal cannot accumulate drift.
  static func adjusted(_ original: NotebookQuickShapeFit, heldAt held: SpatialPoint,
    to point: SpatialPoint, screenScale: Double) -> NotebookQuickShapeFit {
    guard point.x.isFinite, point.y.isFinite else { return original }
    let dx = point.x - held.x, dy = point.y - held.y
    guard dx != 0 || dy != 0 else { return original }
    let frame = original.frame
    var result = original
    if var connection = original.connection {
      let local = SpatialPoint(x: held.x - frame.x, y: held.y - frame.y)
      let grabsStart = hypot(local.x - connection.start.point.x, local.y - connection.start.point.y)
        < hypot(local.x - connection.end.point.x, local.y - connection.end.point.y)
      var endpoint = grabsStart ? connection.start : connection.end
      endpoint.point = .init(x: endpoint.point.x + dx, y: endpoint.point.y + dy)
      endpoint.binding = nil
      if grabsStart { connection.start = endpoint } else { connection.end = endpoint }
      result.connection = connection
    } else {
      let x = (held.x - frame.x - frame.width / 2) / (frame.width / 2)
      let y = (held.y - frame.y - frame.height / 2) / (frame.height / 2)
      // Near an edge midpoint only that dimension changes; near a corner both
      // do. The choice is tied to the hold point, not retargeted while dragging.
      let horizontal = abs(x) * 2 >= abs(y)
      let vertical = abs(y) * 2 >= abs(x)
      let left = x < 0, top = y < 0
      let minimum = 12 / screenScale
      let width = horizontal ? max(minimum, frame.width + (left ? -dx : dx)) : frame.width
      let height = vertical ? max(minimum, frame.height + (top ? -dy : dy)) : frame.height
      result.frame = .init(x: horizontal && left ? frame.x + frame.width - width : frame.x,
        y: vertical && top ? frame.y + frame.height - height : frame.y, width: width, height: height)
    }
    return result
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
    endContact(cancelling: false)
    if accepted != nil { recent.removeAll() }
    return accepted
  }
  func cancel() { endContact(); recent.removeAll() }
  func endContact(cancelling: Bool = true) {
    let hadShape = fit != nil
    task?.cancel(); task = nil; generation = UUID(); fit = nil; originalFit = nil; resolve = { $0 }
    if cancelling && hadShape { onChange?(nil) }
  }
}
