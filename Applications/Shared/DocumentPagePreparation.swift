import Foundation
import CoreGraphics
import CryptoKit
import NotebookCore
import NotebookTypesetter
import WebKit

private func printPreparationMilliseconds(since start: ContinuousClock.Instant) -> Double {
  let elapsed = start.duration(to: .now).components
  return Double(elapsed.seconds)*1000 + Double(elapsed.attoseconds)/1e15
}

struct DocumentBrowserRegion: Codable, Sendable {
  let id: String
  let pageIndex: Int
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  let sourceOffset: Double
}

struct DocumentBrowserDiagnostic: Codable, Sendable {
  let kind: String
  let message: String
  let blockID: String?
}

struct DocumentPageFragment: Codable, Sendable {
  let format: Int
  let sourceKey: String
  let pageIndex: Int
  let width: Double
  let height: Double
  let contentTop: Double
  let contentBottom: Double
  let blockIDs: [String]
  let regions: [DocumentBrowserRegion]
  let html: String
  let nodeCount: Int
  let utf8Bytes: Int
}


@MainActor
final class DocumentPageMessage {
  let json: String
  private let reservation: RasterReservation
  init(json: String, reservation: RasterReservation) { self.json = json; self.reservation = reservation }
  isolated deinit { reservation.release() }
}

@MainActor
final class DocumentPreparedPage {
  let fragment: DocumentPageFragment
  let printed: DocumentPrintedPage
  private let source: DocumentSourceMessage
  private let pageCount: Int
  private let reservation: RasterReservation
  init(fragment: DocumentPageFragment, printed: DocumentPrintedPage, source: DocumentSourceMessage,
    pageCount: Int, reservation: RasterReservation) {
    self.fragment = fragment; self.printed = printed; self.source = source
    self.pageCount = pageCount; self.reservation = reservation
  }
  func encodedMessage(resources: SceneRenderResources, onAdmissionWait: (Bool) -> Void = { _ in }) async throws -> DocumentPageMessage {
    struct Envelope: Encodable {
      let source: DocumentSourceMessage; let fragment: DocumentPageFragment; let pageCount: Int
      let layoutComplete = true; let diagnostics: [DocumentBrowserDiagnostic] = []
    }
    func jsonByteBound(_ value: JSONValue) -> Int {
      switch value {
      case .null, .bool: 5
      case .number: 32
      case .string(let string): string.utf8.count*6+2
      case .array(let values): values.reduce(2) { $0 + jsonByteBound($1) + 1 }
      case .object(let values): values.reduce(2) { $0 + $1.key.utf8.count*6 + jsonByteBound($1.value) + 4 }
      }
    }
    let bytes = source.blocks.reduce(fragment.utf8Bytes + 16_384) { $0 + $1.source.utf8.count + $1.html.utf8.count + $1.css.utf8.count + $1.javaScript.utf8.count
      + jsonByteBound($1.initialState) + 1024 }
    let versionBytes = source.sourceVersions.values.reduce(0) { $0 + $1.observed.count*80 + 512 }
    let admittedBytes = bytes + versionBytes
    guard admittedBytes <= 16*1024*1024 else { throw SceneRenderError.resourceLimit }
    let charge = try await resources.acquirePassiveDerivedBytes(admittedBytes*4) { onAdmissionWait(true) }
    defer { onAdmissionWait(false) }
    do {
      let value = Envelope(source: source, fragment: fragment, pageCount: pageCount)
      let json = try await Task.detached { try canonicalDocumentJSON(value) }.value
      try Task.checkCancellation()
      guard json.utf8.count <= admittedBytes*2 else { throw SceneRenderError.resourceLimit }
      return .init(json: json, reservation: charge)
    } catch { charge.release(); throw error }
  }
  isolated deinit { reservation.release() }
}

/// One immutable PDF layout, not an independently paginated DOM. Mounted pages
/// retain only their local hit regions; no WebKit is borrowed for typesetting.
@MainActor
final class DocumentPagePreparation {
  private let message: DocumentSourceMessage
  private let document: DocumentDocument
  private let resources: SceneRenderResources
  private var preparation: Task<Void, Error>?
  private var printSource: DocumentPrintedSource?
  private var artifact: NotebookPrintedDocument? { printSource?.artifact }
  private var pages: [Int: DocumentPreparedPage] = [:]
  private var demand: [UUID: Int] = [:]
  private var readers: Set<UUID> = []
  private var error: Error?
  private var locations: [DocumentPrintLocation] = []
  private var navigation: DocumentPrintNavigation?
  private var browserRegions: [DocumentBrowserRegion] = []
  private(set) var layout: DocumentLayoutRecord?
  private(set) var measurementCount = 0
  private(set) var compiledPageCount = 0
  private(set) var preparationPhasesMS: [String: Double] = [:]
  var onLayoutAccepted: (DocumentLayoutRecord) throws -> Void = { _ in }
  var pendingReaderCount: Int { readers.count }
  var preparedSourceBlockCount: Int { artifact == nil ? 0 : document.blocks.count }
  var retainedPageIndices: Set<Int> { Set(pages.keys) }
  var failed: Bool { error != nil }
  var lastLayoutMismatch: String? { nil }

  init(document: DocumentDocument, message: DocumentSourceMessage, resources: SceneRenderResources) {
    self.document = document; self.message = message; self.resources = resources
  }
  func retainPage(_ index: Int, hostID: UUID) { demand[hostID] = max(0, index); trim() }
  func releasePage(hostID: UUID, in web: WKWebView?) {
    demand[hostID] = nil; trim()
    cancelUnownedPreparation()
  }
  private func trim() {
    let retained = Set(demand.values.map { min($0, max(0, (layout?.pageCount ?? 1)-1)) })
    pages = pages.filter { retained.contains($0.key) }
  }
  func retryPage(_ index: Int) { error = nil; if artifact == nil { preparation = nil } }
  func discardIdlePreparation() async {
    guard readers.isEmpty, demand.isEmpty else { return }
    preparation?.cancel(); preparation = nil; pages.removeAll(); printSource = nil
    locations.removeAll(); browserRegions.removeAll(); navigation = nil
  }
  private func prepare(onAdmissionWait: @escaping (Bool) -> Void) async throws {
    if artifact != nil { return }
    if let error { throw error }
    if preparation == nil {
      measurementCount += 1
      preparation = Task { try await loadPrint(onAdmissionWait: onAdmissionWait) }
    }
    let id = UUID(), task = preparation!
    readers.insert(id)
    onAdmissionWait(true); defer { onAdmissionWait(false); releaseReader(id) }
    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation(); try await task.value; try Task.checkCancellation()
      } onCancel: { Task { @MainActor [weak self] in self?.releaseReader(id) } }
    }
    catch { if !(error is CancellationError) { self.error = error }; throw error }
  }
  private func releaseReader(_ id: UUID) {
    readers.remove(id); cancelUnownedPreparation()
  }
  private func cancelUnownedPreparation() {
    if demand.isEmpty, readers.isEmpty { preparation?.cancel(); preparation = nil }
  }
  private func loadPrint(onAdmissionWait: @escaping (Bool) -> Void) async throws {
    let start = ContinuousClock.now
    let value = try await DocumentCanonicalPrint.store.artifact(for: document)
    preparationPhasesMS["artifact"] = printPreparationMilliseconds(since: start)
    try Task.checkCancellation()
    // Admit decoding scratch and bounded PDF navigation before materializing
    // either. The same reservation shrinks to the retained source afterwards.
    let bodyBytes = value.pdf.count + value.syncTeX.count + value.source.utf8.count
      + value.assets.reduce(0, { $0 + $1.data.count })
      + value.sourceMap.ranges.reduce(0, { $0 + ($1.sourceOffsets?.count ?? 0)*MemoryLayout<Int>.stride + 256 })
    guard value.locationDecodeBytes <= 16*1024*1024 else { throw SceneRenderError.resourceLimit }
    let admissionStart = ContinuousClock.now
    let charge = try await resources.acquirePassiveDerivedBytes(bodyBytes + value.locationDecodeBytes*5 + 24*1024*1024) { onAdmissionWait(true) }
    preparationPhasesMS["admission"] = printPreparationMilliseconds(since: admissionStart)
    defer { onAdmissionWait(false) }
    do {
      let pdf=DocumentPrintedPDF(value.pdf)
      let worker = Task.detached {
        let locationsStart = ContinuousClock.now
        let addresses=try value.locations()
        let locationsMS = printPreparationMilliseconds(since: locationsStart)
        let pdfStart = ContinuousClock.now
        let (boxes,navigation)=try await pdf.perform { document,quartz in
          let boxes=try (1...quartz.numberOfPages).map { index in
            guard let page=quartz.page(at:index) else { throw DocumentSessionError.invalidLayout }
            return page.getBoxRect(.mediaBox)
          }
          return (boxes,try DocumentPrintNavigation.read(document))
        }
        return (addresses,boxes,navigation,locationsMS,printPreparationMilliseconds(since: pdfStart))
      }
      let (addresses, boxes, navigation, locationsMS, pdfMS) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
      preparationPhasesMS["locations"] = locationsMS
      preparationPhasesMS["pdfNavigation"] = pdfMS
      try Task.checkCancellation()
      let layoutStart = ContinuousClock.now
      try installLayout(value, boxes: boxes, locations: addresses)
      preparationPhasesMS["layout"] = printPreparationMilliseconds(since: layoutStart)
      let cost = bodyBytes + addresses.count*128 + navigation.pageText.reduce(0, { $0 + $1.utf8.count*2 })
        + navigation.links.reduce(0, { $0 + $1.href.utf8.count*2 + 256 })
      guard resources.resizePassiveDerivedReservation(charge, to: max(1, cost)) else { throw SceneRenderError.resourceLimit }
      printSource = DocumentPrintedSource(artifact: value, locations: addresses, pdf: pdf, reservation: charge)
      locations = addresses; self.navigation = navigation
      preparationPhasesMS["canonicalPrint"] = printPreparationMilliseconds(since: start)
      preparation = nil
    } catch { charge.release(); throw error }
  }
  private func installLayout(_ value: NotebookPrintedDocument, boxes: [CGRect], locations: [DocumentPrintLocation]) throws {
    let width = message.paper.surfaceWidth, height = message.paper.surfaceHeight
    let scale = width / message.paper.widthPoints
    var regions: [DocumentBrowserRegion] = [], reading: [[Any]] = []
    var offsets: [String: Double] = [:]
    let byPage = Dictionary(grouping: locations, by: \.pageIndex)
    let order = Dictionary(uniqueKeysWithValues: document.blocks.enumerated().map { ($0.element.id, $0.offset) })
    let ranges = Dictionary(uniqueKeysWithValues: value.sourceMap.ranges.map { ($0.blockID, $0) })
    for (index,box) in boxes.enumerated() {
      guard abs(box.width-message.paper.widthPoints) < 0.1, abs(box.height-message.paper.heightPoints) < 0.1 else {
        throw NotebookTypesetterError("Размер печатной страницы не совпадает с выбранным A4/Letter.")
      }
      let groups = Dictionary(grouping: byPage[index] ?? [], by: \.blockID)
      for id in groups.keys.sorted(by: { order[$0, default: 0] < order[$1, default: 0] }) {
        guard let ordinal = order[id], let entries = groups[id] else { continue }
        let block = document.blocks[ordinal]
        var bounds = CGRect.null
        for entry in entries { bounds = bounds.union(CGRect(x: entry.x, y: entry.y, width: entry.width, height: entry.height)) }
        bounds = bounds.intersection(CGRect(origin: .zero, size: box.size))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
        let region = DocumentBrowserRegion(id: block.id, pageIndex: index, x: bounds.minX*scale, y: bounds.minY*scale,
          width: bounds.width*scale, height: bounds.height*scale, sourceOffset: offsets[block.id] ?? 0)
        regions.append(region); offsets[block.id, default: 0] += region.height
        let line = entries.map(\.generatedLine).min() ?? 1
        guard let range = ranges[block.id] else { throw DocumentSessionError.invalidLayout }
        let offset = DocumentPrintLocations.sourceOffset(line: line, range: range, source: block.source)
        let text = block.source as NSString
        let tail = NSRange(location: offset, length: text.length-offset)
        let newline = text.range(of: "\n", range: tail)
        let fragment = text.substring(with: NSRange(location: offset,
          length: (newline.location == NSNotFound ? text.length : newline.location)-offset))
        let node = SHA256.hash(data: Data(fragment.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        // Macro output resolves to the nearest source line, never a fabricated
        // character position in an independently laid-out DOM.
        reading.append([block.id, node, offset, 0, max(1, fragment.utf16.count), index, region.y])
      }
    }
    // Empty editable blocks still have an addressable paper entry.
    if regions.isEmpty, let block = document.blocks.first {
      regions = [.init(id: block.id, pageIndex: 0, x: message.paper.marginPoints*scale,
        y: message.paper.marginPoints*scale, width: width-2*message.paper.marginPoints*scale, height: 24*scale, sourceOffset: 0)]
    }
    let receipt: NSDictionary = ["sourceKey": message.key, "layoutScope": "source", "layoutCanonical": true,
      "pageCount": boxes.count, "width": width, "height": height, "anchors": boxes.indices.map { ["name": "notebook-print-page-\($0)", "pageIndex": $0] as [String: Any] }, "reading": reading,
      "regions": regions.map { ["id": $0.id, "pageIndex": $0.pageIndex, "x": $0.x, "y": $0.y,
        "width": $0.width, "height": $0.height, "sourceOffset": $0.sourceOffset] as [String: Any] }]
    guard let charge = resources.reserveDerivedBytes(regions.count*384 + reading.count*128 + 4096, priority: .passive) else { throw SceneRenderError.resourceLimit }
    let measured = try DocumentLayoutRecord(receipt: receipt, sourceKey: message.key,
      blockIDs: Set(document.blocks.map(\.id)), geometry: .document(document.paperSize), reservation: charge)
    layout = measured; browserRegions = regions; try onLayoutAccepted(measured)
  }
  func page(_ requested: Int, hostID: UUID,
    onAdmissionWait: @escaping (Bool) -> Void = { _ in }) async throws -> DocumentPreparedPage {
    retainPage(requested, hostID: hostID)
    try await prepare(onAdmissionWait: onAdmissionWait)
    guard artifact != nil, let layout else { throw DocumentSessionError.invalidLayout }
    let index = min(max(0, requested), layout.pageCount-1)
    if let cached = pages[index] { return cached }
    let regions = browserRegions.filter { $0.pageIndex == index }, ids = Set(regions.map(\.id))
    let blocks = document.blocks.filter { ids.contains($0.id) }
    func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
    var html = regions.map { region in
      let block = blocks.first { $0.id == region.id }!
      let accessibility = block.kind == .interactive ? "" : " role=\"button\" tabindex=\"0\" aria-label=\"Исходник: \(escape(String(block.source.prefix(80))))\""
      return "<section class=\"block \(block.kind == .interactive ? "interactive" : "editable")\" data-block-id=\"\(escape(region.id))\" data-kind=\"\(block.kind.rawValue)\"\(accessibility) style=\"position:absolute;left:\(region.x)px;top:\(region.y)px;width:\(region.width)px;height:\(region.height)px;margin:0\"></section>"
    }.joined()
    let scale = message.paper.surfaceWidth / message.paper.widthPoints
    for link in navigation?.links.filter({ $0.page == index }) ?? [] {
      let box = link.rect
      html += "<a href=\"\(escape(link.href))\" aria-label=\"Открыть ссылку\" style=\"position:absolute;left:\(box.minX*scale)px;top:\(box.minY*scale)px;width:\(box.width*scale)px;height:\(box.height*scale)px;z-index:2\"></a>"
    }
    if let text = navigation?.pageText[index] {
      html += "<div role=\"article\" style=\"position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);pointer-events:none\">\(escape(text))</div>"
    }
    let charge = try await resources.acquirePassiveDerivedBytes(html.utf8.count + regions.count*256 + 4096) { onAdmissionWait(true) }
    defer { onAdmissionWait(false) }
    let fragment = DocumentPageFragment(format: 1, sourceKey: message.key, pageIndex: index,
      width: message.paper.surfaceWidth, height: message.paper.surfaceHeight, contentTop: 0,
      contentBottom: message.paper.surfaceHeight, blockIDs: blocks.map(\.id), regions: regions, html: html,
      nodeCount: regions.count, utf8Bytes: html.utf8.count)
    let printed = DocumentPrintedPage(source: printSource!, pageIndex: index, width: message.paper.widthPoints, height: message.paper.heightPoints)
    let local = DocumentSourceMessage(key: message.key, documentID: message.documentID, paper: message.paper,
      blocks: blocks, sourceVersions: message.sourceVersions.filter { ids.contains($0.key) },
      programIdentities: message.programIdentities.filter { ids.contains($0.key) })
    let page = DocumentPreparedPage(fragment: fragment, printed: printed, source: local, pageCount: layout.pageCount, reservation: charge)
    pages[index] = page; compiledPageCount += 1; trim(); return page
  }
  func printedSource() async throws -> DocumentPrintedSource {
    try await prepare(onAdmissionWait: { _ in })
    guard let printSource else { throw DocumentSessionError.invalidLayout }
    return printSource
  }
  func sourceOffset(blockID: String, pageIndex: Int, x: Double, y: Double) -> Int? {
    let scale = message.paper.widthPoints / message.paper.surfaceWidth
    return printSource?.sourceOffset(blockID: blockID, pageIndex: pageIndex, x: x*scale, y: y*scale)
  }
  isolated deinit { preparation?.cancel() }
}
