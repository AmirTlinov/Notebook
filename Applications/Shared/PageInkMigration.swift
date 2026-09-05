import CoreGraphics
import Foundation
import NotebookCore
import PencilKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// One-time import uses the final PencilKit pixels, including every erasure.
/// New actions belong exclusively to PageInkDrawing and the common Metal engine.
enum PageInkMigration {
  @MainActor
  static func importDrawing(_ data: Data, size: PageSize) throws -> PageInkDrawing {
    guard PageInkDrawing.needsMigration(data) else { return try PageInkDrawing.decode(data) }
    let drawing = try PKDrawing(data: data)
    guard !drawing.strokes.isEmpty else { return PageInkDrawing() }
    let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
    var png: Data?
    #if os(macOS)
      var rendered: NSImage?
      let draw = { rendered = drawing.image(from: bounds, scale: 2) }
      if let appearance = NSAppearance(named: .aqua) {
        appearance.performAsCurrentDrawingAppearance(draw)
      } else {
        draw()
      }
      guard let image = rendered else { throw PageInkDrawing.InkError.invalidDrawing }
      png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(
        using: .png, properties: [:])
    #else
      UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
        png = drawing.image(from: bounds, scale: 2).pngData()
      }
    #endif
    guard let png else { throw PageInkDrawing.InkError.invalidDrawing }
    return PageInkDrawing(baselinePNG: png, baselineActionCount: drawing.strokes.count)
  }

  @MainActor
  static func migrate(_ pages: [UUID: PageDocument], store: NotebookStore) throws -> [UUID:
    PageDocument]
  {
    var result = pages
    for page in pages.values where PageInkDrawing.needsMigration(page.drawingData) {
      let drawing = try importDrawing(page.drawingData, size: page.size)
      result[page.id] = try store.migratePageInk(page: page, data: drawing.dataRepresentation())
    }
    return result
  }
}
