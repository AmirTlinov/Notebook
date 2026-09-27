import Foundation
import NotebookCore
import CNotebookTypesetter
import CoreGraphics
import CryptoKit

public final class NotebookPrintedDocument: Sendable {
  public var buildID: String {
    SHA256.hash(data: Data((sourceMap.documentSHA256+sourceMap.inputSHA256+sourceMap.pdfSHA256).utf8)+interactiveMap).map { String(format: "%02x", $0) }.joined()
  }
  public let document: DocumentDocument
  public let source: String
  public let pdf: Data
  public let syncTeX: Data
  public let sourceMap: DocumentPrintSourceMap
  public let interactiveMap: Data
  public let pages: [DocumentPrintPage]
  public let projection: DocumentPrintProjection
  public let dependencies: DocumentPrintDependencies
  public var interactiveRegions: [DocumentPrintInteractiveRegion] { projection.interactiveRegions }
  public var pixelIdentity: String { sourceMap.pdfSHA256 }
  public let diagnostics: [NotebookPrintDiagnostic]
  public let log: String
  public let guestMemoryBytes: Int
  init(document: DocumentDocument, source: String, pdf: Data, syncTeX: Data,
    sourceMap: DocumentPrintSourceMap, interactiveMap: Data, pages: [DocumentPrintPage],
    projection: DocumentPrintProjection, dependencies: DocumentPrintDependencies,
    diagnostics: [NotebookPrintDiagnostic], log: String, guestMemoryBytes: Int) {
    self.document = document; self.source = source; self.pdf = pdf; self.syncTeX = syncTeX
    self.sourceMap = sourceMap; self.interactiveMap = interactiveMap; self.pages = pages
    self.projection = projection; self.dependencies = dependencies; self.diagnostics = diagnostics
    self.log = log; self.guestMemoryBytes = guestMemoryBytes
  }

}
public struct NotebookPrintDiagnostic: Codable, Sendable, Identifiable {
  public var id: String { "\(path ?? "document"):\(line):\(message)" }
  public let fileID: String?
  public let path: String?
  public let line: Int
  public let severity: String
  public let message: String
  public init(fileID: String? = nil, path: String? = nil, line: Int = 1, severity: String = "error", message: String) {
    self.fileID = fileID; self.path = path; self.line = line; self.severity = severity; self.message = message
  }
}
public struct NotebookTypesetterError: Error, LocalizedError, Sendable {
  public let message: String
  public let diagnostics: [NotebookPrintDiagnostic]
  public var errorDescription: String? { message }
  public init(_ message: String, diagnostics: [NotebookPrintDiagnostic] = []) { self.message = message; self.diagnostics = diagnostics }
  static func compiler(_ log: String, document: DocumentDocument) -> Self {
    let pattern = try! NSRegularExpression(pattern: #"(?:/input/)?([A-Za-z0-9_@./-]+):([0-9]+): ?([^\n\r]+)"#)
    let text = log as NSString
    let diagnostics = pattern.matches(in: log, range: NSRange(location: 0, length: text.length)).prefix(64).compactMap { match -> NotebookPrintDiagnostic? in
      var path = text.substring(with: match.range(at: 1))
      if path.hasPrefix("/input/") { path.removeFirst(7) }
      if path.hasPrefix("./") { path.removeFirst(2) }
      guard let line = Int(text.substring(with: match.range(at: 2))) else { return nil }
      let file = document.files.first { $0.path == path }
      let prefix = text.substring(with: NSRange(location: max(0, match.range.location-12), length: min(12, match.range.location)))
      return .init(fileID: file?.id, path: path, line: max(1, line), severity: prefix.contains("warning:") ? "warning" : "error",
        message: text.substring(with: match.range(at: 3)))
    }
    return .init(log, diagnostics: diagnostics)
  }
}

/// Shared source readers can promote a queued compile when a speculative
/// page becomes current. This does not create or preempt a physical engine.
public final class NotebookTypesetterDemand: @unchecked Sendable {
  private let lock = NSLock()
  private var priority: NotebookTypesetter.Priority
  private weak var shared: NotebookTypesetterDemand?
  private var phasesMS: [String: Double] = [:]
  private var sharesMeasurement = false
  public init(priority: NotebookTypesetter.Priority) { self.priority = priority }
  var current: NotebookTypesetter.Priority { lock.lock(); defer { lock.unlock() }; return priority }
  /// Request phases feed the existing document presentation measurement. They
  /// describe this request, never the compilation that originally filled disk.
  public var preparationPhasesMS: [String: Double] {
    lock.lock(); let local = phasesMS, producer = sharesMeasurement ? shared : nil; lock.unlock()
    return (producer?.preparationPhasesMS ?? [:]).merging(local) { _, reader in reader }
  }
  func beginMeasurement() { lock.lock(); phasesMS = [:]; sharesMeasurement = false; lock.unlock() }
  func finishMeasurement() {
    let measured = preparationPhasesMS
    lock.lock(); phasesMS = measured; sharesMeasurement = false; lock.unlock()
  }
  func record(_ phase: String, since start: ContinuousClock.Instant) {
    let elapsed = start.duration(to: .now).components
    record(phase, milliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
  }
  func record(_ phase: String, milliseconds: Double) {
    lock.lock(); phasesMS[phase] = milliseconds; lock.unlock()
  }
  public func promote(to value: NotebookTypesetter.Priority) {
    lock.lock(); if value.rawValue < priority.rawValue { priority = value }; let shared = shared; lock.unlock()
    shared?.promote(to: value)
  }
  func beginJob() { lock.lock(); shared = nil; sharesMeasurement = false; lock.unlock() }
  func join(_ shared: NotebookTypesetterDemand) {
    guard shared !== self else { return }
    lock.lock(); self.shared = shared; sharesMeasurement = true; let current = priority; lock.unlock()
    shared.promote(to: current)
  }
}

/// Cancellation is the only operation allowed across the serial compiler
/// queue. The lock fences destruction against the cancellation callback.
private final class Work: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var deadline: ContinuousClock.Instant?
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func begin() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() }; deadline = .now + .seconds(30) }
  private var tex: OpaquePointer?
  func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; if let tex { nb_typesetter_cancel(tex) } }
  func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() }; if let deadline, ContinuousClock.now >= deadline { throw NotebookTypesetterError("typesetter_deadline") } }
  func remainingMilliseconds() throws -> UInt64 {
    try check(); lock.lock(); let deadline = deadline!; lock.unlock()
    let c = ContinuousClock.now.duration(to: deadline).components
    return max(1, UInt64(max(0, c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)))
  }
  func withTeX<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try check()
    guard let ticket = nb_typesetter_cancel_create() else { throw NotebookTypesetterError("typesetter_resource_limit") }
    lock.lock(); tex = ticket; if cancelled { nb_typesetter_cancel(ticket) }; lock.unlock()
    defer { lock.lock(); tex = nil; nb_typesetter_cancel_destroy(ticket); lock.unlock() }
    return try body(ticket)
  }
}

/// Both app surfaces and export ask this executor for the same immutable
/// snapshot. No camera or page navigation is an input to compilation.
public final class NotebookTypesetter: @unchecked Sendable {
  private let queue = DispatchQueue(label: "Notebook.canonical-typesetter", qos: .userInitiated)
  private let resources: URL
  // Accessed only on queue; the engine itself admits one fixed-memory VM.
  private var runtime: OpaquePointer?
  /// One physical engine; queued work has no VM or deadline until admission.
  public enum Priority: Int, Sendable { case current = 0, anticipated = 1, background = 2, export = 3 }
  private struct Pending: @unchecked Sendable {
    let id: UUID; let demand: NotebookTypesetterDemand; let order: UInt64
    let run: @Sendable () -> Void; let cancel: @Sendable () -> Void
  }
  private let admission = NSLock()
  private var pending: [Pending] = []
  private var running = false
  private var sequence: UInt64 = 0
  private var preferredAdmissions = 0
  private var pressure: DispatchSourceMemoryPressure?
  public init(resources: URL) {
    self.resources = resources
    let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
    pressure.setEventHandler { [weak self] in self?.discardRuntime() }
    pressure.resume(); self.pressure = pressure
  }
  deinit { pressure?.cancel(); if let runtime { nb_typesetter_destroy(runtime) } }
  private func discardRuntime() {
    if let runtime { nb_typesetter_destroy(runtime) }; runtime = nil
  }
  public func trimIdle() async {
    await withCheckedContinuation { continuation in queue.async { [self] in discardRuntime(); continuation.resume() } }
  }

  public func compile(_ document: DocumentDocument, input: NotebookTypesetterInput? = nil, priority: Priority = .current, demand: NotebookTypesetterDemand? = nil) async throws -> NotebookPrintedDocument {
    let demand = demand ?? .init(priority: priority), inputStart = ContinuousClock.now
    let input = try input ?? NotebookTypesetterInput(document: document)
    try input.validate(document: document)
    demand.record("inputValidation", since: inputStart)
    let queuedAt = ContinuousClock.now
    return try await perform(demand: demand) { work in
      demand.record("queue", since: queuedAt)
      return try self.compile(document, input: input, work: work, demand: demand)
    }
  }
  /// Same bounded data-only SVG kernel as canonical document images. No TeX,
  /// layout, JavaScript or second compiler is created for an export overlay.
  public func convertSVG(_ data: Data, priority: Priority = .current) async throws -> Data {
    try await perform(demand: .init(priority: priority)) { try self.convertSVG(data, work: $0) }
  }
  private func perform<T: Sendable>(demand: NotebookTypesetterDemand, _ operation: @escaping @Sendable (Work) throws -> T) async throws -> T {
    let work = Work(), id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        admission.lock()
        if work.isCancelled { admission.unlock(); continuation.resume(throwing: CancellationError()); return }
        // The store also bounds shared document requests. This cap includes
        // direct SVG/export callers and fails before retaining unbounded input.
        guard pending.count < 32 else { admission.unlock(); continuation.resume(throwing: NotebookTypesetterError("typesetter_queue_full")); return }
        sequence &+= 1
        pending.append(.init(id: id, demand: demand, order: sequence, run: {
          do { try work.begin(); continuation.resume(returning: try autoreleasepool { try operation(work) }) }
          catch { continuation.resume(throwing: error) }
        }, cancel: { continuation.resume(throwing: CancellationError()) }))
        let start = !running
        if start { running = true }
        admission.unlock()
        if start { queue.async { [self] in runNext() } }
      }
    } onCancel: { [self] in
      work.cancel()
      admission.lock()
      let index = pending.firstIndex { $0.id == id }
      let removed = index.map { pending.remove(at: $0) }
      admission.unlock()
      removed?.cancel()
    }
  }
  private func runNext() {
    admission.lock()
    guard !pending.isEmpty else { running = false; admission.unlock(); return }
    // A bounded burst of visible work may pass exports, but cannot starve them.
    let oldest = pending.indices.min { pending[$0].order < pending[$1].order }!
    let preferred = pending.indices.min {
      pending[$0].demand.current.rawValue == pending[$1].demand.current.rawValue
        ? pending[$0].order < pending[$1].order
        : pending[$0].demand.current.rawValue < pending[$1].demand.current.rawValue
    }!
    let index = preferredAdmissions >= 8 ? oldest : preferred
    preferredAdmissions = index == oldest ? 0 : preferredAdmissions + 1
    let item = pending.remove(at: index)
    admission.unlock()
    item.run()
    queue.async { [self] in runNext() }
  }

  private func preparedRuntime() throws -> OpaquePointer {
    if runtime == nil {
      runtime = nb_typesetter_create(resources.appendingPathComponent("texlive.zip").path,
        resources.appendingPathComponent("latex.fmt").path, resources.appendingPathComponent("fonts.tsv").path)
    }
    guard let runtime else { throw NotebookTypesetterError("typesetter_resources_unavailable") }
    return runtime
  }
  private func convertSVG(_ imageSource: Data, work: Work) throws -> Data {
    try work.check()
    guard !imageSource.isEmpty, imageSource.count <= 8*1024*1024 else { throw NotebookTypesetterError("print_image_input_limit") }
    let runtime = try preparedRuntime()
    return try work.withTeX { ticket in
      let timeout = try work.remainingMilliseconds()
      let output = imageSource.withUnsafeBytes { raw in nb_typesetter_svg(runtime,
        raw.bindMemory(to: UInt8.self).baseAddress, imageSource.count, timeout, ticket) }
      guard let output else { throw NotebookTypesetterError("print_image_failed") }
      defer { nb_typesetter_output_destroy(output) }
      var count = 0
      let error = nb_typesetter_output_bytes(output, 3, &count)!
      guard count == 0 else { throw NotebookTypesetterError(String(decoding: UnsafeBufferPointer(start: error, count: count), as: UTF8.self)) }
      let bytes = nb_typesetter_output_bytes(output, 0, &count)!
      return Data(bytes: bytes, count: count)
    }
  }

  private func compile(_ document: DocumentDocument, input: NotebookTypesetterInput, work: Work, demand: NotebookTypesetterDemand) throws -> NotebookPrintedDocument {
    try work.check()
    let runtimeStart = ContinuousClock.now
    let runtime = try preparedRuntime()
    demand.record("runtime", since: runtimeStart)
    let bridgeStart = ContinuousClock.now
    let names = input.files.map { strdup($0.path)! }; defer { names.forEach { free($0) } }
    let buffers = input.files.map { $0.data as NSData }
    let nativeFiles = input.files.indices.map { NBTypesetterFile(name: UnsafePointer(names[$0]),
      bytes: buffers[$0].bytes.assumingMemoryBound(to: UInt8.self), count: buffers[$0].length) }
    demand.record("inputBridge", since: bridgeStart)
    return try work.withTeX { ticket in
      let timeout = try work.remainingMilliseconds()
      let nativeStart = ContinuousClock.now
      let output = nativeFiles.withUnsafeBufferPointer { pointers in
        nb_typesetter_compile(runtime, input.entrypoint, pointers.baseAddress, pointers.count,
          UInt64(Date().timeIntervalSince1970), timeout, ticket)
      }
      demand.record("native", since: nativeStart)
      let outputStart = ContinuousClock.now
      defer { demand.record("output", since: outputStart) }
      guard let output else { throw NotebookTypesetterError("typesetter_output_missing") }
      defer { nb_typesetter_output_destroy(output); withExtendedLifetime(buffers) {} }
      func bytes(_ kind: UInt32) -> Data {
        var count = 0; let pointer = nb_typesetter_output_bytes(output, kind, &count)
        return count > 0 ? Data(bytes: pointer!, count: count) : Data()
      }
      let error = bytes(3)
      guard error.isEmpty else { throw NotebookTypesetterError.compiler(String(decoding: error, as: UTF8.self), document: document) }
      try work.check()
      let pdf = bytes(0), syncTeX = bytes(1)
      let pages = try Self.pages(pdf)
      let source = String(decoding: input.files.first { $0.path == input.entrypoint }!.data, as: UTF8.self)
      let revision = try String(contentsOf: resources.appendingPathComponent("revision.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
      let sourceMap = try DocumentPrintSourceMap(document: document, source: source, pdf: pdf, compilerRevision: revision)
      let projection = try NotebookPrintedDocument.projection(syncTeX: syncTeX, files: sourceMap.files, pages: pages)
      let regions = projection.interactiveRegions
      let map = try NotebookPrintedDocument.regionMap(regions)
      let log = String(decoding: bytes(2), as: UTF8.self)
      let diagnostics = NotebookTypesetterError.compiler(log, document: document).diagnostics
      return .init(document: document, source: source, pdf: pdf, syncTeX: syncTeX,
        sourceMap: sourceMap,
        interactiveMap: map, pages: pages, projection: projection,
        dependencies: try DocumentPrintDependencies(records: bytes(4), document: document, compilerRevision: revision), diagnostics: diagnostics,
        log: log, guestMemoryBytes: nb_typesetter_output_memory(output))
    }
  }
  static func pages(_ pdf: Data) throws -> [DocumentPrintPage] {
    guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
      (1...4096).contains(document.numberOfPages) else { throw NotebookTypesetterError("typesetter_pdf_invalid") }
    return try (1...document.numberOfPages).map { index in
      guard let page = document.page(at: index) else { throw NotebookTypesetterError("typesetter_pdf_invalid") }
      let box = page.getBoxRect(.mediaBox)
      guard page.rotationAngle % 90 == 0, [box.minX, box.minY].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
        [box.width, box.height].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1_000_000 }) else {
        throw NotebookTypesetterError("typesetter_page_geometry_invalid")
      }
      return .init(mediaBoxX: box.minX, mediaBoxY: box.minY, mediaBoxWidth: box.width, mediaBoxHeight: box.height, rotation: Int(page.rotationAngle))
    }
  }
}
