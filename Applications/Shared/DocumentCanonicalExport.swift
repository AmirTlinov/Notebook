#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
import NotebookCore
import NotebookTypesetter
import PDFKit

/// Export reads the same ready print artifact as paper. Only live program
/// rectangles are frozen as images; all typeset text, paths and links remain
/// vector PDF, at their already installed physical coordinates.
@MainActor enum DocumentCanonicalExport {
  static func publish(cut: NotebookExportCut, options: NotebookExportOptions = .init(), jobID: UUID, store: NotebookStore, persistence: NotebookPersistenceQueue) async throws -> NotebookExportReceipt {
    let publication = try await publication(cut: cut, options: options, jobID: jobID, store: store, persistence: persistence)
    let preparation = Task.detached(priority: .utility) { try store.prepareDocumentExport(publication) }
    let prepared = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
    try Task.checkCancellation()
    // Once the final fence is accepted, its durable receipt wins over a late
    // cancellation. No byte copying or hashing occupies this writer slot.
    return try await persistence.submit { try $0.publishDocumentExport(prepared) }
  }

  static func publication(cut: NotebookExportCut, options: NotebookExportOptions = .init(), jobID: UUID, store: NotebookStore, persistence: NotebookPersistenceQueue) async throws -> NotebookExportPublication {
    try Task.checkCancellation()
    try options.validate()
    let document = cut.document, state = cut.state
    // A saved export never borrows an uncommitted live frame with an equal
    // journal token, and never checkpoints or rewinds the user's executor.
    let programs = Set(document.blocks.filter { $0.kind == .interactive }.map(\.id))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-export-" + jobID.uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    if options.format == .html {
      guard let block = document.blocks.first(where: { $0.id == options.blockID && $0.kind == .interactive }) else {
        throw CollaborationError("export_block_missing", "HTML экспортирует явно выбранную программу.")
      }
      let html = try NotebookStandaloneExport.document(block: block, state: state.value(for: block.id) ?? block.initialState)
      let file = try await stage(html, path: "document.html", directory: directory, persistence: persistence)
      return .init(cut: cut, source: "", artifact: file, log: "Standalone NotebookProgram/1: saved state, isolated offline iframe", options: options, jobID: jobID)
    }
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    if options.format == .svg {
      guard let block = document.blocks.first(where: { $0.id == options.blockID && $0.kind == .interactive }) else {
        throw CollaborationError("export_block_missing", "SVG exportFrame принадлежит явно названной программе.")
      }
      let locations = try await Task.detached { try artifact.locations() }.value
      guard let page = locations.first(where: { $0.blockID == block.id })?.pageIndex else {
        throw CollaborationError("export_block_missing", "Программы нет в принятом печатном макете.")
      }
      let svg = try await DocumentSnapshotCache.shared.exportSVG(document: document, state: state, block: block,
        pageIndex: page, programStore: store, isolationID: jobID)
      let file = try await stage(Data(svg.utf8), path: "document.svg", directory: directory, persistence: persistence)
      return .init(cut: cut, source: "", artifact: file, log: artifact.log, options: options, jobID: jobID)
    }
    if options.format == .png {
      let pageIndex = options.pageIndex ?? 0, width = options.pixelWidth ?? 1600
      let pages = try await Task.detached {
        guard let provider = CGDataProvider(data: artifact.pdf as CFData), let pdf = CGPDFDocument(provider) else { throw SceneRenderError.resourceLimit }
        return pdf.numberOfPages
      }.value
      guard pageIndex < pages else { throw CollaborationError("export_page_missing", "Такой страницы нет в принятом печатном макете.") }
      let raster = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: pageIndex,
        programStore: store, isolationID: jobID, pixelWidth: width)
      defer { raster.release() }
      var rect = CGRect(origin: .zero, size: raster.image.size)
      guard let image = raster.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw SceneRenderError.resourceLimit }
      guard image.width == width else { throw SceneRenderError.snapshotPending("export_pixel_extent") }
      let url = directory.appendingPathComponent("document.png")
      let encode = Task.detached(priority: .utility) {
        try Task.checkCancellation()
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw SceneRenderError.resourceLimit }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SceneRenderError.snapshotPending("export_png_encoding") }
        try Task.checkCancellation()
      }
      try await withTaskCancellationHandler { try await encode.value } onCancel: { encode.cancel() }
      let file = try await stage(url, path: "document.png", persistence: persistence)
      return .init(cut: cut, source: "", artifact: file, log: artifact.log, options: options, jobID: jobID)
    }
    let pdfURL = directory.appendingPathComponent("document.pdf")
    if !programs.isEmpty {
      let composer = try await PrintedPDFComposer.open(artifact.pdf, outputURL: pdfURL)
      let mapped = try await Task.detached { try artifact.locations().filter { programs.contains($0.blockID) } }.value
      let byPage = Dictionary(grouping: mapped, by: \.pageIndex)
      for pageIndex in 0..<composer.pageCount {
        try Task.checkCancellation()
        let locations = byPage[pageIndex] ?? []
        if locations.isEmpty { try await composer.append(pageIndex: pageIndex, image: nil, regions: []); continue }
        let raster = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: pageIndex,
          programStore: store, isolationID: jobID)
        defer { raster.release() }
        var rect = CGRect(origin: .zero, size: raster.image.size)
        guard let image = raster.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw SceneRenderError.resourceLimit }
        var regions: [CGRect] = []
        for group in Dictionary(grouping: locations, by: \.blockID).values {
          regions.append(group.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) })
        }
        try await composer.append(pageIndex: pageIndex, image: image, regions: regions)
      }
      try await composer.finish()
    }
    else { try await Task.detached { try artifact.pdf.write(to: pdfURL) }.value }
    let pdf = try await stage(pdfURL, path: "document.pdf", persistence: persistence)
    var assets: [NotebookExportFile] = []
    for asset in artifact.assets {
      assets.append(try await stage(asset.data, path: asset.name, directory: directory, persistence: persistence))
    }
    let syncTeX = try await stage(artifact.syncTeX, path: "document.synctex.gz", directory: directory, persistence: persistence)
    let map = try DocumentPrintSourceMap(document: document, source: artifact.source, pdfSHA256: pdf.sha256, ranges: artifact.sourceMap.ranges)
    return .init(cut: cut, source: artifact.source, artifact: pdf, log: artifact.log, options: options, jobID: jobID,
      assets: assets, sourceMap: map, syncTeX: syncTeX)
  }

  private static func stage(_ data: Data, path: String, directory: URL, persistence: NotebookPersistenceQueue) async throws -> NotebookExportFile {
    let url = directory.appendingPathComponent(path)
    try await Task.detached(priority: .utility) { try data.write(to: url) }.value
    return try await stage(url, path: path, persistence: persistence)
  }
  static func stage(_ url: URL, path: String, persistence: NotebookPersistenceQueue) async throws -> NotebookExportFile {
    let inspection = Task.detached(priority: .utility) { try NotebookExportFile.inspect(url, path: path) }
    let file = try await withTaskCancellationHandler { try await inspection.value } onCancel: { inspection.cancel() }
    var offset: Int64 = 0
    for part in file.file.parts {
      try Task.checkCancellation()
      let range = offset..<(offset+Int64(part.byteCount))
      try await persistence.submit { try $0.stageBlob(file: url, expectedHash: part.sha256, byteCount: Int64(part.byteCount), range: range) }
      offset = range.upperBound
      await Task.yield()
    }
    return file
  }
}

/// The queue owns Quartz for the complete composition; at most one admitted
/// page raster crosses it at a time. No source is typeset again here.
final class PrintedPDFComposer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "Notebook.print-export")
  private let queueKey = DispatchSpecificKey<Bool>()
  private let source: Data
  private var input: CGPDFDocument?
  private var links: PDFDocument?
  private var context: CGContext?
  private var destinations: [Int: [(name: String, point: CGPoint)]] = [:]
  private var linkNames: [Int: [Int: String]] = [:]
  private let output: PrintedPDFSink
  private(set) var pageCount = 0
  private init(_ source: Data, outputURL: URL) throws {
    self.source = source; output = try PrintedPDFSink(url: outputURL); queue.setSpecific(key: queueKey, value: true)
  }
  deinit {
    let context = context, input = input, links = links
    let close = { context?.closePDF(); withExtendedLifetime(input) {}; withExtendedLifetime(links) {} }
    if DispatchQueue.getSpecific(key: queueKey) == true { close() } else { queue.sync(execute: close) }
  }
  static func open(_ source: Data, outputURL: URL) async throws -> PrintedPDFComposer {
    let owner = try PrintedPDFComposer(source, outputURL: outputURL)
    try await owner.perform {
      guard let provider = CGDataProvider(data: source as CFData), let document = CGPDFDocument(provider),
        let consumer = owner.output.consumer(), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
        throw SceneRenderError.resourceLimit
      }
      owner.input = document; owner.links = PDFDocument(data: source); owner.context = context; owner.pageCount = document.numberOfPages
      if let links = owner.links {
        for pageIndex in 0..<links.pageCount {
          for (annotationIndex, annotation) in (links.page(at: pageIndex)?.annotations ?? []).enumerated() {
            guard let target = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination,
              let page = target.page else { continue }
            let index = links.index(for: page), name = "notebook-link-\(pageIndex)-\(annotationIndex)"
            let box = page.bounds(for: .mediaBox), targetPoint = target.point
            let point = CGPoint(x: min(box.maxX, max(box.minX, targetPoint.x)), y: min(box.maxY, max(box.minY, targetPoint.y)))
            guard point.x.isFinite, point.y.isFinite, annotationIndex < 16_384 else { throw SceneRenderError.resourceLimit }
            owner.destinations[index, default: []].append((name, point))
            owner.linkNames[pageIndex, default: [:]][annotationIndex] = name
          }
        }
      }
    }
    return owner
  }
  private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in queue.async {
      do { continuation.resume(returning: try autoreleasepool(invoking: body)) } catch { continuation.resume(throwing: error) }
    } }
  }
  func append(pageIndex: Int, image: CGImage?, regions: [CGRect]) async throws {
    try await perform { [self] in
      guard let page = input?.page(at: pageIndex+1), let context else { throw SceneRenderError.resourceLimit }
      let box = page.getBoxRect(.mediaBox)
      context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [box], length: MemoryLayout<CGRect>.size)] as CFDictionary)
      context.drawPDFPage(page)
      if let image {
        for region in regions {
          let physical = CGRect(x: region.minX, y: box.height-region.maxY, width: region.width, height: region.height)
          context.saveGState(); context.clip(to: physical)
          context.draw(image, in: box); context.restoreGState()
        }
      }
      if let original = links?.page(at: pageIndex) {
        for target in destinations[pageIndex] ?? [] { context.addDestination(target.name as CFString, at: target.point) }
        for (annotationIndex, annotation) in original.annotations.enumerated() {
          if let action = annotation.action as? PDFActionURL, let url = action.url { context.setURL(url as CFURL, for: annotation.bounds) }
          else if let name = linkNames[pageIndex]?[annotationIndex] {
            context.setDestination(name as CFString, for: annotation.bounds)
          }
        }
      }
      context.endPDFPage()
      try output.check()
    }
  }
  func finish() async throws {
    try await perform { [self] in
      context?.closePDF(); context = nil; input = nil; links = nil
      try output.check()
      try output.finish()
    }
  }
}
/// Quartz writes straight to a private regular file. The callback retains no
/// PDF bytes and records short writes/disk errors instead of publishing a prefix.
private final class PrintedPDFSink {
  private var fd: Int32
  private var error: Error?
  private var size: Int64 = 0
  init(url: URL) throws {
    fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    if fd < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
  deinit { if fd >= 0 { Darwin.close(fd) } }
  func consumer() -> CGDataConsumer? {
    var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
      guard let info else { return 0 }
      return Unmanaged<PrintedPDFSink>.fromOpaque(info).takeUnretainedValue().write(buffer, count: count)
    }, releaseConsumer: { info in
      if let info { Unmanaged<PrintedPDFSink>.fromOpaque(info).release() }
    })
    let info = Unmanaged.passRetained(self).toOpaque()
    guard let consumer = CGDataConsumer(info: info, cbks: &callbacks) else { Unmanaged<PrintedPDFSink>.fromOpaque(info).release(); return nil }
    return consumer
  }
  private func write(_ buffer: UnsafeRawPointer, count: Int) -> Int {
    guard error == nil, size+Int64(count) <= Int64(NotebookProgramPackage.partBytes)*16_384 else {
      if error == nil { error = NotebookStorageError.limitExceeded("export parts") }; return 0
    }
    var offset = 0
    while offset < count {
      let written = Darwin.write(fd, buffer.advanced(by: offset), count-offset)
      if written < 0 && errno == EINTR { continue }
      if written <= 0 { error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO); return offset }
      offset += written; size += Int64(written)
    }
    return offset
  }
  func check() throws { if let error { throw error } }
  func finish() throws {
    try check()
    guard size > 0, fd >= 0 else { throw SceneRenderError.resourceLimit }
    let result = Darwin.close(fd); fd = -1
    if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
}
#endif
