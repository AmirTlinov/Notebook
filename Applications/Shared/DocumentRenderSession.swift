import CoreFoundation
import Foundation
import NotebookCore
import NotebookTypesetter
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

  func source(_ document: DocumentDocument, store: NotebookStore? = nil) -> DocumentSourceSnapshot {
    precondition(document.id == documentID)
    if let snapshot = sources[document.contentStamp]?.lazy.compactMap(\.value).first(where: { $0.matches(document) && $0.canRead(using: store) }) { return snapshot }
    sources = sources.compactMapValues { values in
      let live = values.filter { $0.value != nil }; return live.isEmpty ? nil : live
    }
    let reuse = sources.values.lazy.flatMap { $0 }.compactMap { $0.value?.printReuse }.first
    let snapshot = DocumentSourceSnapshot(document, store: store, reuse: reuse)
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

struct DocumentSourceMessage: Encodable, Sendable {
  let key: String
  let documentID: UUID
  let paper: DocumentPaperLayout
  let files: [DocumentFile]
  let programs: [DocumentProgramSource]
  let programHeights: [String: Double]
  private enum CodingKeys: String, CodingKey { case key, documentID, paper, files, programs, programHeights }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key, forKey: .key); try c.encode(documentID, forKey: .documentID)
    try c.encode(paper, forKey: .paper)
    // The browser needs addresses, never another editable copy of source bytes.
    try c.encode(files.map { ["id": $0.id, "path": $0.path] }, forKey: .files)
    try c.encode(programHeights, forKey: .programHeights)
    try c.encode(programs.map { program in JSONValue.object([
      "id": .string(program.id), "path": .string(program.path), "programPackage": .string(program.programPackage),
      "initialState": program.initialState, "sourceBasis": .string(program.sourceBasis)]) }, forKey: .programs)
  }
}

struct DocumentStateMessage: Encodable, Sendable {
  let key: String
  let documentID: UUID
  let states: [String: JSONValue]
  let versions: [String: ContentFieldVersion]
}

/// Pages share one immutable source. Its body crosses the browser boundary
/// only as addressed page metadata; the native editor reads the actual files.
@MainActor
final class DocumentSourceSnapshot {
  private let key = UUID().uuidString
  let document: DocumentDocument
  private let store: NotebookStore?
  var message: DocumentSourceMessage { .init(key: key, documentID: document.id, paper: paper(on: 0), files: document.files, programs: programs, programHeights: layout?.programHeights(ids: programIDs) ?? [:]) }
  let stamp: VersionStamp
  var programs: [DocumentProgramSource] { preparation?.programs ?? [] }
  var programIDs: Set<String> { preparation?.programIDs ?? [] }
  var programFailures: [String: String] { preparation?.programFailures ?? [:] }
  private var blockIDs: Set<String> { Set(document.files.map(\.id)).union(programIDs) }
  private(set) var layout: DocumentLayoutRecord?
  private var preparation: DocumentPagePreparation?
  private var reuse: DocumentPrintReuse?
  var printReuse: DocumentPrintReuse? { preparation?.printReuse }
  private var layoutObservers: [UUID: (DocumentLayoutRecord) -> Void] = [:]
  private(set) var preparationCount = 0
  private var receiptLayoutMismatch: String?

  init(_ document: DocumentDocument, store: NotebookStore? = nil, reuse: DocumentPrintReuse? = nil) {
    self.document = document; self.store = store; stamp = document.contentStamp; self.reuse = reuse
  }
  func paper(on page: Int) -> DocumentPaperLayout { layout?.paper(on: page) ?? .uncompiled }
  func program(_ id: String) -> DocumentProgramSource? { programs.first { $0.id == id } }

  func matches(_ document: DocumentDocument) -> Bool { self.document == document }
  func canRead(using store: NotebookStore?) -> Bool { store == nil || self.store?.root == store?.root }

  func programIDs(on page: Int) -> Set<String>? {
    guard let layout, (0..<layout.pageCount).contains(page) else { return nil }
    return layout.blockIDs(on: [page], kind: .program).intersection(programIDs)
  }

  func preparedPage(_ index: Int, hostID: UUID,
    resources: SceneRenderResources, priority: NotebookTypesetter.Priority = .current, onAdmissionWait: @escaping (Bool) -> Void = { _ in },
    onLayoutChanged: @escaping (DocumentLayoutRecord) -> Void = { _ in }) async throws -> DocumentPreparedPage {
    layoutObservers[hostID] = onLayoutChanged
    ensurePreparation(resources: resources)
    let prepared: DocumentPreparedPage
    do { prepared = try await preparation!.page(index, hostID: hostID, priority: priority, onAdmissionWait: onAdmissionWait) }
    catch {
      if preparation?.layout != nil { try acceptPreparedLayout() }
      throw error
    }
    try acceptPreparedLayout()
    return prepared
  }

  func preparePrograms(on pages: Set<Int>, retaining ids: Set<String> = []) async throws {
    guard let preparation, let layout else { return }
    try await preparation.preparePrograms(layout.blockIDs(on: pages, kind: .program).union(ids))
  }

  private func ensurePreparation(resources: SceneRenderResources) {
    if preparation == nil {
      preparationCount += 1
      preparation = DocumentPagePreparation(document: document, sourceKey: key, store: store, resources: resources, reuse: reuse)
      reuse = nil
      preparation?.onLayoutAccepted = { [weak self] record in
        guard let self else { return }
        if let layout, layout !== record { guard layout.matches(record) else { throw DocumentSessionError.inconsistentLayout } }
        else { layout = record }
        for observer in Array(layoutObservers.values) { observer(layout!) }
      }
    }
  }
  /// Accepted opening demand starts immutable print work before any native
  /// host/window exists. The same source is later borrowed by its paper owner.
  func prepareOpening(pageIndex: Int, hostID: UUID, resources: SceneRenderResources) async throws {
    try Task.checkCancellation()
    ensurePreparation(resources: resources)
    preparation!.retainPage(pageIndex, hostID: hostID)
    _ = try await preparation!.printedSource()
    try acceptPreparedLayout()
  }
  func printedSource(resources: SceneRenderResources) async throws -> DocumentPrintedSource {
    ensurePreparation(resources: resources)
    return try await preparation!.printedSource()
  }
  func sourceOffset(fileID: String, pageIndex: Int, x: Double, y: Double) -> Int? {
    preparation?.sourceOffset(fileID: fileID, pageIndex: pageIndex, x: x, y: y)
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
  private var encoding: Task<NotebookProgramStateEncoding, Error>?
  private(set) var encodingCount = 0

  init(documentID: UUID, records: [DocumentStateRecord]) {
    self.records = records
    message = .init(key: UUID().uuidString, documentID: documentID,
      states: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.value) }),
      versions: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.valueVersion) }))
  }

  func encodedState(resources: SceneRenderResources) async throws -> NotebookProgramStateEncoding {
    if encoding == nil {
      encodingCount += 1
      let message = message
      encoding = Task { @MainActor in
        let value: JSONValue = .object(["key": .string(message.key), "documentID": .string(message.documentID.uuidString),
          "states": .object(message.states), "versions": try .encode(message.versions)])
        return try await NotebookProgramStateEncoding.prepare(value, resources: resources)
      }
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
  let buildID: String?
  let pages: [DocumentPaperLayout]
  let readingFileOrder: [String]
  var width: Double { pages[0].surfaceWidth }
  var height: Double { pages[0].surfaceHeight }
  func paper(on page: Int) -> DocumentPaperLayout { pages[min(max(0, page), pages.count - 1)] }
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
    isComplete = true
    self.buildID = receipt["buildID"] as? String
    self.pages = papers
    var seen: Set<String> = []
    self.readingFileOrder = regions.filter { $0.kind == .file }.sorted {
      ($0.pageIndex, $0.frame.y, $0.frame.x) < ($1.pageIndex, $1.frame.y, $1.frame.x)
    }.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    self.reservation = reservation
  }

  init(rebinding original: DocumentLayoutRecord, buildID: String) {
    pageCount = original.pageCount; isComplete = original.isComplete; regions = original.regions
    self.buildID = buildID; pages = original.pages; readingFileOrder = original.readingFileOrder
    anchorPages = original.anchorPages; reading = original.reading; pageRanges = original.pageRanges
    reservation = original.reservation
  }

  func matches(_ other: DocumentLayoutRecord, pageIndex: Int? = nil) -> Bool {
    let expectedRegions = regions[pageIndex.map { pageRanges[$0] ?? 0..<0 } ?? regions.startIndex..<regions.endIndex]
    let tolerance = 1.0 / 32
    guard (pageIndex != nil || (anchorPages == other.anchorPages && reading.matches(other.reading, tolerance: tolerance))),
      (pageIndex != nil || (pageCount == other.pageCount && isComplete == other.isComplete)),
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

  func programHeights(ids: Set<String>) -> [String: Double] {
    var result: [String: Double] = [:]
    for region in regions where region.kind == .program && ids.contains(region.id) {
      result[region.id] = max(result[region.id] ?? 0, region.sourceOffset + region.frame.height)
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
