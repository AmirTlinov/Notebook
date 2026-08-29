import AppKit
import PencilKit
import TetradCore

enum PagePreviewWriter {
  @MainActor
  static func write(_ page: PageDocument, to url: URL) throws {
    let scale = 2.0
    let pixelWidth = max(1, Int((page.size.width * scale).rounded()))
    let pixelHeight = max(1, Int((page.size.height * scale).rounded()))
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelWidth,
      pixelsHigh: pixelHeight,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bitmapFormat: [],
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return }
    bitmap.size = NSSize(width: page.size.width, height: page.size.height)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let bounds = NSRect(
      x: 0,
      y: 0,
      width: page.size.width,
      height: page.size.height
    )
    NSColor(
      calibratedRed: 0.992,
      green: 0.988,
      blue: 0.969,
      alpha: 1
    ).setFill()
    bounds.fill()

    let grid = NSBezierPath()
    grid.lineWidth = 0.5
    var x = 0.0
    while x <= page.size.width {
      grid.move(to: NSPoint(x: x, y: 0))
      grid.line(to: NSPoint(x: x, y: page.size.height))
      x += PhysicalPaper.gridSpacing
    }
    var y = 0.0
    while y <= page.size.height {
      grid.move(to: NSPoint(x: 0, y: y))
      grid.line(to: NSPoint(x: page.size.width, y: y))
      y += PhysicalPaper.gridSpacing
    }
    NSColor(
      calibratedRed: 0.31,
      green: 0.49,
      blue: 0.67,
      alpha: 0.105
    ).setStroke()
    grid.stroke()

    if !page.drawingData.isEmpty,
       let drawing = try? PKDrawing(data: page.drawingData) {
      PaperInkRenderer.image(
        from: drawing,
        bounds: bounds,
        scale: scale
      ).draw(in: bounds)
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      return
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try png.write(to: url, options: [.atomic])
    let revision = "\(page.drawingStamp.counter)@" +
      page.drawingStamp.actor.uuidString.lowercased() + "\n"
    let revisionURL = url.deletingPathExtension().appendingPathExtension("revision")
    try Data(revision.utf8).write(to: revisionURL, options: [.atomic])
  }
}
