import Foundation
@testable import NotebookCore
import Testing

private let visionSHA256 = String(repeating: "a", count: 64)

@Test("Квитанция листа связывает клетки, области и точные изображения")
func pageVisionReceiptBindsVisibleArtifacts() throws {
  let actor = UUID()
  let page = PageDocument(
    size: PageSize(width: 100, height: 100),
    actor: actor
  )
  let cell = PageVisionCell(column: 0, row: 0)
  let cells = PageVisionCellFrame(column: 0, row: 0, width: 1, height: 1)
  let points = PageRect(
    x: 0,
    y: 0,
    width: PhysicalPaper.gridSpacing,
    height: PhysicalPaper.gridSpacing
  )
  let receipt = PageVisionReceipt(
    page: page,
    renderScale: 2,
    gridSpacing: PhysicalPaper.gridSpacing,
    pixelSize: PageVisionPixelSize(width: 200, height: 200),
    visibleInkBounds: PageRect(x: 2, y: 3, width: 8, height: 9),
    occupiedCells: [cell],
    regions: [
      PageVisionRegion(
        id: "r00-00-01-01",
        contentCells: cells,
        cropCells: cells,
        contentPoints: points,
        cropPoints: points,
        cropPixels: PageVisionPixelFrame(x: 0, y: 0, width: 52, height: 52),
        inkPixelCount: 20,
        faithfulPNG_SHA256: visionSHA256,
        inkPNG_SHA256: visionSHA256
      ),
    ],
    previewPNG_SHA256: visionSHA256,
    inkPNG_SHA256: visionSHA256
  )

  #expect(receipt.isValid)
  let decoded = try JSONDecoder().decode(
    PageVisionReceipt.self,
    from: JSONEncoder().encode(receipt)
  )
  #expect(decoded == receipt)
  #expect(decoded.revision == "0@\(actor.uuidString.lowercased())")
  let object = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(receipt)
    ) as? [String: Any]
  )
  #expect(object["previewPNG_SHA256"] as? String == visionSHA256)
  let encodedRegions = try #require(object["regions"] as? [[String: Any]])
  #expect(encodedRegions.first?["inkPNG_SHA256"] as? String == visionSHA256)
}

@Test("Противоречивая геометрия не становится зрительной квитанцией")
func pageVisionReceiptRejectsContradictoryGrid() throws {
  let page = PageDocument(
    size: PageSize(width: 100, height: 100),
    actor: UUID()
  )
  let valid = PageVisionReceipt(
    page: page,
    renderScale: 2,
    gridSpacing: PhysicalPaper.gridSpacing,
    pixelSize: PageVisionPixelSize(width: 200, height: 200),
    visibleInkBounds: nil,
    occupiedCells: [],
    regions: [],
    previewPNG_SHA256: visionSHA256,
    inkPNG_SHA256: visionSHA256
  )
  var object = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(valid)
    ) as? [String: Any]
  )
  object["gridColumns"] = 1
  let corrupted = try JSONDecoder().decode(
    PageVisionReceipt.self,
    from: JSONSerialization.data(withJSONObject: object)
  )

  #expect(!corrupted.isValid)
}

@Test("Координаты области обязаны описывать именно названные клетки")
func pageVisionReceiptRejectsForgedRegionCoordinates() throws {
  let page = PageDocument(
    size: PageSize(width: 100, height: 100),
    actor: UUID()
  )
  let cells = PageVisionCellFrame(column: 0, row: 0, width: 1, height: 1)
  let valid = PageVisionReceipt(
    page: page,
    renderScale: 2,
    gridSpacing: PhysicalPaper.gridSpacing,
    pixelSize: PageVisionPixelSize(width: 200, height: 200),
    visibleInkBounds: PageRect(x: 1, y: 1, width: 2, height: 2),
    occupiedCells: [PageVisionCell(column: 0, row: 0)],
    regions: [
      PageVisionRegion(
        id: "r00-00-01-01",
        contentCells: cells,
        cropCells: cells,
        contentPoints: PageRect(
          x: 0,
          y: 0,
          width: PhysicalPaper.gridSpacing,
          height: PhysicalPaper.gridSpacing
        ),
        cropPoints: PageRect(
          x: 0,
          y: 0,
          width: PhysicalPaper.gridSpacing,
          height: PhysicalPaper.gridSpacing
        ),
        cropPixels: PageVisionPixelFrame(x: 0, y: 0, width: 52, height: 52),
        inkPixelCount: 4,
        faithfulPNG_SHA256: visionSHA256,
        inkPNG_SHA256: visionSHA256
      ),
    ],
    previewPNG_SHA256: visionSHA256,
    inkPNG_SHA256: visionSHA256
  )
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
      as? [String: Any]
  )
  var regions = try #require(object["regions"] as? [[String: Any]])
  var points = try #require(regions[0]["contentPoints"] as? [String: Any])
  points["x"] = 1
  regions[0]["contentPoints"] = points
  object["regions"] = regions
  let corrupted = try JSONDecoder().decode(
    PageVisionReceipt.self,
    from: JSONSerialization.data(withJSONObject: object)
  )

  #expect(!corrupted.isValid)
}
