import Foundation
import CoreGraphics
import NotebookCore
import NotebookTypesetter

/// Canonical print artifacts are shared by the scene and the export adapter.
/// The source document, not a view mode, chooses the sole printed layout.
enum DocumentCanonicalPrint {
  static let store = NotebookPrintedDocumentStore(
    resources: Bundle.main.resourceURL!.appendingPathComponent("NotebookTypesetter", isDirectory: true),
    directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NotebookPrintedPages", isDirectory: true))
}

@MainActor
final class DocumentPrintedSource {
  let artifact: NotebookPrintedDocument
  let locations: [DocumentPrintLocation]
  private let reservation: RasterReservation
  init(artifact: NotebookPrintedDocument, locations: [DocumentPrintLocation] = [], reservation: RasterReservation) {
    self.artifact = artifact; self.locations = locations; self.reservation = reservation
  }
  func sourceOffset(blockID: String, pageIndex: Int, x: Double, y: Double) -> Int? {
    guard let location = DocumentPrintLocations.nearest(in: locations, blockID: blockID, pageIndex: pageIndex, x: x, y: y),
      let range = artifact.sourceMap.ranges.first(where: { $0.blockID == blockID }),
      let block = artifact.document.blocks.first(where: { $0.id == blockID }) else { return nil }
    return DocumentPrintLocations.sourceOffset(line: location.generatedLine, range: range, source: block.source)
  }
  func reference(blockID: String, sourceOffset: Int) -> CollaborationReference? {
    let document = artifact.document
    guard let block = document.blocks.first(where: { $0.id == blockID }),
      let range = artifact.sourceMap.ranges.first(where: { $0.blockID == blockID }) else { return nil }
    let line = DocumentPrintLocations.generatedLine(sourceOffset: sourceOffset, range: range, source: block.source)
    let authored = DocumentPrintLocations.sourceOffset(line: line, range: range, source: block.source)
    func rank(_ location: DocumentPrintLocation) -> (Int, Int, Double, Int, Double) {
      let offset = DocumentPrintLocations.sourceOffset(line: location.generatedLine, range: range, source: block.source)
      return (abs(offset-authored), abs(location.generatedLine-line), location.width*location.height, location.pageIndex, location.y)
    }
    guard let location = locations.lazy.filter({ $0.blockID == blockID }).min(by: { rank($0) < rank($1) }) else { return nil }
    let scale = WorkspaceItemGeometry.document(document.paperSize).width / document.paperSize.widthPoints
    // A region, not an element address: the existing navigation/highlight owner
    // should reveal this source line rather than replace it with the whole block.
    return .init(target: .init(kind: .document, id: document.id),
      region: .init(x: location.x*scale, y: location.y*scale, width: location.width*scale, height: location.height*scale),
      pageIndex: location.pageIndex, revision: document.contentStamp.revision, label: blockID)
  }
  isolated deinit { reservation.release() }
}

@MainActor
struct DocumentPrintedPage {
  let source: DocumentPrintedSource
  var artifact: NotebookPrintedDocument { source.artifact }
  let pageIndex: Int
  let width: Double
  let height: Double

  /// Raster density is a display concern only. It cannot change line breaks,
  /// source addresses, page count or the ready PDF used for export.
  func image(width pixels: Int, overlay: CGImage? = nil) async throws -> CGImage {
    let data = artifact.pdf, pageIndex = pageIndex, aspect = height / width
    let programs = Set(artifact.document.blocks.filter { $0.kind == .interactive }.map(\.id))
    let regions = source.locations.filter { $0.pageIndex == pageIndex && programs.contains($0.blockID) }
      .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let h = max(1, Int(ceil(Double(pixels) * aspect)))
      guard pixels > 0, pixels <= 8192, h <= 8192, pixels * h <= 16_777_216,
        let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
        let page = document.page(at: pageIndex + 1),
        let context = CGContext(data: nil, width: pixels, height: h, bitsPerComponent: 8, bytesPerRow: pixels*4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw SceneRenderError.resourceLimit }
      let rect = CGRect(x: 0, y: 0, width: pixels, height: h)
      context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
      // Quartz fits large pages down but does not enlarge a small media box.
      // Normalize first, then apply the requested pixel extent explicitly.
      context.saveGState(); context.scaleBy(x: rect.width, y: rect.height)
      context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: 1, height: 1), rotate: 0, preserveAspectRatio: false))
      context.drawPDFPage(page); context.restoreGState()
      if let overlay, !regions.isEmpty {
        // A WebKit snapshot can have an opaque white background even though
        // the mounted overlay is transparent. Only program rectangles belong
        // to it; paper/text/formulas remain the canonical PDF's responsibility.
        let box = page.getBoxRect(.mediaBox)
        context.saveGState()
        let clips = regions.map { region in CGRect(x: region.minX/box.width*rect.width,
          y: (box.height-region.maxY)/box.height*rect.height, width: region.width/box.width*rect.width,
          height: region.height/box.height*rect.height) }
        context.clip(to: clips)
        context.draw(overlay, in: rect); context.restoreGState()
      }
      try Task.checkCancellation()
      guard let image = context.makeImage() else { throw SceneRenderError.resourceLimit }
      return image
    }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
}
