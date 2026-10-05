import CoreGraphics
import NotebookSurface

extension InkRenderGeometry {
  /// CoreGraphics adapter for the canonical surface envelope.
  public static func bounds(_ nodes: ArraySlice<Node>) -> CGRect {
    guard let extent = extent(nodes) else { return .null }
    return .init(x: Double(extent.minimum.x), y: Double(extent.minimum.y),
      width: Double(extent.maximum.x - extent.minimum.x),
      height: Double(extent.maximum.y - extent.minimum.y))
  }
}
