import QuartzCore

/// An installed paper accepts a completed output behind its own opaque content
/// and clip. The renderer keeps its pool; this host owns physical mount validity.
@MainActor
protocol PageTurnOutputHost: AnyObject {
  func parkOutput(_ layer: CAMetalLayer, onRevoked: @escaping @MainActor () -> Void) -> Bool
  func unparkOutput(_ layer: CAMetalLayer)
}
