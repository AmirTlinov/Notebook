import AppKit
import PencilKit

@MainActor
enum PaperInkRenderer {
  static func image(
    from drawing: PKDrawing,
    bounds: CGRect,
    scale: CGFloat
  ) -> NSImage {
    var rendered: NSImage?
    let draw = {
      rendered = drawing.image(from: bounds, scale: scale)
    }
    if let paperAppearance = NSAppearance(named: .aqua) {
      paperAppearance.performAsCurrentDrawingAppearance(draw)
    } else {
      draw()
    }
    return rendered ?? drawing.image(from: bounds, scale: scale)
  }
}
