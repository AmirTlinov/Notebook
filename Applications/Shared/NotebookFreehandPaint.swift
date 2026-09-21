import NotebookCore
import SwiftUI

/// Explicit snapshots/exports alone read back a disposable image. Live vectors
/// use NotebookInkMaterialView; both paths share the compact geometry renderer.
enum NotebookFreehandPaint {
  static func paint(_ ink: NotebookFreehand, transform: NotebookGraphicTransform?, context: GraphicsContext, size: CGSize, mask: Bool) {
    let frame = CGRect(origin:.zero,size:size)
    var region = frame, scale = context.environment.displayScale
    context.withCGContext { cg in
      region = frame.intersection(cg.boundingBoxOfClipPath)
      scale *= max(hypot(cg.ctm.a,cg.ctm.b),hypot(cg.ctm.c,cg.ctm.d))
    }
    guard !region.isNull, region.width > 0, region.height > 0 else { return }
    // The enclosing clip is normally a finite scene tile. Bound scratch pixels
    // as well when a whole large object is explicitly exported.
    scale = min(max(scale,0.001),8192/max(region.width,region.height),sqrt(4_194_304/(region.width*region.height)))
    guard let image = InkRasterRenderer.shared.freehand(ink,transform:transform,size:size,region:region,scale:scale,mask:mask) else { return }
    context.draw(Image(decorative:image,scale:1),in:region)
  }
}
