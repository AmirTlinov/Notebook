import Foundation
import NotebookCore

enum NotebookElementCorner: String, CaseIterable, Sendable {
  case topLeading, topTrailing, bottomLeading, bottomTrailing
  var leading: Bool { self == .topLeading || self == .bottomLeading }
  var top: Bool { self == .topLeading || self == .topTrailing }
  var label: String {
    switch self {
    case .topLeading: "верхний левый"
    case .topTrailing: "верхний правый"
    case .bottomLeading: "нижний левый"
    case .bottomTrailing: "нижний правый"
    }
  }
  func point(in frame: CGRect) -> CGPoint {
    .init(x: leading ? frame.minX : frame.maxX, y: top ? frame.minY : frame.maxY)
  }
}

/// One accepted contact, anchored to the physical frame it actually touched.
/// The opposite corner never moves, even when a page edge or minimum is reached.
struct NotebookElementManipulation: Equatable, Sendable {
  enum Kind: Equatable, Sendable { case move, resize(NotebookElementCorner), endpoint(NotebookGraphicConnection.Terminal), bend }
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
    case .resize(let corner):
      let minimumWidth = min(44, original.width), minimumHeight = min(44, original.height)
      let widthLimit = max(2048, original.width), heightLimit = max(2048, original.height)
      let x: CGFloat, y: CGFloat, right: CGFloat, bottom: CGFloat
      if corner.leading {
        right = original.maxX
        x = min(original.maxX - minimumWidth, max(bounds?.minX ?? (original.maxX - widthLimit), original.minX + translation.x))
      } else {
        x = original.minX
        right = max(x + minimumWidth, min(bounds?.maxX ?? (x + widthLimit), original.maxX + translation.x))
      }
      if corner.top {
        bottom = original.maxY
        y = min(original.maxY - minimumHeight, max(bounds?.minY ?? (original.maxY - heightLimit), original.minY + translation.y))
      } else {
        y = original.minY
        bottom = max(y + minimumHeight, min(bounds?.maxY ?? (y + heightLimit), original.maxY + translation.y))
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
