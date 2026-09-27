import Foundation
import NotebookCore
import CNotebookTypesetter
import CoreGraphics
import CryptoKit

public struct NotebookPrintedAsset: Codable, Sendable {
  public let name: String
  public let data: Data
}
public struct NotebookPrintedDocument: Sendable {
  public var buildID: String {
    SHA256.hash(data: Data((sourceMap.documentSHA256+sourceMap.inputSHA256+sourceMap.pdfSHA256).utf8)+interactiveMap).map { String(format: "%02x", $0) }.joined()
  }
  public let document: DocumentDocument
  public let source: String
  public let pdf: Data
  public let syncTeX: Data
  public let sourceMap: DocumentPrintSourceMap
  public let assets: [NotebookPrintedAsset]
  public let interactiveMap: Data
  public let pages: [DocumentPrintPage]
  public let interactiveRegions: [DocumentPrintInteractiveRegion]
  public let diagnostics: [NotebookPrintDiagnostic]
  public let log: String
  public let guestMemoryBytes: Int
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

/// Cancellation is the only operation allowed across the serial compiler
/// queue. The lock fences destruction against the cancellation callback.
private final class Work: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private let deadline = ContinuousClock.now + .seconds(30)
  private var tex: OpaquePointer?
  func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; if let tex { nb_typesetter_cancel(tex) } }
  func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() }; if ContinuousClock.now >= deadline { throw NotebookTypesetterError("typesetter_deadline") } }
  func remainingMilliseconds() throws -> UInt64 {
    try check(); let c = ContinuousClock.now.duration(to: deadline).components
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
  private var idleGeneration: UInt64 = 0
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

  public func compile(_ document: DocumentDocument, input: NotebookTypesetterInput? = nil) async throws -> NotebookPrintedDocument {
    let input = try input ?? NotebookTypesetterInput(document: document)
    try input.validate(document: document)
    return try await perform { try self.compile(document, input: input, work: $0) }
  }
  /// Same bounded data-only SVG kernel as canonical document images. No TeX,
  /// layout, JavaScript or second compiler is created for an export overlay.
  public func convertSVG(_ data: Data) async throws -> Data {
    try await perform { try self.convertSVG(data, work: $0) }
  }
  private func perform<T: Sendable>(_ operation: @escaping @Sendable (Work) throws -> T) async throws -> T {
    let work = Work()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          idleGeneration &+= 1
          let generation = idleGeneration
          defer {
            queue.asyncAfter(deadline: .now()+15) { [weak self] in
              guard let self, self.idleGeneration == generation else { return }
              self.discardRuntime()
            }
          }
          do { continuation.resume(returning: try autoreleasepool { try operation(work) }) }
          catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { work.cancel() }
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

  private func compile(_ document: DocumentDocument, input: NotebookTypesetterInput, work: Work) throws -> NotebookPrintedDocument {
    try work.check()
    let runtime = try preparedRuntime()
    let names = input.files.map { strdup($0.path)! }; defer { names.forEach { free($0) } }
    let buffers = input.files.map { $0.data as NSData }
    let nativeFiles = input.files.indices.map { NBTypesetterFile(name: UnsafePointer(names[$0]),
      bytes: buffers[$0].bytes.assumingMemoryBound(to: UInt8.self), count: buffers[$0].length) }
    return try work.withTeX { ticket in
      let timeout = try work.remainingMilliseconds()
      let output = nativeFiles.withUnsafeBufferPointer { pointers in
        nb_typesetter_compile(runtime, input.entrypoint, pointers.baseAddress, pointers.count,
          UInt64(Date().timeIntervalSince1970), timeout, ticket)
      }
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
      var diagnostics = NotebookTypesetterError.compiler(log, document: document).diagnostics
      for path in Set(regions.map(\.programPath)).sorted() where !input.files.contains(where: { $0.path == path || $0.path.hasPrefix(path+"/") }) {
        let file = document.files.first { $0.resource == nil && $0.source.contains("{"+path+"}") }
        let offset = file.map { ($0.source as NSString).range(of: "{"+path+"}").location } ?? 0
        diagnostics.append(.init(fileID: file?.id, path: file?.path,
          line: file.map { DocumentPrintLocations.line(sourceOffset: offset, source: $0.source) } ?? 1,
          message: "Файлы программы не найдены: \(path)"))
      }
      return .init(document: document, source: source, pdf: pdf, syncTeX: syncTeX,
        sourceMap: sourceMap,
        assets: input.files.filter { $0.path != input.entrypoint }.map { .init(name: $0.path, data: $0.data) },
        interactiveMap: map, pages: pages, interactiveRegions: regions, diagnostics: diagnostics,
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
