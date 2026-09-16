import CoreFoundation
import Foundation
import NotebookCore
import WebKit

/// One mounted document shares immutable bridge inputs. The page coordinators
/// still own their existing WebKit instances; this session never creates one.
@MainActor
final class DocumentRenderSession {
  let documentID: UUID
  private final class WeakSource {
    weak var value: DocumentSourceSnapshot?
    init(_ value: DocumentSourceSnapshot) { self.value = value }
  }
  private final class WeakState {
    weak var value: DocumentStateSnapshot?
    init(_ value: DocumentStateSnapshot) { self.value = value }
  }
  private var sources: [VersionStamp: [WeakSource]] = [:]
  private var states: [WeakState] = []

  init(documentID: UUID) { self.documentID = documentID }

  func source(_ document: DocumentDocument) -> DocumentSourceSnapshot {
    precondition(document.id == documentID)
    if let snapshot = sources[document.contentStamp]?.lazy.compactMap(\.value).first(where: { $0.matches(document) }) { return snapshot }
    sources = sources.compactMapValues { values in
      let live = values.filter { $0.value != nil }; return live.isEmpty ? nil : live
    }
    let snapshot = DocumentSourceSnapshot(document)
    sources[document.contentStamp, default: []].append(WeakSource(snapshot))
    return snapshot
  }

  func state(_ journal: DocumentStateJournal, blockIDs: Set<String>? = nil) -> DocumentStateSnapshot {
    precondition(journal.id == documentID)
    return state(records: journal.records.filter { blockIDs?.contains($0.id) ?? true })
  }

  func state(records: [DocumentStateRecord]) -> DocumentStateSnapshot {
    states = states.filter { $0.value != nil }
    if let snapshot = states.lazy.compactMap(\.value).first(where: { $0.records == records }) { return snapshot }
    let snapshot = DocumentStateSnapshot(documentID: documentID, records: records)
    states.append(WeakState(snapshot))
    return snapshot
  }

  func source(key: String) -> DocumentSourceSnapshot? {
    sources.values.lazy.flatMap { $0 }.compactMap(\.value).first { $0.message.key == key }
  }
}

struct DocumentPaperLayout: Codable, Equatable, Sendable {
  let kind: DocumentPaperSize
  let widthPoints: Double
  let heightPoints: Double
  let marginPoints: Double
  let cornerRadiusRatio: Double
  let surfaceWidth: Double
  let surfaceHeight: Double

  init(_ size: DocumentPaperSize) {
    kind = size
    widthPoints = size.widthPoints; heightPoints = size.heightPoints
    marginPoints = size.marginPoints
    let geometry = WorkspaceItemGeometry.document(size)
    cornerRadiusRatio = geometry.cornerRadius / geometry.width
    surfaceWidth = geometry.width; surfaceHeight = geometry.height
  }
}

struct DocumentSourceMessage: Encodable, Sendable {
  let key: String
  let documentID: UUID
  let paper: DocumentPaperLayout
  let blocks: [DocumentBlock]
  let sourceVersions: [String: ContentFieldVersion]
}

struct DocumentStateMessage: Encodable, Sendable {
  let key: String
  let documentID: UUID
  let states: [String: JSONValue]
}

/// Pages share one immutable source. Its body crosses the browser boundary
/// only in the addressed block batches requested by the canonical flow.
@MainActor
final class DocumentSourceSnapshot {
  let message: DocumentSourceMessage
  private let document: DocumentDocument
  let stamp: VersionStamp
  let programIDs: Set<String>
  private let blockIDs: Set<String>
  private(set) var layout: DocumentLayoutRecord?
  private var preparation: DocumentPagePreparation?
  private var layoutObservers: [UUID: (DocumentLayoutRecord) -> Void] = [:]
  private(set) var preparationCount = 0
  private var receiptLayoutMismatch: String?

  init(_ document: DocumentDocument) {
    self.document = document
    stamp = document.contentStamp
    programIDs = Set(document.blocks.filter { $0.kind == .interactive }.map(\.id))
    blockIDs = Set(document.blocks.map(\.id))
    message = .init(key: UUID().uuidString, documentID: document.id,
      paper: .init(document.paperSize), blocks: document.blocks,
      sourceVersions: Dictionary(uniqueKeysWithValues: document.blocks.map { ($0.id, document.sourceVersion(blockID: $0.id)) }))
  }

  func matches(_ document: DocumentDocument) -> Bool { self.document == document }

  func programIDs(on page: Int) -> Set<String>? {
    guard let layout, (0..<layout.pageCount).contains(page) else { return nil }
    return layout.blockIDs(on: [page]).intersection(programIDs)
  }

  func preparedPage(_ index: Int, hostID: UUID, in web: WKWebView, lease: WebSurfaceLease,
    resources: SceneRenderResources, onAdmissionWait: @escaping (Bool) -> Void = { _ in },
    onLayoutChanged: @escaping (DocumentLayoutRecord) -> Void = { _ in }) async throws -> DocumentPreparedPage {
    layoutObservers[hostID] = onLayoutChanged
    if preparation == nil {
      preparationCount += 1
      preparation = DocumentPagePreparation(message: message, resources: resources)
      preparation?.onLayoutAccepted = { [weak self] record in
        guard let self else { return }
        if let layout, layout !== record { try layout.acceptExtension(record) }
        else { layout = record }
        for observer in Array(layoutObservers.values) { observer(layout!) }
      }
    }
    let prepared: DocumentPreparedPage
    do { prepared = try await preparation!.page(index, hostID: hostID, in: web, lease: lease, onAdmissionWait: onAdmissionWait) }
    catch {
      // Geometry and a page packet have independent readiness. Preserve a
      // successfully checked measurement when this one fragment is refused.
      if preparation?.layout != nil { try acceptPreparedLayout() }
      throw error
    }
    try acceptPreparedLayout()
    return prepared
  }

  private func acceptPreparedLayout() throws {
    guard let measured = preparation?.layout else { throw DocumentSessionError.invalidLayout }
    if let layout, layout !== measured, !layout.matches(measured) {
      receiptLayoutMismatch = "handoff pages=\(layout.pageCount)/\(measured.pageCount); old=\(Array(layout.regions.prefix(3))); new=\(Array(measured.regions.prefix(3)))"
      throw DocumentSessionError.inconsistentLayout
    }
    layout = layout ?? measured
  }

  func retainPage(_ index: Int, hostID: UUID) { preparation?.retainPage(index, hostID: hostID) }
  func releasePage(hostID: UUID, in web: WKWebView?) {
    // An idle executor releases page demand, not its mounted source metadata.
    // A physical WebKit/source retirement ends the observer as well.
    if web != nil { layoutObservers[hostID] = nil }
    preparation?.releasePage(hostID: hostID, in: web)
  }
  func didPresentPage(_ page: Int) { preparation?.didPresentPage(page) }
  func completeLayout(in web: WKWebView, lease: WebSurfaceLease) async throws -> DocumentLayoutRecord {
    guard let preparation else { throw DocumentSessionError.invalidLayout }
    return try await preparation.completeLayout(in: web, lease: lease)
  }
  func discardIdlePreparation() async { await preparation?.discardIdlePreparation() }
  var pendingPreparationReaderCount: Int { preparation?.pendingReaderCount ?? 0 }
  var retainedPageIndices: Set<Int> { preparation?.retainedPageIndices ?? [] }
  var compiledPageCount: Int { preparation?.compiledPageCount ?? 0 }
  var measurementCount: Int { preparation?.measurementCount ?? 0 }
  var preparedSourceBlockCount: Int { preparation?.preparedSourceBlockCount ?? 0 }
  var preparationPhasesMS: [String: Double] { preparation?.preparationPhasesMS ?? [:] }
  var lastPreparationLayoutMismatch: String? { receiptLayoutMismatch ?? preparation?.lastLayoutMismatch }

  func retryPagePreparation(_ pageIndex: Int) {
    if preparation?.failed == true { preparation = nil }
    else { preparation?.retryPage(pageIndex) }
  }

  func acceptLayout(_ receipt: NSDictionary, geometry: WorkspaceItemGeometry) throws -> DocumentLayoutRecord {
    guard let scope = receipt["layoutScope"] as? String, scope == "source" || scope == "page",
      scope != "page" || layout != nil else { throw DocumentSessionError.invalidLayout }
    let measured = try DocumentLayoutRecord(receipt: receipt, sourceKey: message.key, blockIDs: blockIDs, geometry: geometry)
    if let layout {
      if receipt["layoutScope"] as? String == "page" {
        guard let index = receipt["pageIndex"] as? Int, (0..<layout.pageCount).contains(index),
          layout.matches(measured, pageIndex: index) else {
          let page = receipt["pageIndex"] as? Int
          receiptLayoutMismatch = "installed page=\(String(describing: page)); pages=\(layout.pageCount)/\(measured.pageCount); old=\(Array(layout.regions.filter { $0.pageIndex == page }.prefix(3))); new=\(Array(measured.regions.prefix(3)))"
          throw DocumentSessionError.inconsistentLayout
        }
      } else if !layout.matches(measured) {
        receiptLayoutMismatch = "source receipt pages=\(layout.pageCount)/\(measured.pageCount); old=\(Array(layout.regions.prefix(3))); new=\(Array(measured.regions.prefix(3)))"
        throw DocumentSessionError.inconsistentLayout
      }
      return layout
    }
    layout = measured
    return measured
  }

}

@MainActor
final class DocumentStateSnapshot {
  let message: DocumentStateMessage
  let records: [DocumentStateRecord]
  private var encoding: Task<String, Error>?
  private(set) var encodingCount = 0

  init(documentID: UUID, records: [DocumentStateRecord]) {
    self.records = records
    message = .init(key: UUID().uuidString, documentID: documentID,
      states: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.value) }))
  }

  func encodedJSON() async throws -> String {
    if encoding == nil {
      encodingCount += 1
      let message = message
      encoding = Task.detached(priority: .userInitiated) { try canonicalDocumentJSON(message) }
    }
    return try await encoding!.value
  }

  isolated deinit { encoding?.cancel() }
}

func canonicalDocumentJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

enum DocumentSessionError: Error, LocalizedError {
  case invalidLayout
  case inconsistentLayout
  var errorDescription: String? {
    switch self {
    case .invalidLayout: "document_layout_invalid"
    case .inconsistentLayout: "document_layout_inconsistent"
    }
  }
}

enum DocumentLinkDestination: Equatable {
  case page(Int)
  case external(URL)
  case unavailable(String)
}

/// Accepted physical pages never change. The sole source preparation can
/// extend its measured prefix; a page receipt cannot replace or extend it.
@MainActor
final class DocumentLayoutRecord {
  private(set) var pageCount: Int
  private(set) var isComplete: Bool
  private(set) var regions: [DocumentBlockRegion]
  let width: Double
  let height: Double
  private(set) var anchorPages: [String: Int]
  private(set) var reading: DocumentReadingIndex
  private var pageRanges: [Int: Range<Int>]
  // A raster or an address reader can outlive the source preparation. The
  // shared layout, not a temporary task or registry cache, owns this allocation.
  private var reservation: RasterReservation?
  private var releaseObservers: [ObjectIdentifier: @MainActor () -> Void] = [:]

  init(receipt: NSDictionary, sourceKey: String, blockIDs: Set<String>, geometry: WorkspaceItemGeometry,
    reservation: RasterReservation? = nil) throws {
    guard receipt["sourceKey"] as? String == sourceKey,
      let scope = receipt["layoutScope"] as? String, ["source", "source-prefix", "page"].contains(scope),
      receipt["layoutCanonical"] as? Bool == true,
      let count = receipt["pageCount"] as? Int, (1...4096).contains(count),
      let width = receipt["width"] as? Double, width.isFinite, width > 0,
      let height = receipt["height"] as? Double, height.isFinite, height > 0,
      let values = receipt["regions"] as? [[String: Any]] else { throw DocumentSessionError.invalidLayout }
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
        x + w <= width + 0.03125, y + h <= height + 0.03125 else { throw DocumentSessionError.invalidLayout }
      let physicalOffset = sourceOffset * (geometry.height / height)
      guard physicalOffset.isFinite, regions.last.map({ $0.pageIndex <= page }) ?? true else { throw DocumentSessionError.invalidLayout }
      pageRanges[page] = (pageRanges[page]?.lowerBound ?? regions.count)..<(regions.count + 1)
      regions.append(.init(id: id, pageIndex: page, frame: .init(x: x * geometry.width / width,
        y: y * geometry.height / height, width: w * geometry.width / width, height: h * geometry.height / height),
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
    self.reading = try .init(rows: readingRows, blockIDs: blockIDs, pageCount: count, scale: geometry.height / height)
    self.anchorPages = anchors
    self.pageCount = count; self.regions = regions; self.pageRanges = pageRanges
    isComplete = scope != "source-prefix"
    self.width = geometry.width; self.height = geometry.height
    self.reservation = reservation
  }

  func matches(_ other: DocumentLayoutRecord, pageIndex: Int? = nil) -> Bool {
    let expectedRegions = regions[pageIndex.map { pageRanges[$0] ?? 0..<0 } ?? regions.startIndex..<regions.endIndex]
    let tolerance = 1.0 / 32
    guard (pageIndex != nil || (anchorPages == other.anchorPages && reading.matches(other.reading, tolerance: tolerance))),
      (pageIndex != nil || (pageCount == other.pageCount && isComplete == other.isComplete)),
      width == other.width, height == other.height,
      expectedRegions.count == other.regions.count else { return false }
    // Transform round trips may differ by two WebKit layout subpixels. This
    // tolerance never changes the accepted record or grows with page count.
    return zip(expectedRegions, other.regions).allSatisfy { left, right in
      left.id == right.id && left.pageIndex == right.pageIndex
        && abs(left.frame.x - right.frame.x) <= tolerance && abs(left.frame.y - right.frame.y) <= tolerance
        && abs(left.frame.width - right.frame.width) <= tolerance && abs(left.frame.height - right.frame.height) <= tolerance
        && abs(left.sourceOffset - right.sourceOffset) <= tolerance
    }
  }

  /// All old physical regions and text addresses must survive byte-for-byte
  /// (apart from the same fixed WebKit subpixel tolerance). New anchors may be
  /// resolved by the complete index, but an accepted author anchor cannot move.
  func acceptExtension(_ other: DocumentLayoutRecord) throws {
    if matches(other) { return }
    guard !isComplete, other.pageCount >= pageCount, width == other.width, height == other.height,
      anchorPages.allSatisfy({ other.anchorPages[$0.key] == $0.value }),
      reading.matchesPrefix(of: other.reading, pageCount: pageCount, tolerance: 1.0 / 32),
      (0..<pageCount).allSatisfy({ page in
        let left = regions(on: page), right = other.regions(on: page)
        return left.count == right.count && zip(left, right).allSatisfy { a, b in
          a.id == b.id && a.pageIndex == b.pageIndex
            && abs(a.frame.x - b.frame.x) <= 1.0 / 32 && abs(a.frame.y - b.frame.y) <= 1.0 / 32
            && abs(a.frame.width - b.frame.width) <= 1.0 / 32 && abs(a.frame.height - b.frame.height) <= 1.0 / 32
            && abs(a.sourceOffset - b.sourceOffset) <= 1.0 / 32
        }
      }) else { throw DocumentSessionError.inconsistentLayout }
    pageCount = other.pageCount; isComplete = other.isComplete; regions = other.regions
    anchorPages = other.anchorPages; reading = other.reading; pageRanges = other.pageRanges
    reservation = other.reservation
  }

  func regions(on page: Int) -> ArraySlice<DocumentBlockRegion> {
    regions[pageRanges[page] ?? 0..<0]
  }

  func blockIDs(on pages: Set<Int>) -> Set<String> {
    var result: Set<String> = []
    for page in pages {
      guard let range = pageRanges[page] else { continue }
      for region in regions[range] { result.insert(region.id) }
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
