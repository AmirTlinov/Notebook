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
  private var states: [VersionStamp: [WeakState]] = [:]

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

  func state(_ journal: DocumentStateJournal) -> DocumentStateSnapshot {
    precondition(journal.id == documentID)
    if let snapshot = states[journal.stamp]?.lazy.compactMap(\.value).first(where: { $0.matches(journal) }) { return snapshot }
    states = states.compactMapValues { values in
      let live = values.filter { $0.value != nil }; return live.isEmpty ? nil : live
    }
    let snapshot = DocumentStateSnapshot(journal)
    states[journal.stamp, default: []].append(WeakState(snapshot))
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

  init(_ size: DocumentPaperSize) {
    kind = size
    widthPoints = size.widthPoints; heightPoints = size.heightPoints
    marginPoints = size.marginPoints
    let geometry = WorkspaceItemGeometry.document(size)
    cornerRadiusRatio = geometry.cornerRadius / geometry.width
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

/// The encoded string has one producer even when all four pages request it at
/// once. Encoding runs outside the input actor, and no caller mutates its input.
@MainActor
final class DocumentSourceSnapshot {
  let message: DocumentSourceMessage
  private let document: DocumentDocument
  let stamp: VersionStamp
  private let blockIDs: Set<String>
  private var encoding: Task<String, Error>?
  private(set) var encodingCount = 0
  private(set) var layout: DocumentLayoutRecord?
  private var preparation: DocumentPagePreparation?
  private(set) var preparationCount = 0

  init(_ document: DocumentDocument) {
    self.document = document
    stamp = document.contentStamp
    blockIDs = Set(document.blocks.map(\.id))
    message = .init(key: UUID().uuidString, documentID: document.id,
      paper: .init(document.paperSize), blocks: document.blocks,
      sourceVersions: Dictionary(uniqueKeysWithValues: document.blocks.map { ($0.id, document.sourceVersion(blockID: $0.id)) }))
  }

  func matches(_ document: DocumentDocument) -> Bool { self.document == document }

  private func encodingTask() -> Task<String, Error> {
    if encoding == nil {
      encodingCount += 1
      let message = message
      encoding = Task.detached(priority: .userInitiated) { try canonicalDocumentJSON(message) }
    }
    return encoding!
  }

  func encodedJSON() async throws -> String { try await encodingTask().value }

  func preparedPage(_ index: Int, in web: WKWebView, lease: WebSurfaceLease,
    resources: SceneRenderResources) async throws -> DocumentPreparedPage {
    if preparation == nil {
      preparationCount += 1
      preparation = try DocumentPagePreparation(message: message, sourceJSON: encodingTask(), web: web, lease: lease, resources: resources)
    }
    let prepared = try await preparation!.value()
    if let layout, layout !== prepared.layout, !layout.matches(prepared.layout) { throw DocumentSessionError.inconsistentLayout }
    layout = prepared.layout
    return prepared.page(index)
  }

  func retryPagePreparation() {
    if preparation?.failed == true { preparation = nil }
  }

  func acceptLayout(_ receipt: NSDictionary, geometry: WorkspaceItemGeometry) throws -> DocumentLayoutRecord {
    guard let scope = receipt["layoutScope"] as? String, scope == "source" || scope == "page",
      scope != "page" || layout != nil else { throw DocumentSessionError.invalidLayout }
    let measured = try DocumentLayoutRecord(receipt: receipt, sourceKey: message.key, blockIDs: blockIDs, geometry: geometry)
    if let layout {
      if receipt["layoutScope"] as? String == "page" {
        guard let index = receipt["pageIndex"] as? Int, (0..<layout.pageCount).contains(index),
          layout.matches(measured, pageIndex: index) else { throw DocumentSessionError.inconsistentLayout }
      } else if !layout.matches(measured) { throw DocumentSessionError.inconsistentLayout }
      return layout
    }
    layout = measured
    return measured
  }

  isolated deinit { encoding?.cancel() }
}

@MainActor
final class DocumentStateSnapshot {
  let message: DocumentStateMessage
  private let journal: DocumentStateJournal
  let stamp: VersionStamp
  private var encoding: Task<String, Error>?
  private(set) var encodingCount = 0

  init(_ journal: DocumentStateJournal) {
    self.journal = journal
    stamp = journal.stamp
    message = .init(key: UUID().uuidString, documentID: journal.id,
      states: Dictionary(uniqueKeysWithValues: journal.records.map { ($0.id, $0.value) }))
  }

  func matches(_ journal: DocumentStateJournal) -> Bool { self.journal == journal }

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

private func canonicalDocumentJSON<T: Encodable>(_ value: T) throws -> String {
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

/// A measured source layout is immutable after acceptance. Several page frames
/// may reference it, but a disagreeing neighbor cannot replace its geometry.
@MainActor
final class DocumentLayoutRecord {
  let pageCount: Int
  let regions: [DocumentBlockRegion]
  let width: Double
  let height: Double
  private let pageRanges: [Int: Range<Int>]
  // A raster or an address reader can outlive the source preparation. The
  // shared layout, not a temporary task or registry cache, owns this allocation.
  private let reservation: RasterReservation?
  private var releaseObservers: [ObjectIdentifier: @MainActor () -> Void] = [:]

  init(receipt: NSDictionary, sourceKey: String, blockIDs: Set<String>, geometry: WorkspaceItemGeometry,
    reservation: RasterReservation? = nil) throws {
    guard receipt["sourceKey"] as? String == sourceKey,
      receipt["layoutCanonical"] as? Bool == true,
      let count = receipt["pageCount"] as? Int, count > 0,
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
        x + w <= width + 0.03125, y + h <= height + 0.03125 else { throw DocumentSessionError.invalidLayout }
      guard regions.last.map({ $0.pageIndex <= page }) ?? true else { throw DocumentSessionError.invalidLayout }
      pageRanges[page] = (pageRanges[page]?.lowerBound ?? regions.count)..<(regions.count + 1)
      regions.append(.init(id: id, pageIndex: page, frame: .init(x: x * geometry.width / width,
        y: y * geometry.height / height, width: w * geometry.width / width, height: h * geometry.height / height)))
    }
    self.pageCount = count; self.regions = regions; self.pageRanges = pageRanges
    self.width = geometry.width; self.height = geometry.height
    self.reservation = reservation
  }

  func matches(_ other: DocumentLayoutRecord, pageIndex: Int? = nil) -> Bool {
    let expectedRegions = regions[pageIndex.map { pageRanges[$0] ?? 0..<0 } ?? regions.startIndex..<regions.endIndex]
    guard pageCount == other.pageCount, width == other.width, height == other.height,
      expectedRegions.count == other.regions.count else { return false }
    // Transform round trips may differ by two WebKit layout subpixels. This
    // tolerance never changes the accepted record or grows with page count.
    let tolerance = 1.0 / 32
    return zip(expectedRegions, other.regions).allSatisfy { left, right in
      left.id == right.id && left.pageIndex == right.pageIndex
        && abs(left.frame.x - right.frame.x) <= tolerance && abs(left.frame.y - right.frame.y) <= tolerance
        && abs(left.frame.width - right.frame.width) <= tolerance && abs(left.frame.height - right.frame.height) <= tolerance
    }
  }

  func whenReleased(by owner: AnyObject, _ action: @escaping @MainActor () -> Void) {
    releaseObservers[ObjectIdentifier(owner)] = action
  }

  isolated deinit { for action in releaseObservers.values { action() } }
}
