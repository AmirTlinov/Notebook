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
/// rectangles are frozen as images with optional authored vector replacements;
/// all typeset text, paths and links remain
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
    try options.validate(cut: cut)
    let document = cut.document, state = cut.state
    // A saved export never borrows an uncommitted live frame with an equal
    // journal token, and never checkpoints or rewinds the user's executor.
    let programs = Set(document.blocks.filter { $0.kind == .interactive }.map(\.id))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-export-" + jobID.uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    if options.format == .png, let image = cut.presented?.image {
      let file = try await stage(image.png, path: "document.png", directory: directory, persistence: persistence)
      return .init(cut: cut, source: "", artifact: file,
        log: "Exact submitted presentation crop; original pixels/extent; no WebKit, checkpoint, rescale or cache read", options: options, jobID: jobID)
    }
    if options.format == .package {
      let prepare = Task.detached(priority: .utility) {
        let packages = try Set(document.blocks.compactMap(\.programPackage)).sorted().map { hash in
          try NotebookPortableDocument.Package(sha256: hash, value: store.readProgramPackage(hash))
        }
        let portable = NotebookPortableDocument(cut: cut, packages: packages)
        return (try portable.data(), try portable.blobs())
      }
      let (data, assets) = try await withTaskCancellationHandler { try await prepare.value } onCancel: { prepare.cancel() }
      let file = try await stage(data, path: "document.package", directory: directory, persistence: persistence)
      return .init(cut: cut, source: "", artifact: file, log: "NotebookPortable/1: copy the entire directory; submit document.package to import", options: options, jobID: jobID, assets: assets)
    }
    if options.format == .html {
      guard let block = document.blocks.first(where: { $0.id == options.blockID && $0.kind == .interactive }) else {
        throw CollaborationError("export_block_missing", "HTML экспортирует явно выбранную программу.")
      }
      let html = try NotebookStandaloneExport.document(block: block, state: state.value(for: block.id) ?? block.initialState)
      let file = try await stage(html, path: "document.html", directory: directory, persistence: persistence)
      return .init(cut: cut, source: "", artifact: file, log: "Standalone NotebookProgram/1: immutable cut state, isolated offline iframe", options: options, jobID: jobID)
    }
    // The export owns this immutable source through the last composed page.
    // Each page still gets an isolated program heap, but never reopens/redecodes
    // the whole PDF, SyncTeX and navigation after its predecessor retires.
    let printSession: DocumentRenderSession? = options.format != .pdf || !programs.isEmpty
      ? DocumentRenderSession(documentID: document.id) : nil
    let printSource = printSession?.source(document)
    let printed = try await printSource?.printedSource(resources: .shared)
    defer { withExtendedLifetime((printSession, printSource, printed)) {} }
    let artifact: NotebookPrintedDocument
    if let printed { artifact = printed.artifact }
    else { artifact = try await DocumentCanonicalPrint.store.artifact(for: document) }
    if options.format == .mp4 {
      guard document.blocks.contains(where: { $0.id == options.blockID && $0.kind == .interactive }) else {
        throw CollaborationError("export_block_missing", "Видео требует явно выбранную программу.")
      }
      guard let printed, let printSession else { throw DocumentSessionError.invalidLayout }
      let locations = printed.locations
      guard locations.contains(where: { $0.blockID == options.blockID && $0.pageIndex == (options.pageIndex ?? 0) }) else {
        throw CollaborationError("export_block_missing", "Программы нет на выбранной странице видео.")
      }
      let url = directory.appendingPathComponent("document.mp4")
      try await NotebookVideoExport.write(to: url, cut: cut, options: options, jobID: jobID, store: store, renderSession: printSession)
      return .init(cut: cut, source: "", artifact: try await stage(url, path: "document.mp4", persistence: persistence),
        log: "H.264, no audio; explicit model times [start,end); canonical page, even height padded white", options: options, jobID: jobID)
    }
    if options.format == .svg {
      guard let block = document.blocks.first(where: { $0.id == options.blockID && $0.kind == .interactive }) else {
        throw CollaborationError("export_block_missing", "SVG exportFrame принадлежит явно названной программе.")
      }
      guard let printed, let printSession else { throw DocumentSessionError.invalidLayout }
      let locations = printed.locations
      guard let page = locations.first(where: { $0.blockID == block.id })?.pageIndex else {
        throw CollaborationError("export_block_missing", "Программы нет в принятом печатном макете.")
      }
      let svg = try await DocumentSnapshotCache.shared.withPreparedPage(document: document, state: state, pageIndex: page,
        resources: .shared, programStore: store, isolationID: jobID, renderSession: printSession) { coordinator in
        try await coordinator.exportSVG(block: block, state: state.value(for: block.id) ?? block.initialState)
      }
      let file = try await stage(Data(svg.utf8), path: "document.svg", directory: directory, persistence: persistence)
      return .init(cut: cut, source: "", artifact: file, log: artifact.log, options: options, jobID: jobID)
    }
    if options.format == .png {
      let pageIndex = options.pageIndex ?? 0, width = options.pixelWidth ?? 1600
      guard let printSession, let pages = printSource?.layout?.pageCount else { throw DocumentSessionError.invalidLayout }
      guard pageIndex < pages else { throw CollaborationError("export_page_missing", "Такой страницы нет в принятом печатном макете.") }
      let raster = try await DocumentSnapshotCache.shared.withPreparedPage(document: document, state: state, pageIndex: pageIndex,
        resources: .shared, programStore: store, isolationID: jobID, renderSession: printSession) { coordinator in
        try await coordinator.retainPreparedSnapshot(pixelWidth: width, force: true, waitsForRasterAdmission: true)
      }
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
      guard let printed else { throw DocumentSessionError.invalidLayout }
      let composer = try await PrintedPDFComposer.open(printed.pdf, outputURL: pdfURL)
      let mapped = printed.locations.filter { programs.contains($0.blockID) }
      let byPage = Dictionary(grouping: mapped, by: \.pageIndex)
      for pageIndex in 0..<composer.pageCount {
        try Task.checkCancellation()
        let locations = byPage[pageIndex] ?? []
        if locations.isEmpty { try await composer.append(pageIndex: pageIndex, image: nil, regions: []); continue }
        let geometry = WorkspaceItemGeometry.document(document.paperSize)
        try await DocumentSnapshotCache.shared.withPreparedPage(document: document, state: state, pageIndex: pageIndex,
          resources: .shared, programStore: store, isolationID: jobID, renderSession: printSession) { coordinator in
          let raster = try await coordinator.retainPreparedSnapshot(pixelWidth: Int(ceil(document.paperSize.widthPoints * 300 / 72)),
            force: true, waitsForRasterAdmission: true)
          defer { raster.release() }
          let vectors = try await coordinator.exportPDFVectors(pointScale: document.paperSize.widthPoints / geometry.width)
          defer { vectors.storage?.release() }
          var rect = CGRect(origin: .zero, size: raster.image.size)
          guard let image = raster.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw SceneRenderError.resourceLimit }
          let regions = Dictionary(grouping: locations, by: \.blockID).values.map { group in
            group.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
          }
          try await composer.append(pageIndex: pageIndex, image: image, regions: regions, vectors: vectors.values)
        }
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

/// Composition borrows the print source's serial Quartz owner. At most one
/// admitted page raster crosses it at a time; no source parser is reopened.
final class PrintedPDFComposer: @unchecked Sendable {
  private let source: DocumentPrintedPDF
  private var links: PDFDocument?
  private var context: CGContext?
  private var destinations: [Int: [(name: String, point: CGPoint)]] = [:]
  private var linkNames: [Int: [Int: String]] = [:]
  private let output: PrintedPDFSink
  private(set) var pageCount = 0
  private init(_ source: DocumentPrintedPDF, outputURL: URL) throws {
    self.source = source; output = try PrintedPDFSink(url: outputURL)
  }
  deinit {
    let context = context, links = links
    source.finishOnQueue { context?.closePDF(); withExtendedLifetime(links) {} }
  }
  static func open(_ source: DocumentPrintedPDF, outputURL: URL) async throws -> PrintedPDFComposer {
    let owner = try PrintedPDFComposer(source, outputURL: outputURL)
    try await source.perform { links,document in
      guard let consumer = owner.output.consumer(), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
        throw SceneRenderError.resourceLimit
      }
      owner.links = links; owner.context = context; owner.pageCount = document.numberOfPages
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
  func append(pageIndex: Int, image: CGImage?, regions: [CGRect], vectors: [DocumentPDFVector] = []) async throws {
    try await source.perform { [self] _,document in
      guard let page = document.page(at: pageIndex+1), let context else { throw SceneRenderError.resourceLimit }
      let box = page.getBoxRect(.mediaBox)
      context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [box], length: MemoryLayout<CGRect>.size)] as CFDictionary)
      context.drawPDFPage(page)
      if let image {
        for region in regions {
          let physical = CGRect(x: region.minX, y: box.height-region.maxY, width: region.width, height: region.height)
          context.saveGState()
          let mask = CGMutablePath(); mask.addRect(physical)
          for vector in vectors {
            let cut = vector.frame.intersection(vector.clip).intersection(region)
            if !cut.isNull && !cut.isEmpty { mask.addRect(CGRect(x: cut.minX, y: box.height-cut.maxY, width: cut.width, height: cut.height)) }
          }
          context.addPath(mask); context.clip(using: .evenOdd)
          context.draw(image, in: box); context.restoreGState()
        }
      }
      for vector in vectors {
        guard let provider = CGDataProvider(data: vector.pdf as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1), pdf.numberOfPages == 1 else { throw SceneRenderError.resourceLimit }
        let frame = CGRect(x: vector.frame.minX, y: box.height-vector.frame.maxY, width: vector.frame.width, height: vector.frame.height)
        let clip = CGRect(x: vector.clip.minX, y: box.height-vector.clip.maxY, width: vector.clip.width, height: vector.clip.height)
        context.saveGState(); context.clip(to: clip)
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: frame, rotate: 0, preserveAspectRatio: false))
        context.drawPDFPage(page); context.restoreGState()
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
    try await source.perform { [self] _,_ in
      context?.closePDF(); context = nil; links = nil
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
