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
      TimelineView(.animation) { timeline in
        // Capture the timeline tick in the Canvas value, not a clock read hidden
        // inside its cached drawing closure. Lift need not mutate the model.
        let now = timeline.date.timeIntervalSinceReferenceDate
        Canvas { context,_ in
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
    if let region=model.selectionSession.region,let zero=origin(region.address) {
      let f=model.selectionSession.manipulation.flatMap { $0.reference == region.reference ? $0.frame : nil }
        ?? CGRect(x:region.frame.x,y:region.frame.y,width:region.frame.width,height:region.frame.height)
      contour(region.polygon.map { .init(x:f.minX+($0.x-region.frame.x)*f.width/region.frame.width,
        y:f.minY+($0.y-region.frame.y)*f.height/region.frame.height) },origin:zero)
    } else if let pending=model.drawingTools.pendingLasso,let zero=origin(pending.address) {
      contour(pending.points,origin:zero)
    }
    if model.drawingTools.guideEnabled, let guide = model.drawingTools.guide, let zero = origin(guide.address) {
      NotebookGuideControl(model:model,guide:guide,origin:zero,scale:presence.camera.scale)
    }
  }
    }
  private func contour(_ points:[SpatialPoint],origin:CGPoint) -> some View {
    Path { path in
      path.addLines(points.map { .init(x:origin.x+$0.x*presence.camera.scale,y:origin.y+$0.y*presence.camera.scale) })
      path.closeSubpath()
    }.stroke(.blue,style:.init(lineWidth:1.5,dash:[5,3])).allowsHitTesting(false).accessibilityHidden(true)
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
