import AppKit
import CryptoKit
import NotebookCore
import PencilKit

struct PageVisionRenderedRegion {
  let receipt: PageVisionRegion
  let faithfulPNG: Data
  let inkPNG: Data
}

struct PageVisionRender {
  let pixelSize: PageVisionPixelSize
  let faithfulPNG: Data
  let inkPNG: Data
  let visibleInkBounds: PageRect?
  let occupiedCells: [PageVisionCell]
  let regions: [PageVisionRenderedRegion]
}

enum PageVisionRenderer {
  static let scale = 2.0
  private static let regionPaddingCells = 1
  private static let maximumDetailCells = PageVisionReceipt.maximumRegionCellSpan
  private static let detailOverlapCells = 2
  private static let visibleAlphaThreshold: UInt8 = 1

  @MainActor
  static func render(_ page: PageDocument) throws -> PageVisionRender {
    let pixelSize = PageVisionPixelSize(
      width: max(1, Int((page.size.width * scale).rounded())),
      height: max(1, Int((page.size.height * scale).rounded()))
    )
    let bounds = NSRect(
      x: 0,
      y: 0,
      width: page.size.width,
      height: page.size.height
    )
    let drawingImage = try drawingImage(page, bounds: bounds)
    let faithfulBitmap = try bitmap(size: page.size, pixels: pixelSize) {
      drawPaper(in: bounds)
      drawingImage?.draw(in: bounds)
    }
    let inkBitmap = try bitmap(size: page.size, pixels: pixelSize) {
      NSColor.white.setFill()
      bounds.fill()
      drawingImage?.draw(in: bounds)
    }
    let alphaBitmap = try bitmap(size: page.size, pixels: pixelSize) {
      NSColor.clear.setFill()
      bounds.fill(using: .copy)
      drawingImage?.draw(in: bounds)
    }
    let faithfulPNG = try png(faithfulBitmap)
    let inkPNG = try png(inkBitmap)
    let coverage = try visibleInkCoverage(
      in: alphaBitmap,
      page: page,
      pixelSize: pixelSize
    )
    let geometries = regionGeometries(
      coverage: coverage,
      page: page,
      pixelSize: pixelSize
    )
    let regions = try geometries.map { geometry in
      let faithfulCrop = try crop(faithfulBitmap, to: geometry.cropPixels)
      let inkCrop = try crop(inkBitmap, to: geometry.cropPixels)
      return PageVisionRenderedRegion(
        receipt: PageVisionRegion(
          id: geometry.id,
          contentCells: geometry.contentCells,
          cropCells: geometry.cropCells,
          contentPoints: points(for: geometry.contentCells, page: page),
          cropPoints: points(for: geometry.cropCells, page: page),
          cropPixels: geometry.cropPixels,
          inkPixelCount: geometry.inkPixelCount,
          faithfulPNG_SHA256: sha256(faithfulCrop),
          inkPNG_SHA256: sha256(inkCrop)
        ),
        faithfulPNG: faithfulCrop,
        inkPNG: inkCrop
      )
    }
    return PageVisionRender(
      pixelSize: pixelSize,
      faithfulPNG: faithfulPNG,
      inkPNG: inkPNG,
      visibleInkBounds: coverage.pixelBounds.map {
        let x = min(page.size.width, Double($0.x) / scale)
        let y = min(page.size.height, Double($0.y) / scale)
        let maximumX = min(
          page.size.width,
          Double($0.x + $0.width) / scale
        )
        let maximumY = min(
          page.size.height,
          Double($0.y + $0.height) / scale
        )
        return PageRect(
          x: x,
          y: y,
          width: maximumX - x,
          height: maximumY - y
        )
      },
      occupiedCells: coverage.pixelCountByCell.keys.sorted {
        ($0.row, $0.column) < ($1.row, $1.column)
      },
      regions: regions
    )
  }

  private struct Coverage {
    let pixelBounds: PageVisionPixelFrame?
    let pixelCountByCell: [PageVisionCell: Int]
  }

  private struct RegionGeometry {
    let id: String
    let contentCells: PageVisionCellFrame
    let cropCells: PageVisionCellFrame
    let cropPixels: PageVisionPixelFrame
    let inkPixelCount: Int
  }

  @MainActor
  private static func drawingImage(
    _ page: PageDocument,
    bounds: NSRect
  ) throws -> NSImage? {
    guard !page.drawingData.isEmpty else { return nil }
    let drawing = try PKDrawing(data: page.drawingData)
    return PaperInkRenderer.image(from: drawing, bounds: bounds, scale: scale)
  }

  @MainActor
  private static func bitmap(
    size: PageSize,
    pixels: PageVisionPixelSize,
    draw: () -> Void
  ) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixels.width,
      pixelsHigh: pixels.height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bitmapFormat: [],
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { throw RenderError.bitmapAllocation }
    bitmap.size = NSSize(width: size.width, height: size.height)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      throw RenderError.graphicsContext
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    draw()
    context.flushGraphics()
    return bitmap
  }

  @MainActor
  private static func drawPaper(in bounds: NSRect) {
    NSColor(
      calibratedRed: PaperAppearance.background.red,
      green: PaperAppearance.background.green,
      blue: PaperAppearance.background.blue,
      alpha: 1
    ).setFill()
    bounds.fill()

    let grid = NSBezierPath()
    grid.lineWidth = 0.5
    var x = 0.0
    while x <= bounds.width {
      grid.move(to: NSPoint(x: x, y: 0))
      grid.line(to: NSPoint(x: x, y: bounds.height))
      x += PhysicalPaper.gridSpacing
    }
    var y = 0.0
    while y <= bounds.height {
      grid.move(to: NSPoint(x: 0, y: y))
      grid.line(to: NSPoint(x: bounds.width, y: y))
      y += PhysicalPaper.gridSpacing
    }
    NSColor(
      calibratedRed: PaperAppearance.grid.red,
      green: PaperAppearance.grid.green,
      blue: PaperAppearance.grid.blue,
      alpha: PaperAppearance.gridOpacity
    ).setStroke()
    grid.stroke()
  }

  private static func visibleInkCoverage(
    in bitmap: NSBitmapImageRep,
    page: PageDocument,
    pixelSize: PageVisionPixelSize
  ) throws -> Coverage {
    guard let bytes = bitmap.bitmapData,
          bitmap.bitsPerSample == 8,
          bitmap.samplesPerPixel == 4,
          !bitmap.isPlanar
    else { throw RenderError.pixelLayout }
    let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    let pixelsPerCell = PhysicalPaper.gridSpacing * scale
    let columns = Int(ceil(page.size.width / PhysicalPaper.gridSpacing))
    let rows = Int(ceil(page.size.height / PhysicalPaper.gridSpacing))
    var cellCounts = [Int](repeating: 0, count: columns * rows)
    var minX = pixelSize.width
    var minY = pixelSize.height
    var maxX = -1
    var maxY = -1

    for y in 0 ..< pixelSize.height {
      let rowStart = y * bitmap.bytesPerRow
      for x in 0 ..< pixelSize.width {
        let alpha = bytes[rowStart + x * bitmap.samplesPerPixel + alphaOffset]
        guard alpha > visibleAlphaThreshold else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
        let column = min(columns - 1, Int(Double(x) / pixelsPerCell))
        let row = min(rows - 1, Int(Double(y) / pixelsPerCell))
        cellCounts[row * columns + column] += 1
      }
    }
    let bounds = maxX >= minX && maxY >= minY
      ? PageVisionPixelFrame(
        x: minX,
        y: minY,
        width: maxX - minX + 1,
        height: maxY - minY + 1
      )
      : nil
    var counts: [PageVisionCell: Int] = [:]
    for row in 0 ..< rows {
      for column in 0 ..< columns {
        let count = cellCounts[row * columns + column]
        if count > 0 {
          counts[PageVisionCell(column: column, row: row)] = count
        }
      }
    }
    return Coverage(pixelBounds: bounds, pixelCountByCell: counts)
  }

  private static func regionGeometries(
    coverage: Coverage,
    page: PageDocument,
    pixelSize: PageVisionPixelSize
  ) -> [RegionGeometry] {
    let columns = Int(ceil(page.size.width / PhysicalPaper.gridSpacing))
    let rows = Int(ceil(page.size.height / PhysicalPaper.gridSpacing))
    var remaining = Set(coverage.pixelCountByCell.keys)
    var components: [[PageVisionCell]] = []

    while let first = remaining.min(by: {
      ($0.row, $0.column) < ($1.row, $1.column)
    }) {
      var component: [PageVisionCell] = []
      var queue = [first]
      remaining.remove(first)
      var index = 0
      while index < queue.count {
        let cell = queue[index]
        index += 1
        component.append(cell)
        for row in max(0, cell.row - 1) ... min(rows - 1, cell.row + 1) {
          for column in max(0, cell.column - 1) ... min(columns - 1, cell.column + 1) {
            let neighbor = PageVisionCell(column: column, row: row)
            if remaining.remove(neighbor) != nil {
              queue.append(neighbor)
            }
          }
        }
      }
      components.append(component)
    }

    return components.flatMap { detailGroups(in: $0) }.map { content, cells in
      let cropColumn = max(0, content.column - regionPaddingCells)
      let cropRow = max(0, content.row - regionPaddingCells)
      let cropMaxColumn = min(
        columns - 1,
        content.column + content.width - 1 + regionPaddingCells
      )
      let cropMaxRow = min(
        rows - 1,
        content.row + content.height - 1 + regionPaddingCells
      )
      let cropCells = PageVisionCellFrame(
        column: cropColumn,
        row: cropRow,
        width: cropMaxColumn - cropColumn + 1,
        height: cropMaxRow - cropRow + 1
      )
      let cropPixels = pixels(
        for: cropCells,
        page: page,
        pixelSize: pixelSize
      )
      return RegionGeometry(
        id: String(
          format: "r%02d-%02d-%02d-%02d",
          content.column,
          content.row,
          content.width,
          content.height
        ),
        contentCells: content,
        cropCells: cropCells,
        cropPixels: cropPixels,
        inkPixelCount: cells.reduce(0) {
          $0 + coverage.pixelCountByCell[$1, default: 0]
        }
      )
    }.sorted {
      ($0.contentCells.row, $0.contentCells.column)
        < ($1.contentCells.row, $1.contentCells.column)
    }
  }

  private static func detailGroups(
    in cells: [PageVisionCell]
  ) -> [(PageVisionCellFrame, [PageVisionCell])] {
    let minColumn = cells.map(\.column).min()!
    let maxColumn = cells.map(\.column).max()!
    let minRow = cells.map(\.row).min()!
    let maxRow = cells.map(\.row).max()!
    let width = maxColumn - minColumn + 1
    let height = maxRow - minRow + 1
    if width <= maximumDetailCells, height <= maximumDetailCells {
      return [(
        PageVisionCellFrame(
          column: minColumn,
          row: minRow,
          width: width,
          height: height
        ),
        cells
      )]
    }

    let stride = maximumDetailCells - detailOverlapCells
    var groups: [(PageVisionCellFrame, [PageVisionCell])] = []
    var row = minRow
    while row <= maxRow {
      var column = minColumn
      while column <= maxColumn {
        let maximumColumn = min(maxColumn, column + maximumDetailCells - 1)
        let maximumRow = min(maxRow, row + maximumDetailCells - 1)
        let visibleCells = cells.filter {
          $0.column >= column && $0.column <= maximumColumn
            && $0.row >= row && $0.row <= maximumRow
        }
        if !visibleCells.isEmpty {
          groups.append((
            PageVisionCellFrame(
              column: column,
              row: row,
              width: maximumColumn - column + 1,
              height: maximumRow - row + 1
            ),
            visibleCells
          ))
        }
        column += stride
      }
      row += stride
    }
    return groups
  }

  private static func points(
    for cells: PageVisionCellFrame,
    page: PageDocument
  ) -> PageRect {
    let x = Double(cells.column) * PhysicalPaper.gridSpacing
    let y = Double(cells.row) * PhysicalPaper.gridSpacing
    let maximumX = min(
      page.size.width,
      Double(cells.column + cells.width) * PhysicalPaper.gridSpacing
    )
    let maximumY = min(
      page.size.height,
      Double(cells.row + cells.height) * PhysicalPaper.gridSpacing
    )
    return PageRect(x: x, y: y, width: maximumX - x, height: maximumY - y)
  }

  private static func pixels(
    for cells: PageVisionCellFrame,
    page _: PageDocument,
    pixelSize: PageVisionPixelSize
  ) -> PageVisionPixelFrame {
    let x = max(0, Int(floor(Double(cells.column) * PhysicalPaper.gridSpacing * scale)))
    let y = max(0, Int(floor(Double(cells.row) * PhysicalPaper.gridSpacing * scale)))
    let maximumX = min(
      pixelSize.width,
      Int(ceil(Double(cells.column + cells.width) * PhysicalPaper.gridSpacing * scale))
    )
    let maximumY = min(
      pixelSize.height,
      Int(ceil(Double(cells.row + cells.height) * PhysicalPaper.gridSpacing * scale))
    )
    return PageVisionPixelFrame(
      x: x,
      y: y,
      width: maximumX - x,
      height: maximumY - y
    )
  }

  private static func crop(
    _ bitmap: NSBitmapImageRep,
    to frame: PageVisionPixelFrame
  ) throws -> Data {
    guard let image = bitmap.cgImage?.cropping(to: CGRect(
      x: frame.x,
      y: frame.y,
      width: frame.width,
      height: frame.height
    )) else { throw RenderError.imageCrop }
    return try png(NSBitmapImageRep(cgImage: image))
  }

  private static func png(_ bitmap: NSBitmapImageRep) throws -> Data {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw RenderError.pngEncoding
    }
    return data
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private enum RenderError: Error {
    case bitmapAllocation
    case graphicsContext
    case imageCrop
    case pixelLayout
    case pngEncoding
  }
}
