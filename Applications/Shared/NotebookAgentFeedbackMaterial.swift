import NotebookCore
import SwiftUI

/// Borrowed geometry/pixels from the installed source; never a second object.
struct NotebookAgentFeedbackSurface {
  let rect: CGRect
  var scale: Double = 1
  var graphic: NotebookGraphic?
  var layout: NotebookGraphicLayout?
  var text: SpatialElement?
  var ink: Path?
  var raster: RasterLease?
  var paper: DocumentPaperRaster?
  var paperOrigin: CGPoint = .zero
  var isSurface = false
  var erasures: [InkElementErasure] = []
  var clipRect: CGRect?
  var occludedRects: [CGRect] = []
  var occluders: [NotebookAgentFeedbackSurface] = []
}

struct NotebookAgentFeedbackMaterial: View {
  let surface: NotebookAgentFeedbackSurface
  let episode: NotebookAgentFeedback.Episode
  let date: Date
  let reduceMotion: Bool

  private var strength: Double {
    if episode.isAttention { return 0.34 }
    guard date >= episode.startedAt, date < episode.endsAt else { return 0 }
    if reduceMotion { return 0.5 }
    return min(1, date.timeIntervalSince(episode.startedAt) / 0.18, episode.endsAt.timeIntervalSince(date) / 0.55)
  }
  private var phase: Double {
    reduceMotion || episode.isAttention ? 0.48 : date.timeIntervalSince(episode.startedAt).truncatingRemainder(dividingBy: 2.4) / 2.4
  }
  var body: some View {
    let t = Float(phase * .pi * 2)
    ZStack {
      MeshGradient(width: 3, height: 3, points: [
        [0,0],[0.5,0],[1,0], [0,0.5],[0.5 + 0.22 * sin(t),0.5 + 0.18 * cos(t)],[1,0.5], [0,1],[0.5,1],[1,1]
      ], colors: [.white, Color(red:0.72,green:0.80,blue:0.94), .white,
        Color(red:0.80,green:0.76,blue:0.94), .white, Color(red:0.58,green:0.79,blue:0.91),
        .white, Color(red:0.89,green:0.82,blue:0.94), .white])
        .opacity(strength * 0.64).mask { mask(.fillMask) }
        .blendMode(surface.isSurface ? .multiply : .normal)
      inkGradient
        .opacity(strength).mask { mask(.inkMask) }
    }
    .frame(width:surface.rect.width, height:surface.rect.height)
    .position(x:surface.rect.midX,y:surface.rect.midY)
    .allowsHitTesting(false).accessibilityHidden(true)
  }

  private var inkGradient: LinearGradient {
    if reduceMotion || episode.isAttention {
      return LinearGradient(colors:[.white.opacity(0.65),Color(red:0.73,green:0.85,blue:1)],
        startPoint:.leading,endPoint:.trailing)
    }
    return LinearGradient(stops: [
        .init(color:.clear,location:0), .init(color:Color.black.opacity(0.24),location:0.23),
        .init(color:.white.opacity(0.92),location:0.55), .init(color:Color(red:0.73,green:0.85,blue:1),location:0.67),
        .init(color:.clear,location:1)
      ], startPoint:.init(x: -1 + phase * 3, y:0), endPoint:.init(x: phase * 3, y:0.3))
  }

  private func mask(_ layer: NotebookGraphicView.PaintLayer) -> some View {
    Canvas { context, size in
      var context = context
      if let clip = surface.clipRect { context.clip(to:Path(clip.offsetBy(dx:-surface.rect.minX,dy:-surface.rect.minY))) }
      for rect in surface.occludedRects { context.clip(to:Path(rect.offsetBy(dx:-surface.rect.minX,dy:-surface.rect.minY)),options:.inverse) }
      context.drawLayer { mask in
        Self.paintMask(surface,layer:layer,in:mask)
        if layer == .fillMask, surface.graphic != nil {
          var ink = mask; ink.blendMode = .destinationOut
          Self.paintMask(surface,layer:.inkMask,in:ink)
        }
        for occluder in surface.occluders {
          var cut = mask
          cut.blendMode = .destinationOut
          cut.translateBy(x:occluder.rect.minX-surface.rect.minX,y:occluder.rect.minY-surface.rect.minY)
          Self.paintMask(occluder,layer:.content,in:cut)
        }
      }
    }
  }

  /// The content lane is the alpha of a later real object, not its bounding
  /// box: a hollow outline cannot hide the result inside it.
  private static func paintMask(_ surface: NotebookAgentFeedbackSurface,
    layer: NotebookGraphicView.PaintLayer, in original: GraphicsContext) {
    var context = original
    let localSize = CGSize(width:surface.rect.width/surface.scale,height:surface.rect.height/surface.scale)
    context.scaleBy(x:surface.scale,y:surface.scale)
    if let graphic = surface.graphic {
      NotebookGraphicView.paint(graphic,layout:surface.layout,in:context,size:localSize,erasures:surface.erasures,layer:layer)
    } else {
      NotebookElementErasurePaint.clip(surface.erasures,context:&context,size:localSize)
      if surface.isSurface, layer != .inkMask {
        context.fill(Path(CGRect(origin:.zero,size:localSize)),with:.color(.white))
      } else if layer != .fillMask {
        if let paper = surface.paper {
          // Invert the actual printed pixels before converting luminance to
          // alpha: white paper is transparent, letters/contours are the mask.
          // Borrowing this raster retains its existing resource reservation.
          if layer != .content { context.addFilter(.luminanceToAlpha) }
          let geometry = WorkspaceItemGeometry.document(paper.page.artifact.document.paperSize)
          context.drawLayer { ink in
            if layer != .content { ink.addFilter(.colorInvert()) }
            ink.draw(Image(decorative:paper.image,scale:1),
              in:CGRect(origin:surface.paperOrigin,size:.init(width:geometry.width,height:geometry.height)))
          }
        } else if let text = surface.text {
          context.draw(SpatialTextSnapshot.text(text,mask:layer != .content), in:CGRect(origin:.zero,size:localSize))
        } else if let ink = surface.ink { context.fill(ink,with:.color(.white)) }
        else if let raster = surface.raster, !raster.isReleased, let image = raster.sampledImage(for:surface.rect.size) {
          let crop = raster.source.captureRegion.map { CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height) }
          context.draw(Image(decorative:image,scale:1),in:crop ?? CGRect(origin:.zero,size:localSize))
        }
      }
    }
  }
}
