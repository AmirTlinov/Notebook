import NotebookCore
import SwiftUI

/// Uses the installed scene projection, including owner movement and camera
/// scale. Nothing here is saved as content or installed as a window-level layer.
struct NotebookTransientToolsOverlay: View {
  @Environment(NotebookAppModel.self) private var model
  let presence: SessionPresence
  var body: some View {
    ZStack(alignment:.topLeading) {
    if !model.drawingTools.laserTraces.isEmpty {
      TimelineView(.animation) { _ in
        Canvas { context,_ in
          let now = ProcessInfo.processInfo.systemUptime
          for trace in model.drawingTools.laserTraces {
            guard let origin = origin(trace.address) else { continue }
            let points = trace.points(at:now), scale = presence.camera.scale
            guard let first = points.first else { continue }
            func p(_ point: SpatialPoint) -> CGPoint { .init(x:origin.x+point.x*scale,y:origin.y+point.y*scale) }
            var path = Path(); path.move(to:p(first))
            for point in points.dropFirst() { path.addLine(to:p(point)) }
            if points.count == 1 { path.addLine(to:.init(x:p(first).x+0.001,y:p(first).y)) }
            context.stroke(path,with:.color(trace.color.displayColor),style:.init(lineWidth:trace.width*scale,lineCap:.round,lineJoin:.round))
          }
        }
      }.allowsHitTesting(false).accessibilityHidden(true)
    }
    if model.drawingTool == .ruler, let ruler = model.drawingTools.ruler, let zero = origin(ruler.address) {
      NotebookRulerControl(model:model,ruler:ruler,origin:zero,scale:presence.camera.scale)
    }
  }
    }
  private func origin(_ address: NotebookToolAddress) -> CGPoint? {
    if address.surface.kind == .board {
      guard address.surface.ownerID == presence.boardID else { return nil }
      let p = presence.camera.worldToScreen(address.worldOrigin ?? .zero,viewport:presence.viewport)
      return .init(x:p.x,y:p.y)
    }
    guard let rect = NotebookAttentionProjection.frame(.init(target:address.target,revision:""),model:model,presence:presence) else { return nil }
    return rect.origin
  }
}
