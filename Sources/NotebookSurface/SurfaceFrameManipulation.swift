/// The authored edges selected by a contact. Platforms only project these
/// controls into their input and accessibility systems.
public enum NotebookElementResizeHandle: String, CaseIterable, Sendable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing, topCenter, bottomCenter, leadingCenter, trailingCenter

  public var leading: Bool { self == .topLeading || self == .bottomLeading || self == .leadingCenter }
  public var top: Bool { self == .topLeading || self == .topTrailing || self == .topCenter }
  public var changesWidth: Bool { self != .topCenter && self != .bottomCenter }
  public var changesHeight: Bool { self != .leadingCenter && self != .trailingCenter }
  public var isCorner: Bool { changesWidth && changesHeight }
  public static let textWidth: [Self] = [.leadingCenter, .trailingCenter]

  /// Side grips need room between the corners. Their touch targets never
  /// impose a minimum on authored geometry.
  public static func visible(in size: SpatialPoint) -> [Self] {
    allCases.filter { $0.isCorner || ($0.changesWidth ? size.y : size.x) >= 112 }
  }

  public var anchor: SpatialPoint {
    .init(x: changesWidth ? (leading ? 0 : 1) : 0.5,
      y: changesHeight ? (top ? 0 : 1) : 0.5)
  }

  public var label: String {
    switch self {
    case .topLeading: "верхний левый угол"
    case .topTrailing: "верхний правый угол"
    case .bottomLeading: "нижний левый угол"
    case .bottomTrailing: "нижний правый угол"
    case .topCenter: "верхний край"
    case .bottomCenter: "нижний край"
    case .leadingCenter: "левый край"
    case .trailingCenter: "правый край"
    }
  }
}

/// One physical contact, always solved from its immutable starting frame.
/// Reversing after a clamp restores the same pose independently of event rate.
public struct SurfaceFrameManipulation: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case move
    case resize(NotebookElementResizeHandle)
  }

  public let kind: Kind
  public let original: SpatialRect
  public let bounds: SpatialRect?

  public init?(kind: Kind, original: SpatialRect, bounds: SpatialRect? = nil) {
    guard Self.admits(original), bounds.map(Self.admits) ?? true else { return nil }
    self.kind = kind; self.original = original; self.bounds = bounds
  }

  /// A failed projection leaves the caller's last admitted pose untouched.
  public func frame(at translation: SpatialPoint) -> SpatialRect? {
    guard translation.isValid else { return nil }
    if translation == .zero { return original }
    let x: Double, y: Double, width: Double, height: Double
    switch kind {
    case .move:
      let proposedX = original.x + translation.x, proposedY = original.y + translation.y
      guard proposedX.isFinite, proposedY.isFinite else { return nil }
      x = bounds.map { min(max(proposedX, $0.x), $0.x + $0.width - original.width) } ?? proposedX
      y = bounds.map { min(max(proposedY, $0.y), $0.y + $0.height - original.height) } ?? proposedY
      width = original.width; height = original.height
    case .resize(let handle):
      let right = original.x + original.width, bottom = original.y + original.height
      let minimumWidth = min(1, original.width), minimumHeight = min(1, original.height)
      let nextRight: Double, nextBottom: Double
      if !handle.changesWidth { x = original.x; nextRight = right }
      else if handle.leading {
        let proposed = original.x + translation.x
        guard proposed.isFinite else { return nil }
        nextRight = right
        x = min(right - minimumWidth, max(bounds?.x ?? -.greatestFiniteMagnitude, proposed))
      } else {
        let proposed = right + translation.x
        guard proposed.isFinite else { return nil }
        x = original.x
        nextRight = max(x + minimumWidth, min(bounds.map { $0.x + $0.width } ?? .greatestFiniteMagnitude, proposed))
      }
      if !handle.changesHeight { y = original.y; nextBottom = bottom }
      else if handle.top {
        let proposed = original.y + translation.y
        guard proposed.isFinite else { return nil }
        nextBottom = bottom
        y = min(bottom - minimumHeight, max(bounds?.y ?? -.greatestFiniteMagnitude, proposed))
      } else {
        let proposed = bottom + translation.y
        guard proposed.isFinite else { return nil }
        y = original.y
        nextBottom = max(y + minimumHeight, min(bounds.map { $0.y + $0.height } ?? .greatestFiniteMagnitude, proposed))
      }
      width = nextRight - x; height = nextBottom - y
    }
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0,
      (x + width).isFinite, (y + height).isFinite,
      (x - original.x).isFinite, (y - original.y).isFinite else { return nil }
    return .init(x: x, y: y, width: width, height: height)
  }

  private static func admits(_ frame: SpatialRect) -> Bool {
    frame.isValid && (frame.x + frame.width).isFinite && (frame.y + frame.height).isFinite
  }
}
