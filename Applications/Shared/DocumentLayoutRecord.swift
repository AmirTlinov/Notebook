import CoreFoundation
import Foundation
import NotebookCore

/// Media-box dimensions are produced by TeX. A4 is a placeholder only until
/// the first compilation, never a constraint on source or the accepted PDF.
struct DocumentPaperLayout: Codable, Equatable, Sendable {
  static let pointsToSurface = PhysicalPaper.pointsPerCentimeter * 2.54 / 72
  let widthPoints: Double
  let heightPoints: Double
  let cornerRadiusRatio: Double
  let surfaceWidth: Double
  let surfaceHeight: Double
  init(widthPoints: Double, heightPoints: Double) {
    self.widthPoints = widthPoints; self.heightPoints = heightPoints
    let geometry = WorkspaceItemGeometry.document(widthPoints: widthPoints, heightPoints: heightPoints)
    cornerRadiusRatio = geometry.cornerRadius / geometry.width
    surfaceWidth = geometry.width; surfaceHeight = geometry.height
  }
  static let uncompiled = DocumentPaperLayout(widthPoints: 595.275590551, heightPoints: 841.88976378)
  var geometry: WorkspaceItemGeometry { .document(widthPoints: widthPoints, heightPoints: heightPoints) }
}

enum DocumentLinkDestination: Equatable {
  case page(Int)
  case external(URL)
  case unavailable(String)
}

/// Immutable physical pages and their addressed reading/program indexes.
/// Page receipts validate this source; they cannot replace its geometry.
@MainActor
final class DocumentLayoutRecord {
  let pageCount: Int
  let regions: [DocumentBlockRegion]
  let buildID: String?
  let pages: [DocumentPaperLayout]
  let readingFileOrder: [String]
  var width: Double { pages[0].surfaceWidth }
  var height: Double { pages[0].surfaceHeight }
  func paper(on page: Int) -> DocumentPaperLayout { pages[min(max(0, page), pages.count - 1)] }
  let anchorPages: [String: Int]
  let reading: DocumentReadingIndex
  private let pageRanges: [Int: Range<Int>]
  private lazy var programSizes: [String: CGSize] = {
    var sizes: [String: CGSize] = [:]
    for region in regions where region.kind == .program {
      let previous = sizes[region.id]
      sizes[region.id] = .init(width: previous?.width ?? CGFloat(region.frame.width),
        height: max(previous?.height ?? 0, CGFloat(region.sourceOffset + region.frame.height)))
    }
    return sizes
  }()
  // A raster or an address reader can outlive the source preparation. The
  // shared layout, not a temporary task or registry cache, owns this allocation.
  private var reservation: RasterReservation?
  private var printAllocation: DocumentPrintedAllocation?
  private var releaseObservers: [ObjectIdentifier: @MainActor () -> Void] = [:]

  init(receipt: NSDictionary, sourceKey: String, blockIDs: Set<String>, geometry: WorkspaceItemGeometry,
    reservation: RasterReservation? = nil) throws {
    guard receipt["sourceKey"] as? String == sourceKey,
      let scope = receipt["layoutScope"] as? String, ["source", "page"].contains(scope),
      receipt["layoutCanonical"] as? Bool == true,
      let count = receipt["pageCount"] as? Int, (1...4096).contains(count),
      let width = receipt["width"] as? Double, width.isFinite, width > 0,
      let height = receipt["height"] as? Double, height.isFinite, height > 0,
      let values = receipt["regions"] as? [[String: Any]] else { throw DocumentSessionError.invalidLayout }
    let papers: [DocumentPaperLayout]
    if scope == "source" {
      guard let values = receipt["pages"] as? [[String: Double]], values.count == count
      else { throw DocumentSessionError.invalidLayout }
      papers = try values.map { value in
        guard let w = value["widthPoints"], let h = value["heightPoints"], w.isFinite, h.isFinite,
          w > 0, h > 0, w <= 14_400, h <= 14_400 else { throw DocumentSessionError.invalidLayout }
        return .init(widthPoints: w, heightPoints: h)
      }
    } else {
      // Carry the exact PDF points separately from their screen projection.
      // Multiplying and dividing the projection is not an identity for Double.
      guard let w = receipt["widthPoints"] as? Double, let h = receipt["heightPoints"] as? Double,
        w.isFinite, h.isFinite, w > 0, h > 0, w <= 14_400, h <= 14_400
      else { throw DocumentSessionError.invalidLayout }
      let paper = DocumentPaperLayout(widthPoints: w, heightPoints: h)
      guard width == paper.surfaceWidth, height == paper.surfaceHeight else { throw DocumentSessionError.inconsistentLayout }
      papers = Array(repeating: paper, count: count)
    }
    var regions: [DocumentBlockRegion] = []
    var pageRanges: [Int: Range<Int>] = [:]
    regions.reserveCapacity(values.count)
    for value in values {
      guard let id = value["id"] as? String, blockIDs.contains(id),
        let page = value["pageIndex"] as? Int, (0..<count).contains(page),
        let x = value["x"] as? Double, x.isFinite, x >= 0,
        let y = value["y"] as? Double, y.isFinite, y >= 0,
        let w = value["width"] as? Double, w.isFinite, w > 0,
        let h = value["height"] as? Double, h.isFinite, h > 0,
        let origin = value["sourceOffset"] as? NSNumber, CFGetTypeID(origin) != CFBooleanGetTypeID(),
        let sourceOffset = value["sourceOffset"] as? Double, sourceOffset.isFinite, sourceOffset >= 0,
        (sourceOffset + h).isFinite,
        x + w <= papers[page].surfaceWidth + 0.03125, y + h <= papers[page].surfaceHeight + 0.03125 else { throw DocumentSessionError.invalidLayout }
      let physicalOffset = sourceOffset
      guard physicalOffset.isFinite, regions.last.map({ $0.pageIndex <= page }) ?? true else { throw DocumentSessionError.invalidLayout }
      pageRanges[page] = (pageRanges[page]?.lowerBound ?? regions.count)..<(regions.count + 1)
      regions.append(.init(kind: (value["kind"] as? String).flatMap(DocumentRegionKind.init(rawValue:)) ?? .file, id: id, pageIndex: page, frame: .init(x: x, y: y, width: w, height: h),
        sourceOffset: physicalOffset))
    }
    // Page receipts describe pixels, never a replacement for the complete
    // source's link index. The source packet and its existing lease own both.
    var anchors: [String: Int] = [:]
    if scope != "page" {
      guard let values = receipt["anchors"] as? [[String: Any]], values.count <= 16_384
      else { throw DocumentSessionError.invalidLayout }
      var bytes = 0
      for value in values {
        guard let name = value["name"] as? String, !name.isEmpty, name.utf8.count <= 4096,
          let number = value["pageIndex"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let page = value["pageIndex"] as? Int, (0..<count).contains(page), anchors[name] == nil
        else { throw DocumentSessionError.invalidLayout }
        bytes += name.utf8.count
        guard bytes <= 1024 * 1024 else { throw DocumentSessionError.invalidLayout }
        anchors[name] = page
      }
    }
    let readingRows: [[Any]]
    if scope != "page" {
      guard let rows = receipt["reading"] as? [[Any]] else { throw DocumentSessionError.invalidLayout }
      readingRows = rows
    } else { readingRows = [] }
    self.reading = try .init(rows: readingRows, fileIDs: blockIDs, pageCount: count, scale: 1)
    self.anchorPages = anchors
    self.pageCount = count; self.regions = regions; self.pageRanges = pageRanges
    self.buildID = receipt["buildID"] as? String
    self.pages = papers
    var seen: Set<String> = []
    self.readingFileOrder = regions.filter { $0.kind == .file }.sorted {
      ($0.pageIndex, $0.frame.y, $0.frame.x) < ($1.pageIndex, $1.frame.y, $1.frame.x)
    }.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    self.reservation = reservation
  }

  init(prepared: DocumentPreparedLayout, buildID: String, source: DocumentPrintedSource) {
    pageCount = prepared.pages.count; regions = prepared.regions
    self.buildID = buildID; pages = prepared.pages; readingFileOrder = prepared.readingFileOrder
    anchorPages = prepared.anchors; reading = prepared.reading; pageRanges = prepared.pageRanges
    printAllocation = source.allocation
  }

  init(rebinding original: DocumentLayoutRecord, buildID: String) {
    pageCount = original.pageCount; regions = original.regions
    self.buildID = buildID; pages = original.pages; readingFileOrder = original.readingFileOrder
    anchorPages = original.anchorPages; reading = original.reading; pageRanges = original.pageRanges
    programSizes = original.programSizes
    reservation = original.reservation; printAllocation = original.printAllocation
  }

  func matches(_ other: DocumentLayoutRecord, pageIndex: Int? = nil) -> Bool {
    let expectedRegions = regions[pageIndex.map { pageRanges[$0] ?? 0..<0 } ?? regions.startIndex..<regions.endIndex]
    let tolerance = 1.0 / 32
    guard (pageIndex != nil || (anchorPages == other.anchorPages && reading.matches(other.reading, tolerance: tolerance))),
      (pageIndex != nil || pageCount == other.pageCount),
      (pageIndex.map { paper(on: $0) == other.paper(on: $0) } ?? (pages == other.pages)),
      expectedRegions.count == other.regions.count else { return false }
    // Transform round trips may differ by two WebKit layout subpixels. This
    // tolerance never changes the accepted record or grows with page count.
    return zip(expectedRegions, other.regions).allSatisfy { left, right in
      left.kind == right.kind && left.id == right.id && left.pageIndex == right.pageIndex
        && abs(left.frame.x - right.frame.x) <= tolerance && abs(left.frame.y - right.frame.y) <= tolerance
        && abs(left.frame.width - right.frame.width) <= tolerance && abs(left.frame.height - right.frame.height) <= tolerance
        && abs(left.sourceOffset - right.sourceOffset) <= tolerance
    }
  }

  func range(on page: Int) -> Range<Int> { pageRanges[page] ?? 0..<0 }

  func regions(on page: Int) -> ArraySlice<DocumentBlockRegion> {
    regions[pageRanges[page] ?? 0..<0]
  }

  func blockIDs(on pages: Set<Int>, kind: DocumentRegionKind? = nil) -> Set<String> {
    var result: Set<String> = []
    for page in pages {
      guard let range = pageRanges[page] else { continue }
      for region in regions[range] where kind == nil || region.kind == kind { result.insert(region.id) }
    }
    return result
  }

  func programSize(_ id: String) -> CGSize? { programSizes[id] }

  func programHeights(ids: Set<String>) -> [String: Double] {
    var result: [String: Double] = [:]
    for id in ids {
      if let size = programSizes[id] { result[id] = size.height }
    }
    return result
  }

  func destination(for href: String) -> DocumentLinkDestination {
    guard href.utf8.count <= 8192 else { return .unavailable("Слишком длинный адрес ссылки.") }
    if href.hasPrefix("#") {
      guard let name = String(href.dropFirst()).removingPercentEncoding
      else { return .unavailable("Повреждённый адрес раздела.") }
      if name.isEmpty { return .page(0) }
      if let page = anchorPages[name] { return .page(page) }
      if name.lowercased() == "top" { return .page(0) }
      return .unavailable("В документе нет раздела «\(name)».")
    }
    guard let url = URL(string: href), let scheme = url.scheme?.lowercased(),
      ((scheme == "https" || scheme == "http") && url.host?.isEmpty == false)
        || (scheme == "mailto" && !url.path.isEmpty)
    else { return .unavailable("Этот адрес нельзя открыть как раздел документа или внешнюю ссылку.") }
    return .external(url)
  }

  func whenReleased(by owner: AnyObject, _ action: @escaping @MainActor () -> Void) {
    releaseObservers[ObjectIdentifier(owner)] = action
  }

  isolated deinit { for action in releaseObservers.values { action() } }
}
