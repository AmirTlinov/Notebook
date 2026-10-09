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

@MainActor
final class DocumentPreparedPage {
  let printed: DocumentPrintedPage
  let navigation: DocumentPrintNavigation
  let regions: [DocumentBlockRegion]
  var size: CGSize { .init(width: printed.width * DocumentPaperLayout.pointsToSurface,
    height: printed.height * DocumentPaperLayout.pointsToSurface) }
  private let reservation: RasterReservation
  init(printed: DocumentPrintedPage, navigation: DocumentPrintNavigation,
    regions: [DocumentBlockRegion], reservation: RasterReservation) {
    self.printed = printed; self.navigation = navigation; self.regions = regions; self.reservation = reservation
  }
  isolated deinit { reservation.release() }
}

/// Immutable source-wide indices are built on the PDF worker, then installed
/// by the MainActor owner without encoding and parsing a browser receipt.
struct DocumentPreparedLayout: Sendable {
  let pages: [DocumentPaperLayout]
  let regions: [DocumentBlockRegion]
  let pageRanges: [Int: Range<Int>]
  let reading: DocumentReadingIndex
  let readingFileOrder: [String]
  let anchors: [String: Int]
  let lineIndices: [String: DocumentPrintLineIndex]
  let slots: [Int: [DocumentPrintInteractiveRegion]]
  var byteCount: Int {
    regions.count*384 + reading.segments.count*128 + pages.count*128 + 4096
      + lineIndices.values.reduce(0) { $0 + $1.starts.count*MemoryLayout<Int>.stride }
      + slots.values.reduce(0) { $0 + $1.count*128 }
  }
  init(pages: [DocumentPaperLayout], regions: [DocumentBlockRegion], fileIDs: Set<String>,
    reading: [DocumentReadingIndex.Segment] = [], anchors: [String: Int] = [:],
    lineIndices: [String: DocumentPrintLineIndex] = [:], slots: [Int: [DocumentPrintInteractiveRegion]] = [:]) throws {
    let pageCount = pages.count
    guard (1...4096).contains(pageCount), pages.allSatisfy({
      $0.widthPoints.isFinite && $0.heightPoints.isFinite && $0.widthPoints > 0 && $0.heightPoints > 0
        && $0.widthPoints <= 14_400 && $0.heightPoints <= 14_400
    }), anchors.count <= 16_384, anchors.reduce(0, { $0 + $1.key.utf8.count }) <= 1024*1024,
      anchors.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 4096 && (0..<pageCount).contains($0.value) })
    else { throw DocumentSessionError.invalidLayout }
    var pageRanges: [Int: Range<Int>] = [:]
    var previousPage = 0
    for (index, region) in regions.enumerated() {
      let page = region.pageIndex, frame = region.frame
      guard (0..<pageCount).contains(page), page >= previousPage,
        frame.x.isFinite, frame.x >= 0, frame.y.isFinite, frame.y >= 0,
        frame.width.isFinite, frame.width > 0, frame.height.isFinite, frame.height > 0,
        region.sourceOffset.isFinite, region.sourceOffset >= 0, (region.sourceOffset+frame.height).isFinite,
        frame.x+frame.width <= pages[page].surfaceWidth+0.03125,
        frame.y+frame.height <= pages[page].surfaceHeight+0.03125 else { throw DocumentSessionError.invalidLayout }
      previousPage = page
      pageRanges[page] = (pageRanges[page]?.lowerBound ?? index)..<(index+1)
    }
    var seen: Set<String> = []
    readingFileOrder = regions.filter { $0.kind == .file }.sorted {
      ($0.pageIndex, $0.frame.y, $0.frame.x) < ($1.pageIndex, $1.frame.y, $1.frame.x)
    }.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    self.pages = pages; self.regions = regions; self.pageRanges = pageRanges
    self.reading = try .init(segments: reading, fileIDs: fileIDs, pageCount: pageCount)
    self.anchors = anchors; self.lineIndices = lineIndices; self.slots = slots
  }

  init(_ value: NotebookPrintedDocument, document: DocumentDocument, pageCount: Int,
    locations: [DocumentPrintLocation], anchors: [String: Int]) throws {
    let scale = DocumentPaperLayout.pointsToSurface
    var regions: [DocumentBlockRegion] = [], reading: [DocumentReadingIndex.Segment] = []
    let byPage = Dictionary(grouping: locations, by: \.pageIndex)
    let files = Dictionary(uniqueKeysWithValues: document.files.map { ($0.id, $0) })
    let indexedFiles = Set(value.sourceMap.files.map(\.fileID))
    let lineIndices = Dictionary(uniqueKeysWithValues: document.files.filter { $0.resource == nil && indexedFiles.contains($0.id) }.map { ($0.id, DocumentPrintLineIndex($0.source)) })
    let slots = Dictionary(grouping: value.interactiveRegions, by: \.pageIndex)
    guard (1...4096).contains(pageCount), value.pages.count == pageCount else { throw DocumentSessionError.invalidLayout }
    let papers = value.pages.map { DocumentPaperLayout(widthPoints: $0.width, heightPoints: $0.height) }
    for index in 0..<pageCount {
      try Task.checkCancellation()
      let paper = papers[index]
      let groups = Dictionary(grouping: byPage[index] ?? [], by: \.fileID)
      for id in groups.keys.sorted() {
        guard let file = files[id], let entries = groups[id] else { continue }
        var bounds = CGRect.null
        for entry in entries { bounds = bounds.union(CGRect(x: entry.x, y: entry.y, width: entry.width, height: entry.height)) }
        bounds = bounds.intersection(CGRect(x: 0, y: 0, width: paper.widthPoints, height: paper.heightPoints))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
        let region = DocumentBlockRegion(id: id, pageIndex: index, frame: .init(x: bounds.minX*scale, y: bounds.minY*scale,
          width: bounds.width*scale, height: bounds.height*scale), sourceOffset: 0)
        regions.append(region)
        let line = entries.map(\.line).min() ?? 1
        guard let lines = lineIndices[id] else { continue }
        let range = lines.range(line: line), offset = range.location
        let fragment = (file.source as NSString).substring(with: range)
        let node = SHA256.hash(data: Data(fragment.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        reading.append(.init(fileID: id, nodeID: node, textOffset: offset, start: 0, end: max(1, fragment.utf16.count), pageIndex: index, y: region.frame.y))
      }
      for slot in slots[index] ?? [] {
        regions.append(.init(kind: .program, id: slot.instanceID, pageIndex: index, frame: .init(x: slot.x*scale, y: slot.y*scale,
          width: slot.width*scale, height: slot.height*scale), sourceOffset: slot.viewportY*scale))
      }
    }
    if regions.isEmpty, let file = document.files.first(where: { $0.path == document.entrypoint }) {
      regions = [.init(id: file.id, pageIndex: 0, frame: .init(x: 0, y: 0,
        width: papers[0].surfaceWidth, height: papers[0].surfaceHeight), sourceOffset: 0)]
    }
    var anchors = anchors
    for index in 0..<pageCount { anchors["notebook-print-page-\(index)"] = index }
    try self.init(pages: papers, regions: regions, fileIDs: Set(files.keys), reading: reading,
      anchors: anchors, lineIndices: lineIndices, slots: slots)
  }
}

/// A mounted source may lend immutable geometry to a newer causal binding.
/// This value contains material, never a chain of former source snapshots.
@MainActor
struct DocumentPrintReuse {
  let source: DocumentPrintedSource
  let layout: DocumentLayoutRecord
  func matches(_ artifact: NotebookPrintedDocument) -> Bool {
    guard source.artifact.pixelIdentity == artifact.pixelIdentity, source.artifact.syncTeX == artifact.syncTeX else { return false }
    let paths = Set(source.artifact.dependencies.lookups.filter { $0.kind == .path }.map(\.path))
    return source.artifact.sourceMap.files.filter { paths.contains($0.path) }
      == artifact.sourceMap.files.filter { paths.contains($0.path) }
  }
}

/// One immutable PDF layout, not an independently paginated DOM. Mounted pages
/// retain only their local hit regions; no WebKit is borrowed for typesetting.
@MainActor
final class DocumentPagePreparation {
  private let sourceKey: String
  private let store: NotebookStore?
  private(set) var programs: [DocumentProgramSource] = []
  private(set) var programIDs: Set<String> = []
  private(set) var programFailures: [String: String] = [:]
  private let document: DocumentDocument
  private let resources: SceneRenderResources
  private var preparation: Task<Void, Error>?
  private var compilerDemand: NotebookTypesetterDemand?
  private var printSource: DocumentPrintedSource?
  private var reuse: DocumentPrintReuse?
  var printReuse: DocumentPrintReuse? {
    guard let printSource, let layout else { return nil }
    return .init(source: printSource, layout: layout)
  }
  private var artifact: NotebookPrintedDocument? { printSource?.artifact }
  private var pages: [Int: DocumentPreparedPage] = [:]
  private struct PageOperation {
    let id: UUID
    let task: Task<DocumentPreparedPage, Error>
    var readers: Set<UUID>
  }
  private var pageOperations: [Int: PageOperation] = [:]
  private var demand: [UUID: Int] = [:]
  private var readers: Set<UUID> = []
  private var error: Error?
  // Keyed by program path within this immutable source, not by instance.
  private var programTasks: [String: (id: UUID, task: Task<Void, Error>)] = [:]
  private var programSources: [String: DocumentProgramSource] = [:]
  private var programSourceFailures: [String: String] = [:]
  private var programRequests: [String: Set<String>] = [:]
  var onProgramsChanged: () -> Void = {}
  private(set) var layout: DocumentLayoutRecord?
  private(set) var measurementCount = 0
  private(set) var compiledPageCount = 0
  private(set) var preparationPhasesMS: [String: Double] = [:]
  private(set) var preparationBeganAt: TimeInterval?
  private(set) var preparationCompletedAt: TimeInterval?
  var onLayoutAccepted: (DocumentLayoutRecord) throws -> Void = { _ in }
  var pendingReaderCount: Int { readers.count }
  var preparedSourceBlockCount: Int { artifact == nil ? 0 : document.files.count }
  var retainedPageIndices: Set<Int> { Set(pages.keys) }
  var failed: Bool { error != nil }
  var lastLayoutMismatch: String? { nil }

  init(document: DocumentDocument, sourceKey: String, store: NotebookStore?, resources: SceneRenderResources, reuse: DocumentPrintReuse? = nil) {
    self.document = document; self.sourceKey = sourceKey; self.store = store; self.resources = resources; self.reuse = reuse
  }
  func retainPage(_ index: Int, hostID: UUID) { demand[hostID] = max(0, index); trim() }
  func promote(to priority: NotebookTypesetter.Priority) { compilerDemand?.promote(to: priority) }
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
    preparation?.cancel(); preparation = nil; compilerDemand = nil; pages.removeAll(); printSource = nil; reuse = nil
    pageOperations.values.forEach { $0.task.cancel() }; pageOperations.removeAll()
    programTasks.values.forEach { $0.task.cancel() }; programTasks.removeAll(); programs.removeAll()
    programSources.removeAll(); programSourceFailures.removeAll(); programRequests.removeAll(); programFailures.removeAll()
  }
  private func prepare(priority: NotebookTypesetter.Priority = .current, onAdmissionWait: @escaping (Bool) -> Void) async throws {
    if artifact != nil { return }
    if let error { throw error }
    if preparation == nil {
      let compilerDemand = NotebookTypesetterDemand(priority: priority)
      self.compilerDemand = compilerDemand
      measurementCount += 1
      preparation = Task { try await loadPrint(priority: priority, compilerDemand: compilerDemand, onAdmissionWait: onAdmissionWait) }
    } else { promote(to: priority) }
    let id = UUID(), task = preparation!
    readers.insert(id)
    onAdmissionWait(true); defer { onAdmissionWait(false); releaseReader(id) }
    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation(); try await DocumentPreparationSubscriber.wait(for: task); try Task.checkCancellation()
      } onCancel: { Task { @MainActor [weak self] in self?.releaseReader(id) } }
    }
    catch { if !(error is CancellationError) { self.error = error }; throw error }
  }
  private func releaseReader(_ id: UUID) {
    readers.remove(id); cancelUnownedPreparation()
  }
  private func cancelUnownedPreparation() {
    if demand.isEmpty, readers.isEmpty { preparation?.cancel(); preparation = nil; compilerDemand = nil }
    for (index, operation) in pageOperations where operation.readers.isEmpty && !demand.values.contains(index) {
      operation.task.cancel(); pageOperations[index] = nil
    }
  }
  private func loadPrint(priority: NotebookTypesetter.Priority, compilerDemand: NotebookTypesetterDemand,
    onAdmissionWait: @escaping (Bool) -> Void) async throws {
    let start = ContinuousClock.now
    preparationBeganAt = ProcessInfo.processInfo.systemUptime
    preparationCompletedAt = nil
    let document = document, store = store
    let value = try await DocumentCanonicalPrint.store.artifact(for: document, priority: priority, demand: compilerDemand, inputFactory: {
      let worker = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        return try NotebookTypesetterInput(document: document) { file in
          try Task.checkCancellation()
          guard let store else { throw SceneRenderError.snapshotPending("document_resource_store") }
          return try store.readDocumentFileBytes(file)
        }
      }
      return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    })
    preparationPhasesMS["artifact"] = printPreparationMilliseconds(since: start)
    for (phase, milliseconds) in compilerDemand.preparationPhasesMS {
      preparationPhasesMS["artifact." + phase] = milliseconds
    }
    programIDs = Set(value.interactiveRegions.map(\.instanceID))
    try Task.checkCancellation()
    if let previous = reuse, previous.matches(value) {
      let rebound = DocumentLayoutRecord(rebinding: previous.layout, buildID: value.buildID)
      printSource = previous.source.rebinding(value)
      layout = rebound; reuse = nil
      try onLayoutAccepted(rebound)
      preparationPhasesMS["canonicalPrint"] = printPreparationMilliseconds(since: start)
      preparationCompletedAt = ProcessInfo.processInfo.systemUptime
      preparation = nil; return
    }
    reuse = nil
    // Projection was decoded once by the artifact owner. Admit its retained
    // bytes and bounded named-destination scratch, not another SyncTeX decode.
    let bodyBytes = value.pdf.count + value.syncTeX.count + value.source.utf8.count
      + value.sourceMap.files.count * 512
    let admissionStart = ContinuousClock.now
    let readingBound = min(value.projection.locations.count, value.pages.count * value.sourceMap.files.count)
    let layoutBound = readingBound*512 + value.pages.count*128 + value.interactiveRegions.count*512
      + value.sourceMap.files.reduce(0) { $0 + $1.lineCount*MemoryLayout<Int>.stride }
    let charge = try await resources.acquirePassiveDerivedBytes(bodyBytes + value.projection.locations.count*128 + layoutBound + 4*1024*1024, onDeferred: { onAdmissionWait(true) })
    preparationPhasesMS["admission"] = printPreparationMilliseconds(since: admissionStart)
    defer { onAdmissionWait(false) }
    do {
      let pdf = DocumentPrintedPDF(value.pdf)
      let worker = Task.detached {
        let locationsStart = ContinuousClock.now
        let addresses = try value.locations()
        let locationsMS = printPreparationMilliseconds(since: locationsStart)
        let pdfStart = ContinuousClock.now
        let (pageCount, navigation) = try await pdf.perform { document, quartz in
          (quartz.numberOfPages, try DocumentPrintNavigation.namedDestinations(document))
        }
        let pdfMS = printPreparationMilliseconds(since: pdfStart), layoutStart = ContinuousClock.now
        let prepared = try DocumentPreparedLayout(value, document: document, pageCount: pageCount, locations: addresses, anchors: navigation)
        return (addresses, prepared, locationsMS, pdfMS, printPreparationMilliseconds(since: layoutStart))
      }
      let (addresses, prepared, locationsMS, pdfMS, layoutMS) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
      preparationPhasesMS["locations"] = locationsMS
      preparationPhasesMS["pdfNavigation"] = pdfMS
      try Task.checkCancellation()
      preparationPhasesMS["layout"] = layoutMS
      let cost = bodyBytes + addresses.count*128 + prepared.byteCount
        + prepared.anchors.reduce(0, { $0 + $1.key.utf8.count*2 + 128 })
      guard resources.resizePassiveDerivedReservation(charge, to: max(1, cost)) else { throw SceneRenderError.resourceLimit }
      let printed = DocumentPrintedSource(artifact: value, locations: addresses, pdf: pdf, reservation: charge,
        lineIndices: prepared.lineIndices, slots: prepared.slots)
      let measured = DocumentLayoutRecord(prepared: prepared, buildID: value.buildID, allocation: printed.allocation)
      printSource = printed; layout = measured
      try onLayoutAccepted(measured)
      preparationPhasesMS["canonicalPrint"] = printPreparationMilliseconds(since: start)
      preparationCompletedAt = ProcessInfo.processInfo.systemUptime
      preparation = nil
    } catch { charge.release(); throw error }
  }
  func page(_ requested: Int, hostID: UUID, priority: NotebookTypesetter.Priority = .current,
    onAdmissionWait: @escaping (Bool) -> Void = { _ in }) async throws -> DocumentPreparedPage {
    retainPage(requested, hostID: hostID)
    try await prepare(priority: priority, onAdmissionWait: onAdmissionWait)
    guard artifact != nil, let layout else { throw DocumentSessionError.invalidLayout }
    let index = min(max(0, requested), layout.pageCount-1)
    if let cached = pages[index] { return cached }
    let reader = UUID()
    if pageOperations[index] == nil {
      let id = UUID()
      let task = Task { @MainActor [self] in
        let page = try await preparePage(index, onAdmissionWait: { _ in })
        try Task.checkCancellation()
        guard pageOperations[index]?.id == id else { throw CancellationError() }
        pages[index] = page; compiledPageCount += 1; trim()
        return page
      }
      pageOperations[index] = .init(id: id, task: task, readers: [])
    }
    pageOperations[index]!.readers.insert(reader)
    let operation = pageOperations[index]!
    onAdmissionWait(true)
    defer { onAdmissionWait(false); releasePageReader(reader, page: index, operation: operation.id) }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let page = try await DocumentPreparationSubscriber.wait(for: operation.task)
      try Task.checkCancellation()
      return page
    } onCancel: {
      Task { @MainActor [weak self] in self?.releasePageReader(reader, page: index, operation: operation.id) }
    }
  }
  private func releasePageReader(_ reader: UUID, page: Int, operation: UUID) {
    guard pageOperations[page]?.id == operation else { return }
    pageOperations[page]?.readers.remove(reader)
    guard pageOperations[page]?.readers.isEmpty == true else { return }
    // Cache ownership belongs to pages/demand. No completed task keeps a
    // second charged fragment alive after its final reader leaves.
    pageOperations[page]?.task.cancel(); pageOperations[page] = nil
  }
  private func preparePage(_ index: Int, onAdmissionWait: @escaping (Bool) -> Void) async throws -> DocumentPreparedPage {
    guard let layout else { throw DocumentSessionError.invalidLayout }
    let paper = layout.paper(on: index)
    guard let printSource, let artifact else { throw DocumentSessionError.invalidLayout }
    // Text extraction and annotation selection belong to the requested page.
    let navigation = try await printSource.pdf.perform { document, _ in
      try DocumentPrintNavigation.read(document, pages: artifact.pages, pageIndices: [index])
    }
    try Task.checkCancellation()
    let regions = layout.regions(on: index)
    let navigationBytes = navigation.links.reduce(0) { $0 + $1.href.utf8.count + $1.label.utf8.count + 128 }
      + navigation.pageText.values.reduce(0) { $0 + $1.utf8.count }
    let charge = try await resources.acquirePassiveDerivedBytes(navigationBytes + regions.count*512 + 4096, onDeferred: { onAdmissionWait(true) })
    defer { onAdmissionWait(false) }
    do { try Task.checkCancellation() } catch { charge.release(); throw error }
    let printed = DocumentPrintedPage(source: printSource, pageIndex: index, width: paper.widthPoints, height: paper.heightPoints)
    let page = DocumentPreparedPage(printed: printed, navigation: navigation,
      regions: Array(layout.regions(on: index)), reservation: charge)
    return page
  }
  /// Executable packages are materialized only for demanded program slots.
  /// They never delay publication of canonical paper.
  func preparePrograms(_ ids: Set<String>) async throws {
    if artifact == nil { try await prepare(onAdmissionWait: { _ in }) }
    guard let artifact else { return }
    let document = document, store = store
    let declared = Dictionary(artifact.interactiveRegions.map { ($0.instanceID, $0.programPath) }, uniquingKeysWith: { first, _ in first })
    var paths: Set<String> = []
    for id in ids.sorted() where !programs.contains(where: { $0.id == id }) && programFailures[id] == nil {
      guard let path = declared[id] else { continue }
      if let accepted = programSources[path] {
        programs.append(try accepted.forInstance(id)); onProgramsChanged(); continue
      }
      if let failure = programSourceFailures[path] {
        programFailures[id] = failure; onProgramsChanged(); continue
      }
      programRequests[path, default: []].insert(id); paths.insert(path)
      guard programTasks[path] == nil else { continue }
      let operation = UUID()
      let task = Task { @MainActor [weak self] in
        let producer = Task.detached(priority: .userInitiated) {
          try Task.checkCancellation()
          guard let store else { throw SceneRenderError.snapshotPending("program_store") }
          return try store.documentProgramSource(document: document, instanceID: id, path: path)
        }
        do {
          let accepted = try await withTaskCancellationHandler { try await producer.value } onCancel: { producer.cancel() }
          try Task.checkCancellation()
          guard let self, programTasks[path]?.id == operation else { return }
          programSources[path] = accepted
          for instance in programRequests.removeValue(forKey: path) ?? [] {
            programs.append(try accepted.forInstance(instance))
          }
          programTasks[path] = nil
          onProgramsChanged()
        } catch {
          guard let self, programTasks[path]?.id == operation else { throw error }
          programTasks[path] = nil
          if error is CancellationError { throw error }
          programSourceFailures[path] = error.localizedDescription
          for instance in programRequests.removeValue(forKey: path) ?? [] { programFailures[instance] = error.localizedDescription }
          onProgramsChanged()
        }
      }
      programTasks[path] = (operation, task)
    }
    // Each producer publishes independently. This wait is only the caller's
    // requested set; it does not control native installation of earlier slots.
    for path in paths.sorted() {
      if let task = programTasks[path] { try await DocumentPreparationSubscriber.wait(for: task.task) }
    }
  }

  func printedSource(priority: NotebookTypesetter.Priority) async throws -> DocumentPrintedSource {
    try await prepare(priority: priority, onAdmissionWait: { _ in })
    guard let printSource else { throw DocumentSessionError.invalidLayout }
    return printSource
  }
  func sourceOffset(fileID: String, pageIndex: Int, x: Double, y: Double) -> Int? {
    let scale = 1 / DocumentPaperLayout.pointsToSurface
    return printSource?.sourceOffset(fileID: fileID, pageIndex: pageIndex, x: x*scale, y: y*scale)
  }
  isolated deinit {
    preparation?.cancel(); pageOperations.values.forEach { $0.task.cancel() }
    programTasks.values.forEach { $0.task.cancel() }
  }
}

/// A subscriber can leave a shared print operation immediately. Its cancellation
/// does not impersonate completion of the compiler or an admitted WebKit call.
@MainActor
final class DocumentPreparationSubscriber<Value: Sendable> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var cancelled = false
  private func finish(_ result: Result<Value, Error>) {
    let continuation = continuation; self.continuation = nil
    continuation?.resume(with: result)
  }
  static func wait(for task: Task<Value, Error>) async throws -> Value {
    let reader = DocumentPreparationSubscriber()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if reader.cancelled { continuation.resume(throwing: CancellationError()); return }
        reader.continuation = continuation
        Task { @MainActor in reader.finish(await task.result) }
      }
    } onCancel: {
      Task { @MainActor in reader.cancelled = true; reader.finish(.failure(CancellationError())) }
    }
  }
}
