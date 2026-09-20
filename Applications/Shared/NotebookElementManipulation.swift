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
  enum Kind: Equatable, Sendable { case move, resize(NotebookElementResizeHandle), endpoint(NotebookGraphicConnection.Terminal), bend, vertex(Int), roundCorners }
  let id = UUID()
  let reference: EditableElementReference
  let kind: Kind
  let original: CGRect
  let bounds: CGRect?
  let identity: VersionStamp?
  let worldOrigin: WorldPoint?
  private(set) var frame: CGRect
  let originalConnection: NotebookGraphicConnection?
  /// Resolved in the authored body, never the displayed outer frame.
  let originalLayout: NotebookGraphicLayout?
  let placement: NotebookElementPlacement?
  let displayFrame: CGRect
  var originalBasis: NotebookElementBasis? { placement?.basis }
  private(set) var basis: NotebookElementBasis?
  private(set) var connection: NotebookGraphicConnection?
  let originalVertices: [SpatialPoint]?
  private(set) var vertices: [SpatialPoint]?
  let originalCornerRadius: Double
  private(set) var cornerRadius: Double
  private let graphic: NotebookGraphic?
  var ancestorReferences: [EditableElementReference] {
    (placement?.ancestors ?? []).map { ancestor in
      switch reference { case .page(let owner,_): .page(pageID:owner,elementID:ancestor)
        case .spatial(let owner,_): .spatial(boardID:owner,elementID:ancestor) }
    }
  }
  var selectedMembers: [NotebookGraphicSelection.Member] = []
  var selectedEdits: [NotebookGraphicSelection.Edit] {
    NotebookGraphicSelection.translated(selectedMembers, by: .init(x: movement.x,y: movement.y))
  }

  init(reference: EditableElementReference, kind: Kind, frame: CGRect, bounds: CGRect?, identity: VersionStamp? = nil,
    worldOrigin: WorldPoint? = nil, connection: NotebookGraphicConnection? = nil, layout: NotebookGraphicLayout? = nil,
    graphic: NotebookGraphic? = nil, placement: NotebookElementPlacement? = nil, displayFrame: CGRect? = nil) {
    self.reference = reference; self.kind = kind; original = frame
    self.frame = frame; self.bounds = bounds
    self.identity = identity; self.worldOrigin = placement?.origin ?? worldOrigin
    self.placement=placement;basis=placement?.basis;self.displayFrame=displayFrame ?? frame
    originalConnection = connection; self.connection = connection; originalLayout = layout
    self.graphic = graphic; originalVertices = graphic.flatMap(NotebookGraphicGeometry.polygon); vertices = originalVertices
    originalCornerRadius = graphic?.cornerRadius ?? 0; cornerRadius = originalCornerRadius
  }

  mutating func update(translation: CGPoint) {
    guard translation.x.isFinite, translation.y.isFinite else { return }
    if translation == .zero {
      frame = original; basis=originalBasis; connection = originalConnection; vertices = originalVertices; cornerRadius = originalCornerRadius
      return
    }
    switch kind {
    case .move:
      let x = bounds.map { min(max(displayFrame.minX + translation.x, $0.minX), $0.maxX - displayFrame.width) } ?? (displayFrame.minX + translation.x)
      let y = bounds.map { min(max(displayFrame.minY + translation.y, $0.minY), $0.maxY - displayFrame.height) } ?? (displayFrame.minY + translation.y)
      let physical=SpatialPoint(x:x-displayFrame.minX,y:y-displayFrame.minY)
      guard let delta=placement.map({ $0.parentVector(physical) }) ?? physical else { return }
      frame = .init(x:original.minX+delta.x,y:original.minY+delta.y,width:original.width,height:original.height)
      if var value = originalConnection, !value.bindings.isEmpty, let layout = originalLayout {
        // Dragging the body translates it, never secretly bends it. Detach
        // from the visible terminals, not stale fallback points in the record.
        if frame == original { connection = originalConnection; return }
        func point(_ p: SpatialPoint) -> SpatialPoint {
          .init(x:layout.frame.x+p.x,y:layout.frame.y+p.y)
        }
        value.start = .init(point:point(layout.start)); value.end = .init(point:point(layout.end))
        let midpoint = layout.bend
        let dx = layout.end.x-layout.start.x, dy = layout.end.y-layout.start.y, length = max(0.001,hypot(dx,dy))
        value.bendPosition = min(1,max(0,((midpoint.x-layout.start.x)*dx+(midpoint.y-layout.start.y)*dy)/(length*length)))
        value.bend = (-dy*(midpoint.x-(layout.start.x+layout.end.x)/2)+dx*(midpoint.y-(layout.start.y+layout.end.y)/2))/length
        connection = value
      }
    case .resize(let corner):
      let original=displayFrame
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
      let shown=CGRect(x:x,y:y,width:right-x,height:bottom-y)
      if let placement {
        let change=CGAffineTransform(translationX:-original.minX,y:-original.minY)
          .concatenating(.init(scaleX:shown.width/original.width,y:shown.height/original.height))
          .concatenating(.init(translationX:shown.minX,y:shown.minY))
        guard let pose=try? placement.applyingSurfaceTransform(change) else { return }
        frame = .init(x:pose.frame.x,y:pose.frame.y,width:pose.frame.width,height:pose.frame.height);basis=pose.basis
      } else { frame=shown }
    case .endpoint(let terminal):
      guard var value = originalConnection, let layout = originalLayout else { return }
      let p = terminal == .start ? layout.start : layout.end
      let physical=SpatialPoint(x:translation.x,y:translation.y)
      guard let delta=placement.map({ $0.bodyVector(physical) }) ?? physical else { return }
      let endpoint = NotebookGraphicConnection.Endpoint(point:.init(x:layout.frame.x+p.x+delta.x,y:layout.frame.y+p.y+delta.y))
      if terminal == .start { value.start = endpoint } else { value.end = endpoint }
      connection = value
    case .bend:
      guard var value = originalConnection, let layout = originalLayout else { return }
      let physical=SpatialPoint(x:translation.x,y:translation.y)
      guard let delta=placement.map({ $0.bodyVector(physical) }) ?? physical else { return }
      let translation=CGPoint(x:delta.x,y:delta.y)
      let dx = layout.axisEnd.x-layout.axisStart.x, dy = layout.axisEnd.y-layout.axisStart.y, length = max(0.001,hypot(dx,dy))
      value.bendPosition = min(1,max(0,(value.bendPosition ?? 0.5)+(dx*translation.x+dy*translation.y)/(length*length)))
      value.bend += (-dy*translation.x+dx*translation.y)/length
      if value.resolvedRouting == .straight { value.routing = .curved }
      connection = value
    case .vertex(let index):
      guard let originalVertices, originalVertices.indices.contains(index) else { return }
      let points = originalVertices.map { CGPoint(x:original.minX+$0.x*original.width,y:original.minY+$0.y*original.height) }
      var wanted = CGPoint(x:points[index].x+translation.x,y:points[index].y+translation.y)
      if let bounds { wanted.x = min(bounds.maxX,max(bounds.minX,wanted.x)); wanted.y = min(bounds.maxY,max(bounds.minY,wanted.y)) }
      func candidate(_ fraction: Double) -> (CGRect,[SpatialPoint])? {
        var next = points
        next[index] = .init(x:points[index].x+(wanted.x-points[index].x)*fraction,y:points[index].y+(wanted.y-points[index].y)*fraction)
        let x = next.map(\.x).min()!, y = next.map(\.y).min()!
        let width = next.map(\.x).max()!-x, height = next.map(\.y).max()!-y
        guard width >= 1, height >= 1 else { return nil }
        let normalized = next.map { SpatialPoint(x:($0.x-x)/width,y:($0.y-y)/height) }
        guard NotebookGraphicGeometry.isConvex(normalized,sameWindingAs:originalVertices) else { return nil }
        return (.init(x:x,y:y,width:width,height:height),normalized)
      }
      if let next = candidate(1) { frame = next.0; vertices = next.1 }
      else {
        // Stop at the convex boundary instead of flipping/crossing other edges.
        var low = 0.0, high = 1.0
        for _ in 0..<24 { let mid = (low+high)/2; if candidate(mid) == nil { high = mid } else { low = mid } }
        if let next = candidate(low) { frame = next.0; vertices = next.1 }
      }
    case .roundCorners:
      guard let graphic, let corner = NotebookGraphicGeometry.corners(graphic,width:original.width,height:original.height).first else { return }
      let maximum = NotebookGraphicGeometry.maximumCornerRadius(graphic,width:original.width,height:original.height)
      let start = min(originalCornerRadius,maximum)
      cornerRadius = min(maximum,max(0,start+(translation.x*corner.bisector.x+translation.y*corner.bisector.y)*corner.sine))
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


}
