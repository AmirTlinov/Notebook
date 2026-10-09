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
/// Its physical geometry is owned by the accepted typesetter output.
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
  private let allocation: DocumentPrintedAllocation
  private var releaseObservers: [ObjectIdentifier: @MainActor () -> Void] = [:]

  init(prepared: DocumentPreparedLayout, buildID: String?, allocation: DocumentPrintedAllocation) {
    pageCount = prepared.pages.count; regions = prepared.regions
    self.buildID = buildID; pages = prepared.pages; readingFileOrder = prepared.readingFileOrder
    anchorPages = prepared.anchors; reading = prepared.reading; pageRanges = prepared.pageRanges
    self.allocation = allocation
  }

  init(rebinding original: DocumentLayoutRecord, buildID: String) {
    pageCount = original.pageCount; regions = original.regions
    self.buildID = buildID; pages = original.pages; readingFileOrder = original.readingFileOrder
    anchorPages = original.anchorPages; reading = original.reading; pageRanges = original.pageRanges
    allocation = original.allocation
    programSizes = original.programSizes
  }

  func matches(_ other: DocumentLayoutRecord) -> Bool {
    let tolerance = 1.0 / 32
    guard anchorPages == other.anchorPages && reading.matches(other.reading, tolerance: tolerance),
      pages == other.pages, regions.count == other.regions.count else { return false }
    // Projection round trips may differ by a fraction of a surface point.
    // Comparison never changes the accepted physical geometry.
    return zip(regions, other.regions).allSatisfy { left, right in
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
