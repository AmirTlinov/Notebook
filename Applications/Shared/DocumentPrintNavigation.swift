import Foundation
import PDFKit

struct DocumentPrintNavigation: Sendable {
  struct Link: Sendable { let page: Int; let rect: CGRect; let href: String }
  let links: [Link]
  let pageText: [String]
  static func read(_ data: Data) throws -> Self {
    guard let pdf = PDFDocument(data: data) else { throw DocumentSessionError.invalidLayout }
    return try read(pdf)
  }
  static func read(_ pdf: PDFDocument) throws -> Self {
    guard (1...4096).contains(pdf.pageCount) else { throw DocumentSessionError.invalidLayout }
    var links: [Link] = [], text: [String] = [], bytes = 0, linkBytes = 0
    for index in 0..<pdf.pageCount {
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else { throw DocumentSessionError.invalidLayout }
      let bounds = page.bounds(for: .mediaBox), string = page.string ?? ""
      bytes += string.utf8.count
      guard bytes <= 8*1024*1024 else { throw SceneRenderError.resourceLimit }
      text.append(string)
      for annotation in page.annotations {
        let href: String
        if let action = annotation.action as? PDFActionURL, let url = action.url { href = url.absoluteString }
        else if let destination = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination,
          let target = destination.page {
          href = "#notebook-print-page-\(pdf.index(for: target))"
        } else { continue }
        linkBytes += href.utf8.count
        guard linkBytes <= 1024*1024 else { throw SceneRenderError.resourceLimit }
        let box = annotation.bounds.intersection(bounds)
        guard !box.isNull, box.width > 0, box.height > 0, href.utf8.count <= 4096, links.count < 16_384 else { throw SceneRenderError.resourceLimit }
        links.append(.init(page: index, rect: .init(x: box.minX, y: bounds.height-box.maxY, width: box.width, height: box.height), href: href))
      }
    }
    return .init(links: links, pageText: text)
  }
}
