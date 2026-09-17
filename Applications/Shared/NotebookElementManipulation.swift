import Foundation
import NotebookCore

enum NotebookElementResizeHandle: String, CaseIterable, Sendable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing, topCenter, bottomCenter, leadingCenter, trailingCenter
  var leading: Bool { self == .topLeading || self == .bottomLeading || self == .leadingCenter }
  var top: Bool { self == .topLeading || self == .topTrailing || self == .topCenter }
  var changesWidth: Bool { self != .topCenter && self != .bottomCenter }
  var changesHeight: Bool { self != .leadingCenter && self != .trailingCenter }
  var isCorner: Bool { changesWidth && changesHeight }
  /// Side grips need room between the corners. Touch target size never changes
  /// the authored geometry or makes a small object's centre into a resize grip.
  static func visible(in size: CGSize) -> [Self] {
    allCases.filter { $0.isCorner || ($0.changesWidth ? size.height : size.width) >= 112 }
  }
  var label: String {
    switch self {
    case .topLeading: "верхний левый угол"
    case .topTrailing: "верхний правый угол"
    case .bottomLeading: "нижний левый угол"
    case .bottomTrailing: "нижний правый угол"
    case .topCenter: "верхний край"; case .bottomCenter: "нижний край"
    case .leadingCenter: "левый край"; case .trailingCenter: "правый край"
    }
  }
  func point(in frame: CGRect) -> CGPoint {
    .init(x: changesWidth ? (leading ? frame.minX : frame.maxX) : frame.midX,
      y: changesHeight ? (top ? frame.minY : frame.maxY) : frame.midY)
  }
}

/// One accepted contact, anchored to the physical frame it actually touched.
/// The opposite corner never moves, even when a page edge or minimum is reached.
struct NotebookElementManipulation: Equatable, Sendable {
  enum Kind: Equatable, Sendable { case move, resize(NotebookElementResizeHandle), endpoint(NotebookGraphicConnection.Terminal), bend }
  let id = UUID()
  let reference: EditableElementReference
  let kind: Kind
  let original: CGRect
  let bounds: CGRect?
  let identity: VersionStamp?
  let worldOrigin: WorldPoint?
  private(set) var frame: CGRect
  let originalConnection: NotebookGraphicConnection?
  let originalLayout: NotebookGraphicLayout?
  private(set) var connection: NotebookGraphicConnection?

  init(reference: EditableElementReference, kind: Kind, frame: CGRect, bounds: CGRect?, identity: VersionStamp? = nil,
    worldOrigin: WorldPoint? = nil, connection: NotebookGraphicConnection? = nil, layout: NotebookGraphicLayout? = nil) {
    self.reference = reference; self.kind = kind; original = frame
    self.frame = frame; self.bounds = bounds
    self.identity = identity; self.worldOrigin = worldOrigin
    originalConnection = connection; self.connection = connection; originalLayout = layout
  }

  mutating func update(translation: CGPoint) {
    guard translation.x.isFinite, translation.y.isFinite else { return }
    switch kind {
    case .move:
      let x = bounds.map { min(max(original.minX + translation.x, $0.minX), $0.maxX - original.width) } ?? (original.minX + translation.x)
      let y = bounds.map { min(max(original.minY + translation.y, $0.minY), $0.maxY - original.height) } ?? (original.minY + translation.y)
      frame = .init(x: x, y: y, width: original.width, height: original.height)
      if var value = originalConnection, !value.bindings.isEmpty, let layout = originalLayout {
        // Dragging the body translates it, never secretly bends it. Detach
        // from the visible terminals, not stale fallback points in the record.
        if frame == original { connection = originalConnection; return }
        func point(_ p: SpatialPoint) -> SpatialPoint {
          .init(x:layout.frame.x+p.x-original.minX,y:layout.frame.y+p.y-original.minY)
        }
        value.start = .init(point:point(layout.start)); value.end = .init(point:point(layout.end))
        let middleIndex = layout.curves.count/2
        let midpoint = layout.curves[middleIndex].point(at:layout.curves.count.isMultiple(of:2) ? 0 : 0.5)
        let dx = layout.end.x-layout.start.x, dy = layout.end.y-layout.start.y, length = max(0.001,hypot(dx,dy))
        value.bend = (-dy*(midpoint.x-(layout.start.x+layout.end.x)/2)+dx*(midpoint.y-(layout.start.y+layout.end.y)/2))/length
        connection = value
      }
    case .resize(let corner):
      let minimumWidth = min(1, original.width), minimumHeight = min(1, original.height)
      let x: CGFloat, y: CGFloat, right: CGFloat, bottom: CGFloat
      if !corner.changesWidth { x = original.minX; right = original.maxX }
      else if corner.leading {
        right = original.maxX
        x = min(original.maxX - minimumWidth, max(bounds?.minX ?? -.greatestFiniteMagnitude, original.minX + translation.x))
      } else {
        x = original.minX
        right = max(x + minimumWidth, min(bounds?.maxX ?? .greatestFiniteMagnitude, original.maxX + translation.x))
      }
      if !corner.changesHeight { y = original.minY; bottom = original.maxY }
      else if corner.top {
        bottom = original.maxY
        y = min(original.maxY - minimumHeight, max(bounds?.minY ?? -.greatestFiniteMagnitude, original.minY + translation.y))
      } else {
        y = original.minY
        bottom = max(y + minimumHeight, min(bounds?.maxY ?? .greatestFiniteMagnitude, original.maxY + translation.y))
      }
      frame = .init(x: x, y: y, width: right - x, height: bottom - y)
    case .endpoint(let terminal):
      guard var value = originalConnection, let layout = originalLayout else { return }
      let p = terminal == .start ? layout.start : layout.end
      let endpoint = NotebookGraphicConnection.Endpoint(point: .init(x:layout.frame.x+p.x-original.minX+translation.x,
        y:layout.frame.y+p.y-original.minY+translation.y))
      if terminal == .start { value.start = endpoint } else { value.end = endpoint }
      connection = value
    case .bend:
      guard var value = originalConnection, let layout = originalLayout else { return }
      let dx = layout.end.x-layout.start.x, dy = layout.end.y-layout.start.y, length = max(0.001,hypot(dx,dy))
      value.bend += (-dy*translation.x+dx*translation.y)/length
      connection = value
    }
  }

  mutating func bindEndpoint(_ binding: NotebookGraphicConnection.Binding?) {
    guard case .endpoint(let terminal) = kind else { return }
    if terminal == .start { connection?.start.binding = binding } else { connection?.end.binding = binding }
  }

  var movement: CGPoint {
    guard kind == .move else { return .zero }
    return .init(x: frame.minX - original.minX, y: frame.minY - original.minY)
  }

  func projected(over originalScreenFrame: CGRect, scale: Double) -> CGRect {
    .init(x: originalScreenFrame.minX + (frame.minX - original.minX) * scale,
      y: originalScreenFrame.minY + (frame.minY - original.minY) * scale,
      width: frame.width * scale, height: frame.height * scale)
  }
}
