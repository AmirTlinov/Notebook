import CoreGraphics
import Foundation
import NotebookCore
import PencilKit
import AppKit

/// Test fixture materializes final PencilKit pixels to exercise the common Metal readback.
enum LegacyPencilFixture {
  @MainActor
  static func importDrawing(_ data: Data, size: PageSize) throws -> PageInkDrawing {
    if let native = try? PageInkDrawing.decode(data) { return native }
    let drawing = try PKDrawing(data: data)
    guard !drawing.strokes.isEmpty else { return PageInkDrawing() }
    let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    var rendered: NSImage?
    let draw = { rendered = drawing.image(from: bounds, scale: 2) }
    if let appearance = NSAppearance(named: .aqua) {
      appearance.performAsCurrentDrawingAppearance(draw)
    } else {
      draw()
    }
    guard let image = rendered else { throw PageInkDrawing.InkError.invalidDrawing }
    let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(
      using: .png, properties: [:])
    guard let png else { throw PageInkDrawing.InkError.invalidDrawing }
    return PageInkDrawing(baselinePNG: png, baselineActionCount: drawing.strokes.count)
  }
}
