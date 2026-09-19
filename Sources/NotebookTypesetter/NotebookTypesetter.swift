import Foundation
import NotebookCore
import CNotebookTypesetter
import CQuickJS

public struct NotebookPrintedAsset: Codable, Sendable {
  public let name: String
  public let data: Data
}
public struct NotebookPrintedDocument: Sendable {
  public let document: DocumentDocument
  public let source: String
  public let pdf: Data
  public let syncTeX: Data
  public let sourceMap: DocumentPrintSourceMap
  public let assets: [NotebookPrintedAsset]
  public let log: String
  public let guestMemoryBytes: Int
}
public struct NotebookPrintDiagnostic: Sendable, Identifiable {
  public var id: String { "\(blockID ?? "preamble"):\(line):\(message)" }
  public let blockID: String?
  public let line: Int
  public let message: String
}
public struct NotebookTypesetterError: Error, LocalizedError, Sendable {
  public let message: String
  public let diagnostics: [NotebookPrintDiagnostic]
  public var errorDescription: String? { message }
  public init(_ message: String, diagnostics: [NotebookPrintDiagnostic] = []) { self.message = message; self.diagnostics = diagnostics }
  static func compiler(_ log: String, document: DocumentDocument, ranges: [DocumentPrintSourceRange]) -> Self {
    let pattern = try! NSRegularExpression(pattern: #"document\.tex:([0-9]+): ([^\n\r]+)"#)
    let text = log as NSString
    let diagnostics = pattern.matches(in: log, range: NSRange(location: 0, length: text.length)).prefix(32).compactMap { match -> NotebookPrintDiagnostic? in
      guard let generated = Int(text.substring(with: match.range(at: 1))) else { return nil }
      let range = ranges.first { $0.firstLine <= generated && generated <= $0.lastLine }
      let source = range.flatMap { range in document.blocks.first { $0.id == range.blockID }?.source } ?? document.preamble
      let count = source.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
      let line = min(count, max(1, generated - (range?.firstLine ?? 1) + 1))
      return .init(blockID: range?.blockID, line: line, message: text.substring(with: match.range(at: 2)))
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
  private var javascript: OpaquePointer?
  private var tex: OpaquePointer?
  func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; if let javascript { nq_cancel(javascript) }; if let tex { nb_typesetter_cancel(tex) } }
  func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() }; if ContinuousClock.now >= deadline { throw NotebookTypesetterError("typesetter_deadline") } }
  func remainingMilliseconds() throws -> UInt64 {
    try check(); let c = ContinuousClock.now.duration(to: deadline).components
    return max(1, UInt64(max(0, c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)))
  }
  func withJavaScript<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
    try check()
    // Markup is data-only. No host calls, filesystem, timers, network or eval
    // bridge are available to the normalizer.
    guard let runtime = nq_create(64*1024*1024, 1024*1024, 2, nil, nil) else { throw NotebookTypesetterError("markup_resource_limit") }
    lock.lock(); javascript = runtime; if cancelled { nq_cancel(runtime) }; lock.unlock()
    defer { lock.lock(); javascript = nil; nq_destroy(runtime); lock.unlock() }
    return try body(runtime)
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
  private var markup: String?
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
    if let runtime { nb_typesetter_destroy(runtime) }; runtime = nil; markup = nil
  }
  public func trimIdle() async {
    await withCheckedContinuation { continuation in queue.async { [self] in discardRuntime(); continuation.resume() } }
  }

  public func compile(_ document: DocumentDocument) async throws -> NotebookPrintedDocument {
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
          do { continuation.resume(returning: try autoreleasepool { try compile(document, work: work) }) }
          catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: { work.cancel() }
  }

  private struct Preparation: Decodable {
    struct Asset: Decodable { let name: String; let mediaType: String; let data: String }
    let source: String
    let sourceRanges: [DocumentPrintSourceRange]
    let assets: [Asset]
  }
  private func prepare(_ document: DocumentDocument, work: Work) throws -> Preparation {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    struct Input: Encodable { let kind = "documentTeX"; let document: DocumentDocument; let programPointScale: Double }
    let input = try encoder.encode(Input(document: document, programPointScale: document.paperSize.widthPoints / WorkspaceItemGeometry.document(document.paperSize).width))
    guard input.count <= 24*1024*1024 else { throw NotebookTypesetterError("markup_input_limit") }
    if markup == nil { markup = try String(contentsOf: resources.appendingPathComponent("notebook-markup.js"), encoding: .utf8) }
    return try work.withJavaScript { engine in
      func failure() -> NotebookTypesetterError {
        guard let value = nq_error(engine) else { return .init("markup_resource_limit") }
        defer { nq_free_string(value) }; return .init(String(cString: value))
      }
      nq_set_result_limit(engine, 24*1024*1024)
      guard nq_bootstrap(engine, markup!) == 0,
        nq_start(engine, "return notebookMarkup(args);", String(decoding: input, as: UTF8.self)) == 0 else { throw failure() }
      var result = nq_pump(engine)
      while result == 0 { try work.check(); result = nq_pump(engine) }
      guard result == 1, let raw = nq_result(engine) else { throw failure() }
      defer { nq_free_string(raw) }
      return try JSONDecoder().decode(Preparation.self, from: Data(bytes: raw, count: strlen(raw)))
    }
  }
  private func compile(_ document: DocumentDocument, work: Work) throws -> NotebookPrintedDocument {
    try work.check()
    let prepared = try prepare(document, work: work)
    try work.check()
    if runtime == nil {
      runtime = nb_typesetter_create(resources.appendingPathComponent("texlive.zip").path,
        resources.appendingPathComponent("latex.fmt").path, resources.appendingPathComponent("fonts.tsv").path)
    }
    guard let runtime else { throw NotebookTypesetterError("typesetter_resources_unavailable") }
    // Converted assets are frozen with the source before the VM starts.
    var assets: [NotebookPrintedAsset] = [], total = 0
    for asset in prepared.assets {
      try work.check()
      guard let data = Data(base64Encoded: asset.data) else { throw NotebookTypesetterError("print_image_invalid") }
      let imageSource = asset.mediaType == "image/svg+xml" ? data : try NotebookPrintImage.embeddedSVG(data, mediaType: asset.mediaType)
      let pdf = try work.withTeX { ticket in
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
      total += pdf.count
      guard total <= 8*1024*1024 else { throw NotebookTypesetterError("print_images_output_limit") }
      assets.append(.init(name: asset.name, data: pdf))
    }
    let source = Data(prepared.source.utf8)
    let names = assets.map { strdup($0.name)! }; defer { names.forEach { free($0) } }
    let buffers = assets.map { $0.data as NSData }
    let nativeAssets = assets.indices.map { NBTypesetterAsset(name: UnsafePointer(names[$0]), bytes: buffers[$0].bytes.assumingMemoryBound(to: UInt8.self), count: buffers[$0].length) }
    return try work.withTeX { ticket in
      let timeout = try work.remainingMilliseconds()
      let output = source.withUnsafeBytes { raw in
        nativeAssets.withUnsafeBufferPointer { pointers in
          nb_typesetter_compile(runtime, raw.bindMemory(to: UInt8.self).baseAddress, source.count,
            pointers.baseAddress, pointers.count, UInt64(Date().timeIntervalSince1970), timeout, ticket)
        }
      }
      guard let output else { throw NotebookTypesetterError("typesetter_output_missing") }
      defer { nb_typesetter_output_destroy(output); withExtendedLifetime(buffers) {} }
      func bytes(_ kind: UInt32) -> Data {
        var count = 0; let pointer = nb_typesetter_output_bytes(output, kind, &count)
        return count > 0 ? Data(bytes: pointer!, count: count) : Data()
      }
      let error = bytes(3)
      guard error.isEmpty else { throw NotebookTypesetterError.compiler(String(decoding: error, as: UTF8.self), document: document, ranges: prepared.sourceRanges) }
      try work.check()
      let pdf = bytes(0), syncTeX = bytes(1)
      return .init(document: document, source: prepared.source, pdf: pdf, syncTeX: syncTeX,
        sourceMap: try .init(document: document, source: prepared.source, pdf: pdf, ranges: prepared.sourceRanges),
        assets: assets, log: String(decoding: bytes(2), as: UTF8.self), guestMemoryBytes: nb_typesetter_output_memory(output))
    }
  }
}
