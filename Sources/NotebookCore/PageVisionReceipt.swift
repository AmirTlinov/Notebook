import Foundation

public struct PageVisionPixelSize: Codable, Equatable, Sendable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    precondition(width > 0 && height > 0)
    self.width = width
    self.height = height
  }

  var isValid: Bool {
    width > 0 && height > 0
  }
}

public struct PageVisionCell: Codable, Equatable, Hashable, Sendable {
  public let column: Int
  public let row: Int

  public init(column: Int, row: Int) {
    precondition(column >= 0 && row >= 0)
    self.column = column
    self.row = row
  }
}

public struct PageVisionCellFrame: Codable, Equatable, Sendable {
  public let column: Int
  public let row: Int
  public let width: Int
  public let height: Int

  public init(column: Int, row: Int, width: Int, height: Int) {
    precondition(column >= 0 && row >= 0 && width > 0 && height > 0)
    self.column = column
    self.row = row
    self.width = width
    self.height = height
  }

  public func contains(_ cell: PageVisionCell) -> Bool {
    guard column >= 0, row >= 0, width > 0, height > 0,
          cell.column >= column, cell.row >= row
    else { return false }
    return cell.column - column < width
      && cell.row - row < height
  }

  func isContained(columns: Int, rows: Int) -> Bool {
    guard column >= 0, row >= 0, width > 0, height > 0,
          column < columns, row < rows
    else { return false }
    return width <= columns - column
      && height <= rows - row
  }
}

public struct PageVisionPixelFrame: Codable, Equatable, Sendable {
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    precondition(x >= 0 && y >= 0 && width > 0 && height > 0)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  func isContained(in size: PageVisionPixelSize) -> Bool {
    guard x >= 0, y >= 0, width > 0, height > 0,
          x < size.width, y < size.height
    else { return false }
    return width <= size.width - x
      && height <= size.height - y
  }
}

public struct PageVisionRegion: Codable, Equatable, Sendable {
  public let id: String
  public let contentCells: PageVisionCellFrame
  public let cropCells: PageVisionCellFrame
  public let contentPoints: PageRect
  public let cropPoints: PageRect
  public let cropPixels: PageVisionPixelFrame
  public let inkPixelCount: Int
  public let faithfulPNG_SHA256: String
  public let inkPNG_SHA256: String

  public init(
    id: String,
    contentCells: PageVisionCellFrame,
    cropCells: PageVisionCellFrame,
    contentPoints: PageRect,
    cropPoints: PageRect,
    cropPixels: PageVisionPixelFrame,
    inkPixelCount: Int,
    faithfulPNG_SHA256: String,
    inkPNG_SHA256: String
  ) {
    precondition(!id.isEmpty && inkPixelCount > 0)
    precondition(Self.isSHA256(faithfulPNG_SHA256))
    precondition(Self.isSHA256(inkPNG_SHA256))
    self.id = id
    self.contentCells = contentCells
    self.cropCells = cropCells
    self.contentPoints = contentPoints
    self.cropPoints = cropPoints
    self.cropPixels = cropPixels
    self.inkPixelCount = inkPixelCount
    self.faithfulPNG_SHA256 = faithfulPNG_SHA256
    self.inkPNG_SHA256 = inkPNG_SHA256
  }

  fileprivate static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  fileprivate static func isRegionID(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 4,
          let first = parts.first,
          first.first == "r",
          first.dropFirst().count >= 2,
          first.dropFirst().allSatisfy(\.isNumber)
    else { return false }
    return parts.dropFirst().allSatisfy {
      $0.count >= 2 && $0.allSatisfy(\.isNumber)
    }
  }
}

/// Exact page raster and its visible-ink index, published as one settled revision.
public struct PageVisionReceipt: Codable, Equatable, Sendable {
  public static let formatVersion = 1
  public static let maximumRegionCellSpan = 12
  private static let maximumRenderScale = 16.0

  public let format: Int
  public let pageID: UUID
  public let drawingStamp: VersionStamp
  public let pageSize: PageSize
  public let renderScale: Double
  public let gridSpacing: Double
  public let gridColumns: Int
  public let gridRows: Int
  public let pixelSize: PageVisionPixelSize
  public let visibleInkBounds: PageRect?
  public let occupiedCells: [PageVisionCell]
  public let regions: [PageVisionRegion]
  public let previewPNG_SHA256: String
  public let inkPNG_SHA256: String

  public init(
    page: PageDocument,
    renderScale: Double,
    gridSpacing: Double,
    pixelSize: PageVisionPixelSize,
    visibleInkBounds: PageRect?,
    occupiedCells: [PageVisionCell],
    regions: [PageVisionRegion],
    previewPNG_SHA256: String,
    inkPNG_SHA256: String
  ) {
    precondition(renderScale.isFinite && renderScale > 0)
    precondition(gridSpacing.isFinite && gridSpacing > 0)
    format = Self.formatVersion
    pageID = page.id
    drawingStamp = page.drawingStamp
    pageSize = page.size
    self.renderScale = renderScale
    self.gridSpacing = gridSpacing
    gridColumns = Int(ceil(page.size.width / gridSpacing))
    gridRows = Int(ceil(page.size.height / gridSpacing))
    self.pixelSize = pixelSize
    self.visibleInkBounds = visibleInkBounds
    self.occupiedCells = occupiedCells
    self.regions = regions
    self.previewPNG_SHA256 = previewPNG_SHA256
    self.inkPNG_SHA256 = inkPNG_SHA256
    precondition(isValid)
  }

  public var revision: String {
    "\(drawingStamp.counter)@\(drawingStamp.actor.uuidString.lowercased())"
  }

  public var isValid: Bool {
    guard format == Self.formatVersion,
          pageSize.isValid,
          drawingStamp.counter <= VersionStamp.maximumCounter,
          renderScale.isFinite, renderScale > 0,
          renderScale <= Self.maximumRenderScale,
          gridSpacing == PhysicalPaper.gridSpacing,
          gridColumns == Int(ceil(pageSize.width / gridSpacing)),
          gridRows == Int(ceil(pageSize.height / gridSpacing)),
          pixelSize.isValid,
          pixelSize.width == max(1, Int((pageSize.width * renderScale).rounded())),
          pixelSize.height == max(1, Int((pageSize.height * renderScale).rounded())),
          PageVisionRegion.isSHA256(previewPNG_SHA256),
          PageVisionRegion.isSHA256(inkPNG_SHA256)
    else { return false }

    let orderedCells = occupiedCells.sorted {
      ($0.row, $0.column) < ($1.row, $1.column)
    }
    guard occupiedCells == orderedCells,
          Set(occupiedCells).count == occupiedCells.count,
          occupiedCells.allSatisfy({
            $0.column >= 0 && $0.row >= 0
              && $0.column < gridColumns && $0.row < gridRows
          }),
          (visibleInkBounds == nil) == occupiedCells.isEmpty,
          visibleInkBounds?.isContained(in: pageSize) ?? true
    else { return false }

    let ids = regions.map(\.id)
    guard regions.isEmpty == occupiedCells.isEmpty,
          Set(ids).count == ids.count,
          regions.allSatisfy({ region in
            PageVisionRegion.isRegionID(region.id)
              && region.id == Self.regionID(for: region.contentCells)
              && region.inkPixelCount > 0
              && region.contentCells.isContained(columns: gridColumns, rows: gridRows)
              && region.contentCells.width <= Self.maximumRegionCellSpan
              && region.contentCells.height <= Self.maximumRegionCellSpan
              && region.cropCells.isContained(columns: gridColumns, rows: gridRows)
              && region.contentPoints == pointFrame(for: region.contentCells)
              && region.cropPoints == pointFrame(for: region.cropCells)
              && region.cropPixels.isContained(in: pixelSize)
              && region.cropPixels == pixelFrame(for: region.cropCells)
              && region.inkPixelCount
              <= region.cropPixels.width * region.cropPixels.height
              && region.cropCells.contains(PageVisionCell(
                column: region.contentCells.column,
                row: region.contentCells.row
              ))
              && region.cropCells.contains(PageVisionCell(
                column: region.contentCells.column + region.contentCells.width - 1,
                row: region.contentCells.row + region.contentCells.height - 1
              ))
              && PageVisionRegion.isSHA256(region.faithfulPNG_SHA256)
              && PageVisionRegion.isSHA256(region.inkPNG_SHA256)
              && occupiedCells.contains(where: region.contentCells.contains)
          })
    else { return false }

    return occupiedCells.allSatisfy { cell in
      regions.contains { $0.contentCells.contains(cell) }
    }
  }

  private static func regionID(for cells: PageVisionCellFrame) -> String {
    String(
      format: "r%02d-%02d-%02d-%02d",
      cells.column,
      cells.row,
      cells.width,
      cells.height
    )
  }

  private func pointFrame(for cells: PageVisionCellFrame) -> PageRect {
    let x = Double(cells.column) * gridSpacing
    let y = Double(cells.row) * gridSpacing
    let maximumX = min(
      pageSize.width,
      Double(cells.column + cells.width) * gridSpacing
    )
    let maximumY = min(
      pageSize.height,
      Double(cells.row + cells.height) * gridSpacing
    )
    return PageRect(x: x, y: y, width: maximumX - x, height: maximumY - y)
  }

  private func pixelFrame(for cells: PageVisionCellFrame) -> PageVisionPixelFrame {
    let x = Int(floor(Double(cells.column) * gridSpacing * renderScale))
    let y = Int(floor(Double(cells.row) * gridSpacing * renderScale))
    let maximumX = min(
      pixelSize.width,
      Int(ceil(Double(cells.column + cells.width) * gridSpacing * renderScale))
    )
    let maximumY = min(
      pixelSize.height,
      Int(ceil(Double(cells.row + cells.height) * gridSpacing * renderScale))
    )
    return PageVisionPixelFrame(
      x: x,
      y: y,
      width: maximumX - x,
      height: maximumY - y
    )
  }
}
