import NotebookCore
import SwiftUI

/// A value from the installed scene, not another geometry or animation owner.
struct NotebookAgentPearlSurface {
  let rect: CGRect
  var scale: Double = 1
  var graphic: NotebookGraphic? = nil
  var layout: NotebookGraphicLayout? = nil
  var erasures: [InkElementErasure] = []
  var clipRect: CGRect? = nil
}

/// One broad light pass over the actual object. Absolute receipt time prevents
/// replay on remount; only this small paint subtree ticks during the pass.
struct NotebookAgentPearl: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let surface: NotebookAgentPearlSurface
  let startedAt: Date

  var body: some View {
    TimelineView(.animation(minimumInterval:1/60,paused:reduceMotion)) { timeline in
      Canvas { context, size in
        Self.paint(surface,age:timeline.date.timeIntervalSince(startedAt),reduceMotion:reduceMotion,in:context,size:size)
      }
      .frame(width:surface.rect.width,height:surface.rect.height)
      .position(x:surface.rect.midX,y:surface.rect.midY)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  static func paint(_ surface: NotebookAgentPearlSurface, age: TimeInterval, reduceMotion: Bool = false,
    in context: GraphicsContext, size: CGSize) {
    let duration = NotebookAppModel.agentHighlightDuration
    guard age >= 0, age < duration, size.width > 0, size.height > 0, surface.scale > 0 else { return }
    var context = context
    if let clip = surface.clipRect {
      context.clip(to:Path(clip.offsetBy(dx:-surface.rect.minX,dy:-surface.rect.minY)))
    }
    context.clipToLayer { mask in
      let localSize = CGSize(width:size.width/surface.scale,height:size.height/surface.scale)
      mask.scaleBy(x:surface.scale,y:surface.scale)
      if let graphic = surface.graphic {
        NotebookGraphicView.paintSilhouette(graphic,layout:surface.layout,in:mask,size:localSize,erasures:surface.erasures)
      } else {
        NotebookElementErasurePaint.clip(surface.erasures,context:&mask,size:localSize)
        mask.fill(Path(CGRect(origin:.zero,size:localSize)),with:.color(.white))
      }
    }
    // A broad cyan–lilac–pearl–rose ribbon crosses the whole silhouette. No
    // exterior glow, bounding-box border, repeated pulse or content snapshot.
    let progress = age/duration
    let eased = progress*progress*(3-2*progress)
    let center = reduceMotion ? 0.5 : -1+3*eased
    context.opacity = reduceMotion ? 0.7 : min(1,age/0.12,(duration-age)/0.24)
    context.scaleBy(x:size.width,y:size.height)
    context.fill(Path(CGRect(x:0,y:0,width:1,height:1)),with:.linearGradient(Gradient(stops:[
      .init(color:.clear,location:0),
      .init(color:Color(red:0.42,green:0.77,blue:0.85).opacity(0.45),location:0.22),
      .init(color:Color(red:0.70,green:0.60,blue:0.88).opacity(0.48),location:0.40),
      .init(color:Color(red:0.96,green:0.98,blue:1).opacity(0.50),location:0.53),
      .init(color:Color(red:0.96,green:0.74,blue:0.73).opacity(0.45),location:0.64),
      .init(color:Color(red:0.66,green:0.79,blue:0.94).opacity(0.34),location:0.79),
      .init(color:.clear,location:1)
    ]),startPoint:.init(x:center-0.9,y:-0.15),endPoint:.init(x:center+0.9,y:1.15)))
  }
}
