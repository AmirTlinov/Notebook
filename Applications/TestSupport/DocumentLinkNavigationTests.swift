import Foundation
import NotebookCore
import XCTest
@testable import Notebook

@MainActor
final class DocumentLinkNavigationTests: XCTestCase {
  private func book() -> DocumentDocument {
    DocumentTestFiles.document(actor: UUID(), contents: [
      .tex(id: "contents", source: "\\section{Contents}\\hyperlink{far-section}{Far section}"),
      .tex(id: "body", source: String(repeating: "Intermediate content occupies physical sheets.\n\n", count: 120)),
      .tex(id: "far", source: "\\section{Far section}\\hypertarget{far-section}{}\\hypertarget{named}{}\\hyperlink{contents}{Return}\\subsection{Named heading}"),
      .tex(id: "duplicate", source: "\\section{Generated heading}\\hypertarget{generated-heading}{}\n\nThe second automatic address stays distinct.")
    ])
  }

  private func layout(anchors: [String: Int]) throws -> DocumentLayoutRecord {
    try DocumentLayoutFixture.make(pages: Array(repeating: .uncompiled, count: 4), anchors: anchors)
  }

  func testLinkIndexRejectsInvalidAddressesAndCannotBeReplacedByADifferentSourceLayout() throws {
    let first = try layout(anchors: ["section": 2])
    XCTAssertEqual(first.destination(for: "#section"), .page(2))
    XCTAssertEqual(first.destination(for: "#"), .page(0))
    XCTAssertEqual(first.destination(for: "#top"), .page(0))
    for href in ["#absent", "#%ZZ", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "relative.html#section", "https://"] {
      guard case .unavailable = first.destination(for: href) else { return XCTFail("Accepted \(href)") }
    }
    for href in ["https://example.com/book#section", "http://example.com", "mailto:reader@example.com"] {
      XCTAssertEqual(first.destination(for: href), .external(try XCTUnwrap(URL(string: href))))
    }
    XCTAssertFalse(first.matches(try layout(anchors: ["section": 3])))
    for anchors: [String: Int] in [["": 0], ["bad": -1], ["bad": 4], [String(repeating: "x", count: 4097): 0]] {
      XCTAssertThrowsError(try layout(anchors: anchors))
    }
  }

  func testPrintedLinksComeFromTheSamePDFAndKeepTheirPhysicalDestinations() async throws {
    let source = try await preparedSource(book()), layout = try XCTUnwrap(source.layout)
    let far = try XCTUnwrap(layout.regions.first { $0.id == "far" }?.pageIndex)
    XCTAssertGreaterThan(far, 0)
    let printed = try await source.printedSource(resources: SceneRenderResources.shared)
    let pages = printed.artifact.pages
    let links = try await printed.pdf.perform { pdf, _ in
      try DocumentPrintNavigation.read(pdf, pages: pages).links
    }
    XCTAssertTrue(links.contains { $0.page == 0 && $0.label == "Far section" && layout.destination(for: $0.href) == .page(far) })
    XCTAssertTrue(links.contains { $0.page == far && layout.destination(for: $0.href) == .page(0) })
    XCTAssertEqual(source.measurementCount, 1)
  }

  func testMeasuredReadingAddressKeepsTheSameTextAfterPrecedingSourceInsertion() async throws {
    var document = book()
    let first = try await preparedSource(document)
    let oldLayout = try XCTUnwrap(first.layout)
    let far = try XCTUnwrap(oldLayout.regions.first { $0.id == "far" })
    let page = far.pageIndex
    let anchor = try XCTUnwrap(oldLayout.reading.anchor(page: page, fileOrder: document.files.map(\.id), y: far.frame.y))
    XCTAssertEqual(anchor.fileID, "far")
    XCTAssertFalse(anchor.nodeID.isEmpty)
    let originalBody = try XCTUnwrap(document.files.first { $0.id == "body" }).source
    XCTAssertTrue(document.replaceFileSource(id: "body", source:
      String(repeating: "A new preceding paragraph changes page boundaries.\n\n", count: 80) + originalBody, actor: UUID()))
    let next = try await preparedSource(document)
    let layout = try XCTUnwrap(next.layout)
    let restoredPage = try XCTUnwrap(layout.reading.page(for: anchor,
      survivingFileOrder: document.files.map(\.id), regions: layout.regions))
    XCTAssertGreaterThan(restoredPage, page)
    XCTAssertTrue(layout.reading.segments.contains { $0.pageIndex == restoredPage && $0.nodeID == anchor.nodeID },
      "The new page contains the actual old text, not the old numeric page")
    let source = next
    await source.discardIdlePreparation()
    XCTAssertEqual(layout.reading.page(for: anchor, survivingFileOrder: document.files.map(\.id), regions: layout.regions), restoredPage)
  }

  private func preparedSource(_ document: DocumentDocument) async throws -> DocumentSourceSnapshot {
    let source = DocumentSourceSnapshot(document), host = UUID()
    source.retainPage(0, hostID: host)
    defer { source.releasePage(hostID: host, in: nil, retiring: true) }
    _ = try await source.preparedPage(0, hostID: host, resources: SceneRenderResources.shared)
    return source
  }
}
