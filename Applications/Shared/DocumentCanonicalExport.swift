#if os(macOS)
import AppKit
import CoreGraphics
import NotebookCore
import NotebookTypesetter
import PDFKit

/// Export reads the same ready print artifact as paper. Only live program
/// rectangles are frozen as images; all typeset text, paths and links remain
/// vector PDF, at their already installed physical coordinates.
@MainActor enum DocumentCanonicalExport {
  static func publication(document: DocumentDocument, state: DocumentStateJournal, jobID: UUID) async throws -> NotebookExportPublication {
    let artifact = try await DocumentCanonicalPrint.store.artifact(for: document)
    let programs = Set(document.blocks.filter { $0.kind == .interactive }.map(\.id))
    var pdf = artifact.pdf
    if !programs.isEmpty {
      let composer = try await PrintedPDFComposer.open(artifact.pdf)
      let mapped = try await Task.detached { try artifact.locations().filter { programs.contains($0.blockID) } }.value
      let byPage = Dictionary(grouping: mapped, by: \.pageIndex)
      for pageIndex in 0..<composer.pageCount {
        try Task.checkCancellation()
        let locations = byPage[pageIndex] ?? []
        if locations.isEmpty { try await composer.append(pageIndex: pageIndex, image: nil, regions: []); continue }
        let raster = try await DocumentSnapshotCache.shared.prepare(document: document, state: state, pageIndex: pageIndex)
        defer { raster.release() }
        var rect = CGRect(origin: .zero, size: raster.image.size)
        guard let image = raster.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw SceneRenderError.resourceLimit }
        var regions: [CGRect] = []
        for group in Dictionary(grouping: locations, by: \.blockID).values {
          regions.append(group.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) })
        }
        try await composer.append(pageIndex: pageIndex, image: image, regions: regions)
      }
      pdf = try await composer.finish()
    }
    let map = try DocumentPrintSourceMap(document: document, source: artifact.source, pdf: pdf, ranges: artifact.sourceMap.ranges)
    return .init(documentID: document.id, expectedRevision: document.contentStamp.revision,
      source: artifact.source, pdf: pdf, log: artifact.log, jobID: jobID,
      assets: artifact.assets.map { .init(name: $0.name, data: $0.data) }, sourceMap: map, syncTeX: artifact.syncTeX)
  }
}

/// The queue owns Quartz for the complete composition; at most one admitted
/// page raster crosses it at a time. No source is typeset again here.
private final class PrintedPDFComposer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "Notebook.print-export")
  private let queueKey = DispatchSpecificKey<Bool>()
  private let source: Data
  private var input: CGPDFDocument?
  private var links: PDFDocument?
  private var context: CGContext?
  private var destinations: [Int: [(name: String, point: CGPoint)]] = [:]
  private var linkNames: [Int: [Int: String]] = [:]
  private let output = NotebookPDFBuffer(limit: 16*1024*1024)
  private(set) var pageCount = 0
  private init(_ source: Data) { self.source = source; queue.setSpecific(key: queueKey, value: true) }
  deinit {
    let context = context, input = input, links = links
    let close = { context?.closePDF(); withExtendedLifetime(input) {}; withExtendedLifetime(links) {} }
    if DispatchQueue.getSpecific(key: queueKey) == true { close() } else { queue.sync(execute: close) }
  }
  static func open(_ source: Data) async throws -> PrintedPDFComposer {
    let owner = PrintedPDFComposer(source)
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
      _ = try output.result()
    }
  }
  func finish() async throws -> Data {
    try await perform { [self] in
      context?.closePDF(); context = nil; input = nil; links = nil
      _ = try output.result()
      return try output.result()
    }
  }
}
#endif
