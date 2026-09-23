import NotebookCore

// Deliberately exhaustive reference for persistence/rendering fixtures. Live
// input uses InkElementContact; no full-prefix selector ships in NotebookCore.
extension PageInkAction {
  func erasingElements(_ targets: [InkElementTarget]) -> Self {
    guard tool == .eraser else { return self }
    return Self(id: id, tool: tool, color: color, measurements: samples, sequence: sequence, isActive: isActive,
      elementTargets: targets.filter { $0.intersects(samples) }, stateStamp: stateStamp)
  }

}
extension SpatialInkSpan {
  func erasingElements(_ targets: [InkElementTarget]) -> Self {
    .init(surface: surface, measurements: samples, elementTargets: targets.filter { $0.intersects(samples) })
  }

}
