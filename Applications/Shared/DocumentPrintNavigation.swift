import Foundation
import PDFKit
import NotebookCore

struct DocumentPrintNavigation: Sendable {
  struct Link: Sendable { let page: Int; let rect: CGRect; let href: String; let label: String }
  let links: [Link]
  let pageText: [Int: String]
  let anchors: [String: Int]
  static func read(_ pdf: PDFDocument, pages: [DocumentPrintPage], pageIndices: Set<Int>? = nil) throws -> Self {
    guard (1...4096).contains(pdf.pageCount), pages.count == pdf.pageCount else { throw DocumentSessionError.invalidLayout }
    var links: [Link] = [], text: [Int: String] = [:], bytes = 0, linkBytes = 0
    for index in (pageIndices ?? Set(0..<pdf.pageCount)).sorted() {
      guard (0..<pdf.pageCount).contains(index) else { throw DocumentSessionError.invalidLayout }
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else { throw DocumentSessionError.invalidLayout }
      let bounds = page.bounds(for: .mediaBox), string = page.string ?? ""
      bytes += string.utf8.count
      guard bytes <= 8*1024*1024 else { throw SceneRenderError.resourceLimit }
      text[index] = string
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
        let label = String((page.selection(for: box)?.string ?? "").prefix(4096))
          .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        linkBytes += label.utf8.count
        guard linkBytes <= 1024*1024 else { throw SceneRenderError.resourceLimit }
        let projected = pages[index].projectPDF(x: box.minX, y: box.minY, width: box.width, height: box.height)
        links.append(.init(page: index, rect: .init(x: projected.x, y: projected.y,
          width: projected.width, height: projected.height), href: href, label: label.isEmpty ? "Открыть ссылку" : label))
      }
    }
    return .init(links: links, pageText: text, anchors: pageIndices == nil ? try namedDestinations(pdf) : [:])
  }

  /// Hyperref's named destinations remain addresses in the PDF. In particular,
  /// program links use the same shipped target as a printed \ref annotation.
  static func namedDestinations(_ pdf: PDFDocument) throws -> [String: Int] {
    guard let document = pdf.documentRef, let catalog = document.catalog else { return [:] }
    var names: CGPDFDictionaryRef?, destinations: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
      CGPDFDictionaryGetDictionary(names, "Dests", &destinations), let destinations else { return [:] }
    var pageIndices: [CGPDFDictionaryRef: Int] = [:]
    for index in 0..<document.numberOfPages {
      if let dictionary = document.page(at: index + 1)?.dictionary { pageIndices[dictionary] = index }
    }
    var result: [String: Int] = [:], visited: Set<CGPDFDictionaryRef> = [], bytes = 0
    func destinationPage(_ object: CGPDFObjectRef) -> Int? {
      var array: CGPDFArrayRef?, dictionary: CGPDFDictionaryRef?
      if !CGPDFObjectGetValue(object, .array, &array),
        CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary {
        _ = CGPDFDictionaryGetArray(dictionary, "D", &array)
      }
      guard let array, CGPDFArrayGetDictionary(array, 0, &dictionary), let dictionary else { return nil }
      return pageIndices[dictionary]
    }
    func visit(_ node: CGPDFDictionaryRef, depth: Int) throws {
      guard depth < 64, visited.insert(node).inserted, visited.count <= 16_384 else { throw SceneRenderError.resourceLimit }
      try Task.checkCancellation()
      var values: CGPDFArrayRef?
      if CGPDFDictionaryGetArray(node, "Names", &values), let values {
        let count = CGPDFArrayGetCount(values)
        guard count % 2 == 0, count <= 32_768 else { throw SceneRenderError.resourceLimit }
        for index in stride(from: 0, to: count, by: 2) {
          var key: CGPDFStringRef?, object: CGPDFObjectRef?
          guard CGPDFArrayGetString(values, index, &key), let key,
            let text = CGPDFStringCopyTextString(key) as String?,
            CGPDFArrayGetObject(values, index + 1, &object), let object,
            let page = destinationPage(object) else { continue }
          bytes += text.utf8.count
          guard !text.isEmpty, text.utf8.count <= 4096, bytes <= 1024*1024, result.count < 16_384 else { throw SceneRenderError.resourceLimit }
          result[text] = page
        }
      }
      var children: CGPDFArrayRef?
      if CGPDFDictionaryGetArray(node, "Kids", &children), let children {
        guard CGPDFArrayGetCount(children) <= 16_384 else { throw SceneRenderError.resourceLimit }
        for index in 0..<CGPDFArrayGetCount(children) {
          var child: CGPDFDictionaryRef?
          if CGPDFArrayGetDictionary(children, index, &child), let child { try visit(child, depth: depth + 1) }
        }
      }
    }
    try visit(destinations, depth: 0)
    return result
  }

}
